import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../design_system/app_colors.dart';
import '../../../design_system/app_radius.dart';
import '../../../design_system/app_typography.dart';
import '../domain/chat_message_action.dart';
import '../domain/chat_message.dart';
import '../domain/chat_message_group.dart';
import '../domain/chat_message_grouper.dart';
import 'chat_date_formatter.dart';
import 'read_receipt_formatter.dart';

const double _messageHorizontalPadding = 11;

typedef _MessageLongPressCallback =
    Future<void> Function(
      ChatMessage message,
      Rect bubbleRect,
      ui.Image bubbleImage,
    );

typedef _MessageBubbleKeyFor = GlobalKey Function(int messageId);

final class _CapturedMessageBubble {
  const _CapturedMessageBubble({required this.image, required this.rect});

  final ui.Image image;
  final Rect rect;
}

final class _MessageCaptureBoundary extends SingleChildRenderObjectWidget {
  const _MessageCaptureBoundary({required super.child, super.key});

  @override
  _MessageCaptureRenderRepaintBoundary createRenderObject(
    BuildContext context,
  ) {
    return _MessageCaptureRenderRepaintBoundary();
  }
}

final class _MessageCaptureRenderRepaintBoundary extends RenderRepaintBoundary {
  Future<ui.Image> captureImage(Rect bounds, {required double pixelRatio}) {
    assert(!debugNeedsPaint);

    final OffsetLayer offsetLayer = layer! as OffsetLayer;

    return offsetLayer.toImage(bounds, pixelRatio: pixelRatio);
  }
}

Future<_CapturedMessageBubble> _captureMessageBubble({
  required GlobalKey bubbleKey,
  required double pixelRatio,
}) async {
  final _MessageCaptureRenderRepaintBoundary boundary =
      bubbleKey.currentContext!.findRenderObject()!
          as _MessageCaptureRenderRepaintBoundary;

  final Offset bubbleTopLeft = boundary.localToGlobal(Offset.zero);

  const double horizontalOverflow = 8;

  final Rect localCaptureRect = Rect.fromLTWH(
    -horizontalOverflow,
    0,
    boundary.size.width + (horizontalOverflow * 2),
    boundary.size.height,
  );

  final ui.Image image = await boundary.captureImage(
    localCaptureRect,
    pixelRatio: pixelRatio,
  );

  return _CapturedMessageBubble(
    image: image,
    rect: Rect.fromLTWH(
      bubbleTopLeft.dx - horizontalOverflow,
      bubbleTopLeft.dy,
      localCaptureRect.width,
      localCaptureRect.height,
    ),
  );
}

Future<void> _handleMessageBubbleLongPress({
  required BuildContext context,
  required GlobalKey bubbleKey,
  required ChatMessage message,
  required _MessageLongPressCallback onMessageLongPress,
}) async {
  final double pixelRatio = MediaQuery.devicePixelRatioOf(context);

  final _CapturedMessageBubble capturedBubble = await _captureMessageBubble(
    bubbleKey: bubbleKey,
    pixelRatio: pixelRatio,
  );

  await onMessageLongPress(message, capturedBubble.rect, capturedBubble.image);
}

const TextHeightBehavior _messageTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: true,
  applyHeightToLastDescent: true,
  leadingDistribution: TextLeadingDistribution.even,
);

StrutStyle _buildMessageStrutStyle(TextStyle style) {
  return StrutStyle(
    fontFamily: style.fontFamily,
    fontFamilyFallback: style.fontFamilyFallback,
    fontSize: style.fontSize,
    height: style.height,
    fontWeight: style.fontWeight,
    fontStyle: style.fontStyle,
    forceStrutHeight: true,
    leadingDistribution: TextLeadingDistribution.even,
  );
}

final class ChatStylePreviewScreen extends StatelessWidget {
  const ChatStylePreviewScreen({super.key});

  static const int _currentUserId = 1;
  static const Color _chatBackgroundColor = AppColors.white;

  @override
  Widget build(BuildContext context) {
    final SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle.dark
        .copyWith(
          statusBarColor: _chatBackgroundColor,
          systemNavigationBarColor: _chatBackgroundColor,
          systemNavigationBarIconBrightness: Brightness.dark,
        );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: const Scaffold(
        backgroundColor: _chatBackgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              _ChatTopBar(),
              Expanded(child: _MessageList(currentUserId: _currentUserId)),
              _MessageComposer(),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ChatTopBar extends StatelessWidget {
  const _ChatTopBar();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('chat-top-bar'),
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(
            'Lia',
            style: AppTypography.typography4.copyWith(
              color: AppColors.grey900,
              fontWeight: AppTypography.bold,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Search',
                    onPressed: null,
                    icon: const Icon(
                      Icons.search_rounded,
                      size: 28,
                      color: AppColors.grey700,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Call',
                    onPressed: null,
                    icon: const Icon(
                      Icons.call_outlined,
                      size: 26,
                      color: AppColors.grey700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _MessageList extends StatefulWidget {
  const _MessageList({required this.currentUserId});

  final int currentUserId;

  @override
  State<_MessageList> createState() {
    return _MessageListState();
  }
}

final class _MessageListState extends State<_MessageList> {
  static const Duration _previewTranslationDelay = Duration(seconds: 5);

  static const Map<int, String> _previewTranslations = {
    1: '오빠, 나 곧 탑승해.',
    2: '네가 계속 말해주길 기다리고 있어.',
    5: '미안해, 오빠.',
    6: '다음에는 제대로 말할게.',
  };

  final Set<int> _showTranslatedMessageIds = <int>{};
  final Map<int, GlobalKey> _messageBubbleKeys = <int, GlobalKey>{};

  late final DateTime _previewNow;
  late List<ChatMessage> _messages;

  @override
  void initState() {
    super.initState();

    _previewNow = DateTime(2026, 6, 30, 20, 35);

    _messages = [
      ChatMessage(
        id: 1,
        senderId: 2,
        recipientId: 1,
        content: '欧巴我快要登机了',
        translationStatus: ChatTranslationStatus.none,
        createdAt: DateTime(2026, 6, 30, 20, 30, 5),
      ),
      ChatMessage(
        id: 2,
        senderId: 2,
        recipientId: 1,
        content: '我等你继续说呢',
        translatedContent: '네가 계속 말해주길 기다리고 있어.',
        translationStatus: ChatTranslationStatus.translated,
        createdAt: DateTime(2026, 6, 30, 20, 30, 45),
      ),
      ChatMessage(
        id: 3,
        senderId: 1,
        recipientId: 2,
        content: '알아 장난이야',
        createdAt: DateTime(2026, 6, 30, 20, 31, 10),
        readAt: DateTime(2026, 6, 30, 20, 33, 50),
      ),
      ChatMessage(
        id: 4,
        senderId: 1,
        recipientId: 2,
        content: '타이밍이 웃겨서',
        createdAt: DateTime(2026, 6, 30, 20, 31, 40),
        readAt: DateTime(2026, 6, 30, 20, 34, 10),
      ),
      ChatMessage(
        id: 5,
        senderId: 2,
        recipientId: 1,
        content: '抱歉啦欧巴',
        translatedContent: '미안해, 오빠.',
        translationStatus: ChatTranslationStatus.translated,
        createdAt: DateTime(2026, 6, 30, 20, 32, 5),
      ),
      ChatMessage(
        id: 6,
        senderId: 2,
        recipientId: 1,
        content: '我下次会好好说的',
        translationStatus: ChatTranslationStatus.failed,
        translationFailureReason: 'Network error',
        createdAt: DateTime(2026, 6, 30, 20, 32, 40),
      ),
      ChatMessage(
        id: 7,
        senderId: 1,
        recipientId: 2,
        content: '나 곧 탑승하는데',
        createdAt: DateTime(2026, 6, 30, 20, 34, 5),
      ),
      ChatMessage(
        id: 8,
        senderId: 1,
        recipientId: 2,
        content: '너는 계속 얘기해도 돼',
        createdAt: DateTime(2026, 6, 30, 20, 34, 45),
      ),
    ];
  }

  void _handleIncomingMessageTap(int messageId) {
    final ChatMessage? message = _findMessage(messageId);

    if (message == null) {
      return;
    }

    switch (message.translationStatus) {
      case ChatTranslationStatus.none:
        unawaited(_startTranslation(messageId));

      case ChatTranslationStatus.translated:
        if (message.translatedContent == null) {
          return;
        }

        setState(() {
          if (_showTranslatedMessageIds.contains(messageId)) {
            _showTranslatedMessageIds.remove(messageId);
          } else {
            _showTranslatedMessageIds.add(messageId);
          }
        });

      case ChatTranslationStatus.translating:
      case ChatTranslationStatus.failed:
        return;
    }
  }

  void _retryTranslation(int messageId) {
    unawaited(_startTranslation(messageId));
  }

  Future<void> _handleMessageLongPress(
    ChatMessage message,
    Rect bubbleRect,
    ui.Image bubbleImage,
  ) async {
    final List<ChatMessageAction> actions = availableChatMessageActions(
      isOutgoing: message.senderId == widget.currentUserId,
      createdAt: message.createdAt,
      now: _previewNow,
    );

    ChatMessageAction? selectedAction;

    try {
      selectedAction = await showGeneralDialog<ChatMessageAction>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Dismiss message actions',
        barrierColor: AppColors.black.withAlpha(31),
        transitionDuration: const Duration(milliseconds: 140),
        pageBuilder:
            (
              BuildContext context,
              Animation<double> primaryAnimation,
              Animation<double> secondaryAnimation,
            ) {
              return _MessageActionOverlay(
                actions: actions,
                bubbleRect: bubbleRect,
                bubbleImage: bubbleImage,
              );
            },
        transitionBuilder:
            (
              BuildContext context,
              Animation<double> primaryAnimation,
              Animation<double> secondaryAnimation,
              Widget child,
            ) {
              final Animation<double> curvedAnimation = CurvedAnimation(
                parent: primaryAnimation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );

              return FadeTransition(opacity: curvedAnimation, child: child);
            },
      );
    } finally {
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 160),
          bubbleImage.dispose,
        ),
      );
    }

    if (selectedAction == null || !mounted) {
      return;
    }

    switch (selectedAction) {
      case ChatMessageAction.copy:
        final String copiedContent =
            _showTranslatedMessageIds.contains(message.id)
            ? message.translatedContent!
            : message.content;

        await Clipboard.setData(ClipboardData(text: copiedContent));

        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Message copied')));
        return;

      case ChatMessageAction.reply:
      case ChatMessageAction.edit:
        return;

      case ChatMessageAction.unsend:
        _unsendMessage(message.id);
        return;
    }
  }

  void _unsendMessage(int messageId) {
    setState(() {
      _messages.removeWhere((ChatMessage message) => message.id == messageId);
      _showTranslatedMessageIds.remove(messageId);
      _messageBubbleKeys.remove(messageId);
    });
  }

  Future<void> _startTranslation(int messageId) async {
    final int messageIndex = _messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );

    if (messageIndex == -1) {
      return;
    }

    final ChatMessage currentMessage = _messages[messageIndex];

    if (currentMessage.translationStatus == ChatTranslationStatus.translating) {
      return;
    }

    setState(() {
      _showTranslatedMessageIds.remove(messageId);

      _messages[messageIndex] = currentMessage.copyWith(
        translationStatus: ChatTranslationStatus.translating,
        clearTranslationFailureReason: true,
      );
    });

    await Future<void>.delayed(_previewTranslationDelay);

    if (!mounted) {
      return;
    }

    final int refreshedIndex = _messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );

    if (refreshedIndex == -1) {
      return;
    }

    final String? translatedContent = _previewTranslations[messageId];

    if (translatedContent == null) {
      setState(() {
        _messages[refreshedIndex] = _messages[refreshedIndex].copyWith(
          translationStatus: ChatTranslationStatus.failed,
          translationFailureReason: 'Translation unavailable',
        );
      });

      return;
    }

    setState(() {
      _messages[refreshedIndex] = _messages[refreshedIndex].copyWith(
        translationStatus: ChatTranslationStatus.translated,
        translatedContent: translatedContent,
        clearTranslationFailureReason: true,
      );

      _showTranslatedMessageIds.add(messageId);
    });
  }

  GlobalKey _messageBubbleKeyFor(int messageId) {
    return _messageBubbleKeys.putIfAbsent(messageId, () => GlobalKey());
  }

  ChatMessage? _findMessage(int messageId) {
    for (final ChatMessage message in _messages) {
      if (message.id == messageId) {
        return message;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final List<ChatMessageGroup> groups = groupChatMessages(_messages);

    final int? latestReadMessageId = findLatestReadOutgoingMessageId(
      messages: _messages,
      currentUserId: widget.currentUserId,
    );

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: _buildTimeline(
        groups: groups,
        latestReadMessageId: latestReadMessageId,
      ),
    );
  }

  List<Widget> _buildTimeline({
    required List<ChatMessageGroup> groups,
    required int? latestReadMessageId,
  }) {
    final List<Widget> timeline = [];

    for (int index = 0; index < groups.length; index++) {
      final ChatMessageGroup group = groups[index];

      final bool startsNewDate =
          index == 0 ||
          !isSameChatDate(groups[index - 1].createdAt, group.createdAt);

      if (startsNewDate) {
        timeline.add(_DateSeparator(date: group.createdAt));

        timeline.add(const SizedBox(height: 18));
      }

      timeline.add(
        _MessageGroup(
          group: group,
          currentUserId: widget.currentUserId,
          latestReadMessageId: latestReadMessageId,
          now: _previewNow,
          shownTranslatedMessageIds: _showTranslatedMessageIds,
          onIncomingMessageTap: _handleIncomingMessageTap,
          onRetryTranslation: _retryTranslation,
          onMessageLongPress: _handleMessageLongPress,
          messageBubbleKeyFor: _messageBubbleKeyFor,
        ),
      );

      if (index != groups.length - 1) {
        final bool nextGroupStartsNewDate = !isSameChatDate(
          group.createdAt,
          groups[index + 1].createdAt,
        );

        timeline.add(SizedBox(height: nextGroupStartsNewDate ? 18 : 14));
      }
    }

    return timeline;
  }
}

final class _MessageActionOverlay extends StatelessWidget {
  const _MessageActionOverlay({
    required this.actions,
    required this.bubbleRect,
    required this.bubbleImage,
  });

  final List<ChatMessageAction> actions;
  final Rect bubbleRect;
  final ui.Image bubbleImage;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: bubbleRect,
            child: IgnorePointer(
              child: RawImage(
                key: const ValueKey<String>('selected-message-preview'),
                image: bubbleImage,
                fit: BoxFit.fill,
              ),
            ),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _MessageActionMenuLayoutDelegate(
                bubbleRect: bubbleRect,
                safePadding: MediaQuery.paddingOf(context),
              ),
              child: _MessageActionMenu(actions: actions),
            ),
          ),
        ],
      ),
    );
  }
}

final class _MessageActionMenuLayoutDelegate extends SingleChildLayoutDelegate {
  const _MessageActionMenuLayoutDelegate({
    required this.bubbleRect,
    required this.safePadding,
  });

  static const double _horizontalMargin = 16;
  static const double _verticalMargin = 8;
  static const double _bubbleGap = 6;
  static const double _maxWidth = 288;

  final Rect bubbleRect;
  final EdgeInsets safePadding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double width = math.min(
      _maxWidth,
      constraints.maxWidth - (_horizontalMargin * 2),
    );

    return BoxConstraints.tightFor(width: width);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double left = (size.width - childSize.width) / 2;
    final double minimumTop = safePadding.top + _verticalMargin;
    final double maximumBottom =
        size.height - safePadding.bottom - _verticalMargin;
    final double belowTop = bubbleRect.bottom + _bubbleGap;

    final double top = belowTop + childSize.height <= maximumBottom
        ? belowTop
        : math.max(minimumTop, bubbleRect.top - _bubbleGap - childSize.height);

    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_MessageActionMenuLayoutDelegate oldDelegate) {
    return oldDelegate.bubbleRect != bubbleRect ||
        oldDelegate.safePadding != safePadding;
  }
}

final class _MessageActionMenu extends StatelessWidget {
  const _MessageActionMenu({required this.actions});

  final List<ChatMessageAction> actions;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('message-action-menu'),
      color: AppColors.white,
      elevation: 4,
      shadowColor: AppColors.black.withAlpha(31),
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int index = 0; index < actions.length; index++) ...[
            _MessageActionMenuItem(action: actions[index]),
            if (index != actions.length - 1)
              const Divider(height: 1, thickness: 1, color: AppColors.grey100),
          ],
        ],
      ),
    );
  }
}

final class _MessageActionMenuItem extends StatelessWidget {
  const _MessageActionMenuItem({required this.action});

  final ChatMessageAction action;

  @override
  Widget build(BuildContext context) {
    final Color foregroundColor = action == ChatMessageAction.unsend
        ? AppColors.red500
        : AppColors.grey900;

    return InkWell(
      key: ValueKey<String>('message-action-${action.name}'),
      onTap: () {
        Navigator.of(context).pop(action);
      },
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  action.label,
                  style: AppTypography.typography6.copyWith(
                    color: foregroundColor,
                    fontWeight: AppTypography.regular,
                  ),
                ),
              ),
              Icon(
                action.icon,
                size: 20,
                color: action == ChatMessageAction.unsend
                    ? AppColors.red500
                    : AppColors.grey700,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on ChatMessageAction {
  String get label {
    return switch (this) {
      ChatMessageAction.copy => 'Copy',
      ChatMessageAction.reply => 'Reply',
      ChatMessageAction.edit => 'Edit',
      ChatMessageAction.unsend => 'Unsend',
    };
  }

  IconData get icon {
    return switch (this) {
      ChatMessageAction.copy => Icons.copy_outlined,
      ChatMessageAction.reply => Icons.reply_rounded,
      ChatMessageAction.edit => Icons.edit_outlined,
      ChatMessageAction.unsend => Icons.delete_outline_rounded,
    };
  }
}

final class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        key: const ValueKey<String>('chat-date-separator'),
        decoration: const BoxDecoration(
          color: AppColors.grey100,
          borderRadius: AppRadius.borderRadiusFull,
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 7, top: 3, bottom: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatChatDate(date),
                style: AppTypography.typography7.copyWith(
                  color: AppColors.grey700,
                  fontWeight: AppTypography.regular,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: AppColors.grey600,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _MessageGroup extends StatelessWidget {
  const _MessageGroup({
    required this.group,
    required this.currentUserId,
    required this.latestReadMessageId,
    required this.now,
    required this.shownTranslatedMessageIds,
    required this.onIncomingMessageTap,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.messageBubbleKeyFor,
  });

  final ChatMessageGroup group;
  final int currentUserId;
  final int? latestReadMessageId;
  final DateTime now;
  final Set<int> shownTranslatedMessageIds;
  final ValueChanged<int> onIncomingMessageTap;
  final ValueChanged<int> onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _MessageBubbleKeyFor messageBubbleKeyFor;

  @override
  Widget build(BuildContext context) {
    if (group.senderId == currentUserId) {
      return _OutgoingMessageGroup(
        messages: group.messages,
        latestReadMessageId: latestReadMessageId,
        now: now,
        onMessageLongPress: onMessageLongPress,
        messageBubbleKeyFor: messageBubbleKeyFor,
      );
    }

    return _IncomingMessageGroup(
      messages: group.messages,
      shownTranslatedMessageIds: shownTranslatedMessageIds,
      onIncomingMessageTap: onIncomingMessageTap,
      onRetryTranslation: onRetryTranslation,
      onMessageLongPress: onMessageLongPress,
      messageBubbleKeyFor: messageBubbleKeyFor,
    );
  }
}

final class _IncomingMessageGroup extends StatelessWidget {
  const _IncomingMessageGroup({
    required this.messages,
    required this.shownTranslatedMessageIds,
    required this.onIncomingMessageTap,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.messageBubbleKeyFor,
  });

  final List<ChatMessage> messages;
  final Set<int> shownTranslatedMessageIds;
  final ValueChanged<int> onIncomingMessageTap;
  final ValueChanged<int> onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _MessageBubbleKeyFor messageBubbleKeyFor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: _ProfilePlaceholder(),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int index = 0; index < messages.length; index++) ...[
                _IncomingMessageRow(
                  message: messages[index],
                  showTail: index == 0,
                  showTime: index == messages.length - 1,
                  showTranslation: shownTranslatedMessageIds.contains(
                    messages[index].id,
                  ),
                  onMessageTap: () {
                    onIncomingMessageTap(messages[index].id);
                  },
                  onRetryTranslation: () {
                    onRetryTranslation(messages[index].id);
                  },
                  onMessageLongPress: onMessageLongPress,
                  bubbleInteractionKey: messageBubbleKeyFor(messages[index].id),
                ),
                if (index != messages.length - 1) const SizedBox(height: 5),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

final class _IncomingMessageRow extends StatelessWidget {
  const _IncomingMessageRow({
    required this.message,
    required this.showTail,
    required this.showTime,
    required this.showTranslation,
    required this.onMessageTap,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.bubbleInteractionKey,
  });

  final ChatMessage message;
  final bool showTail;
  final bool showTime;
  final bool showTranslation;
  final VoidCallback onMessageTap;
  final VoidCallback onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final GlobalKey bubbleInteractionKey;

  @override
  Widget build(BuildContext context) {
    final bool canTapBubble =
        message.translationStatus == ChatTranslationStatus.none ||
        message.translationStatus == ChatTranslationStatus.translated;

    Widget bubble = _MessageBubble(
      measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
      backgroundColor: AppColors.grey100,
      direction: _BubbleDirection.incoming,
      showTail: showTail,
      child: _IncomingMessageContent(
        message: message,
        showTranslation: showTranslation,
        onRetryTranslation: onRetryTranslation,
      ),
    );

    bubble = _MessageCaptureBoundary(
      key: bubbleInteractionKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTapBubble ? onMessageTap : null,
        onLongPress: () {
          unawaited(
            _handleMessageBubbleLongPress(
              context: context,
              bubbleKey: bubbleInteractionKey,
              message: message,
              onMessageLongPress: onMessageLongPress,
            ),
          );
        },
        child: bubble,
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(fit: FlexFit.loose, child: bubble),
        if (showTime) ...[
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: _MessageTime(createdAt: message.createdAt),
          ),
        ],
      ],
    );
  }
}

final class _IncomingMessageContent extends StatelessWidget {
  const _IncomingMessageContent({
    required this.message,
    required this.showTranslation,
    required this.onRetryTranslation,
  });

  final ChatMessage message;
  final bool showTranslation;
  final VoidCallback onRetryTranslation;

  @override
  Widget build(BuildContext context) {
    final TextStyle messageTextStyle = AppTypography.subTypography10.copyWith(
      color: AppColors.grey900,
      fontWeight: AppTypography.regular,
    );

    final bool hasCompletedTranslation =
        message.translationStatus == ChatTranslationStatus.translated &&
        message.translatedContent != null;

    final Widget messageText;

    if (hasCompletedTranslation) {
      messageText = _AnimatedTranslationText(
        messageId: message.id,
        originalContent: message.content,
        translatedContent: message.translatedContent!,
        showTranslation: showTranslation,
        style: messageTextStyle,
      );
    } else {
      messageText = Text(
        message.content,
        key: ValueKey<String>('original-message-${message.id}'),
        softWrap: true,
        strutStyle: _buildMessageStrutStyle(messageTextStyle),
        textHeightBehavior: _messageTextHeightBehavior,
        style: messageTextStyle,
      );
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          messageText,
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (Widget child, Animation<double> animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: _buildTranslationStatus(context),
          ),
        ],
      ),
    );
  }

  Widget _buildTranslationStatus(BuildContext context) {
    switch (message.translationStatus) {
      case ChatTranslationStatus.translating:
        return Padding(
          key: ValueKey<String>('translation-loading-${message.id}'),
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.grey500,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                'Translating…',
                style: AppTypography.subTypography12.copyWith(
                  color: AppColors.grey500,
                  fontWeight: AppTypography.regular,
                ),
              ),
            ],
          ),
        );

      case ChatTranslationStatus.failed:
        return Padding(
          key: ValueKey<String>('translation-failed-${message.id}'),
          padding: const EdgeInsets.only(top: 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Translation failed: '
                '${message.translationFailureReason ?? 'Unknown error'}',
                style: AppTypography.subTypography12.copyWith(
                  color: AppColors.grey600,
                  fontWeight: AppTypography.regular,
                ),
              ),
              const SizedBox(height: 2),
              TextButton(
                onPressed: onRetryTranslation,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.blue500,
                  minimumSize: Size.zero,
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(
                  'Retry',
                  style: AppTypography.subTypography12.copyWith(
                    color: AppColors.blue500,
                    fontWeight: AppTypography.medium,
                  ),
                ),
              ),
            ],
          ),
        );

      case ChatTranslationStatus.none:
      case ChatTranslationStatus.translated:
        return SizedBox.shrink(
          key: ValueKey<String>('translation-idle-${message.id}'),
        );
    }
  }
}

final class _AnimatedTranslationText extends StatelessWidget {
  const _AnimatedTranslationText({
    required this.messageId,
    required this.originalContent,
    required this.translatedContent,
    required this.showTranslation,
    required this.style,
  });

  final int messageId;
  final String originalContent;
  final String translatedContent;
  final bool showTranslation;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final String displayedContent = showTranslation
        ? translatedContent
        : originalContent;

    final String displayedKey = showTranslation
        ? 'translated-message-$messageId'
        : 'original-message-$messageId';

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
        return Stack(
          alignment: Alignment.topLeft,
          children: [...previousChildren, ?currentChild],
        );
      },
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: Text(
        displayedContent,
        key: ValueKey<String>(displayedKey),
        softWrap: true,
        strutStyle: _buildMessageStrutStyle(style),
        textHeightBehavior: _messageTextHeightBehavior,
        style: style,
      ),
    );
  }
}

final class _OutgoingMessageGroup extends StatelessWidget {
  const _OutgoingMessageGroup({
    required this.messages,
    required this.latestReadMessageId,
    required this.now,
    required this.onMessageLongPress,
    required this.messageBubbleKeyFor,
  });

  final List<ChatMessage> messages;
  final int? latestReadMessageId;
  final DateTime now;
  final _MessageLongPressCallback onMessageLongPress;
  final _MessageBubbleKeyFor messageBubbleKeyFor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (int index = 0; index < messages.length; index++) ...[
          _OutgoingMessageRow(
            message: messages[index],
            showTail: index == 0,
            showTime: index == messages.length - 1,
            onMessageLongPress: onMessageLongPress,
            bubbleInteractionKey: messageBubbleKeyFor(messages[index].id),
          ),
          if (messages[index].id == latestReadMessageId) ...[
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.only(right: _messageHorizontalPadding),
              child: Text(
                formatReadReceipt(readAt: messages[index].readAt!, now: now),
                textAlign: TextAlign.right,
                style: AppTypography.subTypography12.copyWith(
                  color: AppColors.grey500,
                  fontWeight: AppTypography.medium,
                ),
              ),
            ),
          ],
          if (index != messages.length - 1) const SizedBox(height: 5),
        ],
      ],
    );
  }
}

final class _OutgoingMessageRow extends StatelessWidget {
  const _OutgoingMessageRow({
    required this.message,
    required this.showTail,
    required this.showTime,
    required this.onMessageLongPress,
    required this.bubbleInteractionKey,
  });

  final ChatMessage message;
  final bool showTail;
  final bool showTime;
  final _MessageLongPressCallback onMessageLongPress;
  final GlobalKey bubbleInteractionKey;

  @override
  Widget build(BuildContext context) {
    final TextStyle messageTextStyle = AppTypography.subTypography10.copyWith(
      color: AppColors.white,
      fontWeight: AppTypography.regular,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showTime) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: _MessageTime(createdAt: message.createdAt),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          fit: FlexFit.loose,
          child: _MessageCaptureBoundary(
            key: bubbleInteractionKey,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () {
                unawaited(
                  _handleMessageBubbleLongPress(
                    context: context,
                    bubbleKey: bubbleInteractionKey,
                    message: message,
                    onMessageLongPress: onMessageLongPress,
                  ),
                );
              },
              child: _MessageBubble(
                measurementKey: ValueKey<String>(
                  'outgoing-bubble-${message.id}',
                ),
                backgroundColor: AppColors.blue500,
                direction: _BubbleDirection.outgoing,
                showTail: showTail,
                child: Text(
                  message.content,
                  softWrap: true,
                  strutStyle: _buildMessageStrutStyle(messageTextStyle),
                  textHeightBehavior: _messageTextHeightBehavior,
                  style: messageTextStyle,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _BubbleDirection { incoming, outgoing }

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.backgroundColor,
    required this.direction,
    required this.showTail,
    required this.child,
    this.measurementKey,
  });

  final Color backgroundColor;
  final _BubbleDirection direction;
  final bool showTail;
  final Widget child;
  final Key? measurementKey;

  bool get _isOutgoing {
    return direction == _BubbleDirection.outgoing;
  }

  @override
  Widget build(BuildContext context) {
    final double maxWidth = MediaQuery.sizeOf(context).width * 0.68;

    return Stack(
      key: measurementKey,
      clipBehavior: Clip.none,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(!_isOutgoing && showTail ? 6 : 17),
                topRight: Radius.circular(_isOutgoing && showTail ? 6 : 17),
                bottomLeft: const Radius.circular(17),
                bottomRight: const Radius.circular(17),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _messageHorizontalPadding,
                vertical: 6,
              ),
              child: child,
            ),
          ),
        ),
        if (showTail)
          Positioned(
            top: 3,
            left: _isOutgoing ? null : -7,
            right: _isOutgoing ? -7 : null,
            child: CustomPaint(
              size: const Size(12, 13),
              painter: _BubbleTailPainter(
                color: backgroundColor,
                direction: direction,
              ),
            ),
          ),
      ],
    );
  }
}

final class _BubbleTailPainter extends CustomPainter {
  const _BubbleTailPainter({required this.color, required this.direction});

  final Color color;
  final _BubbleDirection direction;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final Path path = Path();

    if (direction == _BubbleDirection.incoming) {
      path
        ..moveTo(size.width, 0)
        ..lineTo(0, 2)
        ..quadraticBezierTo(
          size.width * 0.42,
          size.height * 0.38,
          size.width,
          size.height,
        )
        ..close();
    } else {
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 2)
        ..quadraticBezierTo(
          size.width * 0.58,
          size.height * 0.38,
          0,
          size.height,
        )
        ..close();
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BubbleTailPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.direction != direction;
  }
}

final class _ProfilePlaceholder extends StatelessWidget {
  const _ProfilePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.blue100,
        borderRadius: BorderRadius.all(Radius.circular(13)),
      ),
      child: SizedBox.square(
        dimension: 38,
        child: Icon(Icons.person_rounded, color: AppColors.white, size: 23),
      ),
    );
  }
}

final class _MessageTime extends StatelessWidget {
  const _MessageTime({required this.createdAt});

  final DateTime createdAt;

  @override
  Widget build(BuildContext context) {
    final DateTime localCreatedAt = createdAt.toLocal();

    final String formattedTime = MaterialLocalizations.of(context)
        .formatTimeOfDay(
          TimeOfDay.fromDateTime(localCreatedAt),
          alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
        );

    return Text(
      formattedTime,
      style: AppTypography.subTypography12.copyWith(color: AppColors.grey500),
    );
  }
}

final class _MessageComposer extends StatelessWidget {
  const _MessageComposer();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.grey50,
          borderRadius: AppRadius.borderRadiusFull,
          border: Border.all(color: AppColors.grey200),
        ),
        child: SizedBox(
          height: 50,
          child: Row(
            children: [
              const SizedBox(width: 3),
              IconButton(
                tooltip: 'Attachments',
                onPressed: null,
                icon: const Icon(
                  Icons.add_rounded,
                  size: 29,
                  color: AppColors.grey700,
                ),
              ),
              Expanded(
                child: Text(
                  'Enter a message',
                  style: AppTypography.subTypography10.copyWith(
                    color: AppColors.grey500,
                  ),
                ),
              ),
              const IconButton(
                tooltip: 'Send',
                onPressed: null,
                icon: Icon(
                  Icons.arrow_upward_rounded,
                  size: 24,
                  color: AppColors.grey300,
                ),
              ),
              const SizedBox(width: 3),
            ],
          ),
        ),
      ),
    );
  }
}
