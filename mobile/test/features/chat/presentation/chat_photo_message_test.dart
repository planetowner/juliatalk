import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAABmJLR0QA'
  '/wD/AP+gvaeTAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAB3RJTUUH5gMQ'
  'FwcdLl4wmwAAAAtJREFUCNdjYAACAAAFAAHiJgWbAAAAAElFTkSuQmCC',
);

Widget _buildPhotoMessageScreen(
  ChatMessage message, {
  double? topPadding,
  String currentUserName = 'Me',
  String otherParticipantName = 'Lia',
  int unreadOtherConversationCount = 0,
  VoidCallback? onBack,
}) {
  return MaterialApp(
    builder: topPadding == null
        ? null
        : (BuildContext context, Widget? child) {
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: EdgeInsets.only(top: topPadding)),
              child: child!,
            );
          },
    home: ChatConversationView(
      initialMessages: <ChatMessage>[message],
      currentUserName: currentUserName,
      otherParticipantName: otherParticipantName,
      unreadOtherConversationCount: unreadOtherConversationCount,
      onBack: onBack,
    ),
  );
}

ChatMessage _photoMessage({
  required String senderId,
  required String recipientId,
  int attachmentCount = 1,
  bool photoUploadPending = false,
  int? photoUploadedBytes,
  int? photoUploadTotalBytes,
}) {
  return ChatMessage(
    id: '1',
    senderId: senderId,
    recipientId: recipientId,
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    photoUploadPending: photoUploadPending,
    photoUploadedBytes: photoUploadedBytes,
    photoUploadTotalBytes: photoUploadTotalBytes,
    photoAttachments: List<ChatPhotoAttachment>.generate(
      attachmentCount,
      (int index) => ChatPhotoAttachment(
        assetId: 'photo-preview-$index',
        previewBytes: _testPng,
        width: 1200,
        height: 900,
      ),
    ),
  );
}

Finder _photoFinder(int index) {
  return find.byKey(
    ValueKey<String>('photo-message-photo-preview-$index-$index'),
  );
}

Rect _photoRect(WidgetTester tester, int index) {
  return tester.getRect(_photoFinder(index));
}

const MethodChannel _pathProviderChannel = MethodChannel(
  'plugins.flutter.io/path_provider',
);

Directory _setUpPhotoCacheDirectory(String prefix) {
  final Directory cacheDirectory = Directory.systemTemp.createTempSync(prefix);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProviderChannel, (MethodCall call) async {
        if (call.method == 'getApplicationCacheDirectory') {
          return cacheDirectory.path;
        }

        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (cacheDirectory.existsSync()) {
      cacheDirectory.deleteSync(recursive: true);
    }
  });
  return cacheDirectory;
}

final class _IncomingPhotoHarness extends StatefulWidget {
  const _IncomingPhotoHarness({super.key});

  @override
  State<_IncomingPhotoHarness> createState() {
    return _IncomingPhotoHarnessState();
  }
}

final class _IncomingPhotoHarnessState extends State<_IncomingPhotoHarness> {
  List<ChatMessage> _messages = <ChatMessage>[
    ChatMessage(
      id: 'outgoing-text',
      senderId: '1',
      recipientId: '2',
      content: 'Before photo',
      createdAt: DateTime(2026, 7, 1, 12, 51),
    ),
  ];

  void addIncomingPhoto() {
    setState(() {
      _messages = <ChatMessage>[
        ..._messages,
        ChatMessage(
          id: 'incoming-photo',
          senderId: '2',
          recipientId: '1',
          content: '',
          createdAt: DateTime(2026, 7, 1, 12, 52),
          photoAttachments: <ChatPhotoAttachment>[
            ChatPhotoAttachment(
              assetId: 'incoming-preview',
              previewBytes: _testPng,
              width: 1200,
              height: 900,
            ),
          ],
        ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatConversationView(initialMessages: _messages);
  }
}

final class _PhotoRefreshHarness extends StatefulWidget {
  const _PhotoRefreshHarness({
    this.completedMediaAssetId = 'refreshed-photo-media',
    super.key,
  });

  final String completedMediaAssetId;

  @override
  State<_PhotoRefreshHarness> createState() => _PhotoRefreshHarnessState();
}

final class _PhotoRefreshHarnessState extends State<_PhotoRefreshHarness> {
  final Uint8List completedPreviewBytes = Uint8List.fromList(_testPng);
  final Uint8List serverPreviewBytes = Uint8List.fromList(_testPng);

  ChatMessage _message = ChatMessage(
    id: 'refreshed-photo-message',
    senderId: '1',
    recipientId: '2',
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    photoUploadPending: true,
    photoAttachments: <ChatPhotoAttachment>[
      ChatPhotoAttachment(
        assetId: 'refreshed-photo',
        previewBytes: _testPng,
        width: 1179,
        height: 2556,
      ),
    ],
  );

  void completeWithLocalPreview() {
    setState(() {
      _message = ChatMessage(
        id: 'refreshed-photo-message',
        senderId: '1',
        recipientId: '2',
        content: '',
        createdAt: DateTime(2026, 7, 1, 12, 52),
        photoAttachments: <ChatPhotoAttachment>[
          ChatPhotoAttachment(
            assetId: 'refreshed-photo',
            mediaAssetId: widget.completedMediaAssetId,
            previewBytes: completedPreviewBytes,
            width: 1179,
            height: 2556,
          ),
        ],
      );
    });
  }

  void replaceWithServerMessage() {
    setState(() {
      _message = ChatMessage(
        id: 'refreshed-photo-message',
        senderId: '1',
        recipientId: '2',
        content: '',
        createdAt: DateTime(2026, 7, 1, 12, 52),
        photoAttachments: <ChatPhotoAttachment>[
          ChatPhotoAttachment(
            assetId: 'server-photo',
            mediaAssetId: widget.completedMediaAssetId,
            previewBytes: serverPreviewBytes,
            width: 1179,
            height: 2556,
          ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatConversationView(
      initialMessages: <ChatMessage>[_message],
      onCreatePhotoThumbnailAccessUrl: ({required String mediaAssetId}) {
        return Completer<Uri>().future;
      },
    );
  }
}

final class _PhotoMessageIdentityHarness extends StatefulWidget {
  const _PhotoMessageIdentityHarness({super.key});

  @override
  State<_PhotoMessageIdentityHarness> createState() {
    return _PhotoMessageIdentityHarnessState();
  }
}

final class _PhotoMessageIdentityHarnessState
    extends State<_PhotoMessageIdentityHarness> {
  ChatMessage _message = ChatMessage(
    id: 'local-photo-message',
    senderId: '1',
    recipientId: '2',
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    photoAttachments: <ChatPhotoAttachment>[
      ChatPhotoAttachment(
        assetId: 'stable-photo-preview',
        previewBytes: _testPng,
        width: 1200,
        height: 900,
      ),
    ],
  );

  void replaceWithServerMessage() {
    setState(() {
      _message = ChatMessage(
        id: 'server-photo-message',
        senderId: '1',
        recipientId: '2',
        content: '',
        createdAt: DateTime(2026, 7, 1, 12, 52),
        photoAttachments: <ChatPhotoAttachment>[
          ChatPhotoAttachment(
            assetId: 'stable-photo-preview',
            previewBytes: _testPng,
            width: 1200,
            height: 900,
          ),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatConversationView(initialMessages: <ChatMessage>[_message]);
  }
}

void main() {
  testWidgets(
    'photo element stays mounted when the server id replaces the local id',
    (WidgetTester tester) async {
      final GlobalKey<_PhotoMessageIdentityHarnessState> harnessKey =
          GlobalKey<_PhotoMessageIdentityHarnessState>();

      await tester.pumpWidget(
        MaterialApp(home: _PhotoMessageIdentityHarness(key: harnessKey)),
      );
      await tester.pumpAndSettle();

      const ValueKey<String> photoKey = ValueKey<String>(
        'photo-message-stable-photo-preview-0',
      );
      final Element photoElementBeforeCompletion = tester.element(
        find.byKey(photoKey),
      );

      harnessKey.currentState!.replaceWithServerMessage();
      await tester.pump();

      expect(
        tester.element(find.byKey(photoKey)),
        photoElementBeforeCompletion,
      );
    },
  );

  testWidgets('new incoming photo row fades in at its final position', (
    WidgetTester tester,
  ) async {
    final GlobalKey<_IncomingPhotoHarnessState> harnessKey =
        GlobalKey<_IncomingPhotoHarnessState>();

    await tester.pumpWidget(
      MaterialApp(home: _IncomingPhotoHarness(key: harnessKey)),
    );
    await tester.pumpAndSettle();

    harnessKey.currentState!.addIncomingPhoto();
    await tester.pump();

    final Finder revealFinder = find.byKey(
      const ValueKey<String>('incoming-photo-reveal-incoming-photo'),
    );
    final Finder fadeFinder = find.descendant(
      of: revealFinder,
      matching: find.byType(FadeTransition),
    );

    expect(revealFinder, findsOneWidget);
    expect(
      tester.widget<FadeTransition>(fadeFinder).opacity.value,
      lessThan(1),
    );

    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.widget<FadeTransition>(fadeFinder).opacity.value, 1);
  });

  testWidgets('remote photos wait on a plain white placeholder', (
    WidgetTester tester,
  ) async {
    final Completer<Uri> accessUrl = Completer<Uri>();
    final ChatMessage message = ChatMessage(
      id: 'remote-photo',
      senderId: '2',
      recipientId: '1',
      content: '',
      createdAt: DateTime(2026, 7, 1, 12, 52),
      photoAttachments: const <ChatPhotoAttachment>[
        ChatPhotoAttachment(
          assetId: 'remote-photo',
          mediaAssetId: 'remote-photo',
          width: 1200,
          height: 900,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChatConversationView(
          initialMessages: <ChatMessage>[message],
          onCreatePhotoThumbnailAccessUrl: ({required String mediaAssetId}) {
            return accessUrl.future;
          },
        ),
      ),
    );
    await tester.pump();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-remote-photo'),
    );

    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byIcon(Icons.image_outlined),
      ),
      findsNothing,
    );
  });

  testWidgets('cached remote photos are prepared without a reveal fade', (
    WidgetTester tester,
  ) async {
    final Directory cacheDirectory = _setUpPhotoCacheDirectory(
      'juliatalk-photo-cache-test-',
    );

    const String mediaAssetId = 'cached-route-photo';
    final Directory photoDirectory = Directory(
      '${cacheDirectory.path}/chat-photo-thumbnails',
    );
    photoDirectory.createSync(recursive: true);
    File('${photoDirectory.path}/$mediaAssetId.jpg').writeAsBytesSync(_testPng);

    final ChatConversationViewController controller =
        ChatConversationViewController();
    final ChatMessage message = ChatMessage(
      id: 'cached-remote-photo',
      senderId: '2',
      recipientId: '1',
      content: '',
      createdAt: DateTime(2026, 7, 1, 12, 52),
      photoAttachments: const <ChatPhotoAttachment>[
        ChatPhotoAttachment(
          assetId: 'cached-remote-photo',
          mediaAssetId: mediaAssetId,
          width: 1200,
          height: 900,
        ),
      ],
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            controller: controller,
            initialMessages: <ChatMessage>[message],
            onCreatePhotoThumbnailAccessUrl:
                ({required String mediaAssetId}) async {
                  throw StateError(
                    'Cached photos must not request the network.',
                  );
                },
          ),
        ),
      );
      await tester.pump();

      await tester.pumpAndSettle();
      await controller.prepareInitialCachedPhotos();
      await tester.pump();
    });

    final Finder imageFinder = find.byKey(
      const ValueKey<String>('photo-message-remote-cached-route-photo-0'),
    );
    expect(imageFinder, findsOneWidget);
    final Image cachedImage = tester.widget<Image>(imageFinder);
    final ResizeImage resizedImage = cachedImage.image as ResizeImage;
    expect(resizedImage.width, isNotNull);
    expect(resizedImage.height, isNull);
    expect(
      find.ancestor(of: imageFinder, matching: find.byType(AnimatedOpacity)),
      findsNothing,
    );
  });

  testWidgets('visible photo messages start original prefetch before a tap', (
    WidgetTester tester,
  ) async {
    _setUpPhotoCacheDirectory('juliatalk-photo-original-prefetch-test-');

    final Completer<Uri> originalAccessUrl = Completer<Uri>();
    int originalAccessUrlRequests = 0;
    final ChatMessage message = ChatMessage(
      id: 'original-prefetch-message',
      senderId: '2',
      recipientId: '1',
      content: '',
      createdAt: DateTime(2026, 7, 1, 12, 52),
      photoAttachments: <ChatPhotoAttachment>[
        ChatPhotoAttachment(
          assetId: 'original-prefetch-photo',
          mediaAssetId: 'original-prefetch-media',
          previewBytes: _testPng,
          width: 1200,
          height: 900,
        ),
      ],
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            initialMessages: <ChatMessage>[message],
            onCreateMediaAssetAccessUrl: ({required String mediaAssetId}) {
              originalAccessUrlRequests++;
              return originalAccessUrl.future;
            },
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    expect(originalAccessUrlRequests, 1);
    expect(
      find.byKey(
        const ValueKey<String>('photo-viewer-image-original-prefetch-photo'),
      ),
      findsNothing,
    );
  });

  testWidgets('photo viewer reuses a prefetched original file', (
    WidgetTester tester,
  ) async {
    final Directory cacheDirectory = _setUpPhotoCacheDirectory(
      'juliatalk-photo-original-cache-test-',
    );

    const String mediaAssetId = 'prefetched-original-media';
    final Directory originalDirectory = Directory(
      '${cacheDirectory.path}/chat-photo-originals',
    );
    originalDirectory.createSync(recursive: true);
    final File originalFile = File(
      '${originalDirectory.path}/$mediaAssetId.image',
    )..writeAsBytesSync(_testPng);
    int originalAccessUrlRequests = 0;
    final ChatMessage message = ChatMessage(
      id: 'prefetched-original-message',
      senderId: '2',
      recipientId: '1',
      content: '',
      createdAt: DateTime(2026, 7, 1, 12, 52),
      photoAttachments: <ChatPhotoAttachment>[
        ChatPhotoAttachment(
          assetId: 'prefetched-original-photo',
          mediaAssetId: mediaAssetId,
          previewBytes: _testPng,
          width: 1200,
          height: 900,
        ),
      ],
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            initialMessages: <ChatMessage>[message],
            onCreateMediaAssetAccessUrl:
                ({required String mediaAssetId}) async {
                  originalAccessUrlRequests++;
                  throw StateError('The prefetched original must be reused.');
                },
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
    });

    await tester.tap(
      find.byKey(
        const ValueKey<String>('photo-message-prefetched-original-photo-0'),
      ),
    );
    await tester.pumpAndSettle();

    final Image originalImage = tester.widget<Image>(
      find.byKey(
        const ValueKey<String>(
          'photo-viewer-original-prefetched-original-photo',
        ),
      ),
    );
    final ResizeImage resizedImage = originalImage.image as ResizeImage;
    final FileImage fileImage = resizedImage.imageProvider as FileImage;

    expect(fileImage.file.path, originalFile.path);
    expect(originalAccessUrlRequests, 0);
  });

  testWidgets('photo viewer keeps the cached thumbnail while original loads', (
    WidgetTester tester,
  ) async {
    final Directory cacheDirectory = _setUpPhotoCacheDirectory(
      'juliatalk-photo-viewer-thumbnail-test-',
    );

    const String mediaAssetId = 'viewer-thumbnail-media';
    final Directory thumbnailDirectory = Directory(
      '${cacheDirectory.path}/chat-photo-thumbnails',
    );
    thumbnailDirectory.createSync(recursive: true);
    final File thumbnailFile = File(
      '${thumbnailDirectory.path}/$mediaAssetId.jpg',
    )..writeAsBytesSync(_testPng);
    final Completer<Uri> originalAccessUrl = Completer<Uri>();
    final ChatMessage message = ChatMessage(
      id: 'viewer-thumbnail-message',
      senderId: '2',
      recipientId: '1',
      content: '',
      createdAt: DateTime(2026, 7, 1, 12, 52),
      photoAttachments: const <ChatPhotoAttachment>[
        ChatPhotoAttachment(
          assetId: 'viewer-thumbnail-photo',
          mediaAssetId: mediaAssetId,
          width: 1200,
          height: 900,
        ),
      ],
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatConversationView(
            initialMessages: <ChatMessage>[message],
            onCreateMediaAssetAccessUrl: ({required String mediaAssetId}) {
              return originalAccessUrl.future;
            },
            onCreatePhotoThumbnailAccessUrl:
                ({required String mediaAssetId}) async {
                  throw StateError('The cached thumbnail must be reused.');
                },
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
    });

    await tester.tap(
      find.byKey(
        const ValueKey<String>('photo-message-remote-$mediaAssetId-0'),
      ),
    );
    await tester.pumpAndSettle();

    final Finder viewer = find.byKey(
      const ValueKey<String>('photo-viewer-image-viewer-thumbnail-photo'),
    );
    final Image thumbnailImage = tester.widget<Image>(
      find.descendant(of: viewer, matching: find.byType(Image)),
    );
    final ResizeImage resizedImage = thumbnailImage.image as ResizeImage;
    final FileImage fileImage = resizedImage.imageProvider as FileImage;
    final ColoredBox viewerPlaceholder = tester.widget<ColoredBox>(
      find.descendant(of: viewer, matching: find.byType(ColoredBox)).first,
    );

    expect(fileImage.file.path, thumbnailFile.path);
    expect(viewerPlaceholder.color, const Color(0xFF202020));
    expect(
      find.byKey(
        const ValueKey<String>('photo-viewer-original-viewer-thumbnail-photo'),
      ),
      findsNothing,
    );
  });

  testWidgets('a sent photo keeps its element while upgrading its preview', (
    WidgetTester tester,
  ) async {
    final GlobalKey<_PhotoRefreshHarnessState> harnessKey =
        GlobalKey<_PhotoRefreshHarnessState>();

    await tester.pumpWidget(
      MaterialApp(home: _PhotoRefreshHarness(key: harnessKey)),
    );
    await tester.pump();

    const ValueKey<String> previewKey = ValueKey<String>(
      'photo-message-refreshed-photo-0',
    );
    expect(find.byKey(previewKey), findsOneWidget);
    final Element initialImageElement = tester.element(find.byKey(previewKey));
    expect(
      identical(
        (tester.widget<Image>(find.byKey(previewKey)).image as MemoryImage)
            .bytes,
        _testPng,
      ),
      isTrue,
    );

    harnessKey.currentState!.completeWithLocalPreview();
    await tester.pump();

    expect(find.byKey(previewKey), findsOneWidget);
    expect(
      identical(tester.element(find.byKey(previewKey)), initialImageElement),
      isTrue,
    );
    expect(
      identical(
        (tester.widget<Image>(find.byKey(previewKey)).image as MemoryImage)
            .bytes,
        harnessKey.currentState!.completedPreviewBytes,
      ),
      isTrue,
    );

    harnessKey.currentState!.replaceWithServerMessage();
    await tester.pump();

    expect(find.byKey(previewKey), findsOneWidget);
    expect(
      identical(tester.element(find.byKey(previewKey)), initialImageElement),
      isTrue,
    );
    expect(
      identical(
        (tester.widget<Image>(find.byKey(previewKey)).image as MemoryImage)
            .bytes,
        harnessKey.currentState!.serverPreviewBytes,
      ),
      isTrue,
    );
  });

  testWidgets('a completed sent photo persists its local preview', (
    WidgetTester tester,
  ) async {
    const String mediaAssetId = 'persisted-sent-photo-media';
    final Directory cacheDirectory = _setUpPhotoCacheDirectory(
      'juliatalk-sent-photo-preview-cache-test-',
    );
    final GlobalKey<_PhotoRefreshHarnessState> harnessKey =
        GlobalKey<_PhotoRefreshHarnessState>();
    final File cachedPreview = File(
      '${cacheDirectory.path}/chat-photo-thumbnails/'
      '$mediaAssetId.jpg',
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: _PhotoRefreshHarness(
            key: harnessKey,
            completedMediaAssetId: mediaAssetId,
          ),
        ),
      );
      await tester.pump();

      harnessKey.currentState!.completeWithLocalPreview();
      await tester.pump();

      for (
        int attempt = 0;
        attempt < 20 && !cachedPreview.existsSync();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    expect(cachedPreview.existsSync(), isTrue);
    expect(cachedPreview.readAsBytesSync(), _testPng);
  });

  testWidgets('incoming photo messages render as incoming media bubbles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '2', recipientId: '1')),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('incoming-bubble-1'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(
          const ValueKey<String>('photo-message-photo-preview-0-0'),
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(const ValueKey<String>('original-message-1')),
      ),
      findsNothing,
    );

    await tester.tap(bubbleFinder);
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('outgoing photo messages keep the outgoing media bubble key', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pumpAndSettle();

    final Finder bubbleFinder = find.byKey(
      const ValueKey<String>('outgoing-bubble-photo-photo-preview-0'),
    );

    expect(bubbleFinder, findsOneWidget);
    expect(
      find.descendant(
        of: bubbleFinder,
        matching: find.byKey(
          const ValueKey<String>('photo-message-photo-preview-0-0'),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('outgoing photo upload progress follows message state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(
          senderId: '1',
          recipientId: '2',
          photoUploadPending: true,
          photoUploadedBytes: 0,
          photoUploadTotalBytes: 998000,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey<String>('photo-upload-progress-photo-photo-preview-0'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('photo-upload-image-icon')),
      findsOneWidget,
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('photo-upload-image-icon')),
      ),
      const Size.square(15),
    );
    expect(find.text('0 / 998 KB'), findsOneWidget);

    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(
          senderId: '1',
          recipientId: '2',
          photoUploadPending: true,
          photoUploadedBytes: 524288,
          photoUploadTotalBytes: 1200000,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('0.5 / 1.2 MB'), findsOneWidget);
    final CircularProgressIndicator progressIndicator = tester.widget(
      find.byType(CircularProgressIndicator),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey<String>('photo-upload-progress-circle')),
      ),
      const Size.square(32),
    );
    expect(progressIndicator.strokeWidth, 2.2);
    expect(progressIndicator.backgroundColor, Colors.transparent);
    final Text progressText = tester.widget<Text>(find.text('0.5 / 1.2 MB'));
    expect(progressText.style?.fontSize, 13);

    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(
          senderId: '1',
          recipientId: '2',
          photoUploadPending: true,
          photoUploadedBytes: 1200000,
          photoUploadTotalBytes: 1200000,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('photo-upload-image-icon')),
      findsOneWidget,
    );
    expect(find.text('1.2 / 1.2 MB'), findsNothing);

    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey<String>('photo-upload-progress-photo-photo-preview-0'),
      ),
      findsNothing,
    );
  });

  testWidgets('chat top bar matches the photo viewer back-button position', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(senderId: '1', recipientId: '2'),
        topPadding: 59,
        otherParticipantName: 'june',
        unreadOtherConversationCount: 67,
        onBack: () {},
      ),
    );
    await tester.pumpAndSettle();

    final Finder chatTopBar = find.byKey(
      const ValueKey<String>('chat-top-bar'),
    );
    final Finder chatBackButton = find.byKey(
      const ValueKey<String>('chat-back-button'),
    );
    final Finder chatBackGroup = find.byKey(
      const ValueKey<String>('chat-back-group'),
    );
    final Finder chatActionsGroup = find.byKey(
      const ValueKey<String>('chat-actions-group'),
    );
    final Finder searchButton = find.byKey(
      const ValueKey<String>('chat-search-button'),
    );
    final Finder callButton = find.byKey(
      const ValueKey<String>('chat-call-button'),
    );
    final Finder participantName = find.byKey(
      const ValueKey<String>('chat-participant-name'),
    );
    final Rect chatBackButtonRect = tester.getRect(chatBackButton);
    final Rect chatBackGroupRect = tester.getRect(chatBackGroup);
    final Rect chatActionsGroupRect = tester.getRect(chatActionsGroup);
    final Container backGroupSurface = tester.widget<Container>(
      find.descendant(of: chatBackGroup, matching: find.byType(Container)),
    );
    final BoxDecoration backGroupDecoration =
        backGroupSurface.decoration! as BoxDecoration;
    final Border backGroupBorder = backGroupDecoration.border! as Border;
    final BorderRadius backGroupRadius =
        backGroupDecoration.borderRadius! as BorderRadius;
    final Text participantNameText = tester.widget<Text>(participantName);
    final Icon searchIcon = tester.widget<Icon>(
      find.byKey(const ValueKey<String>('chat-search-icon')),
    );
    final Icon callIcon = tester.widget<Icon>(
      find.byKey(const ValueKey<String>('chat-call-icon')),
    );

    expect(tester.getSize(chatTopBar), const Size(393, 115));
    expect(chatBackButtonRect, const Rect.fromLTWH(16, 59, 44, 44));
    expect(chatBackGroupRect.left, 16);
    expect(chatBackGroupRect.top, 59);
    expect(chatBackGroupRect.width, closeTo(72, 2));
    expect(chatBackGroupRect.height, 44);
    expect(chatActionsGroupRect, const Rect.fromLTWH(289, 59, 88, 44));
    expect(tester.getCenter(searchButton), const Offset(313, 81));
    expect(tester.getCenter(callButton), const Offset(353, 81));
    expect(tester.getCenter(participantName), const Offset(196.5, 81));
    expect(backGroupDecoration.color, Colors.white);
    expect(backGroupDecoration.shape, BoxShape.rectangle);
    expect(backGroupRadius.topLeft.x, 22);
    expect(backGroupBorder.top.color, const Color(0xFFE5E8EB));
    expect(backGroupBorder.top.width, 0.67);
    expect(participantNameText.style?.fontSize, 18);
    expect(participantNameText.style?.fontWeight, FontWeight.w700);
    expect(participantNameText.style?.color, const Color(0xFF191919));
    expect(searchIcon.size, 25);
    expect(searchIcon.color, const Color(0xFF1B3243));
    expect(callIcon.size, 25);
    expect(callIcon.color, const Color(0xFF1B3243));
    expect(find.text('67'), findsOneWidget);

    await tester.tap(_photoFinder(0));
    await tester.pumpAndSettle();

    final Rect photoViewerBackButtonRect = tester.getRect(
      find.byKey(const ValueKey<String>('photo-viewer-back')),
    );

    expect(photoViewerBackButtonRect, chatBackButtonRect);
  });

  testWidgets('tapping a photo opens the full-screen photo viewer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(senderId: '1', recipientId: '2'),
        topPadding: 59,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_photoFinder(0));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-viewer-image-photo-preview-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-back')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-download')),
      findsOneWidget,
    );
    final Finder backButton = find.byKey(
      const ValueKey<String>('photo-viewer-back'),
    );
    final Finder downloadButton = find.byKey(
      const ValueKey<String>('photo-viewer-download'),
    );
    final Finder topBar = find.byKey(
      const ValueKey<String>('photo-viewer-top-bar'),
    );
    final Finder pageView = find.byKey(
      const ValueKey<String>('photo-viewer-page-view'),
    );
    final Finder bottomOverlay = find.byKey(
      const ValueKey<String>('photo-viewer-bottom-overlay'),
    );
    final Finder info = find.byKey(const ValueKey<String>('photo-viewer-info'));
    final Finder senderName = find.byKey(
      const ValueKey<String>('photo-viewer-sender-name'),
    );
    final Finder timestamp = find.byKey(
      const ValueKey<String>('photo-viewer-timestamp'),
    );
    final Finder timestampChevron = find.byKey(
      const ValueKey<String>('photo-viewer-timestamp-chevron'),
    );
    final Scaffold photoViewerScaffold = tester
        .widgetList<Scaffold>(find.byType(Scaffold))
        .last;
    final Finder backButtonSurface = find.descendant(
      of: backButton,
      matching: find.byType(Container),
    );
    final BoxDecoration backButtonDecoration =
        tester.widget<Container>(backButtonSurface).decoration!
            as BoxDecoration;
    final Border backButtonBorder = backButtonDecoration.border! as Border;
    final Rect topBarRect = tester.getRect(topBar);
    final Rect pageViewRect = tester.getRect(pageView);
    final Rect bottomOverlayRect = tester.getRect(bottomOverlay);
    final Rect photoViewerScaffoldRect = tester.getRect(
      find.byWidget(photoViewerScaffold),
    );
    final Rect backButtonRect = tester.getRect(backButton);
    final Rect downloadButtonRect = tester.getRect(downloadButton);
    final Text senderNameText = tester.widget<Text>(senderName);
    final Text timestampText = tester.widget<Text>(timestamp);

    expect(photoViewerScaffold.backgroundColor, const Color(0xFF202020));
    expect(tester.getSize(backButton), const Size.square(44));
    expect(tester.getSize(downloadButton), const Size.square(48));
    expect(backButtonDecoration.color, const Color(0xFF272727));
    expect(backButtonDecoration.shape, BoxShape.circle);
    expect(backButtonBorder.top.color, const Color(0xFF4E4E4E));
    expect(backButtonBorder.top.width, 0.67);
    expect(topBarRect.height, 59 + 44 + 23);
    expect(backButtonRect.top - topBarRect.top, 59);
    expect(topBarRect.bottom - backButtonRect.bottom, 23);
    expect(pageViewRect.top, photoViewerScaffoldRect.top);
    expect(pageViewRect.bottom, photoViewerScaffoldRect.bottom);
    expect(pageViewRect.center, photoViewerScaffoldRect.center);
    expect(bottomOverlayRect.height, 23 + 48 + 23);
    expect(bottomOverlayRect.bottom, photoViewerScaffoldRect.bottom);
    expect(downloadButtonRect.top - bottomOverlayRect.top, 23);
    expect(bottomOverlayRect.bottom - downloadButtonRect.bottom, 23);
    expect(tester.getCenter(info).dy, tester.getCenter(backButton).dy);
    expect(tester.getCenter(senderName).dx, topBarRect.center.dx);
    expect(tester.getCenter(timestamp).dx, topBarRect.center.dx);
    expect(senderNameText.style?.fontSize, 15);
    expect(senderNameText.style?.fontWeight, FontWeight.w700);
    expect(senderNameText.style?.height, 18 / 15);
    expect(senderNameText.style?.color, const Color(0xFFF2F2F2));
    expect(timestampText.style?.fontSize, 13);
    expect(timestampText.style?.fontWeight, FontWeight.w400);
    expect(timestampText.style?.height, 16 / 13);
    expect(timestampText.style?.color, const Color(0xFFF2F2F2));
    expect(timestampChevron, findsNothing);
    expect(find.text('Me'), findsOneWidget);
    expect(find.text('Jul 1, 2026 at 12:52 PM'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-counter')),
      findsNothing,
    );

    await tester.tap(backButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-viewer-image-photo-preview-0')),
      findsNothing,
    );
  });

  testWidgets('photo viewer shows the sender name for the current viewer', (
    WidgetTester tester,
  ) async {
    Future<void> expectSenderName({
      required String senderId,
      required String recipientId,
      required String currentUserName,
      required String otherParticipantName,
      required String expectedSenderName,
    }) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _buildPhotoMessageScreen(
          _photoMessage(senderId: senderId, recipientId: recipientId),
          currentUserName: currentUserName,
          otherParticipantName: otherParticipantName,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_photoFinder(0));
      await tester.pumpAndSettle();

      final Text senderName = tester.widget<Text>(
        find.byKey(const ValueKey<String>('photo-viewer-sender-name')),
      );

      expect(senderName.data, expectedSenderName);
    }

    await expectSenderName(
      senderId: '1',
      recipientId: '2',
      currentUserName: 'June',
      otherParticipantName: '오빠💙',
      expectedSenderName: 'June',
    );
    await expectSenderName(
      senderId: '2',
      recipientId: '1',
      currentUserName: 'Lia',
      otherParticipantName: '애기🤍',
      expectedSenderName: '애기🤍',
    );
  });

  testWidgets(
    'multi-photo viewer starts from tapped photo and swipes forward',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _buildPhotoMessageScreen(
          _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 3),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_photoFinder(1));
      await tester.pumpAndSettle();

      expect(find.text('Number 2 out of 3'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('photo-viewer-image-photo-preview-1'),
        ),
        findsOneWidget,
      );

      await tester.drag(
        find.byKey(const ValueKey<String>('photo-viewer-page-view')),
        const Offset(-420, 0),
      );
      await tester.pumpAndSettle();

      expect(find.text('Number 3 out of 3'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey<String>('photo-viewer-image-photo-preview-2'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('photo viewer toggles controls and dismisses on vertical swipe', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
    );
    await tester.pumpAndSettle();

    await tester.tap(_photoFinder(0));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-viewer-image-photo-preview-0')),
    );
    await tester.pumpAndSettle();

    final AnimatedSlide hiddenTopBar = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey<String>('photo-viewer-top-bar')),
    );
    final AnimatedSlide hiddenBottomOverlay = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey<String>('photo-viewer-bottom-overlay')),
    );

    expect(hiddenTopBar.offset, const Offset(0, -1));
    expect(hiddenBottomOverlay.offset, const Offset(0, 1));

    await tester.drag(
      find.byKey(const ValueKey<String>('photo-viewer-page-view')),
      const Offset(0, -260),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-viewer-download')),
      findsNothing,
    );
  });

  testWidgets(
    'visible photo bars shield taps and hidden bars reveal anywhere',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _buildPhotoMessageScreen(
          _photoMessage(senderId: '1', recipientId: '2'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_photoFinder(0));
      await tester.pumpAndSettle();

      final Finder topBarFinder = find.byKey(
        const ValueKey<String>('photo-viewer-top-bar'),
      );
      final Finder bottomOverlayFinder = find.byKey(
        const ValueKey<String>('photo-viewer-bottom-overlay'),
      );
      final Rect topBarRect = tester.getRect(topBarFinder);
      final Rect bottomOverlayRect = tester.getRect(bottomOverlayFinder);

      await tester.tapAt(Offset(topBarRect.right - 8, topBarRect.center.dy));
      await tester.pump();
      await tester.tapAt(
        Offset(bottomOverlayRect.left + 8, bottomOverlayRect.center.dy),
      );
      await tester.pump();

      expect(tester.widget<AnimatedSlide>(topBarFinder).offset, Offset.zero);
      expect(
        tester.widget<AnimatedSlide>(bottomOverlayFinder).offset,
        Offset.zero,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('photo-viewer-page-view')),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<AnimatedSlide>(topBarFinder).offset,
        const Offset(0, -1),
      );
      expect(
        tester.widget<AnimatedSlide>(bottomOverlayFinder).offset,
        const Offset(0, 1),
      );

      await tester.tapAt(
        Offset(bottomOverlayRect.left + 8, bottomOverlayRect.center.dy),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<AnimatedSlide>(topBarFinder).offset, Offset.zero);
      expect(
        tester.widget<AnimatedSlide>(bottomOverlayFinder).offset,
        Offset.zero,
      );
    },
  );

  testWidgets('three-photo collage uses one large image beside two stacked', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 3),
      ),
    );
    await tester.pumpAndSettle();

    final Rect first = _photoRect(tester, 0);
    final Rect second = _photoRect(tester, 1);
    final Rect third = _photoRect(tester, 2);

    expect(first.left, lessThan(second.left));
    expect(first.top, closeTo(second.top, 0.5));
    expect(second.left, closeTo(third.left, 0.5));
    expect(third.top, greaterThan(second.top));
    expect(first.height, greaterThan(second.height));
    expect(second.height, closeTo(third.height, 0.5));
  });

  testWidgets(
    'five-photo collage uses a three-photo row over a two-photo row',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _buildPhotoMessageScreen(
          _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 5),
        ),
      );
      await tester.pumpAndSettle();

      final Rect first = _photoRect(tester, 0);
      final Rect second = _photoRect(tester, 1);
      final Rect third = _photoRect(tester, 2);
      final Rect fourth = _photoRect(tester, 3);
      final Rect fifth = _photoRect(tester, 4);

      expect(first.top, closeTo(second.top, 0.5));
      expect(second.top, closeTo(third.top, 0.5));
      expect(first.left, lessThan(second.left));
      expect(second.left, lessThan(third.left));
      expect(fourth.top, greaterThan(first.top));
      expect(fourth.top, closeTo(fifth.top, 0.5));
      expect(fourth.left, lessThan(fifth.left));
      expect(fourth.width, greaterThan(first.width));
    },
  );

  testWidgets('ten-photo collage renders three, three, two, and two photos', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(
        _photoMessage(senderId: '1', recipientId: '2', attachmentCount: 10),
      ),
    );
    await tester.pumpAndSettle();

    for (int index = 0; index < 10; index++) {
      expect(_photoFinder(index), findsOneWidget);
    }

    final Rect first = _photoRect(tester, 0);
    final Rect fourth = _photoRect(tester, 3);
    final Rect seventh = _photoRect(tester, 6);
    final Rect ninth = _photoRect(tester, 8);

    expect(_photoRect(tester, 1).top, closeTo(first.top, 0.5));
    expect(_photoRect(tester, 2).top, closeTo(first.top, 0.5));
    expect(_photoRect(tester, 4).top, closeTo(fourth.top, 0.5));
    expect(_photoRect(tester, 5).top, closeTo(fourth.top, 0.5));
    expect(_photoRect(tester, 7).top, closeTo(seventh.top, 0.5));
    expect(_photoRect(tester, 9).top, closeTo(ninth.top, 0.5));
    expect(fourth.top, greaterThan(first.top));
    expect(seventh.top, greaterThan(fourth.top));
    expect(ninth.top, greaterThan(seventh.top));
    expect(seventh.width, greaterThan(first.width));
  });
}
