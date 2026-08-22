import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/domain/chat_message.dart';
import 'package:juliatalk/features/chat/presentation/chat_conversation_view.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAABmJLR0QA'
  '/wD/AP+gvaeTAAAACXBIWXMAAAsTAAALEwEAmpwYAAAAB3RJTUUH5gMQ'
  'FwcdLl4wmwAAAAtJREFUCNdjYAACAAAFAAHiJgWbAAAAAElFTkSuQmCC',
);

final class _FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  final List<String> calls = <String>[];
  final List<Duration> seekPositions = <Duration>[];
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  int _nextPlayerId = 0;
  Duration position = Duration.zero;

  @override
  Future<void> init() async {
    calls.add('init');
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final int playerId = _nextPlayerId++;
    final StreamController<VideoEvent> controller =
        StreamController<VideoEvent>();
    _events[playerId] = controller;
    controller.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(1179, 2556),
      ),
    );
    calls.add('create');
    return playerId;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return _events[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
    seekPositions.add(position);
    calls.add('seek');
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    return position;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    return const ColoredBox(color: Colors.black);
  }

  void complete() {
    _events.values.single.add(VideoEvent(eventType: VideoEventType.completed));
  }
}

Widget _buildVideoMessageScreen(File videoFile) {
  final ChatMessage message = ChatMessage(
    id: 'video-message',
    senderId: '1',
    recipientId: '2',
    content: '',
    createdAt: DateTime(2026, 7, 1, 12, 52),
    videoAttachment: ChatVideoAttachment(
      assetId: 'video-preview',
      width: 1179,
      height: 2556,
      duration: const Duration(seconds: 10),
      previewBytes: _testPng,
      localPath: videoFile.path,
      fileName: 'video.mp4',
      mimeType: 'video/mp4',
    ),
  );

  return MaterialApp(
    builder: (BuildContext context, Widget? child) {
      return MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(padding: const EdgeInsets.only(top: 59)),
        child: child!,
      );
    },
    home: ChatConversationView(
      initialMessages: <ChatMessage>[message],
      currentUserName: 'June',
      otherParticipantName: 'Lia',
    ),
  );
}

Future<void> _openVideoViewer(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('outgoing-bubble-video-video-preview')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VideoPlayerPlatform originalPlatform;
  late _FakeVideoPlayerPlatform videoPlatform;
  late Directory tempDirectory;
  late File videoFile;

  setUp(() {
    originalPlatform = VideoPlayerPlatform.instance;
    videoPlatform = _FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = videoPlatform;
    tempDirectory = Directory.systemTemp.createTempSync(
      'juliatalk-video-viewer-test-',
    );
    videoFile = File('${tempDirectory.path}/video.mp4')
      ..writeAsBytesSync(const <int>[0]);
  });

  tearDown(() {
    VideoPlayerPlatform.instance = originalPlatform;
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'video opens full screen, starts immediately, and matches viewer controls',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(_buildVideoMessageScreen(videoFile));
      await tester.pumpAndSettle();

      expect(find.byType(VideoPlayer), findsNothing);

      await _openVideoViewer(tester);

      expect(videoPlatform.calls, contains('play'));
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('video-viewer-back')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('video-viewer-download')),
        findsOneWidget,
      );
      expect(find.text('June'), findsOneWidget);
      expect(find.text('Jul 1, 2026 at 12:52 PM'), findsOneWidget);

      final Rect topBarRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-top-bar')),
      );
      final Rect bottomOverlayRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-bottom-overlay')),
      );
      final Rect actionBarBackgroundRect = tester.getRect(
        find.byKey(
          const ValueKey<String>('video-viewer-action-bar-background'),
        ),
      );
      final Rect playbackRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-playback')),
      );
      final Rect progressRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-progress')),
      );
      final Rect elapsedTimeRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-elapsed-time')),
      );
      final Rect totalTimeRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-total-time')),
      );
      final Rect downloadRect = tester.getRect(
        find.byKey(const ValueKey<String>('video-viewer-download')),
      );

      expect(topBarRect, const Rect.fromLTWH(0, 0, 393, 126));
      expect(bottomOverlayRect, const Rect.fromLTWH(0, 688, 393, 164));
      expect(actionBarBackgroundRect, const Rect.fromLTWH(0, 707, 393, 145));
      expect(playbackRect, const Rect.fromLTWH(16, 734, 20, 20));
      expect(progressRect.top, 732);
      expect(progressRect.height, 24);
      expect(
        progressRect.center.dy - actionBarBackgroundRect.top,
        downloadRect.top - progressRect.center.dy,
      );
      expect(progressRect.left - elapsedTimeRect.right, 6);
      expect(totalTimeRect.left - progressRect.right, 6);
      expect(totalTimeRect.right, 377);
      expect(downloadRect, const Rect.fromLTWH(172.5, 781, 48, 48));

      final Text elapsedTime = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('video-viewer-elapsed-time')),
          matching: find.byType(Text),
        ),
      );
      expect(elapsedTime.style?.fontSize, 13);
      expect(elapsedTime.style?.height, 20 / 13);
      expect(elapsedTime.style?.letterSpacing, -0.8);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('video-viewer-playback')),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );

      final AnimatedSlide visibleTopBar = tester.widget<AnimatedSlide>(
        find.byKey(const ValueKey<String>('video-viewer-top-bar')),
      );
      final AnimatedSlide visibleBottomOverlay = tester.widget<AnimatedSlide>(
        find.byKey(const ValueKey<String>('video-viewer-bottom-overlay')),
      );
      expect(visibleTopBar.offset, Offset.zero);
      expect(visibleBottomOverlay.offset, Offset.zero);

      await tester.pump(const Duration(milliseconds: 1830));
      await tester.pump(const Duration(milliseconds: 200));

      final AnimatedSlide hiddenTopBar = tester.widget<AnimatedSlide>(
        find.byKey(const ValueKey<String>('video-viewer-top-bar')),
      );
      final AnimatedSlide hiddenBottomOverlay = tester.widget<AnimatedSlide>(
        find.byKey(const ValueKey<String>('video-viewer-bottom-overlay')),
      );
      expect(hiddenTopBar.offset, const Offset(0, -1));
      expect(hiddenBottomOverlay.offset, const Offset(0, 1));
      expect(hiddenTopBar.curve, Curves.linear);
      expect(hiddenBottomOverlay.curve, Curves.linear);
    },
  );

  testWidgets('video completion returns to zero and restores controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_buildVideoMessageScreen(videoFile));
    await tester.pumpAndSettle();
    await _openVideoViewer(tester);

    await tester.pump(const Duration(milliseconds: 1990));
    videoPlatform.complete();
    await tester.pump();
    await tester.pump();

    expect(videoPlatform.seekPositions, contains(Duration.zero));
    expect(find.text('0:00'), findsOneWidget);

    final AnimatedSlide topBar = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey<String>('video-viewer-top-bar')),
    );
    final AnimatedSlide bottomOverlay = tester.widget<AnimatedSlide>(
      find.byKey(const ValueKey<String>('video-viewer-bottom-overlay')),
    );
    expect(topBar.offset, Offset.zero);
    expect(bottomOverlay.offset, Offset.zero);
  });

  testWidgets('dragging the progress thumb seeks before release', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(393, 852));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_buildVideoMessageScreen(videoFile));
    await tester.pumpAndSettle();
    await _openVideoViewer(tester);

    final Rect progressRect = tester.getRect(
      find.byKey(const ValueKey<String>('video-viewer-progress')),
    );
    final TestGesture gesture = await tester.startGesture(
      Offset(
        progressRect.left + progressRect.width * 0.2,
        progressRect.center.dy,
      ),
    );
    await tester.pump();
    await gesture.moveTo(
      Offset(
        progressRect.left + progressRect.width * 0.7,
        progressRect.center.dy,
      ),
    );
    await tester.pump();

    expect(videoPlatform.seekPositions, isNotEmpty);
    expect(
      videoPlatform.seekPositions.last.inMilliseconds,
      closeTo(const Duration(seconds: 7).inMilliseconds, 100),
    );

    await gesture.up();
    await tester.pump();
  });

  testWidgets(
    'visible video bars shield taps and hidden bars reveal anywhere',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(393, 852));
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(_buildVideoMessageScreen(videoFile));
      await tester.pumpAndSettle();
      await _openVideoViewer(tester);

      final Finder topBarFinder = find.byKey(
        const ValueKey<String>('video-viewer-top-bar'),
      );
      final Finder bottomOverlayFinder = find.byKey(
        const ValueKey<String>('video-viewer-bottom-overlay'),
      );
      final Rect topBarRect = tester.getRect(topBarFinder);
      final Rect bottomOverlayRect = tester.getRect(bottomOverlayFinder);

      await tester.tapAt(Offset(topBarRect.right - 8, topBarRect.center.dy));
      await tester.pump();
      await tester.tapAt(
        Offset(bottomOverlayRect.left + 8, bottomOverlayRect.bottom - 64),
      );
      await tester.pump();

      expect(tester.widget<AnimatedSlide>(topBarFinder).offset, Offset.zero);
      expect(
        tester.widget<AnimatedSlide>(bottomOverlayFinder).offset,
        Offset.zero,
      );

      await tester.tapAt(const Offset(196.5, 426));
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        tester.widget<AnimatedSlide>(topBarFinder).offset,
        const Offset(0, -1),
      );
      expect(
        tester.widget<AnimatedSlide>(bottomOverlayFinder).offset,
        const Offset(0, 1),
      );

      await tester.tapAt(
        Offset(bottomOverlayRect.left + 8, bottomOverlayRect.bottom - 64),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.widget<AnimatedSlide>(topBarFinder).offset, Offset.zero);
      expect(
        tester.widget<AnimatedSlide>(bottomOverlayFinder).offset,
        Offset.zero,
      );
    },
  );
}
