import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../design_system/app_colors.dart';
import '../../../design_system/app_typography.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/domain/auth_session.dart';
import '../data/chat_api.dart';
import '../data/chat_api_exception.dart';
import '../domain/chat_message.dart';
import 'chat_conversation_view.dart';

const double _chatListHorizontalPadding = 20;
const double _chatListAvatarSize = 48;
const double _chatListTitleGap = 16;
const double _chatListTextStartInset =
    _chatListHorizontalPadding + _chatListAvatarSize + _chatListTitleGap;

final class ChatConversationHomeScreen extends StatefulWidget {
  const ChatConversationHomeScreen({
    required this.client,
    required this.baseUri,
    required this.session,
    super.key,
  });

  final http.Client client;
  final Uri baseUri;
  final AuthSession session;

  @override
  State<ChatConversationHomeScreen> createState() {
    return _ChatConversationHomeScreenState();
  }
}

final class _ChatConversationHomeScreenState
    extends State<ChatConversationHomeScreen> {
  static const Map<String, List<String>> _chatOrderByUsername =
      <String, List<String>>{
        'liababo': <String>['junebabo', 'yunjung5437'],
        'junebabo': <String>['liababo', 'yunjung5437'],
        'yunjung5437': <String>['junebabo', 'liababo'],
      };
  static const Map<String, Map<String, String>> _displayNameByViewerUsername =
      <String, Map<String, String>>{
        'liababo': <String, String>{'junebabo': '애기🤍', 'yunjung5437': '엄마'},
        'junebabo': <String, String>{'liababo': '오빠💙', 'yunjung5437': '阿姨'},
        'yunjung5437': <String, String>{'junebabo': '리아', 'liababo': '준'},
      };

  late final ChatApi _chatApi;
  final Map<String, List<ChatMessage>> _conversationMessagesByUserId =
      <String, List<ChatMessage>>{};
  final Set<String> _prefetchingConversationUserIds = <String>{};

  List<_ChatListEntry>? _chatEntries;
  AppUser? _selectedUser;
  bool _chatEntriesLoading = true;
  bool _chatEntriesRefreshing = false;
  String? _chatEntriesErrorMessage;

  @override
  void initState() {
    super.initState();

    _chatApi = ChatApi(
      client: widget.client,
      baseUri: widget.baseUri,
      accessToken: widget.session.accessToken,
    );

    unawaited(_loadChatEntries(showInitialLoading: true));
  }

  Future<void> _loadChatEntries({required bool showInitialLoading}) async {
    if (_chatEntriesRefreshing) {
      return;
    }

    _chatEntriesRefreshing = true;

    if (showInitialLoading && _chatEntries == null) {
      setState(() {
        _chatEntriesLoading = true;
        _chatEntriesErrorMessage = null;
      });
    }

    try {
      final List<AppUser> users = await _chatApi.listUsers();

      final List<AppUser> chatUsers = users
          .where((AppUser user) => user.id != widget.session.user.id)
          .toList(growable: false);

      _sortChatUsers(chatUsers);
      _prefetchConversations(chatUsers);

      final List<_ChatListEntry> entries = await Future.wait(
        chatUsers.map((AppUser user) async {
          return _ChatListEntry(
            user: user,
            unreadCount: await _loadUnreadCountFor(user),
          );
        }),
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _chatEntries = List<_ChatListEntry>.unmodifiable(entries);
        _chatEntriesLoading = false;
        _chatEntriesErrorMessage = null;
      });

      _precacheProfileImages(entries);
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _chatEntriesLoading = false;
        _chatEntriesErrorMessage = 'Chat user loading failed.';
      });
    } finally {
      _chatEntriesRefreshing = false;
    }
  }

  Future<int> _loadUnreadCountFor(AppUser user) async {
    try {
      return await _chatApi.countUnreadMessages(fromUserId: user.id);
    } on ChatApiException {
      return 0;
    }
  }

  void _sortChatUsers(List<AppUser> users) {
    final List<String>? chatOrder =
        _chatOrderByUsername[_normalizeUserKey(widget.session.user.username)];

    if (chatOrder == null) {
      return;
    }

    final Map<String, int> priorityByName = <String, int>{
      for (int index = 0; index < chatOrder.length; index++)
        chatOrder[index]: index,
    };

    users.sort((AppUser first, AppUser second) {
      final int firstPriority =
          priorityByName[_normalizeUserKey(first.username)] ??
          priorityByName[_normalizeUserKey(first.displayName)] ??
          chatOrder.length;
      final int secondPriority =
          priorityByName[_normalizeUserKey(second.username)] ??
          priorityByName[_normalizeUserKey(second.displayName)] ??
          chatOrder.length;

      final int priorityComparison = firstPriority.compareTo(secondPriority);

      if (priorityComparison != 0) {
        return priorityComparison;
      }

      return _normalizeUserKey(
        first.displayName,
      ).compareTo(_normalizeUserKey(second.displayName));
    });
  }

  void _precacheProfileImages(List<_ChatListEntry> entries) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      for (final _ChatListEntry entry in entries) {
        final String? imageUrl = entry.user.profileImageUrl?.trim();

        if (imageUrl == null || imageUrl.isEmpty) {
          continue;
        }

        unawaited(
          precacheImage(
            NetworkImage(imageUrl),
            context,
          ).catchError((Object _) {}),
        );
      }
    });
  }

  void _prefetchConversations(List<AppUser> users) {
    for (final AppUser user in users) {
      final String userId = user.id;

      if (_conversationMessagesByUserId.containsKey(userId) ||
          !_prefetchingConversationUserIds.add(userId)) {
        continue;
      }

      unawaited(_prefetchConversation(userId));
    }
  }

  Future<void> _prefetchConversation(String userId) async {
    try {
      final List<ChatMessage> messages = await _chatApi.listConversation(
        otherUserId: userId,
      );

      if (!mounted) {
        return;
      }

      _conversationMessagesByUserId[userId] = List<ChatMessage>.unmodifiable(
        messages,
      );
    } catch (_) {
      // Prefetching should never block the chat list.
    } finally {
      _prefetchingConversationUserIds.remove(userId);
    }
  }

  String _normalizeUserKey(String value) {
    return value.trim().toLowerCase();
  }

  String _displayNameFor(AppUser user) {
    return _displayNameByViewerUsername[_normalizeUserKey(
          widget.session.user.username,
        )]?[_normalizeUserKey(user.username)] ??
        user.displayName;
  }

  void _retryUsers() {
    unawaited(_loadChatEntries(showInitialLoading: true));
  }

  void _cacheConversationMessages({
    required String userId,
    required List<ChatMessage> messages,
  }) {
    _conversationMessagesByUserId[userId] = List<ChatMessage>.unmodifiable(
      messages,
    );
  }

  void _clearUnreadCountFor(String userId) {
    final List<_ChatListEntry>? entries = _chatEntries;

    if (entries == null) {
      return;
    }

    _chatEntries = List<_ChatListEntry>.unmodifiable(
      entries.map((_ChatListEntry entry) {
        if (entry.user.id != userId || entry.unreadCount == 0) {
          return entry;
        }

        return entry.copyWith(unreadCount: 0);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppUser? selectedUser = _selectedUser;

    if (selectedUser != null) {
      return ChatConversationScreen(
        key: ValueKey<String>(selectedUser.id),
        chatApi: _chatApi,
        baseUri: widget.baseUri,
        accessToken: widget.session.accessToken,
        currentUser: widget.session.user,
        otherUser: selectedUser,
        otherUserDisplayName: _displayNameFor(selectedUser),
        initialMessages: _conversationMessagesByUserId[selectedUser.id],
        onMessagesChanged: (List<ChatMessage> messages) {
          _cacheConversationMessages(
            userId: selectedUser.id,
            messages: messages,
          );
        },
        onBack: () {
          setState(() {
            _clearUnreadCountFor(selectedUser.id);
            _selectedUser = null;
          });
          unawaited(_loadChatEntries(showInitialLoading: false));
        },
      );
    }

    if (_chatEntriesLoading && _chatEntries == null) {
      return const Scaffold(
        backgroundColor: AppColors.surface,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.blue500),
        ),
      );
    }

    final String? chatEntriesErrorMessage = _chatEntriesErrorMessage;

    if (chatEntriesErrorMessage != null && _chatEntries == null) {
      return Scaffold(
        backgroundColor: AppColors.surface,
        body: _ChatLoadingError(
          message: chatEntriesErrorMessage,
          onRetry: _retryUsers,
        ),
      );
    }

    final List<_ChatListEntry> entries =
        _chatEntries ?? const <_ChatListEntry>[];

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        titleSpacing: _chatListHorizontalPadding,
        title: Text(
          'Chats',
          style: AppTypography.typography5.copyWith(
            color: AppColors.grey900,
            fontWeight: AppTypography.bold,
          ),
        ),
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                'No chat users yet.',
                style: AppTypography.typography7.copyWith(
                  color: AppColors.grey600,
                  fontWeight: AppTypography.medium,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: entries.length,
              separatorBuilder: (BuildContext context, int index) {
                return const Divider(
                  height: 1,
                  indent: _chatListTextStartInset,
                  color: AppColors.grey100,
                );
              },
              itemBuilder: (BuildContext context, int index) {
                final _ChatListEntry entry = entries[index];
                final AppUser user = entry.user;

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: _chatListHorizontalPadding,
                    vertical: 6,
                  ),
                  horizontalTitleGap: _chatListTitleGap,
                  minLeadingWidth: _chatListAvatarSize,
                  leading: _ChatUserAvatar(
                    imageUrl: user.profileImageUrl,
                    unreadCount: entry.unreadCount,
                  ),
                  title: Text(
                    _displayNameFor(user),
                    style: AppTypography.typography6.copyWith(
                      color: AppColors.grey900,
                      fontWeight: AppTypography.bold,
                    ),
                  ),
                  subtitle: Text(
                    '@${user.username}',
                    style: AppTypography.subTypography12.copyWith(
                      color: AppColors.grey500,
                      fontWeight: AppTypography.regular,
                    ),
                  ),
                  onTap: () {
                    setState(() {
                      _selectedUser = user;
                    });
                  },
                );
              },
            ),
    );
  }
}

final class _ChatListEntry {
  const _ChatListEntry({required this.user, required this.unreadCount});

  final AppUser user;
  final int unreadCount;

  _ChatListEntry copyWith({int? unreadCount}) {
    return _ChatListEntry(
      user: user,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

final class ChatConversationScreen extends StatefulWidget {
  const ChatConversationScreen({
    required this.chatApi,
    required this.baseUri,
    required this.accessToken,
    required this.currentUser,
    required this.otherUser,
    required this.otherUserDisplayName,
    required this.onBack,
    this.initialMessages,
    this.onMessagesChanged,
    super.key,
  });

  final ChatApi chatApi;
  final Uri baseUri;
  final String accessToken;
  final AppUser currentUser;
  final AppUser otherUser;
  final String otherUserDisplayName;
  final VoidCallback onBack;
  final List<ChatMessage>? initialMessages;
  final ValueChanged<List<ChatMessage>>? onMessagesChanged;

  @override
  State<ChatConversationScreen> createState() {
    return _ChatConversationScreenState();
  }
}

final class _ChatConversationScreenState extends State<ChatConversationScreen>
    with WidgetsBindingObserver {
  static const Duration _reconnectDelay = Duration(seconds: 2);
  static const Duration _pingInterval = Duration(seconds: 25);

  WebSocketChannel? _webSocketChannel;
  StreamSubscription<dynamic>? _webSocketSubscription;
  Timer? _reconnectTimer;
  Timer? _pingTimer;

  late bool _loading;
  String? _errorMessage;
  bool _disposed = false;
  bool _connectedOnce = false;
  bool _syncingAfterReconnect = false;
  int _unreadOutsideCurrentConversationCount = 0;
  late List<ChatMessage> _messages;

  @override
  void initState() {
    super.initState();

    final List<ChatMessage>? initialMessages = widget.initialMessages;

    _messages = initialMessages == null
        ? const <ChatMessage>[]
        : List<ChatMessage>.unmodifiable(initialMessages);
    _loading = initialMessages == null;

    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadConversation(showLoading: initialMessages == null));
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    unawaited(_webSocketSubscription?.cancel());
    unawaited(_webSocketChannel?.sink.close());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _connectWebSocket();
      unawaited(_syncConversationFromRest());
    }
  }

  Future<void> _loadConversation({required bool showLoading}) async {
    if (showLoading) {
      setState(() {
        _loading = true;
        _errorMessage = null;
      });
    }

    try {
      final List<ChatMessage> messages = await widget.chatApi.listConversation(
        otherUserId: widget.otherUser.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _messages = List<ChatMessage>.unmodifiable(messages);
        _loading = false;
        _errorMessage = null;
      });
      _notifyMessagesChanged();

      _connectWebSocket();
      unawaited(_markCurrentConversationReadAndRefreshUnreadCount());
    } catch (_) {
      if (!mounted) {
        return;
      }

      if (_messages.isNotEmpty) {
        setState(() {
          _loading = false;
        });
        return;
      }

      setState(() {
        _errorMessage = 'Conversation loading failed.';
        _loading = false;
      });
    }
  }

  Future<void> _syncConversationFromRest() async {
    if (_loading || _syncingAfterReconnect) {
      return;
    }

    _syncingAfterReconnect = true;

    try {
      final List<ChatMessage> messages = await widget.chatApi.listConversation(
        otherUserId: widget.otherUser.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _messages = List<ChatMessage>.unmodifiable(messages);
        _errorMessage = null;
      });
      _notifyMessagesChanged();
      unawaited(_markCurrentConversationReadAndRefreshUnreadCount());
    } catch (_) {
      // Keep the current conversation visible during transient sync errors.
    } finally {
      _syncingAfterReconnect = false;
    }
  }

  Future<void> _markCurrentConversationReadAndRefreshUnreadCount() async {
    try {
      await widget.chatApi.markConversationAsRead(
        otherUserId: widget.otherUser.id,
      );
    } catch (_) {
      // The next reconnect/sync will try again.
    }

    await _refreshUnreadOutsideCurrentConversationCount();
  }

  void _connectWebSocket() {
    if (_disposed || _webSocketChannel != null) {
      return;
    }

    _reconnectTimer?.cancel();

    final WebSocketChannel channel = IOWebSocketChannel.connect(
      _webSocketUri(),
      headers: <String, String>{
        'Authorization': 'Bearer ${widget.accessToken}',
      },
    );

    _webSocketChannel = channel;
    _webSocketSubscription = channel.stream.listen(
      _handleWebSocketData,
      onError: (_) {
        _handleWebSocketDisconnected();
      },
      onDone: _handleWebSocketDisconnected,
    );
  }

  Uri _webSocketUri() {
    final String scheme = widget.baseUri.scheme == 'https' ? 'wss' : 'ws';
    final Uri baseUri = widget.baseUri;

    return Uri(
      scheme: scheme,
      userInfo: baseUri.userInfo,
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : null,
      path: '/ws',
    );
  }

  void _handleWebSocketData(dynamic data) {
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

    if (decodedData is! Map<String, dynamic>) {
      return;
    }

    final Object? eventType = decodedData['type'];

    if (eventType is! String) {
      return;
    }

    switch (eventType) {
      case 'connected':
        _handleWebSocketConnected();
        return;
      case 'pong':
        return;
      case 'message.created':
      case 'message.updated':
      case 'message.translation.updated':
        _handleMessageEvent(decodedData);
        return;
      case 'message.deleted':
        _handleMessageDeletedEvent(decodedData);
        return;
      case 'messages.read':
        _handleMessagesReadEvent(decodedData);
        return;
      case 'error':
        return;
    }
  }

  void _handleWebSocketConnected() {
    final bool wasReconnect = _connectedOnce;

    _connectedOnce = true;
    _startPingTimer();

    if (wasReconnect) {
      unawaited(_syncConversationFromRest());
    }
  }

  void _handleMessageEvent(Map<String, dynamic> event) {
    final Object? messageJson = event['message'];

    if (messageJson is! Map<String, dynamic>) {
      return;
    }

    final ChatMessage message;

    try {
      message = widget.chatApi.messageFromJson(messageJson);
    } catch (_) {
      return;
    }

    if (!_messageBelongsToConversation(message)) {
      if (message.senderId != widget.currentUser.id) {
        unawaited(_refreshUnreadOutsideCurrentConversationCount());
      }

      return;
    }

    _upsertMessage(message);

    if (message.senderId == widget.otherUser.id) {
      unawaited(
        widget.chatApi.markConversationAsRead(otherUserId: widget.otherUser.id),
      );
      unawaited(_refreshUnreadOutsideCurrentConversationCount());
    }
  }

  void _handleMessageDeletedEvent(Map<String, dynamic> event) {
    final Object? messageId = event['message_id'];

    if (messageId is String) {
      _removeMessage(messageId);
    }

    unawaited(_refreshUnreadOutsideCurrentConversationCount());
  }

  void _handleMessagesReadEvent(Map<String, dynamic> event) {
    final Object? senderId = event['sender_id'];
    final Object? readerId = event['reader_id'];
    final Object? messageIds = event['message_ids'];
    final Object? readAtValue = event['read_at'];

    if (senderId != widget.currentUser.id ||
        readerId != widget.otherUser.id ||
        messageIds is! List<dynamic> ||
        readAtValue is! String) {
      return;
    }

    final DateTime readAt;

    try {
      readAt = DateTime.parse(readAtValue);
    } on FormatException {
      return;
    }

    _markMessagesRead(
      messageIds.whereType<String>().toList(growable: false),
      readAt,
    );

    unawaited(_refreshUnreadOutsideCurrentConversationCount());
  }

  Future<int> _loadUnreadOutsideCurrentConversationCount() async {
    try {
      return await widget.chatApi.countUnreadMessages(
        excludeUserId: widget.otherUser.id,
      );
    } catch (_) {
      return _unreadOutsideCurrentConversationCount;
    }
  }

  Future<void> _refreshUnreadOutsideCurrentConversationCount() async {
    final int unreadOutsideCurrentConversationCount =
        await _loadUnreadOutsideCurrentConversationCount();

    if (!mounted) {
      return;
    }

    if (unreadOutsideCurrentConversationCount ==
        _unreadOutsideCurrentConversationCount) {
      return;
    }

    setState(() {
      _unreadOutsideCurrentConversationCount =
          unreadOutsideCurrentConversationCount;
    });
  }

  void _handleWebSocketDisconnected() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _webSocketSubscription = null;
    _webSocketChannel = null;

    if (_disposed) {
      return;
    }

    _reconnectTimer ??= Timer(_reconnectDelay, () {
      _reconnectTimer = null;
      _connectWebSocket();
    });
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
        _handleWebSocketDisconnected();
      }
    });
  }

  bool _messageBelongsToConversation(ChatMessage message) {
    return (message.senderId == widget.currentUser.id &&
            message.recipientId == widget.otherUser.id) ||
        (message.senderId == widget.otherUser.id &&
            message.recipientId == widget.currentUser.id);
  }

  void _upsertMessage(ChatMessage message) {
    final List<ChatMessage> nextMessages = List<ChatMessage>.of(_messages);
    final int existingIndex = nextMessages.indexWhere(
      (ChatMessage existingMessage) => existingMessage.id == message.id,
    );

    if (existingIndex == -1) {
      nextMessages.add(message);
    } else {
      nextMessages[existingIndex] = message;
    }

    nextMessages.sort(_compareMessages);

    setState(() {
      _messages = List<ChatMessage>.unmodifiable(nextMessages);
    });
    _notifyMessagesChanged();
  }

  void _upsertMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return;
    }

    final List<ChatMessage> nextMessages = List<ChatMessage>.of(_messages);

    for (final ChatMessage message in messages) {
      final int existingIndex = nextMessages.indexWhere(
        (ChatMessage existingMessage) => existingMessage.id == message.id,
      );

      if (existingIndex == -1) {
        nextMessages.add(message);
      } else {
        nextMessages[existingIndex] = message;
      }
    }

    nextMessages.sort(_compareMessages);

    setState(() {
      _messages = List<ChatMessage>.unmodifiable(nextMessages);
    });
    _notifyMessagesChanged();
  }

  void _removeMessage(String messageId) {
    setState(() {
      _messages = List<ChatMessage>.unmodifiable(
        _messages.where((ChatMessage message) => message.id != messageId),
      );
    });
    _notifyMessagesChanged();
  }

  void _markMessagesRead(List<String> messageIds, DateTime readAt) {
    if (messageIds.isEmpty) {
      return;
    }

    final Set<String> messageIdSet = messageIds.toSet();

    setState(() {
      _messages = List<ChatMessage>.unmodifiable(
        _messages.map((ChatMessage message) {
          if (!messageIdSet.contains(message.id)) {
            return message;
          }

          return message.copyWith(readAt: readAt);
        }),
      );
    });
    _notifyMessagesChanged();
  }

  void _notifyMessagesChanged() {
    widget.onMessagesChanged?.call(_messages);
  }

  int _compareMessages(ChatMessage first, ChatMessage second) {
    final int createdAtComparison = first.createdAt.compareTo(second.createdAt);

    if (createdAtComparison != 0) {
      return createdAtComparison;
    }

    return first.id.compareTo(second.id);
  }

  Future<ChatMessage> _sendTextMessage({
    required String content,
    ChatReplyReference? replyTo,
  }) async {
    final ChatMessage message = await widget.chatApi.sendTextMessage(
      recipientId: widget.otherUser.id,
      content: content,
      replyToMessageId: replyTo?.messageId,
    );

    if (mounted) {
      _upsertMessage(message);
    }

    return message;
  }

  Future<List<ChatMessage>> _sendPhotoMessages({
    required List<ChatPhotoAttachment> attachments,
    required bool collage,
    ChatReplyReference? replyTo,
  }) async {
    final List<ChatMessage> messages;

    if (collage) {
      messages = <ChatMessage>[
        await widget.chatApi.sendPhotoMessage(
          recipientId: widget.otherUser.id,
          photos: attachments,
          replyToMessageId: replyTo?.messageId,
        ),
      ];
    } else {
      messages = await Future.wait(
        attachments.map((ChatPhotoAttachment attachment) {
          return widget.chatApi.sendPhotoMessage(
            recipientId: widget.otherUser.id,
            photos: <ChatPhotoAttachment>[attachment],
            replyToMessageId: replyTo?.messageId,
          );
        }),
      );
    }

    if (mounted) {
      _upsertMessages(messages);
    }

    return messages;
  }

  Future<ChatMessage> _sendFileMessage({
    required ChatFileAttachment file,
    ChatReplyReference? replyTo,
  }) async {
    final ChatMessage message = await widget.chatApi.sendFileMessage(
      recipientId: widget.otherUser.id,
      file: file,
      replyToMessageId: replyTo?.messageId,
    );

    if (mounted) {
      _upsertMessage(message);
    }

    return message;
  }

  Future<ChatMessage> _sendVoiceMemoMessage({
    required ChatVoiceMemoAttachment voiceMemo,
    ChatReplyReference? replyTo,
  }) async {
    final ChatMessage message = await widget.chatApi.sendVoiceMemoMessage(
      recipientId: widget.otherUser.id,
      voiceMemo: voiceMemo,
      replyToMessageId: replyTo?.messageId,
    );

    if (mounted) {
      _upsertMessage(message);
    }

    return message;
  }

  Future<ChatMessage> _sendCallMessage({
    required ChatCallAttachment call,
  }) async {
    final ChatMessage message = await widget.chatApi.sendCallMessage(
      recipientId: widget.otherUser.id,
      call: call,
    );

    if (mounted) {
      _upsertMessage(message);
    }

    return message;
  }

  Future<ChatMessage> _editTextMessage({
    required String messageId,
    required String content,
  }) async {
    final ChatMessage message = await widget.chatApi.editTextMessage(
      messageId: messageId,
      content: content,
    );

    if (mounted) {
      _upsertMessage(message);
    }

    return message;
  }

  Future<ChatMessage> _retryTextMessageTranslation({
    required String messageId,
  }) async {
    final ChatMessage message = await widget.chatApi.retryMessageTranslation(
      messageId: messageId,
    );

    if (mounted) {
      _upsertMessage(message);
    }

    return message;
  }

  Future<void> _deleteMessage({required String messageId}) async {
    await widget.chatApi.deleteMessage(messageId: messageId);

    if (mounted) {
      _removeMessage(messageId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.surface,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.blue500),
        ),
      );
    }

    final String? errorMessage = _errorMessage;

    if (errorMessage != null) {
      return Scaffold(
        backgroundColor: AppColors.surface,
        body: _ChatLoadingError(
          message: errorMessage,
          onRetry: () {
            unawaited(_loadConversation(showLoading: true));
          },
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          widget.onBack();
        }
      },
      child: ChatConversationView(
        initialMessages: _messages,
        currentUserId: widget.currentUser.id,
        currentUserName: widget.currentUser.displayName,
        currentUserPreferredLanguage: widget.currentUser.preferredLanguage,
        otherParticipantId: widget.otherUser.id,
        otherParticipantName: widget.otherUserDisplayName,
        otherParticipantProfileImageUrl: widget.otherUser.profileImageUrl,
        onSendTextMessage: _sendTextMessage,
        onSendPhotoMessages: _sendPhotoMessages,
        onSendFileMessage: _sendFileMessage,
        onSendVoiceMemoMessage: _sendVoiceMemoMessage,
        onSendCallMessage: _sendCallMessage,
        onCreateMediaAssetAccessUrl: widget.chatApi.createMediaAssetAccessUrl,
        onEditTextMessage: _editTextMessage,
        onRetryTranslation: _retryTextMessageTranslation,
        onDeleteMessage: _deleteMessage,
        onBack: widget.onBack,
        unreadOtherConversationCount: _unreadOutsideCurrentConversationCount,
      ),
    );
  }
}

final class _ChatUserAvatar extends StatelessWidget {
  const _ChatUserAvatar({required this.imageUrl, required this.unreadCount});

  final String? imageUrl;
  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: _chatListAvatarSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _ProfileImageBox(
              imageUrl: imageUrl,
              borderRadius: 16,
              iconSize: 30,
            ),
          ),
          if (unreadCount > 0)
            Positioned(
              top: -4,
              right: -4,
              child: _ChatUnreadBadge(count: unreadCount),
            ),
        ],
      ),
    );
  }
}

final class _ChatUnreadBadge extends StatelessWidget {
  const _ChatUnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final String label = count > 99 ? '99+' : count.toString();

    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.red500,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTypography.subTypography12.copyWith(
          color: AppColors.white,
          fontWeight: AppTypography.bold,
          height: 1,
          fontSize: 11,
        ),
      ),
    );
  }
}

final class _ProfileImageBox extends StatelessWidget {
  const _ProfileImageBox({
    required this.imageUrl,
    required this.borderRadius,
    required this.iconSize,
  });

  final String? imageUrl;
  final double borderRadius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final String? resolvedImageUrl = imageUrl?.trim();
    final BorderRadius resolvedBorderRadius = BorderRadius.circular(
      borderRadius,
    );

    if (resolvedImageUrl != null && resolvedImageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: resolvedBorderRadius,
        child: Image.network(
          resolvedImageUrl,
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) {
                return _DefaultProfileIcon(
                  borderRadius: resolvedBorderRadius,
                  iconSize: iconSize,
                );
              },
        ),
      );
    }

    return _DefaultProfileIcon(
      borderRadius: resolvedBorderRadius,
      iconSize: iconSize,
    );
  }
}

final class _DefaultProfileIcon extends StatelessWidget {
  const _DefaultProfileIcon({
    required this.borderRadius,
    required this.iconSize,
  });

  final BorderRadius borderRadius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.blue100,
        borderRadius: borderRadius,
      ),
      child: Icon(Icons.person_rounded, color: AppColors.white, size: iconSize),
    );
  }
}

final class _ChatLoadingError extends StatelessWidget {
  const _ChatLoadingError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.typography7.copyWith(
                color: AppColors.grey700,
                fontWeight: AppTypography.medium,
              ),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Retry',
                style: AppTypography.typography7.copyWith(
                  color: AppColors.blue500,
                  fontWeight: AppTypography.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
