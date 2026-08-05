import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../design_system/app_colors.dart';
import '../../../design_system/app_typography.dart';
import '../../../design_system/components/app_profile_image.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/domain/auth_session.dart';
import '../data/chat_api.dart';
import '../data/chat_api_exception.dart';
import '../data/chat_message_cache.dart';
import '../data/chat_realtime_service.dart';
import '../domain/chat_message.dart';
import 'chat_conversation_view.dart';
import 'reply_navigation_diagnostics.dart';

const double _chatListHorizontalPadding = 20;
const double _chatListAvatarSize = 48;
const double _chatListTitleGap = 16;
const double _chatListTextStartInset =
    _chatListHorizontalPadding + _chatListAvatarSize + _chatListTitleGap;
const Duration _chatRouteOpenDuration = Duration(milliseconds: 190);
const Duration _chatRouteCloseDuration = Duration(milliseconds: 170);
const double _chatRouteDismissProgress = 0.5;
const double _chatRouteFlingVelocity = 700;
const double _chatRouteDragSlop = 8;
const int _conversationEntryCacheMessageLimit = 100;

final class ChatConversationHomeController extends ChangeNotifier {
  String? _pendingUserId;

  String? get pendingUserId => _pendingUserId;

  void openConversation(String userId) {
    if (userId.isEmpty || _pendingUserId == userId) {
      return;
    }

    _pendingUserId = userId;
    notifyListeners();
  }

  void consume(String userId) {
    if (_pendingUserId == userId) {
      _pendingUserId = null;
    }
  }
}

final class ChatConversationHomeScreen extends StatefulWidget {
  const ChatConversationHomeScreen({
    required this.chatApi,
    required this.realtimeService,
    required this.session,
    required this.controller,
    this.messageCache,
    super.key,
  });

  final ChatApi chatApi;
  final ChatRealtimeService realtimeService;
  final AuthSession session;
  final ChatConversationHomeController controller;
  final ChatMessageCache? messageCache;

  @override
  State<ChatConversationHomeScreen> createState() {
    return _ChatConversationHomeScreenState();
  }
}

final class _ChatConversationHomeScreenState
    extends State<ChatConversationHomeScreen>
    with SingleTickerProviderStateMixin {
  static const Map<String, List<String>> _chatOrderByUsername =
      <String, List<String>>{
        'liababo': <String>['junebabo', 'yunjung5437'],
        'junebabo': <String>['liababo', 'yunjung5437'],
        'yunjung5437': <String>['junebabo', 'liababo'],
      };
  late final AnimationController _chatRouteController;
  late final ChatMessageCache _messageCache;
  final Map<String, List<ChatMessage>> _conversationMessagesByUserId =
      <String, List<ChatMessage>>{};
  final Map<String, bool> _conversationHasMoreByUserId = <String, bool>{};
  final Set<String> _prefetchingConversationUserIds = <String>{};
  final Set<String> _conversationCacheTrimmedUserIds = <String>{};

  List<_ChatListEntry>? _chatEntries;
  AppUser? _selectedUser;
  int? _chatRoutePointer;
  Offset? _chatRoutePointerStart;
  Offset? _chatRoutePointerLast;
  VelocityTracker? _chatRouteVelocityTracker;
  bool _chatRoutePointerRejected = false;
  bool _chatRouteDragActive = false;
  bool _chatRouteClosing = false;
  bool _chatEntriesLoading = true;
  bool _chatEntriesRefreshing = false;
  bool _chatEntriesRefreshPending = false;
  String? _chatEntriesErrorMessage;

  ChatApi get _chatApi => widget.chatApi;

  @override
  void initState() {
    super.initState();

    _chatRouteController = AnimationController(
      vsync: this,
      duration: _chatRouteOpenDuration,
      reverseDuration: _chatRouteCloseDuration,
    );
    _messageCache =
        widget.messageCache ??
        ChatMessageCache(
          chatApi: _chatApi,
          currentUserId: widget.session.user.id,
        );

    widget.controller.addListener(_openPendingConversation);
    widget.realtimeService.addListener(_handleRealtimeStateChanged);

    unawaited(_loadChatEntries(showInitialLoading: true));
  }

  @override
  void dispose() {
    final String? selectedUserId = _selectedUser?.id;
    if (selectedUserId != null) {
      unawaited(
        widget.realtimeService.clearActiveConversationUserId(selectedUserId),
      );
    }

    widget.controller.removeListener(_openPendingConversation);
    widget.realtimeService.removeListener(_handleRealtimeStateChanged);
    _chatRouteController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ChatConversationHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_openPendingConversation);
      widget.controller.addListener(_openPendingConversation);
      _openPendingConversation();
    }

    if (oldWidget.realtimeService != widget.realtimeService) {
      oldWidget.realtimeService.removeListener(_handleRealtimeStateChanged);
      widget.realtimeService.addListener(_handleRealtimeStateChanged);

      final String? selectedUserId = _selectedUser?.id;
      if (selectedUserId != null) {
        unawaited(
          widget.realtimeService.setActiveConversationUserId(selectedUserId),
        );
      }
    }
  }

  void _handleRealtimeStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadChatEntries({required bool showInitialLoading}) async {
    if (_chatEntriesRefreshing) {
      _chatEntriesRefreshPending = true;
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

      final List<_ChatListEntry> entries = chatUsers
          .map((AppUser user) => _ChatListEntry(user: user))
          .toList(growable: false);

      if (!mounted) {
        return;
      }

      setState(() {
        _chatEntries = List<_ChatListEntry>.unmodifiable(entries);
        _chatEntriesLoading = false;
        _chatEntriesErrorMessage = null;
      });

      _precacheProfileImages(entries);
      _openPendingConversation();
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

      if (_chatEntriesRefreshPending && mounted) {
        _chatEntriesRefreshPending = false;
        unawaited(_loadChatEntries(showInitialLoading: false));
      }
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
          priorityByName[_normalizeUserKey(_displayNameFor(first))] ??
          chatOrder.length;
      final int secondPriority =
          priorityByName[_normalizeUserKey(second.username)] ??
          priorityByName[_normalizeUserKey(_displayNameFor(second))] ??
          chatOrder.length;

      final int priorityComparison = firstPriority.compareTo(secondPriority);

      if (priorityComparison != 0) {
        return priorityComparison;
      }

      return _normalizeUserKey(
        _displayNameFor(first),
      ).compareTo(_normalizeUserKey(_displayNameFor(second)));
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
      final ChatCachedConversation cachedConversation = await _messageCache
          .readConversation(userId);

      if (mounted && cachedConversation.messages.isNotEmpty) {
        final int cacheStartIndex =
            cachedConversation.messages.length >
                _conversationEntryCacheMessageLimit
            ? cachedConversation.messages.length -
                  _conversationEntryCacheMessageLimit
            : 0;
        _conversationMessagesByUserId[userId] = List<ChatMessage>.unmodifiable(
          cachedConversation.messages.sublist(cacheStartIndex),
        );
        _conversationHasMoreByUserId[userId] =
            cacheStartIndex > 0 || cachedConversation.hasMoreOlder;
        if (cacheStartIndex > 0) {
          _conversationCacheTrimmedUserIds.add(userId);
        }
      }

      final ChatConversationPage page = await _chatApi.listConversation(
        otherUserId: userId,
      );

      if (!mounted) {
        return;
      }

      unawaited(
        _messageCache.mergeLatestConversation(
          otherUserId: userId,
          messages: page.messages,
          hasMoreOlder: page.hasMore,
        ),
      );
      _conversationMessagesByUserId[userId] = List<ChatMessage>.unmodifiable(
        page.messages,
      );
      _conversationCacheTrimmedUserIds.remove(userId);
      _conversationHasMoreByUserId[userId] = page.hasMore;
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
    return user.effectiveDisplayName;
  }

  void _retryUsers() {
    unawaited(_loadChatEntries(showInitialLoading: true));
  }

  void _openPendingConversation() {
    if (!mounted) {
      return;
    }

    final String? userId = widget.controller.pendingUserId;
    final List<_ChatListEntry>? entries = _chatEntries;
    if (userId == null || entries == null) {
      return;
    }

    _ChatListEntry? entry;
    for (final _ChatListEntry candidate in entries) {
      if (candidate.user.id == userId) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) {
      return;
    }

    widget.controller.consume(userId);
    _openChat(entry.user);
  }

  void _cacheConversationMessages({
    required String userId,
    required List<ChatMessage> messages,
  }) {
    final bool cacheWasTrimmed =
        messages.length > _conversationEntryCacheMessageLimit;
    final int cacheStartIndex = cacheWasTrimmed
        ? messages.length - _conversationEntryCacheMessageLimit
        : 0;

    _conversationMessagesByUserId[userId] = List<ChatMessage>.unmodifiable(
      messages.sublist(cacheStartIndex),
    );

    if (cacheWasTrimmed) {
      _conversationCacheTrimmedUserIds.add(userId);
    } else {
      _conversationCacheTrimmedUserIds.remove(userId);
    }
  }

  void _openChat(AppUser user) {
    if (_selectedUser?.id == user.id) {
      return;
    }

    _chatRouteController.stop();
    _chatRouteController.value = 0;
    _chatRouteClosing = false;
    _chatRouteDragActive = false;

    setState(() {
      _selectedUser = user;
    });
    unawaited(widget.realtimeService.setActiveConversationUserId(user.id));
  }

  Future<void> _startOpenChatAnimation(AppUser user) async {
    if (!mounted ||
        _selectedUser?.id != user.id ||
        _chatRouteClosing ||
        _chatRouteController.isAnimating ||
        _chatRouteController.value >= 1) {
      return;
    }

    try {
      await _chatRouteController
          .animateTo(
            1,
            duration: _chatRouteOpenDuration,
            curve: Curves.easeOutCubic,
          )
          .orCancel;
    } on TickerCanceled {
      // A close gesture can legitimately replace the opening animation.
    }
  }

  void _requestCloseChat() {
    final AppUser? selectedUser = _selectedUser;

    if (selectedUser == null || _chatRouteClosing) {
      return;
    }

    _resetChatRoutePointer();
    _chatRouteClosing = true;

    unawaited(
      _chatRouteController
          .animateTo(
            0,
            duration: _chatRouteCloseDuration,
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            _finishCloseChat(selectedUser);
          }),
    );
  }

  void _finishCloseChat(AppUser selectedUser) {
    if (!mounted || _selectedUser?.id != selectedUser.id) {
      return;
    }

    setState(() {
      _selectedUser = null;
      _chatRouteClosing = false;
      _chatRouteDragActive = false;
    });

    _chatRouteController.value = 0;
    unawaited(
      widget.realtimeService.clearActiveConversationUserId(selectedUser.id),
    );
  }

  void _setChatRouteDragActive(bool active) {
    if (_chatRouteDragActive == active) {
      return;
    }

    setState(() {
      _chatRouteDragActive = active;
    });
  }

  void _resetChatRoutePointer({bool unlockScroll = true}) {
    final bool shouldNotifyScrollUnlock = unlockScroll && _chatRouteDragActive;

    void resetPointer() {
      _chatRoutePointer = null;
      _chatRoutePointerStart = null;
      _chatRoutePointerLast = null;
      _chatRouteVelocityTracker = null;
      _chatRoutePointerRejected = false;

      if (unlockScroll) {
        _chatRouteDragActive = false;
      }
    }

    if (shouldNotifyScrollUnlock) {
      setState(resetPointer);
      return;
    }

    _chatRoutePointer = null;
    _chatRoutePointerStart = null;
    _chatRoutePointerLast = null;
    _chatRouteVelocityTracker = null;
    _chatRoutePointerRejected = false;
  }

  void _handleChatRoutePointerDown(PointerDownEvent event) {
    if (_selectedUser == null ||
        _chatRouteClosing ||
        _chatRouteDragActive ||
        _chatRoutePointer != null) {
      return;
    }

    _chatRoutePointer = event.pointer;
    _chatRoutePointerStart = event.position;
    _chatRoutePointerLast = event.position;
    _chatRouteVelocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _chatRoutePointerRejected = false;
  }

  void _handleChatRoutePointerMove(PointerMoveEvent event) {
    if (_chatRoutePointer != event.pointer ||
        _selectedUser == null ||
        _chatRouteClosing) {
      return;
    }

    _chatRouteVelocityTracker?.addPosition(event.timeStamp, event.position);

    final Offset? pointerStart = _chatRoutePointerStart;
    final Offset? pointerLast = _chatRoutePointerLast;

    if (pointerStart == null || pointerLast == null) {
      return;
    }

    if (!_chatRouteDragActive) {
      if (_chatRoutePointerRejected) {
        return;
      }

      final Offset totalDelta = event.position - pointerStart;
      final double horizontalDistance = totalDelta.dx.abs();
      final double verticalDistance = totalDelta.dy.abs();

      if (horizontalDistance < _chatRouteDragSlop &&
          verticalDistance < _chatRouteDragSlop) {
        return;
      }

      // Decide once per pointer sequence. A vertical scroll must not turn into
      // route navigation later just because the finger drifts to the right.
      if (totalDelta.dx <= 0 || horizontalDistance <= verticalDistance) {
        _chatRoutePointerRejected = true;
        return;
      }

      _chatRouteController.stop();
      _setChatRouteDragActive(true);
    }

    final double width = MediaQuery.sizeOf(context).width;
    final double delta = event.position.dx - pointerLast.dx;

    if (width <= 0) {
      return;
    }

    final double nextValue = (_chatRouteController.value - delta / width)
        .clamp(0.0, 1.0)
        .toDouble();

    _chatRouteController.value = nextValue;
    _chatRoutePointerLast = event.position;
  }

  void _handleChatRoutePointerUp(PointerUpEvent event) {
    if (_chatRoutePointer != event.pointer) {
      return;
    }

    final bool wasDragging = _chatRouteDragActive;
    final double velocity =
        _chatRouteVelocityTracker?.getVelocity().pixelsPerSecond.dx ?? 0;

    if (!wasDragging) {
      _resetChatRoutePointer();
      return;
    }

    final AppUser? selectedUser = _selectedUser;

    if (selectedUser == null) {
      _resetChatRoutePointer();
      return;
    }

    final bool shouldClose =
        velocity > _chatRouteFlingVelocity ||
        _chatRouteController.value <= 1 - _chatRouteDismissProgress;

    if (shouldClose) {
      _resetChatRoutePointer(unlockScroll: false);
      _chatRouteClosing = true;
      unawaited(
        _chatRouteController
            .animateTo(
              0,
              duration: _chatRouteCloseDuration,
              curve: Curves.easeOutCubic,
            )
            .then((_) {
              _finishCloseChat(selectedUser);
            }),
      );
      return;
    }

    _resetChatRoutePointer(unlockScroll: false);
    unawaited(
      _chatRouteController
          .animateTo(
            1,
            duration: _chatRouteOpenDuration,
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted || _selectedUser?.id != selectedUser.id) {
              return;
            }

            _setChatRouteDragActive(false);
          }),
    );
  }

  void _handleChatRoutePointerCancel(PointerCancelEvent event) {
    if (_chatRoutePointer != event.pointer) {
      return;
    }

    final bool wasDragging = _chatRouteDragActive;

    if (!wasDragging) {
      _resetChatRoutePointer();
      return;
    }

    final AppUser? selectedUser = _selectedUser;
    _resetChatRoutePointer(unlockScroll: false);
    unawaited(
      _chatRouteController
          .animateTo(
            1,
            duration: _chatRouteOpenDuration,
            curve: Curves.easeOutCubic,
          )
          .then((_) {
            if (!mounted || _selectedUser?.id != selectedUser?.id) {
              return;
            }

            _setChatRouteDragActive(false);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppUser? selectedUser = _selectedUser;

    final Widget chatList = _buildChatList();

    if (selectedUser == null) {
      return chatList;
    }

    return Stack(
      children: <Widget>[
        IgnorePointer(ignoring: true, child: chatList),
        _buildChatRoute(selectedUser),
      ],
    );
  }

  Widget _buildChatRoute(AppUser selectedUser) {
    return AnimatedBuilder(
      animation: _chatRouteController,
      child: SizedBox.expand(
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handleChatRoutePointerDown,
          onPointerMove: _handleChatRoutePointerMove,
          onPointerUp: _handleChatRoutePointerUp,
          onPointerCancel: _handleChatRoutePointerCancel,
          child: ChatConversationScreen(
            key: ValueKey<String>(selectedUser.id),
            chatApi: _chatApi,
            messageCache: _messageCache,
            realtimeService: widget.realtimeService,
            currentUser: widget.session.user,
            otherUser: selectedUser,
            otherUserDisplayName: _displayNameFor(selectedUser),
            routeNavigationDragActive: _chatRouteDragActive,
            initialMessages: _conversationMessagesByUserId[selectedUser.id],
            initialHasMoreMessages:
                _conversationHasMoreByUserId[selectedUser.id],
            onMessagesChanged: (List<ChatMessage> messages) {
              _cacheConversationMessages(
                userId: selectedUser.id,
                messages: messages,
              );
            },
            onHasMoreMessagesChanged: (bool hasMore) {
              _conversationHasMoreByUserId[selectedUser.id] =
                  hasMore ||
                  _conversationCacheTrimmedUserIds.contains(selectedUser.id);
            },
            onReadyForRouteAnimation: () =>
                _startOpenChatAnimation(selectedUser),
            onBack: _requestCloseChat,
          ),
        ),
      ),
      builder: (BuildContext context, Widget? child) {
        final double width = MediaQuery.sizeOf(context).width;
        final double offset = (1 - _chatRouteController.value) * width;

        return Transform.translate(
          key: const ValueKey<String>('chat-route-transform'),
          offset: Offset(offset, 0),
          child: child,
        );
      },
    );
  }

  Widget _buildChatList() {
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
                    unreadCount: widget.realtimeService.unreadCountFor(user.id),
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
                    _openChat(user);
                  },
                );
              },
            ),
    );
  }
}

final class _ChatListEntry {
  const _ChatListEntry({required this.user});

  final AppUser user;
}

final class ChatConversationScreen extends StatefulWidget {
  const ChatConversationScreen({
    required this.chatApi,
    required this.messageCache,
    required this.realtimeService,
    required this.currentUser,
    required this.otherUser,
    required this.otherUserDisplayName,
    required this.onBack,
    this.onReadyForRouteAnimation,
    this.routeNavigationDragActive = false,
    this.initialMessages,
    this.initialHasMoreMessages,
    this.onMessagesChanged,
    this.onHasMoreMessagesChanged,
    super.key,
  });

  final ChatApi chatApi;
  final ChatMessageCache messageCache;
  final ChatRealtimeService realtimeService;
  final AppUser currentUser;
  final AppUser otherUser;
  final String otherUserDisplayName;
  final VoidCallback onBack;
  final Future<void> Function()? onReadyForRouteAnimation;
  final bool routeNavigationDragActive;
  final List<ChatMessage>? initialMessages;
  final bool? initialHasMoreMessages;
  final ValueChanged<List<ChatMessage>>? onMessagesChanged;
  final ValueChanged<bool>? onHasMoreMessagesChanged;

  @override
  State<ChatConversationScreen> createState() {
    return _ChatConversationScreenState();
  }
}

final class _ChatConversationScreenState extends State<ChatConversationScreen> {
  static const int _replyNavigationContextRadius = 30;
  static const int _conversationPageSize = 100;
  static const List<Duration> _olderMessagesRetryDelays = <Duration>[
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];

  StreamSubscription<Map<String, dynamic>>? _realtimeEventSubscription;
  Future<void>? _olderMessagesLoadFuture;
  Future<void>? _newerMessagesLoadFuture;
  int _messageWindowGeneration = 0;
  late bool _loading;
  String? _errorMessage;
  bool _syncingAfterReconnect = false;
  bool _loadingOlderMessages = false;
  bool _loadingNewerMessages = false;
  late bool _hasMoreMessages;
  bool _hasMoreNewerMessages = false;
  late List<ChatMessage> _messages;
  late List<ChatMessage> _latestMessages;
  late bool _latestHasMoreMessages;
  bool _showingLatestWindow = true;
  late final bool _openedWithCachedMessages;
  bool _didNotifyReadyForRouteAnimation = false;

  @override
  void initState() {
    super.initState();

    final List<ChatMessage>? initialMessages = widget.initialMessages;

    _messages = initialMessages == null
        ? const <ChatMessage>[]
        : List<ChatMessage>.unmodifiable(initialMessages);
    _latestMessages = _messages;
    _openedWithCachedMessages = initialMessages != null;
    _loading = initialMessages == null;
    _hasMoreMessages =
        widget.initialHasMoreMessages ?? (initialMessages?.length == 100);
    _latestHasMoreMessages = _hasMoreMessages;

    _subscribeToRealtimeService();
    widget.realtimeService.addListener(_handleRealtimeStateChanged);

    if (!_openedWithCachedMessages) {
      unawaited(_loadConversation(showLoading: true));
    }

    // Start after the first route frame has built so synchronous widget
    // construction cannot consume the animation before anything is painted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyReadyForRouteAnimation();
    });
  }

  @override
  void didUpdateWidget(covariant ChatConversationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.realtimeService != widget.realtimeService) {
      unawaited(_realtimeEventSubscription?.cancel());
      oldWidget.realtimeService.removeListener(_handleRealtimeStateChanged);
      _subscribeToRealtimeService();
      widget.realtimeService.addListener(_handleRealtimeStateChanged);
    }
  }

  @override
  void dispose() {
    widget.realtimeService.removeListener(_handleRealtimeStateChanged);
    unawaited(_realtimeEventSubscription?.cancel());
    super.dispose();
  }

  void _subscribeToRealtimeService() {
    _realtimeEventSubscription = widget.realtimeService.events.listen(
      _handleRealtimeEvent,
    );
  }

  void _handleRealtimeStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _notifyReadyForRouteAnimation() {
    if (!mounted || _didNotifyReadyForRouteAnimation) {
      return;
    }

    _didNotifyReadyForRouteAnimation = true;
    unawaited(_openRouteAndRefreshCachedConversation());
  }

  Future<void> _openRouteAndRefreshCachedConversation() async {
    final Future<void> Function()? onReady = widget.onReadyForRouteAnimation;

    if (onReady != null) {
      await onReady();
    }

    if (!mounted) {
      return;
    }

    if (_openedWithCachedMessages) {
      // Rebuilding a long cached timeline during the 190ms route transition can
      // starve the animation of frames, so refresh only after it has completed.
      await _loadConversation(showLoading: false);
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
      final ChatConversationPage page = await widget.chatApi.listConversation(
        otherUserId: widget.otherUser.id,
      );

      if (!mounted) {
        return;
      }

      final bool hadCachedMessages = _latestMessages.isNotEmpty;
      final List<ChatMessage> untrimmedLatestMessages = hadCachedMessages
          ? _mergeMessageLists(_latestMessages, page.messages)
          : page.messages;
      final List<ChatMessage> mergedLatestMessages = hadCachedMessages
          ? _trimLatestMessages(untrimmedLatestMessages)
          : page.messages;
      final bool latestHasMoreMessages =
          page.hasMore ||
          (hadCachedMessages &&
              untrimmedLatestMessages.length >
                  _conversationEntryCacheMessageLimit);

      setState(() {
        _latestMessages = List<ChatMessage>.unmodifiable(mergedLatestMessages);
        _latestHasMoreMessages = latestHasMoreMessages;
        if (_showingLatestWindow) {
          _messages = _latestMessages;
          _hasMoreMessages = latestHasMoreMessages;
          _hasMoreNewerMessages = false;
        }
        _loading = false;
        _errorMessage = null;
      });
      _notifyMessagesChanged();

      unawaited(
        widget.realtimeService.markConversationAsRead(widget.otherUser.id),
      );
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

  Future<bool> _ensureMessageLoaded(
    String messageId, {
    required bool restoreLatestWindow,
  }) async {
    ReplyNavigationDiagnostics.record(
      '[reply-navigation] ensure-start '
      'target=$messageId loaded=${_containsMessage(messageId)} '
      'messages=${_messages.length} '
      'hasMoreOlder=$_hasMoreMessages '
      'hasMoreNewer=$_hasMoreNewerMessages '
      'restoreLatest=$restoreLatestWindow',
    );

    if (restoreLatestWindow &&
        _latestMessages.any((ChatMessage message) => message.id == messageId) &&
        mounted) {
      _messageWindowGeneration += 1;
      setState(() {
        _showingLatestWindow = true;
        _messages = _latestMessages;
        _hasMoreMessages = _latestHasMoreMessages;
        _hasMoreNewerMessages = false;
      });
      ReplyNavigationDiagnostics.record(
        '[reply-navigation] latest-window-result '
        'target=$messageId result=true messages=${_messages.length}',
      );
      return true;
    }

    final ChatCachedConversation? cachedContext = await widget.messageCache
        .readConversationAround(
          otherUserId: widget.otherUser.id,
          messageId: messageId,
          olderLimit: _replyNavigationContextRadius,
          newerLimit: _replyNavigationContextRadius,
        );

    if (cachedContext != null &&
        cachedContext.messages.any(
          (ChatMessage message) => message.id == messageId,
        ) &&
        mounted) {
      _showConversationContext(cachedContext);
      ReplyNavigationDiagnostics.record(
        '[reply-navigation] cache-result '
        'target=$messageId result=true '
        'messages=${cachedContext.messages.length} '
        'hasMoreOlder=${cachedContext.hasMoreOlder} '
        'hasMoreNewer=${cachedContext.hasMoreNewer}',
      );
      return true;
    }

    ReplyNavigationDiagnostics.record(
      '[reply-navigation] cache-miss target=$messageId',
    );
    ReplyNavigationDiagnostics.record(
      '[reply-navigation] context-request '
      'target=$messageId older=$_replyNavigationContextRadius '
      'newer=$_replyNavigationContextRadius',
    );
    final ChatConversationContext? context =
        await _requestMessageContextWithRetry(messageId);

    if (!mounted ||
        context == null ||
        !context.messages.any(
          (ChatMessage message) => message.id == messageId,
        )) {
      ReplyNavigationDiagnostics.record(
        '[reply-navigation] context-result '
        'target=$messageId result=false',
      );
      return false;
    }

    _showConversationContext(
      ChatCachedConversation(
        messages: context.messages,
        hasMoreOlder: context.hasMoreOlder,
        hasMoreNewer: context.hasMoreNewer,
      ),
    );
    unawaited(
      widget.messageCache.mergeConversationContext(
        otherUserId: widget.otherUser.id,
        messages: context.messages,
        hasMoreOlder: context.hasMoreOlder,
        hasMoreNewer: context.hasMoreNewer,
      ),
    );
    ReplyNavigationDiagnostics.record(
      '[reply-navigation] context-result '
      'target=$messageId result=true '
      'messages=${context.messages.length} '
      'hasMoreOlder=${context.hasMoreOlder} '
      'hasMoreNewer=${context.hasMoreNewer}',
    );
    return true;
  }

  void _showConversationContext(ChatCachedConversation context) {
    _messageWindowGeneration += 1;
    setState(() {
      _showingLatestWindow = false;
      _messages = context.messages;
      _hasMoreMessages = context.hasMoreOlder;
      _hasMoreNewerMessages = context.hasMoreNewer;
    });
  }

  Future<void> _showLatestMessages() async {
    if (!mounted) {
      return;
    }

    _messageWindowGeneration += 1;

    if (_showingLatestWindow && !_hasMoreNewerMessages) {
      return;
    }

    setState(() {
      _showingLatestWindow = true;
      _messages = _latestMessages;
      _hasMoreMessages = _latestHasMoreMessages;
      _hasMoreNewerMessages = false;
    });

    await WidgetsBinding.instance.endOfFrame;
  }

  Future<ChatConversationContext?> _requestMessageContextWithRetry(
    String messageId,
  ) async {
    int retryAttempt = 0;

    while (true) {
      try {
        return await widget.chatApi.getConversationMessageContext(
          otherUserId: widget.otherUser.id,
          messageId: messageId,
          olderLimit: _replyNavigationContextRadius,
          newerLimit: _replyNavigationContextRadius,
        );
      } on ChatApiException catch (error) {
        ReplyNavigationDiagnostics.record(
          '[reply-navigation] context-error '
          'target=$messageId status=${error.statusCode} '
          'retryable=${error.retryable}',
        );
        if (!error.retryable ||
            retryAttempt >= _olderMessagesRetryDelays.length) {
          return null;
        }
      } catch (_) {
        return null;
      }

      final Duration retryDelay = _olderMessagesRetryDelays[retryAttempt];
      retryAttempt += 1;
      await Future<void>.delayed(retryDelay);

      if (!mounted) {
        return null;
      }
    }
  }

  Future<void> _loadOlderMessages() async {
    final Future<void>? inFlightLoad = _olderMessagesLoadFuture;

    if (inFlightLoad != null) {
      await inFlightLoad;
      return;
    }

    final Future<void> loadFuture = _performOlderMessagesLoad();
    _olderMessagesLoadFuture = loadFuture;

    try {
      await loadFuture;
    } finally {
      if (identical(_olderMessagesLoadFuture, loadFuture)) {
        _olderMessagesLoadFuture = null;
      }
    }
  }

  Future<void> _performOlderMessagesLoad() async {
    if (!_hasMoreMessages || _messages.isEmpty || !mounted) {
      return;
    }

    final int messageWindowGeneration = _messageWindowGeneration;
    setState(() {
      _loadingOlderMessages = true;
    });
    final String beforeMessageId = _messages.first.id;

    try {
      final ChatCachedConversation? cachedPage = await widget.messageCache
          .readMessagesBefore(
            otherUserId: widget.otherUser.id,
            beforeMessageId: beforeMessageId,
            limit: _conversationPageSize,
          );

      if (!mounted || messageWindowGeneration != _messageWindowGeneration) {
        return;
      }

      if (cachedPage != null && cachedPage.messages.isNotEmpty) {
        setState(() {
          _showingLatestWindow = false;
          _messages = _mergeMessageLists(cachedPage.messages, _messages);
          _hasMoreMessages = cachedPage.hasMoreOlder;
        });
        _notifyMessagesChanged(persistToMessageCache: false);
        return;
      }

      final ChatConversationPage? page =
          await _requestConversationPageWithRetry(
            beforeMessageId: beforeMessageId,
            limit: _conversationPageSize,
          );

      if (!mounted ||
          page == null ||
          messageWindowGeneration != _messageWindowGeneration) {
        return;
      }

      if (page.messages.isEmpty) {
        setState(() {
          _hasMoreMessages = false;
        });
        unawaited(
          widget.messageCache.updateOlderBoundary(
            otherUserId: widget.otherUser.id,
            boundaryMessageId: beforeMessageId,
            hasMoreOlder: false,
          ),
        );
        return;
      }

      setState(() {
        _showingLatestWindow = false;
        _messages = _mergeMessageLists(page.messages, _messages);
        _hasMoreMessages = page.hasMore;
      });
      unawaited(
        widget.messageCache.mergeOlderPage(
          otherUserId: widget.otherUser.id,
          beforeMessageId: beforeMessageId,
          messages: page.messages,
          hasMoreOlder: page.hasMore,
        ),
      );
      _notifyMessagesChanged(persistToMessageCache: false);
    } finally {
      if (mounted) {
        setState(() {
          _loadingOlderMessages = false;
        });
      } else {
        _loadingOlderMessages = false;
      }
    }
  }

  Future<void> _loadNewerMessages() async {
    final Future<void>? inFlightLoad = _newerMessagesLoadFuture;

    if (inFlightLoad != null) {
      await inFlightLoad;
      return;
    }

    final Future<void> loadFuture = _performNewerMessagesLoad();
    _newerMessagesLoadFuture = loadFuture;

    try {
      await loadFuture;
    } finally {
      if (identical(_newerMessagesLoadFuture, loadFuture)) {
        _newerMessagesLoadFuture = null;
      }
    }
  }

  Future<void> _performNewerMessagesLoad() async {
    if (!_hasMoreNewerMessages || _messages.isEmpty || !mounted) {
      return;
    }

    final int messageWindowGeneration = _messageWindowGeneration;
    setState(() {
      _loadingNewerMessages = true;
    });
    final String afterMessageId = _messages.last.id;

    try {
      final ChatCachedConversation? cachedPage = await widget.messageCache
          .readMessagesAfter(
            otherUserId: widget.otherUser.id,
            afterMessageId: afterMessageId,
            limit: _conversationPageSize,
          );

      if (!mounted || messageWindowGeneration != _messageWindowGeneration) {
        return;
      }

      if (cachedPage != null && cachedPage.messages.isNotEmpty) {
        setState(() {
          _messages = _mergeMessageLists(_messages, cachedPage.messages);
          _hasMoreNewerMessages = cachedPage.hasMoreNewer;
        });
        _notifyMessagesChanged(persistToMessageCache: false);
        return;
      }

      final ChatConversationPage? page =
          await _requestConversationPageWithRetry(
            afterMessageId: afterMessageId,
            limit: _conversationPageSize,
          );

      if (!mounted ||
          page == null ||
          messageWindowGeneration != _messageWindowGeneration) {
        return;
      }

      if (page.messages.isEmpty) {
        setState(() {
          _hasMoreNewerMessages = false;
        });
        unawaited(
          widget.messageCache.updateNewerBoundary(
            otherUserId: widget.otherUser.id,
            boundaryMessageId: afterMessageId,
            hasMoreNewer: false,
          ),
        );
        return;
      }

      setState(() {
        _messages = _mergeMessageLists(_messages, page.messages);
        _hasMoreNewerMessages = page.hasMore;
      });
      unawaited(
        widget.messageCache.mergeNewerPage(
          otherUserId: widget.otherUser.id,
          afterMessageId: afterMessageId,
          messages: page.messages,
          hasMoreNewer: page.hasMore,
        ),
      );
      _notifyMessagesChanged(persistToMessageCache: false);
    } finally {
      if (mounted) {
        setState(() {
          _loadingNewerMessages = false;
        });
      } else {
        _loadingNewerMessages = false;
      }
    }
  }

  Future<ChatConversationPage?> _requestConversationPageWithRetry({
    String? beforeMessageId,
    String? afterMessageId,
    required int limit,
  }) async {
    int retryAttempt = 0;
    final String? cursorMessageId = beforeMessageId ?? afterMessageId;
    final String direction = beforeMessageId == null ? 'newer' : 'older';

    while (true) {
      try {
        return await widget.chatApi.listConversation(
          otherUserId: widget.otherUser.id,
          beforeMessageId: beforeMessageId,
          afterMessageId: afterMessageId,
          limit: limit,
        );
      } on ChatApiException catch (error) {
        ReplyNavigationDiagnostics.record(
          '[reply-navigation] page-error '
          'direction=$direction cursor=$cursorMessageId limit=$limit '
          'status=${error.statusCode} retryable=${error.retryable}',
        );
        if (!error.retryable ||
            retryAttempt >= _olderMessagesRetryDelays.length) {
          return null;
        }
      } catch (_) {
        return null;
      }

      final Duration retryDelay = _olderMessagesRetryDelays[retryAttempt];
      retryAttempt += 1;
      await Future<void>.delayed(retryDelay);

      if (!mounted) {
        return null;
      }
    }
  }

  bool _containsMessage(String messageId) {
    return _messages.any((ChatMessage message) => message.id == messageId);
  }

  Future<void> _syncConversationFromRest() async {
    if (_loading || _syncingAfterReconnect) {
      return;
    }

    _syncingAfterReconnect = true;

    try {
      final ChatConversationPage page = await widget.chatApi.listConversation(
        otherUserId: widget.otherUser.id,
      );

      if (!mounted) {
        return;
      }

      final List<ChatMessage> untrimmedLatestMessages = _mergeMessageLists(
        _latestMessages,
        page.messages,
      );
      final List<ChatMessage> nextLatestMessages = _trimLatestMessages(
        untrimmedLatestMessages,
      );
      final bool nextLatestHasMoreMessages =
          page.hasMore ||
          untrimmedLatestMessages.length > _conversationEntryCacheMessageLimit;
      final bool visibleWindowIncludesNewest = !_hasMoreNewerMessages;

      setState(() {
        _latestMessages = nextLatestMessages;
        _latestHasMoreMessages = nextLatestHasMoreMessages;
        if (visibleWindowIncludesNewest) {
          _messages = _mergeMessageLists(_messages, page.messages);
          _hasMoreNewerMessages = false;
        }
        _errorMessage = null;
      });
      _notifyMessagesChanged();
      unawaited(
        widget.realtimeService.markConversationAsRead(widget.otherUser.id),
      );
    } catch (_) {
      // Keep the current conversation visible during transient sync errors.
    } finally {
      _syncingAfterReconnect = false;
    }
  }

  List<ChatMessage> _mergeMessageLists(
    Iterable<ChatMessage> first,
    Iterable<ChatMessage> second,
  ) {
    final Map<String, ChatMessage> messagesById = <String, ChatMessage>{
      for (final ChatMessage message in first) message.id: message,
    };

    for (final ChatMessage message in second) {
      messagesById[message.id] = message;
    }

    final List<ChatMessage> mergedMessages = messagesById.values.toList(
      growable: false,
    )..sort(compareChatMessages);

    return List<ChatMessage>.unmodifiable(mergedMessages);
  }

  List<ChatMessage> _trimLatestMessages(Iterable<ChatMessage> messages) {
    final List<ChatMessage> sortedMessages = messages.toList(growable: false)
      ..sort(compareChatMessages);
    final int startIndex =
        sortedMessages.length > _conversationEntryCacheMessageLimit
        ? sortedMessages.length - _conversationEntryCacheMessageLimit
        : 0;
    return List<ChatMessage>.unmodifiable(sortedMessages.sublist(startIndex));
  }

  void _handleRealtimeEvent(Map<String, dynamic> event) {
    final Object? eventType = event['type'];

    if (eventType is! String) {
      return;
    }

    switch (eventType) {
      case 'connected':
        unawaited(_syncConversationFromRest());
        return;
      case 'pong':
        return;
      case 'message.created':
      case 'message.updated':
      case 'message.translation.updated':
        _handleMessageEvent(event);
        return;
      case 'message.deleted':
        _handleMessageDeletedEvent(event);
        return;
      case 'messages.read':
        _handleMessagesReadEvent(event);
        return;
      case 'error':
        return;
    }
  }

  void _handleMessageEvent(Map<String, dynamic> event) {
    final Object? messageJson = event['message'];

    if (messageJson is! Map) {
      return;
    }

    final ChatMessage message;

    try {
      message = widget.chatApi.messageFromJson(
        Map<String, dynamic>.from(messageJson),
      );
    } catch (_) {
      return;
    }

    if (!_messageBelongsToConversation(message)) {
      return;
    }

    _upsertMessage(message);
  }

  void _handleMessageDeletedEvent(Map<String, dynamic> event) {
    final Object? messageId = event['message_id'];

    if (messageId is String) {
      _removeMessage(messageId);
    }
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
  }

  bool _messageBelongsToConversation(ChatMessage message) {
    return (message.senderId == widget.currentUser.id &&
            message.recipientId == widget.otherUser.id) ||
        (message.senderId == widget.otherUser.id &&
            message.recipientId == widget.currentUser.id);
  }

  void _upsertMessage(ChatMessage message) {
    final bool isNewLatestMessage = !_latestMessages.any(
      (ChatMessage existingMessage) => existingMessage.id == message.id,
    );
    final List<ChatMessage> untrimmedLatestMessages = _mergeMessageLists(
      _latestMessages,
      <ChatMessage>[message],
    );
    final List<ChatMessage> nextLatestMessages = _trimLatestMessages(
      untrimmedLatestMessages,
    );
    final bool revealNewestWindow =
        _showingLatestWindow ||
        (isNewLatestMessage && message.senderId == widget.currentUser.id);
    final bool updateVisibleContext =
        !revealNewestWindow &&
        (_containsMessage(message.id) || !_hasMoreNewerMessages);

    setState(() {
      _latestMessages = nextLatestMessages;
      _latestHasMoreMessages =
          _latestHasMoreMessages ||
          untrimmedLatestMessages.length > _conversationEntryCacheMessageLimit;
      if (revealNewestWindow) {
        _showingLatestWindow = true;
        _messages = _latestMessages;
        _hasMoreMessages = _latestHasMoreMessages;
        _hasMoreNewerMessages = false;
      } else if (updateVisibleContext) {
        _messages = _mergeMessageLists(_messages, <ChatMessage>[message]);
      }
    });
    _notifyMessagesChanged();
  }

  void _upsertMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return;
    }

    final bool hasNewOutgoingMessage = messages.any(
      (ChatMessage message) =>
          message.senderId == widget.currentUser.id &&
          !_latestMessages.any(
            (ChatMessage existingMessage) => existingMessage.id == message.id,
          ),
    );
    final List<ChatMessage> untrimmedLatestMessages = _mergeMessageLists(
      _latestMessages,
      messages,
    );
    final List<ChatMessage> nextLatestMessages = _trimLatestMessages(
      untrimmedLatestMessages,
    );
    final bool revealNewestWindow =
        _showingLatestWindow || hasNewOutgoingMessage;
    final List<ChatMessage> visibleUpdates = messages
        .where(
          (ChatMessage message) =>
              _containsMessage(message.id) || !_hasMoreNewerMessages,
        )
        .toList(growable: false);

    setState(() {
      _latestMessages = nextLatestMessages;
      _latestHasMoreMessages =
          _latestHasMoreMessages ||
          untrimmedLatestMessages.length > _conversationEntryCacheMessageLimit;
      if (revealNewestWindow) {
        _showingLatestWindow = true;
        _messages = _latestMessages;
        _hasMoreMessages = _latestHasMoreMessages;
        _hasMoreNewerMessages = false;
      } else if (visibleUpdates.isNotEmpty) {
        _messages = _mergeMessageLists(_messages, visibleUpdates);
      }
    });
    _notifyMessagesChanged();
  }

  void _removeMessage(String messageId) {
    setState(() {
      _messages = List<ChatMessage>.unmodifiable(
        _messages.where((ChatMessage message) => message.id != messageId),
      );
      _latestMessages = List<ChatMessage>.unmodifiable(
        _latestMessages.where((ChatMessage message) => message.id != messageId),
      );
    });
    unawaited(
      widget.messageCache.removeMessage(
        otherUserId: widget.otherUser.id,
        messageId: messageId,
      ),
    );
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
      _latestMessages = List<ChatMessage>.unmodifiable(
        _latestMessages.map((ChatMessage message) {
          if (!messageIdSet.contains(message.id)) {
            return message;
          }

          return message.copyWith(readAt: readAt);
        }),
      );
    });
    _notifyMessagesChanged();
  }

  void _notifyMessagesChanged({bool persistToMessageCache = true}) {
    if (persistToMessageCache) {
      unawaited(
        widget.messageCache.mergeConversationContext(
          otherUserId: widget.otherUser.id,
          messages: _messages,
          hasMoreOlder: _hasMoreMessages,
          hasMoreNewer: _hasMoreNewerMessages,
        ),
      );
      unawaited(
        widget.messageCache.mergeLatestConversation(
          otherUserId: widget.otherUser.id,
          messages: _latestMessages,
          hasMoreOlder: _latestHasMoreMessages,
        ),
      );
    }
    widget.onMessagesChanged?.call(_latestMessages);
    widget.onHasMoreMessagesChanged?.call(_latestHasMoreMessages);
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

  Future<ChatMessage> _updateCallOutcome({
    required String messageId,
    required ChatCallOutcome outcome,
    required Duration duration,
  }) async {
    final ChatMessage message = await widget.chatApi.updateCallOutcome(
      messageId: messageId,
      outcome: outcome,
      duration: duration,
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
        showingLatestWindow: _showingLatestWindow,
        hasMoreMessages: _hasMoreMessages,
        hasMoreNewerMessages: _hasMoreNewerMessages,
        loadingOlderMessages: _loadingOlderMessages,
        loadingNewerMessages: _loadingNewerMessages,
        onLoadOlderMessages: _loadOlderMessages,
        onLoadNewerMessages: _loadNewerMessages,
        onShowLatestMessages: _showLatestMessages,
        onEnsureMessageLoaded: _ensureMessageLoaded,
        showLatestReadReceipt: !_hasMoreNewerMessages,
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
        onUpdateCallOutcome: _updateCallOutcome,
        onCreateMediaAssetAccessUrl: widget.chatApi.createMediaAssetAccessUrl,
        onEditTextMessage: _editTextMessage,
        onRetryTranslation: _retryTextMessageTranslation,
        onDeleteMessage: _deleteMessage,
        onBack: widget.onBack,
        unreadOtherConversationCount: widget.realtimeService
            .unreadCountExcluding(widget.otherUser.id),
        routeNavigationDragActive: widget.routeNavigationDragActive,
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
            child: AppProfileImage(
              imageUrl: imageUrl,
              size: _chatListAvatarSize,
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
