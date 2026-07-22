import Intents
import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    bestAttemptContent = mutableContent

    Task {
      let content = await makeCommunicationContent(from: mutableContent)
      finish(with: content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let bestAttemptContent {
      finish(with: bestAttemptContent)
    }
  }

  private func finish(with content: UNNotificationContent) {
    guard let contentHandler else { return }
    self.contentHandler = nil
    contentHandler(content)
  }

  private func makeCommunicationContent(
    from content: UNMutableNotificationContent
  ) async -> UNNotificationContent {
    guard let payload = content.userInfo["juliatalk"] as? [String: Any] else {
      return content
    }

    if
      let photoURLString = payload["photo_url"] as? String,
      let photoURL = URL(string: photoURLString),
      let attachment = try? await notificationAttachment(from: photoURL)
    {
      content.attachments = [attachment]
    }

    guard #available(iOSApplicationExtension 15.0, *) else {
      return content
    }

    let senderID = payload["sender_id"] as? String ?? "unknown"
    let senderName = payload["sender_name"] as? String ?? content.title
    var senderImage: INImage?
    if
      let imageURLString = payload["sender_image_url"] as? String,
      let imageURL = URL(string: imageURLString),
      let imageResult = try? await URLSession.shared.data(from: imageURL)
    {
      senderImage = INImage(imageData: imageResult.0)
    }

    var senderNameComponents = PersonNameComponents()
    senderNameComponents.nickname = senderName
    let sender = INPerson(
      personHandle: INPersonHandle(value: senderID, type: .unknown),
      nameComponents: senderNameComponents,
      displayName: senderName,
      image: senderImage,
      contactIdentifier: nil,
      customIdentifier: senderID,
      isMe: false,
      suggestionType: .none
    )
    let recipient = INPerson(
      personHandle: INPersonHandle(value: "me", type: .unknown),
      nameComponents: nil,
      displayName: nil,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: "me",
      isMe: true,
      suggestionType: .none
    )
    let conversationIdentifier =
      payload["conversation_id"] as? String ?? content.threadIdentifier
    let intent = INSendMessageIntent(
      recipients: [recipient],
      outgoingMessageType: .outgoingMessageText,
      content: content.body,
      speakableGroupName: nil,
      conversationIdentifier: conversationIdentifier,
      serviceName: "JuliaTalk",
      sender: sender,
      attachments: nil
    )
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    await withCheckedContinuation {
      (continuation: CheckedContinuation<Void, Never>) in
      interaction.donate { _ in
        continuation.resume()
      }
    }

    do {
      return try content.updating(from: intent)
    } catch {
      return content
    }
  }

  private func notificationAttachment(
    from remoteURL: URL
  ) async throws -> UNNotificationAttachment {
    let (data, response) = try await URLSession.shared.data(from: remoteURL)
    let mimeType = (response as? HTTPURLResponse)?.mimeType
    let fileExtension = preferredExtension(
      mimeType: mimeType,
      remoteURL: remoteURL
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let localURL = directory.appendingPathComponent("attachment.\(fileExtension)")
    try data.write(to: localURL, options: .atomic)
    return try UNNotificationAttachment(
      identifier: "juliatalk-photo",
      url: localURL,
      options: nil
    )
  }

  private func preferredExtension(mimeType: String?, remoteURL: URL) -> String {
    switch mimeType?.lowercased() {
    case "image/png": return "png"
    case "image/gif": return "gif"
    case "image/heic", "image/heif": return "heic"
    case "image/webp": return "webp"
    default:
      let pathExtension = remoteURL.pathExtension
      return pathExtension.isEmpty ? "jpg" : pathExtension
    }
  }
}
