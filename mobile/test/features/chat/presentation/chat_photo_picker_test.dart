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

final class _FakePhotoLibrary implements ChatPhotoLibrary {
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

Future<void> _tapPhotoAsset(
  WidgetTester tester,
  String assetId,
) async {
  final Finder tileFinder = find.byKey(
    ValueKey<String>('photo-tile-$assetId'),
  );

  final Finder gridFinder = find.byKey(
    const ValueKey<String>('photo-grid'),
  );

  final Finder gridScrollableFinder = find.descendant(
    of: gridFinder,
    matching: find.byType(Scrollable),
  );

  for (int attempt = 0; attempt < 30; attempt++) {
    if (tileFinder.evaluate().isEmpty) {
      await tester.drag(
        gridScrollableFinder,
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      continue;
    }

    final Rect gridRect = tester.getRect(gridFinder);
    final Rect tileRect = tester.getRect(tileFinder);

    // 타일 중심이 GridView의 실제 터치 가능 영역 안에 있어야 한다.
    // 단순히 위젯 트리에 빌드됐다는 것만으로는 충분하지 않다.
    final double safeTop = gridRect.top + 8;
    final double safeBottom = gridRect.bottom - 8;

    if (tileRect.center.dy < safeTop) {
      await tester.drag(
        gridScrollableFinder,
        const Offset(0, 120),
      );
      await tester.pumpAndSettle();
      continue;
    }

    if (tileRect.center.dy > safeBottom) {
      await tester.drag(
        gridScrollableFinder,
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      continue;
    }

    await tester.tapAt(tileRect.center);

    // 선택 번호, Send 활성 상태, 선택 제한 상태가
    // 다음 동작 전에 위젯 트리에 반영되도록 한다.
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
      final _FakePhotoLibrary library =
          _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (
            ChatPhotoSelectionResult result,
          ) async {},
        ),
      );

      await tester.pumpAndSettle();

      await _tapPhotoAsset(
        tester,
        'asset-2',
      );

      await _tapPhotoAsset(
        tester,
        'asset-4',
      );

      Finder badgeFinder = find.descendant(
        of: find.byKey(
          const ValueKey<String>(
            'photo-selection-badge-asset-2',
          ),
        ),
        matching: find.text('1'),
      );

      expect(badgeFinder, findsOneWidget);

      badgeFinder = find.descendant(
        of: find.byKey(
          const ValueKey<String>(
            'photo-selection-badge-asset-4',
          ),
        ),
        matching: find.text('2'),
      );

      expect(badgeFinder, findsOneWidget);

      await _tapPhotoAsset(
        tester,
        'asset-2',
      );

      badgeFinder = find.descendant(
        of: find.byKey(
          const ValueKey<String>(
            'photo-selection-badge-asset-4',
          ),
        ),
        matching: find.text('1'),
      );

      expect(badgeFinder, findsOneWidget);

      expect(
        find.text('1 Send'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'photo picker limits selection to ten photos',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library =
          _FakePhotoLibrary();

      ChatPhotoSelectionResult? result;

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          onSend: (
            ChatPhotoSelectionResult value,
          ) async {
            result = value;
          },
        ),
      );

      await tester.pumpAndSettle();

      for (int index = 0; index < 10; index++) {
        await _tapPhotoAsset(
          tester,
          'asset-$index',
        );
      }

      expect(
        find.text('10 Send'),
        findsOneWidget,
      );

      // 10장이 이미 선택된 상태에서 11번째를 선택한다.
      await _tapPhotoAsset(
        tester,
        'asset-10',
      );

      expect(
        find.text(
          'You can select up to 10 photos.',
        ),
        findsOneWidget,
      );

      // 제한을 초과한 사진은 선택되지 않아야 한다.
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey<String>(
              'photo-selection-badge-asset-10',
            ),
          ),
          matching: find.text('11'),
        ),
        findsNothing,
      );

      expect(
        find.text('10 Send'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-picker-send',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.assets.length, 10);
      expect(result!.collage, isTrue);
    },
  );

  testWidgets(
    'album list changes the visible album without clearing selections',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library =
          _FakePhotoLibrary();

      await tester.pumpWidget(
        _buildPicker(
          library: library,
          expanded: true,
          onSend: (
            ChatPhotoSelectionResult result,
          ) async {},
        ),
      );

      await tester.pumpAndSettle();

      await _tapPhotoAsset(
        tester,
        'asset-1',
      );

      expect(
        find.text('1 Send'),
        findsOneWidget,
      );

      // 확장 패널 헤더의 Recents 드롭다운을 연다.
      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-album-dropdown',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>(
            'photo-album-list',
          ),
        ),
        findsOneWidget,
      );

      expect(
        find.byKey(
          const ValueKey<String>(
            'photo-album-sheet',
          ),
        ),
        findsNothing,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-album-row-favorites',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>(
            'photo-tile-favorite-0',
          ),
        ),
        findsOneWidget,
      );

      // 다른 앨범으로 이동해도 기존 선택 개수는 유지된다.
      expect(
        find.text('1 Send'),
        findsOneWidget,
      );

      // 다시 Recents로 돌아간다.
      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-album-dropdown',
          ),
        ),
      );

      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-album-row-all',
          ),
        ),
      );

      await tester.pumpAndSettle();

      await _tapPhotoAsset(
        tester,
        'asset-1',
      );

      // 기존에 1번이었던 사진을 탭하면 해제된다.
      // 이는 앨범 이동 중에도 동일한 선택 항목이 유지됐다는 뜻이다.
      expect(
        find.text('1 Send'),
        findsNothing,
      );

      expect(
        find.text('Send'),
        findsOneWidget,
      );
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

    // 사진 선택 결과가 반영되어 Send 버튼이 활성화된 상태다.
    expect(find.text('1 Send'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('photo-collage-toggle')),
    );

    // collage 상태 변경을 다음 Send 탭 전에 반영한다.
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
      await tester.binding.setSurfaceSize(
        const Size(420, 900),
      );

      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });

      final _FakePhotoLibrary library =
          _FakePhotoLibrary();

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
                  onSend: (
                    ChatPhotoSelectionResult result,
                  ) async {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final Rect pickerRect = tester.getRect(
        find.byKey(
          const ValueKey<String>('photo-picker'),
        ),
      );

      final Rect closeRect = tester.getRect(
        find.byKey(
          const ValueKey<String>(
            'photo-picker-close',
          ),
        ),
      );

      final Rect titleRect = tester.getRect(
        find.byKey(
          const ValueKey<String>(
            'photo-picker-title',
          ),
        ),
      );

      final Rect sendRect = tester.getRect(
        find.byKey(
          const ValueKey<String>(
            'photo-picker-send',
          ),
        ),
      );

      expect(
        pickerRect.width,
        closeTo(420, 0.01),
      );

      expect(
        closeRect.right,
        lessThan(titleRect.left),
      );

      expect(
        titleRect.right,
        lessThan(sendRect.left),
      );

      expect(
        titleRect.center.dx,
        closeTo(
          pickerRect.center.dx,
          0.5,
        ),
      );
    },
  );

  testWidgets(
    'photo picker handle reports vertical drag gestures',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library =
          _FakePhotoLibrary();

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
                onSend: (
                  ChatPhotoSelectionResult result,
                ) async {},
                onHandleDragStart: (
                  DragStartDetails details,
                ) {
                  dragStarts++;
                },
                onHandleDragUpdate: (
                  DragUpdateDetails details,
                ) {
                  dragUpdates++;
                },
                onHandleDragEnd: (
                  DragEndDetails details,
                ) {
                  dragEnds++;
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(
          const ValueKey<String>(
            'photo-picker-handle-area',
          ),
        ),
        const Offset(0, -120),
      );

      await tester.pumpAndSettle();

      expect(dragStarts, 1);
      expect(dragUpdates, greaterThan(0));
      expect(dragEnds, 1);
    },
  );

  testWidgets(
    'expanded photo picker switches between grid and album list',
    (WidgetTester tester) async {
      final _FakePhotoLibrary library =
          _FakePhotoLibrary();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 760,
              child: ChatPhotoPicker(
                photoLibrary: library,
                expanded: true,
                onClose: () {},
                onSend: (
                  ChatPhotoSelectionResult result,
                ) async {},
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>(
            'photo-album-dropdown',
          ),
        ),
        findsOneWidget,
      );

      expect(find.text('Recents'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-album-dropdown',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>(
            'photo-album-list',
          ),
        ),
        findsOneWidget,
      );

      expect(find.text('Favorites'), findsOneWidget);

      await tester.tap(
        find.byKey(
          const ValueKey<String>(
            'photo-album-row-favorites',
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const ValueKey<String>(
            'photo-tile-favorite-0',
          ),
        ),
        findsOneWidget,
      );
    },
  );
}
