import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

enum ChatPhotoAccessState { authorized, limited, denied }

enum ChatPhotoAssetType { image, video }

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
    this.createdAt,
    this.type = ChatPhotoAssetType.image,
    this.duration = Duration.zero,
  });

  final String id;
  final int width;
  final int height;
  final DateTime? createdAt;
  final ChatPhotoAssetType type;
  final Duration duration;

  bool get isVideo => type == ChatPhotoAssetType.video;
}

final class ChatPhotoFile {
  const ChatPhotoFile({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.localPath,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String? localPath;
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

abstract interface class ChatPhotoLibraryPreloader {
  Future<void> preload();

  void invalidateCache();
}

abstract interface class ChatQuickPhotoSource {
  Future<ChatPhotoAccessState> checkAccess();

  Future<ChatPhotoAsset?> loadLatestPhoto();
}

final class ChatPhotoLibraryChange {
  ChatPhotoLibraryChange({
    Iterable<String> createdAssetIds = const <String>[],
    Iterable<String> deletedAssetIds = const <String>[],
    Iterable<String> updatedAssetIds = const <String>[],
  }) : createdAssetIds = Set<String>.unmodifiable(createdAssetIds),
       deletedAssetIds = Set<String>.unmodifiable(deletedAssetIds),
       updatedAssetIds = Set<String>.unmodifiable(updatedAssetIds);

  final Set<String> createdAssetIds;
  final Set<String> deletedAssetIds;
  final Set<String> updatedAssetIds;
}

typedef ChatPhotoLibraryChangeCallback =
    void Function(ChatPhotoLibraryChange change);

abstract interface class ChatPhotoLibraryChangeSource {
  void addChangeListener(ChatPhotoLibraryChangeCallback listener);

  void removeChangeListener(ChatPhotoLibraryChangeCallback listener);
}

final class PhotoManagerChatPhotoLibrary
    implements
        ChatPhotoLibrary,
        ChatPhotoLibraryChangeSource,
        ChatQuickPhotoSource,
        ChatPhotoLibraryPreloader {
  static const int _preloadPageSize = 60;
  static const int _preloadThumbnailCount = 18;
  static const int _maximumThumbnailCacheCount = 160;
  static const PermissionRequestOption _permissionOption =
      PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.readWrite,
        androidPermission: AndroidPermission(
          type: RequestType.common,
          mediaLocation: false,
        ),
      );

  static final Set<PhotoManagerChatPhotoLibrary> _observedLibraries =
      <PhotoManagerChatPhotoLibrary>{};

  static final void Function(MethodCall) _photoManagerChangeCallback =
      _handlePhotoManagerChange;

  static Timer? _stopChangeNotificationsTimer;

  static Future<void>? _startChangeNotificationsInFlight;

  static Future<void>? _stopChangeNotificationsInFlight;

  static bool _changeNotificationsStarted = false;

  final Map<String, AssetPathEntity> _albumEntities =
      <String, AssetPathEntity>{};

  final Map<String, AssetEntity> _assetEntities = <String, AssetEntity>{};

  final Set<ChatPhotoLibraryChangeCallback> _changeListeners =
      <ChatPhotoLibraryChangeCallback>{};

  final Map<String, List<ChatPhotoAsset>> _assetPageCache =
      <String, List<ChatPhotoAsset>>{};

  final Map<String, Future<List<ChatPhotoAsset>>> _assetPageRequests =
      <String, Future<List<ChatPhotoAsset>>>{};

  final Map<String, Uint8List> _thumbnailCache = <String, Uint8List>{};

  final Map<String, Future<Uint8List?>> _thumbnailRequests =
      <String, Future<Uint8List?>>{};

  ChatPhotoAccessState? _cachedAccessState;

  List<ChatPhotoAlbum>? _albumCache;

  Future<ChatPhotoAccessState>? _accessRequestInFlight;

  Future<List<ChatPhotoAlbum>>? _albumRequestInFlight;

  int _cacheVersion = 0;

  static FilterOptionGroup _createFilterOption() {
    // FilterOptionGroup의 기본 생성일 상한은 생성 순간의 DateTime.now()예요.
    // 조회 옵션을 앱 수명 동안 재사용하면 앱 실행 후 추가된 사진이
    // 영구적으로 빠지므로 앨범을 조회할 때마다 새로 만들어요.
    return FilterOptionGroup(
      orders: const <OrderOption>[
        OrderOption(type: OrderOptionType.createDate, asc: false),
      ],
    );
  }

  @override
  void addChangeListener(ChatPhotoLibraryChangeCallback listener) {
    final bool wasEmpty = _changeListeners.isEmpty;

    _changeListeners.add(listener);

    if (!wasEmpty || _changeListeners.isEmpty) {
      return;
    }

    _stopChangeNotificationsTimer?.cancel();
    _stopChangeNotificationsTimer = null;
    _observedLibraries.add(this);

    unawaited(_ensureChangeNotificationsStarted());
  }

  @override
  void removeChangeListener(ChatPhotoLibraryChangeCallback listener) {
    _changeListeners.remove(listener);

    if (_changeListeners.isNotEmpty) {
      return;
    }

    _observedLibraries.remove(this);

    if (_observedLibraries.isNotEmpty) {
      return;
    }

    // AnimatedSwitcher로 선택기를 빠르게 닫았다 다시 여는 동안
    // 네이티브 observer를 그대로 유지해요.
    _stopChangeNotificationsTimer?.cancel();
    _stopChangeNotificationsTimer = Timer(
      const Duration(milliseconds: 400),
      () {
        _stopChangeNotificationsTimer = null;
        unawaited(_stopChangeNotificationsIfUnused());
      },
    );
  }

  static Future<void> _ensureChangeNotificationsStarted() async {
    _stopChangeNotificationsTimer?.cancel();
    _stopChangeNotificationsTimer = null;

    final Future<void>? stopping = _stopChangeNotificationsInFlight;

    if (stopping != null) {
      await stopping;
    }

    if (_changeNotificationsStarted || _observedLibraries.isEmpty) {
      return;
    }

    final Future<void>? existing = _startChangeNotificationsInFlight;

    if (existing != null) {
      await existing;
      return;
    }

    final Future<void> request = _startChangeNotificationsOnce();
    _startChangeNotificationsInFlight = request;

    await request;
  }

  static Future<void> _startChangeNotificationsOnce() async {
    PhotoManager.addChangeCallback(_photoManagerChangeCallback);

    try {
      await PhotoManager.startChangeNotify();
      _changeNotificationsStarted = true;
    } catch (_) {
      PhotoManager.removeChangeCallback(_photoManagerChangeCallback);
    } finally {
      _startChangeNotificationsInFlight = null;
    }
  }

  static Future<void> _stopChangeNotificationsIfUnused() async {
    final Future<void>? starting = _startChangeNotificationsInFlight;

    if (starting != null) {
      await starting;
    }

    if (_observedLibraries.isNotEmpty || !_changeNotificationsStarted) {
      return;
    }

    final Future<void>? existing = _stopChangeNotificationsInFlight;

    if (existing != null) {
      await existing;
      return;
    }

    final Future<void> request = _stopChangeNotificationsOnce();
    _stopChangeNotificationsInFlight = request;

    await request;
  }

  static Future<void> _stopChangeNotificationsOnce() async {
    try {
      await PhotoManager.stopChangeNotify();
    } catch (_) {
      // 다음 구독 때 다시 시작할 수 있도록 로컬 상태는 정리해요.
    } finally {
      PhotoManager.removeChangeCallback(_photoManagerChangeCallback);
      _changeNotificationsStarted = false;
      _stopChangeNotificationsInFlight = null;
    }
  }

  static void _handlePhotoManagerChange(MethodCall call) {
    final ChatPhotoLibraryChange change = _changeFromMethodCall(call);

    for (final PhotoManagerChatPhotoLibrary library
        in List<PhotoManagerChatPhotoLibrary>.of(_observedLibraries)) {
      library._notifyChangeListeners(change);
    }
  }

  static ChatPhotoLibraryChange _changeFromMethodCall(MethodCall call) {
    final Object? arguments = call.arguments;

    if (arguments is! Map<Object?, Object?>) {
      return ChatPhotoLibraryChange();
    }

    return ChatPhotoLibraryChange(
      createdAssetIds: _assetIdsFromChange(arguments['create']),
      deletedAssetIds: _assetIdsFromChange(arguments['delete']),
      updatedAssetIds: _assetIdsFromChange(arguments['update']),
    );
  }

  static Iterable<String> _assetIdsFromChange(Object? value) sync* {
    if (value is! Iterable<Object?>) {
      return;
    }

    for (final Object? item in value) {
      if (item is! Map<Object?, Object?>) {
        continue;
      }

      final Object? id = item['id'];

      if (id is String && id.isNotEmpty) {
        yield id;
      }
    }
  }

  void _notifyChangeListeners(ChatPhotoLibraryChange change) {
    invalidateCache();

    for (final ChatPhotoLibraryChangeCallback listener
        in List<ChatPhotoLibraryChangeCallback>.of(_changeListeners)) {
      listener(change);
    }
  }

  @override
  Future<ChatPhotoAccessState> requestAccess() {
    final ChatPhotoAccessState? cachedState = _cachedAccessState;

    // 이번 앱 실행 중 사용자가 이미 결정했다면 시스템 권한 요청을 생략해요.
    if (cachedState != null) {
      return Future<ChatPhotoAccessState>.value(cachedState);
    }

    final Future<ChatPhotoAccessState>? existingRequest =
        _accessRequestInFlight;

    // Photo를 빠르게 여러 번 눌러도 하나의 권한 요청을 함께 사용해요.
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
      final ChatPhotoAccessState accessState = _accessStateFor(permissionState);

      _cachedAccessState = accessState;

      return accessState;
    } finally {
      _accessRequestInFlight = null;
    }
  }

  @override
  Future<ChatPhotoAccessState> checkAccess() async {
    final PermissionState permissionState =
        await PhotoManager.getPermissionState(requestOption: _permissionOption);

    final ChatPhotoAccessState accessState = _accessStateFor(permissionState);
    _cachedAccessState = accessState;

    return accessState;
  }

  @override
  Future<ChatPhotoAsset?> loadLatestPhoto() async {
    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: true,
      filterOption: _createFilterOption(),
    );

    if (paths.isEmpty) {
      return null;
    }

    final List<AssetEntity> entities = await paths.first.getAssetListPaged(
      page: 0,
      size: 1,
    );

    if (entities.isEmpty) {
      return null;
    }

    final AssetEntity entity = entities.first;
    _assetEntities[entity.id] = entity;

    return _photoAssetFor(entity);
  }

  @override
  Future<List<ChatPhotoAlbum>> loadAlbums() {
    final List<ChatPhotoAlbum>? cachedAlbums = _albumCache;

    if (cachedAlbums != null) {
      return Future<List<ChatPhotoAlbum>>.value(cachedAlbums);
    }

    final Future<List<ChatPhotoAlbum>>? existingRequest = _albumRequestInFlight;

    if (existingRequest != null) {
      return existingRequest;
    }

    final Future<List<ChatPhotoAlbum>> request = _loadAlbumsAndCache(
      cacheVersion: _cacheVersion,
    );
    _albumRequestInFlight = request;

    return request;
  }

  Future<List<ChatPhotoAlbum>> _loadAlbumsAndCache({
    required int cacheVersion,
  }) async {
    try {
      final List<ChatPhotoAlbum> albums = await _loadAlbumsFresh(
        cacheVersion: cacheVersion,
      );

      if (_cacheVersion == cacheVersion) {
        _albumCache = albums;
      }

      return albums;
    } finally {
      if (_cacheVersion == cacheVersion) {
        _albumRequestInFlight = null;
      }
    }
  }

  Future<List<ChatPhotoAlbum>> _loadAlbumsFresh({
    required int cacheVersion,
  }) async {
    final FilterOptionGroup filterOption = _createFilterOption();

    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      hasAll: true,
      onlyAll: false,
      filterOption: filterOption,
    );

    final Map<String, AssetPathEntity> albumEntities =
        <String, AssetPathEntity>{
          for (final AssetPathEntity path in paths) path.id: path,
        };
    final Map<String, AssetEntity> coverAssetEntities = <String, AssetEntity>{};

    final List<ChatPhotoAlbum?> loadedAlbums = await Future.wait(
      paths.map((AssetPathEntity path) async {
        final int count = await path.assetCountAsync;

        if (count == 0) {
          return null;
        }

        final List<AssetEntity> coverAssets = await path.getAssetListPaged(
          page: 0,
          size: 1,
        );
        final AssetEntity? coverAsset = coverAssets.isEmpty
            ? null
            : coverAssets.first;

        if (coverAsset != null) {
          coverAssetEntities[coverAsset.id] = coverAsset;
        }

        return ChatPhotoAlbum(
          id: path.id,
          name: path.name,
          assetCount: count,
          isAll: path.isAll,
          coverAssetId: coverAsset?.id,
        );
      }),
    );
    final List<ChatPhotoAlbum> albums = loadedAlbums
        .whereType<ChatPhotoAlbum>()
        .toList();

    final int allAlbumIndex = albums.indexWhere(
      (ChatPhotoAlbum album) => album.isAll,
    );

    if (allAlbumIndex > 0) {
      final ChatPhotoAlbum allAlbum = albums.removeAt(allAlbumIndex);

      albums.insert(0, allAlbum);
    }

    if (_cacheVersion == cacheVersion) {
      _albumEntities
        ..clear()
        ..addAll(albumEntities);
      _assetEntities
        ..clear()
        ..addAll(coverAssetEntities);
    }

    return List<ChatPhotoAlbum>.unmodifiable(albums);
  }

  @override
  Future<List<ChatPhotoAsset>> loadAssets({
    required String albumId,
    required int page,
    required int pageSize,
  }) {
    final String cacheKey = '$albumId:$page:$pageSize';
    final List<ChatPhotoAsset>? cachedAssets = _assetPageCache[cacheKey];

    if (cachedAssets != null) {
      return Future<List<ChatPhotoAsset>>.value(cachedAssets);
    }

    final Future<List<ChatPhotoAsset>>? existingRequest =
        _assetPageRequests[cacheKey];

    if (existingRequest != null) {
      return existingRequest;
    }

    final Future<List<ChatPhotoAsset>> request = _loadAssetsAndCache(
      cacheKey: cacheKey,
      cacheVersion: _cacheVersion,
      albumId: albumId,
      page: page,
      pageSize: pageSize,
    );
    _assetPageRequests[cacheKey] = request;

    return request;
  }

  Future<List<ChatPhotoAsset>> _loadAssetsAndCache({
    required String cacheKey,
    required int cacheVersion,
    required String albumId,
    required int page,
    required int pageSize,
  }) async {
    try {
      final List<ChatPhotoAsset> assets = await _loadAssetsFresh(
        cacheVersion: cacheVersion,
        albumId: albumId,
        page: page,
        pageSize: pageSize,
      );
      if (_cacheVersion == cacheVersion) {
        _assetPageCache[cacheKey] = assets;
      }

      return assets;
    } finally {
      if (_cacheVersion == cacheVersion) {
        _assetPageRequests.remove(cacheKey);
      }
    }
  }

  Future<List<ChatPhotoAsset>> _loadAssetsFresh({
    required int cacheVersion,
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

    if (_cacheVersion == cacheVersion) {
      for (final AssetEntity entity in entities) {
        _assetEntities[entity.id] = entity;
      }
    }

    return List<ChatPhotoAsset>.unmodifiable(entities.map(_photoAssetFor));
  }

  @override
  Future<Uint8List?> loadThumbnail({
    required String assetId,
    required int width,
    required int height,
  }) {
    final String cacheKey = '$assetId:$width:$height';
    final Uint8List? cachedBytes = _thumbnailCache[cacheKey];

    if (cachedBytes != null) {
      return Future<Uint8List?>.value(cachedBytes);
    }

    final Future<Uint8List?>? existingRequest = _thumbnailRequests[cacheKey];

    if (existingRequest != null) {
      return existingRequest;
    }

    final Future<Uint8List?> request = _loadThumbnailAndCache(
      cacheKey: cacheKey,
      cacheVersion: _cacheVersion,
      assetId: assetId,
      width: width,
      height: height,
    );
    _thumbnailRequests[cacheKey] = request;

    return request;
  }

  Future<Uint8List?> _loadThumbnailAndCache({
    required String cacheKey,
    required int cacheVersion,
    required String assetId,
    required int width,
    required int height,
  }) async {
    try {
      final Uint8List? bytes = await _loadThumbnailFresh(
        assetId: assetId,
        width: width,
        height: height,
      );

      if (bytes != null && _cacheVersion == cacheVersion) {
        _thumbnailCache[cacheKey] = bytes;

        if (_thumbnailCache.length > _maximumThumbnailCacheCount) {
          _thumbnailCache.remove(_thumbnailCache.keys.first);
        }
      }

      return bytes;
    } finally {
      if (_cacheVersion == cacheVersion) {
        _thumbnailRequests.remove(cacheKey);
      }
    }
  }

  Future<Uint8List?> _loadThumbnailFresh({
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
  Future<void> preload() async {
    final ChatPhotoAccessState accessState =
        _cachedAccessState ?? await checkAccess();

    if (accessState == ChatPhotoAccessState.denied) {
      return;
    }

    final List<ChatPhotoAlbum> albums = await loadAlbums();

    if (albums.isEmpty) {
      return;
    }

    final ChatPhotoAlbum album = albums.firstWhere(
      (ChatPhotoAlbum album) => album.isAll,
      orElse: () => albums.first,
    );
    final List<ChatPhotoAsset> assets = await loadAssets(
      albumId: album.id,
      page: 0,
      pageSize: _preloadPageSize,
    );

    await Future.wait(
      assets
          .take(_preloadThumbnailCount)
          .map(
            (ChatPhotoAsset asset) =>
                loadThumbnail(assetId: asset.id, width: 320, height: 320),
          ),
    );
  }

  @override
  void invalidateCache() {
    _cacheVersion += 1;
    _albumCache = null;
    _albumRequestInFlight = null;
    _assetPageCache.clear();
    _assetPageRequests.clear();
    _thumbnailCache.clear();
    _thumbnailRequests.clear();
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

    final String fallbackName = entity.type == AssetType.video
        ? '$assetId.mp4'
        : '$assetId.jpg';
    final String? entityTitle = entity.title;
    final String fileName = entityTitle == null || entityTitle.isEmpty
        ? fallbackName
        : entityTitle;

    return ChatPhotoFile(
      bytes: bytes,
      fileName: fileName,
      mimeType: entity.type == AssetType.video
          ? videoMimeTypeForFileName(fileName)
          : imageMimeTypeForFileName(fileName),
      sizeBytes: bytes.length,
      localPath: file.path,
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

  static ChatPhotoAccessState _accessStateFor(PermissionState permissionState) {
    if (permissionState.isAuth) {
      return ChatPhotoAccessState.authorized;
    }

    if (permissionState.hasAccess) {
      return ChatPhotoAccessState.limited;
    }

    return ChatPhotoAccessState.denied;
  }

  static ChatPhotoAsset _photoAssetFor(AssetEntity entity) {
    return ChatPhotoAsset(
      id: entity.id,
      width: entity.orientatedWidth,
      height: entity.orientatedHeight,
      createdAt: entity.createDateTime,
      type: entity.type == AssetType.video
          ? ChatPhotoAssetType.video
          : ChatPhotoAssetType.image,
      duration: entity.type == AssetType.video
          ? entity.videoDuration
          : Duration.zero,
    );
  }
}

String imageMimeTypeForFileName(String fileName) {
  final String mimeType = mimeTypeForFileName(fileName);
  return mimeType.startsWith('image/') ? mimeType : 'image/jpeg';
}

String videoMimeTypeForFileName(String fileName) {
  final String mimeType = mimeTypeForFileName(fileName);
  return mimeType.startsWith('video/') ? mimeType : 'video/mp4';
}

String mimeTypeForFileName(String fileName) {
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
