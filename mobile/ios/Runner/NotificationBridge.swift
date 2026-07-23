import CallKit
import Flutter
import Foundation
import PushKit
import Security
import UIKit
import UserNotifications

private enum NotificationConstants {
  static let methodChannel = "juliatalk/notifications"
  static let eventChannel = "juliatalk/notification-events"
  static let replyCategory = "JULIATALK_REPLY"
  static let photoCategory = "JULIATALK_PHOTO"
  static let replyAction = "JULIATALK_REPLY_ACTION"
  static let credentialsKey = "notification-credentials"
  static let installationKey = "notification-installation-id"
  static let pushTokenKey = "juliatalk.push-token"
  static let voipPushTokenKey = "juliatalk.voip-push-token"
}

private struct NotificationCredentials: Codable {
  let apiBaseURL: String
  let accessToken: String
  let userID: String
  let preferredLanguage: String
}

private enum KeychainStore {
  static func save(_ data: Data, key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Bundle.main.bundleIdentifier ?? "JuliaTalk",
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)

    var insert = query
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(insert as CFDictionary, nil)
  }

  static func load(key: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Bundle.main.bundleIdentifier ?? "JuliaTalk",
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
      return nil
    }
    return result as? Data
  }
}

final class NotificationBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static var sharedInstance: NotificationBridge?

  private var eventSink: FlutterEventSink?
  private var pendingEvents: [[String: Any]] = []
  private var voipRegistry: PKPushRegistry?
  private var activeChatSenderID: String?
  private var activeCallers: [UUID: [String: Any]] = [:]
  private var answeredCalls: [UUID: Date] = [:]
  private var callSignalingSession: URLSession?
  private var callSignalingTask: URLSessionWebSocketTask?
  private let callProvider: CXProvider

  override init() {
    let configuration = CXProviderConfiguration(localizedName: "JuliaTalk")
    configuration.supportsVideo = true
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]
    configuration.includesCallsInRecents = true
    callProvider = CXProvider(configuration: configuration)
    super.init()
    callProvider.setDelegate(self, queue: .main)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NotificationBridge()
    sharedInstance = instance

    let methodChannel = FlutterMethodChannel(
      name: NotificationConstants.methodChannel,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    registrar.addApplicationDelegate(instance)

    let eventChannel = FlutterEventChannel(
      name: NotificationConstants.eventChannel,
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(instance)
    UNUserNotificationCenter.current().delegate = instance
    instance.registerNotificationCategories()
    instance.startVoIPRegistration()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      configure(arguments: call.arguments, result: result)
    case "requestAuthorization":
      requestAuthorization(result: result)
    case "startVoIP":
      startVoIPRegistration()
      result(nil)
    case "getSettings":
      getSettings(result: result)
    case "setBadgeCount":
      let arguments = call.arguments as? [String: Any]
      let count = arguments?["count"] as? Int ?? 0
      setBadgeCount(count, result: result)
    case "setActiveChatSenderId":
      let arguments = call.arguments as? [String: Any]
      activeChatSenderID = arguments?["senderId"] as? String
      result(nil)
    case "clearActiveChatSenderId":
      let arguments = call.arguments as? [String: Any]
      let senderID = arguments?["senderId"] as? String
      if activeChatSenderID == senderID {
        activeChatSenderID = nil
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    pendingEvents.forEach(events)
    pendingEvents.removeAll()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func configure(arguments: Any?, result: @escaping FlutterResult) {
    guard
      let values = arguments as? [String: Any],
      let apiBaseURL = values["apiBaseUrl"] as? String,
      let accessToken = values["accessToken"] as? String,
      let userID = values["userId"] as? String,
      let preferredLanguage = values["preferredLanguage"] as? String
    else {
      result(FlutterError(
        code: "invalid-arguments",
        message: "Notification configuration is incomplete.",
        details: nil
      ))
      return
    }

    let credentials = NotificationCredentials(
      apiBaseURL: apiBaseURL,
      accessToken: accessToken,
      userID: userID,
      preferredLanguage: preferredLanguage
    )
    guard let data = try? JSONEncoder().encode(credentials) else {
      result(FlutterError(
        code: "configuration-failed",
        message: "Could not encode notification configuration.",
        details: nil
      ))
      return
    }

    KeychainStore.save(data, key: NotificationConstants.credentialsKey)
    registerNotificationCategories()
    syncDeviceRegistration()
    result(nil)
  }

  private func requestAuthorization(result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(
            code: "authorization-failed",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }

        if granted {
          UIApplication.shared.registerForRemoteNotifications()
        }
        result(granted)
      }
    }
  }

  private func getSettings(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      result([
        "authorizationStatus": settings.authorizationStatus.rawValue,
        "alertSetting": settings.alertSetting.rawValue,
        "badgeSetting": settings.badgeSetting.rawValue,
        "soundSetting": settings.soundSetting.rawValue,
        "lockScreenSetting": settings.lockScreenSetting.rawValue,
        "notificationCenterSetting": settings.notificationCenterSetting.rawValue,
      ])
    }
  }

  private func setBadgeCount(_ count: Int, result: @escaping FlutterResult) {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(count) { error in
        if let error = error {
          result(FlutterError(
            code: "badge-failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          result(nil)
        }
      }
    } else {
      UIApplication.shared.applicationIconBadgeNumber = count
      result(nil)
    }
  }

  private func registerNotificationCategories() {
    let language = Locale.preferredLanguages.first?.lowercased() ?? "ko"
    let isChinese = language.hasPrefix("zh")
    let action = UNTextInputNotificationAction(
      identifier: NotificationConstants.replyAction,
      title: isChinese ? "答复" : "답장",
      options: [],
      textInputButtonTitle: isChinese ? "发送" : "전송",
      textInputPlaceholder: ""
    )
    let replyCategory = UNNotificationCategory(
      identifier: NotificationConstants.replyCategory,
      actions: [action],
      intentIdentifiers: ["INSendMessageIntent"],
      options: [.customDismissAction]
    )
    let photoCategory = UNNotificationCategory(
      identifier: NotificationConstants.photoCategory,
      actions: [action],
      intentIdentifiers: ["INSendMessageIntent"],
      options: [.customDismissAction]
    )
    UNUserNotificationCenter.current().setNotificationCategories([
      replyCategory,
      photoCategory,
    ])
  }

  private func startVoIPRegistration() {
    guard voipRegistry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
  }

  private func credentials() -> NotificationCredentials? {
    guard let data = KeychainStore.load(key: NotificationConstants.credentialsKey) else {
      return nil
    }
    return try? JSONDecoder().decode(NotificationCredentials.self, from: data)
  }

  private func installationID() -> String {
    if
      let data = KeychainStore.load(key: NotificationConstants.installationKey),
      let value = String(data: data, encoding: .utf8)
    {
      return value
    }

    let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    KeychainStore.save(Data(value.utf8), key: NotificationConstants.installationKey)
    return value
  }

  private var apnsEnvironment: String? {
    guard
      let profileURL = Bundle.main.url(
        forResource: "embedded",
        withExtension: "mobileprovision"
      )
    else {
      // App Store and TestFlight builds do not expose an embedded profile at
      // runtime, and both use the production APNs environment.
      return "production"
    }

    if
      let profileData = try? Data(contentsOf: profileURL),
      let profileText = String(data: profileData, encoding: .isoLatin1),
      let plistStart = profileText.range(of: "<?xml"),
      let plistEnd = profileText.range(
        of: "</plist>",
        range: plistStart.lowerBound..<profileText.endIndex
      ),
      let plistData = String(
        profileText[plistStart.lowerBound..<plistEnd.upperBound]
      ).data(using: .utf8),
      let plist = try? PropertyListSerialization.propertyList(
        from: plistData,
        options: [],
        format: nil
      ),
      let profile = plist as? [String: Any],
      let entitlements = profile["Entitlements"] as? [String: Any],
      let environment = entitlements["aps-environment"] as? String,
      environment == "development" || environment == "production"
    {
      return environment
    }

    return nil
  }

  private func syncDeviceRegistration(clearVoIPToken: Bool = false) {
    guard
      let credentials = credentials(),
      let baseURL = URL(string: credentials.apiBaseURL),
      let bundleID = Bundle.main.bundleIdentifier,
      let apnsEnvironment
    else { return }

    let defaults = UserDefaults.standard
    let pushToken = defaults.string(forKey: NotificationConstants.pushTokenKey)
    let voipToken = defaults.string(forKey: NotificationConstants.voipPushTokenKey)
    guard pushToken != nil || voipToken != nil || clearVoIPToken else { return }

    var body: [String: Any] = [
      "installation_id": installationID(),
      "platform": "ios",
      "app_bundle_id": bundleID,
      "apns_environment": apnsEnvironment,
      "device_name": UIDevice.current.name,
    ]
    if let pushToken { body["push_token"] = pushToken }
    if let voipToken {
      body["voip_push_token"] = voipToken
    } else if clearVoIPToken {
      body["voip_push_token"] = NSNull()
    }

    var request = URLRequest(url: baseURL.appendingPathComponent("devices/current"))
    request.httpMethod = "PUT"
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: request).resume()
  }

  private func sendQuickReply(
    text: String,
    userInfo: [AnyHashable: Any],
    completion: @escaping () -> Void
  ) {
    guard
      let payload = userInfo["juliatalk"] as? [String: Any],
      let senderID = payload["sender_id"] as? String,
      let credentials = credentials(),
      let baseURL = URL(string: credentials.apiBaseURL)
    else {
      completion()
      return
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      completion()
      return
    }

    let body: [String: Any] = [
      "recipient_id": senderID,
      "content": trimmed,
      "message_type": "text",
    ]
    var request = URLRequest(url: baseURL.appendingPathComponent("messages"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: request) { _, _, _ in completion() }.resume()
  }

  private func reportCallOutcome(
    callUUID: UUID,
    outcome: String,
    durationMilliseconds: Int
  ) {
    guard
      let credentials = credentials(),
      let baseURL = URL(string: credentials.apiBaseURL)
    else { return }

    let body: [String: Any] = [
      "outcome": outcome,
      "duration_ms": durationMilliseconds,
    ]
    var request = URLRequest(
      url: baseURL
        .appendingPathComponent("messages")
        .appendingPathComponent(callUUID.uuidString)
        .appendingPathComponent("call-outcome")
    )
    request.httpMethod = "PATCH"
    request.timeoutInterval = 15
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: request).resume()
  }

  private func connectCallSignaling(callUUID: UUID) {
    guard
      let credentials = credentials(),
      let apiURL = URL(string: credentials.apiBaseURL),
      var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
    else { return }

    disconnectCallSignaling()
    components.scheme = apiURL.scheme == "https" ? "wss" : "ws"
    components.path = "/ws"
    components.query = nil
    components.fragment = nil
    guard let socketURL = components.url else { return }

    var request = URLRequest(url: socketURL)
    request.setValue(
      "Bearer \(credentials.accessToken)",
      forHTTPHeaderField: "Authorization"
    )
    let session = URLSession(configuration: .default)
    let task = session.webSocketTask(with: request)
    callSignalingSession = session
    callSignalingTask = task
    task.resume()
    receiveCallSignalingMessage(task: task, callUUID: callUUID)
  }

  private func receiveCallSignalingMessage(
    task: URLSessionWebSocketTask,
    callUUID: UUID
  ) {
    task.receive { [weak self] result in
      guard let self = self, self.callSignalingTask === task else { return }

      switch result {
      case .failure:
        self.disconnectCallSignaling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
          guard self.activeCallers[callUUID] != nil else { return }
          self.connectCallSignaling(callUUID: callUUID)
        }
      case .success(let message):
        let data: Data?
        switch message {
        case .data(let value):
          data = value
        case .string(let value):
          data = value.data(using: .utf8)
        @unknown default:
          data = nil
        }

        if
          let data = data,
          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          event["type"] as? String == "message.updated",
          let messagePayload = event["message"] as? [String: Any],
          (messagePayload["id"] as? String)?.lowercased()
            == callUUID.uuidString.lowercased(),
          let metadata = messagePayload["metadata"] as? [String: Any],
          let outcome = metadata["outcome"] as? String,
          outcome != "started"
        {
          let reason: CXCallEndedReason =
            outcome == "no_answer" || outcome == "missed"
              ? .unanswered
              : .remoteEnded
          self.callProvider.reportCall(
            with: callUUID,
            endedAt: Date(),
            reason: reason
          )
          self.activeCallers.removeValue(forKey: callUUID)
          self.answeredCalls.removeValue(forKey: callUUID)
          self.disconnectCallSignaling()
          return
        }

        self.receiveCallSignalingMessage(task: task, callUUID: callUUID)
      }
    }
  }

  private func disconnectCallSignaling() {
    callSignalingTask?.cancel(with: .goingAway, reason: nil)
    callSignalingSession?.invalidateAndCancel()
    callSignalingTask = nil
    callSignalingSession = nil
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async {
      if let eventSink = self.eventSink {
        eventSink(event)
      } else {
        self.pendingEvents.append(event)
      }
    }
  }

  private static func hexadecimalToken(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}

extension NotificationBridge {
  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    UserDefaults.standard.set(
      Self.hexadecimalToken(deviceToken),
      forKey: NotificationConstants.pushTokenKey
    )
    syncDeviceRegistration()
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    emit(["type": "apns.registration.failed", "message": error.localizedDescription])
  }
}

extension NotificationBridge: UNUserNotificationCenterDelegate {
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    let notificationPayload = userInfo["juliatalk"] as? [String: Any]
    let senderID = notificationPayload?["sender_id"] as? String

    if let senderID, senderID == activeChatSenderID {
      completionHandler([])
      return
    }

    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if
      response.actionIdentifier == NotificationConstants.replyAction,
      let textResponse = response as? UNTextInputNotificationResponse
    {
      sendQuickReply(
        text: textResponse.userText,
        userInfo: userInfo,
        completion: completionHandler
      )
      return
    }

    if let payload = userInfo["juliatalk"] as? [String: Any] {
      emit(["type": "notification.opened", "payload": payload])
    }
    completionHandler()
  }
}

extension NotificationBridge: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate pushCredentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    UserDefaults.standard.set(
      Self.hexadecimalToken(pushCredentials.token),
      forKey: NotificationConstants.voipPushTokenKey
    )
    syncDeviceRegistration()
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    UserDefaults.standard.removeObject(forKey: NotificationConstants.voipPushTokenKey)
    syncDeviceRegistration(clearVoIPToken: true)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard
      type == .voIP,
      let call = payload.dictionaryPayload["juliatalk_call"] as? [String: Any],
      let uuidString = call["call_uuid"] as? String,
      let uuid = UUID(uuidString: uuidString)
    else {
      completion()
      return
    }

    let callerName = call["caller_name"] as? String ?? "JuliaTalk"
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerName)
    update.localizedCallerName = callerName
    update.hasVideo = call["has_video"] as? Bool ?? false
    activeCallers[uuid] = call
    connectCallSignaling(callUUID: uuid)

    callProvider.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error = error {
        self.activeCallers.removeValue(forKey: uuid)
        self.disconnectCallSignaling()
        self.emit([
          "type": "call.report.failed",
          "callUuid": uuid.uuidString,
          "message": error.localizedDescription,
        ])
      }
      completion()
    }
  }
}

extension NotificationBridge: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    activeCallers.removeAll()
    answeredCalls.removeAll()
    disconnectCallSignaling()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    answeredCalls[action.callUUID] = Date()
    emit([
      "type": "call.answered",
      "callUuid": action.callUUID.uuidString,
      "payload": activeCallers[action.callUUID] ?? [:],
    ])
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    disconnectCallSignaling()
    let answeredAt = answeredCalls.removeValue(forKey: action.callUUID)
    let durationMilliseconds: Int
    let outcome: String
    if let answeredAt {
      durationMilliseconds = max(0, Int(Date().timeIntervalSince(answeredAt) * 1000))
      outcome = "ended"
    } else {
      durationMilliseconds = 0
      outcome = "missed"
    }
    reportCallOutcome(
      callUUID: action.callUUID,
      outcome: outcome,
      durationMilliseconds: durationMilliseconds
    )
    emit([
      "type": "call.ended",
      "callUuid": action.callUUID.uuidString,
      "payload": activeCallers[action.callUUID] ?? [:],
    ])
    activeCallers.removeValue(forKey: action.callUUID)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    emit(["type": "call.action.timed-out"])
  }
}
