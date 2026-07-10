import 'dart:io';
import 'dart:typed_data';

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

final class ChatPhotoFile {
  const ChatPhotoFile({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
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

  Future<ChatPhotoFile?> loadOriginalFile({required String assetId});

  Future<void> openSettings();
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

  @override
  Future<ChatPhotoFile?> loadOriginalFile({required String assetId}) async {
    final AssetEntity? entity = await _assetEntityFor(assetId);

    if (entity == null) {
      return null;
    }

    final File? file = await entity.file;

    if (file == null) {
      return null;
    }

    final Uint8List bytes = await file.readAsBytes();

    if (bytes.isEmpty) {
      return null;
    }

    final String fallbackName = '$assetId.jpg';
    final String? entityTitle = entity.title;
    final String fileName =
        entityTitle == null || entityTitle.isEmpty ? fallbackName : entityTitle;

    return ChatPhotoFile(
      bytes: bytes,
      fileName: fileName,
      mimeType: _imageMimeTypeForFileName(fileName),
      sizeBytes: bytes.length,
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

String _imageMimeTypeForFileName(String fileName) {
  final String lowerCase = fileName.toLowerCase();

  if (lowerCase.endsWith('.png')) {
    return 'image/png';
  }

  if (lowerCase.endsWith('.heic')) {
    return 'image/heic';
  }

  if (lowerCase.endsWith('.webp')) {
    return 'image/webp';
  }

  return 'image/jpeg';
}
