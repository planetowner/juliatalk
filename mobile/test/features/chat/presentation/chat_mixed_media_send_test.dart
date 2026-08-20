import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/data/chat_photo_library.dart';
import 'package:juliatalk/features/chat/data/chat_video_transcoder.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  'CAYAAAAfFcSJAAAADUlEQVR42mNk+M/w'
  'HwAEAQH/2p3KAAAAAElFTkSuQmCC',
);

final class _MixedMediaLibrary implements ChatPhotoLibrary {
  static const List<ChatPhotoAsset> assets = <ChatPhotoAsset>[
    ChatPhotoAsset(
      id: 'video-0',
      width: 1080,
      height: 1920,
      type: ChatPhotoAssetType.video,
      duration: Duration(seconds: 14),
    ),
    ChatPhotoAsset(
      id: 'video-1',
      width: 1920,
      height: 1080,
      type: ChatPhotoAssetType.video,
      duration: Duration(seconds: 28),
    ),
    ChatPhotoAsset(id: 'photo-0', width: 1200, height: 900),
    ChatPhotoAsset(id: 'photo-1', width: 900, height: 1200),
  ];

  @override
  Future<ChatPhotoAccessState> requestAccess() async {
    return ChatPhotoAccessState.authorized;
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    return const <ChatPhotoAlbum>[
      ChatPhotoAlbum(
        id: 'all',
        name: 'Recents',
        assetCount: 4,
        isAll: true,
        coverAssetId: 'video-0',
      ),
    ];
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    if (page > 0) {
      return const <ChatPhotoAsset>[];
    }

    return assets;
  }

  @override
  Future<Uint8List?> loadThumbnail({
    required String assetId,
    required int width,
    required int height,
  }) async {
    return _testPng;
  }

  @override
  Future<Uint8List?> loadMessagePreview({required String assetId}) async {
    return _testPng;
  }

  @override
  Future<ChatPhotoFile?> loadOriginalFile({required String assetId}) async {
    final bool isVideo = assetId.startsWith('video-');

    return ChatPhotoFile(
      bytes: _testPng,
      fileName: isVideo ? '$assetId.mp4' : '$assetId.png',
      mimeType: isVideo ? 'video/mp4' : 'image/png',
      sizeBytes: _testPng.length,
    );
  }

  @override
  Future<void> openSettings() async {}
}

final class _IdentityVideoTranscoder implements ChatVideoTranscoder {
  const _IdentityVideoTranscoder();

  @override
  Future<ChatVideoTranscodeResult> transcode({
    required ChatPhotoFile source,
    required int width,
    required int height,
    required Duration duration,
  }) async {
    return ChatVideoTranscodeResult(
      fileName: source.fileName,
      mimeType: source.mimeType,
      sizeBytes: source.sizeBytes,
      width: width,
      height: height,
      duration: duration,
      localPath: source.localPath,
      uploadBytes: source.bytes,
    );
  }
}

Future<void> _tapMediaAsset(WidgetTester tester, String assetId) async {
  final Finder tileFinder = find.byKey(ValueKey<String>('photo-tile-$assetId'));
  final Finder gridFinder = find.byKey(const ValueKey<String>('photo-grid'));
  final Finder gridScrollableFinder = find.descendant(
    of: gridFinder,
    matching: find.byType(Scrollable),
  );

  for (int attempt = 0; attempt < 30; attempt++) {
    if (tileFinder.evaluate().isEmpty) {
      await tester.drag(gridScrollableFinder, const Offset(0, -160));
      await tester.pumpAndSettle();
      continue;
    }

    final Rect gridRect = tester.getRect(gridFinder);
    final Rect tileRect = tester.getRect(tileFinder);
    final double safeTop = gridRect.top + 8;
    final double safeBottom = gridRect.bottom - 8;

    if (tileRect.center.dy < safeTop) {
      await tester.drag(gridScrollableFinder, const Offset(0, 120));
      await tester.pumpAndSettle();
      continue;
    }

    if (tileRect.center.dy > safeBottom) {
      await tester.drag(gridScrollableFinder, const Offset(0, -120));
      await tester.pumpAndSettle();
      continue;
    }

    await tester.tapAt(tileRect.center);
    await tester.pump();
    return;
  }

  throw TestFailure(
    'Could not bring media asset "$assetId" into the tappable grid viewport.',
  );
}

ChatMessage _sentPhotoMessage(
  List<ChatPhotoAttachment> attachments,
  DateTime createdAt,
) {
  return ChatMessage(
    id: 'sent-photos',
    senderId: '1',
    recipientId: '2',
    content: '',
    createdAt: createdAt,
    photoAttachments: attachments,
  );
}

ChatMessage _sentVideoMessage(
  ChatVideoAttachment attachment,
  DateTime createdAt,
) {
  return ChatMessage(
    id: 'sent-${attachment.assetId}',
    senderId: '1',
    recipientId: '2',
    content: '',
    createdAt: createdAt,
    videoAttachment: attachment,
  );
}

void _expectMixedMediaOrder(WidgetTester tester) {
  final double photoTop = tester
      .getTopLeft(
        find.byKey(const ValueKey<String>('outgoing-bubble-photo-photo-1')),
      )
      .dy;
  final double firstVideoTop = tester
      .getTopLeft(
        find.byKey(const ValueKey<String>('outgoing-bubble-video-video-1')),
      )
      .dy;
  final double secondVideoTop = tester
      .getTopLeft(
        find.byKey(const ValueKey<String>('outgoing-bubble-video-video-0')),
      )
      .dy;

  expect(photoTop, lessThan(firstVideoTop));
  expect(firstVideoTop, lessThan(secondVideoTop));
}

void main() {
  testWidgets(
    'mixed media sends photos first and videos sequentially by selection order',
    (WidgetTester tester) async {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (
        MethodCall call,
      ) async {
        return null;
      });
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() async {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.binding.setSurfaceSize(null);
      });

      final Completer<List<ChatMessage>> photoCompleter =
          Completer<List<ChatMessage>>();
      final Map<String, Completer<ChatMessage>> videoCompleters =
          <String, Completer<ChatMessage>>{};
      final Map<String, ChatVideoAttachment> sentVideoAttachments =
          <String, ChatVideoAttachment>{};
      final Map<String, DateTime> sentVideoCreatedAts = <String, DateTime>{};
      final List<String> sendOrder = <String>[];
      late List<ChatPhotoAttachment> sentPhotoAttachments;
      late List<DateTime> sentPhotoCreatedAts;

      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            photoLibrary: _MixedMediaLibrary(),
            videoTranscoder: const _IdentityVideoTranscoder(),
            initialMessages: const <ChatMessage>[],
            onSendPhotoMessages:
                ({
                  required List<ChatPhotoAttachment> attachments,
                  required bool collage,
                  required List<DateTime> createdAts,
                  ChatReplyReference? replyTo,
                  ChatPhotoUploadProgressCallback? onUploadProgress,
                }) {
                  expect(collage, isTrue);
                  sentPhotoAttachments = attachments;
                  sentPhotoCreatedAts = createdAts;
                  sendOrder.add(
                    'photos:${attachments.map((attachment) => attachment.assetId).join(',')}',
                  );
                  return photoCompleter.future;
                },
            onSendVideoMessage:
                ({
                  required ChatVideoAttachment attachment,
                  required DateTime createdAt,
                  ChatReplyReference? replyTo,
                  ChatVideoUploadProgressCallback? onUploadProgress,
                }) {
                  sendOrder.add('video:${attachment.assetId}');
                  sentVideoAttachments[attachment.assetId] = attachment;
                  sentVideoCreatedAts[attachment.assetId] = createdAt;
                  final Completer<ChatMessage> completer =
                      Completer<ChatMessage>();
                  videoCompleters[attachment.assetId] = completer;
                  return completer.future;
                },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('message-attachment')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(
        find.byKey(const ValueKey<String>('attachment-action-photo')),
      );
      await tester.pumpAndSettle();

      await _tapMediaAsset(tester, 'video-1');
      await _tapMediaAsset(tester, 'video-0');
      await _tapMediaAsset(tester, 'photo-1');
      await _tapMediaAsset(tester, 'photo-0');
      await tester.tap(find.byKey(const ValueKey<String>('photo-picker-send')));
      await tester.pump();
      await tester.pump();

      expect(sendOrder, <String>['photos:photo-1,photo-0']);
      expect(videoCompleters, isEmpty);
      _expectMixedMediaOrder(tester);

      photoCompleter.complete(<ChatMessage>[
        _sentPhotoMessage(sentPhotoAttachments, sentPhotoCreatedAts.single),
      ]);
      await tester.pump();
      await tester.pump();

      expect(sendOrder, <String>['photos:photo-1,photo-0', 'video:video-1']);
      expect(videoCompleters.containsKey('video-0'), isFalse);
      _expectMixedMediaOrder(tester);

      videoCompleters['video-1']!.complete(
        _sentVideoMessage(
          sentVideoAttachments['video-1']!,
          sentVideoCreatedAts['video-1']!,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(sendOrder, <String>[
        'photos:photo-1,photo-0',
        'video:video-1',
        'video:video-0',
      ]);
      _expectMixedMediaOrder(tester);

      videoCompleters['video-0']!.complete(
        _sentVideoMessage(
          sentVideoAttachments['video-0']!,
          sentVideoCreatedAts['video-0']!,
        ),
      );
      await tester.pump();
      _expectMixedMediaOrder(tester);
    },
  );
}
