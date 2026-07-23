import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/notifications/notification_service.dart';
import '../../auth/domain/auth_session.dart';
import 'chat_api.dart';
import 'chat_realtime_event_state.dart';

final class ChatRealtimeService extends ChangeNotifier
    with WidgetsBindingObserver {
  ChatRealtimeService({
    required ChatApi chatApi,
    required Uri baseUri,
    required AuthSession session,
    required NotificationService notificationService,
  }) : _chatApi = chatApi,
       _baseUri = baseUri,
       _session = session,
       _notificationService = notificationService;

  static const Duration _reconnectDelay = Duration(seconds: 2);
  static const Duration _pingInterval = Duration(seconds: 25);

  final ChatApi _chatApi;
  final Uri _baseUri;
  final AuthSession _session;
  final NotificationService _notificationService;
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final Set<String> _markReadInFlight = <String>{};
  final Set<String> _markReadPending = <String>{};
  final RecentMessageIdCache _processedMessageIds = RecentMessageIdCache();

  WebSocketChannel? _webSocketChannel;
  StreamSubscription<dynamic>? _webSocketSubscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Map<String, int> _unreadCountByUserId = const <String, int>{};
  AppLifecycleState _lifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  String? _activeConversationUserId;
  String? _unreadSnapshotStreamId;
  int _lastUnreadSnapshotSequence = 0;
  int _unreadMutationRevision = 0;
  int? _pendingBadgeCount;
  bool _badgeSyncInProgress = false;
  bool _unreadRefreshInProgress = false;
  bool _unreadRefreshPending = false;
  bool _started = false;
  bool _disposed = false;

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  String? get activeConversationUserId => _activeConversationUserId;

  int get totalUnreadCount {
    return _unreadCountByUserId.values.fold<int>(
      0,
      (int total, int count) => total + count,
    );
  }

  int unreadCountFor(String userId) {
    return _unreadCountByUserId[userId] ?? 0;
  }

  int unreadCountExcluding(String userId) {
    return _unreadCountByUserId.entries.fold<int>(0, (
      int total,
      MapEntry<String, int> entry,
    ) {
      return entry.key == userId ? total : total + entry.value;
    });
  }

  void start() {
    if (_started || _disposed) {
      return;
    }

    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(refreshUnreadCounts());
    _connectWebSocket();
  }

  Future<void> setActiveConversationUserId(String userId) async {
    if (_disposed || userId.isEmpty) {
      return;
    }

    _activeConversationUserId = userId;
    _setUnreadCount(userId, 0);

    try {
      await _notificationService.setActiveChatSenderId(userId);
    } catch (_) {
      // A later conversation transition will retry the native state update.
    }

    await markConversationAsRead(userId);
  }

  Future<void> clearActiveConversationUserId(String userId) async {
    if (_disposed || _activeConversationUserId != userId) {
      return;
    }

    _activeConversationUserId = null;

    try {
      await _notificationService.clearActiveChatSenderId(userId);
    } catch (_) {
      // Native active-chat suppression also ends when the app leaves foreground.
    }

    await refreshUnreadCounts();
  }

  Future<void> markConversationAsRead(String userId) async {
    if (_disposed || userId.isEmpty) {
      return;
    }

    _setUnreadCount(userId, 0);

    if (!_markReadInFlight.add(userId)) {
      _markReadPending.add(userId);
      return;
    }

    bool failed = false;

    try {
      do {
        _markReadPending.remove(userId);
        failed = false;

        try {
          await _chatApi.markConversationAsRead(otherUserId: userId);
        } catch (_) {
          failed = true;
        }
      } while (!_disposed && _markReadPending.remove(userId));
    } finally {
      _markReadInFlight.remove(userId);
    }

    if (failed && _activeConversationUserId != userId) {
      unawaited(refreshUnreadCounts());
    }
  }

  Future<void> refreshUnreadCounts() async {
    if (_disposed) {
      return;
    }

    if (_unreadRefreshInProgress) {
      _unreadRefreshPending = true;
      return;
    }

    _unreadRefreshInProgress = true;

    try {
      do {
        _unreadRefreshPending = false;
        final int revisionAtStart = _unreadMutationRevision;

        try {
          final Map<String, int> counts = await _chatApi
              .listUnreadMessageCounts();

          if (_disposed) {
            return;
          }

          if (revisionAtStart != _unreadMutationRevision) {
            _unreadRefreshPending = true;
            continue;
          }

          final Map<String, int> nextCounts = <String, int>{...counts};
          final String? activeUserId = _activeConversationUserId;

          if (activeUserId != null && _isForeground) {
            nextCounts[activeUserId] = 0;
          }

          _replaceUnreadCounts(nextCounts);
        } catch (_) {
          // Keep the real-time snapshot during transient REST failures.
        }
      } while (_unreadRefreshPending && !_disposed);
    } finally {
      _unreadRefreshInProgress = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;

    if (state != AppLifecycleState.resumed || _disposed) {
      return;
    }

    _restartWebSocket();
    unawaited(refreshUnreadCounts());

    final String? activeUserId = _activeConversationUserId;
    if (activeUserId != null) {
      unawaited(markConversationAsRead(activeUserId));
    }
  }

  bool get _isForeground => _lifecycleState == AppLifecycleState.resumed;

  void _connectWebSocket() {
    if (!_started || _disposed || _webSocketChannel != null) {
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final WebSocketChannel channel = IOWebSocketChannel.connect(
      _webSocketUri(),
      headers: <String, String>{
        'Authorization': 'Bearer ${_session.accessToken}',
      },
    );

    _webSocketChannel = channel;
    _webSocketSubscription = channel.stream.listen(
      (dynamic data) {
        _handleWebSocketData(channel, data);
      },
      onError: (_) {
        _handleWebSocketDisconnected(channel);
      },
      onDone: () {
        _handleWebSocketDisconnected(channel);
      },
    );
  }

  void _restartWebSocket() {
    final StreamSubscription<dynamic>? subscription = _webSocketSubscription;
    final WebSocketChannel? channel = _webSocketChannel;

    _pingTimer?.cancel();
    _pingTimer = null;
    _webSocketSubscription = null;
    _webSocketChannel = null;

    unawaited(subscription?.cancel());
    unawaited(channel?.sink.close());
    _connectWebSocket();
  }

  Uri _webSocketUri() {
    final String scheme = _baseUri.scheme == 'https' ? 'wss' : 'ws';

    return Uri(
      scheme: scheme,
      userInfo: _baseUri.userInfo,
      host: _baseUri.host,
      port: _baseUri.hasPort ? _baseUri.port : null,
      path: '/ws',
    );
  }

  void _handleWebSocketData(WebSocketChannel channel, dynamic data) {
    if (_disposed || !identical(_webSocketChannel, channel)) {
      return;
    }

    final Object? decodedData;

    try {
      if (data is String) {
        decodedData = jsonDecode(data);
      } else if (data is List<int>) {
        decodedData = jsonDecode(utf8.decode(data));
      } else {
        return;
      }
    } on FormatException {
      return;
    }

    if (decodedData is! Map) {
      return;
    }

    final Map<String, dynamic> event = Map<String, dynamic>.from(decodedData);
    final bool hasAuthoritativeUnreadCounts = _applyUnreadCountsSnapshot(
      event['unread_counts'],
    );
    bool shouldPublishEvent = true;

    switch (event['type']) {
      case 'connected':
        _startPingTimer();
        unawaited(refreshUnreadCounts());
        break;
      case 'pong':
        break;
      case 'message.created':
        if (_rememberMessageCreated(event)) {
          _handleMessageCreated(
            event,
            hasAuthoritativeUnreadCounts: hasAuthoritativeUnreadCounts,
          );
        } else {
          shouldPublishEvent = false;
        }
        break;
      case 'message.deleted':
        if (!hasAuthoritativeUnreadCounts) {
          unawaited(refreshUnreadCounts());
        }
        break;
      case 'messages.read':
        _handleMessagesRead(event);
        break;
    }

    if (shouldPublishEvent && !_eventController.isClosed) {
      _eventController.add(Map<String, dynamic>.unmodifiable(event));
    }
  }

  bool _applyUnreadCountsSnapshot(Object? rawSnapshot) {
    final UnreadCountsSnapshot? snapshot = UnreadCountsSnapshot.tryParse(
      rawSnapshot,
    );

    if (snapshot == null || snapshot.userId != _session.user.id) {
      return false;
    }

    if (_unreadSnapshotStreamId == snapshot.streamId &&
        snapshot.sequence <= _lastUnreadSnapshotSequence) {
      return true;
    }

    _unreadSnapshotStreamId = snapshot.streamId;
    _lastUnreadSnapshotSequence = snapshot.sequence;

    final Map<String, int> nextCounts = <String, int>{
      ...snapshot.countsBySenderId,
    };
    final String? activeUserId = _activeConversationUserId;

    if (activeUserId != null && _isForeground) {
      nextCounts[activeUserId] = 0;
    }

    _replaceUnreadCounts(nextCounts);
    return true;
  }

  bool _rememberMessageCreated(Map<String, dynamic> event) {
    final Object? rawMessage = event['message'];
    if (rawMessage is! Map) {
      return true;
    }

    final Object? rawMessageId = rawMessage['id'];
    if (rawMessageId is! String || rawMessageId.isEmpty) {
      return true;
    }

    return _processedMessageIds.addIfAbsent(rawMessageId);
  }

  void _handleMessageCreated(
    Map<String, dynamic> event, {
    required bool hasAuthoritativeUnreadCounts,
  }) {
    final Object? rawMessage = event['message'];
    if (rawMessage is! Map) {
      return;
    }

    final Object? rawSenderId = rawMessage['sender_id'];
    if (rawSenderId is! String || rawSenderId == _session.user.id) {
      return;
    }

    if (rawSenderId == _activeConversationUserId && _isForeground) {
      _setUnreadCount(rawSenderId, 0);
      unawaited(markConversationAsRead(rawSenderId));
      return;
    }

    if (!hasAuthoritativeUnreadCounts) {
      unawaited(refreshUnreadCounts());
    }
  }

  void _handleMessagesRead(Map<String, dynamic> event) {
    final Object? readerId = event['reader_id'];
    final Object? senderId = event['sender_id'];

    if (readerId == _session.user.id && senderId is String) {
      _setUnreadCount(senderId, 0);
    }
  }

  void _setUnreadCount(String userId, int count) {
    final int normalizedCount = count < 0 ? 0 : count;
    final int currentCount = unreadCountFor(userId);

    if (currentCount == normalizedCount &&
        _unreadCountByUserId.containsKey(userId)) {
      _scheduleBadgeSync();
      return;
    }

    _unreadMutationRevision += 1;
    _unreadCountByUserId = Map<String, int>.unmodifiable(<String, int>{
      ..._unreadCountByUserId,
      userId: normalizedCount,
    });
    notifyListeners();
    _scheduleBadgeSync();
  }

  void _replaceUnreadCounts(Map<String, int> counts) {
    final Map<String, int> nextCounts = Map<String, int>.unmodifiable(counts);

    if (!_mapsEqual(_unreadCountByUserId, nextCounts)) {
      _unreadMutationRevision += 1;
      _unreadCountByUserId = nextCounts;
      notifyListeners();
    }

    _scheduleBadgeSync();
  }

  bool _mapsEqual(Map<String, int> first, Map<String, int> second) {
    if (first.length != second.length) {
      return false;
    }

    for (final MapEntry<String, int> entry in first.entries) {
      if (second[entry.key] != entry.value) {
        return false;
      }
    }

    return true;
  }

  void _scheduleBadgeSync() {
    if (_disposed) {
      return;
    }

    _pendingBadgeCount = totalUnreadCount;
    if (_badgeSyncInProgress) {
      return;
    }

    _badgeSyncInProgress = true;
    unawaited(_drainBadgeSync());
  }

  Future<void> _drainBadgeSync() async {
    try {
      while (!_disposed && _pendingBadgeCount != null) {
        final int count = _pendingBadgeCount!;
        _pendingBadgeCount = null;

        try {
          await _notificationService.setBadgeCount(count);
        } catch (_) {
          // The next unread mutation or foreground refresh will retry.
        }
      }
    } finally {
      _badgeSyncInProgress = false;

      if (!_disposed && _pendingBadgeCount != null) {
        _scheduleBadgeSync();
      }
    }
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      final WebSocketChannel? channel = _webSocketChannel;
      if (channel == null) {
        return;
      }

      try {
        channel.sink.add(jsonEncode(<String, String>{'type': 'ping'}));
      } catch (_) {
        _handleWebSocketDisconnected(channel);
      }
    });
  }

  void _handleWebSocketDisconnected(WebSocketChannel channel) {
    if (!identical(_webSocketChannel, channel)) {
      return;
    }

    _pingTimer?.cancel();
    _pingTimer = null;
    _webSocketSubscription = null;
    _webSocketChannel = null;

    if (_disposed || _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectTimer = Timer(_reconnectDelay, () {
      _reconnectTimer = null;
      _connectWebSocket();
    });
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }

    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    unawaited(_webSocketSubscription?.cancel());
    unawaited(_webSocketChannel?.sink.close());
    unawaited(_eventController.close());
    super.dispose();
  }
}
