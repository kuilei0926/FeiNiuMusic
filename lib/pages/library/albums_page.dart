import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart';

import '../../app/router/app_page_route.dart';
import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/state/settings_state.dart';
import '../../app/tv/tv_layout.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/deferred_page_init_mixin.dart';
import '../../components/index.dart';
import '../../pages/search/search_page.dart';
import 'library_detail_pages.dart';
import 'library_metadata.dart';

class AlbumsPage extends StatefulWidget {
  const AlbumsPage({super.key});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

// Exposed so the app-wide warm-up path can pre-compute the default grouping
// while the user is still on Home / Songs. Keep in sync with _AlbumsPageState.
const String albumsCacheScope = 'albums_groups';
const String albumsPrefsSortMode = 'albums_sort_mode_v1';
const String albumsPrefsSortAscending = 'albums_sort_ascending_v1';
// 默认按歌曲数降序（用户要求）。API 排序参数走 _apiSortParam()，客户端不再重排。
const String albumsDefaultSortMode = 'trackCount';
const bool albumsDefaultAscending = false;

class AlbumGroup {
  final String name;
  final int songCount;
  final FeiNiuAlbum album;
  final String? coverId;

  AlbumGroup.fromFeiNiuAlbum(FeiNiuAlbum a)
      : name = a.name,
        songCount = a.trackCount ?? 0,
        album = a,
        coverId = a.coverId;

  AlbumGroup.fromFeiNiuAlbumJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        songCount = json['songCount'] as int? ?? 0,
        album = FeiNiuAlbum.fromJson(json['album'] as Map<String, dynamic>),
        coverId = json['coverId'] as String?;

  Map<String, dynamic> toJson() => {
        'name': name,
        'songCount': songCount,
        'album': album.toJson(),
        'coverId': coverId,
      };
}

class _AlbumsPageState extends State<AlbumsPage>
    with SignalsMixin, DeferredPageInitMixin {
  static const String _prefsSortMode = albumsPrefsSortMode;
  static const String _prefsSortAscending = albumsPrefsSortAscending;
  static const String _prefsGridColumns = 'albums_grid_columns_v1';

  final ScrollController _gridController = ScrollController();
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _loading = createSignal(true);
  late final _loadingMore = createSignal(false);
  late final _isRefreshing = createSignal(false);
  late final _groups = createSignal<List<AlbumGroup>>([]);
  late final _sortMode = createSignal(albumsDefaultSortMode);
  late final _ascending = createSignal(albumsDefaultAscending);
  late final _gridColumns = createSignal(2);

  int _currentPage = 1;
  bool _hasMore = true;
  int _total = 0;
  static const int _pageSize = 100;

  late final _indexPreviewLetter = createSignal<String?>(null);
  late final _indexPreviewVisible = createSignal(false);
  Timer? _indexPreviewTimer;

  double _gridAspectRatioForColumns(int cols) {
    // TV 模式：正方形封面 + 标题，比例取 TvLayout（0.84~0.88），
    // 避免 0.5 时封面下方空出大段空白。
    if (AppLayoutSettings.tvMode.value) {
      return TvLayout.cardAspectRatio(cols);
    }
    // 平板/Windows 大屏：卡片更宽，比例相应拉大，避免正方形封面下方留白。
    if (AppLayoutSettings.effectiveTabletMode) {
      return switch (cols) {
        3 => 0.82,
        4 => 0.74,
        5 => 0.62,
        _ => 0.88,
      };
    }
    if (cols == 2) return 0.76;
    if (cols == 3) return 0.65;
    if (cols == 5) return 0.52;
    if (cols == 6) return 0.5;
    return 0.57;
  }

  /// 平板/Windows 大屏下按可用宽度自适应列数（手机端仍用用户手动选择）。
  int _adaptiveGridColumns(BuildContext context) {
    if (AppLayoutSettings.effectiveTabletMode &&
        !AppLayoutSettings.tvMode.value) {
      final width = MediaQuery.sizeOf(context).width;
      if (width >= 1400) return 5;
      if (width >= 1000) return 4;
      return 3;
    }
    return _gridColumns.value;
  }

  double _gridMainAxisSpacingForColumns(int cols) {
    return 12.0;
  }

  @override
  void initState() {
    super.initState();
    _gridController.addListener(_handleScroll);
    scheduleDeferredInit();
  }

  @override
  Future<void> runDeferredInit() async {
    await _init();
  }

  @override
  void dispose() {
    _indexPreviewTimer?.cancel();
    _gridController.removeListener(_handleScroll);
    _gridController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_gridController.hasClients || !_hasMore || _loadingMore.value) return;
    final maxScroll = _gridController.position.maxScrollExtent;
    final offset = _gridController.offset;
    if (maxScroll - offset < 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore.value || !_hasMore) return;
    _loadingMore.value = true;
    _currentPage++;
    try {
      final pageData = await FeiNiuApiClient.instance.getAlbumList(
        page: _currentPage,
        size: _pageSize,
        sort: _apiSortParam(),
      );
      if (!mounted) return;
      _total = pageData.total;
      // 优先用服务端 total 判定；total 未知时退化为「取满一页认为还有更多」
      final totalKnown = _total > 0;
      _hasMore = totalKnown
          ? _groups.value.length + pageData.list.length < _total
          : pageData.list.length >= _pageSize;
      final groups =
          pageData.list.map((a) => AlbumGroup.fromFeiNiuAlbum(a)).toList();
      _groups.value = [..._groups.value, ...groups];
    } catch (_) {
      _currentPage--;
    } finally {
      if (mounted) _loadingMore.value = false;
    }
  }

  void _applyMetadataUpdate(String guid, LibraryEntityMetadata metadata) {
    if (!_groups.value.any((group) => group.album.guid == guid)) return;
    final albums = replaceAlbumMetadata(
      _groups.value.map((group) => group.album).toList(),
      guid,
      metadata,
    );
    final groups = albums.map(AlbumGroup.fromFeiNiuAlbum).toList();
    _groups.value = groups;

    unawaited(
      ApiCacheManager.instance.set(
        scope: 'album_list',
        key: 'page=1&size=$_pageSize',
        jsonData: jsonEncode(
          groups.take(_pageSize).map((group) => group.toJson()).toList(),
        ),
      ),
    );
  }

  Future<void> _init() async {
    await _loadPrefs();
    await _load(forceRefresh: false);
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _activateIndexPreview(String letter) {
    _indexPreviewTimer?.cancel();
    final changed = _indexPreviewLetter.value != letter;
    if (_indexPreviewVisible.value && !changed) return;
    _indexPreviewLetter.value = letter;
    _indexPreviewVisible.value = true;
  }

  void _scheduleHideIndexPreview() {
    _indexPreviewTimer?.cancel();
    _indexPreviewTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _indexPreviewVisible.value = false;
    });
  }

  Future<void> _loadPrefs() async {
    // 在首个 await 前取宽，避免跨异步间隙使用 BuildContext。
    final width = AppLayoutSettings.tvMode.value
        ? MediaQuery.sizeOf(context).width
        : 0.0;
    final prefs = await SharedPreferences.getInstance();
    var mode =
        (prefs.getString(_prefsSortMode) ?? albumsDefaultSortMode).trim();
    if (mode.isEmpty) mode = albumsDefaultSortMode;
    var asc = prefs.getBool(_prefsSortAscending) ?? albumsDefaultAscending;
    // TV 模式：列数按屏幕宽度自适应，不读移动端持久化值（互不串味）。
    if (AppLayoutSettings.tvMode.value) {
      _gridColumns.value = TvLayout.gridColumns(width);
    } else {
      var cols = prefs.getInt(_prefsGridColumns) ?? 2;
      if (cols < 2) cols = 2;
      if (cols > 4) cols = 4;
      _gridColumns.value = cols;
    }
    _sortMode.value = mode;
    _ascending.value = asc;
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSortMode, _sortMode.value);
    await prefs.setBool(_prefsSortAscending, _ascending.value);
    // TV 模式的列数选择不写入移动端持久化，避免污染手机端偏好。
    if (!AppLayoutSettings.tvMode.value) {
      await prefs.setInt(_prefsGridColumns, _gridColumns.value);
    }
  }

  void _preloadCovers(List<AlbumGroup> groups, {int count = 30}) {
    if (groups.isEmpty || !mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();
    for (final g in groups.take(count)) {
      if (g.coverId != null && g.coverId!.isNotEmpty) {
        final url = api.coverUrl(g.coverId!, size: FeiNiuApiClient.coverRequestSize, updatedAt: null);
        unawaited(precacheImage(
          CachedNetworkImageProvider(url, headers: headers),
          context,
        ));
      }
    }
  }

  String _apiSortParam() {
    switch (_sortMode.value) {
      case 'newTrackAddedAt':
        return 'newTrackAddedAt,${_ascending.value ? 'asc' : 'desc'}';
      case 'releaseYear':
        return 'releaseYear,${_ascending.value ? 'asc' : 'desc'}';
      case 'name':
        return 'name,${_ascending.value ? 'asc' : 'desc'}';
      case 'artistName':
        return 'artistName,${_ascending.value ? 'asc' : 'desc'}';
      case 'trackCount':
        return 'trackCount,${_ascending.value ? 'asc' : 'desc'}';
      default:
        return 'newTrackAddedAt,desc';
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    _currentPage = 1;
    _hasMore = true;
    final cacheKey = 'page=1&size=$_pageSize';

    Future<List<AlbumGroup>> fetch() async {
      final pageData = await FeiNiuApiClient.instance.getAlbumList(
        page: 1,
        size: _pageSize,
        sort: _apiSortParam(),
      );
      _total = pageData.total;
      _hasMore = _total > 0
          ? pageData.list.length < _total
          : pageData.list.length >= _pageSize;
      final groups =
          pageData.list.map((a) => AlbumGroup.fromFeiNiuAlbum(a)).toList();
      _ensureUnknownAlbum(groups);
      return groups;
    }

    if (forceRefresh) {
      _isRefreshing.value = true;
      try {
        final groups = await fetch();
        if (mounted) {
          _groups.value = groups;
          _loading.value = false;
          _preloadCovers(groups);
        }
        await ApiCacheManager.instance.set(
          scope: 'album_list',
          key: cacheKey,
          jsonData: jsonEncode(groups.map((g) => g.toJson()).toList()),
        );
      } finally {
        if (mounted) _isRefreshing.value = false;
      }
      return;
    }

    // 非 forceRefresh 模式：有缓存秒加载，无缓存同步等网络
    _isRefreshing.value = true;
    try {
      void onData(List<AlbumGroup>? data) {
        if (mounted) {
          if (data != null) {
            _groups.value = data;
            _loading.value = false;
            _preloadCovers(data);
          }
          _isRefreshing.value = false; // 后台刷新完成
        }
      }

      final cached = await ApiCacheManager.instance.cacheThenNetwork(
        scope: 'album_list',
        key: cacheKey,
        fetch: fetch,
        fromJson: (json) => (jsonDecode(json) as List)
            .map((e) => AlbumGroup.fromFeiNiuAlbumJson(e as Map<String, dynamic>))
            .toList(),
        toJson: (data) => jsonEncode(data.map((g) => g.toJson()).toList()),
        fetchCallback: onData,
      );

      if (cached != null) {
        // 缓存命中 → 全屏转圈消失，右上角转圈保持直到后台刷新结束
        if (mounted) {
          _groups.value = cached;
          _loading.value = false;
          _preloadCovers(cached);
        }
      }
      debugPrint('[AlbumsPage] load complete, groups=${_groups.value.length}, cached=$cached');
    } catch (_) {
      if (!mounted) return;
      _isRefreshing.value = false;
      if (_groups.value.isEmpty) _groups.value = [];
      _loading.value = false;
    }
  }

  /// 分页数据已按服务端 sort 参数排好序（trackCount 等），客户端不再重排，
  /// 只把「未知专辑」固定置顶，保持原有体验。
  void _ensureUnknownAlbum(List<AlbumGroup> groups) {
    final idx = groups.indexWhere((g) => g.name == '未知专辑');
    if (idx >= 0) {
      final unknown = groups.removeAt(idx);
      groups.insert(0, unknown);
    }
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '专辑排序',
          options: const [
            SortOption(key: 'newTrackAddedAt', label: '更新日期', icon: Icons.update),
            SortOption(key: 'releaseYear', label: '发行年份', icon: Icons.calendar_today),
            SortOption(key: 'name', label: '专辑名', icon: Icons.sort_by_alpha),
            SortOption(key: 'artistName', label: '歌手名', icon: Icons.person),
            SortOption(key: 'trackCount', label: '歌曲数', icon: Icons.music_note_outlined),
          ],
          currentKey: _sortMode.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortMode.value = value;
            _savePrefs();
            _load(forceRefresh: true);
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _savePrefs();
            _load(forceRefresh: true);
          },
          extra: Watch.builder(
            builder: (context) {
              // 平板/Windows 大屏列数自适应，隐藏手动列数选择（TV 仍用自定义列数）。
              if (AppLayoutSettings.effectiveTabletMode &&
                  !AppLayoutSettings.tvMode.value) {
                return const SizedBox.shrink();
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetSectionTitle('列数'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      // TV 大屏给更多列选项（4/5/6），手机保持 2/3/4。
                      child: SegmentedButton<int>(
                    segments: AppLayoutSettings.tvMode.value
                        ? const [
                            ButtonSegment(
                              value: 4,
                              label: Text('四列'),
                              icon: Icon(Icons.grid_view_rounded),
                            ),
                            ButtonSegment(
                              value: 5,
                              label: Text('五列'),
                              icon: Icon(Icons.grid_view_rounded),
                            ),
                            ButtonSegment(
                              value: 6,
                              label: Text('六列'),
                              icon: Icon(Icons.grid_view_rounded),
                            ),
                          ]
                        : const [
                            ButtonSegment(
                              value: 2,
                              label: Text('二列'),
                              icon: Icon(Icons.grid_view_rounded),
                            ),
                            ButtonSegment(
                              value: 3,
                              label: Text('三列'),
                              icon: Icon(Icons.grid_view_rounded),
                            ),
                            ButtonSegment(
                              value: 4,
                              label: Text('四列'),
                              icon: Icon(Icons.grid_view_rounded),
                            ),
                          ],
                    selected: {_gridColumns.value},
                    onSelectionChanged: (selection) {
                      final v = selection.first;
                      _gridColumns.value = v;
                      _savePrefs();
                    },
                    showSelectedIcon: false,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _scrollToIndex(int index, BuildContext context) {
    if (!_gridController.hasClients) return;
    const headerHeight = 8.0;
    final screenWidth = MediaQuery.of(context).size.width;
    final cols = _adaptiveGridColumns(context);
    final totalSpacing = 14.0 * (cols - 1);
    final totalPadding = 12.0 + 12.0;
    final itemWidth = (screenWidth - totalPadding - totalSpacing) / cols;
    final aspectRatio = _gridAspectRatioForColumns(cols);
    final itemHeight = itemWidth / aspectRatio;
    final rowHeight = itemHeight + _gridMainAxisSpacingForColumns(cols);
    final rowIndex = (index / cols).floor();
    final offset = rowIndex * rowHeight + headerHeight;
    final max = _gridController.position.maxScrollExtent;
    _gridController.jumpTo(offset.clamp(0.0, max));
  }

  Widget _buildGrid(BuildContext context) {
    final theme = Theme.of(context);
    final showIndexBar = _groups.value.isNotEmpty;
    return Stack(
      children: [
        CustomScrollView(
          controller: _gridController,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverPadding(
              padding: AppLayoutSettings.tvMode.value
                  ? TvLayout.pagePadding()
                  : const EdgeInsets.fromLTRB(12, 0, 12, 160),
              sliver: SliverGrid(
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (index >= _groups.value.length) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }
                  final g = _groups.value[index];
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      Navigator.of(context).push(
                        buildAppPageRoute(
                          (_) => AlbumDetailPage(
                            albumName: g.name,
                            albumGuid: g.album.guid,
                            onMetadataChanged: (metadata) {
                              if (!mounted) return;
                              _applyMetadataUpdate(g.album.guid, metadata);
                            },
                          ),
                        ),
                      );
                    },
                    onLongPress: () {},
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          const gapAfterArtwork = 8.0;
                          const gapAfterTitle = 3.0;
                          const titleStyle = TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          );
                          final subtitleStyle =
                              (theme.textTheme.bodySmall ?? const TextStyle())
                                  .copyWith(
                                    fontSize: 12,
                                    height: 1.1,
                                    color: theme.textTheme.bodySmall?.color
                                        ?.withValues(alpha: 0.7),
                                  );

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, box) {
                                    final size = box.maxWidth.clamp(
                                      0.0,
                                      box.maxHeight.clamp(0.0, double.infinity),
                                    );
                                    if (size <= 0) {
                                      return const SizedBox.shrink();
                                    }
                                    return Align(
                                      alignment: Alignment.topLeft,
                                      child: _AlbumCover(
                                        coverId: g.coverId,
                                        size: size,
                                        borderRadius: 16,
                                        albumName: g.name,
                                        placeholder: const SizedBox.shrink(),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(height: gapAfterArtwork),
                              Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
                              ),
                              const SizedBox(height: gapAfterTitle),
                              Text(
                                '${g.songCount}首',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: subtitleStyle,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  );
                }, childCount: _groups.value.length + (_loadingMore.value ? 1 : 0)),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _adaptiveGridColumns(context),
                  crossAxisSpacing: 14,
                  mainAxisSpacing: _gridMainAxisSpacingForColumns(
                    _adaptiveGridColumns(context),
                  ),
                  childAspectRatio: _gridAspectRatioForColumns(
                    _adaptiveGridColumns(context),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (showIndexBar)
          Positioned(
            right: 0,
            top: 4,
            bottom: 4,
            child: DraggableScrollbar(
              controller: _gridController,
              itemCount: _groups.value.length,
              itemExtent: 0,
              getLabel: (index) {
                final name = _groups.value[index].name;
                if (name == '未知专辑') return '↑';
                return IndexUtils.leadingLetter(name);
              },
              onIndexChanged: _activateIndexPreview,
              onScrollRequest: (index) => _scrollToIndex(index, context),
              onDragEnd: _scheduleHideIndexPreview,
            ),
          ),
        IndexPreview(
          text: _indexPreviewLetter.value ?? '',
          visible: _indexPreviewVisible.value,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '专辑',
          isRefreshing: _isRefreshing.value,
          leading: useBottomNavigation || AppLayoutSettings.tvMode.value
              ? null
              : IconButton(
                  icon: Icon(
                    useBottomNavigation
                        ? Icons.arrow_back_rounded
                        : Icons.menu_rounded,
                  ),
                  onPressed: useBottomNavigation
                      ? () => Navigator.of(context).maybePop()
                      : _openDrawer,
                ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            SortActionButton(onTap: _showSortSheet),
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.pushNamed(context, AppRoutes.search, arguments: SearchCategory.album),
            ),
          ],
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        body: Watch.builder(
          builder: (context) {
            return RefreshIndicator(
              onRefresh: () => _load(forceRefresh: true),
              child: _buildGrid(context),
            );
          },
        ),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
      ),
    );
  }
}

class _AlbumCover extends StatelessWidget {
  final String? coverId;
  final double size;
  final double borderRadius;
  final Widget placeholder;
  final String albumName;

  const _AlbumCover({
    required this.coverId,
    required this.size,
    required this.borderRadius,
    required this.placeholder,
    required this.albumName,
  });

  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (coverId == null || coverId!.isEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: Container(
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          alignment: Alignment.center,
          child: Text(
            albumName.isNotEmpty ? albumName.characters.first.toUpperCase() : '?',
            style: TextStyle(
              fontSize: size * 0.4,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
    }
    final coverUrl =
        FeiNiuApiClient.instance.coverUrl(coverId!, size: FeiNiuApiClient.coverRequestSize);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: CachedNetworkImage(
        imageUrl: coverUrl,
        httpHeaders: _authHeaders(),
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (context, url) =>
            SizedBox(width: size, height: size, child: placeholder),
        errorWidget: (context, url, error) =>
            SizedBox(width: size, height: size, child: placeholder),
      ),
    );
  }
}
