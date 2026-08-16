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

Widget _buildPhotoMessageScreen(ChatMessage message) {
  return MaterialApp(
    home: ChatConversationView(initialMessages: <ChatMessage>[message]),
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
  const _PhotoRefreshHarness({super.key});

  @override
  State<_PhotoRefreshHarness> createState() => _PhotoRefreshHarnessState();
}

final class _PhotoRefreshHarnessState extends State<_PhotoRefreshHarness> {
  ChatMessage _message = ChatMessage(
    id: 'refreshed-photo-message',
    senderId: '1',
    recipientId: '2',
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    photoAttachments: <ChatPhotoAttachment>[
      ChatPhotoAttachment(
        assetId: 'refreshed-photo',
        mediaAssetId: 'refreshed-photo-media',
        previewBytes: _testPng,
        width: 1179,
        height: 2556,
      ),
    ],
  );

  void replaceWithServerMessage() {
    setState(() {
      _message = ChatMessage(
        id: 'refreshed-photo-message',
        senderId: '1',
        recipientId: '2',
        content: '',
        createdAt: DateTime(2026, 7, 1, 12, 52),
        photoAttachments: const <ChatPhotoAttachment>[
          ChatPhotoAttachment(
            assetId: 'refreshed-photo',
            mediaAssetId: 'refreshed-photo-media',
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

void main() {
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
    final Directory cacheDirectory = Directory.systemTemp.createTempSync(
      'juliatalk-photo-cache-test-',
    );
    const MethodChannel pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (MethodCall call) async {
          if (call.method == 'getApplicationCacheDirectory') {
            return cacheDirectory.path;
          }

          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (cacheDirectory.existsSync()) {
        cacheDirectory.deleteSync(recursive: true);
      }
    });

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

  testWidgets('a server refresh keeps the visible local photo preview', (
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

    harnessKey.currentState!.replaceWithServerMessage();
    await tester.pump();

    expect(find.byKey(previewKey), findsOneWidget);
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
      const ValueKey<String>('outgoing-bubble-1'),
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
      find.byKey(const ValueKey<String>('photo-upload-progress-1')),
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
      const Size.square(16),
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
    expect(progressIndicator.strokeWidth, 2.2);
    expect(progressIndicator.backgroundColor, Colors.transparent);

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
      find.byKey(const ValueKey<String>('photo-upload-progress-1')),
      findsNothing,
    );
  });

  testWidgets('tapping a photo opens the full-screen photo viewer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildPhotoMessageScreen(_photoMessage(senderId: '1', recipientId: '2')),
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
    expect(find.text('Me'), findsOneWidget);
    expect(find.text('Jul 1, 2026 at 12:52 PM'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('photo-viewer-counter')),
      findsNothing,
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
