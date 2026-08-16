import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../design_system/app_colors.dart';
import '../../../design_system/app_typography.dart';
import '../data/chat_photo_library.dart';

final class ChatPhotoSelectionResult {
  ChatPhotoSelectionResult({
    required List<ChatPhotoAsset> assets,
    required this.collage,
    Map<String, Uint8List> previewBytesByAssetId = const <String, Uint8List>{},
  }) : assets = List<ChatPhotoAsset>.unmodifiable(assets),
       previewBytesByAssetId = Map<String, Uint8List>.unmodifiable(
         previewBytesByAssetId,
       );

  final List<ChatPhotoAsset> assets;
  final bool collage;
  final Map<String, Uint8List> previewBytesByAssetId;
}

typedef ChatPhotoSendCallback =
    Future<void> Function(ChatPhotoSelectionResult result);

final class ChatPhotoPicker extends StatefulWidget {
  const ChatPhotoPicker({
    required this.photoLibrary,
    required this.onClose,
    required this.onSend,
    this.expanded = false,
    this.onHandleDragStart,
    this.onHandleDragUpdate,
    this.onHandleDragEnd,
    super.key,
  });

  final ChatPhotoLibrary photoLibrary;
  final VoidCallback onClose;
  final ChatPhotoSendCallback onSend;

  final bool expanded;

  final GestureDragStartCallback? onHandleDragStart;

  final GestureDragUpdateCallback? onHandleDragUpdate;

  final GestureDragEndCallback? onHandleDragEnd;

  @override
  State<ChatPhotoPicker> createState() {
    return _ChatPhotoPickerState();
  }
}

final class _ChatPhotoPickerState extends State<ChatPhotoPicker>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const int _pageSize = 60;
  static const int _maximumSelectionCount = 10;
  static const int _gridCrossAxisCount = 3;
  static const double _gridSpacing = 2;
  static const Duration _libraryRefreshDebounceDuration = Duration(
    milliseconds: 180,
  );
  static const Duration _assetTransitionDuration = Duration(milliseconds: 160);

  final ScrollController _gridController = ScrollController();

  late final AnimationController _assetTransitionController;

  final List<ChatPhotoAlbum> _albums = <ChatPhotoAlbum>[];

  final List<ChatPhotoAsset> _assets = <ChatPhotoAsset>[];

  final List<ChatPhotoAsset> _selectedAssets = <ChatPhotoAsset>[];

  final Set<String> _pendingDeletedAssetIds = <String>{};
  final Map<String, Uint8List> _thumbnailBytesByAssetId = <String, Uint8List>{};

  ChatPhotoAccessState? _accessState;
  ChatPhotoAlbum? _selectedAlbum;

  ChatPhotoLibraryChangeSource? _changeSource;

  Timer? _libraryRefreshTimer;

  _PhotoGridTransition? _photoGridTransition;
  List<ChatPhotoAsset>? _queuedAssetSnapshot;

  late AppLifecycleState _appLifecycleState;

  int _nextPage = 0;

  bool _initializing = true;
  bool _loadingMore = false;
  bool _hasMoreAssets = true;
  bool _sending = false;
  bool _refreshingLibrary = false;
  bool _libraryRefreshRequested = false;
  bool _collagePhotos = true;

  bool _albumListOpen = false;

  String? _errorMessage;

  @override
  void initState() {
    super.initState();

    _assetTransitionController = AnimationController(
      vsync: this,
      duration: _assetTransitionDuration,
    )..addStatusListener(_handleAssetTransitionStatus);
    _appLifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

    WidgetsBinding.instance.addObserver(this);
    _gridController.addListener(_handleGridScroll);

    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(ChatPhotoPicker oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.photoLibrary != widget.photoLibrary) {
      _unsubscribeFromLibraryChanges();
      _pendingDeletedAssetIds.clear();
      _thumbnailBytesByAssetId.clear();
      unawaited(_reinitializeForPhotoLibraryChange());
    }

    if (oldWidget.expanded && !widget.expanded && _albumListOpen) {
      _albumListOpen = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _libraryRefreshTimer?.cancel();
    _unsubscribeFromLibraryChanges();
    _assetTransitionController
      ..removeStatusListener(_handleAssetTransitionStatus)
      ..dispose();

    _gridController
      ..removeListener(_handleGridScroll)
      ..dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;

    if (state == AppLifecycleState.resumed) {
      _scheduleLibraryRefresh();
    } else {
      _libraryRefreshTimer?.cancel();
      _libraryRefreshTimer = null;
    }
  }

  Future<void> _reinitializeForPhotoLibraryChange() async {
    if (!mounted) {
      return;
    }

    _assetTransitionController.stop();

    setState(() {
      _photoGridTransition = null;
      _queuedAssetSnapshot = null;
      _accessState = null;
      _selectedAlbum = null;
      _albums.clear();
      _assets.clear();
      _selectedAssets.clear();
      _nextPage = 0;
      _hasMoreAssets = true;
      _initializing = true;
      _errorMessage = null;
    });

    await _initialize();
  }

  void _subscribeToLibraryChanges() {
    if (_changeSource != null) {
      return;
    }

    final Object photoLibrary = widget.photoLibrary;

    if (photoLibrary is! ChatPhotoLibraryChangeSource) {
      return;
    }

    photoLibrary.addChangeListener(_handlePhotoLibraryChange);
    _changeSource = photoLibrary;
  }

  void _unsubscribeFromLibraryChanges() {
    final ChatPhotoLibraryChangeSource? changeSource = _changeSource;

    if (changeSource == null) {
      return;
    }

    changeSource.removeChangeListener(_handlePhotoLibraryChange);
    _changeSource = null;
  }

  void _handlePhotoLibraryChange(ChatPhotoLibraryChange change) {
    _pendingDeletedAssetIds.addAll(change.deletedAssetIds);
    _scheduleLibraryRefresh();
  }

  void _scheduleLibraryRefresh() {
    if (!mounted ||
        _accessState == null ||
        _accessState == ChatPhotoAccessState.denied) {
      return;
    }

    _libraryRefreshRequested = true;
    _libraryRefreshTimer?.cancel();

    if (_appLifecycleState != AppLifecycleState.resumed) {
      _libraryRefreshTimer = null;
      return;
    }

    _libraryRefreshTimer = Timer(_libraryRefreshDebounceDuration, () {
      _libraryRefreshTimer = null;
      unawaited(_refreshLibrary());
    });
  }

  void _schedulePendingLibraryRefresh() {
    if (_libraryRefreshRequested && !_refreshingLibrary) {
      _scheduleLibraryRefresh();
    }
  }

  Future<void> _refreshLibrary() async {
    if (!mounted) {
      return;
    }

    if (_initializing || _loadingMore || _refreshingLibrary) {
      _libraryRefreshRequested = true;
      return;
    }

    _libraryRefreshRequested = false;
    _refreshingLibrary = true;

    try {
      if (widget.photoLibrary case final ChatPhotoLibraryPreloader preloader) {
        preloader.invalidateCache();
      }

      final String? previouslySelectedAlbumId = _selectedAlbum?.id;
      final List<ChatPhotoAlbum> albums = await widget.photoLibrary
          .loadAlbums();

      if (!mounted) {
        return;
      }

      if (albums.isEmpty) {
        setState(() {
          _albums.clear();
          _selectedAlbum = null;
          _selectedAssets.clear();
          _errorMessage = _accessState == ChatPhotoAccessState.limited
              ? 'No photos are currently shared with JuliaTalk.'
              : 'No photos are available on this device.';
          _nextPage = 0;
          _hasMoreAssets = false;
        });

        _applyAssetSnapshot(const <ChatPhotoAsset>[], animate: true);
        _pendingDeletedAssetIds.clear();
        return;
      }

      final ChatPhotoAlbum refreshedAlbum = albums.firstWhere(
        (ChatPhotoAlbum album) => album.id == previouslySelectedAlbumId,
        orElse: () => albums.firstWhere(
          (ChatPhotoAlbum album) => album.isAll,
          orElse: () => albums.first,
        ),
      );

      final bool sameAlbum = refreshedAlbum.id == previouslySelectedAlbumId;
      final int pagesToLoad = sameAlbum && _assets.isNotEmpty
          ? (_assets.length + _pageSize - 1) ~/ _pageSize
          : 1;
      final List<ChatPhotoAsset> refreshedAssets = <ChatPhotoAsset>[];
      final Set<String> refreshedAssetIds = <String>{};

      int loadedPages = 0;
      int lastPageLength = 0;

      for (int page = 0; page < pagesToLoad; page++) {
        final List<ChatPhotoAsset> pageAssets = await widget.photoLibrary
            .loadAssets(
              albumId: refreshedAlbum.id,
              page: page,
              pageSize: _pageSize,
            );

        loadedPages = page + 1;
        lastPageLength = pageAssets.length;

        for (final ChatPhotoAsset asset in pageAssets) {
          if (refreshedAssetIds.add(asset.id)) {
            refreshedAssets.add(asset);
          }
        }

        if (pageAssets.length < _pageSize) {
          break;
        }
      }

      if (!mounted) {
        return;
      }

      // 사용자가 새로고침 도중 다른 앨범을 선택했다면 현재 선택을
      // 유지하고 새 선택을 기준으로 다시 조회해요.
      if (_selectedAlbum?.id != previouslySelectedAlbumId) {
        _libraryRefreshRequested = true;
        return;
      }

      setState(() {
        _albums
          ..clear()
          ..addAll(albums);
        _selectedAlbum = refreshedAlbum;
        _errorMessage = null;
        _nextPage = loadedPages;
        _hasMoreAssets = lastPageLength == _pageSize;
      });

      _applyAssetSnapshot(refreshedAssets, animate: sameAlbum);

      if (_pendingDeletedAssetIds.isNotEmpty) {
        setState(() {
          _selectedAssets.removeWhere(
            (ChatPhotoAsset asset) =>
                _pendingDeletedAssetIds.contains(asset.id),
          );
        });
      }

      _pendingDeletedAssetIds.clear();
    } catch (_) {
      // Photos 조회가 잠시 실패해도 현재 화면을 유지해요.
      // 다음 변경 알림이나 앱 복귀 때 다시 동기화해요.
    } finally {
      _refreshingLibrary = false;

      if (mounted && _libraryRefreshRequested) {
        _scheduleLibraryRefresh();
      }
    }
  }

  void _applyAssetSnapshot(
    List<ChatPhotoAsset> nextAssets, {
    required bool animate,
  }) {
    if (!animate || _initializing || _albumListOpen) {
      _assetTransitionController.stop();

      setState(() {
        _photoGridTransition = null;
        _queuedAssetSnapshot = null;
        _assets
          ..clear()
          ..addAll(nextAssets);
      });

      return;
    }

    if (_assetTransitionController.isAnimating) {
      _queuedAssetSnapshot = List<ChatPhotoAsset>.of(nextAssets);
      return;
    }

    final List<ChatPhotoAsset> previousAssets = List<ChatPhotoAsset>.of(
      _assets,
    );
    final Map<String, int> previousIndexes = <String, int>{
      for (int index = 0; index < previousAssets.length; index++)
        previousAssets[index].id: index,
    };
    final Map<String, int> nextIndexes = <String, int>{
      for (int index = 0; index < nextAssets.length; index++)
        nextAssets[index].id: index,
    };
    final Set<String> addedAssetIds = nextIndexes.keys
        .where((String assetId) => !previousIndexes.containsKey(assetId))
        .toSet();
    final List<_RemovedPhotoGridItem> removedItems = <_RemovedPhotoGridItem>[];
    bool assetsMoved = false;

    for (int index = 0; index < previousAssets.length; index++) {
      final ChatPhotoAsset asset = previousAssets[index];
      final int? nextIndex = nextIndexes[asset.id];

      if (nextIndex == null) {
        final int selectionIndex = _selectionIndex(asset);

        removedItems.add(
          _RemovedPhotoGridItem(
            asset: asset,
            previousIndex: index,
            selectedNumber: selectionIndex < 0 ? null : selectionIndex + 1,
            thumbnailBytes: _thumbnailBytesByAssetId[asset.id],
          ),
        );
      } else if (nextIndex != index) {
        assetsMoved = true;
      }
    }

    if (addedAssetIds.isEmpty && removedItems.isEmpty && !assetsMoved) {
      setState(() {
        _assets
          ..clear()
          ..addAll(nextAssets);
      });

      return;
    }

    final double scrollOffset = _gridController.hasClients
        ? _gridController.position.pixels
        : 0;

    // 각 자산의 이전 인덱스를 유지한 채 새 스냅샷을 먼저 배치해요.
    // 타일은 이전 좌표에서 새 좌표까지 한 타임라인으로 이동해요.
    setState(() {
      _photoGridTransition = _PhotoGridTransition(
        previousIndexes: previousIndexes,
        addedAssetIds: addedAssetIds,
        removedItems: removedItems,
        scrollOffset: scrollOffset,
      );
      _assets
        ..clear()
        ..addAll(nextAssets);
    });

    _assetTransitionController.forward(from: 0);
  }

  void _handleAssetTransitionStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) {
      return;
    }

    final List<ChatPhotoAsset>? queuedSnapshot = _queuedAssetSnapshot;

    setState(() {
      _photoGridTransition = null;
      _queuedAssetSnapshot = null;
    });

    if (queuedSnapshot == null) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) {
        _applyAssetSnapshot(queuedSnapshot, animate: true);
      }
    });
  }

  Future<void> _initialize() async {
    try {
      final ChatPhotoAccessState accessState = await widget.photoLibrary
          .requestAccess();

      if (!mounted) {
        return;
      }

      if (accessState == ChatPhotoAccessState.denied) {
        setState(() {
          _accessState = accessState;
          _initializing = false;
        });

        return;
      }

      _subscribeToLibraryChanges();

      final List<ChatPhotoAlbum> albums = await widget.photoLibrary
          .loadAlbums();

      if (!mounted) {
        return;
      }

      if (albums.isEmpty) {
        setState(() {
          _accessState = accessState;
          _initializing = false;
          _errorMessage = accessState == ChatPhotoAccessState.limited
              ? 'No photos are currently shared with JuliaTalk.'
              : 'No photos are available on this device.';
        });

        return;
      }

      final ChatPhotoAlbum initialAlbum = albums.firstWhere(
        (ChatPhotoAlbum album) => album.isAll,
        orElse: () => albums.first,
      );

      setState(() {
        _accessState = accessState;
        _albums
          ..clear()
          ..addAll(albums);
        _selectedAlbum = initialAlbum;
      });

      await _loadFirstPage(initialAlbum);
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _initializing = false;
        _errorMessage = 'Photos could not be loaded.';
      });
    } finally {
      _schedulePendingLibraryRefresh();
    }
  }

  Future<void> _loadFirstPage(ChatPhotoAlbum album) async {
    _assetTransitionController.stop();

    setState(() {
      _photoGridTransition = null;
      _queuedAssetSnapshot = null;
      _initializing = true;
      _errorMessage = null;
      _nextPage = 0;
      _hasMoreAssets = true;
      _assets.clear();
      _selectedAlbum = album;
    });

    try {
      final List<ChatPhotoAsset> firstPage = await widget.photoLibrary
          .loadAssets(albumId: album.id, page: 0, pageSize: _pageSize);

      if (!mounted || _selectedAlbum?.id != album.id) {
        return;
      }

      setState(() {
        _assets.addAll(firstPage);
        _nextPage = 1;
        _hasMoreAssets = firstPage.length == _pageSize;
        _initializing = false;
      });

      if (_gridController.hasClients) {
        _gridController.jumpTo(0);
      }
    } catch (_) {
      if (!mounted || _selectedAlbum?.id != album.id) {
        return;
      }

      setState(() {
        _initializing = false;
        _errorMessage = 'This album could not be loaded.';
      });
    } finally {
      _schedulePendingLibraryRefresh();
    }
  }

  Future<void> _loadMoreAssets() async {
    final ChatPhotoAlbum? album = _selectedAlbum;

    if (album == null ||
        _loadingMore ||
        _refreshingLibrary ||
        !_hasMoreAssets) {
      return;
    }

    setState(() {
      _loadingMore = true;
    });

    try {
      final List<ChatPhotoAsset> nextPage = await widget.photoLibrary
          .loadAssets(albumId: album.id, page: _nextPage, pageSize: _pageSize);

      if (!mounted || _selectedAlbum?.id != album.id) {
        return;
      }

      final Set<String> existingIds = _assets
          .map((ChatPhotoAsset asset) => asset.id)
          .toSet();
      final List<ChatPhotoAsset> appendedAssets = nextPage
          .where((ChatPhotoAsset asset) => !existingIds.contains(asset.id))
          .toList(growable: false);
      final List<ChatPhotoAsset> nextSnapshot = <ChatPhotoAsset>[
        ..._assets,
        ...appendedAssets,
      ];

      setState(() {
        _nextPage++;
        _hasMoreAssets = nextPage.length == _pageSize;
      });

      _applyAssetSnapshot(nextSnapshot, animate: true);
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });

        _schedulePendingLibraryRefresh();
      }
    }
  }

  void _handleGridScroll() {
    if (!_gridController.hasClients ||
        _loadingMore ||
        _refreshingLibrary ||
        !_hasMoreAssets) {
      return;
    }

    final ScrollPosition position = _gridController.position;

    if (position.pixels >= position.maxScrollExtent - 400) {
      unawaited(_loadMoreAssets());
    }
  }

  int _selectionIndex(ChatPhotoAsset asset) {
    return _selectedAssets.indexWhere(
      (ChatPhotoAsset selectedAsset) => selectedAsset.id == asset.id,
    );
  }

  void _cacheThumbnail(String assetId, Uint8List bytes) {
    _thumbnailBytesByAssetId
      ..remove(assetId)
      ..[assetId] = bytes;

    while (_thumbnailBytesByAssetId.length > 180) {
      _thumbnailBytesByAssetId.remove(_thumbnailBytesByAssetId.keys.first);
    }
  }

  void _toggleAsset(ChatPhotoAsset asset) {
    final int currentIndex = _selectionIndex(asset);

    if (currentIndex >= 0) {
      setState(() {
        _selectedAssets.removeAt(currentIndex);
      });

      return;
    }

    if (_selectedAssets.length >= _maximumSelectionCount) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('You can select up to 10 photos.')),
        );

      return;
    }

    setState(() {
      _selectedAssets.add(asset);
    });
  }

  Future<void> _sendSelection() async {
    if (_selectedAssets.isEmpty || _sending) {
      return;
    }

    _sending = true;

    try {
      await widget.onSend(
        ChatPhotoSelectionResult(
          assets: _selectedAssets,
          collage: _collagePhotos,
          previewBytesByAssetId: <String, Uint8List>{
            for (final ChatPhotoAsset asset in _selectedAssets)
              if (_thumbnailBytesByAssetId.containsKey(asset.id))
                asset.id: _thumbnailBytesByAssetId[asset.id]!,
          },
        ),
      );
    } finally {
      _sending = false;

      if (mounted) {
        _schedulePendingLibraryRefresh();
      }
    }
  }

  String get _selectedAlbumLabel {
    final ChatPhotoAlbum? album = _selectedAlbum;

    if (album == null || album.isAll) {
      return 'Recents';
    }

    return album.name;
  }

  void _toggleAlbumList() {
    setState(() {
      _albumListOpen = !_albumListOpen;
    });
  }

  Future<void> _selectAlbum(ChatPhotoAlbum album) async {
    setState(() {
      _albumListOpen = false;
    });

    if (album.id == _selectedAlbum?.id) {
      return;
    }

    await _loadFirstPage(album);
  }

  Widget _buildPhotoGridTile(
    ChatPhotoAsset asset, {
    int? selectedNumber,
    bool interactive = true,
    Uint8List? thumbnailBytes,
  }) {
    final int selectionIndex = selectedNumber == null
        ? _selectionIndex(asset)
        : -1;
    final int? resolvedSelectedNumber =
        selectedNumber ?? (selectionIndex < 0 ? null : selectionIndex + 1);

    return IgnorePointer(
      ignoring: !interactive,
      child: _PhotoGridTile(
        asset: asset,
        photoLibrary: widget.photoLibrary,
        thumbnailBytes: thumbnailBytes ?? _thumbnailBytesByAssetId[asset.id],
        onThumbnailLoaded: _cacheThumbnail,
        selectedNumber: resolvedSelectedNumber,
        onTap: () {
          _toggleAsset(asset);
        },
      ),
    );
  }

  Offset _photoGridTranslation({
    required int previousIndex,
    required int nextIndex,
    required double itemStep,
  }) {
    final int previousColumn = previousIndex % _gridCrossAxisCount;
    final int previousRow = previousIndex ~/ _gridCrossAxisCount;
    final int nextColumn = nextIndex % _gridCrossAxisCount;
    final int nextRow = nextIndex ~/ _gridCrossAxisCount;

    return Offset(
      (previousColumn - nextColumn) * itemStep,
      (previousRow - nextRow) * itemStep,
    );
  }

  Widget _buildTransitionedPhotoGridTile(
    ChatPhotoAsset asset,
    int index,
    double itemStep,
  ) {
    final _PhotoGridTransition? transition = _photoGridTransition;
    final Widget tile = _buildPhotoGridTile(asset);
    final Key itemKey = ValueKey<String>('photo-grid-item-${asset.id}');

    if (transition == null) {
      return KeyedSubtree(key: itemKey, child: tile);
    }

    final int? previousIndex = transition.previousIndexes[asset.id];
    final bool entering = transition.addedAssetIds.contains(asset.id);
    final Offset initialOffset = previousIndex == null
        ? Offset.zero
        : _photoGridTranslation(
            previousIndex: previousIndex,
            nextIndex: index,
            itemStep: itemStep,
          );

    return KeyedSubtree(
      key: itemKey,
      child: AnimatedBuilder(
        animation: _assetTransitionController,
        child: tile,
        builder: (BuildContext context, Widget? child) {
          final double movementProgress = Curves.easeInOutCubic.transform(
            _assetTransitionController.value,
          );
          Widget result = Transform.translate(
            offset: Offset.lerp(initialOffset, Offset.zero, movementProgress)!,
            child: child,
          );

          if (entering) {
            final double appearanceProgress = Curves.easeOutCubic.transform(
              _assetTransitionController.value,
            );

            result = Opacity(
              opacity: appearanceProgress,
              child: Transform.scale(
                scale: 0.88 + (0.12 * appearanceProgress),
                child: result,
              ),
            );
          }

          return result;
        },
      ),
    );
  }

  Widget _buildRemovedPhotoGridTile(
    _RemovedPhotoGridItem item,
    double itemExtent,
    double itemStep,
    double scrollOffset,
  ) {
    final int column = item.previousIndex % _gridCrossAxisCount;
    final int row = item.previousIndex ~/ _gridCrossAxisCount;

    return Positioned(
      key: ValueKey<String>('photo-grid-removal-${item.asset.id}'),
      left: column * itemStep,
      top: (row * itemStep) - scrollOffset,
      width: itemExtent,
      height: itemExtent,
      child: AnimatedBuilder(
        animation: _assetTransitionController,
        child: _buildPhotoGridTile(
          item.asset,
          selectedNumber: item.selectedNumber,
          interactive: false,
          thumbnailBytes: item.thumbnailBytes,
        ),
        builder: (BuildContext context, Widget? child) {
          final double disappearanceProgress = Curves.easeInCubic.transform(
            _assetTransitionController.value,
          );

          return Opacity(
            opacity: 1 - disappearanceProgress,
            child: Transform.scale(
              scale: 1 - (0.12 * disappearanceProgress),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Widget _buildPhotoGrid() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double itemExtent =
            (constraints.maxWidth -
                ((_gridCrossAxisCount - 1) * _gridSpacing)) /
            _gridCrossAxisCount;
        final double itemStep = itemExtent + _gridSpacing;
        final _PhotoGridTransition? transition = _photoGridTransition;
        final Map<Key, int> indexesByItemKey = <Key, int>{
          for (int index = 0; index < _assets.length; index++)
            ValueKey<String>('photo-grid-item-${_assets[index].id}'): index,
        };
        final Widget grid = GridView.builder(
          key: const ValueKey<String>('photo-asset-grid'),
          controller: _gridController,
          padding: EdgeInsets.zero,
          physics: transition == null
              ? null
              : const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _gridCrossAxisCount,
            mainAxisSpacing: _gridSpacing,
            crossAxisSpacing: _gridSpacing,
          ),
          findChildIndexCallback: (Key key) => indexesByItemKey[key],
          itemCount: _assets.length,
          itemBuilder: (BuildContext context, int index) {
            return _buildTransitionedPhotoGridTile(
              _assets[index],
              index,
              itemStep,
            );
          },
        );
        final Widget interactiveGrid = IgnorePointer(
          ignoring: transition != null,
          child: grid,
        );

        if (transition == null || transition.removedItems.isEmpty) {
          return interactiveGrid;
        }

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(child: interactiveGrid),
            for (final _RemovedPhotoGridItem item in transition.removedItems)
              _buildRemovedPhotoGridTile(
                item,
                itemExtent,
                itemStep,
                transition.scrollOffset,
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius panelRadius = widget.expanded
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
          )
        : BorderRadius.zero;

    return SizedBox.expand(
      child: Material(
        key: const ValueKey<String>('photo-picker'),
        color: AppColors.white,
        borderRadius: panelRadius,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            GestureDetector(
              key: const ValueKey<String>('photo-picker-handle-area'),
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: widget.onHandleDragStart,
              onVerticalDragUpdate: widget.onHandleDragUpdate,
              onVerticalDragEnd: widget.onHandleDragEnd,
              child: SizedBox(
                height: 25,
                width: double.infinity,
                child: Center(
                  child: Container(
                    key: const ValueKey<String>('photo-picker-handle'),
                    width: 38,
                    height: 5,
                    decoration: const BoxDecoration(
                      color: AppColors.grey400,
                      borderRadius: BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                ),
              ),
            ),
            _buildHeader(),
            const Divider(height: 1, thickness: 1, color: AppColors.grey100),
            Expanded(child: _buildBody()),
            if (_accessState != ChatPhotoAccessState.denied)
              _buildCollageControl(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final int selectedCount = _selectedAssets.length;

    final bool canSend = selectedCount > 0 && !_sending;

    final Widget title;

    if (widget.expanded) {
      title = Material(
        key: const ValueKey<String>('photo-album-dropdown'),
        color: Colors.transparent,
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          onTap: _toggleAlbumList,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    _selectedAlbumLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.typography5.copyWith(
                      color: AppColors.grey900,
                      fontWeight: AppTypography.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  _albumListOpen
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 24,
                  color: AppColors.grey900,
                ),
              ],
            ),
          ),
        ),
      );
    } else {
      title = Text(
        'Photo',
        key: const ValueKey<String>('photo-picker-title'),
        style: AppTypography.typography5.copyWith(
          color: AppColors.grey900,
          fontWeight: AppTypography.bold,
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      height: 58,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          Align(alignment: Alignment.center, child: title),
          Positioned(
            left: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                key: const ValueKey<String>('photo-picker-close'),
                tooltip: 'Close photo picker',
                onPressed: widget.onClose,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 29,
                  color: AppColors.grey900,
                ),
              ),
            ),
          ),
          Positioned(
            right: 10,
            top: 0,
            bottom: 0,
            child: Center(
              child: Material(
                key: const ValueKey<String>('photo-picker-send'),
                color: canSend ? AppColors.blue500 : AppColors.grey100,
                borderRadius: const BorderRadius.all(Radius.circular(22)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: Colors.transparent,
                  onTap: canSend
                      ? () {
                          unawaited(_sendSelection());
                        }
                      : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 72),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 9,
                      ),
                      child: Text(
                        selectedCount == 0 ? 'Send' : '$selectedCount Send',
                        textAlign: TextAlign.center,
                        style: AppTypography.subTypography10.copyWith(
                          color: canSend ? AppColors.white : AppColors.grey500,
                          fontWeight: AppTypography.semibold,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_initializing) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppColors.blue500,
        ),
      );
    }

    if (_accessState == ChatPhotoAccessState.denied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 42,
                color: AppColors.grey500,
              ),
              const SizedBox(height: 12),
              Text(
                'Photo access is required.',
                textAlign: TextAlign.center,
                style: AppTypography.subTypography10.copyWith(
                  color: AppColors.grey900,
                  fontWeight: AppTypography.semibold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Allow photo access in settings to choose photos.',
                textAlign: TextAlign.center,
                style: AppTypography.subTypography11.copyWith(
                  color: AppColors.grey600,
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () {
                  unawaited(widget.photoLibrary.openSettings());
                },
                child: const Text('Open Settings'),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.photo_library_outlined,
                size: 44,
                color: AppColors.grey400,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: AppTypography.subTypography10.copyWith(
                  color: AppColors.grey600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_albumListOpen) {
      return _buildAlbumList();
    }

    return Stack(
      key: const ValueKey<String>('photo-grid'),
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: _buildPhotoGrid()),
        if (_loadingMore)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.white,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(7),
                  child: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.blue500,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAlbumList() {
    return ListView.separated(
      key: const ValueKey<String>('photo-album-list'),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _albums.length,
      separatorBuilder: (BuildContext context, int index) {
        return const Divider(height: 1, indent: 76, color: AppColors.grey100);
      },
      itemBuilder: (BuildContext context, int index) {
        final ChatPhotoAlbum album = _albums[index];

        final String albumName = album.isAll ? 'Recents' : album.name;

        return InkWell(
          key: ValueKey<String>('photo-album-row-${album.id}'),
          onTap: () {
            unawaited(_selectAlbum(album));
          },
          child: SizedBox(
            height: 88,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                  child: SizedBox.square(
                    dimension: 60,
                    child: album.coverAssetId == null
                        ? const ColoredBox(
                            color: AppColors.grey100,
                            child: Icon(
                              Icons.photo_outlined,
                              color: AppColors.grey500,
                            ),
                          )
                        : _PhotoThumbnail(
                            assetId: album.coverAssetId!,
                            photoLibrary: widget.photoLibrary,
                            size: 180,
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        albumName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.typography5.copyWith(
                          color: AppColors.grey900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${album.assetCount}',
                        style: AppTypography.subTypography10.copyWith(
                          color: AppColors.grey500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (album.id == _selectedAlbum?.id)
                  const Icon(Icons.check_rounded, color: AppColors.blue500),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCollageControl() {
    return Material(
      color: AppColors.white,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(20, 6, 20, 10),
        child: InkWell(
          key: const ValueKey<String>('photo-collage-toggle'),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          onTap: () {
            setState(() {
              _collagePhotos = !_collagePhotos;
            });
          },
          child: SizedBox(
            height: 54,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: 25,
                  height: 25,
                  decoration: BoxDecoration(
                    color: _collagePhotos ? AppColors.blue500 : AppColors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _collagePhotos
                          ? AppColors.blue500
                          : AppColors.grey300,
                      width: 1.5,
                    ),
                  ),
                  child: _collagePhotos
                      ? const Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: AppColors.white,
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Text(
                  'Collage Photos',
                  style: AppTypography.subTypography10.copyWith(
                    color: AppColors.grey900,
                    fontWeight: AppTypography.medium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _PhotoGridTransition {
  _PhotoGridTransition({
    required Map<String, int> previousIndexes,
    required Set<String> addedAssetIds,
    required List<_RemovedPhotoGridItem> removedItems,
    required this.scrollOffset,
  }) : previousIndexes = Map<String, int>.unmodifiable(previousIndexes),
       addedAssetIds = Set<String>.unmodifiable(addedAssetIds),
       removedItems = List<_RemovedPhotoGridItem>.unmodifiable(removedItems);

  final Map<String, int> previousIndexes;
  final Set<String> addedAssetIds;
  final List<_RemovedPhotoGridItem> removedItems;
  final double scrollOffset;
}

final class _RemovedPhotoGridItem {
  const _RemovedPhotoGridItem({
    required this.asset,
    required this.previousIndex,
    required this.selectedNumber,
    required this.thumbnailBytes,
  });

  final ChatPhotoAsset asset;
  final int previousIndex;
  final int? selectedNumber;
  final Uint8List? thumbnailBytes;
}

final class _PhotoGridTile extends StatelessWidget {
  const _PhotoGridTile({
    required this.asset,
    required this.photoLibrary,
    required this.thumbnailBytes,
    required this.onThumbnailLoaded,
    required this.selectedNumber,
    required this.onTap,
  });

  final ChatPhotoAsset asset;
  final ChatPhotoLibrary photoLibrary;
  final Uint8List? thumbnailBytes;
  final void Function(String assetId, Uint8List bytes) onThumbnailLoaded;
  final int? selectedNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool selected = selectedNumber != null;

    return Material(
      key: ValueKey<String>('photo-tile-${asset.id}'),
      color: AppColors.grey100,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailBytes case final Uint8List bytes)
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
              )
            else
              _PhotoThumbnail(
                assetId: asset.id,
                photoLibrary: photoLibrary,
                size: 320,
                onLoaded: (Uint8List bytes) {
                  onThumbnailLoaded(asset.id, bytes);
                },
              ),
            if (selected) ColoredBox(color: AppColors.black.withAlpha(24)),
            Positioned(
              top: 7,
              right: 7,
              child: _PhotoSelectionBadge(
                assetId: asset.id,
                selectedNumber: selectedNumber,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PhotoSelectionBadge extends StatelessWidget {
  const _PhotoSelectionBadge({
    required this.assetId,
    required this.selectedNumber,
  });

  final String assetId;
  final int? selectedNumber;

  @override
  Widget build(BuildContext context) {
    final int? number = selectedNumber;

    return Container(
      key: ValueKey<String>('photo-selection-badge-$assetId'),
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: number == null
            ? AppColors.white.withAlpha(200)
            : AppColors.blue500,
        shape: BoxShape.circle,
        border: Border.all(
          color: number == null ? AppColors.grey400 : AppColors.blue500,
          width: 1.5,
        ),
      ),
      child: number == null
          ? null
          : Text(
              '$number',
              style: AppTypography.subTypography11.copyWith(
                color: AppColors.white,
                fontWeight: AppTypography.bold,
              ),
            ),
    );
  }
}

final class _PhotoThumbnail extends StatefulWidget {
  const _PhotoThumbnail({
    required this.assetId,
    required this.photoLibrary,
    required this.size,
    this.onLoaded,
  });

  final String assetId;
  final ChatPhotoLibrary photoLibrary;
  final int size;
  final ValueChanged<Uint8List>? onLoaded;

  @override
  State<_PhotoThumbnail> createState() {
    return _PhotoThumbnailState();
  }
}

final class _PhotoThumbnailState extends State<_PhotoThumbnail> {
  late Future<Uint8List?> _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = _loadThumbnail();
  }

  @override
  void didUpdateWidget(_PhotoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.assetId != widget.assetId ||
        oldWidget.photoLibrary != widget.photoLibrary ||
        oldWidget.size != widget.size) {
      _thumbnailFuture = _loadThumbnail();
    }
  }

  Future<Uint8List?> _loadThumbnail() async {
    final Uint8List? bytes = await widget.photoLibrary.loadThumbnail(
      assetId: widget.assetId,
      width: widget.size,
      height: widget.size,
    );

    if (bytes != null) {
      widget.onLoaded?.call(bytes);
    }

    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _thumbnailFuture,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? bytes = snapshot.data;

        if (bytes == null) {
          return const ColoredBox(color: AppColors.grey100);
        }

        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        );
      },
    );
  }
}
