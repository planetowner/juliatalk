import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:photo_manager/photo_manager.dart';

enum ChatPhotoAccessState { authorized, limited, denied }

final class ChatPhotoAlbum {
  const ChatPhotoAlbum({
    required this.id,
    required this.name,
    required this.assetCount,
    required this.isAll,
    required this.coverAssetId,
  });

  final String id;
  final String name;
  final int assetCount;
  final bool isAll;
  final String? coverAssetId;
}

final class ChatPhotoAsset {
  const ChatPhotoAsset({
    required this.id,
    required this.width,
    required this.height,
  });

  final String id;
  final int width;
  final int height;
}

abstract interface class ChatPhotoLibrary {
  Future<ChatPhotoAccessState> requestAccess();

  Future<List<ChatPhotoAlbum>> loadAlbums();

  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  });

  Future<Uint8List?> loadThumbnail({
    required String assetId,
    required int width,
    required int height,
  });

  Future<Uint8List?> loadMessagePreview({required String assetId});

  Future<void> openSettings();
}

final class MockChatPhotoLibrary implements ChatPhotoLibrary {
  MockChatPhotoLibrary();

  static const String _recentsAlbumId = 'mock-recents';
  static const String _favoritesAlbumId = 'mock-favorites';

  static const List<_MockPhotoSpec> _photos = <_MockPhotoSpec>[
    _MockPhotoSpec(
      id: 'mock-photo-window-light',
      width: 1200,
      height: 900,
      startColor: ui.Color(0xFFB7DFFF),
      endColor: ui.Color(0xFFFFD7A8),
      accentColor: ui.Color(0xFF3182F6),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-night-cafe',
      width: 900,
      height: 1200,
      startColor: ui.Color(0xFF2F3A56),
      endColor: ui.Color(0xFFE8B86D),
      accentColor: ui.Color(0xFFFFF1C7),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-airport',
      width: 1400,
      height: 900,
      startColor: ui.Color(0xFFE8F3FF),
      endColor: ui.Color(0xFF8B95A1),
      accentColor: ui.Color(0xFF03B26C),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-desk',
      width: 1200,
      height: 900,
      startColor: ui.Color(0xFFF9FAFB),
      endColor: ui.Color(0xFFB0B8C1),
      accentColor: ui.Color(0xFFF04452),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-rain',
      width: 900,
      height: 1200,
      startColor: ui.Color(0xFF4E5968),
      endColor: ui.Color(0xFFC9E2FF),
      accentColor: ui.Color(0xFF90C2FF),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-park',
      width: 1200,
      height: 900,
      startColor: ui.Color(0xFFAEEFD5),
      endColor: ui.Color(0xFFE8F3FF),
      accentColor: ui.Color(0xFF03B26C),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-train',
      width: 1300,
      height: 900,
      startColor: ui.Color(0xFFFFEEEE),
      endColor: ui.Color(0xFF90C2FF),
      accentColor: ui.Color(0xFF2272EB),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-dessert',
      width: 900,
      height: 900,
      startColor: ui.Color(0xFFFFD4D6),
      endColor: ui.Color(0xFFFFF1C7),
      accentColor: ui.Color(0xFFF04452),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-lake',
      width: 1400,
      height: 900,
      startColor: ui.Color(0xFF64A8FF),
      endColor: ui.Color(0xFFAEEFD5),
      accentColor: ui.Color(0xFFFFFFFF),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-notes',
      width: 900,
      height: 1200,
      startColor: ui.Color(0xFFF2F4F6),
      endColor: ui.Color(0xFFFFD7A8),
      accentColor: ui.Color(0xFF191F28),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-skyline',
      width: 1200,
      height: 900,
      startColor: ui.Color(0xFF1957C2),
      endColor: ui.Color(0xFFE8F3FF),
      accentColor: ui.Color(0xFFFFD7A8),
    ),
    _MockPhotoSpec(
      id: 'mock-photo-flowers',
      width: 900,
      height: 1200,
      startColor: ui.Color(0xFFFFEEEE),
      endColor: ui.Color(0xFFAEEFD5),
      accentColor: ui.Color(0xFFF66570),
    ),
  ];

  static final Map<String, _MockPhotoSpec> _photoById =
      <String, _MockPhotoSpec>{
        for (final _MockPhotoSpec photo in _photos) photo.id: photo,
      };

  final Map<String, Uint8List> _imageCache = <String, Uint8List>{};

  @override
  Future<ChatPhotoAccessState> requestAccess() async {
    return ChatPhotoAccessState.authorized;
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    return <ChatPhotoAlbum>[
      ChatPhotoAlbum(
        id: _recentsAlbumId,
        name: 'Recents',
        assetCount: _photos.length,
        isAll: true,
        coverAssetId: _photos.first.id,
      ),
      ChatPhotoAlbum(
        id: _favoritesAlbumId,
        name: 'Favorites',
        assetCount: 4,
        isAll: false,
        coverAssetId: _photos[1].id,
      ),
    ];
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    final List<_MockPhotoSpec> source = switch (albumId) {
      _favoritesAlbumId => _photos.take(4).toList(growable: false),
      _ => _photos,
    };

    final int start = page * pageSize;

    if (start >= source.length) {
      return const <ChatPhotoAsset>[];
    }

    final int end = (start + pageSize).clamp(0, source.length);

    return source
        .sublist(start, end)
        .map(
          (_MockPhotoSpec photo) => ChatPhotoAsset(
            id: photo.id,
            width: photo.width,
            height: photo.height,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<Uint8List?> loadThumbnail({
    required String assetId,
    required int width,
    required int height,
  }) {
    return _imageBytes(assetId: assetId, width: width, height: height);
  }

  @override
  Future<Uint8List?> loadMessagePreview({required String assetId}) {
    final _MockPhotoSpec? photo = _photoById[assetId];

    if (photo == null) {
      return Future<Uint8List?>.value();
    }

    final int longestSide = photo.width > photo.height
        ? photo.width
        : photo.height;
    final double scale = 960 / longestSide;
    final int width = (photo.width * scale).round().clamp(1, 960).toInt();
    final int height = (photo.height * scale).round().clamp(1, 960).toInt();

    return _imageBytes(assetId: assetId, width: width, height: height);
  }

  Future<Uint8List?> _imageBytes({
    required String assetId,
    required int width,
    required int height,
  }) async {
    final _MockPhotoSpec? photo = _photoById[assetId];

    if (photo == null) {
      return null;
    }

    final String cacheKey = '$assetId-$width-$height';
    final Uint8List? cachedBytes = _imageCache[cacheKey];

    if (cachedBytes != null) {
      return cachedBytes;
    }

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Rect bounds = ui.Rect.fromLTWH(
      0,
      0,
      width.toDouble(),
      height.toDouble(),
    );

    canvas.drawRect(
      bounds,
      ui.Paint()
        ..shader = ui.Gradient.linear(
          bounds.topLeft,
          bounds.bottomRight,
          <ui.Color>[photo.startColor, photo.endColor],
        ),
    );

    _paintMockPhotoDetails(canvas: canvas, bounds: bounds, photo: photo);

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(width, height);
    final ByteData? byteData = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );

    image.dispose();
    picture.dispose();

    if (byteData == null) {
      return null;
    }

    final Uint8List bytes = byteData.buffer.asUint8List();
    _imageCache[cacheKey] = bytes;

    return bytes;
  }

  void _paintMockPhotoDetails({
    required ui.Canvas canvas,
    required ui.Rect bounds,
    required _MockPhotoSpec photo,
  }) {
    final double shortSide = bounds.width < bounds.height
        ? bounds.width
        : bounds.height;
    final ui.Paint accentPaint = ui.Paint()
      ..color = photo.accentColor.withAlpha(210);
    final ui.Paint softPaint = ui.Paint()
      ..color = const ui.Color(0xFFFFFFFF).withAlpha(98);
    final ui.Paint shadowPaint = ui.Paint()
      ..color = const ui.Color(0xFF000000).withAlpha(22);

    canvas.drawCircle(
      ui.Offset(bounds.left + shortSide * 0.78, bounds.top + shortSide * 0.24),
      shortSide * 0.14,
      softPaint,
    );

    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        ui.Rect.fromLTWH(
          bounds.left + shortSide * 0.12,
          bounds.top + shortSide * 0.18,
          shortSide * 0.42,
          shortSide * 0.62,
        ),
        ui.Radius.circular(shortSide * 0.045),
      ),
      shadowPaint,
    );

    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        ui.Rect.fromLTWH(
          bounds.left + shortSide * 0.1,
          bounds.top + shortSide * 0.16,
          shortSide * 0.42,
          shortSide * 0.62,
        ),
        ui.Radius.circular(shortSide * 0.045),
      ),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF).withAlpha(136),
    );

    for (int index = 0; index < 4; index++) {
      final double y = bounds.top + shortSide * (0.26 + index * 0.11);

      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(
            bounds.left + shortSide * 0.16,
            y,
            shortSide * (index.isEven ? 0.25 : 0.18),
            shortSide * 0.025,
          ),
          ui.Radius.circular(shortSide * 0.012),
        ),
        accentPaint,
      );
    }

    canvas.drawPath(
      ui.Path()
        ..moveTo(bounds.left, bounds.bottom - shortSide * 0.22)
        ..quadraticBezierTo(
          bounds.left + bounds.width * 0.28,
          bounds.bottom - shortSide * 0.35,
          bounds.left + bounds.width * 0.55,
          bounds.bottom - shortSide * 0.18,
        )
        ..quadraticBezierTo(
          bounds.left + bounds.width * 0.8,
          bounds.bottom - shortSide * 0.03,
          bounds.right,
          bounds.bottom - shortSide * 0.16,
        )
        ..lineTo(bounds.right, bounds.bottom)
        ..lineTo(bounds.left, bounds.bottom)
        ..close(),
      ui.Paint()..color = photo.accentColor.withAlpha(118),
    );
  }

  @override
  Future<void> openSettings() async {}
}

final class _MockPhotoSpec {
  const _MockPhotoSpec({
    required this.id,
    required this.width,
    required this.height,
    required this.startColor,
    required this.endColor,
    required this.accentColor,
  });

  final String id;
  final int width;
  final int height;
  final ui.Color startColor;
  final ui.Color endColor;
  final ui.Color accentColor;
}

final class PhotoManagerChatPhotoLibrary implements ChatPhotoLibrary {
  static const PermissionRequestOption _permissionOption =
      PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.readWrite,
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: false,
        ),
      );

  static final FilterOptionGroup _filterOption = FilterOptionGroup(
    orders: const <OrderOption>[
      OrderOption(type: OrderOptionType.createDate, asc: false),
    ],
  );

  final Map<String, AssetPathEntity> _albumEntities =
      <String, AssetPathEntity>{};

  final Map<String, AssetEntity> _assetEntities = <String, AssetEntity>{};

  ChatPhotoAccessState? _cachedAccessState;

  Future<ChatPhotoAccessState>? _accessRequestInFlight;

  @override
  Future<ChatPhotoAccessState> requestAccess() {
    final ChatPhotoAccessState? cachedState = _cachedAccessState;

    // 이번 앱 실행 중 이미 사용자가 결정을 내렸다면
    // 시스템 권한 요청을 다시 호출하지 않는다.
    if (cachedState != null) {
      return Future<ChatPhotoAccessState>.value(cachedState);
    }

    final Future<ChatPhotoAccessState>? existingRequest =
        _accessRequestInFlight;

    // 빠르게 여러 번 Photo가 눌려도 권한 팝업을
    // 중복 요청하지 않는다.
    if (existingRequest != null) {
      return existingRequest;
    }

    final Future<ChatPhotoAccessState> request = _requestAccessOnce();

    _accessRequestInFlight = request;

    return request;
  }

  Future<ChatPhotoAccessState> _requestAccessOnce() async {
    try {
      final PermissionState permissionState =
          await PhotoManager.requestPermissionExtend(
            requestOption: _permissionOption,
          );

      final ChatPhotoAccessState accessState;

      if (permissionState.isAuth) {
        accessState = ChatPhotoAccessState.authorized;
      } else if (permissionState.hasAccess) {
        accessState = ChatPhotoAccessState.limited;
      } else {
        accessState = ChatPhotoAccessState.denied;
      }

      _cachedAccessState = accessState;

      return accessState;
    } finally {
      _accessRequestInFlight = null;
    }
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: false,
      filterOption: _filterOption,
    );

    _albumEntities
      ..clear()
      ..addEntries(
        paths.map(
          (AssetPathEntity path) =>
              MapEntry<String, AssetPathEntity>(path.id, path),
        ),
      );

    final List<ChatPhotoAlbum> albums = <ChatPhotoAlbum>[];

    for (final AssetPathEntity path in paths) {
      final int count = await path.assetCountAsync;

      if (count == 0) {
        continue;
      }

      final List<AssetEntity> coverAssets = await path.getAssetListPaged(
        page: 0,
        size: 1,
      );

      final AssetEntity? coverAsset = coverAssets.isEmpty
          ? null
          : coverAssets.first;

      if (coverAsset != null) {
        _assetEntities[coverAsset.id] = coverAsset;
      }

      albums.add(
        ChatPhotoAlbum(
          id: path.id,
          name: path.name,
          assetCount: count,
          isAll: path.isAll,
          coverAssetId: coverAsset?.id,
        ),
      );
    }

    final int allAlbumIndex = albums.indexWhere(
      (ChatPhotoAlbum album) => album.isAll,
    );

    if (allAlbumIndex > 0) {
      final ChatPhotoAlbum allAlbum = albums.removeAt(allAlbumIndex);

      albums.insert(0, allAlbum);
    }

    return List<ChatPhotoAlbum>.unmodifiable(albums);
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    AssetPathEntity? path = _albumEntities[albumId];

    if (path == null) {
      await loadAlbums();
      path = _albumEntities[albumId];
    }

    if (path == null) {
      return const <ChatPhotoAsset>[];
    }

    final List<AssetEntity> entities = await path.getAssetListPaged(
      page: page,
      size: pageSize,
    );

    for (final AssetEntity entity in entities) {
      _assetEntities[entity.id] = entity;
    }

    return List<ChatPhotoAsset>.unmodifiable(
      entities.map(
        (AssetEntity entity) => ChatPhotoAsset(
          id: entity.id,
          width: entity.orientatedWidth,
          height: entity.orientatedHeight,
        ),
      ),
    );
  }

  @override
  Future<Uint8List?> loadThumbnail({
    required String assetId,
    required int width,
    required int height,
  }) async {
    final AssetEntity? entity = await _assetEntityFor(assetId);

    if (entity == null) {
      return null;
    }

    return entity.thumbnailDataWithSize(
      ThumbnailSize(width, height),
      format: ThumbnailFormat.jpeg,
      quality: 85,
    );
  }

  @override
  Future<Uint8List?> loadMessagePreview({required String assetId}) async {
    final AssetEntity? entity = await _assetEntityFor(assetId);

    if (entity == null) {
      return null;
    }

    return entity.thumbnailDataWithSize(
      const ThumbnailSize.square(1280),
      format: ThumbnailFormat.jpeg,
      quality: 92,
    );
  }

  Future<AssetEntity?> _assetEntityFor(String assetId) async {
    final AssetEntity? cached = _assetEntities[assetId];

    if (cached != null) {
      return cached;
    }

    final AssetEntity? entity = await AssetEntity.fromId(assetId);

    if (entity != null) {
      _assetEntities[assetId] = entity;
    }

    return entity;
  }

  @override
  Future<void> openSettings() async {
    await PhotoManager.openSetting();
  }
}
