import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../../design_system/app_colors.dart';
import '../../../design_system/app_radius.dart';
import '../../../design_system/app_typography.dart';
import '../data/chat_photo_library.dart';
import '../domain/chat_message_action.dart';
import '../domain/chat_message.dart';
import '../domain/chat_message_group.dart';
import '../domain/chat_message_grouper.dart';
import 'chat_date_formatter.dart';
import 'chat_photo_picker.dart';
import 'read_receipt_formatter.dart';

const double _messageHorizontalPadding = 11;

const double _messageToComposerGap = 12;

const double _attachmentPanelFallbackHeight = 302;

const Duration _bottomSurfaceAnimationDuration = Duration(milliseconds: 180);

typedef _MessageLongPressCallback =
    Future<void> Function(ChatMessage message, GlobalKey bubbleKey);

typedef _MessageBubbleKeyFor = GlobalKey Function(int messageId);

typedef _ReplyQuoteTapCallback =
    Future<void> Function({
      required int replyMessageId,
      required int originalMessageId,
    });

typedef _ReplySelectedCallback =
    void Function(ChatMessage message, String displayedContent);

typedef _EditSelectedCallback = void Function(ChatMessage message);

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

final class ChatStylePreviewScreen extends StatefulWidget {
  const ChatStylePreviewScreen({super.key, this.photoLibrary});

  final ChatPhotoLibrary? photoLibrary;

  static const int _currentUserId = 1;
  static const int _otherParticipantId = 2;
  static const String _otherParticipantName = 'Lia';
  static const Color _chatBackgroundColor = AppColors.white;

  @override
  State<ChatStylePreviewScreen> createState() {
    return _ChatStylePreviewScreenState();
  }
}

final class _ChatStylePreviewScreenState extends State<ChatStylePreviewScreen>
    with WidgetsBindingObserver {
  final GlobalKey<_MessageListState> _messageListKey =
      GlobalKey<_MessageListState>();

  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final GlobalKey _messageInputHostKey = GlobalKey();
  final GlobalKey _composerMeasureKey = GlobalKey();

  late final ChatPhotoLibrary _photoLibrary;

  ChatMessage? _replyingToMessage;
  String? _replyingToContent;
  ChatMessage? _editingMessage;
  String? _editingOriginalContent;

  Timer? _keyboardTransitionTimer;
  Timer? _composerResizeTimer;
  Timer? _bottomSurfaceHoldTimer;

  bool _keyboardTransitionActive = false;
  bool _pinBottomDuringComposerResize = false;

  bool _attachmentPanelOpen = false;
  bool _photoPickerOpen = false;

  bool _photoPickerExpanded = false;
  bool _photoPickerDragging = false;

  double? _photoPickerCollapsedHeight;
  double? _photoPickerHeight;

  double _lastKeyboardHeight = _attachmentPanelFallbackHeight;

  double? _heldBottomSurfaceHeight;

  @override
  void initState() {
    super.initState();

    _photoLibrary = widget.photoLibrary ?? PhotoManagerChatPhotoLibrary();

    WidgetsBinding.instance.addObserver(this);
    _messageFocusNode.addListener(_handleMessageFocusChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _messageFocusNode.removeListener(_handleMessageFocusChanged);

    _keyboardTransitionTimer?.cancel();
    _composerResizeTimer?.cancel();
    _bottomSurfaceHoldTimer?.cancel();

    _messageController.dispose();
    _messageFocusNode.dispose();

    super.dispose();
  }

  double _currentKeyboardHeight() {
    final ui.FlutterView view = View.of(context);

    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  void _startBottomSurfacePinIfNeeded() {
    final _MessageListState? messageListState = _messageListKey.currentState;

    _stopComposerResizePin();

    if (messageListState == null || messageListState.isNearBottom) {
      _startComposerResizePin();
    }
  }

  void _scheduleBottomSurfaceHoldRelease() {
    _bottomSurfaceHoldTimer?.cancel();

    _bottomSurfaceHoldTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted || _heldBottomSurfaceHeight == null) {
        return;
      }

      setState(() {
        _heldBottomSurfaceHeight = null;
      });
    });
  }

  void _closeAttachmentPanelForKeyboard() {
    if (!_attachmentPanelOpen) {
      return;
    }

    _startBottomSurfacePinIfNeeded();
    _bottomSurfaceHoldTimer?.cancel();

    setState(() {
      _attachmentPanelOpen = false;

      // 키보드가 나타나는 동안 작성창 높이가 먼저 내려가지 않도록
      // 기존 첨부 패널 높이를 잠시 유지한다.
      _heldBottomSurfaceHeight = _lastKeyboardHeight;
    });

    _scheduleBottomSurfaceHoldRelease();
  }

  void _openAttachmentPanel() {
    if (_attachmentPanelOpen) {
      return;
    }

    final double keyboardHeight = _currentKeyboardHeight();

    _stopKeyboardTransition();
    _startBottomSurfacePinIfNeeded();
    _bottomSurfaceHoldTimer?.cancel();

    setState(() {
      if (keyboardHeight > 0.5) {
        _lastKeyboardHeight = keyboardHeight;
      }

      _heldBottomSurfaceHeight = null;
      _photoPickerOpen = false;
      _attachmentPanelOpen = true;
    });

    // 입력 내용은 지우지 않고 포커스와 키보드만 내린다.
    _messageFocusNode.unfocus();
  }

  void _closeAttachmentPanelToDefault() {
    if (!_attachmentPanelOpen &&
        !_photoPickerOpen &&
        _heldBottomSurfaceHeight == null) {
      return;
    }

    _startBottomSurfacePinIfNeeded();
    _bottomSurfaceHoldTimer?.cancel();

    setState(_resetBottomSurfaceState);
  }

  void _handleAttachmentButtonPressed() {
    if (_attachmentPanelOpen) {
      _closeAttachmentPanelForKeyboard();
      _messageFocusNode.requestFocus();
      return;
    }

    _openAttachmentPanel();
  }

  void _openPhotoPicker() {
    if (!_attachmentPanelOpen ||
        _photoPickerOpen) {
      return;
    }

    final BuildContext? composerContext =
        _composerMeasureKey.currentContext;

    final RenderObject? renderObject =
        composerContext?.findRenderObject();

    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) {
          if (mounted) {
            _openPhotoPicker();
          }
        },
      );

      return;
    }

    final double attachmentPanelHeight =
        math.max(
          _lastKeyboardHeight,
          MediaQuery.viewPaddingOf(context).bottom,
        );

    // Photo 선택기의 최초 높이는 임의 비율이 아니라
    // 현재 작성창 + 현재 첨부 패널의 실제 합산 높이다.
    //
    // 따라서 Photo로 전환해도 패널의 위쪽 경계가
    // 기존 입력창 위쪽 경계와 정확히 같은 위치에 남는다.
    final double collapsedHeight =
        renderObject.size.height +
        attachmentPanelHeight;

    _startBottomSurfacePinIfNeeded();

    setState(() {
      _attachmentPanelOpen = false;
      _photoPickerOpen = true;

      _photoPickerExpanded = false;
      _photoPickerDragging = false;

      _photoPickerCollapsedHeight =
          collapsedHeight;

      _photoPickerHeight = collapsedHeight;

      _heldBottomSurfaceHeight = null;
    });
  }

  void _closePhotoPicker() {
    if (!_photoPickerOpen) {
      return;
    }

    _startBottomSurfacePinIfNeeded();

    setState(() {
      _photoPickerOpen = false;
      _attachmentPanelOpen = true;

      _photoPickerExpanded = false;
      _photoPickerDragging = false;

      _photoPickerCollapsedHeight = null;
      _photoPickerHeight = null;
    });
  }

  void _handlePhotoPickerDragStart(
    DragStartDetails details,
  ) {
    if (!_photoPickerOpen) {
      return;
    }

    setState(() {
      _photoPickerDragging = true;
    });
  }

  void _handlePhotoPickerDragUpdate(
    DragUpdateDetails details, {
    required double maximumHeight,
  }) {
    final double? currentHeight =
        _photoPickerHeight;

    final double? collapsedHeight =
        _photoPickerCollapsedHeight;

    if (!_photoPickerOpen ||
        currentHeight == null ||
        collapsedHeight == null) {
      return;
    }

    final double nextHeight =
        (currentHeight - details.delta.dy)
            .clamp(
              collapsedHeight,
              maximumHeight,
            )
            .toDouble();

    setState(() {
      _photoPickerHeight = nextHeight;

      _photoPickerExpanded =
          nextHeight >
          collapsedHeight + 32;
    });
  }

  void _handlePhotoPickerDragEnd(
    DragEndDetails details, {
    required double maximumHeight,
  }) {
    final double? currentHeight =
        _photoPickerHeight;

    final double? collapsedHeight =
        _photoPickerCollapsedHeight;

    if (!_photoPickerOpen ||
        currentHeight == null ||
        collapsedHeight == null) {
      return;
    }

    final double velocity =
        details.primaryVelocity ?? 0;

    final double expansionThreshold =
        collapsedHeight +
        ((maximumHeight - collapsedHeight) *
            0.34);

    final bool shouldExpand;

    if (velocity <= -300) {
      shouldExpand = true;
    } else if (velocity >= 300) {
      shouldExpand = false;
    } else {
      shouldExpand =
          currentHeight >= expansionThreshold;
    }

    setState(() {
      _photoPickerDragging = false;
      _photoPickerExpanded = shouldExpand;

      _photoPickerHeight = shouldExpand
          ? maximumHeight
          : collapsedHeight;
    });
  }

  // 첨부 패널·Photo 선택기를 모두 닫고 Photo 크기 상태를 초기화한다.
  void _resetBottomSurfaceState() {
    _attachmentPanelOpen = false;
    _photoPickerOpen = false;
    _photoPickerExpanded = false;
    _photoPickerDragging = false;
    _photoPickerCollapsedHeight = null;
    _photoPickerHeight = null;
    _heldBottomSurfaceHeight = null;
  }

  // 사진 전송 직후 진행 중인 전환·타이머를 정리하고
  // 하단 서피스를 닫은 뒤 최신 메시지로 스크롤한다.
  void _dismissComposerAfterPhotoSend() {
    _stopKeyboardTransition();
    _stopComposerResizePin();
    _bottomSurfaceHoldTimer?.cancel();

    _messageFocusNode.unfocus();

    setState(_resetBottomSurfaceState);

    _scheduleScrollToBottom(animate: true);
  }

  Future<void> _sendSelectedPhotos(ChatPhotoSelectionResult result) async {
    final List<ChatPhotoAttachment?> loadedAttachments =
        await Future.wait<ChatPhotoAttachment?>(
          result.assets.map((ChatPhotoAsset asset) async {
            final bytes = await _photoLibrary.loadMessagePreview(
              assetId: asset.id,
            );

            if (bytes == null) {
              return null;
            }

            return ChatPhotoAttachment(
              assetId: asset.id,
              previewBytes: bytes,
              width: asset.width,
              height: asset.height,
            );
          }),
        );

    if (!mounted) {
      return;
    }

    final List<ChatPhotoAttachment> attachments = loadedAttachments
        .whereType<ChatPhotoAttachment>()
        .toList(growable: false);

    if (attachments.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('The selected photos could not be loaded.'),
          ),
        );

      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    messageListState.addOutgoingPhotoMessages(
      attachments: attachments,
      collage: result.collage,
    );

    _dismissComposerAfterPhotoSend();
  }

  Future<void> _openCamera() async {
    final ImagePicker picker = ImagePicker();

    // image_picker가 기기의 기본 카메라 앱을 실행한다.
    // iOS는 최초 1회만 시스템 카메라 권한 팝업을 띄우고 결과를 기억하며,
    // Android는 카메라 앱에 위임하므로 앱 차원의 반복 권한 요청이 없다.
    XFile? capture;

    try {
      capture = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
        maxWidth: 1920,
      );
    } on PlatformException catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('The camera is not available.'),
          ),
        );

      return;
    }

    // 사용자가 촬영을 취소하면 아무것도 전송하지 않는다.
    if (!mounted || capture == null) {
      return;
    }

    final Uint8List bytes = await capture.readAsBytes();

    if (!mounted) {
      return;
    }

    int width = 0;
    int height = 0;

    try {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();

      width = frame.image.width;
      height = frame.image.height;

      frame.image.dispose();
      codec.dispose();
    } catch (_) {
      // 디코딩에 실패해도 전송은 진행한다.
    }

    if (!mounted) {
      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    messageListState.addOutgoingPhotoMessages(
      attachments: <ChatPhotoAttachment>[
        ChatPhotoAttachment(
          assetId: 'camera-${capture.name}',
          previewBytes: bytes,
          width: width > 0 ? width : 1080,
          height: height > 0 ? height : 1440,
        ),
      ],
      collage: false,
    );

    _dismissComposerAfterPhotoSend();
  }

  void _handleMessageInputTap() {
    if (_attachmentPanelOpen) {
      _closeAttachmentPanelForKeyboard();
    }
  }

  void _handleMessageFocusChanged() {
    if (!_messageFocusNode.hasFocus) {
      return;
    }

    // 첨부 패널 상태에서 입력창을 직접 탭한 경우에도
    // × 버튼과 동일하게 키보드 상태로 전환한다.
    if (_attachmentPanelOpen) {
      _closeAttachmentPanelForKeyboard();
    }

    if (_keyboardTransitionActive) {
      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null || !messageListState.isNearBottom) {
      return;
    }

    _startKeyboardTransition();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }

    final double keyboardHeight = _currentKeyboardHeight();

    // 첨부 패널을 띄운 채 키보드가 내려가는 중간 높이는
    // 저장하지 않는다. 완전히 열린 키보드 높이만 사용한다.
    if (keyboardHeight > 0.5 && !_attachmentPanelOpen) {
      _lastKeyboardHeight = keyboardHeight;
    }

    final double? heldHeight = _heldBottomSurfaceHeight;

    if (heldHeight != null && keyboardHeight >= heldHeight - 1) {
      _bottomSurfaceHoldTimer?.cancel();
      _bottomSurfaceHoldTimer = null;

      setState(() {
        _heldBottomSurfaceHeight = null;
      });
    }

    if (!_keyboardTransitionActive) {
      return;
    }

    _keyboardTransitionTimer?.cancel();
    _keyboardTransitionTimer = Timer(
      const Duration(milliseconds: 300),
      _finishKeyboardTransition,
    );

    _scheduleKeyboardViewportUpdate(animate: false);
  }

  void _startKeyboardTransition({bool animateInitialScroll = false}) {
    _keyboardTransitionActive = true;

    _keyboardTransitionTimer?.cancel();
    _keyboardTransitionTimer = Timer(
      const Duration(milliseconds: 500),
      _finishKeyboardTransition,
    );

    _scheduleKeyboardViewportUpdate(animate: animateInitialScroll);
  }

  void _finishKeyboardTransition() {
    _keyboardTransitionTimer?.cancel();
    _keyboardTransitionTimer = null;

    _keyboardTransitionActive = false;
  }

  void _stopKeyboardTransition() {
    _finishKeyboardTransition();
  }

  void _scheduleKeyboardViewportUpdate({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_keyboardTransitionActive) {
        return;
      }

      final _MessageListState? messageListState = _messageListKey.currentState;

      if (messageListState == null) {
        return;
      }

      unawaited(messageListState.scrollToBottom(animate: animate));
    });
  }

  void _scheduleScrollToBottom({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      final _MessageListState? messageListState = _messageListKey.currentState;

      if (messageListState == null) {
        return;
      }

      unawaited(messageListState.scrollToBottom(animate: animate));
    });
  }

  void _startComposerResizePin() {
    _pinBottomDuringComposerResize = true;

    _composerResizeTimer?.cancel();
    _composerResizeTimer = Timer(const Duration(milliseconds: 260), () {
      _pinBottomDuringComposerResize = false;
    });
  }

  void _stopComposerResizePin() {
    _composerResizeTimer?.cancel();
    _composerResizeTimer = null;

    _pinBottomDuringComposerResize = false;
  }

  void _handleComposerTextChanged(String value) {
    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null || !messageListState.isNearBottom) {
      return;
    }

    _startComposerResizePin();
  }

  bool _handleComposerSizeChanged(SizeChangedLayoutNotification notification) {
    if (_keyboardTransitionActive) {
      _scheduleKeyboardViewportUpdate(animate: false);

      return false;
    }

    if (_pinBottomDuringComposerResize) {
      _scheduleScrollToBottom(animate: false);
    }

    return false;
  }

  void _dismissComposerSurface() {
    _stopKeyboardTransition();
    _stopComposerResizePin();

    _messageFocusNode.unfocus();
    _closeAttachmentPanelToDefault();
  }

  Future<void> _prepareMessageActions() async {
    _stopKeyboardTransition();
    _stopComposerResizePin();

    final bool keyboardWasVisible = _currentKeyboardHeight() > 0.5;

    final bool customBottomSurfaceWasOpen =
        _attachmentPanelOpen || _photoPickerOpen;

    final bool hadHeldBottomSurface = _heldBottomSurfaceHeight != null;

    _bottomSurfaceHoldTimer?.cancel();
    _bottomSurfaceHoldTimer = null;

    _messageFocusNode.unfocus();

    if (customBottomSurfaceWasOpen || hadHeldBottomSurface) {
      setState(_resetBottomSurfaceState);
    }

    // 첨부 패널의 180ms 닫힘 전환이 끝난 뒤
    // 변경된 위치에서 말풍선을 캡처한다.
    if (customBottomSurfaceWasOpen) {
      await WidgetsBinding.instance.endOfFrame;

      await Future<void>.delayed(_bottomSurfaceAnimationDuration);

      if (!mounted) {
        return;
      }

      await WidgetsBinding.instance.endOfFrame;
    }

    if (!keyboardWasVisible) {
      if (!customBottomSurfaceWasOpen) {
        await WidgetsBinding.instance.endOfFrame;
      }

      return;
    }

    for (int frame = 0; mounted && frame < 45; frame++) {
      await WidgetsBinding.instance.endOfFrame;

      if (!mounted) {
        return;
      }

      if (View.of(context).viewInsets.bottom == 0) {
        await WidgetsBinding.instance.endOfFrame;
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    if (mounted) {
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _restoreComposerFocusAfterModeChange({
    bool animateInitialScroll = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _messageFocusNode.requestFocus();

      _startKeyboardTransition(animateInitialScroll: animateInitialScroll);
    });
  }

  void _beginReply(ChatMessage message, String displayedContent) {
    final bool wasEditing = _editingMessage != null;

    _stopKeyboardTransition();
    _stopComposerResizePin();

    setState(() {
      _replyingToMessage = message;
      _replyingToContent = displayedContent;
      _editingMessage = null;
      _editingOriginalContent = null;
    });

    if (wasEditing) {
      _messageController.clear();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _messageFocusNode.requestFocus();

      _startKeyboardTransition(animateInitialScroll: true);
    });
  }

  void _cancelReply() {
    final bool shouldKeepBottom =
        _messageListKey.currentState?.isNearBottom ?? true;

    setState(() {
      _replyingToMessage = null;
      _replyingToContent = null;
    });

    if (shouldKeepBottom) {
      _startComposerResizePin();
    }
  }

  void _beginEdit(ChatMessage message) {
    _stopKeyboardTransition();
    _stopComposerResizePin();

    setState(() {
      _replyingToMessage = null;
      _replyingToContent = null;
      _editingMessage = message;
      _editingOriginalContent = message.content;
    });

    _messageController.value = TextEditingValue(
      text: message.content,
      selection: TextSelection.collapsed(offset: message.content.length),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _messageFocusNode.requestFocus();

      _startKeyboardTransition(animateInitialScroll: true);
    });
  }

  void _cancelEdit() {
    _stopKeyboardTransition();
    _stopComposerResizePin();

    setState(() {
      _editingMessage = null;
      _editingOriginalContent = null;
    });

    _messageController.clear();
    _messageFocusNode.unfocus();
  }

  void _saveEdit() {
    final ChatMessage? editingMessage = _editingMessage;
    final String? originalContent = _editingOriginalContent;

    // trim하지 않은 실제 입력값을 그대로 보관한다.
    final String updatedContent = _messageController.text;

    if (editingMessage == null ||
        originalContent == null ||
        updatedContent.trim().isEmpty ||
        updatedContent == originalContent) {
      return;
    }

    final bool didUpdate =
        _messageListKey.currentState?.updateMessageContent(
          messageId: editingMessage.id,
          content: updatedContent,
        ) ??
        false;

    if (!didUpdate) {
      return;
    }

    _stopKeyboardTransition();
    _stopComposerResizePin();

    setState(() {
      _editingMessage = null;
      _editingOriginalContent = null;
    });

    _messageController.clear();

    _restoreComposerFocusAfterModeChange(animateInitialScroll: true);
  }

  void _sendMessage() {
    if (_editingMessage != null) {
      return;
    }

    // 실제 보낼 내용은 trim하지 않는다.
    final String content = _messageController.text;

    // 공백이나 줄바꿈만 있는 메시지만 차단한다.
    if (content.trim().isEmpty) {
      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final ChatMessage? replyingToMessage = _replyingToMessage;
    final String? replyingToContent = _replyingToContent;

    final ChatReplyReference? replyTo =
        replyingToMessage == null || replyingToContent == null
        ? null
        : ChatReplyReference(
            messageId: replyingToMessage.id,
            senderId: replyingToMessage.senderId,
            content: replyingToContent,
          );

    _stopKeyboardTransition();
    _stopComposerResizePin();

    messageListState.addOutgoingMessage(content: content, replyTo: replyTo);

    _messageController.clear();

    setState(() {
      _replyingToMessage = null;
      _replyingToContent = null;
    });

    _restoreComposerFocusAfterModeChange(animateInitialScroll: true);
  }

  @override
  Widget build(BuildContext context) {
    final SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle.dark
        .copyWith(
          statusBarColor: ChatStylePreviewScreen._chatBackgroundColor,
          systemNavigationBarColor: ChatStylePreviewScreen._chatBackgroundColor,
          systemNavigationBarIconBrightness: Brightness.dark,
        );

    final MediaQueryData mediaQuery = MediaQuery.of(context);

    final double keyboardHeight = mediaQuery.viewInsets.bottom;

    final double systemBottomPadding = mediaQuery.viewPadding.bottom;

    final double passiveBottomHeight = keyboardHeight > 0.5
        ? keyboardHeight
        : systemBottomPadding;

    final double attachmentPanelHeight = math.max(
      _lastKeyboardHeight,
      systemBottomPadding,
    );

    final double resolvedPhotoPickerHeight =
        _photoPickerHeight ??
        _photoPickerCollapsedHeight ??
        attachmentPanelHeight;

    // 카카오톡 확장 화면은 화면 전체를 덮지 않고,
    // 상단 상태 표시줄과 일부 채팅 상단을 남긴다.
    // 첨부 이미지 비율상 전체 화면의 약 89% 높이다.
    //
    // 단, 확장 패널은 상단 바(56) 아래 영역에만 놓이므로
    // 상태 표시줄뿐 아니라 상단 바 높이도 함께 빼야
    // 카메라 컷아웃 등으로 상태 표시줄이 큰 기기에서
    // 메시지 리스트가 음수로 눌려 하단이 넘치지 않는다.
    final double photoPickerMaximumHeight =
        math.max(
          resolvedPhotoPickerHeight,
          math.min(
            mediaQuery.size.height * 0.89,
            mediaQuery.size.height -
                mediaQuery.padding.top -
                _ChatTopBar.height -
                12,
          ),
        );

    final double bottomSurfaceHeight =
        _photoPickerOpen
        ? resolvedPhotoPickerHeight
        : _attachmentPanelOpen
        ? attachmentPanelHeight
        : math.max(
            passiveBottomHeight,
            _heldBottomSurfaceHeight ?? 0,
          );

    final bool animateBottomSurfaceHeight =
        !_photoPickerDragging &&
        (_photoPickerOpen ||
            _attachmentPanelOpen ||
            _heldBottomSurfaceHeight != null ||
            keyboardHeight <= 0.5);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: ChatStylePreviewScreen._chatBackgroundColor,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          bottom: false,
          child: Stack(
            children: [
              Column(
                children: [
                  const _ChatTopBar(),
                  Expanded(
                    child: _MessageList(
                      key: _messageListKey,
                      currentUserId:
                          ChatStylePreviewScreen._currentUserId,
                      otherParticipantId:
                          ChatStylePreviewScreen._otherParticipantId,
                      onReplySelected: _beginReply,
                      onEditSelected: _beginEdit,
                      onBackgroundTap: _dismissComposerSurface,
                      onPrepareMessageActions: _prepareMessageActions,
                    ),
                  ),
                  NotificationListener<SizeChangedLayoutNotification>(
                    onNotification: _handleComposerSizeChanged,
                    child: SizeChangedLayoutNotifier(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_photoPickerOpen)
                            SizedBox(
                              key: _composerMeasureKey,
                              child: _MessageComposer(
                                controller: _messageController,
                                focusNode: _messageFocusNode,
                                inputHostKey: _messageInputHostKey,
                                replyingToMessage: _replyingToMessage,
                                replyingToContent: _replyingToContent,
                                editingMessage: _editingMessage,
                                editingOriginalContent:
                                    _editingOriginalContent,
                                currentUserId:
                                    ChatStylePreviewScreen._currentUserId,
                                otherParticipantName:
                                    ChatStylePreviewScreen
                                        ._otherParticipantName,
                                attachmentPanelOpen: _attachmentPanelOpen,
                                onCancelReply: _cancelReply,
                                onCancelEdit: _cancelEdit,
                                onSend: _sendMessage,
                                onSaveEdit: _saveEdit,
                                onTextChanged: _handleComposerTextChanged,
                                onToggleAttachmentPanel:
                                    _handleAttachmentButtonPressed,
                                onInputTap: _handleMessageInputTap,
                              ),
                            ),
                          _ComposerBottomSurface(
                            height: bottomSurfaceHeight,
                            showAttachmentPanel: _attachmentPanelOpen,
                            showPhotoPicker: _photoPickerOpen,
                            photoPickerExpanded: _photoPickerExpanded,
                            animateHeight: animateBottomSurfaceHeight,
                            photoLibrary: _photoLibrary,
                            onPhotoPressed: _openPhotoPicker,
                            onCameraPressed: _openCamera,
                            onClosePhotoPicker: _closePhotoPicker,
                            onSendPhotos: _sendSelectedPhotos,
                            onPhotoPickerDragStart:
                                _handlePhotoPickerDragStart,
                            onPhotoPickerDragUpdate:
                                (DragUpdateDetails details) {
                                  _handlePhotoPickerDragUpdate(
                                    details,
                                    maximumHeight: photoPickerMaximumHeight,
                                  );
                                },
                            onPhotoPickerDragEnd:
                                (DragEndDetails details) {
                                  _handlePhotoPickerDragEnd(
                                    details,
                                    maximumHeight: photoPickerMaximumHeight,
                                  );
                                },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              if (_photoPickerOpen && _photoPickerExpanded)
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  bottom: resolvedPhotoPickerHeight,
                  child: const AbsorbPointer(
                    child: ColoredBox(
                      color: Color(0x52000000),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ChatTopBar extends StatelessWidget {
  const _ChatTopBar();

  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('chat-top-bar'),
      height: height,
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
  const _MessageList({
    required this.currentUserId,
    required this.otherParticipantId,
    required this.onReplySelected,
    required this.onEditSelected,
    required this.onBackgroundTap,
    required this.onPrepareMessageActions,
    super.key,
  });

  final int currentUserId;
  final int otherParticipantId;
  final _ReplySelectedCallback onReplySelected;
  final _EditSelectedCallback onEditSelected;
  final VoidCallback onBackgroundTap;
  final Future<void> Function() onPrepareMessageActions;

  @override
  State<_MessageList> createState() {
    return _MessageListState();
  }
}

final class _MessageListState extends State<_MessageList> {
  static const Duration _previewTranslationDelay = Duration(seconds: 5);

  static const double _replyOriginalAlignment = 0.28;

  static const Map<int, String> _previewTranslations = {
    1: '오빠, 나 곧 탑승해.',
    2: '네가 계속 말해주길 기다리고 있어.',
    5: '미안해, 오빠.',
    6: '다음에는 제대로 말할게.',
    101: '그럼 만약 어느 날 내가 벌레가 되면 오빠는 어떻게 할 거야?',
    102: '🥺',
    105: '알을 낳는다고🥚??',
    106: 'ㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋㅋ',
    107:
        '그럼 풀어놓고 키워도 돼? 나는 새장에 갇히고 싶지 않고, '
        '오빠랑 꼭 안고 자고 뽀뽀도 하고 싶어.',
  };

  final Set<int> _showTranslatedMessageIds = <int>{};
  final Map<int, GlobalKey> _messageBubbleKeys = <int, GlobalKey>{};
  final ScrollController _scrollController = ScrollController();
  bool _didResolveInitialScrollPosition = false;

  Timer? _messageHighlightTimer;

  int? _highlightedMessageId;
  int? _returnToReplyMessageId;
  double? _returnToReplyScrollOffset;

  bool _replyNavigationInProgress = false;

  late DateTime _previewNow;
  late List<ChatMessage> _messages;
  int _nextMessageId = 9;

  @override
  void initState() {
    super.initState();

    _previewNow = DateTime(2026, 7, 1, 12, 51);

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
      ChatMessage(
        id: 101,
        senderId: 2,
        recipientId: 1,
        content: '那如果有一天我变成虫子了 欧巴怎么办',
        createdAt: DateTime(2026, 7, 1, 12, 45, 5),
      ),
      ChatMessage(
        id: 102,
        senderId: 2,
        recipientId: 1,
        content: '🥺',
        createdAt: DateTime(2026, 7, 1, 12, 45, 35),
      ),
      ChatMessage(
        id: 103,
        senderId: 1,
        recipientId: 2,
        content: '알 낳을거야?',
        createdAt: DateTime(2026, 7, 1, 12, 47, 5),
        readAt: DateTime(2026, 7, 1, 12, 50, 30),
      ),
      ChatMessage(
        id: 104,
        senderId: 1,
        recipientId: 2,
        content: '더 번식 안 하고 너만 있는거면 내가 잘 키워줄게',
        createdAt: DateTime(2026, 7, 1, 12, 47, 35),
        readAt: DateTime(2026, 7, 1, 12, 50, 30),
      ),
      ChatMessage(
        id: 105,
        senderId: 2,
        recipientId: 1,
        content: '下蛋🥚？？',
        createdAt: DateTime(2026, 7, 1, 12, 50, 5),
      ),
      ChatMessage(
        id: 106,
        senderId: 2,
        recipientId: 1,
        content: '哈哈哈哈哈哈哈哈哈哈哈哈哈',
        createdAt: DateTime(2026, 7, 1, 12, 50, 25),
      ),
      ChatMessage(
        id: 107,
        senderId: 2,
        recipientId: 1,
        content:
            '那可以放养吗 我不想被关进笼子里 '
            '还想和你抱抱睡觉觉 然后亲亲',
        createdAt: DateTime(2026, 7, 1, 12, 50, 45),
      ),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveInitialScrollPosition();
    });
  }

  void _resolveInitialScrollPosition() {
    if (!mounted || _didResolveInitialScrollPosition) {
      return;
    }

    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _resolveInitialScrollPosition();
      });
      return;
    }

    final ScrollPosition position = _scrollController.position;

    final bool conversationOverflows =
        position.maxScrollExtent > position.minScrollExtent + 0.5;

    if (!conversationOverflows) {
      setState(() {
        _didResolveInitialScrollPosition = true;
      });
      return;
    }

    // 대화가 화면을 넘으면 최신 메시지 구간으로 이동한다.
    _scrollController.jumpTo(position.maxScrollExtent);

    // 아래쪽 항목이 새로 레이아웃되면서 maxScrollExtent가
    // 조금 달라질 수 있으므로 다음 프레임에서 한 번 더 맞춘다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }

      setState(() {
        _didResolveInitialScrollPosition = true;
      });
    });
  }

  @override
  void dispose() {
    _messageHighlightTimer?.cancel();
    _scrollController.dispose();

    super.dispose();
  }

  void addOutgoingMessage({
    required String content,
    ChatReplyReference? replyTo,
  }) {
    setState(() {
      _previewNow = _previewNow.add(const Duration(minutes: 1));

      _messages.add(
        ChatMessage(
          id: _nextMessageId,
          senderId: widget.currentUserId,
          recipientId: widget.otherParticipantId,
          content: content,
          createdAt: _previewNow,
          replyTo: replyTo,
        ),
      );

      _nextMessageId++;
    });
  }

  void addOutgoingPhotoMessages({
    required List<ChatPhotoAttachment> attachments,
    required bool collage,
  }) {
    if (attachments.isEmpty) {
      return;
    }

    setState(() {
      final DateTime baseCreatedAt = _previewNow.add(
        const Duration(minutes: 1),
      );

      if (collage) {
        _messages.add(
          ChatMessage(
            id: _nextMessageId,
            senderId: widget.currentUserId,
            recipientId: widget.otherParticipantId,
            content: '',
            createdAt: baseCreatedAt,
            photoAttachments: List<ChatPhotoAttachment>.unmodifiable(
              attachments,
            ),
          ),
        );

        _nextMessageId++;
        _previewNow = baseCreatedAt;
        return;
      }

      for (int index = 0; index < attachments.length; index++) {
        final DateTime createdAt = baseCreatedAt.add(Duration(seconds: index));

        _messages.add(
          ChatMessage(
            id: _nextMessageId,
            senderId: widget.currentUserId,
            recipientId: widget.otherParticipantId,
            content: '',
            createdAt: createdAt,
            photoAttachments: <ChatPhotoAttachment>[attachments[index]],
          ),
        );

        _nextMessageId++;
        _previewNow = createdAt;
      }
    });
  }

  bool updateMessageContent({required int messageId, required String content}) {
    final int messageIndex = _messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );

    if (messageIndex == -1 ||
        _messages[messageIndex].senderId != widget.currentUserId) {
      return false;
    }

    setState(() {
      _messages[messageIndex] = _messages[messageIndex].copyWith(
        content: content,
        editedAt: _previewNow,
      );
    });

    return true;
  }

  bool get isNearBottom {
    if (!_scrollController.hasClients) {
      return true;
    }

    final ScrollPosition position = _scrollController.position;

    return position.maxScrollExtent - position.pixels <= 48;
  }

  Future<void> scrollToBottom({bool animate = true}) async {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }

    final double targetOffset = _scrollController.position.maxScrollExtent;

    final double currentOffset = _scrollController.position.pixels;

    if ((targetOffset - currentOffset).abs() < 0.5) {
      return;
    }

    if (!animate) {
      _scrollController.jumpTo(targetOffset);
      return;
    }

    await _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  RenderObject? _messageRenderObject(int messageId) {
    final GlobalKey? messageKey = _messageBubbleKeys[messageId];

    final BuildContext? messageContext = messageKey?.currentContext;

    if (messageContext == null || !messageContext.mounted) {
      return null;
    }

    final RenderObject? renderObject = messageContext.findRenderObject();

    if (renderObject == null || !renderObject.attached) {
      return null;
    }

    return renderObject;
  }

  Future<bool> _scrollToMessage(
    int messageId, {
    required double alignment,
  }) async {
    final int targetIndex = _messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );

    if (targetIndex == -1) {
      return false;
    }

    bool usedEstimatedOffset = false;

    for (int attempt = 0; attempt < 14; attempt++) {
      if (!mounted || !_scrollController.hasClients) {
        return false;
      }

      final RenderObject? targetRenderObject = _messageRenderObject(messageId);

      if (targetRenderObject != null) {
        final RenderAbstractViewport viewport = RenderAbstractViewport.of(
          targetRenderObject,
        );

        final ScrollPosition position = _scrollController.position;

        final RevealedOffset leadingReveal = viewport.getOffsetToReveal(
          targetRenderObject,
          0,
        );

        final RevealedOffset trailingReveal = viewport.getOffsetToReveal(
          targetRenderObject,
          1,
        );

        final RevealedOffset desiredReveal = viewport.getOffsetToReveal(
          targetRenderObject,
          alignment,
        );

        final double fullyVisibleMinimum = math.min(
          leadingReveal.offset,
          trailingReveal.offset,
        );

        final double fullyVisibleMaximum = math.max(
          leadingReveal.offset,
          trailingReveal.offset,
        );

        final double targetHeight = targetRenderObject is RenderBox
            ? targetRenderObject.size.height
            : desiredReveal.rect.height;

        final bool canFitEntireMessage =
            targetHeight <= position.viewportDimension + 0.5;

        double targetOffset = desiredReveal.offset;

        if (canFitEntireMessage) {
          // 상단 28% 배치를 우선하되, 긴 원문이 잘리는 경우에는
          // 말풍선 전체가 보이는 범위 안으로 위치를 보정한다.
          targetOffset = targetOffset
              .clamp(fullyVisibleMinimum, fullyVisibleMaximum)
              .toDouble();
        }

        targetOffset = targetOffset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble();

        if ((targetOffset - position.pixels).abs() >= 0.5) {
          // 카카오톡처럼 중간 스크롤 과정을 보여주지 않고
          // 계산된 원문 위치로 즉시 이동한다.
          _scrollController.jumpTo(targetOffset);
        }

        await WidgetsBinding.instance.endOfFrame;

        return mounted;
      }

      final ScrollPosition position = _scrollController.position;

      final double scrollRange =
          position.maxScrollExtent - position.minScrollExtent;

      if (scrollRange <= 0) {
        return false;
      }

      final double targetRatio = _messages.length <= 1
          ? 0
          : targetIndex / (_messages.length - 1);

      final double targetOffset;

      if (!usedEstimatedOffset) {
        targetOffset = position.minScrollExtent + (scrollRange * targetRatio);

        usedEstimatedOffset = true;
      } else {
        final double currentRatio =
            ((position.pixels - position.minScrollExtent) / scrollRange)
                .clamp(0.0, 1.0)
                .toDouble();

        final double direction = targetRatio < currentRatio ? -1.0 : 1.0;

        targetOffset =
            (position.pixels + (direction * position.viewportDimension * 0.72))
                .clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble();
      }

      if ((targetOffset - position.pixels).abs() < 0.5) {
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }

      // 화면 밖의 위젯이 아직 렌더링되지 않았을 때도
      // 중간 스크롤 애니메이션 없이 예상 위치로 바로 이동한다.
      _scrollController.jumpTo(targetOffset);

      await WidgetsBinding.instance.endOfFrame;
    }

    return false;
  }

  void _flashMessage(int messageId) {
    if (!mounted || _findMessage(messageId) == null) {
      return;
    }

    _messageHighlightTimer?.cancel();

    // 같은 메시지가 아직 강조 중일 때 다시 요청되어도
    // false → true 전환을 만들어 애니메이션을 재시작한다.
    if (_highlightedMessageId == messageId) {
      setState(() {
        _highlightedMessageId = null;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        _activateMessageHighlight(messageId);
      });

      return;
    }

    _activateMessageHighlight(messageId);
  }

  void _activateMessageHighlight(int messageId) {
    if (!mounted || _findMessage(messageId) == null) {
      return;
    }

    setState(() {
      _highlightedMessageId = messageId;
    });

    _messageHighlightTimer = Timer(const Duration(milliseconds: 440), () {
      if (!mounted || _highlightedMessageId != messageId) {
        return;
      }

      setState(() {
        _highlightedMessageId = null;
      });
    });
  }

  Future<void> _handleReplyQuoteTap({
    required int replyMessageId,
    required int originalMessageId,
  }) async {
    if (_replyNavigationInProgress ||
        _findMessage(replyMessageId) == null ||
        _findMessage(originalMessageId) == null ||
        !_scrollController.hasClients) {
      return;
    }

    // 원문으로 이동하기 직전 보고 있던 화면의 정확한 스크롤 위치를
    // 먼저 저장한다.
    final double returnScrollOffset = _scrollController.position.pixels;

    _replyNavigationInProgress = true;

    try {
      final bool didNavigate = await _scrollToMessage(
        originalMessageId,
        alignment: _replyOriginalAlignment,
      );

      if (!mounted || !didNavigate) {
        return;
      }

      setState(() {
        _returnToReplyMessageId = replyMessageId;
        _returnToReplyScrollOffset = returnScrollOffset;
      });

      // 즉시 이동한 화면이 페인트된 뒤 원문 펄스를 실행한다.
      _flashMessage(originalMessageId);
    } finally {
      _replyNavigationInProgress = false;
    }
  }

  Future<void> _handleBackToReplyMessage() async {
    final int? replyMessageId = _returnToReplyMessageId;

    final double? returnScrollOffset = _returnToReplyScrollOffset;

    if (replyMessageId == null ||
        returnScrollOffset == null ||
        _replyNavigationInProgress) {
      return;
    }

    if (_findMessage(replyMessageId) == null || !_scrollController.hasClients) {
      if (mounted) {
        setState(() {
          _returnToReplyMessageId = null;
          _returnToReplyScrollOffset = null;
        });
      }

      return;
    }

    _replyNavigationInProgress = true;

    try {
      final ScrollPosition position = _scrollController.position;

      final double restoredOffset = returnScrollOffset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();

      // 답장 메시지를 특정 위치에 정렬하지 않고,
      // 인용문을 탭하기 직전의 화면을 그대로 복원한다.
      _scrollController.jumpTo(restoredOffset);

      await WidgetsBinding.instance.endOfFrame;

      if (!mounted) {
        return;
      }

      setState(() {
        _returnToReplyMessageId = null;
        _returnToReplyScrollOffset = null;
      });

      // 원래 화면으로 복원된 뒤 해당 답장 말풍선에 같은 펄스를 준다.
      if (_messageRenderObject(replyMessageId) != null) {
        _flashMessage(replyMessageId);
      }
    } finally {
      _replyNavigationInProgress = false;
    }
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

  String _displayedContentFor(ChatMessage message) {
    if (message.isPhotoMessage) {
      return message.replyPreviewContent;
    }

    final String? translatedContent = message.translatedContent;

    if (_showTranslatedMessageIds.contains(message.id) &&
        translatedContent != null) {
      return translatedContent;
    }

    return message.content;
  }

  Future<void> _handleMessageLongPress(
    ChatMessage message,
    GlobalKey bubbleKey,
  ) async {
    await widget.onPrepareMessageActions();

    if (!mounted || bubbleKey.currentContext == null) {
      return;
    }

    // 키보드가 닫힌 뒤 새 위치에서 말풍선을 캡처한다.
    await WidgetsBinding.instance.endOfFrame;

    if (!mounted || bubbleKey.currentContext == null) {
      return;
    }

    final _CapturedMessageBubble capturedBubble = await _captureMessageBubble(
      bubbleKey: bubbleKey,
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );

    if (!mounted) {
      capturedBubble.image.dispose();
      return;
    }

    final Rect bubbleRect = capturedBubble.rect;
    final ui.Image bubbleImage = capturedBubble.image;

    final List<ChatMessageAction> actions = availableChatMessageActions(
      isOutgoing: message.senderId == widget.currentUserId,
      createdAt: message.createdAt,
      now: _previewNow,
      isMedia: message.isPhotoMessage,
    );

    ChatMessageAction? selectedAction;

    try {
      selectedAction = await showGeneralDialog<ChatMessageAction>(
        context: context,
        requestFocus: false,
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
        await Clipboard.setData(
          ClipboardData(text: _displayedContentFor(message)),
        );

        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Message copied')));
        return;

      case ChatMessageAction.reply:
        widget.onReplySelected(message, message.replyPreviewContent);
        return;

      case ChatMessageAction.edit:
        widget.onEditSelected(message);
        return;

      case ChatMessageAction.unsend:
        _unsendMessage(message.id);
        return;
    }
  }

  void _unsendMessage(int messageId) {
    if (_highlightedMessageId == messageId) {
      _messageHighlightTimer?.cancel();
    }

    setState(() {
      _messages.removeWhere((ChatMessage message) => message.id == messageId);

      _showTranslatedMessageIds.remove(messageId);
      _messageBubbleKeys.remove(messageId);

      if (_highlightedMessageId == messageId) {
        _highlightedMessageId = null;
      }

      if (_returnToReplyMessageId == messageId) {
        _returnToReplyMessageId = null;
        _returnToReplyScrollOffset = null;
      }
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

    final Widget messageList = IgnorePointer(
      ignoring: !_didResolveInitialScrollPosition,
      child: Opacity(
        opacity: _didResolveInitialScrollPosition ? 1 : 0,
        child: GestureDetector(
          key: const ValueKey<String>('message-list-tap-area'),
          behavior: HitTestBehavior.translucent,
          onTap: widget.onBackgroundTap,
          child: ListView(
            key: const ValueKey<String>('message-list'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(8, 8, 8, _messageToComposerGap),
            children: _buildTimeline(
              groups: groups,
              latestReadMessageId: latestReadMessageId,
            ),
          ),
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        messageList,
        if (_returnToReplyMessageId != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(
              child: _BackToReplyMessageButton(
                onPressed: () {
                  unawaited(_handleBackToReplyMessage());
                },
              ),
            ),
          ),
      ],
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
          highlightedMessageId: _highlightedMessageId,
          onIncomingMessageTap: _handleIncomingMessageTap,
          onRetryTranslation: _retryTranslation,
          onMessageLongPress: _handleMessageLongPress,
          onReplyQuoteTap: _handleReplyQuoteTap,
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

final class _BackToReplyMessageButton extends StatelessWidget {
  const _BackToReplyMessageButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('back-to-reply-message'),
      color: AppColors.white,
      elevation: 4,
      shadowColor: AppColors.black.withAlpha(31),
      borderRadius: AppRadius.borderRadiusFull,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadius.borderRadiusFull,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
          child: Text(
            'Back to Reply Message',
            style: AppTypography.typography7.copyWith(
              color: AppColors.grey900,
              fontWeight: AppTypography.bold,
            ),
          ),
        ),
      ),
    );
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

final class _ReplyMessageBody extends StatelessWidget {
  const _ReplyMessageBody({
    required this.message,
    required this.isOutgoing,
    required this.onReplyQuoteTap,
    required this.child,
  });

  final ChatMessage message;
  final bool isOutgoing;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ChatReplyReference? replyTo = message.replyTo;

    final Widget messageBody;

    if (replyTo == null) {
      messageBody = child;
    } else {
      final String authorLabel =
          replyTo.senderId == ChatStylePreviewScreen._currentUserId
          ? 'Me'
          : ChatStylePreviewScreen._otherParticipantName;

      final Color primaryColor = isOutgoing
          ? AppColors.white
          : AppColors.grey900;

      final Color secondaryColor = isOutgoing
          ? AppColors.white.withAlpha(220)
          : AppColors.grey700;

      final Color dividerColor = isOutgoing
          ? AppColors.white.withAlpha(56)
          : AppColors.grey200;

      final Widget quotedArea = GestureDetector(
        key: ValueKey<String>('reply-quote-area-${message.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          unawaited(
            onReplyQuoteTap(
              replyMessageId: message.id,
              originalMessageId: replyTo.messageId,
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reply to $authorLabel',
              key: ValueKey<String>('reply-message-title-${message.id}'),
              style: AppTypography.subTypography10.copyWith(
                color: primaryColor,
                fontWeight: AppTypography.bold,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              replyTo.content,
              key: ValueKey<String>('reply-message-preview-${message.id}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.subTypography10.copyWith(
                color: secondaryColor,
                fontWeight: AppTypography.regular,
              ),
            ),
            const SizedBox(height: 7),
            Divider(height: 1, thickness: 1, color: dividerColor),
          ],
        ),
      );

      messageBody = Column(
        key: ValueKey<String>('reply-message-${message.id}'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [quotedArea, const SizedBox(height: 7), child],
      );
    }

    return _MessageEditStatusBody(
      message: message,
      isOutgoing: isOutgoing,
      child: messageBody,
    );
  }
}

final class _MessageEditStatusBody extends StatelessWidget {
  const _MessageEditStatusBody({
    required this.message,
    required this.isOutgoing,
    required this.child,
  });

  final ChatMessage message;
  final bool isOutgoing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (message.editedAt == null) {
      return child;
    }

    final Color editedColor = isOutgoing
        ? AppColors.white.withAlpha(190)
        : AppColors.grey600;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        child,
        const SizedBox(height: 1),
        Text(
          'Edited',
          key: ValueKey<String>('message-edited-${message.id}'),
          style: AppTypography.typography7.copyWith(
            color: editedColor,
            fontWeight: AppTypography.regular,
          ),
        ),
      ],
    );
  }
}

final class _DateSeparator extends StatelessWidget {
  const _DateSeparator({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        key: ValueKey<String>(
          'chat-date-separator-'
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
        ),
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
    required this.highlightedMessageId,
    required this.onIncomingMessageTap,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.messageBubbleKeyFor,
  });

  final ChatMessageGroup group;
  final int currentUserId;
  final int? latestReadMessageId;
  final DateTime now;
  final Set<int> shownTranslatedMessageIds;
  final int? highlightedMessageId;
  final ValueChanged<int> onIncomingMessageTap;
  final ValueChanged<int> onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final _MessageBubbleKeyFor messageBubbleKeyFor;

  @override
  Widget build(BuildContext context) {
    if (group.senderId == currentUserId) {
      return _OutgoingMessageGroup(
        messages: group.messages,
        latestReadMessageId: latestReadMessageId,
        now: now,
        highlightedMessageId: highlightedMessageId,
        onMessageLongPress: onMessageLongPress,
        onReplyQuoteTap: onReplyQuoteTap,
        messageBubbleKeyFor: messageBubbleKeyFor,
      );
    }

    return _IncomingMessageGroup(
      messages: group.messages,
      shownTranslatedMessageIds: shownTranslatedMessageIds,
      highlightedMessageId: highlightedMessageId,
      onIncomingMessageTap: onIncomingMessageTap,
      onRetryTranslation: onRetryTranslation,
      onMessageLongPress: onMessageLongPress,
      onReplyQuoteTap: onReplyQuoteTap,
      messageBubbleKeyFor: messageBubbleKeyFor,
    );
  }
}

final class _IncomingMessageGroup extends StatelessWidget {
  const _IncomingMessageGroup({
    required this.messages,
    required this.shownTranslatedMessageIds,
    required this.highlightedMessageId,
    required this.onIncomingMessageTap,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.messageBubbleKeyFor,
  });

  final List<ChatMessage> messages;
  final Set<int> shownTranslatedMessageIds;
  final int? highlightedMessageId;
  final ValueChanged<int> onIncomingMessageTap;
  final ValueChanged<int> onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
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
                  isHighlighted: messages[index].id == highlightedMessageId,
                  onMessageTap: () {
                    onIncomingMessageTap(messages[index].id);
                  },
                  onRetryTranslation: () {
                    onRetryTranslation(messages[index].id);
                  },
                  onMessageLongPress: onMessageLongPress,
                  onReplyQuoteTap: onReplyQuoteTap,
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
    required this.isHighlighted,
    required this.onMessageTap,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.bubbleInteractionKey,
  });

  final ChatMessage message;
  final bool showTail;
  final bool showTime;
  final bool showTranslation;
  final bool isHighlighted;
  final VoidCallback onMessageTap;
  final VoidCallback onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final GlobalKey bubbleInteractionKey;

  @override
  Widget build(BuildContext context) {
    final bool canTapBubble =
        message.translationStatus == ChatTranslationStatus.none ||
        message.translationStatus == ChatTranslationStatus.translated;

    Widget bubble = _MessageBubble(
      messageId: message.id,
      measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
      backgroundColor: AppColors.grey100,
      direction: _BubbleDirection.incoming,
      showTail: showTail,
      isHighlighted: isHighlighted,
      child: _IncomingMessageContent(
        message: message,
        showTranslation: showTranslation,
        onRetryTranslation: onRetryTranslation,
        onReplyQuoteTap: onReplyQuoteTap,
      ),
    );

    bubble = _MessageCaptureBoundary(
      key: bubbleInteractionKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTapBubble ? onMessageTap : null,
        onLongPress: () {
          unawaited(onMessageLongPress(message, bubbleInteractionKey));
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
    required this.onReplyQuoteTap,
  });

  final ChatMessage message;
  final bool showTranslation;
  final VoidCallback onRetryTranslation;
  final _ReplyQuoteTapCallback onReplyQuoteTap;

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

    final Widget messageBody = Column(
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
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: _ReplyMessageBody(
        message: message,
        isOutgoing: false,
        onReplyQuoteTap: onReplyQuoteTap,
        child: messageBody,
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
    required this.highlightedMessageId,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.messageBubbleKeyFor,
  });

  final List<ChatMessage> messages;
  final int? latestReadMessageId;
  final DateTime now;
  final int? highlightedMessageId;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
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
            isHighlighted: messages[index].id == highlightedMessageId,
            onMessageLongPress: onMessageLongPress,
            onReplyQuoteTap: onReplyQuoteTap,
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
    required this.isHighlighted,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.bubbleInteractionKey,
  });

  final ChatMessage message;
  final bool showTail;
  final bool showTime;
  final bool isHighlighted;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final GlobalKey bubbleInteractionKey;

  @override
  Widget build(BuildContext context) {
    final TextStyle messageTextStyle = AppTypography.subTypography10.copyWith(
      color: AppColors.white,
      fontWeight: AppTypography.regular,
    );

    final Widget content = message.isPhotoMessage
        ? _OutgoingPhotoMessage(
            messageId: message.id,
            measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
            attachments: message.photoAttachments,
            isHighlighted: isHighlighted,
          )
        : _MessageBubble(
            messageId: message.id,
            measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
            backgroundColor: AppColors.blue500,
            direction: _BubbleDirection.outgoing,
            showTail: showTail,
            isHighlighted: isHighlighted,
            child: _ReplyMessageBody(
              message: message,
              isOutgoing: true,
              onReplyQuoteTap: onReplyQuoteTap,
              child: Text(
                message.content,
                softWrap: true,
                strutStyle: _buildMessageStrutStyle(messageTextStyle),
                textHeightBehavior: _messageTextHeightBehavior,
                style: messageTextStyle,
              ),
            ),
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
                unawaited(onMessageLongPress(message, bubbleInteractionKey));
              },
              child: content,
            ),
          ),
        ),
      ],
    );
  }
}

final class _OutgoingPhotoMessage extends StatefulWidget {
  const _OutgoingPhotoMessage({
    required this.messageId,
    required this.attachments,
    required this.isHighlighted,
    required this.measurementKey,
  });

  final int messageId;
  final List<ChatPhotoAttachment> attachments;
  final bool isHighlighted;
  final Key measurementKey;

  @override
  State<_OutgoingPhotoMessage> createState() {
    return _OutgoingPhotoMessageState();
  }
}

final class _OutgoingPhotoMessageState extends State<_OutgoingPhotoMessage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  late final Animation<double> _scaleAnimation;

  late final Animation<double> _verticalOffsetAnimation;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1,
          end: 1.026,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 22,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1.026,
          end: 0.995,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 28,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.995,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 50,
      ),
    ]).animate(_pulseController);

    _verticalOffsetAnimation = TweenSequence<double>([
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 0, end: -1.4),
        weight: 22,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: -1.4, end: 0.5),
        weight: 28,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(begin: 0.5, end: 0),
        weight: 50,
      ),
    ]).animate(_pulseController);

    if (widget.isHighlighted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _pulseController.forward(from: 0);
        }
      });
    }
  }

  @override
  void didUpdateWidget(_OutgoingPhotoMessage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isHighlighted && !oldWidget.isHighlighted) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      child: _PhotoMessageCollage(attachments: widget.attachments),
      builder: (BuildContext context, Widget? child) {
        final double progress = _pulseController.value;

        final double overlayStrength = progress <= 0.22
            ? progress / 0.22
            : (1 - progress) / 0.78;

        return Transform.translate(
          offset: Offset(0, _verticalOffsetAnimation.value),
          child: Transform.scale(
            key: ValueKey<String>('message-pulse-${widget.messageId}'),
            scale: _scaleAnimation.value,
            alignment: Alignment.centerRight,
            child: Stack(
              key: widget.measurementKey,
              children: [
                child!,
                if (progress > 0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(14),
                        ),
                        child: ColoredBox(
                          color: AppColors.black.withAlpha(
                            (18 * overlayStrength.clamp(0.0, 1.0)).round(),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.isHighlighted)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: SizedBox.expand(
                        key: ValueKey<String>(
                          'message-highlight-'
                          '${widget.messageId}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _PhotoMessageCollage extends StatelessWidget {
  const _PhotoMessageCollage({required this.attachments});

  final List<ChatPhotoAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    final double width = math.min(260, MediaQuery.sizeOf(context).width * 0.68);

    if (attachments.length == 1) {
      final ChatPhotoAttachment attachment = attachments.first;

      final double sourceAspectRatio = attachment.height <= 0
          ? 1
          : attachment.width / attachment.height;

      final double aspectRatio = sourceAspectRatio.clamp(0.75, 1.5).toDouble();

      final double height = (width / aspectRatio).clamp(150, 260).toDouble();

      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: SizedBox(
          width: width,
          height: height,
          child: _PhotoMessageImage(attachment: attachment, itemIndex: 0),
        ),
      );
    }

    if (attachments.length == 2) {
      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: SizedBox(
          width: width,
          height: width * 0.66,
          child: Row(
            children: [
              Expanded(
                child: _PhotoMessageImage(
                  attachment: attachments[0],
                  itemIndex: 0,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: _PhotoMessageImage(
                  attachment: attachments[1],
                  itemIndex: 1,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (attachments.length == 3) {
      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(14)),
        child: SizedBox(
          width: width,
          height: width * 0.78,
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: _PhotoMessageImage(
                  attachment: attachments[0],
                  itemIndex: 0,
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    Expanded(
                      child: _PhotoMessageImage(
                        attachment: attachments[1],
                        itemIndex: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Expanded(
                      child: _PhotoMessageImage(
                        attachment: attachments[2],
                        itemIndex: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final List<ChatPhotoAttachment> visible = attachments.take(4).toList();

    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      child: SizedBox(
        width: width,
        height: width,
        child: GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: visible.length,
          itemBuilder: (BuildContext context, int index) {
            final int hiddenCount = index == 3 ? attachments.length - 4 : 0;

            return Stack(
              fit: StackFit.expand,
              children: [
                _PhotoMessageImage(
                  attachment: visible[index],
                  itemIndex: index,
                ),
                if (hiddenCount > 0)
                  ColoredBox(
                    color: AppColors.black.withAlpha(112),
                    child: Center(
                      child: Text(
                        '+$hiddenCount',
                        style: AppTypography.typography4.copyWith(
                          color: AppColors.white,
                          fontWeight: AppTypography.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _PhotoMessageImage extends StatelessWidget {
  const _PhotoMessageImage({required this.attachment, required this.itemIndex});

  final ChatPhotoAttachment attachment;
  final int itemIndex;

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      attachment.previewBytes,
      key: ValueKey<String>(
        'photo-message-'
        '${attachment.assetId}-'
        '$itemIndex',
      ),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }
}

enum _BubbleDirection { incoming, outgoing }

final class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.messageId,
    required this.backgroundColor,
    required this.direction,
    required this.showTail,
    required this.isHighlighted,
    required this.child,
    this.measurementKey,
  });

  final int messageId;
  final Color backgroundColor;
  final _BubbleDirection direction;
  final bool showTail;
  final bool isHighlighted;
  final Widget child;
  final Key? measurementKey;

  @override
  State<_MessageBubble> createState() {
    return _MessageBubbleState();
  }
}

final class _MessageBubbleState extends State<_MessageBubble>
    with SingleTickerProviderStateMixin {
  static const Duration _pulseDuration = Duration(milliseconds: 360);

  late final AnimationController _pulseController;

  late final Animation<double> _scaleAnimation;

  late final Animation<double> _verticalOffsetAnimation;

  bool get _isOutgoing {
    return widget.direction == _BubbleDirection.outgoing;
  }

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: _pulseDuration,
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1,
          end: 1.026,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 22,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 1.026,
          end: 0.995,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 28,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.995,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 50,
      ),
    ]).animate(_pulseController);

    _verticalOffsetAnimation = TweenSequence<double>([
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0,
          end: -1.4,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 22,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: -1.4,
          end: 0.5,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 28,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: 0.5,
          end: 0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 50,
      ),
    ]).animate(_pulseController);

    if (widget.isHighlighted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        _pulseController.forward(from: 0);
      });
    }
  }

  @override
  void didUpdateWidget(_MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool highlightStarted =
        widget.isHighlighted &&
        (!oldWidget.isHighlighted || oldWidget.messageId != widget.messageId);

    if (highlightStarted) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Color _bubbleColorFor(double progress) {
    final Color pulseColor = Color.alphaBlend(
      AppColors.black.withAlpha(18),
      widget.backgroundColor,
    );

    const double peakPoint = 0.22;

    if (progress <= peakPoint) {
      final double normalized = (progress / peakPoint)
          .clamp(0.0, 1.0)
          .toDouble();

      return Color.lerp(
        widget.backgroundColor,
        pulseColor,
        Curves.easeOutCubic.transform(normalized),
      )!;
    }

    final double normalized = ((progress - peakPoint) / (1 - peakPoint))
        .clamp(0.0, 1.0)
        .toDouble();

    return Color.lerp(
      pulseColor,
      widget.backgroundColor,
      Curves.easeOutCubic.transform(normalized),
    )!;
  }

  @override
  Widget build(BuildContext context) {
    final double maxWidth = MediaQuery.sizeOf(context).width * 0.68;

    final BorderRadius borderRadius = BorderRadius.only(
      topLeft: Radius.circular(!_isOutgoing && widget.showTail ? 6 : 17),
      topRight: Radius.circular(_isOutgoing && widget.showTail ? 6 : 17),
      bottomLeft: const Radius.circular(17),
      bottomRight: const Radius.circular(17),
    );

    final Alignment pulseAlignment = _isOutgoing
        ? Alignment.centerRight
        : Alignment.centerLeft;

    return AnimatedBuilder(
      animation: _pulseController,
      child: widget.child,
      builder: (BuildContext context, Widget? child) {
        final Color bubbleColor = _bubbleColorFor(_pulseController.value);

        return Transform.translate(
          offset: Offset(0, _verticalOffsetAnimation.value),
          child: Transform.scale(
            key: ValueKey<String>('message-pulse-${widget.messageId}'),
            scale: _scaleAnimation.value,
            alignment: pulseAlignment,
            child: Stack(
              key: widget.measurementKey,
              clipBehavior: Clip.none,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: borderRadius,
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
                if (widget.showTail)
                  Positioned(
                    top: 3,
                    left: _isOutgoing ? null : -7,
                    right: _isOutgoing ? -7 : null,
                    child: CustomPaint(
                      size: const Size(12, 13),
                      painter: _BubbleTailPainter(
                        color: bubbleColor,
                        direction: widget.direction,
                      ),
                    ),
                  ),
                if (widget.isHighlighted)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: SizedBox.expand(
                        key: ValueKey<String>(
                          'message-highlight-'
                          '${widget.messageId}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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

final class _AttachmentPanelActionData {
  const _AttachmentPanelActionData({
    required this.id,
    required this.label,
    required this.icon,
    required this.foregroundColor,
  });

  final String id;
  final String label;
  final IconData icon;
  final Color foregroundColor;
}

final class _ComposerBottomSurface extends StatelessWidget {
  const _ComposerBottomSurface({
    required this.height,
    required this.showAttachmentPanel,
    required this.showPhotoPicker,
    required this.photoPickerExpanded,
    required this.animateHeight,
    required this.photoLibrary,
    required this.onPhotoPressed,
    required this.onCameraPressed,
    required this.onClosePhotoPicker,
    required this.onSendPhotos,
    required this.onPhotoPickerDragStart,
    required this.onPhotoPickerDragUpdate,
    required this.onPhotoPickerDragEnd,
  });

  final double height;
  final bool showAttachmentPanel;
  final bool showPhotoPicker;
  final bool animateHeight;

  final bool photoPickerExpanded;

  final ChatPhotoLibrary photoLibrary;

  final VoidCallback onPhotoPressed;
  final VoidCallback onCameraPressed;
  final VoidCallback onClosePhotoPicker;
  final ChatPhotoSendCallback onSendPhotos;

  final GestureDragStartCallback
      onPhotoPickerDragStart;

  final GestureDragUpdateCallback
      onPhotoPickerDragUpdate;

  final GestureDragEndCallback
      onPhotoPickerDragEnd;

  @override
  Widget build(BuildContext context) {
    late final Key surfaceKey;
    late final Widget surface;

    if (showPhotoPicker) {
      surfaceKey = const ValueKey<String>(
        'photo-picker-visible',
      );

      surface = ChatPhotoPicker(
        photoLibrary: photoLibrary,
        expanded: photoPickerExpanded,
        onClose: onClosePhotoPicker,
        onSend: onSendPhotos,
        onHandleDragStart:
            onPhotoPickerDragStart,
        onHandleDragUpdate:
            onPhotoPickerDragUpdate,
        onHandleDragEnd:
            onPhotoPickerDragEnd,
      );
    } else if (showAttachmentPanel) {
      surfaceKey = const ValueKey<String>(
        'attachment-panel-visible',
      );

      surface = _ChatAttachmentPanel(
        onPhotoPressed: onPhotoPressed,
        onCameraPressed: onCameraPressed,
      );
    } else {
      surfaceKey = const ValueKey<String>(
        'attachment-panel-hidden',
      );

      surface = const SizedBox.shrink();
    }

    return AnimatedContainer(
      key: const ValueKey<String>(
        'composer-bottom-surface',
      ),
      width: double.infinity,
      height: height,
      duration: animateHeight
          ? _bottomSurfaceAnimationDuration
          : Duration.zero,
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(
        color: AppColors.white,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(
          milliseconds: 140,
        ),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,

        // AnimatedSwitcher의 기본 Stack은 자식에게
        // 느슨한 가로 제약을 줄 수 있다.
        // 모든 하단 패널을 부모 너비와 높이에 강제로 맞춘다.
        layoutBuilder: (
          Widget? currentChild,
          List<Widget> previousChildren,
        ) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ...previousChildren,
              ?currentChild,
            ],
          );
        },

        transitionBuilder: (
          Widget child,
          Animation<double> animation,
        ) {
          final Animation<Offset> position =
              Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                ),
              );

          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: position,
              child: child,
            ),
          );
        },

        child: SizedBox.expand(
          key: surfaceKey,
          child: surface,
        ),
      ),
    );
  }
}

final class _ChatAttachmentPanel extends StatelessWidget {
  const _ChatAttachmentPanel({
    required this.onPhotoPressed,
    required this.onCameraPressed,
  });

  final VoidCallback onPhotoPressed;
  final VoidCallback onCameraPressed;

  static const List<_AttachmentPanelActionData> _actions = [
    _AttachmentPanelActionData(
      id: 'photo',
      label: 'Photo',
      icon: Icons.image_rounded,
      foregroundColor: AppColors.green500,
    ),
    _AttachmentPanelActionData(
      id: 'camera',
      label: 'Camera',
      icon: Icons.photo_camera_rounded,
      foregroundColor: AppColors.blue500,
    ),
    _AttachmentPanelActionData(
      id: 'call',
      label: 'Call',
      icon: Icons.call_rounded,
      foregroundColor: AppColors.green500,
    ),
    _AttachmentPanelActionData(
      id: 'file',
      label: 'File',
      icon: Icons.insert_drive_file_rounded,
      foregroundColor: AppColors.grey600,
    ),
    _AttachmentPanelActionData(
      id: 'voice-memo',
      label: 'Voice Memo',
      icon: Icons.graphic_eq_rounded,
      foregroundColor: AppColors.red500,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final double bottomSafePadding = MediaQuery.viewPaddingOf(context).bottom;

    return Material(
      key: const ValueKey<String>('attachment-panel'),
      color: AppColors.white,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.grey100)),
        ),
        child: GridView.builder(
          key: const ValueKey<String>('attachment-panel-grid'),
          padding: EdgeInsets.fromLTRB(
            10,
            26,
            10,
            math.max(18, bottomSafePadding + 12),
          ),
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisExtent: 106,
          ),
          itemCount: _actions.length,
          itemBuilder: (BuildContext context, int index) {
            final _AttachmentPanelActionData action = _actions[index];

            final VoidCallback onPressed;

            switch (action.id) {
              case 'photo':
                onPressed = onPhotoPressed;
              case 'camera':
                onPressed = onCameraPressed;
              default:
                onPressed = () {};
            }

            return _AttachmentPanelAction(
              action: action,
              onPressed: onPressed,
            );
          },
        ),
      ),
    );
  }
}

final class _AttachmentPanelAction extends StatelessWidget {
  const _AttachmentPanelAction({required this.action, required this.onPressed});

  final _AttachmentPanelActionData action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey<String>('attachment-action-${action.id}'),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      onTap: () {
        Feedback.forTap(context);
        onPressed();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 54,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: AppColors.grey100,
                shape: BoxShape.circle,
              ),
              child: Icon(action.icon, size: 28, color: action.foregroundColor),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            action.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppTypography.subTypography11.copyWith(
              color: AppColors.grey900,
              fontWeight: AppTypography.regular,
            ),
          ),
        ],
      ),
    );
  }
}

final class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.focusNode,
    required this.inputHostKey,
    required this.replyingToMessage,
    required this.replyingToContent,
    required this.editingMessage,
    required this.editingOriginalContent,
    required this.currentUserId,
    required this.otherParticipantName,
    required this.attachmentPanelOpen,
    required this.onCancelReply,
    required this.onCancelEdit,
    required this.onSend,
    required this.onSaveEdit,
    required this.onTextChanged,
    required this.onToggleAttachmentPanel,
    required this.onInputTap,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey inputHostKey;
  final ChatMessage? replyingToMessage;
  final String? replyingToContent;
  final ChatMessage? editingMessage;
  final String? editingOriginalContent;
  final int currentUserId;
  final String otherParticipantName;
  final bool attachmentPanelOpen;

  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final VoidCallback onSend;
  final VoidCallback onSaveEdit;
  final ValueChanged<String> onTextChanged;
  final VoidCallback onToggleAttachmentPanel;
  final VoidCallback onInputTap;

  @override
  Widget build(BuildContext context) {
    final ChatMessage? editTarget = editingMessage;
    final ChatMessage? replyTarget = replyingToMessage;

    final bool isEditing = editTarget != null;
    final bool isReplying = !isEditing && replyTarget != null;

    final String? replyTitle = replyTarget == null
        ? null
        : 'Reply to '
              '${replyTarget.senderId == currentUserId ? 'Me' : otherParticipantName}';

    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder:
              (BuildContext context, TextEditingValue value, Widget? child) {
                final String rawValue = value.text;
                final bool hasContent = rawValue.trim().isNotEmpty;

                final bool canSend = hasContent;

                final bool canSaveEdit =
                    isEditing &&
                    hasContent &&
                    rawValue != editingOriginalContent;

                return AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: isEditing
                      ? _buildEditComposer(
                          originalContent: editingOriginalContent ?? '',
                          canSaveEdit: canSaveEdit,
                        )
                      : isReplying
                      ? _buildReplyComposer(
                          replyTitle: replyTitle!,
                          replyPreview: replyingToContent ?? '',
                          canSend: canSend,
                        )
                      : _buildDefaultComposer(canSend: canSend),
                );
              },
        ),
      ),
    );
  }

  Widget _buildDefaultComposer({required bool canSend}) {
    return ClipRRect(
      key: const ValueKey<String>('message-composer-default'),
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      child: ColoredBox(
        color: AppColors.grey50,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ComposerLastLineAction(
                  child: _ComposerCircleButton(
                    buttonKey: const ValueKey<String>('message-attachment'),
                    tooltip: attachmentPanelOpen
                        ? 'Open keyboard'
                        : 'Attachments',
                    icon: attachmentPanelOpen
                        ? Icons.close_rounded
                        : Icons.add_rounded,
                    iconSize: attachmentPanelOpen ? 27 : 29,
                    backgroundColor: AppColors.white,
                    foregroundColor: AppColors.grey700,
                    onPressed: onToggleAttachmentPanel,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(child: _buildTextField(hintText: 'Enter a message')),
                const SizedBox(width: 4),
                _ComposerLastLineAction(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 140),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder:
                        (Widget child, Animation<double> animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: animation,
                              child: child,
                            ),
                          );
                        },
                    child: canSend
                        ? _ComposerCircleButton(
                            buttonKey: const ValueKey<String>('message-send'),
                            tooltip: 'Send',
                            icon: Icons.arrow_upward_rounded,
                            iconSize: 23,
                            backgroundColor: AppColors.blue500,
                            foregroundColor: AppColors.white,
                            onPressed: onSend,
                          )
                        : _ComposerCircleButton(
                            buttonKey: const ValueKey<String>('message-voice'),
                            tooltip: 'Voice message',
                            icon: Icons.graphic_eq_rounded,
                            iconSize: 25,
                            backgroundColor: AppColors.white,
                            foregroundColor: AppColors.grey700,
                            onPressed: () {},
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReplyComposer({
    required String replyTitle,
    required String replyPreview,
    required bool canSend,
  }) {
    return ClipRRect(
      key: const ValueKey<String>('reply-composer'),
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      child: ColoredBox(
        key: const ValueKey<String>('reply-composer-surface'),
        color: AppColors.grey50,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 10, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            replyTitle,
                            key: const ValueKey<String>('reply-composer-title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.typography6.copyWith(
                              color: AppColors.grey900,
                              fontWeight: AppTypography.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            replyPreview,
                            key: const ValueKey<String>(
                              'reply-composer-preview',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.typography6.copyWith(
                              color: AppColors.grey700,
                              fontWeight: AppTypography.regular,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _ReplyActionSlot(
                    child: SizedBox.square(
                      key: const ValueKey<String>('reply-cancel'),
                      dimension: 34,
                      child: Material(
                        color: AppColors.white,
                        shape: const CircleBorder(
                          side: BorderSide(color: AppColors.grey200),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onCancelReply,
                          child: const Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: AppColors.grey700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 50),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _buildTextField(
                        hintText: 'Reply to message...',
                        horizontalContentPadding: 0,
                      ),
                    ),
                    const SizedBox(width: 4),
                    _ComposerLastLineAction(
                      child: _ReplyActionSlot(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 140),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder:
                              (Widget child, Animation<double> animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  ),
                                );
                              },
                          child: canSend
                              ? _ComposerCircleButton(
                                  buttonKey: const ValueKey<String>(
                                    'message-send',
                                  ),
                                  tooltip: 'Send',
                                  icon: Icons.arrow_upward_rounded,
                                  iconSize: 23,
                                  backgroundColor: AppColors.blue500,
                                  foregroundColor: AppColors.white,
                                  onPressed: onSend,
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey<String>(
                                    'reply-action-placeholder',
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditComposer({
    required String originalContent,
    required bool canSaveEdit,
  }) {
    return ClipRRect(
      key: const ValueKey<String>('edit-composer'),
      borderRadius: const BorderRadius.all(Radius.circular(28)),
      child: ColoredBox(
        key: const ValueKey<String>('edit-composer-surface'),
        color: AppColors.grey50,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 10, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Edit message',
                            key: const ValueKey<String>('edit-composer-title'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.typography6.copyWith(
                              color: AppColors.grey900,
                              fontWeight: AppTypography.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            originalContent,
                            key: const ValueKey<String>(
                              'edit-composer-preview',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.typography6.copyWith(
                              color: AppColors.grey700,
                              fontWeight: AppTypography.regular,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _ReplyActionSlot(
                    child: SizedBox.square(
                      key: const ValueKey<String>('edit-cancel'),
                      dimension: 34,
                      child: Material(
                        color: AppColors.white,
                        shape: const CircleBorder(
                          side: BorderSide(color: AppColors.grey200),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onCancelEdit,
                          child: const Icon(
                            Icons.close_rounded,
                            size: 20,
                            color: AppColors.grey700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 50),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _buildTextField(
                        hintText: '',
                        horizontalContentPadding: 0,
                      ),
                    ),
                    const SizedBox(width: 4),
                    _ComposerLastLineAction(
                      child: _ReplyActionSlot(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 140),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          transitionBuilder:
                              (Widget child, Animation<double> animation) {
                                return FadeTransition(
                                  opacity: animation,
                                  child: ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  ),
                                );
                              },
                          child: canSaveEdit
                              ? _ComposerCircleButton(
                                  buttonKey: const ValueKey<String>(
                                    'edit-save',
                                  ),
                                  tooltip: 'Save edit',
                                  icon: Icons.check_rounded,
                                  iconSize: 24,
                                  backgroundColor: AppColors.grey900,
                                  foregroundColor: AppColors.white,
                                  onPressed: onSaveEdit,
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey<String>(
                                    'edit-action-placeholder',
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String hintText,
    double horizontalContentPadding = 4,
  }) {
    return KeyedSubtree(
      key: inputHostKey,
      child: TextField(
        key: const ValueKey<String>('message-input'),
        controller: controller,
        focusNode: focusNode,
        onTap: onInputTap,
        onChanged: onTextChanged,
        minLines: 1,
        maxLines: 4,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        cursorColor: AppColors.blue500,
        style: AppTypography.subTypography10.copyWith(
          color: AppColors.grey900,
          fontWeight: AppTypography.regular,
        ),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: AppTypography.subTypography10.copyWith(
            color: AppColors.grey500,
            fontWeight: AppTypography.regular,
          ),
          filled: false,
          fillColor: Colors.transparent,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: horizontalContentPadding,
            vertical: 12,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
        ),
      ),
    );
  }
}

final class _ReplyActionSlot extends StatelessWidget {
  const _ReplyActionSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(dimension: 42, child: Center(child: child));
  }
}

final class _ComposerLastLineAction extends StatelessWidget {
  const _ComposerLastLineAction({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(offset: const Offset(0, -2), child: child);
  }
}

final class _ComposerCircleButton extends StatelessWidget {
  const _ComposerCircleButton({
    required this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.iconSize,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        key: buttonKey,
        dimension: 42,
        child: Material(
          color: backgroundColor,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(scale: animation, child: child),
                );
              },
              child: Icon(
                icon,
                key: ValueKey<String>(
                  '${icon.codePoint}-'
                  '${icon.fontFamily}',
                ),
                size: iconSize,
                color: foregroundColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
