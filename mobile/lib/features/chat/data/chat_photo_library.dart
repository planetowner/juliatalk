import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
    this.createdAt,
  });

  final String id;
  final int width;
  final int height;
  final DateTime? createdAt;
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
        ChatQuickPhotoSource {
  static const PermissionRequestOption _permissionOption =
      PermissionRequestOption(
        iosAccessLevel: IosAccessLevel.readWrite,
        androidPermission: AndroidPermission(
          type: RequestType.image,
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

  ChatPhotoAccessState? _cachedAccessState;

  Future<ChatPhotoAccessState>? _accessRequestInFlight;

  static FilterOptionGroup _createFilterOption() {
    // FilterOptionGroup의 기본 생성일 상한은 생성 순간의 DateTime.now()다.
    // 조회 옵션을 앱 수명 동안 재사용하면 앱 실행 후 추가된 사진이
    // 영구적으로 제외되므로 앨범을 조회할 때마다 새로 만든다.
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
    // 네이티브 observer를 불필요하게 중단했다 재시작하지 않는다.
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
      // 다음 구독 때 다시 시작할 수 있도록 로컬 상태는 정리한다.
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
    for (final ChatPhotoLibraryChangeCallback listener
        in List<ChatPhotoLibraryChangeCallback>.of(_changeListeners)) {
      listener(change);
    }
  }

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

    return _accessStateFor(permissionState);
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
  Future<List<ChatPhotoAlbum>> loadAlbums() async {
    final FilterOptionGroup filterOption = _createFilterOption();

    final List<AssetPathEntity> paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      hasAll: true,
      onlyAll: false,
      filterOption: filterOption,
    );

    _albumEntities
      ..clear()
      ..addEntries(
        paths.map(
          (AssetPathEntity path) =>
              MapEntry<String, AssetPathEntity>(path.id, path),
        ),
      );

    _assetEntities.clear();

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

    return List<ChatPhotoAsset>.unmodifiable(entities.map(_photoAssetFor));
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
    final String fileName = entityTitle == null || entityTitle.isEmpty
        ? fallbackName
        : entityTitle;

    return ChatPhotoFile(
      bytes: bytes,
      fileName: fileName,
      mimeType: imageMimeTypeForFileName(fileName),
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
    );
  }
}

String imageMimeTypeForFileName(String fileName) {
  final String mimeType = mimeTypeForFileName(fileName);
  return mimeType.startsWith('image/') ? mimeType : 'image/jpeg';
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
