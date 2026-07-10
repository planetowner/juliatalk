import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:record/record.dart';

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

final RegExp _messageUrlPattern = RegExp(
  r'''(?:(?:https?):\/\/|www\.)[^\s<>'"]+''',
  caseSensitive: false,
);

const String _trailingUrlPunctuation = '.,!?;:)]}…';

const double _messageToComposerGap = 12;

const double _attachmentPanelFallbackHeight = 302;

const Duration _bottomSurfaceAnimationDuration = Duration(milliseconds: 180);

const Duration _outgoingCallNoAnswerTimeout = Duration(seconds: 30);

typedef _MessageLongPressCallback =
    Future<void> Function(ChatMessage message, GlobalKey bubbleKey);

typedef _MessageBubbleKeyFor = GlobalKey Function(String messageId);

typedef _ReplyQuoteTapCallback =
    Future<void> Function({
      required String replyMessageId,
      required String originalMessageId,
    });

typedef _ReplySelectedCallback =
    void Function(ChatMessage message, String displayedContent);

typedef _EditSelectedCallback = void Function(ChatMessage message);

typedef _PhotoMessageTapCallback =
    void Function(ChatMessage message, int photoIndex);

typedef ChatTextMessageSender =
    Future<ChatMessage> Function({
      required String content,
      ChatReplyReference? replyTo,
    });

typedef ChatPhotoMessageSender =
    Future<List<ChatMessage>> Function({
      required List<ChatPhotoAttachment> attachments,
      required bool collage,
      ChatReplyReference? replyTo,
    });

typedef ChatFileMessageSender =
    Future<ChatMessage> Function({
      required ChatFileAttachment file,
      ChatReplyReference? replyTo,
    });

typedef ChatVoiceMemoMessageSender =
    Future<ChatMessage> Function({
      required ChatVoiceMemoAttachment voiceMemo,
      ChatReplyReference? replyTo,
    });

typedef ChatCallMessageSender =
    Future<ChatMessage> Function({required ChatCallAttachment call});

typedef ChatMediaAssetAccessUrlCreator =
    Future<Uri> Function({required String mediaAssetId});

typedef ChatTextMessageEditor =
    Future<ChatMessage> Function({
      required String messageId,
      required String content,
    });

typedef ChatMessageTranslator = Future<String?> Function(ChatMessage message);

typedef ChatMessageDeleter = Future<void> Function({required String messageId});

enum _CallNowAction { voice, video }

enum _AudioOutputRoute { phone, speaker, bluetooth }

enum _VoiceMemoSheetMode { idle, recording, recorded, playing }

final class _SearchMatch {
  const _SearchMatch({required this.start, required this.end});

  final int start;
  final int end;
}

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

final class ChatConversationView extends StatefulWidget {
  const ChatConversationView({
    super.key,
    this.photoLibrary,
    this.initialMessages,
    this.currentUserId = _currentUserId,
    this.currentUserName = _currentUserName,
    this.currentUserPreferredLanguage = _currentUserPreferredLanguage,
    this.otherParticipantId = _otherParticipantId,
    this.otherParticipantName = _otherParticipantName,
    this.onSendTextMessage,
    this.onSendPhotoMessages,
    this.onSendFileMessage,
    this.onSendVoiceMemoMessage,
    this.onSendCallMessage,
    this.onCreateMediaAssetAccessUrl,
    this.onEditTextMessage,
    this.onTranslateMessage,
    this.onDeleteMessage,
    this.translationDelay = Duration.zero,
    this.initialClock,
    this.nextLocalMessageId = 1,
  });

  final ChatPhotoLibrary? photoLibrary;
  final List<ChatMessage>? initialMessages;
  final String currentUserId;
  final String currentUserName;
  final String currentUserPreferredLanguage;
  final String otherParticipantId;
  final String otherParticipantName;
  final ChatTextMessageSender? onSendTextMessage;
  final ChatPhotoMessageSender? onSendPhotoMessages;
  final ChatFileMessageSender? onSendFileMessage;
  final ChatVoiceMemoMessageSender? onSendVoiceMemoMessage;
  final ChatCallMessageSender? onSendCallMessage;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ChatTextMessageEditor? onEditTextMessage;
  final ChatMessageTranslator? onTranslateMessage;
  final ChatMessageDeleter? onDeleteMessage;
  final Duration translationDelay;
  final DateTime? initialClock;
  final int nextLocalMessageId;

  static const String _currentUserId = '1';
  static const String _currentUserName = 'Me';
  static const String _currentUserPreferredLanguage = 'ko';
  static const String _otherParticipantId = '2';
  static const String _otherParticipantName = 'Lia';
  static const Color _chatBackgroundColor = AppColors.white;

  @override
  State<ChatConversationView> createState() {
    return _ChatConversationViewState();
  }
}

final class _ChatConversationViewState extends State<ChatConversationView>
    with WidgetsBindingObserver {
  final GlobalKey<_MessageListState> _messageListKey =
      GlobalKey<_MessageListState>();

  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final GlobalKey _messageInputHostKey = GlobalKey();
  final GlobalKey _composerMeasureKey = GlobalKey();
  final Map<String, Future<Uri>> _mediaAssetAccessUrlFutures =
      <String, Future<Uri>>{};
  late final ChatMediaAssetAccessUrlCreator _mediaAssetAccessUrlCreator =
      _createCachedMediaAssetAccessUrl;

  late final ChatPhotoLibrary _photoLibrary;

  ChatMessage? _replyingToMessage;
  String? _replyingToContent;
  ChatMessage? _editingMessage;
  String? _editingOriginalContent;

  Timer? _keyboardTransitionTimer;
  Timer? _keyboardDismissSettleTimer;
  Timer? _composerResizeTimer;
  Timer? _bottomSurfaceHoldTimer;
  Timer? _voiceCallConnectionTimer;
  Timer? _voiceCallTicker;

  bool _keyboardTransitionActive = false;
  bool _pinBottomDuringComposerResize = false;
  bool _pinBottomAfterKeyboardDismiss = false;
  bool _postSendBottomSettlePending = false;

  bool _attachmentPanelOpen = false;
  bool _photoPickerOpen = false;

  bool _photoPickerExpanded = false;
  bool _photoPickerDragging = false;

  double? _photoPickerCollapsedHeight;
  double? _photoPickerHeight;

  double _lastKeyboardHeight = _attachmentPanelFallbackHeight;
  double _observedKeyboardHeight = 0;

  double? _heldBottomSurfaceHeight;

  DateTime? _voiceCallStartedAt;
  DateTime? _voiceCallConnectedAt;
  bool _voiceCallScreenVisible = false;
  bool _voiceCallMuted = false;
  _AudioOutputRoute _audioOutputRoute = _AudioOutputRoute.speaker;

  bool _searchModeActive = false;
  bool _searchDateSheetOpen = false;
  String _searchQuery = '';
  List<String> _searchResultMessageIds = const <String>[];
  int? _searchResultIndex;
  DateTime? _selectedSearchDate;

  @override
  void initState() {
    super.initState();

    _photoLibrary = widget.photoLibrary ?? PhotoManagerChatPhotoLibrary();

    WidgetsBinding.instance.addObserver(this);
    _messageFocusNode.addListener(_handleMessageFocusChanged);
  }

  @override
  void didUpdateWidget(covariant ChatConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.onCreateMediaAssetAccessUrl !=
        widget.onCreateMediaAssetAccessUrl) {
      _mediaAssetAccessUrlFutures.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _messageFocusNode.removeListener(_handleMessageFocusChanged);

    _keyboardTransitionTimer?.cancel();
    _keyboardDismissSettleTimer?.cancel();
    _composerResizeTimer?.cancel();
    _bottomSurfaceHoldTimer?.cancel();
    _voiceCallConnectionTimer?.cancel();
    _voiceCallTicker?.cancel();

    _messageController.dispose();
    _messageFocusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();

    super.dispose();
  }

  ChatMediaAssetAccessUrlCreator? get _cachedMediaAssetAccessUrlCreator {
    if (widget.onCreateMediaAssetAccessUrl == null) {
      return null;
    }

    return _mediaAssetAccessUrlCreator;
  }

  Future<Uri> _createCachedMediaAssetAccessUrl({required String mediaAssetId}) {
    return _mediaAssetAccessUrlFutures.putIfAbsent(mediaAssetId, () {
      return _loadMediaAssetAccessUrl(mediaAssetId);
    });
  }

  Future<Uri> _loadMediaAssetAccessUrl(String mediaAssetId) async {
    try {
      final ChatMediaAssetAccessUrlCreator? createAccessUrl =
          widget.onCreateMediaAssetAccessUrl;

      if (createAccessUrl == null) {
        throw StateError('Media asset access URL creator is unavailable.');
      }

      return await createAccessUrl(mediaAssetId: mediaAssetId);
    } catch (_) {
      _mediaAssetAccessUrlFutures.remove(mediaAssetId);
      rethrow;
    }
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
      _heldBottomSurfaceHeight = math.max(
        _lastKeyboardHeight,
        _attachmentPanelFallbackHeight,
      );
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
      if (keyboardHeight > _attachmentPanelFallbackHeight * 0.5) {
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
    if (!_attachmentPanelOpen || _photoPickerOpen) {
      return;
    }

    final BuildContext? composerContext = _composerMeasureKey.currentContext;

    final RenderObject? renderObject = composerContext?.findRenderObject();

    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openPhotoPicker();
        }
      });

      return;
    }

    final double attachmentPanelHeight = math.max(
      _attachmentPanelFallbackHeight,
      math.max(_lastKeyboardHeight, MediaQuery.viewPaddingOf(context).bottom),
    );

    // Photo 선택기의 최초 높이는 임의 비율이 아니라
    // 현재 작성창 + 현재 첨부 패널의 실제 합산 높이다.
    //
    // 따라서 Photo로 전환해도 패널의 위쪽 경계가
    // 기존 입력창 위쪽 경계와 정확히 같은 위치에 남는다.
    final double collapsedHeight =
        renderObject.size.height + attachmentPanelHeight;

    _startBottomSurfacePinIfNeeded();

    setState(() {
      _attachmentPanelOpen = false;
      _photoPickerOpen = true;

      _photoPickerExpanded = false;
      _photoPickerDragging = false;

      _photoPickerCollapsedHeight = collapsedHeight;

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

  void _handlePhotoPickerDragStart(DragStartDetails details) {
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
    final double? currentHeight = _photoPickerHeight;

    final double? collapsedHeight = _photoPickerCollapsedHeight;

    if (!_photoPickerOpen || currentHeight == null || collapsedHeight == null) {
      return;
    }

    final double nextHeight = (currentHeight - details.delta.dy)
        .clamp(collapsedHeight, maximumHeight)
        .toDouble();

    setState(() {
      _photoPickerHeight = nextHeight;

      _photoPickerExpanded = nextHeight > collapsedHeight + 32;
    });
  }

  void _handlePhotoPickerDragEnd(
    DragEndDetails details, {
    required double maximumHeight,
  }) {
    final double? currentHeight = _photoPickerHeight;

    final double? collapsedHeight = _photoPickerCollapsedHeight;

    if (!_photoPickerOpen || currentHeight == null || collapsedHeight == null) {
      return;
    }

    final double velocity = details.primaryVelocity ?? 0;

    final double expansionThreshold =
        collapsedHeight + ((maximumHeight - collapsedHeight) * 0.34);

    final bool shouldExpand;

    if (velocity <= -300) {
      shouldExpand = true;
    } else if (velocity >= 300) {
      shouldExpand = false;
    } else {
      shouldExpand = currentHeight >= expansionThreshold;
    }

    setState(() {
      _photoPickerDragging = false;
      _photoPickerExpanded = shouldExpand;

      _photoPickerHeight = shouldExpand ? maximumHeight : collapsedHeight;
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

  // 첨부(사진·카메라·파일) 전송 직후 진행 중인 전환·타이머를 정리하고
  // 하단 서피스를 닫은 뒤 최신 메시지로 스크롤한다.
  void _dismissComposerAfterAttachmentSend() {
    _stopKeyboardTransition();
    _stopComposerResizePin();
    _bottomSurfaceHoldTimer?.cancel();

    _messageFocusNode.unfocus();

    setState(_resetBottomSurfaceState);

    _scheduleScrollToBottom(animate: true);
  }

  ChatReplyReference? _currentReplyReference() {
    final ChatMessage? replyingToMessage = _replyingToMessage;
    final String? replyingToContent = _replyingToContent;

    if (replyingToMessage == null || replyingToContent == null) {
      return null;
    }

    return ChatReplyReference(
      messageId: replyingToMessage.id,
      senderId: replyingToMessage.senderId,
      content: replyingToContent,
    );
  }

  void _showChatOperationFailure(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sendSelectedPhotos(ChatPhotoSelectionResult result) async {
    final List<ChatPhotoAttachment?> loadedAttachments =
        await Future.wait<ChatPhotoAttachment?>(
          result.assets.map((ChatPhotoAsset asset) async {
            final ChatPhotoFile? originalFile = await _photoLibrary
                .loadOriginalFile(assetId: asset.id);

            if (originalFile == null) {
              return null;
            }

            final Uint8List? previewBytes = await _photoLibrary
                .loadMessagePreview(assetId: asset.id);

            return ChatPhotoAttachment(
              assetId: asset.id,
              previewBytes: previewBytes ?? originalFile.bytes,
              width: asset.width,
              height: asset.height,
              fileName: originalFile.fileName,
              mimeType: originalFile.mimeType,
              sizeBytes: originalFile.sizeBytes,
              uploadBytes: originalFile.bytes,
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

    final ChatPhotoMessageSender? sender = widget.onSendPhotoMessages;

    if (sender == null) {
      messageListState.addOutgoingPhotoMessages(
        attachments: attachments,
        collage: result.collage,
      );
    } else {
      try {
        final List<ChatMessage> messages = await sender(
          attachments: attachments,
          collage: result.collage,
          replyTo: _currentReplyReference(),
        );

        if (!mounted) {
          return;
        }

        messageListState.addMessages(messages);
      } catch (_) {
        _showChatOperationFailure('Photo sending failed.');
        return;
      }
    }

    _dismissComposerAfterAttachmentSend();
  }

  void _openPhotoViewer(ChatMessage message, int initialIndex) {
    final List<ChatPhotoAttachment> attachments = message.photoAttachments;

    if (attachments.isEmpty) {
      return;
    }

    _dismissComposerSurface();

    final int resolvedInitialIndex = initialIndex.clamp(
      0,
      attachments.length - 1,
    );

    final String senderName = message.senderId == widget.currentUserId
        ? widget.currentUserName
        : widget.otherParticipantName;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) {
          return _PhotoViewerScreen(
            attachments: attachments,
            initialIndex: resolvedInitialIndex,
            senderName: senderName,
            sentAt: message.createdAt,
            onCreateMediaAssetAccessUrl: _cachedMediaAssetAccessUrlCreator,
          );
        },
      ),
    );
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
          const SnackBar(content: Text('The camera is not available.')),
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

    final ChatPhotoAttachment attachment = ChatPhotoAttachment(
      assetId: 'camera-${capture.name}',
      previewBytes: bytes,
      width: width > 0 ? width : 1080,
      height: height > 0 ? height : 1440,
      fileName: capture.name,
      mimeType: capture.mimeType ?? _mimeTypeForFileName(capture.name),
      sizeBytes: bytes.length,
      uploadBytes: bytes,
    );

    final ChatPhotoMessageSender? sender = widget.onSendPhotoMessages;

    if (sender == null) {
      messageListState.addOutgoingPhotoMessages(
        attachments: <ChatPhotoAttachment>[attachment],
        collage: false,
      );
    } else {
      try {
        final List<ChatMessage> messages = await sender(
          attachments: <ChatPhotoAttachment>[attachment],
          collage: false,
          replyTo: _currentReplyReference(),
        );

        if (!mounted) {
          return;
        }

        messageListState.addMessages(messages);
      } catch (_) {
        _showChatOperationFailure('Photo sending failed.');
        return;
      }
    }

    _dismissComposerAfterAttachmentSend();
  }

  Future<void> _openFile() async {
    // file_picker가 기기의 기본 문서 선택기(iOS는 Files 앱)를 연다.
    // 사용자가 직접 파일을 고르는 방식이라 별도 권한 팝업이 없다.
    FilePickerResult? result;

    try {
      result = await FilePicker.platform.pickFiles(withData: true);
    } on PlatformException catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('The file picker is not available.')),
        );

      return;
    }

    // 사용자가 선택을 취소하면 아무것도 전송하지 않는다.
    if (!mounted || result == null || result.files.isEmpty) {
      return;
    }

    final ScaffoldMessengerState scaffoldMessenger = ScaffoldMessenger.of(
      context,
    );
    final PlatformFile file = result.files.first;
    Uint8List? fileBytes = file.bytes;

    if (fileBytes == null && file.path != null) {
      fileBytes = await File(file.path!).readAsBytes();
    }

    if (!mounted || fileBytes == null || fileBytes.isEmpty) {
      scaffoldMessenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('The selected file could not be read.')),
        );

      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final ChatFileAttachment attachment = ChatFileAttachment(
      name: file.name,
      sizeBytes: fileBytes.length,
      mimeType: _mimeTypeForFileName(file.name),
      uploadBytes: fileBytes,
    );

    final ChatFileMessageSender? sender = widget.onSendFileMessage;

    if (sender == null) {
      messageListState.addOutgoingFileMessage(
        name: attachment.name,
        sizeBytes: attachment.sizeBytes,
      );
    } else {
      try {
        final ChatMessage message = await sender(
          file: attachment,
          replyTo: _currentReplyReference(),
        );

        if (!mounted) {
          return;
        }

        messageListState.addMessage(message);
      } catch (_) {
        _showChatOperationFailure('File sending failed.');
        return;
      }
    }

    _dismissComposerAfterAttachmentSend();
  }

  Future<void> _openVoiceMemoSheet() async {
    _dismissComposerSurface();

    final ChatVoiceMemoAttachment? voiceMemo =
        await showModalBottomSheet<ChatVoiceMemoAttachment>(
          context: context,
          backgroundColor: Colors.transparent,
          barrierColor: AppColors.black.withAlpha(112),
          isScrollControlled: true,
          builder: (BuildContext context) {
            return const _VoiceMemoSheet();
          },
        );

    if (!mounted || voiceMemo == null) {
      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final ChatVoiceMemoMessageSender? sender = widget.onSendVoiceMemoMessage;

    if (sender == null) {
      messageListState.addOutgoingVoiceMemoMessage(voiceMemo: voiceMemo);
    } else {
      try {
        final ChatMessage message = await sender(
          voiceMemo: voiceMemo,
          replyTo: _currentReplyReference(),
        );

        if (!mounted) {
          return;
        }

        messageListState.addMessage(message);
      } catch (_) {
        _showChatOperationFailure('Voice memo sending failed.');
        return;
      }
    }

    _dismissComposerAfterAttachmentSend();
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
    final double previousKeyboardHeight = _observedKeyboardHeight;

    _observedKeyboardHeight = keyboardHeight;

    // 키보드가 내려가는 중간 높이를 저장하면 첨부 패널이
    // safe area 높이만큼만 열릴 수 있다. 올라가거나 열린 상태의
    // 유효한 높이만 기억한다.
    final bool keyboardIsOpeningOrStable =
        keyboardHeight >= previousKeyboardHeight - 0.5;

    if (keyboardHeight > 0.5 &&
        !_attachmentPanelOpen &&
        keyboardIsOpeningOrStable) {
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

    _handleKeyboardDismissViewportChange(
      previousKeyboardHeight: previousKeyboardHeight,
      keyboardHeight: keyboardHeight,
    );

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

  void _markPostSendBottomSettlePending() {
    _postSendBottomSettlePending = true;
    _pinBottomAfterKeyboardDismiss = true;
  }

  void _handleKeyboardDismissViewportChange({
    required double previousKeyboardHeight,
    required double keyboardHeight,
  }) {
    final bool keyboardWasVisible = previousKeyboardHeight > 0.5;

    final bool keyboardIsClosing =
        keyboardWasVisible && keyboardHeight < previousKeyboardHeight - 0.5;

    final bool keyboardIsClosedAfterSend =
        _postSendBottomSettlePending && keyboardHeight <= 0.5;

    if (!keyboardIsClosing && !keyboardIsClosedAfterSend) {
      if (keyboardHeight > previousKeyboardHeight + 0.5) {
        _pinBottomAfterKeyboardDismiss = false;
        _keyboardDismissSettleTimer?.cancel();
        _keyboardDismissSettleTimer = null;
      }

      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    final bool shouldKeepBottomPinned =
        _postSendBottomSettlePending ||
        _pinBottomAfterKeyboardDismiss ||
        (messageListState?.isNearBottom ?? false);

    if (!shouldKeepBottomPinned) {
      return;
    }

    _pinBottomAfterKeyboardDismiss = true;
    _scheduleKeyboardDismissBottomSettle();
  }

  void _scheduleKeyboardDismissBottomSettle() {
    _keyboardDismissSettleTimer?.cancel();

    final _MessageListState? currentMessageListState =
        _messageListKey.currentState;

    if (currentMessageListState != null) {
      unawaited(currentMessageListState.scrollToBottom(animate: false));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pinBottomAfterKeyboardDismiss) {
        return;
      }

      final _MessageListState? messageListState = _messageListKey.currentState;

      if (messageListState == null) {
        return;
      }

      unawaited(messageListState.scrollToBottom(animate: false));
    });

    _keyboardDismissSettleTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) {
        return;
      }

      final _MessageListState? messageListState = _messageListKey.currentState;

      if (messageListState != null) {
        unawaited(messageListState.scrollToBottom(animate: false));
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        final _MessageListState? settledMessageListState =
            _messageListKey.currentState;

        if (settledMessageListState != null) {
          unawaited(settledMessageListState.scrollToBottom(animate: false));
        }

        _pinBottomAfterKeyboardDismiss = false;
        _postSendBottomSettlePending = false;
      });
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

  String? get _currentSearchMessageId {
    final int? resultIndex = _searchResultIndex;

    if (resultIndex == null ||
        resultIndex < 0 ||
        resultIndex >= _searchResultMessageIds.length) {
      return null;
    }

    return _searchResultMessageIds[resultIndex];
  }

  bool get _hasSearchQuery {
    return _searchQuery.trim().isNotEmpty;
  }

  bool get _canMoveToPreviousSearchResult {
    final int? resultIndex = _searchResultIndex;

    return _hasSearchQuery && resultIndex != null && resultIndex > 0;
  }

  bool get _canMoveToNextSearchResult {
    final int? resultIndex = _searchResultIndex;

    return _hasSearchQuery &&
        resultIndex != null &&
        resultIndex < _searchResultMessageIds.length - 1;
  }

  void _enterSearchMode() {
    if (_searchModeActive) {
      _searchFocusNode.requestFocus();
      return;
    }

    _dismissComposerSurface();

    setState(() {
      _searchModeActive = true;
      _searchQuery = _searchController.text;
      _searchResultMessageIds = const <String>[];
      _searchResultIndex = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _searchFocusNode.requestFocus();
      _syncSearchResults();
    });
  }

  void _exitSearchMode() {
    if (!_searchModeActive) {
      return;
    }

    if (_searchDateSheetOpen) {
      Navigator.of(context).maybePop();
      _searchDateSheetOpen = false;
    }

    _searchFocusNode.unfocus();
    _searchController.clear();

    setState(() {
      _searchModeActive = false;
      _searchQuery = '';
      _searchResultMessageIds = const <String>[];
      _searchResultIndex = null;
      _selectedSearchDate = null;
    });
  }

  void _syncSearchResults({bool scrollToFirstResult = false}) {
    if (!_searchModeActive) {
      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;
    final List<String> resultMessageIds =
        messageListState?.searchMessageIds(_searchQuery) ?? const <String>[];

    final int? nextIndex = resultMessageIds.isEmpty ? null : 0;

    setState(() {
      _searchResultMessageIds = resultMessageIds;
      _searchResultIndex = nextIndex;
    });

    if (scrollToFirstResult && nextIndex != null) {
      _scrollToCurrentSearchResult();
    }
  }

  void _handleSearchQueryChanged(String value) {
    setState(() {
      _searchQuery = value;
    });

    _syncSearchResults(scrollToFirstResult: value.trim().isNotEmpty);
  }

  void _clearSearchQuery() {
    if (_searchController.text.isEmpty) {
      return;
    }

    _searchController.clear();
    _handleSearchQueryChanged('');
  }

  void _submitSearch(String value) {
    _syncSearchResults(scrollToFirstResult: true);
    _searchFocusNode.unfocus();
  }

  void _scrollToCurrentSearchResult() {
    final String? messageId = _currentSearchMessageId;

    if (messageId == null) {
      return;
    }

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    unawaited(messageListState.scrollToSearchMessage(messageId));
  }

  void _moveToPreviousSearchResult() {
    if (!_canMoveToPreviousSearchResult) {
      return;
    }

    setState(() {
      _searchResultIndex = _searchResultIndex! - 1;
    });

    _scrollToCurrentSearchResult();
  }

  void _moveToNextSearchResult() {
    if (!_canMoveToNextSearchResult) {
      return;
    }

    setState(() {
      _searchResultIndex = _searchResultIndex! + 1;
    });

    _scrollToCurrentSearchResult();
  }

  Future<void> _openSearchDateSheet() async {
    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final Set<DateTime> searchableDates = messageListState
        .searchableMessageDates();

    if (searchableDates.isEmpty) {
      return;
    }

    _searchFocusNode.unfocus();

    setState(() {
      _searchDateSheetOpen = true;
    });

    final ChatMessage? currentSearchMessage = _currentSearchMessageId == null
        ? null
        : messageListState.findMessage(_currentSearchMessageId!);

    final DateTime latestSearchableDate = searchableDates.reduce(
      (DateTime a, DateTime b) => a.isBefore(b) ? b : a,
    );

    final DateTime initialDate =
        _selectedSearchDate ??
        (currentSearchMessage == null
            ? latestSearchableDate
            : _dateOnly(currentSearchMessage.createdAt));

    final DateTime? selectedDate = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.black.withAlpha(112),
      isScrollControlled: true,
      builder: (BuildContext context) {
        return _SearchDateSheet(
          initialDate: initialDate,
          enabledDates: searchableDates,
        );
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _searchDateSheetOpen = false;
    });

    if (selectedDate == null) {
      return;
    }

    _handleSearchDateSelected(selectedDate);
  }

  void _handleSearchDateSelected(DateTime selectedDate) {
    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final DateTime normalizedDate = _dateOnly(selectedDate);

    setState(() {
      _selectedSearchDate = normalizedDate;
    });

    if (_hasSearchQuery && _searchResultMessageIds.isNotEmpty) {
      final int matchingIndex = _searchResultMessageIds.indexWhere((String id) {
        final ChatMessage? message = messageListState.findMessage(id);

        return message != null &&
            _dateOnly(message.createdAt) == normalizedDate;
      });

      if (matchingIndex != -1) {
        setState(() {
          _searchResultIndex = matchingIndex;
        });

        _scrollToCurrentSearchResult();
        return;
      }
    }

    unawaited(messageListState.scrollToSearchDate(normalizedDate));
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

  Future<void> _saveEdit() async {
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

    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final ChatTextMessageEditor? editor = widget.onEditTextMessage;

    final bool didUpdate;

    if (editor == null) {
      didUpdate = messageListState.updateMessageContent(
        messageId: editingMessage.id,
        content: updatedContent,
      );
    } else {
      try {
        final ChatMessage updatedMessage = await editor(
          messageId: editingMessage.id,
          content: updatedContent,
        );

        if (!mounted) {
          return;
        }

        didUpdate = messageListState.replaceMessage(updatedMessage);
      } catch (_) {
        _showChatOperationFailure('Message editing failed.');
        return;
      }
    }

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

  Future<void> _sendMessage() async {
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

    final ChatReplyReference? replyTo = _currentReplyReference();

    _stopKeyboardTransition();
    _stopComposerResizePin();
    setState(_markPostSendBottomSettlePending);

    final ChatTextMessageSender? sender = widget.onSendTextMessage;

    if (sender == null) {
      messageListState.addOutgoingMessage(content: content, replyTo: replyTo);
    } else {
      try {
        final ChatMessage message = await sender(
          content: content,
          replyTo: replyTo,
        );

        if (!mounted) {
          return;
        }

        messageListState.addMessage(message);
      } catch (_) {
        if (mounted) {
          setState(() {
            _pinBottomAfterKeyboardDismiss = false;
            _postSendBottomSettlePending = false;
          });
        }

        _showChatOperationFailure('Message sending failed.');
        return;
      }
    }

    _messageController.clear();

    setState(() {
      _replyingToMessage = null;
      _replyingToContent = null;
    });

    _restoreComposerFocusAfterModeChange(animateInitialScroll: true);
  }

  bool get _hasActiveVoiceCall {
    return _voiceCallStartedAt != null;
  }

  bool get _voiceCallConnected {
    return _voiceCallConnectedAt != null;
  }

  Duration get _voiceCallElapsed {
    final DateTime? connectedAt = _voiceCallConnectedAt;

    if (connectedAt == null) {
      return Duration.zero;
    }

    return DateTime.now().difference(connectedAt);
  }

  Future<void> _openCallNowSheet() async {
    if (_hasActiveVoiceCall) {
      _showVoiceCallScreen();
      return;
    }

    _dismissComposerSurface();

    final _CallNowAction? action = await showModalBottomSheet<_CallNowAction>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: AppColors.black.withAlpha(112),
      isScrollControlled: true,
      builder: (BuildContext context) {
        return const _CallNowSheet();
      },
    );

    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case _CallNowAction.voice:
        _startVoiceCall();
      case _CallNowAction.video:
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Video call is not available yet.')),
          );
    }
  }

  void _startVoiceCall() {
    _voiceCallConnectionTimer?.cancel();
    _voiceCallTicker?.cancel();

    unawaited(
      _addCallMessage(
        outcome: ChatCallOutcome.started,
        duration: Duration.zero,
        advanceClock: true,
      ),
    );

    setState(() {
      _voiceCallStartedAt = DateTime.now();
      _voiceCallConnectedAt = null;
      _voiceCallScreenVisible = true;
      _voiceCallMuted = false;
      _audioOutputRoute = _AudioOutputRoute.speaker;
    });

    _voiceCallConnectionTimer = Timer(
      _outgoingCallNoAnswerTimeout,
      _handleOutgoingCallNoAnswer,
    );
  }

  void _handleOutgoingCallNoAnswer() {
    if (!mounted || !_hasActiveVoiceCall || _voiceCallConnected) {
      return;
    }

    _voiceCallConnectionTimer?.cancel();
    _voiceCallConnectionTimer = null;
    _voiceCallTicker?.cancel();

    setState(() {
      _voiceCallStartedAt = null;
      _voiceCallConnectedAt = null;
      _voiceCallScreenVisible = false;
      _voiceCallMuted = false;
      _audioOutputRoute = _AudioOutputRoute.speaker;
    });

    unawaited(
      _addCallMessage(
        outcome: ChatCallOutcome.noAnswer,
        duration: Duration.zero,
        advanceClock: true,
      ),
    );
  }

  Future<void> _addCallMessage({
    required ChatCallOutcome outcome,
    required Duration duration,
    required bool advanceClock,
  }) async {
    final _MessageListState? messageListState = _messageListKey.currentState;

    if (messageListState == null) {
      return;
    }

    final ChatCallMessageSender? sender = widget.onSendCallMessage;

    if (sender == null) {
      messageListState.addOutgoingCallMessage(
        outcome: outcome,
        duration: duration,
        advanceClock: advanceClock,
      );
    } else {
      try {
        final ChatMessage message = await sender(
          call: ChatCallAttachment(
            kind: ChatCallKind.voice,
            outcome: outcome,
            duration: duration,
          ),
        );

        if (!mounted) {
          return;
        }

        messageListState.addMessage(message);
      } catch (_) {
        _showChatOperationFailure('Call record saving failed.');
        return;
      }
    }

    _scheduleScrollToBottom(animate: true);
  }

  void _showVoiceCallScreen() {
    if (!_hasActiveVoiceCall) {
      return;
    }

    setState(() {
      _voiceCallScreenVisible = true;
    });
  }

  void _returnToChatDuringCall() {
    if (!_hasActiveVoiceCall) {
      return;
    }

    setState(() {
      _voiceCallScreenVisible = false;
    });
  }

  void _toggleVoiceCallMute() {
    if (!_hasActiveVoiceCall) {
      return;
    }

    setState(() {
      _voiceCallMuted = !_voiceCallMuted;
    });
  }

  Future<void> _chooseAudioOutputRoute() async {
    if (!_hasActiveVoiceCall) {
      return;
    }

    final _AudioOutputRoute? route =
        await showModalBottomSheet<_AudioOutputRoute>(
          context: context,
          backgroundColor: Colors.transparent,
          barrierColor: AppColors.black.withAlpha(112),
          builder: (BuildContext context) {
            return _AudioOutputSheet(selectedRoute: _audioOutputRoute);
          },
        );

    if (!mounted || route == null) {
      return;
    }

    setState(() {
      _audioOutputRoute = route;
    });
  }

  void _endVoiceCall() {
    if (!_hasActiveVoiceCall) {
      return;
    }

    final bool wasConnected = _voiceCallConnected;
    final Duration duration = _voiceCallElapsed;

    _voiceCallConnectionTimer?.cancel();
    _voiceCallTicker?.cancel();

    setState(() {
      _voiceCallStartedAt = null;
      _voiceCallConnectedAt = null;
      _voiceCallScreenVisible = false;
      _voiceCallMuted = false;
      _audioOutputRoute = _AudioOutputRoute.speaker;
    });

    unawaited(
      _addCallMessage(
        outcome: wasConnected
            ? ChatCallOutcome.ended
            : ChatCallOutcome.cancelled,
        duration: duration,
        advanceClock: true,
      ),
    );
  }

  String _searchCounterText() {
    if (!_hasSearchQuery) {
      return '';
    }

    final int? resultIndex = _searchResultIndex;

    if (resultIndex == null || _searchResultMessageIds.isEmpty) {
      return '0/0';
    }

    return '${resultIndex + 1}/${_searchResultMessageIds.length}';
  }

  @override
  Widget build(BuildContext context) {
    final bool showingVoiceCallScreen =
        _voiceCallScreenVisible && _hasActiveVoiceCall;

    final SystemUiOverlayStyle overlayStyle =
        (showingVoiceCallScreen
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark)
            .copyWith(
              statusBarColor: showingVoiceCallScreen
                  ? AppColors.black
                  : Colors.transparent,
              systemNavigationBarColor: showingVoiceCallScreen
                  ? AppColors.black
                  : ChatConversationView._chatBackgroundColor,
              systemNavigationBarIconBrightness: showingVoiceCallScreen
                  ? Brightness.light
                  : Brightness.dark,
            );

    final MediaQueryData mediaQuery = MediaQuery.of(context);

    final double keyboardHeight = mediaQuery.viewInsets.bottom;

    final double systemBottomPadding = mediaQuery.viewPadding.bottom;

    final double passiveBottomHeight = math.max(
      keyboardHeight,
      systemBottomPadding,
    );

    final double attachmentPanelHeight = math.max(
      _attachmentPanelFallbackHeight,
      math.max(_lastKeyboardHeight, systemBottomPadding),
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
    final double photoPickerMaximumHeight = math.max(
      resolvedPhotoPickerHeight,
      math.min(
        mediaQuery.size.height * 0.89,
        mediaQuery.size.height -
            mediaQuery.padding.top -
            _ChatTopBar.height -
            12,
      ),
    );

    final double bottomSurfaceHeight = _photoPickerOpen
        ? resolvedPhotoPickerHeight
        : _attachmentPanelOpen
        ? attachmentPanelHeight
        : math.max(passiveBottomHeight, _heldBottomSurfaceHeight ?? 0);

    final double searchToolbarBottom = keyboardHeight > 0.5
        ? keyboardHeight + 10
        : systemBottomPadding + 10;

    final bool showActiveVoiceCallBanner =
        !_searchModeActive && _hasActiveVoiceCall && !showingVoiceCallScreen;

    final double messageListBottomPadding = _searchModeActive
        ? searchToolbarBottom + 70
        : _messageToComposerGap;

    final double messageListHeaderInset = showingVoiceCallScreen
        ? 0
        : mediaQuery.padding.top +
              (_searchModeActive
                  ? _ChatSearchTopBar.height
                  : _ChatTopBar.height) +
              (showActiveVoiceCallBanner
                  ? _ActiveVoiceCallBanner.occupiedHeight
                  : 0);

    final double messageListTopPadding = messageListHeaderInset + 8;

    final bool pinMessageListToBottom =
        !_searchModeActive &&
        (_keyboardTransitionActive ||
            _pinBottomDuringComposerResize ||
            _pinBottomAfterKeyboardDismiss ||
            _postSendBottomSettlePending);

    final bool animateBottomSurfaceHeight =
        !_photoPickerDragging &&
        (_photoPickerOpen ||
            _attachmentPanelOpen ||
            _heldBottomSurfaceHeight != null ||
            keyboardHeight <= 0.5);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: showingVoiceCallScreen
            ? AppColors.black
            : ChatConversationView._chatBackgroundColor,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          top: false,
          bottom: false,
          child: Stack(
            children: [
              Column(
                children: [
                  Expanded(
                    child: _MessageList(
                      key: _messageListKey,
                      initialMessages: widget.initialMessages,
                      currentUserId: widget.currentUserId,
                      currentUserPreferredLanguage:
                          widget.currentUserPreferredLanguage,
                      otherParticipantId: widget.otherParticipantId,
                      otherParticipantName: widget.otherParticipantName,
                      onTranslateMessage: widget.onTranslateMessage,
                      onDeleteMessage: widget.onDeleteMessage,
                      onPhotoMessageTap: _openPhotoViewer,
                      onCreateMediaAssetAccessUrl:
                          _cachedMediaAssetAccessUrlCreator,
                      translationDelay: widget.translationDelay,
                      initialClock: widget.initialClock,
                      nextLocalMessageId: widget.nextLocalMessageId,
                      onReplySelected: _beginReply,
                      onEditSelected: _beginEdit,
                      onBackgroundTap: _searchModeActive
                          ? _searchFocusNode.unfocus
                          : _dismissComposerSurface,
                      onPrepareMessageActions: _prepareMessageActions,
                      searchQuery: _searchModeActive ? _searchQuery : '',
                      activeSearchMessageId: _currentSearchMessageId,
                      topPadding: messageListTopPadding,
                      bottomPadding: messageListBottomPadding,
                      pinToBottom: pinMessageListToBottom,
                    ),
                  ),
                  if (!_searchModeActive)
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
                                  currentUserId: widget.currentUserId,
                                  otherParticipantName:
                                      widget.otherParticipantName,
                                  attachmentPanelOpen: _attachmentPanelOpen,
                                  onCancelReply: _cancelReply,
                                  onCancelEdit: _cancelEdit,
                                  onSend: () {
                                    unawaited(_sendMessage());
                                  },
                                  onSaveEdit: () {
                                    unawaited(_saveEdit());
                                  },
                                  onTextChanged: _handleComposerTextChanged,
                                  onToggleAttachmentPanel:
                                      _handleAttachmentButtonPressed,
                                  onInputTap: _handleMessageInputTap,
                                  onVoiceMemoPressed: _openVoiceMemoSheet,
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
                              onCallPressed: _openCallNowSheet,
                              onFilePressed: _openFile,
                              onVoiceMemoPressed: _openVoiceMemoSheet,
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
                              onPhotoPickerDragEnd: (DragEndDetails details) {
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

              if (!showingVoiceCallScreen)
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_searchModeActive)
                        _ChatSearchTopBar(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          hasText: _searchController.text.isNotEmpty,
                          onChanged: _handleSearchQueryChanged,
                          onSubmitted: _submitSearch,
                          onClear: _clearSearchQuery,
                          onCancel: _exitSearchMode,
                        )
                      else
                        _ChatTopBar(
                          participantName: widget.otherParticipantName,
                          onSearchPressed: _enterSearchMode,
                          onCallPressed: _openCallNowSheet,
                        ),
                      if (showActiveVoiceCallBanner)
                        _ActiveVoiceCallBanner(
                          connected: _voiceCallConnected,
                          elapsed: _voiceCallElapsed,
                          onPressed: _showVoiceCallScreen,
                        ),
                    ],
                  ),
                ),

              if (_photoPickerOpen && _photoPickerExpanded)
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  bottom: resolvedPhotoPickerHeight,
                  child: const AbsorbPointer(
                    child: ColoredBox(color: Color(0x52000000)),
                  ),
                ),
              if (showingVoiceCallScreen)
                Positioned.fill(
                  child: _VoiceCallScreen(
                    participantName: widget.otherParticipantName,
                    connected: _voiceCallConnected,
                    elapsed: _voiceCallElapsed,
                    muted: _voiceCallMuted,
                    audioOutputRoute: _audioOutputRoute,
                    onReturnToChat: _returnToChatDuringCall,
                    onToggleMute: _toggleVoiceCallMute,
                    onEndCall: _endVoiceCall,
                    onChooseAudioOutput: _chooseAudioOutputRoute,
                  ),
                ),
              if (_searchModeActive && !showingVoiceCallScreen)
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: searchToolbarBottom,
                  child: _ChatSearchToolbar(
                    counterText: _searchCounterText(),
                    showCounter: _hasSearchQuery,
                    canMovePrevious: _canMoveToPreviousSearchResult,
                    canMoveNext: _canMoveToNextSearchResult,
                    onDateSearchPressed: _openSearchDateSheet,
                    onMovePrevious: _moveToPreviousSearchResult,
                    onMoveNext: _moveToNextSearchResult,
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
  const _ChatTopBar({
    required this.participantName,
    required this.onSearchPressed,
    required this.onCallPressed,
  });

  static const double height = 56;

  final String participantName;
  final VoidCallback onSearchPressed;
  final VoidCallback onCallPressed;

  @override
  Widget build(BuildContext context) {
    final double topPadding = MediaQuery.paddingOf(context).top;

    return _TranslucentTopBarSurface(
      key: const ValueKey<String>('chat-top-bar'),
      height: topPadding + height,
      child: Padding(
        padding: EdgeInsets.only(top: topPadding),
        child: SizedBox(
          height: height,
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: Text(
                  participantName,
                  style: AppTypography.typography4.copyWith(
                    color: AppColors.grey900,
                    fontWeight: AppTypography.bold,
                  ),
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
                        onPressed: onSearchPressed,
                        icon: const Icon(
                          Icons.search_rounded,
                          size: 28,
                          color: AppColors.grey700,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Call',
                        onPressed: onCallPressed,
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
        ),
      ),
    );
  }
}

final class _TranslucentTopBarSurface extends StatelessWidget {
  const _TranslucentTopBarSurface({
    required this.height,
    required this.child,
    super.key,
  });

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: height,
            child: const IgnorePointer(child: _TopBarGradientBlur()),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

final class _TopBarGradientBlur extends StatelessWidget {
  const _TopBarGradientBlur();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _TopBarBlurFade(
          sigma: 64,
          tintAlpha: 38,
          alphas: [255, 255, 255, 220, 96, 0],
          stops: [0, 0.28, 0.46, 0.66, 0.86, 1],
        ),
        const _TopBarBlurFade(
          sigma: 34,
          tintAlpha: 24,
          alphas: [255, 255, 232, 150, 54, 0],
          stops: [0, 0.4, 0.62, 0.82, 0.94, 1],
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.surface.withAlpha(238),
                AppColors.surface.withAlpha(226),
                AppColors.surface.withAlpha(176),
                AppColors.surface.withAlpha(76),
                AppColors.surface.withAlpha(0),
              ],
              stops: [0, 0.3, 0.54, 0.8, 1],
            ),
          ),
        ),
      ],
    );
  }
}

final class _TopBarBlurFade extends StatelessWidget {
  const _TopBarBlurFade({
    required this.sigma,
    required this.tintAlpha,
    required this.alphas,
    required this.stops,
  });

  final double sigma;
  final int tintAlpha;
  final List<int> alphas;
  final List<double> stops;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            for (final int alpha in alphas) AppColors.black.withAlpha(alpha),
          ],
          stops: stops,
        ).createShader(bounds);
      },
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: ColoredBox(
            color: AppColors.surface.withAlpha(tintAlpha),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

final class _ChatSearchTopBar extends StatelessWidget {
  const _ChatSearchTopBar({
    required this.controller,
    required this.focusNode,
    required this.hasText,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
    required this.onCancel,
  });

  static const double height = 56;

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final double topPadding = MediaQuery.paddingOf(context).top;

    return _TranslucentTopBarSurface(
      key: const ValueKey<String>('chat-search-top-bar'),
      height: topPadding + height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, topPadding + 7, 16, 7),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 42,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.grey100.withAlpha(204),
                    borderRadius: AppRadius.borderRadius12,
                  ),
                  child: TextField(
                    key: const ValueKey<String>('chat-search-input'),
                    controller: controller,
                    focusNode: focusNode,
                    autofocus: true,
                    textAlignVertical: TextAlignVertical.center,
                    textInputAction: TextInputAction.search,
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                    cursorColor: AppColors.primary,
                    style: AppTypography.typography4.copyWith(
                      color: AppColors.grey900,
                      fontWeight: AppTypography.medium,
                    ),
                    decoration: InputDecoration(
                      // 테마의 filled:true(grey100)가 사각형으로 채워져
                      // DecoratedBox의 둥근 모서리를 덮으므로 끈다.
                      filled: false,
                      hintText: 'Search',
                      hintStyle: AppTypography.typography4.copyWith(
                        color: AppColors.grey500,
                        fontWeight: AppTypography.medium,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 50,
                        minHeight: 42,
                      ),
                      prefixIcon: const Padding(
                        padding: EdgeInsets.only(left: 14, right: 10),
                        child: Icon(
                          Icons.search_rounded,
                          color: AppColors.grey700,
                          size: 24,
                        ),
                      ),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 42,
                        minHeight: 42,
                      ),
                      suffixIcon: hasText
                          ? IconButton(
                              tooltip: 'Clear search',
                              onPressed: onClear,
                              padding: EdgeInsets.zero,
                              icon: const Icon(
                                Icons.cancel_rounded,
                                color: AppColors.grey600,
                                size: 22,
                              ),
                            )
                          : null,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: onCancel,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.grey900,
                minimumSize: const Size(64, 42),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Cancel',
                style: AppTypography.typography4.copyWith(
                  color: AppColors.grey900,
                  fontWeight: AppTypography.medium,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ChatSearchToolbar extends StatelessWidget {
  const _ChatSearchToolbar({
    required this.counterText,
    required this.showCounter,
    required this.canMovePrevious,
    required this.canMoveNext,
    required this.onDateSearchPressed,
    required this.onMovePrevious,
    required this.onMoveNext,
  });

  final String counterText;
  final bool showCounter;
  final bool canMovePrevious;
  final bool canMoveNext;
  final VoidCallback onDateSearchPressed;
  final VoidCallback onMovePrevious;
  final VoidCallback onMoveNext;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('chat-search-toolbar'),
      color: AppColors.white.withAlpha(238),
      elevation: 5,
      shadowColor: AppColors.black.withAlpha(22),
      borderRadius: AppRadius.borderRadiusFull,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 14),
            _SearchToolIconButton(
              semanticLabel: 'Search by date',
              onPressed: onDateSearchPressed,
              child: const _CalendarSearchIcon(),
            ),
            Expanded(
              child: Center(
                child: showCounter
                    ? Text(
                        counterText,
                        key: const ValueKey<String>('chat-search-counter'),
                        style: AppTypography.typography5.copyWith(
                          color: AppColors.grey900,
                          fontWeight: AppTypography.bold,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            _SearchChevronButton(
              semanticLabel: 'Previous search result',
              icon: Icons.keyboard_arrow_up_rounded,
              enabled: canMovePrevious,
              onPressed: onMovePrevious,
            ),
            const SizedBox(width: 6),
            _SearchChevronButton(
              semanticLabel: 'Next search result',
              icon: Icons.keyboard_arrow_down_rounded,
              enabled: canMoveNext,
              onPressed: onMoveNext,
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

final class _SearchToolIconButton extends StatelessWidget {
  const _SearchToolIconButton({
    required this.semanticLabel,
    required this.onPressed,
    required this.child,
  });

  final String semanticLabel;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      enabled: onPressed != null,
      child: SizedBox.square(
        dimension: 44,
        child: IconButton(
          tooltip: semanticLabel,
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          icon: child,
        ),
      ),
    );
  }
}

final class _SearchChevronButton extends StatelessWidget {
  const _SearchChevronButton({
    required this.semanticLabel,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String semanticLabel;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: SizedBox.square(
        dimension: 44,
        child: IconButton(
          tooltip: semanticLabel,
          onPressed: enabled ? onPressed : null,
          padding: EdgeInsets.zero,
          icon: Icon(
            icon,
            size: 31,
            color: enabled ? AppColors.grey900 : AppColors.grey300,
          ),
        ),
      ),
    );
  }
}

final class _CalendarSearchIcon extends StatelessWidget {
  const _CalendarSearchIcon();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: const [
        Icon(Icons.calendar_today_rounded, color: AppColors.grey900, size: 26),
        Positioned(
          right: 4,
          bottom: 4,
          child: Icon(Icons.search_rounded, color: AppColors.grey900, size: 13),
        ),
      ],
    );
  }
}

final class _SearchDateSheet extends StatefulWidget {
  const _SearchDateSheet({
    required this.initialDate,
    required this.enabledDates,
  });

  final DateTime initialDate;
  final Set<DateTime> enabledDates;

  @override
  State<_SearchDateSheet> createState() {
    return _SearchDateSheetState();
  }
}

final class _SearchDateSheetState extends State<_SearchDateSheet> {
  static const List<String> _weekdayLabels = <String>[
    'S',
    'M',
    'T',
    'W',
    'T',
    'F',
    'S',
  ];

  late final Set<DateTime> _enabledDates;
  late final List<DateTime> _enabledMonths;
  late DateTime _visibleMonth;
  late DateTime _selectedDate;

  bool _monthPickerOpen = false;
  int _temporaryYear = 0;
  int _temporaryMonth = 0;
  FixedExtentScrollController? _yearController;
  FixedExtentScrollController? _monthController;

  @override
  void initState() {
    super.initState();

    _enabledDates = widget.enabledDates.map(_dateOnly).toSet();
    _enabledMonths = _enabledDates.map(_monthOnly).toSet().toList()
      ..sort((DateTime a, DateTime b) => a.compareTo(b));
    _selectedDate = _dateOnly(widget.initialDate);
    _visibleMonth = _monthOnly(widget.initialDate);
  }

  @override
  void dispose() {
    _yearController?.dispose();
    _monthController?.dispose();
    super.dispose();
  }

  bool get _canMoveToPreviousMonth {
    return _enabledMonths.any(
      (DateTime month) => month.isBefore(_visibleMonth),
    );
  }

  bool get _canMoveToNextMonth {
    return _enabledMonths.any((DateTime month) => month.isAfter(_visibleMonth));
  }

  List<int> get _enabledYears {
    return _enabledMonths.map((DateTime month) => month.year).toSet().toList()
      ..sort();
  }

  List<int> _enabledMonthsForYear(int year) {
    return <int>[
      for (final DateTime month in _enabledMonths)
        if (month.year == year) month.month,
    ];
  }

  void _moveMonth(int delta) {
    final DateTime nextMonth = _addMonths(_visibleMonth, delta);

    if (!_enabledMonths.contains(nextMonth)) {
      return;
    }

    setState(() {
      _visibleMonth = nextMonth;
    });
  }

  void _openMonthPicker() {
    final List<int> years = _enabledYears;
    _temporaryYear = _visibleMonth.year;
    _temporaryMonth = _visibleMonth.month;
    _yearController?.dispose();
    _monthController?.dispose();
    _yearController = FixedExtentScrollController(
      initialItem: math.max(0, years.indexOf(_temporaryYear)),
    );
    _monthController = FixedExtentScrollController(
      initialItem: math.max(
        0,
        _enabledMonthsForYear(_temporaryYear).indexOf(_temporaryMonth),
      ),
    );

    setState(() {
      _monthPickerOpen = true;
    });
  }

  void _cancelMonthPicker() {
    setState(() {
      _monthPickerOpen = false;
    });
  }

  void _applyMonthPicker() {
    final DateTime selectedMonth = DateTime(_temporaryYear, _temporaryMonth);

    if (!_enabledMonths.contains(selectedMonth)) {
      return;
    }

    setState(() {
      _visibleMonth = selectedMonth;
      _monthPickerOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      bottom: false,
      child: Material(
        color: AppColors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, 22, 24, bottomPadding + 22),
          child: _monthPickerOpen
              ? _buildMonthPicker(context)
              : _buildCalendar(context),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final bool showUpCaret = _monthPickerOpen;

    return SizedBox(
      height: 48,
      child: Row(
        children: [
          _MonthChevronButton(
            semanticLabel: 'Previous month',
            icon: Icons.chevron_left_rounded,
            enabled: !_monthPickerOpen && _canMoveToPreviousMonth,
            onPressed: () {
              _moveMonth(-1);
            },
          ),
          Expanded(
            child: Center(
              child: TextButton(
                onPressed: _monthPickerOpen ? null : _openMonthPicker,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.grey900,
                  disabledForegroundColor: AppColors.grey900,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatSearchMonth(_visibleMonth),
                      style: AppTypography.typography4.copyWith(
                        color: AppColors.grey900,
                        fontWeight: AppTypography.bold,
                      ),
                    ),
                    Icon(
                      showUpCaret
                          ? Icons.arrow_drop_up_rounded
                          : Icons.arrow_drop_down_rounded,
                      color: AppColors.grey900,
                    ),
                  ],
                ),
              ),
            ),
          ),
          _MonthChevronButton(
            semanticLabel: 'Next month',
            icon: Icons.chevron_right_rounded,
            enabled: !_monthPickerOpen && _canMoveToNextMonth,
            onPressed: () {
              _moveMonth(1);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCalendar(BuildContext context) {
    final int leadingBlankCount =
        DateTime(_visibleMonth.year, _visibleMonth.month).weekday % 7;
    final int dayCount = _daysInMonth(_visibleMonth.year, _visibleMonth.month);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(),
        const SizedBox(height: 18),
        Row(
          children: [
            for (final String label in _weekdayLabels)
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: AppTypography.typography7.copyWith(
                      color: AppColors.grey600,
                      fontWeight: AppTypography.medium,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 4,
          children: [
            for (int index = 0; index < leadingBlankCount; index++)
              const SizedBox.shrink(),
            for (int day = 1; day <= dayCount; day++)
              _SearchDateCell(
                date: DateTime(_visibleMonth.year, _visibleMonth.month, day),
                selected:
                    _selectedDate ==
                    DateTime(_visibleMonth.year, _visibleMonth.month, day),
                enabled: _enabledDates.contains(
                  DateTime(_visibleMonth.year, _visibleMonth.month, day),
                ),
                onSelected: (DateTime date) {
                  setState(() {
                    _selectedDate = _dateOnly(date);
                  });

                  Navigator.of(context).pop(_dateOnly(date));
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMonthPicker(BuildContext context) {
    final List<int> years = _enabledYears;
    final List<int> months = _enabledMonthsForYear(_temporaryYear);
    final bool canApply = months.contains(_temporaryMonth);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildHeader(),
        const SizedBox(height: 36),
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 45,
              decoration: const BoxDecoration(
                color: AppColors.grey100,
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
            SizedBox(
              height: 156,
              child: Row(
                children: [
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: _yearController,
                      itemExtent: 45,
                      selectionOverlay: const SizedBox.shrink(),
                      onSelectedItemChanged: (int index) {
                        final int year = years[index];
                        final List<int> yearMonths = _enabledMonthsForYear(
                          year,
                        );

                        setState(() {
                          _temporaryYear = year;
                          if (!yearMonths.contains(_temporaryMonth)) {
                            _temporaryMonth = yearMonths.first;
                          }
                        });
                      },
                      children: [
                        for (final int year in years)
                          Center(
                            child: Text(
                              '$year',
                              style: AppTypography.typography3.copyWith(
                                color: year == _temporaryYear
                                    ? AppColors.grey900
                                    : AppColors.grey400,
                                fontWeight: AppTypography.medium,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: _monthController,
                      itemExtent: 45,
                      selectionOverlay: const SizedBox.shrink(),
                      onSelectedItemChanged: (int index) {
                        setState(() {
                          _temporaryMonth = months[index];
                        });
                      },
                      children: [
                        for (final int month in months)
                          Center(
                            child: Text(
                              _monthName(month),
                              style: AppTypography.typography3.copyWith(
                                color: month == _temporaryMonth
                                    ? AppColors.grey900
                                    : AppColors.grey400,
                                fontWeight: AppTypography.medium,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 42),
        Row(
          children: [
            Expanded(
              child: _SearchDateSheetButton(
                label: 'Cancel',
                onPressed: _cancelMonthPicker,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SearchDateSheetButton(
                label: 'OK',
                onPressed: canApply ? _applyMonthPicker : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _monthName(int month) {
    return switch (month) {
      1 => 'January',
      2 => 'February',
      3 => 'March',
      4 => 'April',
      5 => 'May',
      6 => 'June',
      7 => 'July',
      8 => 'August',
      9 => 'September',
      10 => 'October',
      11 => 'November',
      12 => 'December',
      _ => '$month',
    };
  }
}

final class _MonthChevronButton extends StatelessWidget {
  const _MonthChevronButton({
    required this.semanticLabel,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String semanticLabel;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: semanticLabel,
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        size: 32,
        color: enabled ? AppColors.grey900 : AppColors.grey300,
      ),
    );
  }
}

final class _SearchDateCell extends StatelessWidget {
  const _SearchDateCell({
    required this.date,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final DateTime date;
  final bool selected;
  final bool enabled;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final Color textColor = selected
        ? AppColors.white
        : enabled
        ? AppColors.grey900
        : AppColors.grey300;

    return Center(
      child: SizedBox.square(
        dimension: 42,
        child: Material(
          color: selected ? AppColors.blue500 : Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? () => onSelected(date) : null,
            child: Center(
              child: Text(
                '${date.day}',
                style: AppTypography.typography5.copyWith(
                  color: textColor,
                  fontWeight: selected
                      ? AppTypography.bold
                      : AppTypography.medium,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _SearchDateSheetButton extends StatelessWidget {
  const _SearchDateSheetButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          backgroundColor: AppColors.grey100,
          foregroundColor: AppColors.grey900,
          disabledForegroundColor: AppColors.grey400,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
        ),
        child: Text(
          label,
          style: AppTypography.typography5.copyWith(
            fontWeight: AppTypography.medium,
          ),
        ),
      ),
    );
  }
}

String _formatCallDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds.clamp(0, 359999).toInt();
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;

  String twoDigits(int value) {
    return value.toString().padLeft(2, '0');
  }

  if (hours > 0) {
    return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  return '${twoDigits(minutes)}:${twoDigits(seconds)}';
}

String _formatVoiceMemoSheetDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds.clamp(0, 5999).toInt();
  final int minutes = totalSeconds ~/ 60;
  final int seconds = totalSeconds % 60;

  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String _formatVoiceMemoBubbleDuration(Duration duration) {
  final int totalSeconds = duration.inSeconds.clamp(0, 5999).toInt();
  final int minutes = totalSeconds ~/ 60;
  final int seconds = totalSeconds % 60;

  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

double _voiceMemoMessageBubbleWidth(BuildContext context) {
  return math.min(304, math.max(196, MediaQuery.sizeOf(context).width - 128));
}

const int _voiceMemoWaveformSampleCount = 42;
const int _voiceMemoWaveformRawSampleLimit = 1800;
final ValueNotifier<String?> _activeVoiceMemoPlaybackMessageId =
    ValueNotifier<String?>(null);
final Map<String, List<double>> _voiceMemoWaveformSamplesByCacheKey =
    <String, List<double>>{};
final Map<String, Duration> _voiceMemoPlaybackPositionsByCacheKey =
    <String, Duration>{};

double _voiceMemoSampleFromAmplitude(double dbfs) {
  if (!dbfs.isFinite) {
    return 0.03;
  }

  if (dbfs <= -58) {
    return 0.03;
  }

  final double normalized = ((dbfs.clamp(-55.0, -8.0) + 55) / 47)
      .clamp(0.0, 1.0)
      .toDouble();

  return math.pow(normalized, 1.08).toDouble().clamp(0.03, 1).toDouble();
}

double _clampVoiceMemoWaveformSample(num sample) {
  return sample.toDouble().clamp(0, 1).toDouble();
}

List<double> _resampleVoiceMemoWaveformSamples(List<double> samples) {
  if (samples.isEmpty) {
    return const <double>[];
  }

  if (samples.length == _voiceMemoWaveformSampleCount) {
    return List<double>.unmodifiable(
      samples.map(_clampVoiceMemoWaveformSample),
    );
  }

  final List<double> resampled = <double>[];

  for (int index = 0; index < _voiceMemoWaveformSampleCount; index++) {
    final double bucketStart =
        samples.length * index / _voiceMemoWaveformSampleCount;
    final double bucketEnd =
        samples.length * (index + 1) / _voiceMemoWaveformSampleCount;
    final int start = bucketStart.floor().clamp(0, samples.length - 1).toInt();
    final int end = bucketEnd.ceil().clamp(start + 1, samples.length).toInt();

    double peak = 0;
    double total = 0;

    for (int sampleIndex = start; sampleIndex < end; sampleIndex++) {
      final double sample = _clampVoiceMemoWaveformSample(samples[sampleIndex]);
      peak = math.max(peak, sample);
      total += sample;
    }

    final double average = total / (end - start);
    resampled.add((peak * 0.7) + (average * 0.3));
  }

  return List<double>.unmodifiable(resampled);
}

List<double> _normalizeVoiceMemoWaveformSamples(List<double> samples) {
  if (samples.isEmpty) {
    return const <double>[];
  }

  final List<double> normalizedInput = samples
      .map(_clampVoiceMemoWaveformSample)
      .toList(growable: false);
  final List<double> sortedSamples = List<double>.of(normalizedInput)..sort();
  final double low =
      sortedSamples[(sortedSamples.length * 0.12).floor().clamp(
        0,
        sortedSamples.length - 1,
      )];
  final double high =
      sortedSamples[(sortedSamples.length * 0.92).floor().clamp(
        0,
        sortedSamples.length - 1,
      )];
  final double range = high - low;
  final double peak = sortedSamples.last;

  if (peak <= 0.08) {
    return List<double>.unmodifiable(List<double>.filled(samples.length, 0.04));
  }

  final List<double> shapedSamples = <double>[];

  for (final double sample in normalizedInput) {
    final double relative = range > 0.025
        ? ((sample - low) / range).clamp(0.0, 1.0).toDouble()
        : sample.clamp(0.0, 1.0).toDouble();
    final double shaped = math.pow(relative, 0.76).toDouble();
    final double displayed = shaped < 0.1
        ? 0.04 + (shaped * 0.45)
        : 0.12 + (shaped * 0.84);

    shapedSamples.add(displayed.clamp(0.04, 1).toDouble());
  }

  return List<double>.unmodifiable(
    List<double>.generate(shapedSamples.length, (int index) {
      final double previous = shapedSamples[math.max(0, index - 1)];
      final double current = shapedSamples[index];
      final double next =
          shapedSamples[math.min(shapedSamples.length - 1, index + 1)];

      return ((current * 0.72) + (previous * 0.14) + (next * 0.14))
          .clamp(0.04, 1)
          .toDouble();
    }, growable: false),
  );
}

List<double> _finalizeVoiceMemoWaveformSamples(List<double> samples) {
  return _normalizeVoiceMemoWaveformSamples(
    _resampleVoiceMemoWaveformSamples(samples),
  );
}

List<double> _voiceMemoWaveformSamplesForStorage(
  List<double> samples, {
  Uint8List? fallbackAudioBytes,
}) {
  if (samples.length == _voiceMemoWaveformSampleCount) {
    return List<double>.unmodifiable(
      samples.map(_clampVoiceMemoWaveformSample),
    );
  }

  if (samples.isNotEmpty) {
    return _finalizeVoiceMemoWaveformSamples(samples);
  }

  if (fallbackAudioBytes == null || fallbackAudioBytes.isEmpty) {
    return const <double>[];
  }

  return _voiceMemoWaveformSamplesFromBytes(fallbackAudioBytes);
}

List<double> _appendVoiceMemoWaveformSample(
  List<double> samples,
  double sample,
) {
  final List<double> nextSamples = List<double>.of(samples)
    ..add(_clampVoiceMemoWaveformSample(sample));

  if (nextSamples.length <= _voiceMemoWaveformRawSampleLimit) {
    return List<double>.unmodifiable(nextSamples);
  }

  return List<double>.unmodifiable(
    nextSamples.sublist(nextSamples.length - _voiceMemoWaveformRawSampleLimit),
  );
}

List<double> _voiceMemoWaveformSamplesFromBytes(Uint8List bytes) {
  if (bytes.isEmpty) {
    return const <double>[];
  }

  final int offset = bytes.length > 1400 ? 1024 : 0;
  final int usableLength = bytes.length - offset;

  if (usableLength <= 0) {
    return const <double>[];
  }

  final List<double> samples = <double>[];

  for (int index = 0; index < _voiceMemoWaveformSampleCount; index++) {
    final int start =
        offset +
        ((usableLength * index) / _voiceMemoWaveformSampleCount).floor();
    final int end =
        offset +
        ((usableLength * (index + 1)) / _voiceMemoWaveformSampleCount).floor();

    if (end <= start) {
      samples.add(0.04);
      continue;
    }

    double totalDeviation = 0;
    double totalDelta = 0;
    int minByte = 255;
    int maxByte = 0;
    int previousByte = bytes[math.max(0, start - 1)];

    for (int byteIndex = start; byteIndex < end; byteIndex++) {
      final int byte = bytes[byteIndex];
      totalDeviation += (byte - 128).abs();
      totalDelta += (byte - previousByte).abs();
      minByte = math.min(minByte, byte);
      maxByte = math.max(maxByte, byte);
      previousByte = byte;
    }

    final double averageDeviation = totalDeviation / ((end - start) * 128);
    final double averageDelta = totalDelta / ((end - start) * 255);
    final double byteRange = (maxByte - minByte) / 255;
    final double normalized =
        (averageDeviation * 0.2) + (averageDelta * 0.48) + (byteRange * 0.32);

    samples.add(normalized);
  }

  return _finalizeVoiceMemoWaveformSamples(samples);
}

String _safeVoiceMemoCacheKey(String value) {
  return value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
}

final class _CallNowSheet extends StatelessWidget {
  const _CallNowSheet();

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      bottom: false,
      child: Material(
        color: AppColors.grey50,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 26, 18, bottomPadding + 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Call Now',
                  style: AppTypography.typography5.copyWith(
                    color: AppColors.grey900,
                    fontWeight: AppTypography.semibold,
                  ),
                ),
                const SizedBox(height: 18),
                _CallNowOption(
                  label: 'Voice Call',
                  icon: Icons.call_rounded,
                  onTap: () {
                    Navigator.of(context).pop(_CallNowAction.voice);
                  },
                ),
                const SizedBox(height: 12),
                _CallNowOption(
                  label: 'Video Call',
                  icon: Icons.videocam_rounded,
                  onTap: () {
                    Navigator.of(context).pop(_CallNowAction.video);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _CallNowOption extends StatelessWidget {
  const _CallNowOption({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.white,
      borderRadius: AppRadius.borderRadius16,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: AppColors.green50,
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                  ),
                  child: Icon(icon, size: 21, color: AppColors.green500),
                ),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: AppTypography.subTypography10.copyWith(
                    color: AppColors.grey900,
                    fontWeight: AppTypography.semibold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _VoiceMemoSheet extends StatefulWidget {
  const _VoiceMemoSheet();

  @override
  State<_VoiceMemoSheet> createState() {
    return _VoiceMemoSheetState();
  }
}

final class _VoiceMemoSheetState extends State<_VoiceMemoSheet> {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _previewPlayer = AudioPlayer();

  Timer? _timer;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<Duration>? _previewPositionSubscription;
  StreamSubscription<PlayerState>? _previewStateSubscription;

  _VoiceMemoSheetMode _mode = _VoiceMemoSheetMode.idle;
  Duration _elapsed = Duration.zero;
  Duration _playbackPosition = Duration.zero;
  String? _recordingPath;
  List<double> _waveformSamples = const <double>[];

  @override
  void initState() {
    super.initState();

    unawaited(_previewPlayer.setLoopMode(LoopMode.off));

    _previewPositionSubscription = _previewPlayer.positionStream.listen((
      Duration position,
    ) {
      if (!mounted || _mode != _VoiceMemoSheetMode.playing) {
        return;
      }

      setState(() {
        _playbackPosition = position > _elapsed ? _elapsed : position;
      });
    });

    _previewStateSubscription = _previewPlayer.playerStateStream.listen((
      PlayerState state,
    ) {
      if (!mounted || state.processingState != ProcessingState.completed) {
        return;
      }

      setState(() {
        _mode = _VoiceMemoSheetMode.recorded;
        _playbackPosition = _elapsed;
      });
      unawaited(_finishPreviewPlayback());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _amplitudeSubscription?.cancel();
    _previewPositionSubscription?.cancel();
    _previewStateSubscription?.cancel();
    unawaited(_previewPlayer.dispose());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<String> _createRecordingPath() async {
    final Directory temporaryDirectory = await getTemporaryDirectory();
    final int timestamp = DateTime.now().microsecondsSinceEpoch;

    return '${temporaryDirectory.path}/juliatalk_voice_$timestamp.m4a';
  }

  void _showVoiceMemoFailure(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _finishPreviewPlayback() async {
    try {
      await _previewPlayer.pause();
      await _previewPlayer.seek(Duration.zero);
    } catch (_) {
      return;
    }
  }

  Future<void> _deleteRecordingFile(String? path) async {
    if (path == null) {
      return;
    }

    final File file = File(path);

    if (await file.exists()) {
      await file.delete();
    }
  }

  void _handleRecordingAmplitude(Amplitude amplitude) {
    if (!mounted || _mode != _VoiceMemoSheetMode.recording) {
      return;
    }

    final double sample = _voiceMemoSampleFromAmplitude(amplitude.current);

    setState(() {
      _waveformSamples = _appendVoiceMemoWaveformSample(
        _waveformSamples,
        sample,
      );
    });
  }

  Future<void> _startRecording() async {
    _timer?.cancel();
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    try {
      _activeVoiceMemoPlaybackMessageId.value = null;
      await _previewPlayer.stop();

      if (!await _recorder.hasPermission()) {
        _showVoiceMemoFailure('Microphone permission is required.');
        return;
      }

      await _deleteRecordingFile(_recordingPath);

      final String recordingPath = await _createRecordingPath();

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: recordingPath,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _mode = _VoiceMemoSheetMode.recording;
        _elapsed = Duration.zero;
        _playbackPosition = Duration.zero;
        _recordingPath = recordingPath;
        _waveformSamples = const <double>[];
      });

      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen(_handleRecordingAmplitude);

      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          return;
        }

        setState(() {
          _elapsed += const Duration(seconds: 1);
        });
      });
    } catch (_) {
      _timer?.cancel();
      _timer = null;
      await _amplitudeSubscription?.cancel();
      _amplitudeSubscription = null;
      _showVoiceMemoFailure('Voice memo recording failed.');
    }
  }

  Future<void> _stopRecording() async {
    if (_mode != _VoiceMemoSheetMode.recording) {
      return;
    }

    _timer?.cancel();
    _timer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    try {
      final String? stoppedPath = await _recorder.stop();
      final String? waveformPath = stoppedPath ?? _recordingPath;
      Uint8List? fallbackAudioBytes;

      if (_waveformSamples.isEmpty && waveformPath != null) {
        fallbackAudioBytes = await File(waveformPath).readAsBytes();
      }

      final List<double> waveformSamples = _voiceMemoWaveformSamplesForStorage(
        _waveformSamples,
        fallbackAudioBytes: fallbackAudioBytes,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _mode = _VoiceMemoSheetMode.recorded;
        if (_elapsed.inSeconds == 0) {
          _elapsed = const Duration(seconds: 1);
        }
        _playbackPosition = Duration.zero;
        _recordingPath = stoppedPath ?? _recordingPath;
        _waveformSamples = waveformSamples;
      });
    } catch (_) {
      _showVoiceMemoFailure('Voice memo recording failed.');
    }
  }

  Future<void> _resetRecording() async {
    _timer?.cancel();
    _timer = null;
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;

    try {
      await _previewPlayer.stop();
      await _recorder.cancel();
      await _deleteRecordingFile(_recordingPath);
    } catch (_) {
      // Reset should still clear local UI state even if cleanup fails.
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _mode = _VoiceMemoSheetMode.idle;
      _elapsed = Duration.zero;
      _playbackPosition = Duration.zero;
      _recordingPath = null;
      _waveformSamples = const <double>[];
    });
  }

  Future<void> _togglePlayback() async {
    if (_mode == _VoiceMemoSheetMode.playing) {
      await _previewPlayer.pause();

      setState(() {
        _mode = _VoiceMemoSheetMode.recorded;
      });
      return;
    }

    if (_elapsed == Duration.zero) {
      return;
    }

    final String? recordingPath = _recordingPath;

    if (recordingPath == null) {
      _showVoiceMemoFailure('Voice memo audio is not available.');
      return;
    }

    try {
      _activeVoiceMemoPlaybackMessageId.value = null;
      await _previewPlayer.stop();
      await _previewPlayer.setLoopMode(LoopMode.off);
      await _previewPlayer.setUrl(Uri.file(recordingPath).toString());
      await _previewPlayer.seek(Duration.zero);

      setState(() {
        _mode = _VoiceMemoSheetMode.playing;
        _playbackPosition = Duration.zero;
      });

      unawaited(_previewPlayer.play());
    } catch (_) {
      _showVoiceMemoFailure('Voice memo playback failed.');
    }
  }

  Future<void> _sendVoiceMemo() async {
    if (_mode == _VoiceMemoSheetMode.recording) {
      await _stopRecording();
    }

    final Duration duration = _elapsed.inSeconds == 0
        ? const Duration(seconds: 1)
        : _elapsed;

    final String? recordingPath = _recordingPath;

    if (recordingPath == null) {
      _showVoiceMemoFailure('Voice memo audio is not available.');
      return;
    }

    try {
      final Uint8List audioBytes = await File(recordingPath).readAsBytes();

      if (audioBytes.isEmpty) {
        _showVoiceMemoFailure('Voice memo audio is empty.');
        return;
      }

      final List<double> waveformSamples = _voiceMemoWaveformSamplesForStorage(
        _waveformSamples,
        fallbackAudioBytes: audioBytes,
      );

      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(
        ChatVoiceMemoAttachment(
          duration: duration,
          audioBytes: audioBytes,
          mimeType: 'audio/mp4',
          fileName: 'voice-memo.m4a',
          sizeBytes: audioBytes.length,
          localPath: recordingPath,
          waveformSamples: waveformSamples,
        ),
      );
    } catch (_) {
      _showVoiceMemoFailure('Voice memo sending failed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      bottom: false,
      child: Material(
        key: const ValueKey<String>('voice-memo-sheet'),
        color: AppColors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 26, 18, bottomPadding + 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Voice Memo',
                style: AppTypography.typography5.copyWith(
                  color: AppColors.grey900,
                  fontWeight: AppTypography.semibold,
                ),
              ),
              const SizedBox(height: 22),
              Transform.translate(
                offset: const Offset(0, 4),
                child: _VoiceMemoRecorderBar(
                  mode: _mode,
                  elapsed: _elapsed,
                  playbackPosition: _playbackPosition,
                  waveformSamples: _waveformSamples,
                  onPlayPressed: _togglePlayback,
                ),
              ),
              const SizedBox(height: 44),
              SizedBox(
                height: 54,
                child: _VoiceMemoRecorderControls(
                  mode: _mode,
                  onRecordPressed: _startRecording,
                  onStopPressed: _stopRecording,
                  onResetPressed: _resetRecording,
                  onSendPressed: _sendVoiceMemo,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _VoiceMemoRecorderBar extends StatelessWidget {
  const _VoiceMemoRecorderBar({
    required this.mode,
    required this.elapsed,
    required this.playbackPosition,
    required this.waveformSamples,
    required this.onPlayPressed,
  });

  final _VoiceMemoSheetMode mode;
  final Duration elapsed;
  final Duration playbackPosition;
  final List<double> waveformSamples;
  final VoidCallback onPlayPressed;

  bool get _hasRecording {
    return mode != _VoiceMemoSheetMode.idle;
  }

  bool get _canPlay {
    return mode == _VoiceMemoSheetMode.recorded ||
        mode == _VoiceMemoSheetMode.playing;
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = _hasRecording;
    final Color backgroundColor = isActive
        ? AppColors.primary
        : AppColors.grey100;
    final Color foregroundColor = isActive
        ? AppColors.white
        : AppColors.grey500;
    final Duration displayDuration = elapsed;
    final double progress = elapsed.inMilliseconds == 0
        ? 0
        : playbackPosition.inMilliseconds / elapsed.inMilliseconds;
    final double waveformProgress = mode == _VoiceMemoSheetMode.recording
        ? 1
        : progress.clamp(0, 1).toDouble();

    return SizedBox(
      height: 64,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: const BorderRadius.all(Radius.circular(14)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              if (_canPlay) ...[
                _VoiceMemoInlinePlayButton(
                  playing: mode == _VoiceMemoSheetMode.playing,
                  color: foregroundColor,
                  onPressed: onPlayPressed,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: _hasRecording
                    ? _VoiceMemoWaveform(
                        color: foregroundColor.withAlpha(126),
                        playedColor: foregroundColor,
                        samples: waveformSamples,
                        progress: waveformProgress,
                        showProgress:
                            mode == _VoiceMemoSheetMode.recording ||
                            mode == _VoiceMemoSheetMode.playing ||
                            playbackPosition > Duration.zero,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 14),
              Text(
                _formatVoiceMemoSheetDuration(displayDuration),
                style: AppTypography.typography5.copyWith(
                  color: foregroundColor,
                  fontWeight: AppTypography.semibold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _VoiceMemoInlinePlayButton extends StatelessWidget {
  const _VoiceMemoInlinePlayButton({
    required this.playing,
    required this.color,
    required this.onPressed,
  });

  final bool playing;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey<String>('voice-memo-preview-play'),
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      icon: Icon(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        size: 30,
        color: color,
      ),
    );
  }
}

final class _VoiceMemoRecorderControls extends StatelessWidget {
  const _VoiceMemoRecorderControls({
    required this.mode,
    required this.onRecordPressed,
    required this.onStopPressed,
    required this.onResetPressed,
    required this.onSendPressed,
  });

  final _VoiceMemoSheetMode mode;
  final VoidCallback onRecordPressed;
  final VoidCallback onStopPressed;
  final VoidCallback onResetPressed;
  final VoidCallback onSendPressed;

  @override
  Widget build(BuildContext context) {
    if (mode == _VoiceMemoSheetMode.idle) {
      return Center(
        child: _VoiceMemoRoundButton(
          key: const ValueKey<String>('voice-memo-record'),
          size: 44,
          backgroundColor: AppColors.error,
          foregroundColor: AppColors.white,
          onPressed: onRecordPressed,
          child: const SizedBox.shrink(),
        ),
      );
    }

    final Widget centerButton = mode == _VoiceMemoSheetMode.recording
        ? _VoiceMemoRoundButton(
            key: const ValueKey<String>('voice-memo-stop'),
            size: 44,
            backgroundColor: AppColors.grey50,
            foregroundColor: AppColors.grey900,
            onPressed: onStopPressed,
            child: const Icon(Icons.stop_rounded, size: 28),
          )
        : _VoiceMemoRoundButton(
            key: const ValueKey<String>('voice-memo-reset'),
            size: 44,
            backgroundColor: AppColors.white,
            foregroundColor: AppColors.grey900,
            onPressed: onResetPressed,
            child: const Icon(Icons.replay_rounded, size: 31),
          );

    return Stack(
      alignment: Alignment.center,
      children: [
        centerButton,
        Align(
          alignment: Alignment.centerRight,
          child: _VoiceMemoRoundButton(
            key: const ValueKey<String>('voice-memo-send'),
            size: 44,
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.white,
            onPressed: onSendPressed,
            child: const Icon(Icons.arrow_upward_rounded, size: 31),
          ),
        ),
      ],
    );
  }
}

final class _VoiceMemoRoundButton extends StatelessWidget {
  const _VoiceMemoRoundButton({
    required this.size,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
    required this.child,
    super.key,
  });

  final double size;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor.withAlpha(24),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Material(
          color: backgroundColor,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: IconTheme(
                data: IconThemeData(color: foregroundColor),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _VoiceMemoWaveform extends StatelessWidget {
  const _VoiceMemoWaveform({
    required this.color,
    this.playedColor,
    this.samples = const <double>[],
    this.progress = 0,
    this.showProgress = false,
  });

  final Color color;
  final Color? playedColor;
  final List<double> samples;
  final double progress;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _VoiceMemoWaveformPainter(
        color: color,
        playedColor: playedColor ?? color,
        samples: samples,
        progress: progress,
        showProgress: showProgress,
      ),
      child: const SizedBox.expand(),
    );
  }
}

final class _VoiceMemoWaveformPainter extends CustomPainter {
  const _VoiceMemoWaveformPainter({
    required this.color,
    required this.playedColor,
    required this.samples,
    required this.progress,
    required this.showProgress,
  });

  final Color color;
  final Color playedColor;
  final List<double> samples;
  final double progress;
  final bool showProgress;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    final Paint paint = Paint()
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;

    if (samples.isEmpty) {
      return;
    }

    final List<double> displaySamples;

    if (samples.length >= _voiceMemoWaveformSampleCount) {
      displaySamples = samples.sublist(
        samples.length - _voiceMemoWaveformSampleCount,
      );
    } else {
      displaySamples = <double>[
        ...samples,
        ...List<double>.filled(
          _voiceMemoWaveformSampleCount - samples.length,
          0.04,
        ),
      ];
    }

    final int count = displaySamples.length;

    if (count == 0) {
      return;
    }

    final double step = count == 1 ? 0 : size.width / (count - 1);
    final double centerY = size.height / 2;
    final double clampedProgress = progress.clamp(0, 1).toDouble();
    final double playedIndex = clampedProgress * (count - 1);
    final bool progressVisible = showProgress && clampedProgress > 0;

    for (int index = 0; index < count; index++) {
      final double x = count == 1 ? size.width / 2 : index * step;
      final double sample = displaySamples[index].clamp(0, 1).toDouble();
      final bool isPlayed = progressVisible && index <= playedIndex;

      paint.color = isPlayed ? playedColor : color;

      if (sample <= 0.12) {
        final double dotRadius = math.min(
          1.7,
          math.max(1.1, size.height * 0.07),
        );
        canvas.drawCircle(Offset(x, centerY), dotRadius, paint);
        continue;
      }

      final double minBarHeight = math.min(6, size.height * 0.2);
      final double maxBarHeight = math.min(28, size.height * 0.94);
      final double barHeight =
          minBarHeight + sample * (maxBarHeight - minBarHeight);
      final RRect bar = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, centerY),
          width: math.min(2.8, math.max(1.8, size.height * 0.09)),
          height: barHeight,
        ),
        const Radius.circular(2),
      );

      canvas.drawRRect(bar, paint);
    }
  }

  @override
  bool shouldRepaint(_VoiceMemoWaveformPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.samples != samples ||
        oldDelegate.progress != progress ||
        oldDelegate.showProgress != showProgress;
  }
}

final class _ActiveVoiceCallBanner extends StatelessWidget {
  const _ActiveVoiceCallBanner({
    required this.connected,
    required this.elapsed,
    required this.onPressed,
  });

  static const double _verticalPadding = 8;
  static const double _buttonHeight = 52;
  static const double occupiedHeight = _buttonHeight + (_verticalPadding * 2);

  final bool connected;
  final Duration elapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String semanticLabel = connected
        ? 'Voice call ${_formatCallDuration(elapsed)}'
        : 'Voice call connecting';

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          10,
          _verticalPadding,
          0,
          _verticalPadding,
        ),
        child: Semantics(
          button: true,
          label: semanticLabel,
          child: Material(
            key: const ValueKey<String>('active-voice-call-banner'),
            color: AppColors.green500,
            borderRadius: AppRadius.borderRadius16,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox(
                width: connected ? 126 : 122,
                height: _buttonHeight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.call_rounded,
                      size: 28,
                      color: AppColors.white,
                    ),
                    SizedBox(width: connected ? 14 : 18),
                    if (connected)
                      Text(
                        _formatCallDuration(elapsed),
                        style: AppTypography.typography5.copyWith(
                          color: AppColors.white,
                          fontWeight: AppTypography.bold,
                        ),
                      )
                    else
                      const _ActiveCallDots(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ActiveCallDots extends StatelessWidget {
  const _ActiveCallDots();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActiveCallDot(color: AppColors.white.withAlpha(122)),
        const SizedBox(width: 5),
        _ActiveCallDot(color: AppColors.white.withAlpha(122)),
        const SizedBox(width: 5),
        _ActiveCallDot(color: AppColors.white.withAlpha(122)),
      ],
    );
  }
}

final class _ActiveCallDot extends StatelessWidget {
  const _ActiveCallDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

final class _VoiceCallScreen extends StatelessWidget {
  const _VoiceCallScreen({
    required this.participantName,
    required this.connected,
    required this.elapsed,
    required this.muted,
    required this.audioOutputRoute,
    required this.onReturnToChat,
    required this.onToggleMute,
    required this.onEndCall,
    required this.onChooseAudioOutput,
  });

  final String participantName;
  final bool connected;
  final Duration elapsed;
  final bool muted;
  final _AudioOutputRoute audioOutputRoute;
  final VoidCallback onReturnToChat;
  final VoidCallback onToggleMute;
  final VoidCallback onEndCall;
  final VoidCallback onChooseAudioOutput;

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return Material(
      key: const ValueKey<String>('voice-call-screen'),
      color: AppColors.black,
      child: Column(
        children: [
          SizedBox(
            height: 106,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 22),
                child: _CallTopButton(
                  icon: Icons.picture_in_picture_alt_rounded,
                  tooltip: 'Back to chat',
                  onPressed: onReturnToChat,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.grey900,
                  borderRadius: AppRadius.borderRadius24,
                ),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final double topSpacing = (constraints.maxHeight * 0.12)
                        .clamp(72.0, 116.0)
                        .toDouble();

                    return Column(
                      children: [
                        SizedBox(height: topSpacing),
                        Text(
                          participantName,
                          style: AppTypography.typography2.copyWith(
                            color: AppColors.white,
                            fontWeight: AppTypography.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          connected
                              ? _formatCallDuration(elapsed)
                              : 'Connecting...',
                          style: AppTypography.typography5.copyWith(
                            color: AppColors.white,
                            fontWeight: AppTypography.medium,
                          ),
                        ),
                        const SizedBox(height: 14),
                        connected
                            ? Text(
                                'Voice Call',
                                style: AppTypography.subTypography11.copyWith(
                                  color: AppColors.grey400,
                                  fontWeight: AppTypography.medium,
                                ),
                              )
                            : const _ConnectingDots(),
                        SizedBox(height: constraints.maxHeight * 0.08),
                        Container(
                          width: 112,
                          height: 112,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: AppColors.blue100,
                            borderRadius: BorderRadius.all(Radius.circular(32)),
                          ),
                          child: const Icon(
                            Icons.person_rounded,
                            size: 64,
                            color: AppColors.blue50,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(28, 0, 28, bottomPadding + 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _CallControlButton(
                  tooltip: muted ? 'Unmute' : 'Mute',
                  icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  active: muted,
                  onPressed: onToggleMute,
                ),
                const SizedBox(width: 34),
                _EndCallButton(onPressed: onEndCall),
                const SizedBox(width: 34),
                _CallControlButton(
                  tooltip: audioOutputRoute.label,
                  icon: audioOutputRoute.icon,
                  active: audioOutputRoute != _AudioOutputRoute.phone,
                  onPressed: onChooseAudioOutput,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ConnectingDots extends StatelessWidget {
  const _ConnectingDots();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        _ConnectingDot(),
        SizedBox(width: 9),
        _ConnectingDot(),
        SizedBox(width: 9),
        _ConnectingDot(),
      ],
    );
  }
}

final class _ConnectingDot extends StatelessWidget {
  const _ConnectingDot();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.blue500,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

final class _CallTopButton extends StatelessWidget {
  const _CallTopButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 32, color: AppColors.white),
    );
  }
}

final class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox.square(
        dimension: 66,
        child: Material(
          color: active ? AppColors.grey700 : AppColors.grey800,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(icon, size: 31, color: AppColors.white),
          ),
        ),
      ),
    );
  }
}

final class _EndCallButton extends StatelessWidget {
  const _EndCallButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'End call',
      child: SizedBox.square(
        dimension: 72,
        child: Material(
          color: AppColors.red500,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: const Icon(
              Icons.call_end_rounded,
              size: 34,
              color: AppColors.white,
            ),
          ),
        ),
      ),
    );
  }
}

final class _AudioOutputSheet extends StatelessWidget {
  const _AudioOutputSheet({required this.selectedRoute});

  final _AudioOutputRoute selectedRoute;

  @override
  Widget build(BuildContext context) {
    final double bottomPadding = MediaQuery.viewPaddingOf(context).bottom;

    return SafeArea(
      top: false,
      child: Material(
        color: AppColors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 12, 18, bottomPadding + 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.grey300,
                  borderRadius: BorderRadius.all(Radius.circular(3)),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Audio Output',
                style: AppTypography.typography4.copyWith(
                  color: AppColors.grey900,
                  fontWeight: AppTypography.bold,
                ),
              ),
              const SizedBox(height: 16),
              for (final _AudioOutputRoute route in _AudioOutputRoute.values)
                _AudioOutputOption(
                  route: route,
                  selected: route == selectedRoute,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _AudioOutputOption extends StatelessWidget {
  const _AudioOutputOption({required this.route, required this.selected});

  final _AudioOutputRoute route;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: AppRadius.borderRadius16,
        onTap: () {
          Navigator.of(context).pop(route);
        },
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              const SizedBox(width: 4),
              Icon(route.icon, size: 25, color: AppColors.grey700),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  route.label,
                  style: AppTypography.subTypography10.copyWith(
                    color: AppColors.grey900,
                    fontWeight: AppTypography.medium,
                  ),
                ),
              ),
              if (selected)
                const Icon(Icons.check_rounded, color: AppColors.blue500),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

extension on _AudioOutputRoute {
  String get label {
    return switch (this) {
      _AudioOutputRoute.phone => 'Phone',
      _AudioOutputRoute.speaker => 'Speaker',
      _AudioOutputRoute.bluetooth => 'Bluetooth Headset',
    };
  }

  IconData get icon {
    return switch (this) {
      _AudioOutputRoute.phone => Icons.phone_in_talk_rounded,
      _AudioOutputRoute.speaker => Icons.volume_up_rounded,
      _AudioOutputRoute.bluetooth => Icons.headphones_rounded,
    };
  }
}

String _normalizeSearchQuery(String query) {
  return query.trim().toLowerCase();
}

DateTime _dateOnly(DateTime value) {
  final DateTime local = value.toLocal();

  return DateTime(local.year, local.month, local.day);
}

DateTime _monthOnly(DateTime value) {
  final DateTime local = value.toLocal();

  return DateTime(local.year, local.month);
}

DateTime _addMonths(DateTime value, int delta) {
  return DateTime(value.year, value.month + delta);
}

int _daysInMonth(int year, int month) {
  return DateTime(year, month + 1, 0).day;
}

String _formatSearchMonth(DateTime month) {
  return '${month.year}.${month.month.toString().padLeft(2, '0')}';
}

String? _firstUrlInMessageText(String content) {
  final RegExpMatch? match = _messageUrlPattern.firstMatch(content);

  if (match == null) {
    return null;
  }

  String url = match.group(0)!.trimRight();

  while (url.isNotEmpty &&
      _trailingUrlPunctuation.contains(url[url.length - 1])) {
    url = url.substring(0, url.length - 1);
  }

  if (url.toLowerCase().startsWith('www.')) {
    return 'https://$url';
  }

  return url;
}

String _domainForLinkUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  String domain = uri?.host ?? '';

  if (domain.isEmpty) {
    return url;
  }

  if (domain.startsWith('www.')) {
    domain = domain.substring(4);
  }

  return domain;
}

ChatLinkPreview? _linkPreviewForContent(String content) {
  final String? url = _firstUrlInMessageText(content);

  if (url == null) {
    return null;
  }

  return ChatLinkPreview(url: url, domain: _domainForLinkUrl(url));
}

bool _isLinkOnlyMessage(ChatMessage message) {
  if (!message.isLinkMessage) {
    return false;
  }

  final String remainingText = message.content
      .replaceAll(_messageUrlPattern, '')
      .replaceAll(RegExp(r'[\s.,!?;:()\[\]{}…]+'), '');

  return remainingText.isEmpty;
}

List<String> _searchableTextSegmentsFor(ChatMessage message) {
  final List<String> segments = <String>[];

  if (!message.isPhotoMessage &&
      !message.isFileMessage &&
      !message.isCallMessage) {
    if (message.content.trim().isNotEmpty) {
      segments.add(message.content);
    }

    final String? translatedContent = message.translatedContent;

    if (translatedContent != null && translatedContent.trim().isNotEmpty) {
      segments.add(translatedContent);
    }

    final String? replyContent = message.replyTo?.content;

    if (replyContent != null && replyContent.trim().isNotEmpty) {
      segments.add(replyContent);
    }
  }

  return segments;
}

bool _messageMatchesSearchQuery(ChatMessage message, String normalizedQuery) {
  if (normalizedQuery.isEmpty) {
    return false;
  }

  for (final String segment in _searchableTextSegmentsFor(message)) {
    if (segment.toLowerCase().contains(normalizedQuery)) {
      return true;
    }
  }

  return false;
}

bool _messageNeedsTranslation(
  ChatMessage message, {
  required String currentUserPreferredLanguage,
}) {
  if (message.isPhotoMessage ||
      message.isFileMessage ||
      message.isCallMessage ||
      message.isLinkMessage ||
      message.isVoiceMemoMessage) {
    return false;
  }

  final String content = message.content.trim();

  if (content.isEmpty) {
    return false;
  }

  final String? targetLanguage =
      _normalizeChatLanguageCode(message.translatedLanguage) ??
      _normalizeChatLanguageCode(currentUserPreferredLanguage);
  final String? contentLanguage = _inferMessageContentLanguage(content);

  if (targetLanguage != null && contentLanguage != null) {
    return contentLanguage != targetLanguage;
  }

  final String? sourceLanguage = _normalizeChatLanguageCode(
    message.sourceLanguage,
  );

  if (sourceLanguage != null && targetLanguage != null) {
    return sourceLanguage != targetLanguage;
  }

  return contentLanguage != null;
}

String? _normalizeChatLanguageCode(String? languageCode) {
  final String normalized = (languageCode ?? '')
      .trim()
      .replaceAll('_', '-')
      .toLowerCase();

  if (normalized.isEmpty) {
    return null;
  }

  if (normalized == 'ko' || normalized.startsWith('ko-')) {
    return 'ko';
  }

  if (normalized == 'zh' || normalized.startsWith('zh-')) {
    return 'zh-CN';
  }

  return normalized;
}

String? _inferMessageContentLanguage(String text) {
  int koreanCount = 0;
  int chineseCount = 0;

  for (final int rune in text.runes) {
    if (_isHangulRune(rune)) {
      koreanCount++;
    } else if (_isCjkIdeographRune(rune)) {
      chineseCount++;
    }
  }

  if (koreanCount == 0 && chineseCount == 0) {
    return null;
  }

  return koreanCount >= chineseCount ? 'ko' : 'zh-CN';
}

bool _isHangulRune(int rune) {
  return (rune >= 0xAC00 && rune <= 0xD7AF) ||
      (rune >= 0x1100 && rune <= 0x11FF) ||
      (rune >= 0x3130 && rune <= 0x318F);
}

bool _isCjkIdeographRune(int rune) {
  return (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF);
}

double _measureMessageTextWidth({
  required BuildContext context,
  required String text,
  required TextStyle style,
  required double maxWidth,
}) {
  if (text.isEmpty) {
    return 0;
  }

  final double effectiveMaxWidth = maxWidth.isFinite
      ? maxWidth
      : double.infinity;
  final TextPainter textPainter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textWidthBasis: TextWidthBasis.longestLine,
    strutStyle: _buildMessageStrutStyle(style),
  )..layout(maxWidth: effectiveMaxWidth);

  if (!maxWidth.isFinite) {
    return textPainter.width;
  }

  return textPainter.width.clamp(0, maxWidth).toDouble();
}

List<_SearchMatch> _searchMatchesIn(String text, String query) {
  final String normalizedQuery = _normalizeSearchQuery(query);

  if (normalizedQuery.isEmpty || text.isEmpty) {
    return const <_SearchMatch>[];
  }

  final String normalizedText = text.toLowerCase();
  final List<_SearchMatch> matches = <_SearchMatch>[];

  int start = 0;

  while (start < normalizedText.length) {
    final int index = normalizedText.indexOf(normalizedQuery, start);

    if (index == -1) {
      break;
    }

    final int end = index + normalizedQuery.length;
    matches.add(_SearchMatch(start: index, end: end));
    start = end;
  }

  return List<_SearchMatch>.unmodifiable(matches);
}

final class _MessageList extends StatefulWidget {
  const _MessageList({
    required this.initialMessages,
    required this.currentUserId,
    required this.currentUserPreferredLanguage,
    required this.otherParticipantId,
    required this.otherParticipantName,
    required this.onTranslateMessage,
    required this.onDeleteMessage,
    required this.onPhotoMessageTap,
    required this.onCreateMediaAssetAccessUrl,
    required this.translationDelay,
    required this.initialClock,
    required this.nextLocalMessageId,
    required this.onReplySelected,
    required this.onEditSelected,
    required this.onBackgroundTap,
    required this.onPrepareMessageActions,
    required this.searchQuery,
    required this.activeSearchMessageId,
    required this.topPadding,
    required this.bottomPadding,
    required this.pinToBottom,
    super.key,
  });

  final List<ChatMessage>? initialMessages;
  final String currentUserId;
  final String currentUserPreferredLanguage;
  final String otherParticipantId;
  final String otherParticipantName;
  final ChatMessageTranslator? onTranslateMessage;
  final ChatMessageDeleter? onDeleteMessage;
  final _PhotoMessageTapCallback onPhotoMessageTap;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final Duration translationDelay;
  final DateTime? initialClock;
  final int nextLocalMessageId;
  final _ReplySelectedCallback onReplySelected;
  final _EditSelectedCallback onEditSelected;
  final VoidCallback onBackgroundTap;
  final Future<void> Function() onPrepareMessageActions;
  final String searchQuery;
  final String? activeSearchMessageId;
  final double topPadding;
  final double bottomPadding;
  final bool pinToBottom;

  @override
  State<_MessageList> createState() {
    return _MessageListState();
  }
}

final class _MessageListState extends State<_MessageList> {
  static const double _replyOriginalAlignment = 0.28;

  final Set<String> _showTranslatedMessageIds = <String>{};
  final Map<String, GlobalKey> _messageBubbleKeys = <String, GlobalKey>{};
  final ScrollController _scrollController = ScrollController();
  bool _didResolveInitialScrollPosition = false;

  Timer? _messageHighlightTimer;

  String? _highlightedMessageId;
  String? _returnToReplyMessageId;
  double? _returnToReplyScrollOffset;

  bool _replyNavigationInProgress = false;

  late DateTime _messageClock;
  late List<ChatMessage> _messages;
  late int _nextMessageId;

  @override
  void initState() {
    super.initState();

    _messageClock = widget.initialClock ?? DateTime.now();
    _messages = List<ChatMessage>.of(
      widget.initialMessages ?? const <ChatMessage>[],
    );
    _syncMessageClockWithMessages(_messages);
    _nextMessageId = widget.nextLocalMessageId;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveInitialScrollPosition();
    });
  }

  String _nextLocalMessageId() {
    return '${_nextMessageId++}';
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

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.pinToBottom && !oldWidget.pinToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(scrollToBottom(animate: false));
        }
      });
    }

    if (identical(widget.initialMessages, oldWidget.initialMessages)) {
      return;
    }

    _messages = List<ChatMessage>.of(
      widget.initialMessages ?? const <ChatMessage>[],
    );
    _syncMessageClockWithMessages(_messages);
  }

  void _syncMessageClockWith(ChatMessage message) {
    if (_messageClock.isBefore(message.createdAt)) {
      _messageClock = message.createdAt;
    }
  }

  void _syncMessageClockWithMessages(Iterable<ChatMessage> messages) {
    for (final ChatMessage message in messages) {
      _syncMessageClockWith(message);
    }
  }

  void addMessage(ChatMessage message) {
    setState(() {
      final int existingIndex = _messages.indexWhere(
        (ChatMessage existingMessage) => existingMessage.id == message.id,
      );

      if (existingIndex == -1) {
        _messages.add(message);
      } else {
        _messages[existingIndex] = message;
      }

      _messages.sort(_compareMessages);
      _syncMessageClockWith(message);
    });
  }

  void addMessages(List<ChatMessage> messages) {
    if (messages.isEmpty) {
      return;
    }

    setState(() {
      for (final ChatMessage message in messages) {
        final int existingIndex = _messages.indexWhere(
          (ChatMessage existingMessage) => existingMessage.id == message.id,
        );

        if (existingIndex == -1) {
          _messages.add(message);
        } else {
          _messages[existingIndex] = message;
        }
      }

      _messages.sort(_compareMessages);
      _syncMessageClockWithMessages(messages);
    });
  }

  bool replaceMessage(ChatMessage message) {
    final int messageIndex = _messages.indexWhere(
      (ChatMessage existingMessage) => existingMessage.id == message.id,
    );

    if (messageIndex == -1) {
      return false;
    }

    setState(() {
      _messages[messageIndex] = message;
      _messages.sort(_compareMessages);
      _syncMessageClockWith(message);
    });

    return true;
  }

  int _compareMessages(ChatMessage first, ChatMessage second) {
    final int createdAtComparison = first.createdAt.compareTo(second.createdAt);

    if (createdAtComparison != 0) {
      return createdAtComparison;
    }

    return first.id.compareTo(second.id);
  }

  void addOutgoingMessage({
    required String content,
    ChatReplyReference? replyTo,
  }) {
    setState(() {
      final DateTime createdAt = DateTime.now();
      _messageClock = createdAt;
      final ChatLinkPreview? linkPreview = _linkPreviewForContent(content);

      _messages.add(
        ChatMessage(
          id: _nextLocalMessageId(),
          senderId: widget.currentUserId,
          recipientId: widget.otherParticipantId,
          content: content,
          createdAt: createdAt,
          replyTo: replyTo,
          linkPreview: linkPreview,
        ),
      );
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
      final DateTime baseCreatedAt = DateTime.now();

      if (collage) {
        _messages.add(
          ChatMessage(
            id: _nextLocalMessageId(),
            senderId: widget.currentUserId,
            recipientId: widget.otherParticipantId,
            content: '',
            createdAt: baseCreatedAt,
            photoAttachments: List<ChatPhotoAttachment>.unmodifiable(
              attachments,
            ),
          ),
        );

        _messageClock = baseCreatedAt;
        return;
      }

      for (int index = 0; index < attachments.length; index++) {
        final DateTime createdAt = baseCreatedAt.add(Duration(seconds: index));

        _messages.add(
          ChatMessage(
            id: _nextLocalMessageId(),
            senderId: widget.currentUserId,
            recipientId: widget.otherParticipantId,
            content: '',
            createdAt: createdAt,
            photoAttachments: <ChatPhotoAttachment>[attachments[index]],
          ),
        );

        _messageClock = createdAt;
      }
    });
  }

  void addOutgoingFileMessage({required String name, required int sizeBytes}) {
    setState(() {
      final DateTime createdAt = DateTime.now();
      _messageClock = createdAt;

      _messages.add(
        ChatMessage(
          id: _nextLocalMessageId(),
          senderId: widget.currentUserId,
          recipientId: widget.otherParticipantId,
          content: '',
          createdAt: createdAt,
          fileAttachment: ChatFileAttachment(name: name, sizeBytes: sizeBytes),
        ),
      );
    });
  }

  void addOutgoingVoiceMemoMessage({
    required ChatVoiceMemoAttachment voiceMemo,
  }) {
    setState(() {
      final DateTime createdAt = DateTime.now();
      _messageClock = createdAt;

      _messages.add(
        ChatMessage(
          id: _nextLocalMessageId(),
          senderId: widget.currentUserId,
          recipientId: widget.otherParticipantId,
          content: '',
          createdAt: createdAt,
          voiceMemoAttachment: voiceMemo,
        ),
      );
    });
  }

  void addOutgoingCallMessage({
    required ChatCallOutcome outcome,
    required Duration duration,
    bool advanceClock = true,
  }) {
    setState(() {
      final DateTime createdAt = DateTime.now();
      _messageClock = createdAt;

      _messages.add(
        ChatMessage(
          id: _nextLocalMessageId(),
          senderId: widget.currentUserId,
          recipientId: widget.otherParticipantId,
          content: '',
          createdAt: createdAt,
          callAttachment: ChatCallAttachment(
            kind: ChatCallKind.voice,
            outcome: outcome,
            duration: duration,
          ),
        ),
      );
    });
  }

  bool updateMessageContent({
    required String messageId,
    required String content,
  }) {
    final int messageIndex = _messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );

    if (messageIndex == -1 ||
        _messages[messageIndex].senderId != widget.currentUserId) {
      return false;
    }

    setState(() {
      _messageClock = DateTime.now();
      final ChatLinkPreview? linkPreview = _linkPreviewForContent(content);

      _messages[messageIndex] = _messages[messageIndex].copyWith(
        content: content,
        editedAt: _messageClock,
        linkPreview: linkPreview,
        clearLinkPreview: linkPreview == null,
      );
    });

    return true;
  }

  List<String> searchMessageIds(String query) {
    final String normalizedQuery = _normalizeSearchQuery(query);

    if (normalizedQuery.isEmpty) {
      return const <String>[];
    }

    final List<ChatMessage> sortedMessages = List<ChatMessage>.of(_messages)
      ..sort((ChatMessage first, ChatMessage second) {
        final int createdAtComparison = first.createdAt.compareTo(
          second.createdAt,
        );

        if (createdAtComparison != 0) {
          return createdAtComparison;
        }

        return first.id.compareTo(second.id);
      });

    return <String>[
      for (final ChatMessage message in sortedMessages)
        if (_messageMatchesSearchQuery(message, normalizedQuery)) message.id,
    ];
  }

  Set<DateTime> searchableMessageDates() {
    return <DateTime>{
      for (final ChatMessage message in _messages)
        if (_searchableTextSegmentsFor(message).isNotEmpty)
          _dateOnly(message.createdAt),
    };
  }

  String? firstSearchableMessageIdOnDate(DateTime date) {
    final DateTime targetDate = _dateOnly(date);

    final List<ChatMessage> sortedMessages = List<ChatMessage>.of(_messages)
      ..sort((ChatMessage first, ChatMessage second) {
        final int createdAtComparison = first.createdAt.compareTo(
          second.createdAt,
        );

        if (createdAtComparison != 0) {
          return createdAtComparison;
        }

        return first.id.compareTo(second.id);
      });

    for (final ChatMessage message in sortedMessages) {
      if (_dateOnly(message.createdAt) == targetDate &&
          _searchableTextSegmentsFor(message).isNotEmpty) {
        return message.id;
      }
    }

    return null;
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

  bool _handleScrollMetricsChanged(ScrollMetricsNotification notification) {
    if (!widget.pinToBottom || !_scrollController.hasClients) {
      return false;
    }

    final ScrollPosition position = _scrollController.position;

    if (!position.hasContentDimensions) {
      return false;
    }

    final double targetOffset = position.maxScrollExtent;

    if ((position.pixels - targetOffset).abs() < 0.5) {
      return false;
    }

    _scrollController.jumpTo(targetOffset);

    return false;
  }

  RenderObject? _messageRenderObject(String messageId) {
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
    String messageId, {
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
        double targetOffsetFor(RenderObject renderObject) {
          final RenderAbstractViewport viewport = RenderAbstractViewport.of(
            renderObject,
          );

          final ScrollPosition position = _scrollController.position;

          final RevealedOffset leadingReveal = viewport.getOffsetToReveal(
            renderObject,
            0,
          );

          final RevealedOffset trailingReveal = viewport.getOffsetToReveal(
            renderObject,
            1,
          );

          final RevealedOffset desiredReveal = viewport.getOffsetToReveal(
            renderObject,
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

          final double targetHeight = renderObject is RenderBox
              ? renderObject.size.height
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

          return targetOffset
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
        }

        double targetOffset = targetOffsetFor(targetRenderObject);

        if ((targetOffset - _scrollController.position.pixels).abs() >= 0.5) {
          // 카카오톡처럼 중간 스크롤 과정을 보여주지 않고
          // 계산된 원문 위치로 즉시 이동한다.
          _scrollController.jumpTo(targetOffset);
        }

        await WidgetsBinding.instance.endOfFrame;

        if (!mounted || !_scrollController.hasClients) {
          return false;
        }

        final RenderObject? settledTargetRenderObject = _messageRenderObject(
          messageId,
        );

        if (settledTargetRenderObject != null) {
          targetOffset = targetOffsetFor(settledTargetRenderObject);

          if ((targetOffset - _scrollController.position.pixels).abs() >= 0.5) {
            _scrollController.jumpTo(targetOffset);
            await WidgetsBinding.instance.endOfFrame;
          }
        }

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

  Future<bool> scrollToSearchMessage(String messageId) {
    return _scrollToMessage(messageId, alignment: 0.24);
  }

  Future<bool> scrollToSearchDate(DateTime date) async {
    final String? messageId = firstSearchableMessageIdOnDate(date);

    if (messageId == null) {
      return false;
    }

    return _scrollToMessage(messageId, alignment: 0.24);
  }

  void _flashMessage(String messageId) {
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

  void _activateMessageHighlight(String messageId) {
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
    required String replyMessageId,
    required String originalMessageId,
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
    final String? replyMessageId = _returnToReplyMessageId;

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

  void _handleIncomingMessageTap(String messageId) {
    final ChatMessage? message = _findMessage(messageId);

    if (message == null) {
      return;
    }

    if (!_messageNeedsTranslation(
      message,
      currentUserPreferredLanguage: widget.currentUserPreferredLanguage,
    )) {
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

  void _handleFileMessageTap(ChatMessage message) {
    final ChatFileAttachment? attachment = message.fileAttachment;
    final String? mediaAssetId = attachment?.mediaAssetId;
    final ChatMediaAssetAccessUrlCreator? createAccessUrl =
        widget.onCreateMediaAssetAccessUrl;

    if (mediaAssetId == null || createAccessUrl == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('File preview is not available yet.')),
        );
      return;
    }

    unawaited(_downloadFileAttachment(attachment!, mediaAssetId));
  }

  Future<void> _downloadFileAttachment(
    ChatFileAttachment attachment,
    String mediaAssetId,
  ) async {
    try {
      final Uri accessUrl = await widget.onCreateMediaAssetAccessUrl!(
        mediaAssetId: mediaAssetId,
      );
      final http.Response response = await http.get(accessUrl);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('File download failed.');
      }

      final Directory temporaryDirectory = await getTemporaryDirectory();
      final String fileName = _safeLocalFileName(attachment.name);
      final File file = File('${temporaryDirectory.path}/$fileName');

      await file.writeAsBytes(response.bodyBytes, flush: true);
      await Clipboard.setData(ClipboardData(text: file.path));

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('File downloaded. Path copied.')),
        );
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('File download is not available.')),
        );
    }
  }

  void _retryTranslation(String messageId) {
    unawaited(_startTranslation(messageId));
  }

  String _displayedContentFor(ChatMessage message) {
    if (message.isPhotoMessage ||
        message.isFileMessage ||
        message.isCallMessage) {
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
    final DateTime actionNow = widget.initialClock == null
        ? DateTime.now()
        : _messageClock;

    final List<ChatMessageAction> actions = availableChatMessageActions(
      isOutgoing: message.senderId == widget.currentUserId,
      createdAt: message.createdAt,
      now: actionNow,
      isMedia:
          message.isPhotoMessage ||
          message.isFileMessage ||
          message.isVoiceMemoMessage,
      isCall: message.isCallMessage,
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
        unawaited(_unsendMessage(message.id));
        return;
    }
  }

  Future<void> _unsendMessage(String messageId) async {
    final ChatMessageDeleter? deleter = widget.onDeleteMessage;

    if (deleter != null) {
      try {
        await deleter(messageId: messageId);
      } catch (_) {
        return;
      }
    }

    if (!mounted) {
      return;
    }

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

  Future<void> _startTranslation(String messageId) async {
    final ChatMessageTranslator? translateMessage = widget.onTranslateMessage;

    if (translateMessage == null) {
      return;
    }

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

    if (!_messageNeedsTranslation(
      currentMessage,
      currentUserPreferredLanguage: widget.currentUserPreferredLanguage,
    )) {
      return;
    }

    setState(() {
      _showTranslatedMessageIds.remove(messageId);

      _messages[messageIndex] = currentMessage.copyWith(
        translationStatus: ChatTranslationStatus.translating,
        clearTranslationFailureReason: true,
      );
    });

    await Future<void>.delayed(widget.translationDelay);

    if (!mounted) {
      return;
    }

    final int refreshedIndex = _messages.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );

    if (refreshedIndex == -1) {
      return;
    }

    final String? translatedContent = await translateMessage(
      _messages[refreshedIndex],
    );

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

  GlobalKey _messageBubbleKeyFor(String messageId) {
    return _messageBubbleKeys.putIfAbsent(messageId, () => GlobalKey());
  }

  ChatMessage? _findMessage(String messageId) {
    for (final ChatMessage message in _messages) {
      if (message.id == messageId) {
        return message;
      }
    }

    return null;
  }

  ChatMessage? findMessage(String messageId) {
    return _findMessage(messageId);
  }

  @override
  Widget build(BuildContext context) {
    final List<ChatMessageGroup> groups = groupChatMessages(_messages);

    final String? latestReadMessageId = findLatestReadOutgoingMessageId(
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
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _handleScrollMetricsChanged,
            child: ListView(
              key: const ValueKey<String>('message-list'),
              controller: _scrollController,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                8,
                widget.topPadding,
                8,
                widget.bottomPadding,
              ),
              children: _buildTimeline(
                groups: groups,
                latestReadMessageId: latestReadMessageId,
              ),
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
    required String? latestReadMessageId,
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
          currentUserPreferredLanguage: widget.currentUserPreferredLanguage,
          otherParticipantName: widget.otherParticipantName,
          latestReadMessageId: latestReadMessageId,
          now: _messageClock,
          shownTranslatedMessageIds: _showTranslatedMessageIds,
          highlightedMessageId:
              _highlightedMessageId ?? widget.activeSearchMessageId,
          searchQuery: widget.searchQuery,
          canRequestTranslation: widget.onTranslateMessage != null,
          onIncomingMessageTap: _handleIncomingMessageTap,
          onFileMessageTap: _handleFileMessageTap,
          onPhotoMessageTap: widget.onPhotoMessageTap,
          onCreateMediaAssetAccessUrl: widget.onCreateMediaAssetAccessUrl,
          onRetryTranslation: _retryTranslation,
          onMessageLongPress: _handleMessageLongPress,
          onReplyQuoteTap: _handleReplyQuoteTap,
          messageBubbleKeyFor: _messageBubbleKeyFor,
        ),
      );

      if (index != groups.length - 1) {
        timeline.add(
          SizedBox(height: _timelineGapBetweenGroups(group, groups[index + 1])),
        );
      }
    }

    return timeline;
  }

  double _timelineGapBetweenGroups(
    ChatMessageGroup group,
    ChatMessageGroup nextGroup,
  ) {
    if (!isSameChatDate(group.createdAt, nextGroup.createdAt)) {
      return 18;
    }

    final bool consecutiveCallBubbles =
        group.senderId == nextGroup.senderId &&
        group.messages.last.isCallMessage &&
        nextGroup.messages.first.isCallMessage;

    return consecutiveCallBubbles ? 8 : 14;
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
    required this.currentUserId,
    required this.otherParticipantName,
    required this.isOutgoing,
    required this.searchQuery,
    required this.onReplyQuoteTap,
    required this.child,
  });

  final ChatMessage message;
  final String currentUserId;
  final String otherParticipantName;
  final bool isOutgoing;
  final String searchQuery;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ChatReplyReference? replyTo = message.replyTo;

    final Widget messageBody;

    if (replyTo == null) {
      messageBody = child;
    } else {
      final String authorLabel = replyTo.senderId == currentUserId
          ? 'Me'
          : otherParticipantName;

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
            _SearchHighlightedText(
              text: replyTo.content,
              query: searchQuery,
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
    required this.currentUserPreferredLanguage,
    required this.otherParticipantName,
    required this.latestReadMessageId,
    required this.now,
    required this.shownTranslatedMessageIds,
    required this.highlightedMessageId,
    required this.searchQuery,
    required this.canRequestTranslation,
    required this.onIncomingMessageTap,
    required this.onFileMessageTap,
    required this.onPhotoMessageTap,
    required this.onCreateMediaAssetAccessUrl,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.messageBubbleKeyFor,
  });

  final ChatMessageGroup group;
  final String currentUserId;
  final String currentUserPreferredLanguage;
  final String otherParticipantName;
  final String? latestReadMessageId;
  final DateTime now;
  final Set<String> shownTranslatedMessageIds;
  final String? highlightedMessageId;
  final String searchQuery;
  final bool canRequestTranslation;
  final ValueChanged<String> onIncomingMessageTap;
  final ValueChanged<ChatMessage> onFileMessageTap;
  final _PhotoMessageTapCallback onPhotoMessageTap;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ValueChanged<String> onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final _MessageBubbleKeyFor messageBubbleKeyFor;

  @override
  Widget build(BuildContext context) {
    if (group.senderId == currentUserId) {
      return _OutgoingMessageGroup(
        messages: group.messages,
        currentUserId: currentUserId,
        otherParticipantName: otherParticipantName,
        latestReadMessageId: latestReadMessageId,
        now: now,
        highlightedMessageId: highlightedMessageId,
        searchQuery: searchQuery,
        onFileMessageTap: onFileMessageTap,
        onPhotoMessageTap: onPhotoMessageTap,
        onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
        onMessageLongPress: onMessageLongPress,
        onReplyQuoteTap: onReplyQuoteTap,
        messageBubbleKeyFor: messageBubbleKeyFor,
      );
    }

    return _IncomingMessageGroup(
      messages: group.messages,
      currentUserId: currentUserId,
      currentUserPreferredLanguage: currentUserPreferredLanguage,
      otherParticipantName: otherParticipantName,
      shownTranslatedMessageIds: shownTranslatedMessageIds,
      highlightedMessageId: highlightedMessageId,
      searchQuery: searchQuery,
      canRequestTranslation: canRequestTranslation,
      onIncomingMessageTap: onIncomingMessageTap,
      onFileMessageTap: onFileMessageTap,
      onPhotoMessageTap: onPhotoMessageTap,
      onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
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
    required this.currentUserId,
    required this.currentUserPreferredLanguage,
    required this.otherParticipantName,
    required this.shownTranslatedMessageIds,
    required this.highlightedMessageId,
    required this.searchQuery,
    required this.canRequestTranslation,
    required this.onIncomingMessageTap,
    required this.onFileMessageTap,
    required this.onPhotoMessageTap,
    required this.onCreateMediaAssetAccessUrl,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.messageBubbleKeyFor,
  });

  final List<ChatMessage> messages;
  final String currentUserId;
  final String currentUserPreferredLanguage;
  final String otherParticipantName;
  final Set<String> shownTranslatedMessageIds;
  final String? highlightedMessageId;
  final String searchQuery;
  final bool canRequestTranslation;
  final ValueChanged<String> onIncomingMessageTap;
  final ValueChanged<ChatMessage> onFileMessageTap;
  final _PhotoMessageTapCallback onPhotoMessageTap;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ValueChanged<String> onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final _MessageBubbleKeyFor messageBubbleKeyFor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _ProfilePlaceholder(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int index = 0; index < messages.length; index++) ...[
                _IncomingMessageRow(
                  message: messages[index],
                  currentUserId: currentUserId,
                  currentUserPreferredLanguage: currentUserPreferredLanguage,
                  otherParticipantName: otherParticipantName,
                  showTail: index == 0,
                  showTime: index == messages.length - 1,
                  showTranslation: shownTranslatedMessageIds.contains(
                    messages[index].id,
                  ),
                  isHighlighted: messages[index].id == highlightedMessageId,
                  searchQuery: searchQuery,
                  canRequestTranslation: canRequestTranslation,
                  onMessageTap: () {
                    onIncomingMessageTap(messages[index].id);
                  },
                  onFileMessageTap: onFileMessageTap,
                  onPhotoMessageTap: onPhotoMessageTap,
                  onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
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
    required this.currentUserId,
    required this.currentUserPreferredLanguage,
    required this.otherParticipantName,
    required this.showTail,
    required this.showTime,
    required this.showTranslation,
    required this.isHighlighted,
    required this.searchQuery,
    required this.canRequestTranslation,
    required this.onMessageTap,
    required this.onFileMessageTap,
    required this.onPhotoMessageTap,
    required this.onCreateMediaAssetAccessUrl,
    required this.onRetryTranslation,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.bubbleInteractionKey,
  });

  final ChatMessage message;
  final String currentUserId;
  final String currentUserPreferredLanguage;
  final String otherParticipantName;
  final bool showTail;
  final bool showTime;
  final bool showTranslation;
  final bool isHighlighted;
  final String searchQuery;
  final bool canRequestTranslation;
  final VoidCallback onMessageTap;
  final ValueChanged<ChatMessage> onFileMessageTap;
  final _PhotoMessageTapCallback onPhotoMessageTap;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final VoidCallback onRetryTranslation;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final GlobalKey bubbleInteractionKey;

  @override
  Widget build(BuildContext context) {
    final bool isFileMessage = message.isFileMessage;
    final bool isPhotoMessage = message.isPhotoMessage;
    final bool isCallMessage = message.isCallMessage;
    final bool isVoiceMemoMessage = message.isVoiceMemoMessage;
    final bool isLinkMessage = message.isLinkMessage;
    final bool canUseTranslation = _messageNeedsTranslation(
      message,
      currentUserPreferredLanguage: currentUserPreferredLanguage,
    );
    final bool canTapBubble =
        isFileMessage ||
        (!isPhotoMessage &&
            !isCallMessage &&
            !isVoiceMemoMessage &&
            canUseTranslation &&
            (message.translationStatus == ChatTranslationStatus.translated ||
                (canRequestTranslation &&
                    message.translationStatus == ChatTranslationStatus.none)));

    final Widget content;

    if (isPhotoMessage) {
      content = _PhotoMessage(
        messageId: message.id,
        measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
        attachments: message.photoAttachments,
        isHighlighted: isHighlighted,
        pulseAlignment: Alignment.centerLeft,
        onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
        onPhotoTap: (int photoIndex) {
          onPhotoMessageTap(message, photoIndex);
        },
      );
    } else if (isCallMessage) {
      content = _CallMessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
        attachment: message.callAttachment!,
        isOutgoing: false,
        isHighlighted: isHighlighted,
      );
    } else if (isVoiceMemoMessage) {
      content = _VoiceMemoMessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
        attachment: message.voiceMemoAttachment!,
        isHighlighted: isHighlighted,
        onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
      );
    } else if (isLinkMessage) {
      content = _LinkMessageContent(
        message: message,
        isOutgoing: false,
        showTail: showTail && !_isLinkOnlyMessage(message),
        isHighlighted: isHighlighted,
        searchQuery: searchQuery,
        currentUserId: currentUserId,
        otherParticipantName: otherParticipantName,
        onReplyQuoteTap: onReplyQuoteTap,
        measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
      );
    } else {
      content = _MessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('incoming-bubble-${message.id}'),
        backgroundColor: AppColors.grey100,
        direction: _BubbleDirection.incoming,
        showTail: showTail,
        isHighlighted: isHighlighted,
        child: isFileMessage
            ? _FileMessageContent(
                attachment: message.fileAttachment!,
                isOutgoing: false,
              )
            : _IncomingMessageContent(
                message: message,
                currentUserId: currentUserId,
                otherParticipantName: otherParticipantName,
                showTranslation: showTranslation,
                searchQuery: searchQuery,
                canRequestTranslation: canRequestTranslation,
                canUseTranslation: canUseTranslation,
                onRetryTranslation: onRetryTranslation,
                onReplyQuoteTap: onReplyQuoteTap,
              ),
      );
    }

    final Widget bubble = _MessageCaptureBoundary(
      key: bubbleInteractionKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTapBubble
            ? isFileMessage
                  ? () {
                      onFileMessageTap(message);
                    }
                  : onMessageTap
            : null,
        onLongPress: () {
          unawaited(onMessageLongPress(message, bubbleInteractionKey));
        },
        child: content,
      ),
    );
    final Widget rowBubble = isCallMessage || isVoiceMemoMessage
        ? bubble
        : Flexible(fit: FlexFit.loose, child: bubble);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        rowBubble,
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
    required this.currentUserId,
    required this.otherParticipantName,
    required this.showTranslation,
    required this.searchQuery,
    required this.canRequestTranslation,
    required this.canUseTranslation,
    required this.onRetryTranslation,
    required this.onReplyQuoteTap,
  });

  final ChatMessage message;
  final String currentUserId;
  final String otherParticipantName;
  final bool showTranslation;
  final String searchQuery;
  final bool canRequestTranslation;
  final bool canUseTranslation;
  final VoidCallback onRetryTranslation;
  final _ReplyQuoteTapCallback onReplyQuoteTap;

  @override
  Widget build(BuildContext context) {
    final TextStyle messageTextStyle = AppTypography.subTypography10.copyWith(
      color: AppColors.grey900,
      fontWeight: AppTypography.regular,
    );

    final bool hasCompletedTranslation =
        canUseTranslation &&
        message.translationStatus == ChatTranslationStatus.translated &&
        message.translatedContent != null;

    final Widget messageText;

    if (hasCompletedTranslation) {
      final bool searchMatchesOriginal = _searchMatchesIn(
        message.content,
        searchQuery,
      ).isNotEmpty;
      final bool searchMatchesTranslation = _searchMatchesIn(
        message.translatedContent!,
        searchQuery,
      ).isNotEmpty;
      final bool showSearchTranslation =
          searchQuery.trim().isNotEmpty &&
          searchMatchesTranslation &&
          !searchMatchesOriginal;

      messageText = _AnimatedTranslationText(
        messageId: message.id,
        originalContent: message.content,
        translatedContent: message.translatedContent!,
        showTranslation: showTranslation || showSearchTranslation,
        searchQuery: searchQuery,
        style: messageTextStyle,
      );
    } else {
      messageText = _SearchHighlightedText(
        text: message.content,
        query: searchQuery,
        key: ValueKey<String>('original-message-${message.id}'),
        style: messageTextStyle,
      );
    }

    final Widget messageBody = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double statusMaxWidth = _measureMessageTextWidth(
          context: context,
          text: message.content,
          style: messageTextStyle,
          maxWidth: constraints.maxWidth,
        );

        return Column(
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
              child: _buildTranslationStatus(context, maxWidth: statusMaxWidth),
            ),
          ],
        );
      },
    );

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: _ReplyMessageBody(
        message: message,
        currentUserId: currentUserId,
        otherParticipantName: otherParticipantName,
        isOutgoing: false,
        searchQuery: searchQuery,
        onReplyQuoteTap: onReplyQuoteTap,
        child: messageBody,
      ),
    );
  }

  Widget _buildTranslationStatus(
    BuildContext context, {
    required double maxWidth,
  }) {
    if (!canUseTranslation) {
      return SizedBox.shrink(
        key: ValueKey<String>('translation-skipped-${message.id}'),
      );
    }

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
          child: SizedBox(
            width: maxWidth,
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
                if (canRequestTranslation && canUseTranslation) ...[
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
              ],
            ),
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
    required this.searchQuery,
    required this.style,
  });

  final String messageId;
  final String originalContent;
  final String translatedContent;
  final bool showTranslation;
  final String searchQuery;
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
      child: _SearchHighlightedText(
        text: displayedContent,
        query: searchQuery,
        key: ValueKey<String>(displayedKey),
        style: style,
      ),
    );
  }
}

final class _SearchHighlightedText extends StatelessWidget {
  const _SearchHighlightedText({
    required this.text,
    required this.query,
    required this.style,
    this.maxLines,
    this.overflow,
    super.key,
  });

  final String text;
  final String query;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final List<_SearchMatch> matches = _searchMatchesIn(text, query);

    if (matches.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: overflow,
        softWrap: true,
        strutStyle: _buildMessageStrutStyle(style),
        style: style,
        textWidthBasis: TextWidthBasis.longestLine,
        textHeightBehavior: _messageTextHeightBehavior,
      );
    }

    return Text.rich(
      _buildSpan(matches),
      maxLines: maxLines,
      overflow: overflow,
      softWrap: true,
      strutStyle: _buildMessageStrutStyle(style),
      textWidthBasis: TextWidthBasis.longestLine,
      textHeightBehavior: _messageTextHeightBehavior,
    );
  }

  TextSpan _buildSpan(List<_SearchMatch> matches) {
    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;

    for (final _SearchMatch match in matches) {
      if (match.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, match.start)));
      }

      children.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: style.copyWith(
            backgroundColor: AppColors.primary.withAlpha(54),
          ),
        ),
      );

      cursor = match.end;
    }

    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }

    return TextSpan(style: style, children: children);
  }
}

final class _LinkMessageContent extends StatelessWidget {
  const _LinkMessageContent({
    required this.message,
    required this.isOutgoing,
    required this.showTail,
    required this.isHighlighted,
    required this.searchQuery,
    required this.currentUserId,
    required this.otherParticipantName,
    required this.onReplyQuoteTap,
    required this.measurementKey,
  });

  final ChatMessage message;
  final bool isOutgoing;
  final bool showTail;
  final bool isHighlighted;
  final String searchQuery;
  final String currentUserId;
  final String otherParticipantName;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final Key measurementKey;

  @override
  Widget build(BuildContext context) {
    final ChatLinkPreview preview = message.linkPreview!;
    final bool linkOnly = _isLinkOnlyMessage(message);
    final CrossAxisAlignment crossAxisAlignment = isOutgoing
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;
    final TextStyle messageTextStyle = AppTypography.subTypography10.copyWith(
      color: isOutgoing ? AppColors.white : AppColors.grey900,
      fontWeight: AppTypography.regular,
    );

    final List<Widget> children = <Widget>[];

    if (!linkOnly) {
      children.add(
        _MessageBubble(
          messageId: message.id,
          measurementKey: measurementKey,
          backgroundColor: isOutgoing ? AppColors.blue500 : AppColors.grey100,
          direction: isOutgoing
              ? _BubbleDirection.outgoing
              : _BubbleDirection.incoming,
          showTail: showTail,
          isHighlighted: isHighlighted,
          child: _ReplyMessageBody(
            message: message,
            currentUserId: currentUserId,
            otherParticipantName: otherParticipantName,
            isOutgoing: isOutgoing,
            searchQuery: searchQuery,
            onReplyQuoteTap: onReplyQuoteTap,
            child: _LinkifiedMessageText(
              text: message.content,
              style: messageTextStyle,
              linkColor: isOutgoing ? AppColors.white : AppColors.blue500,
            ),
          ),
        ),
      );
      children.add(const SizedBox(height: 6));
    }

    children.add(
      _LinkPreviewCard(
        key: linkOnly ? measurementKey : null,
        preview: preview,
        isHighlighted: linkOnly && isHighlighted,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      children: children,
    );
  }
}

final class _LinkifiedMessageText extends StatelessWidget {
  const _LinkifiedMessageText({
    required this.text,
    required this.style,
    required this.linkColor,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      _buildSpan(),
      softWrap: true,
      strutStyle: _buildMessageStrutStyle(style),
      textWidthBasis: TextWidthBasis.longestLine,
      textHeightBehavior: _messageTextHeightBehavior,
    );
  }

  TextSpan _buildSpan() {
    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;

    for (final RegExpMatch match in _messageUrlPattern.allMatches(text)) {
      if (match.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, match.start)));
      }

      final String rawUrl = match.group(0)!;
      int linkEnd = rawUrl.length;

      while (linkEnd > 0 &&
          _trailingUrlPunctuation.contains(rawUrl[linkEnd - 1])) {
        linkEnd--;
      }

      final String linkText = rawUrl.substring(0, linkEnd);
      final String trailingText = rawUrl.substring(linkEnd);

      if (linkText.isNotEmpty) {
        children.add(
          TextSpan(
            text: linkText,
            style: style.copyWith(
              color: linkColor,
              decoration: TextDecoration.underline,
              decorationColor: linkColor,
              decorationThickness: 1.2,
            ),
          ),
        );
      }

      if (trailingText.isNotEmpty) {
        children.add(TextSpan(text: trailingText));
      }

      cursor = match.end;
    }

    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }

    return TextSpan(style: style, children: children);
  }
}

final class _LinkPreviewCard extends StatelessWidget {
  const _LinkPreviewCard({
    required this.preview,
    required this.isHighlighted,
    super.key,
  });

  final ChatLinkPreview preview;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    final double cardWidth = math.min(
      MediaQuery.sizeOf(context).width * 0.68,
      316,
    );
    final Border border = Border.all(
      color: isHighlighted
          ? AppColors.primary.withAlpha(110)
          : AppColors.grey200,
      width: isHighlighted ? 1.6 : 1,
    );
    final String title = preview.title ?? preview.siteName ?? preview.domain;
    final String? description = preview.description;
    final String domain = preview.domain;

    return SizedBox(
      width: cardWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(17),
          border: border,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(17),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LinkPreviewImage(preview: preview, width: cardWidth),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subTypography10.copyWith(
                        color: AppColors.grey900,
                        fontWeight: AppTypography.bold,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.subTypography12.copyWith(
                          color: AppColors.grey600,
                          fontWeight: AppTypography.regular,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      domain,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subTypography12.copyWith(
                        color: AppColors.blue500,
                        fontWeight: AppTypography.regular,
                        decoration: TextDecoration.underline,
                        decorationColor: AppColors.blue500,
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
}

final class _LinkPreviewImage extends StatelessWidget {
  const _LinkPreviewImage({required this.preview, required this.width});

  final ChatLinkPreview preview;
  final double width;

  @override
  Widget build(BuildContext context) {
    final String? imageUrl = preview.imageUrl;
    final Uri? imageUri = imageUrl == null ? null : Uri.tryParse(imageUrl);

    if (imageUri == null ||
        (imageUri.scheme != 'http' && imageUri.scheme != 'https')) {
      return _buildPlaceholder();
    }

    return Image.network(
      imageUri.toString(),
      width: width,
      height: 128,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      loadingBuilder:
          (
            BuildContext context,
            Widget child,
            ImageChunkEvent? loadingProgress,
          ) {
            if (loadingProgress == null) {
              return child;
            }

            return _buildPlaceholder();
          },
      errorBuilder: (_, _, _) {
        return _buildPlaceholder();
      },
    );
  }

  Widget _buildPlaceholder() {
    final String label = preview.siteName ?? preview.domain;

    return Container(
      width: width,
      height: 112,
      alignment: Alignment.center,
      color: AppColors.grey50,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: AppTypography.subTypography10.copyWith(
          color: AppColors.grey600,
          fontWeight: AppTypography.bold,
        ),
      ),
    );
  }
}

final class _OutgoingMessageGroup extends StatelessWidget {
  const _OutgoingMessageGroup({
    required this.messages,
    required this.currentUserId,
    required this.otherParticipantName,
    required this.latestReadMessageId,
    required this.now,
    required this.highlightedMessageId,
    required this.searchQuery,
    required this.onFileMessageTap,
    required this.onPhotoMessageTap,
    required this.onCreateMediaAssetAccessUrl,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.messageBubbleKeyFor,
  });

  final List<ChatMessage> messages;
  final String currentUserId;
  final String otherParticipantName;
  final String? latestReadMessageId;
  final DateTime now;
  final String? highlightedMessageId;
  final String searchQuery;
  final ValueChanged<ChatMessage> onFileMessageTap;
  final _PhotoMessageTapCallback onPhotoMessageTap;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
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
            currentUserId: currentUserId,
            otherParticipantName: otherParticipantName,
            showTail: index == 0,
            showTime: index == messages.length - 1,
            isHighlighted: messages[index].id == highlightedMessageId,
            searchQuery: searchQuery,
            onFileMessageTap: onFileMessageTap,
            onPhotoMessageTap: onPhotoMessageTap,
            onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
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
    required this.currentUserId,
    required this.otherParticipantName,
    required this.showTail,
    required this.showTime,
    required this.isHighlighted,
    required this.searchQuery,
    required this.onFileMessageTap,
    required this.onPhotoMessageTap,
    required this.onCreateMediaAssetAccessUrl,
    required this.onMessageLongPress,
    required this.onReplyQuoteTap,
    required this.bubbleInteractionKey,
  });

  final ChatMessage message;
  final String currentUserId;
  final String otherParticipantName;
  final bool showTail;
  final bool showTime;
  final bool isHighlighted;
  final String searchQuery;
  final ValueChanged<ChatMessage> onFileMessageTap;
  final _PhotoMessageTapCallback onPhotoMessageTap;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final _MessageLongPressCallback onMessageLongPress;
  final _ReplyQuoteTapCallback onReplyQuoteTap;
  final GlobalKey bubbleInteractionKey;

  @override
  Widget build(BuildContext context) {
    final TextStyle messageTextStyle = AppTypography.subTypography10.copyWith(
      color: AppColors.white,
      fontWeight: AppTypography.regular,
    );

    final Widget content;

    if (message.isPhotoMessage) {
      content = _PhotoMessage(
        messageId: message.id,
        measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
        attachments: message.photoAttachments,
        isHighlighted: isHighlighted,
        pulseAlignment: Alignment.centerRight,
        onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
        onPhotoTap: (int photoIndex) {
          onPhotoMessageTap(message, photoIndex);
        },
      );
    } else if (message.isCallMessage) {
      content = _CallMessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
        attachment: message.callAttachment!,
        isOutgoing: true,
        isHighlighted: isHighlighted,
      );
    } else if (message.isVoiceMemoMessage) {
      content = _VoiceMemoMessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
        attachment: message.voiceMemoAttachment!,
        isHighlighted: isHighlighted,
        onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
      );
    } else if (message.isLinkMessage) {
      content = _LinkMessageContent(
        message: message,
        isOutgoing: true,
        showTail: showTail && !_isLinkOnlyMessage(message),
        isHighlighted: isHighlighted,
        searchQuery: searchQuery,
        currentUserId: currentUserId,
        otherParticipantName: otherParticipantName,
        onReplyQuoteTap: onReplyQuoteTap,
        measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
      );
    } else if (message.isFileMessage) {
      content = _MessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
        backgroundColor: AppColors.blue500,
        direction: _BubbleDirection.outgoing,
        showTail: showTail,
        isHighlighted: isHighlighted,
        child: _FileMessageContent(
          attachment: message.fileAttachment!,
          isOutgoing: true,
        ),
      );
    } else {
      content = _MessageBubble(
        messageId: message.id,
        measurementKey: ValueKey<String>('outgoing-bubble-${message.id}'),
        backgroundColor: AppColors.blue500,
        direction: _BubbleDirection.outgoing,
        showTail: showTail,
        isHighlighted: isHighlighted,
        child: _ReplyMessageBody(
          message: message,
          currentUserId: currentUserId,
          otherParticipantName: otherParticipantName,
          isOutgoing: true,
          searchQuery: searchQuery,
          onReplyQuoteTap: onReplyQuoteTap,
          child: _SearchHighlightedText(
            text: message.content,
            query: searchQuery,
            style: messageTextStyle,
            key: ValueKey<String>('original-message-${message.id}'),
          ),
        ),
      );
    }

    final Widget bubble = _MessageCaptureBoundary(
      key: bubbleInteractionKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: message.isFileMessage
            ? () {
                onFileMessageTap(message);
              }
            : null,
        onLongPress: () {
          unawaited(onMessageLongPress(message, bubbleInteractionKey));
        },
        child: content,
      ),
    );
    final Widget rowBubble = message.isCallMessage || message.isVoiceMemoMessage
        ? bubble
        : Flexible(fit: FlexFit.loose, child: bubble);

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
        rowBubble,
      ],
    );
  }
}

final class _PhotoMessage extends StatefulWidget {
  const _PhotoMessage({
    required this.messageId,
    required this.attachments,
    required this.isHighlighted,
    required this.measurementKey,
    required this.pulseAlignment,
    required this.onCreateMediaAssetAccessUrl,
    required this.onPhotoTap,
  });

  final String messageId;
  final List<ChatPhotoAttachment> attachments;
  final bool isHighlighted;
  final Key measurementKey;
  final Alignment pulseAlignment;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ValueChanged<int> onPhotoTap;

  @override
  State<_PhotoMessage> createState() {
    return _PhotoMessageState();
  }
}

final class _PhotoMessageState extends State<_PhotoMessage>
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
  void didUpdateWidget(_PhotoMessage oldWidget) {
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
      child: _PhotoMessageCollage(
        attachments: widget.attachments,
        onCreateMediaAssetAccessUrl: widget.onCreateMediaAssetAccessUrl,
        onPhotoTap: widget.onPhotoTap,
      ),
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
            alignment: widget.pulseAlignment,
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
  const _PhotoMessageCollage({
    required this.attachments,
    required this.onCreateMediaAssetAccessUrl,
    required this.onPhotoTap,
  });

  final List<ChatPhotoAttachment> attachments;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ValueChanged<int> onPhotoTap;

  static const double _spacing = 2;

  static const List<int> _tenPhotoRows = <int>[3, 3, 2, 2];

  @override
  Widget build(BuildContext context) {
    final double width = math.min(260, MediaQuery.sizeOf(context).width * 0.68);

    if (attachments.isEmpty) {
      return const SizedBox.shrink();
    }

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
          child: _buildPhotoTile(
            attachment: attachment,
            itemIndex: 0,
            hiddenCount: 0,
            onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
            onTap: () {
              onPhotoTap(0);
            },
          ),
        ),
      );
    }

    if (attachments.length == 3) {
      return _buildThreePhotoCollage(width);
    }

    final List<ChatPhotoAttachment> visible = attachments.take(10).toList();

    return _buildRowCollage(
      width: width,
      rowPattern: _rowPatternForCount(visible.length),
      visible: visible,
      hiddenCount: attachments.length - visible.length,
    );
  }

  Widget _buildThreePhotoCollage(double width) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      child: SizedBox(
        width: width,
        height: width,
        child: Row(
          children: [
            Expanded(
              child: _buildPhotoTile(
                attachment: attachments[0],
                itemIndex: 0,
                hiddenCount: 0,
                onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
                onTap: () {
                  onPhotoTap(0);
                },
              ),
            ),
            const SizedBox(width: _spacing),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: _buildPhotoTile(
                      attachment: attachments[1],
                      itemIndex: 1,
                      hiddenCount: 0,
                      onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
                      onTap: () {
                        onPhotoTap(1);
                      },
                    ),
                  ),
                  const SizedBox(height: _spacing),
                  Expanded(
                    child: _buildPhotoTile(
                      attachment: attachments[2],
                      itemIndex: 2,
                      hiddenCount: 0,
                      onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
                      onTap: () {
                        onPhotoTap(2);
                      },
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

  static List<int> _rowPatternForCount(int count) {
    return switch (count) {
      2 => const <int>[2],
      4 => const <int>[2, 2],
      5 => const <int>[3, 2],
      6 => const <int>[3, 3],
      7 => const <int>[3, 2, 2],
      8 => const <int>[3, 3, 2],
      9 => const <int>[3, 3, 3],
      10 => _tenPhotoRows,
      _ => _tenPhotoRows,
    };
  }

  Widget _buildRowCollage({
    required double width,
    required List<int> rowPattern,
    required List<ChatPhotoAttachment> visible,
    int hiddenCount = 0,
  }) {
    final int maximumColumns = rowPattern.reduce(math.max);
    final double rowHeight =
        (width - (_spacing * (maximumColumns - 1))) / maximumColumns;
    final double height =
        (rowHeight * rowPattern.length) + (_spacing * (rowPattern.length - 1));

    final List<Widget> rows = <Widget>[];
    int attachmentIndex = 0;

    for (int rowIndex = 0; rowIndex < rowPattern.length; rowIndex++) {
      final int columns = rowPattern[rowIndex];
      final List<Widget> rowChildren = <Widget>[];

      for (
        int columnIndex = 0;
        columnIndex < columns && attachmentIndex < visible.length;
        columnIndex++
      ) {
        final int itemIndex = attachmentIndex;

        rowChildren.add(
          Expanded(
            child: _buildPhotoTile(
              attachment: visible[itemIndex],
              itemIndex: itemIndex,
              hiddenCount: itemIndex == visible.length - 1 ? hiddenCount : 0,
              onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
              onTap: () {
                onPhotoTap(itemIndex);
              },
            ),
          ),
        );

        attachmentIndex++;

        if (columnIndex < columns - 1 && attachmentIndex < visible.length) {
          rowChildren.add(const SizedBox(width: _spacing));
        }
      }

      rows.add(
        SizedBox(
          height: rowHeight,
          child: Row(children: rowChildren),
        ),
      );

      if (rowIndex < rowPattern.length - 1) {
        rows.add(const SizedBox(height: _spacing));
      }
    }

    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(14)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(children: rows),
      ),
    );
  }

  static Widget _buildPhotoTile({
    required ChatPhotoAttachment attachment,
    required int itemIndex,
    required int hiddenCount,
    required ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PhotoMessageImage(
            attachment: attachment,
            itemIndex: itemIndex,
            onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
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
      ),
    );
  }
}

final class _PhotoMessageImage extends StatefulWidget {
  const _PhotoMessageImage({
    required this.attachment,
    required this.itemIndex,
    required this.onCreateMediaAssetAccessUrl,
    this.imageKey,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.filterQuality = FilterQuality.medium,
  });

  final ChatPhotoAttachment attachment;
  final int itemIndex;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final String? imageKey;
  final double? width;
  final double? height;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  State<_PhotoMessageImage> createState() {
    return _PhotoMessageImageState();
  }
}

final class _PhotoMessageImageState extends State<_PhotoMessageImage> {
  static const Duration _resolvedAccessUrlTtl = Duration(minutes: 4);
  static final Map<String, _ResolvedPhotoAccessUrl> _resolvedAccessUrls =
      <String, _ResolvedPhotoAccessUrl>{};

  Future<Uri>? _accessUrlFuture;
  Uri? _resolvedAccessUrl;

  static void rememberAccessUrl(String mediaAssetId, Uri url) {
    _resolvedAccessUrls[mediaAssetId] = _ResolvedPhotoAccessUrl(
      url: url,
      resolvedAt: DateTime.now(),
    );
  }

  @override
  void initState() {
    super.initState();
    _syncAccessUrlFuture();
  }

  @override
  void didUpdateWidget(_PhotoMessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.attachment != widget.attachment ||
        oldWidget.onCreateMediaAssetAccessUrl !=
            widget.onCreateMediaAssetAccessUrl) {
      _syncAccessUrlFuture();
    }
  }

  void _syncAccessUrlFuture() {
    if (widget.attachment.previewBytes != null) {
      _accessUrlFuture = null;
      _resolvedAccessUrl = null;
      return;
    }

    final String? mediaAssetId = widget.attachment.mediaAssetId;
    final ChatMediaAssetAccessUrlCreator? createAccessUrl =
        widget.onCreateMediaAssetAccessUrl;

    if (mediaAssetId == null || createAccessUrl == null) {
      _accessUrlFuture = null;
      _resolvedAccessUrl = null;
      return;
    }

    final _ResolvedPhotoAccessUrl? resolvedAccessUrl =
        _resolvedAccessUrls[mediaAssetId];

    if (resolvedAccessUrl != null &&
        DateTime.now().difference(resolvedAccessUrl.resolvedAt) <
            _resolvedAccessUrlTtl) {
      _accessUrlFuture = null;
      _resolvedAccessUrl = resolvedAccessUrl.url;
      return;
    }

    _resolvedAccessUrl = null;
    _accessUrlFuture = createAccessUrl(mediaAssetId: mediaAssetId).then((
      Uri url,
    ) {
      rememberAccessUrl(mediaAssetId, url);

      if (mounted && widget.attachment.mediaAssetId == mediaAssetId) {
        _resolvedAccessUrl = url;
      }

      return url;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? previewBytes = widget.attachment.previewBytes;

    if (previewBytes != null) {
      return Image.memory(
        previewBytes,
        key: ValueKey<String>(widget.imageKey ?? _defaultImageKey),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: widget.filterQuality,
      );
    }

    final Uri? resolvedAccessUrl = _resolvedAccessUrl;

    if (resolvedAccessUrl != null) {
      return _buildNetworkImage(resolvedAccessUrl);
    }

    final Future<Uri>? accessUrlFuture = _accessUrlFuture;

    if (accessUrlFuture == null) {
      return _buildPlaceholder();
    }

    return FutureBuilder<Uri>(
      future: accessUrlFuture,
      builder: (BuildContext context, AsyncSnapshot<Uri> snapshot) {
        if (!snapshot.hasData) {
          return _buildPlaceholder();
        }

        return _buildNetworkImage(snapshot.data!);
      },
    );
  }

  Widget _buildNetworkImage(Uri accessUrl) {
    return Image.network(
      accessUrl.toString(),
      key: ValueKey<String>(widget.imageKey ?? _defaultRemoteImageKey),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      filterQuality: widget.filterQuality,
      loadingBuilder:
          (
            BuildContext context,
            Widget child,
            ImageChunkEvent? loadingProgress,
          ) {
            if (loadingProgress == null) {
              return child;
            }

            return _buildPlaceholder();
          },
      errorBuilder: (_, _, _) {
        final String? mediaAssetId = widget.attachment.mediaAssetId;

        if (mediaAssetId != null) {
          _resolvedAccessUrls.remove(mediaAssetId);
        }

        _resolvedAccessUrl = null;

        return _buildPlaceholder();
      },
    );
  }

  Widget _buildPlaceholder() {
    return _PhotoMessagePlaceholder(width: widget.width, height: widget.height);
  }

  String get _defaultImageKey {
    return 'photo-message-${widget.attachment.assetId}-${widget.itemIndex}';
  }

  String get _defaultRemoteImageKey {
    return 'photo-message-remote-'
        '${widget.attachment.mediaAssetId}-'
        '${widget.itemIndex}';
  }
}

final class _ResolvedPhotoAccessUrl {
  const _ResolvedPhotoAccessUrl({required this.url, required this.resolvedAt});

  final Uri url;
  final DateTime resolvedAt;
}

final class _PhotoMessagePlaceholder extends StatelessWidget {
  const _PhotoMessagePlaceholder({this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: const ColoredBox(
        color: AppColors.grey100,
        child: Center(
          child: Icon(Icons.image_outlined, color: AppColors.grey400, size: 28),
        ),
      ),
    );
  }
}

final class _PhotoViewerScreen extends StatefulWidget {
  const _PhotoViewerScreen({
    required this.attachments,
    required this.initialIndex,
    required this.senderName,
    required this.sentAt,
    required this.onCreateMediaAssetAccessUrl,
  });

  final List<ChatPhotoAttachment> attachments;
  final int initialIndex;
  final String senderName;
  final DateTime sentAt;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;

  @override
  State<_PhotoViewerScreen> createState() {
    return _PhotoViewerScreenState();
  }
}

final class _PhotoViewerScreenState extends State<_PhotoViewerScreen> {
  static const Duration _controlsAnimationDuration = Duration(
    milliseconds: 190,
  );

  static const Color _chromeBarColor = AppColors.black;

  static const Color _filmstripOverlayColor = Color(0x94000000);

  static const Color _thumbnailBorderColor = AppColors.blue500;

  static const double _topBarContentHeight = 72;

  static const double _actionBarContentHeight = 62;

  late final PageController _pageController;

  late final List<GlobalKey> _thumbnailKeys;

  late int _currentIndex;

  bool _controlsVisible = true;

  double _verticalDragDistance = 0;

  bool get _hasMultiplePhotos {
    return widget.attachments.length > 1;
  }

  ChatPhotoAttachment get _currentAttachment {
    return widget.attachments[_currentIndex];
  }

  @override
  void initState() {
    super.initState();

    _currentIndex = widget.initialIndex.clamp(0, widget.attachments.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    _thumbnailKeys = List<GlobalKey>.generate(
      widget.attachments.length,
      (int index) => GlobalKey(),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCurrentThumbnailIntoView();
      unawaited(_warmNearbyPhotos(_currentIndex));
    });
  }

  @override
  void dispose() {
    _pageController.dispose();

    super.dispose();
  }

  void _close() {
    Navigator.of(context).maybePop();
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
    });
  }

  void _handlePageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCurrentThumbnailIntoView();
    });

    unawaited(_warmNearbyPhotos(index));
  }

  Future<void> _warmNearbyPhotos(int centerIndex) async {
    final Set<int> indices = <int>{
      centerIndex,
      centerIndex - 1,
      centerIndex + 1,
    };

    for (final int index in indices) {
      if (index < 0 || index >= widget.attachments.length || !mounted) {
        continue;
      }

      await _warmPhoto(widget.attachments[index]);
    }
  }

  Future<void> _warmPhoto(ChatPhotoAttachment attachment) async {
    final ImageProvider imageProvider;
    final Uint8List? previewBytes = attachment.previewBytes;

    if (previewBytes != null) {
      return;
    } else {
      final String? mediaAssetId = attachment.mediaAssetId;
      final ChatMediaAssetAccessUrlCreator? createAccessUrl =
          widget.onCreateMediaAssetAccessUrl;

      if (mediaAssetId == null || createAccessUrl == null) {
        return;
      }

      try {
        final Uri accessUrl = await createAccessUrl(mediaAssetId: mediaAssetId);
        _PhotoMessageImageState.rememberAccessUrl(mediaAssetId, accessUrl);
        imageProvider = NetworkImage(accessUrl.toString());
      } catch (_) {
        return;
      }
    }

    if (!mounted) {
      return;
    }

    try {
      await precacheImage(imageProvider, context);
    } catch (_) {
      return;
    }
  }

  void _scrollCurrentThumbnailIntoView() {
    if (!_hasMultiplePhotos) {
      return;
    }

    final BuildContext? thumbnailContext =
        _thumbnailKeys[_currentIndex].currentContext;

    if (thumbnailContext == null) {
      return;
    }

    Scrollable.ensureVisible(
      thumbnailContext,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      alignment: 0.5,
    );
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    _verticalDragDistance = 0;
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    _verticalDragDistance += details.delta.dy;
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    final double velocity = details.primaryVelocity ?? 0;

    if (_verticalDragDistance.abs() > 82 || velocity.abs() > 650) {
      _close();
    }

    _verticalDragDistance = 0;
  }

  Future<void> _downloadCurrentPhoto() async {
    final ChatPhotoAttachment attachment = _currentAttachment;
    final int timestamp = DateTime.now().millisecondsSinceEpoch;

    try {
      Uint8List? imageBytes = attachment.previewBytes;

      if (imageBytes == null) {
        final String? mediaAssetId = attachment.mediaAssetId;
        final ChatMediaAssetAccessUrlCreator? createAccessUrl =
            widget.onCreateMediaAssetAccessUrl;

        if (mediaAssetId == null || createAccessUrl == null) {
          throw StateError('Photo bytes are not available.');
        }

        final Uri accessUrl = await createAccessUrl(mediaAssetId: mediaAssetId);
        final http.Response response = await http.get(accessUrl);

        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError('Photo download failed.');
        }

        imageBytes = response.bodyBytes;
      }

      await PhotoManager.editor.saveImage(
        imageBytes,
        filename: 'juliatalk-$timestamp.jpg',
        title: 'JuliaTalk Photo',
        creationDate: DateTime.now(),
      );

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Photo saved.')));
    } catch (_) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Photo could not be saved.')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle.light
        .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: AppColors.black,
          systemNavigationBarIconBrightness: Brightness.light,
        );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleControls,
          onVerticalDragStart: _handleVerticalDragStart,
          onVerticalDragUpdate: _handleVerticalDragUpdate,
          onVerticalDragEnd: _handleVerticalDragEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                key: const ValueKey<String>('photo-viewer-page-view'),
                controller: _pageController,
                itemCount: widget.attachments.length,
                onPageChanged: _handlePageChanged,
                itemBuilder: (BuildContext context, int index) {
                  return _PhotoViewerPage(
                    attachment: widget.attachments[index],
                    onCreateMediaAssetAccessUrl:
                        widget.onCreateMediaAssetAccessUrl,
                  );
                },
              ),
              _PhotoViewerTopBar(
                visible: _controlsVisible,
                senderName: widget.senderName,
                sentAt: widget.sentAt,
                onBackPressed: _close,
              ),
              _PhotoViewerBottomOverlay(
                visible: _controlsVisible,
                attachments: widget.attachments,
                currentIndex: _currentIndex,
                thumbnailKeys: _thumbnailKeys,
                onCreateMediaAssetAccessUrl: widget.onCreateMediaAssetAccessUrl,
                onThumbnailPressed: (int index) {
                  _pageController.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                  );
                },
                onDownloadPressed: () {
                  unawaited(_downloadCurrentPhoto());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _PhotoViewerPage extends StatelessWidget {
  const _PhotoViewerPage({
    required this.attachment,
    required this.onCreateMediaAssetAccessUrl,
  });

  final ChatPhotoAttachment attachment;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Center(
          child: _PhotoMessageImage(
            attachment: attachment,
            itemIndex: 0,
            onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
            imageKey: 'photo-viewer-image-${attachment.assetId}',
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            fit: _photoViewerFit(
              attachment: attachment,
              viewport: Size(constraints.maxWidth, constraints.maxHeight),
            ),
            filterQuality: FilterQuality.high,
          ),
        );
      },
    );
  }
}

final class _PhotoViewerTopBar extends StatelessWidget {
  const _PhotoViewerTopBar({
    required this.visible,
    required this.senderName,
    required this.sentAt,
    required this.onBackPressed,
  });

  final bool visible;
  final String senderName;
  final DateTime sentAt;
  final VoidCallback onBackPressed;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding = MediaQuery.paddingOf(context);

    return Positioned(
      left: 0,
      top: 0,
      right: 0,
      child: AnimatedSlide(
        key: const ValueKey<String>('photo-viewer-top-bar'),
        duration: _PhotoViewerScreenState._controlsAnimationDuration,
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -1),
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            duration: _PhotoViewerScreenState._controlsAnimationDuration,
            opacity: visible ? 1 : 0,
            child: Container(
              height:
                  padding.top + _PhotoViewerScreenState._topBarContentHeight,
              padding: EdgeInsets.only(top: padding.top),
              color: _PhotoViewerScreenState._chromeBarColor,
              child: Row(
                children: [
                  SizedBox(
                    width: 54,
                    height: 54,
                    child: IconButton(
                      key: const ValueKey<String>('photo-viewer-back'),
                      onPressed: onBackPressed,
                      icon: const Icon(
                        Icons.chevron_left_rounded,
                        color: AppColors.white,
                        size: 34,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          senderName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.subTypography10.copyWith(
                            color: AppColors.white,
                            fontWeight: AppTypography.bold,
                          ),
                        ),
                        const SizedBox(height: 0),
                        Text(
                          _formatPhotoViewerTimestamp(sentAt),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.subTypography11.copyWith(
                            color: AppColors.grey200,
                            fontWeight: AppTypography.regular,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 54, height: 54),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _PhotoViewerBottomOverlay extends StatelessWidget {
  const _PhotoViewerBottomOverlay({
    required this.visible,
    required this.attachments,
    required this.currentIndex,
    required this.thumbnailKeys,
    required this.onCreateMediaAssetAccessUrl,
    required this.onThumbnailPressed,
    required this.onDownloadPressed,
  });

  final bool visible;
  final List<ChatPhotoAttachment> attachments;
  final int currentIndex;
  final List<GlobalKey> thumbnailKeys;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ValueChanged<int> onThumbnailPressed;
  final VoidCallback onDownloadPressed;

  bool get _hasMultiplePhotos {
    return attachments.length > 1;
  }

  @override
  Widget build(BuildContext context) {
    final EdgeInsets padding = MediaQuery.paddingOf(context);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedSlide(
        key: const ValueKey<String>('photo-viewer-bottom-overlay'),
        duration: _PhotoViewerScreenState._controlsAnimationDuration,
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, 1),
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            duration: _PhotoViewerScreenState._controlsAnimationDuration,
            opacity: visible ? 1 : 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hasMultiplePhotos)
                  SizedBox(
                    width: double.infinity,
                    child: ColoredBox(
                      color: _PhotoViewerScreenState._filmstripOverlayColor,
                      child: _PhotoViewerThumbnailBar(
                        attachments: attachments,
                        currentIndex: currentIndex,
                        thumbnailKeys: thumbnailKeys,
                        onCreateMediaAssetAccessUrl:
                            onCreateMediaAssetAccessUrl,
                        onThumbnailPressed: onThumbnailPressed,
                      ),
                    ),
                  ),
                Container(
                  height:
                      _PhotoViewerScreenState._actionBarContentHeight +
                      padding.bottom,
                  padding: EdgeInsets.only(bottom: padding.bottom),
                  color: _PhotoViewerScreenState._chromeBarColor,
                  child: Center(
                    child: IconButton(
                      key: const ValueKey<String>('photo-viewer-download'),
                      onPressed: onDownloadPressed,
                      icon: const Icon(
                        Icons.file_download_outlined,
                        color: AppColors.white,
                        size: 31,
                      ),
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
}

final class _PhotoViewerThumbnailBar extends StatelessWidget {
  const _PhotoViewerThumbnailBar({
    required this.attachments,
    required this.currentIndex,
    required this.thumbnailKeys,
    required this.onCreateMediaAssetAccessUrl,
    required this.onThumbnailPressed,
  });

  final List<ChatPhotoAttachment> attachments;
  final int currentIndex;
  final List<GlobalKey> thumbnailKeys;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final ValueChanged<int> onThumbnailPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 56,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int index = 0; index < attachments.length; index++) ...[
                    _PhotoViewerThumbnail(
                      key: thumbnailKeys[index],
                      attachment: attachments[index],
                      selected: index == currentIndex,
                      onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
                      onPressed: () {
                        onThumbnailPressed(index);
                      },
                    ),
                    if (index != attachments.length - 1)
                      const SizedBox(width: 7),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            key: const ValueKey<String>('photo-viewer-counter'),
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.image_outlined,
                color: AppColors.white,
                size: 18,
              ),
              const SizedBox(width: 5),
              Text(
                'Number ${currentIndex + 1} out of ${attachments.length}',
                style: AppTypography.subTypography10.copyWith(
                  color: AppColors.white,
                  fontWeight: AppTypography.medium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _PhotoViewerThumbnail extends StatelessWidget {
  const _PhotoViewerThumbnail({
    required this.attachment,
    required this.selected,
    required this.onCreateMediaAssetAccessUrl,
    required this.onPressed,
    super.key,
  });

  final ChatPhotoAttachment attachment;
  final bool selected;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        width: 54,
        height: 54,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(7)),
          border: Border.all(
            color: selected
                ? _PhotoViewerScreenState._thumbnailBorderColor
                : Colors.transparent,
            width: selected ? 3 : 0,
          ),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          child: _PhotoMessageImage(
            attachment: attachment,
            itemIndex: 0,
            onCreateMediaAssetAccessUrl: onCreateMediaAssetAccessUrl,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}

BoxFit _photoViewerFit({
  required ChatPhotoAttachment attachment,
  required Size viewport,
}) {
  if (attachment.width <= 0 ||
      attachment.height <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return BoxFit.contain;
  }

  final double photoRatio = attachment.width / attachment.height;
  final double viewportRatio = viewport.width / viewport.height;
  final bool sameOrientation =
      (photoRatio >= 1 && viewportRatio >= 1) ||
      (photoRatio < 1 && viewportRatio < 1);
  final double ratioDelta = (math.log(photoRatio / viewportRatio)).abs();

  if (sameOrientation && ratioDelta < 0.45) {
    return BoxFit.cover;
  }

  return BoxFit.contain;
}

String _formatPhotoViewerTimestamp(DateTime date) {
  final DateTime local = date.toLocal();
  final int hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final String minute = local.minute.toString().padLeft(2, '0');
  final String period = local.hour < 12 ? 'AM' : 'PM';

  return '${_shortMonthName(local.month)} '
      '${local.day}, '
      '${local.year} at '
      '$hour:$minute $period';
}

String _shortMonthName(int month) {
  return switch (month) {
    DateTime.january => 'Jan',
    DateTime.february => 'Feb',
    DateTime.march => 'Mar',
    DateTime.april => 'Apr',
    DateTime.may => 'May',
    DateTime.june => 'Jun',
    DateTime.july => 'Jul',
    DateTime.august => 'Aug',
    DateTime.september => 'Sep',
    DateTime.october => 'Oct',
    DateTime.november => 'Nov',
    DateTime.december => 'Dec',
    _ => throw ArgumentError.value(
      month,
      'month',
      'Month must be between 1 and 12.',
    ),
  };
}

String _formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }

  final double kb = bytes / 1024;

  if (kb < 1024) {
    return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  }

  final double mb = kb / 1024;

  if (mb < 1024) {
    return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  }

  final double gb = mb / 1024;

  return '${gb.toStringAsFixed(1)} GB';
}

String _mimeTypeForFileName(String fileName) {
  final String lowerCase = fileName.toLowerCase();

  if (lowerCase.endsWith('.jpg') || lowerCase.endsWith('.jpeg')) {
    return 'image/jpeg';
  }

  if (lowerCase.endsWith('.png')) {
    return 'image/png';
  }

  if (lowerCase.endsWith('.heic')) {
    return 'image/heic';
  }

  if (lowerCase.endsWith('.webp')) {
    return 'image/webp';
  }

  if (lowerCase.endsWith('.mp4')) {
    return 'video/mp4';
  }

  if (lowerCase.endsWith('.mov')) {
    return 'video/quicktime';
  }

  if (lowerCase.endsWith('.m4a')) {
    return 'audio/mp4';
  }

  if (lowerCase.endsWith('.mp3')) {
    return 'audio/mpeg';
  }

  if (lowerCase.endsWith('.pdf')) {
    return 'application/pdf';
  }

  return 'application/octet-stream';
}

String _safeLocalFileName(String fileName) {
  final List<String> segments = fileName
      .split(RegExp(r'[/\\]'))
      .where((String segment) => segment.isNotEmpty)
      .toList(growable: false);
  final String sanitized = segments.isEmpty ? 'download.bin' : segments.last;

  return sanitized.trim().isEmpty ? 'download.bin' : sanitized.trim();
}

final class _CallMessagePresentation {
  const _CallMessagePresentation({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.showsDuration,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
  final bool showsDuration;
}

_CallMessagePresentation _callMessagePresentation(
  ChatCallAttachment attachment,
  bool isOutgoing,
) {
  if (!isOutgoing &&
      (attachment.outcome == ChatCallOutcome.cancelled ||
          attachment.outcome == ChatCallOutcome.noAnswer)) {
    return const _CallMessagePresentation(
      label: 'Missed Call',
      icon: Icons.phone_missed_rounded,
      iconColor: AppColors.red500,
      showsDuration: false,
    );
  }

  return switch (attachment.outcome) {
    ChatCallOutcome.started => const _CallMessagePresentation(
      label: 'Voice Call',
      icon: Icons.call_rounded,
      iconColor: AppColors.green500,
      showsDuration: false,
    ),
    ChatCallOutcome.ended => const _CallMessagePresentation(
      label: 'End voice call',
      icon: Icons.call_rounded,
      iconColor: AppColors.grey900,
      showsDuration: true,
    ),
    ChatCallOutcome.cancelled => const _CallMessagePresentation(
      label: 'Canceled',
      icon: Icons.phone_disabled_rounded,
      iconColor: AppColors.grey500,
      showsDuration: false,
    ),
    ChatCallOutcome.missed => const _CallMessagePresentation(
      label: 'Missed Call',
      icon: Icons.phone_missed_rounded,
      iconColor: AppColors.red500,
      showsDuration: false,
    ),
    ChatCallOutcome.noAnswer => const _CallMessagePresentation(
      label: 'No Answer',
      icon: Icons.phone_disabled_rounded,
      iconColor: AppColors.grey500,
      showsDuration: false,
    ),
  };
}

final class _CallMessageBubble extends StatelessWidget {
  const _CallMessageBubble({
    required this.messageId,
    required this.measurementKey,
    required this.attachment,
    required this.isOutgoing,
    required this.isHighlighted,
  });

  final String messageId;
  final Key measurementKey;
  final ChatCallAttachment attachment;
  final bool isOutgoing;
  final bool isHighlighted;

  @override
  Widget build(BuildContext context) {
    final _CallMessagePresentation presentation = _callMessagePresentation(
      attachment,
      isOutgoing,
    );
    final String? durationText = presentation.showsDuration
        ? _formatCallDuration(attachment.duration)
        : null;
    const double horizontalPadding = _messageHorizontalPadding;
    const double iconSize = 22;
    const double iconLabelGap = 10;
    final TextStyle callTextStyle = AppTypography.subTypography10.copyWith(
      color: AppColors.grey900,
      fontWeight: AppTypography.regular,
    );
    final StrutStyle callStrutStyle = _buildMessageStrutStyle(callTextStyle);
    Widget callText(String text) {
      return Text(
        key: ValueKey<String>('call-text-slot-$messageId-$text'),
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        strutStyle: callStrutStyle,
        style: callTextStyle,
        textHeightBehavior: _messageTextHeightBehavior,
      );
    }

    final Widget callLabel = durationText == null
        ? callText(presentation.label)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [callText(presentation.label), callText(durationText)],
          );

    return Transform.scale(
      key: ValueKey<String>('message-pulse-$messageId'),
      scale: 1,
      child: Stack(
        key: measurementKey,
        clipBehavior: Clip.none,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: const BorderRadius.all(Radius.circular(17)),
              border: Border.all(color: AppColors.grey100),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: 9,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    key: ValueKey<String>('call-icon-slot-$messageId'),
                    width: iconSize,
                    height: iconSize,
                    child: Icon(
                      presentation.icon,
                      size: iconSize,
                      color: presentation.iconColor,
                    ),
                  ),
                  const SizedBox(width: iconLabelGap),
                  callLabel,
                ],
              ),
            ),
          ),
          if (isHighlighted)
            Positioned.fill(
              child: IgnorePointer(
                child: SizedBox.expand(
                  key: ValueKey<String>('message-highlight-$messageId'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _VoiceMemoMessageBubble extends StatefulWidget {
  const _VoiceMemoMessageBubble({
    required this.messageId,
    required this.measurementKey,
    required this.attachment,
    required this.isHighlighted,
    required this.onCreateMediaAssetAccessUrl,
  });

  final String messageId;
  final Key measurementKey;
  final ChatVoiceMemoAttachment attachment;
  final bool isHighlighted;
  final ChatMediaAssetAccessUrlCreator? onCreateMediaAssetAccessUrl;

  @override
  State<_VoiceMemoMessageBubble> createState() {
    return _VoiceMemoMessageBubbleState();
  }
}

final class _VoiceMemoMessageBubbleState
    extends State<_VoiceMemoMessageBubble> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  Duration _playbackPosition = Duration.zero;
  Duration? _scrubPosition;
  bool _playing = false;
  bool _draggingWaveform = false;
  String? _cachedAudioPath;
  String? _loadedAudioPath;
  List<double> _waveformSamples = const <double>[];
  Future<String?>? _audioPathFuture;

  String get _waveformCacheKey {
    return _waveformCacheKeyFor(widget.attachment, widget.messageId);
  }

  Duration get _displayPlaybackPosition {
    return _scrubPosition ?? _playbackPosition;
  }

  double get _progress {
    final int durationMs = widget.attachment.duration.inMilliseconds;

    if (durationMs <= 0) {
      return 0;
    }

    return (_displayPlaybackPosition.inMilliseconds / durationMs)
        .clamp(0, 1)
        .toDouble();
  }

  @override
  void initState() {
    super.initState();

    _waveformSamples = _initialWaveformSamples();
    _playbackPosition = _initialPlaybackPosition();
    _activeVoiceMemoPlaybackMessageId.addListener(
      _handleActiveVoiceMemoPlaybackChanged,
    );
  }

  @override
  void didUpdateWidget(_VoiceMemoMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);

    final bool messageChanged = oldWidget.messageId != widget.messageId;
    final bool sourceChanged =
        messageChanged ||
        _voiceMemoAudioSourceChanged(oldWidget.attachment, widget.attachment);

    if (messageChanged) {
      _cachePlaybackPosition(
        _playbackPosition,
        cacheKey: _waveformCacheKeyFor(
          oldWidget.attachment,
          oldWidget.messageId,
        ),
        duration: oldWidget.attachment.duration,
      );

      if (_activeVoiceMemoPlaybackMessageId.value == oldWidget.messageId) {
        _activeVoiceMemoPlaybackMessageId.value = null;
      }
      unawaited(_stopPlayerSilently());
      _playing = false;
      _cachedAudioPath = null;
      _loadedAudioPath = null;
      _audioPathFuture = null;
      _waveformSamples = _initialWaveformSamples();
      _playbackPosition = _initialPlaybackPosition();
      _scrubPosition = null;
      _draggingWaveform = false;
    } else {
      _syncWaveformSamplesFromAttachment(clearExisting: sourceChanged);
    }

    if (sourceChanged) {
      if (!messageChanged) {
        unawaited(_stopPlayback(resetPosition: true));
      }
      _cachedAudioPath = null;
      _loadedAudioPath = null;
      _audioPathFuture = null;
    } else if (oldWidget.onCreateMediaAssetAccessUrl !=
        widget.onCreateMediaAssetAccessUrl) {
      _audioPathFuture = null;
    }
  }

  @override
  void dispose() {
    _activeVoiceMemoPlaybackMessageId.removeListener(
      _handleActiveVoiceMemoPlaybackChanged,
    );
    if (_activeVoiceMemoPlaybackMessageId.value == widget.messageId) {
      _activeVoiceMemoPlaybackMessageId.value = null;
    }
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _cachePlaybackPosition(_currentPlaybackPositionForCaching());
    unawaited(_player?.dispose());
    super.dispose();
  }

  String _waveformCacheKeyFor(
    ChatVoiceMemoAttachment attachment,
    String messageId,
  ) {
    return attachment.mediaAssetId ?? attachment.localPath ?? messageId;
  }

  void _handleActiveVoiceMemoPlaybackChanged() {
    if (!mounted || !_playing) {
      return;
    }

    if (_activeVoiceMemoPlaybackMessageId.value == widget.messageId) {
      return;
    }

    unawaited(
      _pausePlayback(resetPosition: false, clearActivePlaybackId: false),
    );
  }

  List<double> _initialWaveformSamples() {
    final List<double> attachmentSamples = widget.attachment.waveformSamples;

    if (attachmentSamples.isNotEmpty) {
      _cacheWaveformSamples(attachmentSamples);
      return attachmentSamples;
    }

    final List<double>? cachedSamples =
        _voiceMemoWaveformSamplesByCacheKey[_waveformCacheKey];

    if (cachedSamples != null && cachedSamples.isNotEmpty) {
      return cachedSamples;
    }

    return const <double>[];
  }

  Duration _initialPlaybackPosition() {
    final Duration? cachedPosition =
        _voiceMemoPlaybackPositionsByCacheKey[_waveformCacheKey];

    if (cachedPosition == null) {
      return Duration.zero;
    }

    return _clampedPlaybackPosition(cachedPosition);
  }

  bool _voiceMemoAudioSourceChanged(
    ChatVoiceMemoAttachment previous,
    ChatVoiceMemoAttachment current,
  ) {
    return previous.duration != current.duration ||
        previous.mediaAssetId != current.mediaAssetId ||
        previous.localPath != current.localPath ||
        previous.sizeBytes != current.sizeBytes ||
        previous.audioBytes?.length != current.audioBytes?.length;
  }

  void _syncWaveformSamplesFromAttachment({required bool clearExisting}) {
    final List<double> attachmentSamples = widget.attachment.waveformSamples;

    if (attachmentSamples.isNotEmpty) {
      _cacheWaveformSamples(attachmentSamples);
      _waveformSamples = attachmentSamples;
      return;
    }

    final List<double>? cachedSamples =
        _voiceMemoWaveformSamplesByCacheKey[_waveformCacheKey];

    if (cachedSamples != null && cachedSamples.isNotEmpty) {
      _waveformSamples = cachedSamples;
      return;
    }

    if (clearExisting) {
      _waveformSamples = const <double>[];
    }
  }

  void _cacheWaveformSamples(List<double> samples) {
    if (samples.isEmpty) {
      return;
    }

    if (_voiceMemoWaveformSamplesByCacheKey.length > 240) {
      _voiceMemoWaveformSamplesByCacheKey.remove(
        _voiceMemoWaveformSamplesByCacheKey.keys.first,
      );
    }

    _voiceMemoWaveformSamplesByCacheKey[_waveformCacheKey] =
        List<double>.unmodifiable(samples);
  }

  void _cachePlaybackPosition(
    Duration position, {
    String? cacheKey,
    Duration? duration,
  }) {
    final String resolvedCacheKey = cacheKey ?? _waveformCacheKey;
    final Duration clampedPosition = _clampedPlaybackPosition(
      position,
      duration: duration,
    );

    if (clampedPosition <= Duration.zero ||
        clampedPosition >= (duration ?? widget.attachment.duration)) {
      _voiceMemoPlaybackPositionsByCacheKey.remove(resolvedCacheKey);
      return;
    }

    if (_voiceMemoPlaybackPositionsByCacheKey.length > 240) {
      _voiceMemoPlaybackPositionsByCacheKey.remove(
        _voiceMemoPlaybackPositionsByCacheKey.keys.first,
      );
    }

    _voiceMemoPlaybackPositionsByCacheKey[resolvedCacheKey] = clampedPosition;
  }

  Future<AudioPlayer> _ensurePlayer() async {
    final AudioPlayer existingPlayer;

    if (_player case final AudioPlayer player) {
      existingPlayer = player;
    } else {
      existingPlayer = AudioPlayer();
      await existingPlayer.setLoopMode(LoopMode.off);
      _player = existingPlayer;

      _positionSubscription = existingPlayer.positionStream.listen((
        Duration position,
      ) {
        if (!mounted ||
            !_playing ||
            _activeVoiceMemoPlaybackMessageId.value != widget.messageId) {
          return;
        }

        final Duration clampedPosition = _clampedPlaybackPosition(position);
        _cachePlaybackPosition(clampedPosition);

        setState(() {
          _playbackPosition = clampedPosition;
        });
      });

      _playerStateSubscription = existingPlayer.playerStateStream.listen((
        PlayerState state,
      ) {
        if (!mounted ||
            !_playing ||
            _activeVoiceMemoPlaybackMessageId.value != widget.messageId ||
            state.processingState != ProcessingState.completed) {
          return;
        }

        setState(() {
          _playing = false;
          _playbackPosition = Duration.zero;
          _scrubPosition = null;
          _draggingWaveform = false;
        });
        _cachePlaybackPosition(Duration.zero);
        if (_activeVoiceMemoPlaybackMessageId.value == widget.messageId) {
          _activeVoiceMemoPlaybackMessageId.value = null;
        }
        unawaited(_finishCompletedPlayback(existingPlayer));
      });
    }

    return existingPlayer;
  }

  Future<String?> _audioPathForPlayback() async {
    final Future<String?>? existingFuture = _audioPathFuture;

    if (existingFuture != null) {
      return existingFuture;
    }

    _audioPathFuture = _resolveAudioPathForPlayback();

    return _audioPathFuture;
  }

  Future<String?> _resolveAudioPathForPlayback() async {
    final String? localPath = widget.attachment.localPath;

    if (localPath != null && await File(localPath).exists()) {
      return localPath;
    }

    final String? cachedAudioPath = _cachedAudioPath;

    if (cachedAudioPath != null && await File(cachedAudioPath).exists()) {
      return cachedAudioPath;
    }

    final Uint8List? audioBytes = widget.attachment.audioBytes;

    if (audioBytes != null && audioBytes.isNotEmpty) {
      final Directory temporaryDirectory = await getTemporaryDirectory();
      final File audioFile = File(
        '${temporaryDirectory.path}/juliatalk_voice_${widget.messageId}.m4a',
      );

      await audioFile.writeAsBytes(audioBytes, flush: true);
      _cachedAudioPath = audioFile.path;

      return audioFile.path;
    }

    return _downloadRemoteAudioToCache();
  }

  Future<String?> _downloadRemoteAudioToCache() async {
    final String? mediaAssetId = widget.attachment.mediaAssetId;
    final ChatMediaAssetAccessUrlCreator? createAccessUrl =
        widget.onCreateMediaAssetAccessUrl;

    if (mediaAssetId == null || createAccessUrl == null) {
      return null;
    }

    final Uri audioUri;

    try {
      audioUri = await createAccessUrl(mediaAssetId: mediaAssetId);
    } catch (_) {
      _audioPathFuture = null;
      return null;
    }

    try {
      final http.Response response = await http.get(audioUri);

      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.isEmpty) {
        _audioPathFuture = null;
        return null;
      }

      final Directory temporaryDirectory = await getTemporaryDirectory();
      final File audioFile = File(
        '${temporaryDirectory.path}/juliatalk_voice_'
        '${_safeVoiceMemoCacheKey(mediaAssetId)}.m4a',
      );

      await audioFile.writeAsBytes(response.bodyBytes, flush: true);
      _cachedAudioPath = audioFile.path;

      return audioFile.path;
    } catch (_) {
      _audioPathFuture = null;
      return null;
    }
  }

  Future<void> _finishCompletedPlayback(AudioPlayer player) async {
    try {
      await player.pause();
      await player.seek(Duration.zero);
    } catch (_) {
      return;
    }
  }

  Future<void> _stopPlayerSilently() async {
    final AudioPlayer? player = _player;

    if (player == null) {
      return;
    }

    try {
      await player.stop();
    } catch (_) {
      return;
    } finally {
      _loadedAudioPath = null;
    }
  }

  Duration _clampedPlaybackPosition(Duration position, {Duration? duration}) {
    if (position <= Duration.zero) {
      return Duration.zero;
    }

    final Duration resolvedDuration = duration ?? widget.attachment.duration;

    if (resolvedDuration <= Duration.zero || position >= resolvedDuration) {
      return resolvedDuration;
    }

    return position;
  }

  bool get _hasPausedPlaybackPosition {
    return _playbackPosition > Duration.zero &&
        _playbackPosition < widget.attachment.duration;
  }

  Duration _currentPlaybackPositionForCaching() {
    final AudioPlayer? player = _player;

    if (player == null) {
      return _clampedPlaybackPosition(_playbackPosition);
    }

    final Duration playerPosition = _clampedPlaybackPosition(player.position);

    if (playerPosition > Duration.zero &&
        playerPosition < widget.attachment.duration) {
      return playerPosition;
    }

    return _clampedPlaybackPosition(_playbackPosition);
  }

  Duration _waveformPositionFromLocalDx(double localDx, double width) {
    final Duration duration = widget.attachment.duration;

    if (duration <= Duration.zero || width <= 0) {
      return Duration.zero;
    }

    final double progress = (localDx / width).clamp(0, 1).toDouble();

    return _clampedPlaybackPosition(
      Duration(microseconds: (duration.inMicroseconds * progress).round()),
    );
  }

  void _beginWaveformScrub(Offset localPosition, double width) {
    final Duration targetPosition = _waveformPositionFromLocalDx(
      localPosition.dx,
      width,
    );

    setState(() {
      _scrubPosition = targetPosition;
    });
  }

  void _updateWaveformScrub(Offset localPosition, double width) {
    final Duration targetPosition = _waveformPositionFromLocalDx(
      localPosition.dx,
      width,
    );

    if (_scrubPosition == targetPosition) {
      return;
    }

    setState(() {
      _scrubPosition = targetPosition;
    });
  }

  void _cancelWaveformScrub() {
    if (!mounted) {
      return;
    }

    setState(() {
      _scrubPosition = null;
      _draggingWaveform = false;
    });
  }

  Future<void> _commitWaveformScrub() async {
    final Duration? targetPosition = _scrubPosition;

    if (targetPosition == null) {
      _cancelWaveformScrub();
      return;
    }

    final Duration clampedPosition = _clampedPlaybackPosition(targetPosition);
    Duration resolvedPosition = clampedPosition;
    final AudioPlayer? player = _player;

    if (player != null && _loadedAudioPath != null) {
      try {
        await player.seek(clampedPosition);
      } catch (_) {
        resolvedPosition = _currentPlaybackPositionForCaching();
      }
    }

    if (mounted) {
      setState(() {
        _playbackPosition = resolvedPosition;
        _scrubPosition = null;
        _draggingWaveform = false;
      });
    }
    _cachePlaybackPosition(resolvedPosition);
  }

  Future<void> _pausePlayback({
    required bool resetPosition,
    required bool clearActivePlaybackId,
  }) async {
    final AudioPlayer? player = _player;
    final Duration pausedPosition = _currentPlaybackPositionForCaching();

    if (player != null) {
      await player.pause();
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _playing = false;
      _scrubPosition = null;
      _draggingWaveform = false;
      if (resetPosition) {
        _playbackPosition = Duration.zero;
      } else {
        _playbackPosition = pausedPosition;
      }
    });
    _cachePlaybackPosition(resetPosition ? Duration.zero : pausedPosition);

    if (clearActivePlaybackId &&
        _activeVoiceMemoPlaybackMessageId.value == widget.messageId) {
      _activeVoiceMemoPlaybackMessageId.value = null;
    }
  }

  Future<void> _stopPlayback({required bool resetPosition}) async {
    final AudioPlayer? player = _player;

    if (player != null) {
      await player.stop();
    }
    _loadedAudioPath = null;

    if (!mounted) {
      return;
    }

    setState(() {
      _playing = false;
      _scrubPosition = null;
      _draggingWaveform = false;
      if (resetPosition) {
        _playbackPosition = Duration.zero;
      }
    });
    if (resetPosition) {
      _cachePlaybackPosition(Duration.zero);
    } else {
      _cachePlaybackPosition(_currentPlaybackPositionForCaching());
    }

    if (_activeVoiceMemoPlaybackMessageId.value == widget.messageId) {
      _activeVoiceMemoPlaybackMessageId.value = null;
    }
  }

  Future<void> _togglePlayback() async {
    if (_playing) {
      await _pausePlayback(resetPosition: false, clearActivePlaybackId: true);
      return;
    }

    _activeVoiceMemoPlaybackMessageId.value = widget.messageId;

    final String? audioPath = await _audioPathForPlayback();

    if (audioPath == null) {
      if (_activeVoiceMemoPlaybackMessageId.value == widget.messageId) {
        _activeVoiceMemoPlaybackMessageId.value = null;
      }
      return;
    }

    if (!mounted ||
        _activeVoiceMemoPlaybackMessageId.value != widget.messageId) {
      return;
    }

    final AudioPlayer player = await _ensurePlayer();

    try {
      if (_activeVoiceMemoPlaybackMessageId.value != widget.messageId) {
        return;
      }

      final Duration startPosition = _hasPausedPlaybackPosition
          ? _playbackPosition
          : Duration.zero;

      if (_loadedAudioPath != audioPath) {
        await player.stop();
        await player.setLoopMode(LoopMode.off);
        await player.setUrl(Uri.file(audioPath).toString());
        _loadedAudioPath = audioPath;
      } else {
        await player.pause();
        await player.setLoopMode(LoopMode.off);
      }

      await player.seek(startPosition);

      if (!mounted ||
          _activeVoiceMemoPlaybackMessageId.value != widget.messageId) {
        return;
      }

      setState(() {
        _playing = true;
        _playbackPosition = startPosition;
      });
      _cachePlaybackPosition(startPosition);

      unawaited(player.play());
    } catch (_) {
      _cachedAudioPath = null;
      _audioPathFuture = null;
      await _stopPlayback(resetPosition: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final double width = _voiceMemoMessageBubbleWidth(context);
    final Duration displayPlaybackPosition = _displayPlaybackPosition;
    final bool canPlay =
        widget.attachment.localPath != null ||
        (widget.attachment.audioBytes?.isNotEmpty ?? false) ||
        (widget.attachment.mediaAssetId != null &&
            widget.onCreateMediaAssetAccessUrl != null);
    final bool canScrub = canPlay && widget.attachment.duration > Duration.zero;

    return Transform.scale(
      key: ValueKey<String>('message-pulse-${widget.messageId}'),
      scale: 1,
      child: Stack(
        key: widget.measurementKey,
        children: [
          SizedBox(
            width: width,
            height: 56,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: const BorderRadius.all(Radius.circular(15)),
                border: Border.all(color: AppColors.grey100),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 40,
                      child: Material(
                        color: AppColors.grey50,
                        shape: const CircleBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: canPlay ? _togglePlayback : null,
                          child: Icon(
                            _playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 30,
                            color: canPlay
                                ? AppColors.grey900
                                : AppColors.grey300,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final double scrubWidth = constraints.maxWidth;

                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapDown: canScrub
                                ? (details) {
                                    _draggingWaveform = false;
                                    _beginWaveformScrub(
                                      details.localPosition,
                                      scrubWidth,
                                    );
                                  }
                                : null,
                            onTapUp: canScrub
                                ? (details) {
                                    _updateWaveformScrub(
                                      details.localPosition,
                                      scrubWidth,
                                    );
                                    unawaited(_commitWaveformScrub());
                                  }
                                : null,
                            onTapCancel: canScrub
                                ? () {
                                    if (!_draggingWaveform) {
                                      _cancelWaveformScrub();
                                    }
                                  }
                                : null,
                            onHorizontalDragStart: canScrub
                                ? (details) {
                                    _draggingWaveform = true;
                                    _beginWaveformScrub(
                                      details.localPosition,
                                      scrubWidth,
                                    );
                                  }
                                : null,
                            onHorizontalDragUpdate: canScrub
                                ? (details) {
                                    _updateWaveformScrub(
                                      details.localPosition,
                                      scrubWidth,
                                    );
                                  }
                                : null,
                            onHorizontalDragEnd: canScrub
                                ? (_) {
                                    unawaited(_commitWaveformScrub());
                                  }
                                : null,
                            onHorizontalDragCancel: canScrub
                                ? _cancelWaveformScrub
                                : null,
                            child: SizedBox(
                              height: 22,
                              child: _VoiceMemoWaveform(
                                color: AppColors.grey300,
                                playedColor: AppColors.grey900,
                                samples: _waveformSamples,
                                progress: _progress,
                                showProgress:
                                    displayPlaybackPosition > Duration.zero &&
                                    widget.attachment.duration > Duration.zero,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _formatVoiceMemoBubbleDuration(
                        widget.attachment.duration,
                      ),
                      style: AppTypography.subTypography10.copyWith(
                        color: AppColors.grey900,
                        fontWeight: AppTypography.medium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.isHighlighted)
            Positioned.fill(
              child: IgnorePointer(
                child: SizedBox.expand(
                  key: ValueKey<String>(
                    'message-highlight-${widget.messageId}',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _FileMessageContent extends StatelessWidget {
  const _FileMessageContent({
    required this.attachment,
    required this.isOutgoing,
  });

  final ChatFileAttachment attachment;
  final bool isOutgoing;

  @override
  Widget build(BuildContext context) {
    final Color iconBackgroundColor = isOutgoing
        ? AppColors.white.withAlpha(38)
        : AppColors.blue50;
    final Color iconColor = isOutgoing ? AppColors.white : AppColors.blue500;
    final Color titleColor = isOutgoing ? AppColors.white : AppColors.grey900;
    final Color metadataColor = isOutgoing
        ? AppColors.white.withAlpha(200)
        : AppColors.grey500;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 224),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: iconBackgroundColor,
              borderRadius: AppRadius.borderRadius8,
            ),
            child: Icon(
              Icons.insert_drive_file_rounded,
              size: 21,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  attachment.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.typography6.copyWith(
                    color: titleColor,
                    fontWeight: AppTypography.medium,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _formatFileSize(attachment.sizeBytes),
                  style: AppTypography.subTypography12.copyWith(
                    color: metadataColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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

  final String messageId;
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
                    top: 6,
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
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      child: SizedBox.square(
        dimension: 36,
        child: Icon(Icons.person_rounded, color: AppColors.white, size: 22),
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
    required this.onCallPressed,
    required this.onFilePressed,
    required this.onVoiceMemoPressed,
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
  final VoidCallback onCallPressed;
  final VoidCallback onFilePressed;
  final VoidCallback onVoiceMemoPressed;
  final VoidCallback onClosePhotoPicker;
  final ChatPhotoSendCallback onSendPhotos;

  final GestureDragStartCallback onPhotoPickerDragStart;

  final GestureDragUpdateCallback onPhotoPickerDragUpdate;

  final GestureDragEndCallback onPhotoPickerDragEnd;

  @override
  Widget build(BuildContext context) {
    late final Key surfaceKey;
    late final Widget surface;

    if (showPhotoPicker) {
      surfaceKey = const ValueKey<String>('photo-picker-visible');

      surface = ChatPhotoPicker(
        photoLibrary: photoLibrary,
        expanded: photoPickerExpanded,
        onClose: onClosePhotoPicker,
        onSend: onSendPhotos,
        onHandleDragStart: onPhotoPickerDragStart,
        onHandleDragUpdate: onPhotoPickerDragUpdate,
        onHandleDragEnd: onPhotoPickerDragEnd,
      );
    } else if (showAttachmentPanel) {
      surfaceKey = const ValueKey<String>('attachment-panel-visible');

      surface = _ChatAttachmentPanel(
        onPhotoPressed: onPhotoPressed,
        onCameraPressed: onCameraPressed,
        onCallPressed: onCallPressed,
        onFilePressed: onFilePressed,
        onVoiceMemoPressed: onVoiceMemoPressed,
      );
    } else {
      surfaceKey = const ValueKey<String>('attachment-panel-hidden');

      surface = const SizedBox.shrink();
    }

    return AnimatedContainer(
      key: const ValueKey<String>('composer-bottom-surface'),
      width: double.infinity,
      height: height,
      duration: animateHeight ? _bottomSurfaceAnimationDuration : Duration.zero,
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(color: AppColors.white),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 140),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,

        // AnimatedSwitcher의 기본 Stack은 자식에게
        // 느슨한 가로 제약을 줄 수 있다.
        // 모든 하단 패널을 부모 너비와 높이에 강제로 맞춘다.
        layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[...previousChildren, ?currentChild],
          );
        },

        transitionBuilder: (Widget child, Animation<double> animation) {
          final Animation<Offset> position =
              Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );

          return FadeTransition(
            opacity: animation,
            child: SlideTransition(position: position, child: child),
          );
        },

        child: SizedBox.expand(key: surfaceKey, child: surface),
      ),
    );
  }
}

final class _ChatAttachmentPanel extends StatelessWidget {
  const _ChatAttachmentPanel({
    required this.onPhotoPressed,
    required this.onCameraPressed,
    required this.onCallPressed,
    required this.onFilePressed,
    required this.onVoiceMemoPressed,
  });

  final VoidCallback onPhotoPressed;
  final VoidCallback onCameraPressed;
  final VoidCallback onCallPressed;
  final VoidCallback onFilePressed;
  final VoidCallback onVoiceMemoPressed;

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
      foregroundColor: AppColors.grey700,
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
              case 'call':
                onPressed = onCallPressed;
              case 'file':
                onPressed = onFilePressed;
              case 'voice-memo':
                onPressed = onVoiceMemoPressed;
              default:
                onPressed = () {};
            }

            return _AttachmentPanelAction(action: action, onPressed: onPressed);
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
    required this.onVoiceMemoPressed,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey inputHostKey;
  final ChatMessage? replyingToMessage;
  final String? replyingToContent;
  final ChatMessage? editingMessage;
  final String? editingOriginalContent;
  final String currentUserId;
  final String otherParticipantName;
  final bool attachmentPanelOpen;

  final VoidCallback onCancelReply;
  final VoidCallback onCancelEdit;
  final VoidCallback onSend;
  final VoidCallback onSaveEdit;
  final ValueChanged<String> onTextChanged;
  final VoidCallback onToggleAttachmentPanel;
  final VoidCallback onInputTap;
  final VoidCallback onVoiceMemoPressed;

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
                            onPressed: onVoiceMemoPressed,
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
