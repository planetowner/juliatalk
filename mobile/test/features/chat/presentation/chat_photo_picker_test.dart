import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/chat/data/chat_photo_library.dart';
import 'package:juliatalk/features/chat/presentation/chat_photo_picker.dart';

final Uint8List _testPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  'CAYAAAAfFcSJAAAADUlEQVR42mNk+M/w'
  'HwAEAQH/2p3KAAAAAElFTkSuQmCC',
);

final class _FakePhotoLibrary
    implements ChatPhotoLibrary, ChatPhotoLibraryChangeSource {
  _FakePhotoLibrary()
    : albums = const <ChatPhotoAlbum>[
        ChatPhotoAlbum(
          id: 'all',
          name: 'Recents',
          assetCount: 12,
          isAll: true,
          coverAssetId: 'asset-0',
        ),
        ChatPhotoAlbum(
          id: 'favorites',
          name: 'Favorites',
          assetCount: 2,
          isAll: false,
          coverAssetId: 'favorite-0',
        ),
      ],
      assetsByAlbum = <String, List<ChatPhotoAsset>>{
        'all': List<ChatPhotoAsset>.generate(
          12,
          (int index) =>
              ChatPhotoAsset(id: 'asset-$index', width: 1200, height: 900),
        ),
        'favorites': List<ChatPhotoAsset>.generate(
          2,
          (int index) =>
              ChatPhotoAsset(id: 'favorite-$index', width: 900, height: 1200),
        ),
      };

  final List<ChatPhotoAlbum> albums;

  final Map<String, List<ChatPhotoAsset>> assetsByAlbum;

  final Set<ChatPhotoLibraryChangeCallback> _changeListeners =
      <ChatPhotoLibraryChangeCallback>{};

  @override
  void addChangeListener(ChatPhotoLibraryChangeCallback listener) {
    _changeListeners.add(listener);
  }

  @override
  void removeChangeListener(ChatPhotoLibraryChangeCallback listener) {
    _changeListeners.remove(listener);
  }

  void emitChange({
    Iterable<String> createdAssetIds = const <String>[],
    Iterable<String> deletedAssetIds = const <String>[],
  }) {
    final ChatPhotoLibraryChange change = ChatPhotoLibraryChange(
      createdAssetIds: createdAssetIds,
      deletedAssetIds: deletedAssetIds,
    );

    for (final ChatPhotoLibraryChangeCallback listener
        in List<ChatPhotoLibraryChangeCallback>.of(_changeListeners)) {
      listener(change);
    }
  }

  @override
  Future<ChatPhotoAccessState> requestAccess() async {
    return ChatPhotoAccessState.authorized;
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    return albums;
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    final List<ChatPhotoAsset> source =
        assetsByAlbum[albumId] ?? const <ChatPhotoAsset>[];

    final int start = page * pageSize;

    if (start >= source.length) {
      return const <ChatPhotoAsset>[];
    }

    final int end = (start + pageSize).clamp(0, source.length);

    return source.sublist(start, end);
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
    return ChatPhotoFile(
      bytes: _testPng,
      fileName: '$assetId.png',
      mimeType: 'image/png',
      sizeBytes: _testPng.length,
    );
  }

  @override
  Future<void> openSettings() async {}
}

Widget _buildPicker({
  required _FakePhotoLibrary library,
  required ChatPhotoSendCallback onSend,
  bool expanded = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 420,
          height: 520,
          child: ChatPhotoPicker(
            photoLibrary: library,
            expanded: expanded,
            onClose: () {},
            onSend: onSend,
          ),
        ),
      ),
    ),
  );
}

Future<void> _tapPhotoAsset(WidgetTester tester, String assetId) async {
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

    // 타일 중심이 GridView의 실제 터치 영역 안에 있어야 해요.
    // 위젯 트리에 빌드된 것만으로는 실제 탭 가능 여부를 확인할 수 없어요.
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

    // 선택 번호, Send 활성 상태, 선택 제한 상태가
    // 다음 동작 전에 위젯 트리에 반영되게 해요.
    await tester.pump();

    return;
  }

  throw TestFailure(
    'Could not bring photo asset "$assetId" '
    'into the tappable grid viewport.',
  );
}

void main() {
  testWidgets(
    'photo selections are numbered in selection order and renumber after removal',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library = _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (ChatPhotoSelectionResult result) async {},
        ),
      );

      await tester.pumpAndSettle();

      await _tapPhotoAsset(tester, 'asset-2');

      await _tapPhotoAsset(tester, 'asset-4');

      Finder badgeFinder = find.descendant(
        of: find.byKey(const ValueKey<String>('photo-selection-badge-asset-2')),
        matching: find.text('1'),
      );

      expect(badgeFinder, findsOneWidget);

      badgeFinder = find.descendant(
        of: find.byKey(const ValueKey<String>('photo-selection-badge-asset-4')),
        matching: find.text('2'),
      );

      expect(badgeFinder, findsOneWidget);

      await _tapPhotoAsset(tester, 'asset-2');

      badgeFinder = find.descendant(
        of: find.byKey(const ValueKey<String>('photo-selection-badge-asset-4')),
        matching: find.text('1'),
      );

      expect(badgeFinder, findsOneWidget);

      expect(find.text('1 Send'), findsOneWidget);
    },
  );

  testWidgets('photo picker limits selection to ten photos', (
    WidgetTester tester,
  ) async {
    final _FakePhotoLibrary library = _FakePhotoLibrary();

    ChatPhotoSelectionResult? result;

    await tester.pumpWidget(
      _buildPicker(
        library: library,
        onSend: (ChatPhotoSelectionResult value) async {
          result = value;
        },
      ),
    );

    await tester.pumpAndSettle();

    for (int index = 0; index < 10; index++) {
      await _tapPhotoAsset(tester, 'asset-$index');
    }

    expect(find.text('10 Send'), findsOneWidget);

    await _tapPhotoAsset(tester, 'asset-10');

    expect(find.text('You can select up to 10 items.'), findsOneWidget);

    expect(
      find.descendant(
        of: find.byKey(
          const ValueKey<String>('photo-selection-badge-asset-10'),
        ),
        matching: find.text('11'),
      ),
      findsNothing,
    );

    expect(find.text('10 Send'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('photo-picker-send')));

    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.assets.length, 10);
    expect(result!.collage, isTrue);
  });

  testWidgets('video tiles show duration and send one video at a time', (
    WidgetTester tester,
  ) async {
    final _FakePhotoLibrary library = _FakePhotoLibrary();
    library.assetsByAlbum['all']!.insert(
      0,
      const ChatPhotoAsset(
        id: 'video-0',
        width: 1080,
        height: 1920,
        type: ChatPhotoAssetType.video,
        duration: Duration(seconds: 14),
      ),
    );
    ChatPhotoSelectionResult? result;

    await tester.pumpWidget(
      _buildPicker(
        library: library,
        onSend: (ChatPhotoSelectionResult value) async {
          result = value;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0:14'), findsOneWidget);

    await _tapPhotoAsset(tester, 'asset-0');
    await _tapPhotoAsset(tester, 'video-0');

    expect(find.text('1 Send'), findsOneWidget);
    expect(find.text('Collage Photos'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('photo-picker-send')));
    await tester.pumpAndSettle();

    expect(result?.assets, hasLength(1));
    expect(result?.assets.single.id, 'video-0');
    expect(result?.assets.single.isVideo, isTrue);
    expect(result?.collage, isFalse);
  });

  testWidgets(
    'send keeps its label and includes the loaded thumbnail while pending',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library = _FakePhotoLibrary();
      final Completer<void> sendCompleter = Completer<void>();
      ChatPhotoSelectionResult? result;

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (ChatPhotoSelectionResult value) {
            result = value;
            return sendCompleter.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await _tapPhotoAsset(tester, 'asset-0');

      final Finder sendButton = find.byKey(
        const ValueKey<String>('photo-picker-send'),
      );
      final InkWell sendInkWell = tester.widget<InkWell>(
        find.descendant(of: sendButton, matching: find.byType(InkWell)),
      );

      expect(sendInkWell.splashFactory, same(NoSplash.splashFactory));
      expect(sendInkWell.highlightColor, Colors.transparent);

      await tester.tap(sendButton);
      await tester.pump();

      expect(find.text('1 Send'), findsOneWidget);
      expect(
        find.descendant(
          of: sendButton,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(result, isNotNull);
      expect(result!.previewBytesByAssetId['asset-0'], same(_testPng));

      sendCompleter.complete();
      await tester.pump();
    },
  );

  testWidgets(
    'album list changes the visible album without clearing selections',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library = _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          expanded: true,
          onSend: (ChatPhotoSelectionResult result) async {},
        ),
      );

      await tester.pumpAndSettle();

      await _tapPhotoAsset(tester, 'asset-1');

      expect(find.text('1 Send'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('photo-album-dropdown')),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('photo-album-list')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey<String>('photo-album-sheet')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('photo-album-row-favorites')),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('photo-tile-favorite-0')),
        findsOneWidget,
      );

      // 다른 앨범으로 이동해도 기존 선택 개수는 유지돼요.
      expect(find.text('1 Send'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('photo-album-dropdown')),
      );

      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('photo-album-row-all')),
      );

      await tester.pumpAndSettle();

      await _tapPhotoAsset(tester, 'asset-1');

      // 앨범 이동 중에도 같은 선택을 유지했는지 선택 해제로 검증해요.
      expect(find.text('1 Send'), findsNothing);

      expect(find.text('Send'), findsOneWidget);
    },
  );

  testWidgets('collage control changes the send mode', (
    WidgetTester tester,
  ) async {
    final _FakePhotoLibrary library = _FakePhotoLibrary();

    ChatPhotoSelectionResult? result;

    await tester.pumpWidget(
      _buildPicker(
        library: library,
        onSend: (ChatPhotoSelectionResult value) async {
          result = value;
        },
      ),
    );

    await tester.pumpAndSettle();

    await _tapPhotoAsset(tester, 'asset-0');

    // 사진 선택 결과가 반영돼 Send 버튼이 활성화된 상태예요.
    expect(find.text('1 Send'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-collage-toggle')),
    );

    // collage 상태 변경을 다음 Send 탭 전에 반영해요.
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey<String>('photo-picker-send')));

    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.assets.length, 1);
    expect(result!.collage, isFalse);
  });

  testWidgets(
    'photo picker fills its surface and header controls do not overlap',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      final _FakePhotoLibrary library = _FakePhotoLibrary();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: 420,
                height: 480,
                child: ChatPhotoPicker(
                  photoLibrary: library,
                  onClose: () {},
                  onSend: (ChatPhotoSelectionResult result) async {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final Rect pickerRect = tester.getRect(
        find.byKey(const ValueKey<String>('photo-picker')),
      );

      final Rect closeRect = tester.getRect(
        find.byKey(const ValueKey<String>('photo-picker-close')),
      );

      final Rect titleRect = tester.getRect(
        find.byKey(const ValueKey<String>('photo-picker-title')),
      );

      final Rect sendRect = tester.getRect(
        find.byKey(const ValueKey<String>('photo-picker-send')),
      );

      expect(pickerRect.width, closeTo(420, 0.01));

      expect(closeRect.right, lessThan(titleRect.left));

      expect(titleRect.right, lessThan(sendRect.left));

      expect(titleRect.center.dx, closeTo(pickerRect.center.dx, 0.5));
    },
  );

  testWidgets('photo picker handle reports vertical drag gestures', (
    WidgetTester tester,
  ) async {
    final _FakePhotoLibrary library = _FakePhotoLibrary();

    int dragStarts = 0;
    int dragUpdates = 0;
    int dragEnds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 520,
            child: ChatPhotoPicker(
              photoLibrary: library,
              onClose: () {},
              onSend: (ChatPhotoSelectionResult result) async {},
              onHandleDragStart: (DragStartDetails details) {
                dragStarts++;
              },
              onHandleDragUpdate: (DragUpdateDetails details) {
                dragUpdates++;
              },
              onHandleDragEnd: (DragEndDetails details) {
                dragEnds++;
              },
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey<String>('photo-picker-handle-area')),
      const Offset(0, -120),
    );

    await tester.pumpAndSettle();

    expect(dragStarts, 1);
    expect(dragUpdates, greaterThan(0));
    expect(dragEnds, 1);
  });

  testWidgets('expanded photo picker switches between grid and album list', (
    WidgetTester tester,
  ) async {
    final _FakePhotoLibrary library = _FakePhotoLibrary();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 760,
            child: ChatPhotoPicker(
              photoLibrary: library,
              expanded: true,
              onClose: () {},
              onSend: (ChatPhotoSelectionResult result) async {},
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-album-dropdown')),
      findsOneWidget,
    );

    expect(find.text('Recents'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-album-dropdown')),
    );

    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-album-list')),
      findsOneWidget,
    );

    expect(find.text('Favorites'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-album-row-favorites')),
    );

    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('photo-tile-favorite-0')),
      findsOneWidget,
    );
  });

  testWidgets(
    'visible picker animates gallery additions and removals into the grid',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library = _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (ChatPhotoSelectionResult result) async {},
        ),
      );

      await tester.pumpAndSettle();
      await _tapPhotoAsset(tester, 'asset-0');

      final Finder movingAssetFinder = find.byKey(
        const ValueKey<String>('photo-tile-asset-2'),
      );
      final Rect beforeAdditionRect = tester.getRect(movingAssetFinder);

      library.assetsByAlbum['all']!.insert(
        0,
        const ChatPhotoAsset(id: 'new-screenshot', width: 1290, height: 2796),
      );
      library.emitChange(createdAssetIds: const <String>['new-screenshot']);

      await tester.pump(const Duration(milliseconds: 181));
      await tester.pump();

      final Finder enteringItemFinder = find.byKey(
        const ValueKey<String>('photo-grid-item-new-screenshot'),
      );

      expect(enteringItemFinder, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 80));

      final Rect duringAdditionRect = tester.getRect(movingAssetFinder);
      final Opacity enteringOpacity = tester.widget<Opacity>(
        find.descendant(of: enteringItemFinder, matching: find.byType(Opacity)),
      );

      expect(duringAdditionRect.left, lessThan(beforeAdditionRect.left));
      expect(duringAdditionRect.top, greaterThan(beforeAdditionRect.top));
      expect(enteringOpacity.opacity, greaterThan(0));
      expect(enteringOpacity.opacity, lessThan(1));

      await tester.pumpAndSettle();

      final Rect afterAdditionRect = tester.getRect(movingAssetFinder);

      expect(afterAdditionRect.left, lessThan(duringAdditionRect.left));
      expect(afterAdditionRect.top, greaterThan(duringAdditionRect.top));
      expect(
        find.byKey(const ValueKey<String>('photo-tile-new-screenshot')),
        findsOneWidget,
      );

      final Rect beforeRemovalRect = tester.getRect(movingAssetFinder);

      library.assetsByAlbum['all']!.removeWhere(
        (ChatPhotoAsset asset) => asset.id == 'asset-0',
      );
      library.emitChange(deletedAssetIds: const <String>['asset-0']);

      await tester.pump(const Duration(milliseconds: 181));
      await tester.pump();

      final Finder removedItemFinder = find.byKey(
        const ValueKey<String>('photo-grid-removal-asset-0'),
      );

      expect(removedItemFinder, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 80));

      final Rect duringRemovalRect = tester.getRect(movingAssetFinder);
      final Opacity removalOpacity = tester.widget<Opacity>(
        find.descendant(of: removedItemFinder, matching: find.byType(Opacity)),
      );

      expect(duringRemovalRect.left, greaterThan(beforeRemovalRect.left));
      expect(duringRemovalRect.top, lessThan(beforeRemovalRect.top));
      expect(removalOpacity.opacity, greaterThan(0));
      expect(removalOpacity.opacity, lessThan(1));

      await tester.pumpAndSettle();

      final Rect afterRemovalRect = tester.getRect(movingAssetFinder);

      expect(afterRemovalRect.left, greaterThan(duringRemovalRect.left));
      expect(afterRemovalRect.top, lessThan(duringRemovalRect.top));
      expect(removedItemFinder, findsNothing);
      expect(
        find.byKey(const ValueKey<String>('photo-tile-asset-0')),
        findsNothing,
      );
      expect(find.text('1 Send'), findsNothing);
      expect(find.text('Send'), findsOneWidget);
    },
  );

  testWidgets(
    'photo changes received while inactive animate after the app resumes',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library = _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (ChatPhotoSelectionResult result) async {},
        ),
      );

      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      library.assetsByAlbum['all']!.insert(
        0,
        const ChatPhotoAsset(
          id: 'created-while-inactive',
          width: 1200,
          height: 1600,
        ),
      );
      library.emitChange(
        createdAssetIds: const <String>['created-while-inactive'],
      );

      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey<String>('photo-tile-created-while-inactive')),
        findsNothing,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 181));
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey<String>('photo-grid-item-created-while-inactive'),
        ),
        findsOneWidget,
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('photo-tile-created-while-inactive')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'picker refreshes after the app resumes even without a native change event',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library = _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (ChatPhotoSelectionResult result) async {},
        ),
      );

      await tester.pumpAndSettle();

      library.assetsByAlbum['all']!.insert(
        0,
        const ChatPhotoAsset(
          id: 'saved-while-backgrounded',
          width: 1200,
          height: 1600,
        ),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await tester.pump(const Duration(milliseconds: 181));
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>('photo-tile-saved-while-backgrounded'),
        ),
        findsOneWidget,
      );
    },
  );
}
