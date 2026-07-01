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
  }) : assets = List<ChatPhotoAsset>.unmodifiable(assets);

  final List<ChatPhotoAsset> assets;
  final bool collage;
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

  final GestureDragStartCallback?
      onHandleDragStart;

  final GestureDragUpdateCallback?
      onHandleDragUpdate;

  final GestureDragEndCallback?
      onHandleDragEnd;

  @override
  State<ChatPhotoPicker> createState() {
    return _ChatPhotoPickerState();
  }
}

final class _ChatPhotoPickerState extends State<ChatPhotoPicker> {
  static const int _pageSize = 60;
  static const int _maximumSelectionCount = 10;

  final ScrollController _gridController = ScrollController();

  final List<ChatPhotoAlbum> _albums = <ChatPhotoAlbum>[];

  final List<ChatPhotoAsset> _assets = <ChatPhotoAsset>[];

  final List<ChatPhotoAsset> _selectedAssets = <ChatPhotoAsset>[];

  ChatPhotoAccessState? _accessState;
  ChatPhotoAlbum? _selectedAlbum;

  int _nextPage = 0;

  bool _initializing = true;
  bool _loadingMore = false;
  bool _hasMoreAssets = true;
  bool _sending = false;
  bool _collagePhotos = true;

  bool _albumListOpen = false;

  String? _errorMessage;

  @override
  void initState() {
    super.initState();

    _gridController.addListener(_handleGridScroll);

    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(
    ChatPhotoPicker oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.expanded &&
        !widget.expanded &&
        _albumListOpen) {
      _albumListOpen = false;
    }
  }

  @override
  void dispose() {
    _gridController
      ..removeListener(_handleGridScroll)
      ..dispose();

    super.dispose();
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

      final List<ChatPhotoAlbum> albums = await widget.photoLibrary
          .loadAlbums();

      if (!mounted) {
        return;
      }

      if (albums.isEmpty) {
        setState(() {
          _accessState = accessState;
          _initializing = false;
          _errorMessage =
              accessState == ChatPhotoAccessState.limited
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
    }
  }

  Future<void> _loadFirstPage(ChatPhotoAlbum album) async {
    setState(() {
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
    }
  }

  Future<void> _loadMoreAssets() async {
    final ChatPhotoAlbum? album = _selectedAlbum;

    if (album == null || _loadingMore || !_hasMoreAssets) {
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

      setState(() {
        _assets.addAll(
          nextPage.where(
            (ChatPhotoAsset asset) => !existingIds.contains(asset.id),
          ),
        );

        _nextPage++;
        _hasMoreAssets = nextPage.length == _pageSize;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingMore = false;
        });
      }
    }
  }

  void _handleGridScroll() {
    if (!_gridController.hasClients || _loadingMore || !_hasMoreAssets) {
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

    setState(() {
      _sending = true;
    });

    try {
      await widget.onSend(
        ChatPhotoSelectionResult(
          assets: _selectedAssets,
          collage: _collagePhotos,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  String get _selectedAlbumLabel {
    final ChatPhotoAlbum? album =
        _selectedAlbum;

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

  Future<void> _selectAlbum(
    ChatPhotoAlbum album,
  ) async {
    setState(() {
      _albumListOpen = false;
    });

    if (album.id == _selectedAlbum?.id) {
      return;
    }

    await _loadFirstPage(album);
  }

  @override
  Widget build(BuildContext context) {
    final BorderRadius panelRadius =
        widget.expanded
        ? const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
          )
        : BorderRadius.zero;

    return SizedBox.expand(
      child: Material(
        key: const ValueKey<String>(
          'photo-picker',
        ),
        color: AppColors.white,
        borderRadius: panelRadius,
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            GestureDetector(
              key: const ValueKey<String>(
                'photo-picker-handle-area',
              ),
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart:
                  widget.onHandleDragStart,
              onVerticalDragUpdate:
                  widget.onHandleDragUpdate,
              onVerticalDragEnd:
                  widget.onHandleDragEnd,
              child: SizedBox(
                height: 25,
                width: double.infinity,
                child: Center(
                  child: Container(
                    key: const ValueKey<String>(
                      'photo-picker-handle',
                    ),
                    width: 38,
                    height: 5,
                    decoration:
                        const BoxDecoration(
                      color: AppColors.grey400,
                      borderRadius:
                          BorderRadius.all(
                        Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _buildHeader(),
            const Divider(
              height: 1,
              thickness: 1,
              color: AppColors.grey100,
            ),
            Expanded(
              child: _buildBody(),
            ),
            if (_accessState !=
                ChatPhotoAccessState.denied)
              _buildCollageControl(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final int selectedCount =
        _selectedAssets.length;

    final bool canSend =
        selectedCount > 0 && !_sending;

    final Widget title;

    if (widget.expanded) {
      title = Material(
        key: const ValueKey<String>(
          'photo-album-dropdown',
        ),
        color: Colors.transparent,
        child: InkWell(
          borderRadius:
              const BorderRadius.all(
            Radius.circular(16),
          ),
          onTap: _toggleAlbumList,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(
                    maxWidth: 180,
                  ),
                  child: Text(
                    _selectedAlbumLabel,
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                    style: AppTypography
                        .typography5
                        .copyWith(
                      color: AppColors.grey900,
                      fontWeight:
                          AppTypography.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  _albumListOpen
                      ? Icons
                            .keyboard_arrow_up_rounded
                      : Icons
                            .keyboard_arrow_down_rounded,
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
        key: const ValueKey<String>(
          'photo-picker-title',
        ),
        style:
            AppTypography.typography5.copyWith(
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
          Align(
            alignment: Alignment.center,
            child: title,
          ),
          Positioned(
            left: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                key: const ValueKey<String>(
                  'photo-picker-close',
                ),
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
                key: const ValueKey<String>(
                  'photo-picker-send',
                ),
                color: canSend
                    ? AppColors.blue500
                    : AppColors.grey100,
                borderRadius:
                    const BorderRadius.all(
                      Radius.circular(22),
                    ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: canSend
                      ? () {
                          unawaited(
                            _sendSelection(),
                          );
                        }
                      : null,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(
                      minWidth: 72,
                    ),
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 9,
                      ),
                      child: _sending
                          ? const Center(
                              child: SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.white,
                                ),
                              ),
                            )
                          : Text(
                              selectedCount == 0
                                  ? 'Send'
                                  : '$selectedCount Send',
                              textAlign: TextAlign.center,
                              style: AppTypography
                                  .subTypography10
                                  .copyWith(
                                color: canSend
                                    ? AppColors.white
                                    : AppColors.grey500,
                                fontWeight:
                                    AppTypography.semibold,
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
          padding: const EdgeInsets.symmetric(
            horizontal: 32,
          ),
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
                style:
                    AppTypography.subTypography10.copyWith(
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
      children: [
        Positioned.fill(
          child: GridView.builder(
            key: const ValueKey<String>('photo-grid'),
            controller: _gridController,
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: _assets.length + (_loadingMore ? 1 : 0),
            itemBuilder: (BuildContext context, int index) {
              if (index >= _assets.length) {
                return const Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.blue500,
                    ),
                  ),
                );
              }

              final ChatPhotoAsset asset = _assets[index];

              final int selectedIndex = _selectionIndex(asset);

              return _PhotoGridTile(
                asset: asset,
                photoLibrary: widget.photoLibrary,
                selectedNumber: selectedIndex < 0 ? null : selectedIndex + 1,
                onTap: () {
                  _toggleAsset(asset);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumList() {
    return ListView.separated(
      key: const ValueKey<String>(
        'photo-album-list',
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
      ),
      itemCount: _albums.length,
      separatorBuilder: (
        BuildContext context,
        int index,
      ) {
        return const Divider(
          height: 1,
          indent: 76,
          color: AppColors.grey100,
        );
      },
      itemBuilder: (
        BuildContext context,
        int index,
      ) {
        final ChatPhotoAlbum album =
            _albums[index];

        final String albumName = album.isAll
            ? 'Recents'
            : album.name;

        return InkWell(
          key: ValueKey<String>(
            'photo-album-row-${album.id}',
          ),
          onTap: () {
            unawaited(
              _selectAlbum(album),
            );
          },
          child: SizedBox(
            height: 88,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.all(
                    Radius.circular(4),
                  ),
                  child: SizedBox.square(
                    dimension: 60,
                    child:
                        album.coverAssetId == null
                        ? const ColoredBox(
                            color:
                                AppColors.grey100,
                            child: Icon(
                              Icons
                                  .photo_outlined,
                              color:
                                  AppColors.grey500,
                            ),
                          )
                        : _PhotoThumbnail(
                            assetId:
                                album.coverAssetId!,
                            photoLibrary:
                                widget.photoLibrary,
                            size: 180,
                          ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisSize:
                        MainAxisSize.min,
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        albumName,
                        maxLines: 1,
                        overflow:
                            TextOverflow.ellipsis,
                        style: AppTypography
                            .typography5
                            .copyWith(
                          color:
                              AppColors.grey900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${album.assetCount}',
                        style: AppTypography
                            .subTypography10
                            .copyWith(
                          color:
                              AppColors.grey500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (album.id ==
                    _selectedAlbum?.id)
                  const Icon(
                    Icons.check_rounded,
                    color: AppColors.blue500,
                  ),
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
        minimum: const EdgeInsets.fromLTRB(
          20,
          6,
          20,
          10,
        ),
        child: InkWell(
          key: const ValueKey<String>(
            'photo-collage-toggle',
          ),
          borderRadius:
              const BorderRadius.all(
            Radius.circular(12),
          ),
          onTap: () {
            setState(() {
              _collagePhotos =
                  !_collagePhotos;
            });
          },
          child: SizedBox(
            height: 54,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(
                    milliseconds: 140,
                  ),
                  width: 25,
                  height: 25,
                  decoration: BoxDecoration(
                    color: _collagePhotos
                        ? AppColors.blue500
                        : AppColors.white,
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
                  style: AppTypography
                      .subTypography10
                      .copyWith(
                    color: AppColors.grey900,
                    fontWeight:
                        AppTypography.medium,
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

final class _PhotoGridTile extends StatelessWidget {
  const _PhotoGridTile({
    required this.asset,
    required this.photoLibrary,
    required this.selectedNumber,
    required this.onTap,
  });

  final ChatPhotoAsset asset;
  final ChatPhotoLibrary photoLibrary;
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
            _PhotoThumbnail(
              assetId: asset.id,
              photoLibrary: photoLibrary,
              size: 320,
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
  });

  final String assetId;
  final ChatPhotoLibrary photoLibrary;
  final int size;

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

  Future<Uint8List?> _loadThumbnail() {
    return widget.photoLibrary.loadThumbnail(
      assetId: widget.assetId,
      width: widget.size,
      height: widget.size,
    );
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
