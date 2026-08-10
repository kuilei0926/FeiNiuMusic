import 'dart:async';

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/feiniu/playlist_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_layout_state.dart';
import '../../app/state/settings_playback_state.dart';
import '../../app/state/song_state.dart';
import '../../app/tv/tv_layout.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/deferred_page_init_mixin.dart';
import '../../app/utils/image_crop_helper.dart';
import '../../app/utils/primary_tab_refresh_mixin.dart';
import '../../app/theme/app_styles.dart';
import '../../components/index.dart';
import '../library/library_detail_pages.dart';
import '../songs/song_detail_sheet.dart';

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage>
    with SignalsMixin, DeferredPageInitMixin, PrimaryTabRefreshMixin {
  static const String _prefsSortMode = 'playlists_sort_mode_v1';
  static const String _prefsSortAscending = 'playlists_sort_ascending_v1';
  static const String _prefsGridColumns = 'playlists_grid_columns_v1';

  final FeiNiuPlaylistService _service = FeiNiuPlaylistService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _loading = createSignal(true);
  late final _playlists = createSignal<List<FeiNiuPlaylist>>([]);
  late final _sortMode = createSignal('name');
  late final _ascending = createSignal(true);
  late final _isRefreshing = createSignal(false);
  late final _loadingMore = createSignal(false);
  late final _filteredPlaylists = createSignal<List<FeiNiuPlaylist>>([]);
  late final _gridColumns = createSignal(2);
  List<FeiNiuPlaylist> _allPlaylists = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchVisible = false;

  static const int _pageSize = 100;
  int _currentPage = 1;
  bool _hasMore = true;

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

  void _preloadCovers(List<FeiNiuPlaylist> items, {int count = 20}) {
    if (items.isEmpty || !mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();
    for (final p in items.take(count)) {
      if (p.coverId != null && p.coverId!.isNotEmpty) {
        final url = api.coverUrl(p.coverId!, size: 300, updatedAt: p.updatedAt);
        unawaited(precacheImage(
          CachedNetworkImageProvider(url, headers: headers),
          context,
        ));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    scheduleDeferredInit();
  }

  @override
  Future<void> runDeferredInit() async {
    await _init();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || !_hasMore || _loadingMore.value) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;
    if (maxScroll - offset < 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore.value || !_hasMore) return;
    _loadingMore.value = true;
    _currentPage++;
    try {
      final playlists = await _service.getPlaylistList(
        page: _currentPage,
        size: _pageSize,
      );
      if (!mounted) return;
      _allPlaylists = [..._allPlaylists, ...playlists];
      _hasMore = playlists.length >= _pageSize;
      _applySortFromBase();
    } catch (_) {
      _currentPage--;
    } finally {
      if (mounted) _loadingMore.value = false;
    }
  }

  Future<void> _init() async {
    await _loadPrefs();
    await _load();
  }

  @override
  int get primaryTabIndex => 1;

  @override
  Future<void> onPrimaryTabActivated() async {
    if (mounted) await _load();
  }

  Future<void> _loadPrefs() async {
    // 在首个 await 前取宽，避免跨异步间隙使用 BuildContext。
    final width = AppLayoutSettings.tvMode.value
        ? MediaQuery.sizeOf(context).width
        : 0.0;
    final prefs = await SharedPreferences.getInstance();
    var mode = (prefs.getString(_prefsSortMode) ?? 'name').trim();
    if (mode.isEmpty) mode = 'name';
    final asc = prefs.getBool(_prefsSortAscending) ?? true;
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

  Future<void> _load({bool forceRefresh = false}) async {
    // 分页后首屏只拿第 1 页。缓存 key 保持不变，新的分页数据会直接覆盖旧缓存。
    const cacheKey = 'all';

    Future<List<FeiNiuPlaylist>> fetch() async {
      final playlists = await _service.getPlaylistList(
        page: 1,
        size: _pageSize,
      );
      if (mounted) {
        _currentPage = 1;
        _hasMore = playlists.length >= _pageSize;
      }
      return playlists;
    }

    if (forceRefresh) {
      _isRefreshing.value = true;
      try {
        final playlists = await fetch();
        if (!mounted) return;
        _allPlaylists = playlists;
        _applySortFromBase();
        _preloadCovers(playlists);
        _loading.value = false;
        await ApiCacheManager.instance.set(
          scope: 'playlist_list',
          key: cacheKey,
          jsonData: jsonEncode(playlists.map((p) => p.toJson()).toList()),
        );
      } finally {
        if (mounted) _isRefreshing.value = false;
      }
      return;
    }

    _isRefreshing.value = true;
    try {
      void onData(List<FeiNiuPlaylist>? data) {
        if (mounted) {
          if (data != null) {
            _currentPage = 1;
            _allPlaylists = data;
            _applySortFromBase();
            _preloadCovers(data);
            _loading.value = false;
          }
          _isRefreshing.value = false; // 后台刷新完成
        }
      }

      final cached = await ApiCacheManager.instance.cacheThenNetwork(
        scope: 'playlist_list',
        key: cacheKey,
        fetch: fetch,
        fromJson: (json) => (jsonDecode(json) as List)
            .map((e) => FeiNiuPlaylist.fromJson(e as Map<String, dynamic>))
            .toList(),
        toJson: (data) => jsonEncode(data.map((p) => p.toJson()).toList()),
        fetchCallback: onData,
      );

      if (cached != null) {
        // 缓存命中 → 全屏转圈消失，右上角转圈保持直到后台刷新结束
        if (mounted) {
          _currentPage = 1;
          _allPlaylists = cached;
          _applySortFromBase();
          _preloadCovers(cached);
          _loading.value = false;
        }
      }
    } catch (e) {
      debugPrint('[PlaylistsPage] load error: $e');
      if (mounted) {
        _isRefreshing.value = false;
        _loading.value = false;
      }
    }
  }

  void _applySortFromBase() {
    final playlists = List<FeiNiuPlaylist>.from(_allPlaylists);

    if (_sortMode.value == 'custom') {
      _playlists.value = playlists;
      _applySearch();
      return;
    }

    int compare(FeiNiuPlaylist a, FeiNiuPlaylist b) {
      switch (_sortMode.value) {
        case 'name':
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case 'count':
          return a.trackCount.compareTo(b.trackCount);
        case 'recent':
        default:
          return a.createdAt.compareTo(b.createdAt);
      }
    }

    playlists.sort(compare);
    if (!_ascending.value) {
      _playlists.value = playlists.reversed.toList();
    } else {
      _playlists.value = playlists;
    }
    _applySearch();
  }

  void _applySearch() {
    if (_searchQuery.isEmpty) {
      _filteredPlaylists.value = _playlists.value;
    } else {
      final q = _searchQuery.toLowerCase();
      _filteredPlaylists.value = _playlists.value.where((p) {
        return p.name.toLowerCase().contains(q);
      }).toList();
    }
  }

  Future<void> _createPlaylist() async {
    String? coverId;
    await _showPlaylistNameDialog(
      context,
      title: '新建歌单',
      initial: '',
      confirmText: '创建',
      fallbackName: '新建歌单',
      onCoverUploaded: (id) => coverId = id,
      onSubmit: (name) async {
        await _service.createPlaylist(name, coverId: coverId);
        if (!mounted) return;
        AppToast.show(context, '已创建歌单');
        await _load();
      },
    );
  }

  Future<void> _renamePlaylist(FeiNiuPlaylist playlist) async {
    // 初始化为现有封面：若用户未重新上传，保存时沿用原封面，
    // 避免 coverId 为空导致服务端清空图片。
    String? coverId = playlist.coverId;
    await _showPlaylistNameDialog(
      context,
      title: '编辑歌单',
      initial: playlist.name,
      confirmText: '保存',
      fallbackName: null,
      initialCoverId: playlist.coverId,
      onCoverUploaded: (id) => coverId = id,
      onSubmit: (name) async {
        await _service.editPlaylist(
          guid: playlist.guid,
          name: name,
          coverId: coverId,
        );
        if (!mounted) return;
        AppToast.show(context, '已保存');
        await _load();
      },
    );
  }

  Future<void> _deletePlaylist(FeiNiuPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '删除歌单',
        contentText: '确定删除「${playlist.name}」吗？',
        isDestructive: true,
        onConfirm: () {},
      ),
    );
    if (confirmed != true) return;
    await _service.deletePlaylist(playlist.guid);
    if (!mounted) return;
    AppToast.show(context, '已删除');
    await _load();
  }

  Future<void> _purgeInvalidTracks(FeiNiuPlaylist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '清除无效歌曲',
        contentText: '确定清除「${playlist.name}」中已失效的歌曲吗？',
        isDestructive: true,
        confirmText: '清除',
        onConfirm: () {},
      ),
    );
    if (confirmed != true) return;
    try {
      final count = await _service.purgeInvalidTracks(playlist.guid);
      if (!mounted) return;
      AppToast.show(context, count > 0 ? '已清除 $count 首无效歌曲' : '未发现无效歌曲');
      await _load();
    } catch (e) {
      debugPrint('[PlaylistsPage] purge invalid tracks error: $e');
      if (!mounted) return;
      AppToast.show(context, '清除失败', type: ToastType.error);
    }
  }

  void _showPlaylistSheet(FeiNiuPlaylist playlist) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return AppSheetPanel(
          title: playlist.name,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppListTile(
                leading: const Icon(Icons.cleaning_services_rounded),
                title: '清除无效歌曲',
                onTap: () {
                  Navigator.of(context).pop();
                  _purgeInvalidTracks(playlist);
                },
              ),
              AppListTile(
                leading: const Icon(Icons.edit_rounded),
                title: '编辑',
                onTap: () {
                  Navigator.of(context).pop();
                  _renamePlaylist(playlist);
                },
              ),
              AppListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red,
                ),
                title: '删除',
                titleColor: Colors.red,
                onTap: () {
                  Navigator.of(context).pop();
                  _deletePlaylist(playlist);
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return SortSheet(
          title: '歌单排序',
          options: const [
            SortOption(
              key: 'recent',
              label: '创建时间',
              icon: Icons.schedule_rounded,
            ),
            SortOption(
              key: 'name',
              label: '名称',
              icon: Icons.sort_by_alpha_rounded,
            ),
            SortOption(
              key: 'count',
              label: '歌曲数量',
              icon: Icons.queue_music_rounded,
            ),
          ],
          currentKey: _sortMode.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortMode.value = value;
            _applySortFromBase();
            _savePrefs();
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _applySortFromBase();
            _savePrefs();
          },
          extra: Watch.builder(
            builder: (context) {
              // 平板/Windows 大屏列数自适应，隐藏手动列数选择（TV 仍用自定义列数）。
              if (AppLayoutSettings.effectiveTabletMode &&
                  !AppLayoutSettings.tvMode.value) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    // TV 大屏给更多列选项（4/5/6），手机/平板保持 2/3/4。
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
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '我的歌单',
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
            IconButton(
              icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
              onPressed: () {
                setState(() {
                  _searchVisible = !_searchVisible;
                  if (!_searchVisible) {
                    _searchController.clear();
                    _searchQuery = '';
                    _applySearch();
                  }
                });
              },
            ),
            SortActionButton(onTap: _showSortSheet),
            IconButton(
              tooltip: '新建歌单',
              icon: const Icon(Icons.add),
              onPressed: _createPlaylist,
            ),
            const SizedBox(width: 8),
          ],
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 1 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        body: Column(
          children: [
            if (_searchVisible)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (v) {
                    setState(() => _searchQuery = v);
                    _applySearch();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索歌单...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                              _applySearch();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Theme.of(context).appPanelColor,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                      borderSide: BorderSide.none,
                    ),
                    isDense: true,
                  ),
                ),
              ),
            Expanded(
              child: Watch.builder(
                builder: (context) => RefreshIndicator(
                  onRefresh: _load,
                  child: _loading.value
                      ? const Center(child: CircularProgressIndicator())
                      : _filteredPlaylists.value.isEmpty
                      ? const Center(child: Text('暂无歌单'))
                      : CustomScrollView(
                          controller: _scrollController,
                          slivers: [
                            const SliverToBoxAdapter(child: SizedBox(height: 8)),
                            SliverPadding(
                              padding: AppLayoutSettings.tvMode.value
                                  ? TvLayout.pagePadding()
                                  : const EdgeInsets.fromLTRB(12, 0, 12, 160),
                              sliver: SliverGrid(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    if (index >=
                                        _filteredPlaylists.value.length) {
                                      return const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(8),
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                    final p =
                                        _filteredPlaylists.value[index];
                                    return InkWell(
                                      key: ValueKey(p.guid),
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: () async {
                                        await Navigator.of(context).push(
                                          buildAppPageRoute(
                                            (_) => PlaylistDetailPage(
                                              playlistId: p.guid,
                                              playlistName: p.name,
                                            ),
                                          ),
                                        );
                                        if (!mounted) return;
                                        await _load();
                                      },
                                      onLongPress: () => _showPlaylistSheet(p),
                                      child: Padding(
                                        padding: const EdgeInsets.all(4),
                                        child: LayoutBuilder(
                                          builder: (context, constraints) {
                                            const gapAfterArtwork = 8.0;
                                            const titleStyle = TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              height: 1.1,
                                            );

                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Expanded(
                                                  child: LayoutBuilder(
                                                    builder: (context, box) {
                                                      final size = box.maxWidth
                                                          .clamp(
                                                            0.0,
                                                            box.maxHeight
                                                                .clamp(
                                                                  0.0,
                                                                  double
                                                                      .infinity,
                                                                ),
                                                          );
                                                      if (size <= 0) {
                                                        return const SizedBox
                                                            .shrink();
                                                      }
                                                      return Align(
                                                        alignment:
                                                            Alignment.topLeft,
                                                        child: _PlaylistCover(
                                                          coverId: p.coverId,
                                                          updatedAt: p.updatedAt,
                                                          size: size,
                                                          borderRadius: 16,
                                                          playlistName: p.name,
                                                          placeholder:
                                                              const SizedBox
                                                                  .shrink(),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                                const SizedBox(
                                                  height: gapAfterArtwork,
                                                ),
                                                Text(
                                                  p.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: titleStyle,
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                  childCount: _filteredPlaylists.value.length +
                                      (_loadingMore.value ? 1 : 0),
                                ),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: _adaptiveGridColumns(context),
                                  crossAxisSpacing: 14,
                                  mainAxisSpacing:
                                      _gridMainAxisSpacingForColumns(
                                    _adaptiveGridColumns(context),
                                  ),
                                  childAspectRatio:
                                      _gridAspectRatioForColumns(
                                    _adaptiveGridColumns(context),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌单封面（大图标网格用）。有封面显示图片，无封面显示首字母占位。
class _PlaylistCover extends StatelessWidget {
  final String? coverId;
  final int? updatedAt;
  final double size;
  final double borderRadius;
  final String playlistName;
  final Widget placeholder;

  const _PlaylistCover({
    required this.coverId,
    this.updatedAt,
    required this.size,
    required this.borderRadius,
    required this.playlistName,
    required this.placeholder,
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
          child: Icon(
            Icons.queue_music_rounded,
            size: size * 0.35,
            color: theme.colorScheme.primary.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    final coverUrl = FeiNiuApiClient.instance.coverUrl(
      coverId!,
      size: 300,
      updatedAt: updatedAt,
    );
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

class PlaylistDetailPage extends StatefulWidget {
  final String playlistId;
  final String playlistName;

  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.playlistName = '歌单',
  });

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage>
    with SignalsMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuPlaylistService _service = FeiNiuPlaylistService.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;

  late final _loading = createSignal(true);
  late final _loadingMore = createSignal(false);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _originalSongs = createSignal<List<SongEntity>>([]);
  late final _showCovers = createSignal(true);
  late final _isSequentialPlay = createSignal(false);
  late final _multiSelect = createSignal(false);
  late final _selectedIds = createSignal<Set<String>>({});
  late final _sortKey = createSignal('default');
  late final _sortAscending = createSignal(true);
  final ScrollController _scrollController = ScrollController();

  static const int _pageSize = 100;
  int _currentPage = 1;
  int _total = 0;
  bool _hasMore = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || !_hasMore || _loadingMore.value) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final offset = _scrollController.offset;
    if (maxScroll - offset < 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore.value || !_hasMore) return;
    _loadingMore.value = true;
    await _fetchAndAppendNextPage();
    if (mounted) _loadingMore.value = false;
  }

  /// 拉取下一页并追加到列表（同时维护 _songs 与 _originalSongs）。
  /// 返回是否有新增数据。供滚动加载（_loadMore）与「按数量加载」共用。
  Future<bool> _fetchAndAppendNextPage() async {
    _currentPage++;
    try {
      final pageData = await _api.getPlaylistTracks(
        playlistGUID: widget.playlistId,
        page: _currentPage,
        size: _pageSize,
      );
      if (!mounted) return false;
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t))
          .toList();
      _total = pageData.total;
      _songs.value = [..._songs.value, ...songs];
      _originalSongs.value = [..._originalSongs.value, ...songs];
      _hasMore = _songs.value.length < _total;
      return songs.isNotEmpty;
    } catch (_) {
      _currentPage--;
      return false;
    }
  }

  /// 按目标数量加载：循环整页 _pageSize 直到达到 target 或没有更多。
  Future<void> _loadMoreToTarget(int target) async {
    if (_loadingMore.value || target <= _songs.value.length) return;
    _loadingMore.value = true;
    try {
      while (mounted && _songs.value.length < target && _hasMore) {
        if (!await _fetchAndAppendNextPage()) break;
      }
    } finally {
      if (mounted) _loadingMore.value = false;
    }
  }

  /// 点击数量显示 → 弹出输入对话框，按用户指定的数量加载。
  Future<void> _showLoadMoreDialog() async {
    final loaded = _songs.value.length;
    if (_total <= loaded) return;
    final target = await LoadMoreCountDialog.show(
      context,
      currentCount: loaded,
      maxTotal: _total,
      title: '歌单加载更多',
    );
    if (target == null || !mounted || target <= loaded) return;
    await _loadMoreToTarget(target);
  }

  /// 拉取「已加载页之后」的第 [page] 页歌单歌曲（供填充播放使用）。
  Future<List<SongEntity>> _fetchPlaylistPage(int page) async {
    final pageData = await _api.getPlaylistTracks(
      playlistGUID: widget.playlistId,
      page: _currentPage + page,
      size: _pageSize,
    );
    return pageData.list
        .map((t) => _trackService.trackToSongEntity(t))
        .toList();
  }

  /// 按队列上限循环拉满整个歌单（供 header 顺序/随机播放共用）。
  Future<List<SongEntity>> _fetchFilledSongs() async {
    final full = List<SongEntity>.from(_songs.value);
    final cap = AppPlaybackQueueSettings.maxQueueLength.value.clamp(10, 1000);
    var page = 1;
    while (full.length < cap) {
      final songs = await _fetchPlaylistPage(page++);
      if (songs.isEmpty) break;
      full.addAll(songs);
    }
    if (full.length > cap) full.removeRange(cap, full.length);
    return full;
  }

  Future<void> _load() async {
    _loading.value = true;
    try {
      final pageData = await _api.getPlaylistTracks(
        playlistGUID: widget.playlistId,
        page: 1,
        size: _pageSize,
      );
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t))
          .toList();
      if (!mounted) return;
      _currentPage = 1;
      _total = pageData.total;
      // total 未知（服务端未返回）时退化为「首屏取满一页即认为还有更多」
      final totalKnown = _total > 0;
      _hasMore = totalKnown ? songs.length < _total : songs.length >= _pageSize;
      _songs.value = songs;
      _originalSongs.value = List<SongEntity>.from(songs);
      _loading.value = false;
    } catch (e) {
      debugPrint('[PlaylistDetailPage] load error: $e');
      if (mounted) _loading.value = false;
    }
  }

  List<SongEntity> _sortedSongs(List<SongEntity> songs) {
    if (_sortKey.value == 'default') return songs;
    final list = List<SongEntity>.from(songs);
    int cmp(SongEntity a, SongEntity b) {
      switch (_sortKey.value) {
        case 'title':
          return a.title.compareTo(b.title);
        case 'artist':
          return a.artist.compareTo(b.artist);
        case 'album':
          return (a.album ?? '').compareTo(b.album ?? '');
        default:
          return 0;
      }
    }

    list.sort((a, b) => _sortAscending.value ? cmp(a, b) : -cmp(a, b));
    return list;
  }

  Future<void> _showSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SortSheet(
        options: const [
          SortOption(key: 'default', label: '添加时间', icon: Icons.sort),
          SortOption(key: 'title', label: '歌曲名称', icon: Icons.sort_by_alpha),
          SortOption(key: 'artist', label: '歌手名称', icon: Icons.person_outline),
          SortOption(key: 'album', label: '专辑名称', icon: Icons.album_outlined),
        ],
        currentKey: _sortKey.value,
        ascending: _sortAscending.value,
        onSelectKey: (key) {
          if (_sortKey.value != key) {
            _sortKey.value = key;
            _sortAscending.value = true;
          }
          _songs.value = key == 'default'
              ? _originalSongs.value
              : _sortedSongs(_songs.value);
        },
        onSelectAscending: (asc) {
          _sortAscending.value = asc;
          _songs.value = _sortKey.value == 'default'
              ? _originalSongs.value
              : _sortedSongs(_songs.value);
        },
      ),
    );
  }

  void _toggleSelectAll() {
    if (_songs.value.isEmpty) return;
    if (_selectedIds.value.length == _songs.value.length) {
      _selectedIds.value = {};
    } else {
      _selectedIds.value = _songs.value.map((e) => e.id).toSet();
    }
  }

  void _toggleMultiSelect() {
    _multiSelect.value = !_multiSelect.value;
    _selectedIds.value = {};
  }

  void _togglePlayMode() {
    _isSequentialPlay.value = !_isSequentialPlay.value;
    AppToast.show(context, _isSequentialPlay.value ? '已切换为顺序播放' : '已切换为随机播放');
  }

  Future<void> _removeSong(SongEntity song) async {
    try {
      await _service.removeTrack(widget.playlistId, song.id);
      if (!mounted) return;
      AppToast.show(context, '已移除');
      await _load();
    } catch (e) {
      if (mounted) AppToast.show(context, '移除失败', type: ToastType.error);
    }
  }

  Future<void> _removeSongsByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      // 批量移除：一次请求提交全部，避免多选几十首时逐首发请求
      await _service.removeTracks(widget.playlistId, ids);
      if (!mounted) return;
      final idSet = ids.toSet();
      _songs.value = _songs.value.where((s) => !idSet.contains(s.id)).toList();
      _originalSongs.value =
          _originalSongs.value.where((s) => !idSet.contains(s.id)).toList();
      _selectedIds.value = Set<String>.from(_selectedIds.value)
        ..removeAll(idSet);
      AppToast.show(context, '已移除 ${ids.length} 首');
    } catch (e) {
      debugPrint('[PlaylistDetailPage] remove tracks error: $e');
      if (!mounted) return;
      AppToast.show(context, '移除失败', type: ToastType.error);
    }
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final player = PlayerService.instance;
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        extendBodyBehindAppBar: true,
        showMiniPlayer: !_multiSelect.value,
        appBar: AppTopBar(
          title: widget.playlistName,
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Watch.builder(
          builder: (context) {
            final canReorder =
                _multiSelect.value && _sortKey.value == 'default';
            // 全选按已加载歌曲数判断（未加载的无法选中）；
            // 头部播放计数用歌单真实总数（服务端 total），分页时仍显示完整数量。
            final totalCount = _songs.value.length;
            final selectedCount = _selectedIds.value.length;
            final isAllSelected = totalCount > 0 && selectedCount == totalCount;
            final playbackTotal = _total > totalCount ? _total : totalCount;
            final bottomInset =
                MediaQuery.of(context).padding.bottom +
                (_multiSelect.value ? 160 : 80);
            return _loading.value
                ? const Center(child: CircularProgressIndicator())
                : _songs.value.isEmpty
                ? const Center(child: Text('歌单为空'))
                : Column(
                    children: [
                      MediaListHeader(
                        multiSelect: _multiSelect.value,
                        isAllSelected: isAllSelected,
                        selectedCount: selectedCount,
                        totalCount: totalCount,
                        playbackCount: playbackTotal,
                        isSequentialPlay: _isSequentialPlay.value,
                        onToggleSelectAll: _toggleSelectAll,
                        onPlay: () async {
                          if (_songs.value.isEmpty) return;
                          // 按队列上限拉满整个歌单再播放（顺序或随机）
                          final full = await _fetchFilledSongs();
                          final queue = List<SongEntity>.from(full);
                          if (!_isSequentialPlay.value) {
                            queue.shuffle();
                          }
                          await player.playQueue(queue, 0);
                        },
                        onConfigurePlay: () {},
                        onTogglePlayMode: _togglePlayMode,
                        onSort: _showSortSheet,
                        onToggleMultiSelect: _toggleMultiSelect,
                      ),
                      if (_hasMore && _total > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                          child: Row(
                            children: [
                              LoadMoreCountText(
                                text:
                                    '已加载 ${_songs.value.length} / 共 $_total 首',
                                style: TextStyle(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                                onTap: _showLoadMoreDialog,
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: EdgeInsets.only(bottom: bottomInset),
                          itemCount:
                              _songs.value.length + (_loadingMore.value ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _songs.value.length) {
                              return const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final song = _songs.value[index];
                            return _buildSongTile(
                              context,
                              player: player,
                              song: song,
                              index: index,
                              canReorder: canReorder,
                            );
                          },
                        ),
                      ),
                      if (_multiSelect.value)
                        MultiSelectBottomBar(
                          actions: [
                            MultiSelectAction(
                              icon: Icons.queue_play_next,
                              label: '下一首播放',
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final selected = _songs.value
                                          .where(
                                            (s) => _selectedIds.value.contains(
                                              s.id,
                                            ),
                                          )
                                          .toList();
                                      await player.insertNext(selected);
                                      if (!context.mounted) return;
                                      AppToast.show(
                                        context,
                                        '已将 ${_selectedIds.value.length} 首歌曲加入下一首播放',
                                      );
                                      _toggleMultiSelect();
                                    },
                            ),
                            MultiSelectAction(
                              icon: Icons.playlist_add,
                              label: '添加到歌单',
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final ids = _selectedIds.value.toList();
                                      final added =
                                          await showAddToPlaylistDialog(
                                            context,
                                            songIds: ids,
                                          );
                                      if (!mounted) return;
                                      if (added) _toggleMultiSelect();
                                    },
                            ),
                            MultiSelectAction(
                              icon: Icons.favorite_border_rounded,
                              label: '添加到收藏',
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final ids = _selectedIds.value.toList();
                                      final failed = await FeiNiuFavoriteService
                                          .instance
                                          .favoriteAll(ids);
                                      if (!context.mounted) return;
                                      final ok = ids.length - failed;
                                      AppToast.show(
                                        context,
                                        failed == 0
                                            ? '已收藏 $ok 首歌曲'
                                            : '已收藏 $ok 首，$failed 首失败',
                                        type: failed == 0
                                            ? ToastType.success
                                            : ToastType.error,
                                      );
                                      _toggleMultiSelect();
                                    },
                            ),
                            MultiSelectAction(
                              icon: Icons.delete_outline,
                              label: '移出',
                              isDestructive: true,
                              onTap: _selectedIds.value.isEmpty
                                  ? null
                                  : () async {
                                      final confirmed = await showDialog<bool>(
                                        context: context,
                                        builder: (ctx) {
                                          return AlertDialog(
                                            title: const Text('移出选中歌曲'),
                                            content: Text(
                                              '确定要从歌单中移出这 ${_selectedIds.value.length} 首歌曲吗？',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  ctx,
                                                ).pop(false),
                                                child: const Text('取消'),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(ctx).pop(true),
                                                style: TextButton.styleFrom(
                                                  foregroundColor: Colors.red,
                                                ),
                                                child: const Text('移出'),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                      if (confirmed != true) return;
                                      final ids = _selectedIds.value.toList();
                                      await _removeSongsByIds(ids);
                                      if (!mounted) return;
                                      _toggleMultiSelect();
                                    },
                            ),
                          ],
                        ),
                    ],
                  );
          },
        ),
        bottomNavIndex: useBottomNavigation ? 1 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
      ),
    );
  }

  Widget _buildSongTile(
    BuildContext context, {
    required PlayerService player,
    required SongEntity song,
    required int index,
    required bool canReorder,
  }) {
    return ValueListenableBuilder<SongEntity?>(
      valueListenable: player.currentSong,
      builder: (context, current, _) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        final isCurrent = current?.id == song.id;
        final isSelected = _selectedIds.value.contains(song.id);
        final titleColor = isCurrent
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface;
        final subtitleColor = isCurrent
            ? theme.colorScheme.primary
            : (isDark
                  ? Colors.white70
                  : const Color.fromARGB(255, 100, 100, 100));

        final tile = AppListTile(
          leading: SizedBox(
            width: 48,
            height: 48,
            child: _multiSelect.value
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      isSelected ? Icons.check_circle : Icons.circle_outlined,
                      size: 20,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.disabledColor,
                    ),
                  )
                : _coverOrIndex(context, song, index, subtitleColor),
          ),
          title: song.title,
          subtitle: song.artistDisplayName,
          titleColor: titleColor,
          trailing: null,
          onTap: () async {
            if (_multiSelect.value) {
              final next = _selectedIds.value.toSet();
              if (isSelected) {
                next.remove(song.id);
              } else {
                next.add(song.id);
              }
              _selectedIds.value = next;
              return;
            }
            await player.playQueueFilledToLimit(
              _songs.value,
              index,
              fetchMore: _fetchPlaylistPage,
            );
          },
          onLongPress: () {
            showModalBottomSheet<void>(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => SongDetailSheet(
                song: song,
                onUpdated: (_) => _load(),
                onOpenArtist: (artistName) {
                  Navigator.of(context).push(
                    buildAppPageRoute(
                      (_) => ArtistDetailPage(artistName: artistName),
                    ),
                  );
                },
                onOpenAlbum: (albumName) {
                  Navigator.of(context).push(
                    buildAppPageRoute(
                      (_) => AlbumDetailPage(
                        albumName: albumName,
                        albumGuid: song.albumGuid,
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );

        if (_multiSelect.value) return tile;

        return Dismissible(
          key: Key('playlist_${widget.playlistId}_${song.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            color: Colors.red,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (direction) async {
            return await showDialog<bool>(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: const Text('移除歌曲'),
                  content: const Text('确定要从歌单中移除这首歌曲吗？'),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('移除'),
                    ),
                  ],
                );
              },
            );
          },
          onDismissed: (direction) async {
            await _removeSong(song);
          },
          child: tile,
        );
      },
    );
  }

  Widget _coverOrIndex(
    BuildContext context,
    SongEntity song,
    int index,
    Color subtitleColor,
  ) {
    if (!_showCovers.value) {
      return Center(
        child: Text(
          '${index + 1}',
          style: TextStyle(
            fontSize: 16,
            color: subtitleColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return ArtworkWidget(
      song: song,
      size: 48,
      borderRadius: 4,
      placeholder: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          song.title.trim().isEmpty
              ? '?'
              : song.title.trim().substring(0, 1).toUpperCase(),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class PlaylistPickerSheet extends StatefulWidget {
  final List<String> songIds;

  const PlaylistPickerSheet({super.key, required this.songIds});

  @override
  State<PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<PlaylistPickerSheet>
    with SignalsMixin {
  final FeiNiuPlaylistService _service = FeiNiuPlaylistService.instance;

  late final _loading = createSignal(true);
  late final _playlists = createSignal<List<FeiNiuPlaylist>>([]);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _loading.value = true;
    final playlists = await _service.getPlaylistList();
    if (!mounted) return;
    _playlists.value = playlists;
    _loading.value = false;
  }

  Future<void> _createAndAdd() async {
    await _showPlaylistNameDialog(
      context,
      title: '新建歌单',
      initial: '',
      confirmText: '创建',
      fallbackName: '新建歌单',
      onSubmit: (name) async {
        final created = await _service.createPlaylist(name);
        await _service.addTracks(created.guid, widget.songIds);
        if (!mounted) return;
        AppToast.show(context, '已收藏到歌单');
        Future.delayed(const Duration(milliseconds: 80), () {
          if (!mounted) return;
          Navigator.of(context).pop(true);
        });
      },
    );
  }

  Future<void> _addToPlaylist(FeiNiuPlaylist playlist) async {
    await _service.addTracks(playlist.guid, widget.songIds);
    if (!mounted) return;
    AppToast.show(context, '已收藏到歌单');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetPanel(
      title: '选择歌单',
      expand: true,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Watch.builder(
        builder: (context) => _loading.value
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: [
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('新建歌单'),
                    onTap: _createAndAdd,
                  ),
                  const Divider(height: 1),
                  if (_playlists.value.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('暂无歌单')),
                    )
                  else
                    ..._playlists.value.map(
                      (p) => ListTile(
                        leading: p.coverId != null && p.coverId!.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CachedNetworkImage(
                                  imageUrl: FeiNiuApiClient.instance
                                      .coverUrl(p.coverId!, size: 48, updatedAt: p.updatedAt),
                                  httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                                  width: 40,
                                  height: 40,
                                  memCacheWidth: 40,
                                  memCacheHeight: 40,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) =>
                                      Icon(Icons.queue_music_rounded, color: Theme.of(context).colorScheme.primary),
                                ),
                              )
                            : Icon(Icons.queue_music_rounded, color: Theme.of(context).colorScheme.primary),
                        title: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: null,
                        onTap: () => _addToPlaylist(p),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

Future<bool> showAddToPlaylistDialog(
  BuildContext context, {
  required List<String> songIds,
}) async {
  final ids = songIds.where((e) => e.trim().isNotEmpty).toList();
  if (ids.isEmpty) return false;

  final service = FeiNiuPlaylistService.instance;
  final playlists = await service.getPlaylistList();
  if (!context.mounted) return false;

  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AppDialog(
        title: '添加到歌单',
        confirmText: '新建歌单',
        onConfirm: () {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (!context.mounted) return;
            _showPlaylistNameDialog(
              context,
              title: '新建歌单',
              initial: '',
              confirmText: '创建',
              fallbackName: '新建歌单',
              onSubmit: (name) async {
                final created = await service.createPlaylist(name);
                await service.addTracks(created.guid, ids);
                if (!context.mounted) return;
                AppToast.show(context, '已添加到歌单: ${created.name}');
              },
            );
          });
        },
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: playlists.isEmpty
              ? const Center(
                  child: Text('暂无歌单', style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return AppListTile(
                      leading: playlist.coverId != null &&
                              playlist.coverId!.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: CachedNetworkImage(
                                imageUrl: FeiNiuApiClient.instance.coverUrl(
                                  playlist.coverId!,
                                  size: 48,
                                  updatedAt: playlist.updatedAt,
                                ),
                                httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
                                width: 40,
                                height: 40,
                                memCacheWidth: 40,
                                memCacheHeight: 40,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => Icon(
                                  Icons.queue_music,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            )
                          : Icon(
                              Icons.queue_music,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      title: playlist.name,
                      subtitle: null,
                      onTap: () async {
                        await service.addTracks(playlist.guid, ids);
                        if (!context.mounted) return;
                        Navigator.pop(dialogContext, true);
                        AppToast.show(context, '已添加到歌单: ${playlist.name}');
                      },
                    );
                  },
                ),
        ),
      );
    },
  );
  return result == true;
}

Future<void> _showPlaylistNameDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required String confirmText,
  required String? fallbackName,
  required Future<void> Function(String name) onSubmit,
  String? initialCoverId,
  void Function(String coverId)? onCoverUploaded,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _PlaylistNameDialog(
          title: title,
          initial: initial,
          confirmText: confirmText,
          fallbackName: fallbackName,
          onSubmit: onSubmit,
          initialCoverId: initialCoverId,
          onCoverUploaded: onCoverUploaded,
        ),
      );
    },
  );
}

class _PlaylistNameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String confirmText;
  final String? fallbackName;
  final Future<void> Function(String name) onSubmit;
  final String? initialCoverId;
  final void Function(String coverId)? onCoverUploaded;

  const _PlaylistNameDialog({
    required this.title,
    required this.initial,
    required this.confirmText,
    required this.fallbackName,
    required this.onSubmit,
    this.initialCoverId,
    this.onCoverUploaded,
  });

  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final TextEditingController _controller;
  String? _coverId;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _coverId = widget.initialCoverId;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 从本地相册/文件选择图片，裁剪为正方形后上传，得到 coverId。
  Future<void> _pickCover() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final file = result?.files.first;
    if (file?.path == null) return;

    // 正方形裁剪，与歌单封面展示比例一致
    final cropped = await cropCoverImage(
      sourcePath: file!.path!,
      ratioX: 1,
      ratioY: 1,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '裁剪封面',
          hideBottomControls: true,
          lockAspectRatio: true,
          toolbarColor: const Color(0xFF212121),
          statusBarLight: false,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: Colors.white,
          backgroundColor: Colors.black,
        ),
        IOSUiSettings(
          title: '裁剪封面',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    if (cropped == null || !mounted) return;

    setState(() {}); // 关闭加载态
    try {
      final coverId = await FeiNiuPlaylistService.instance
          .uploadCoverFromFile(cropped.path);
      if (!mounted) return;
      setState(() => _coverId = coverId);
      widget.onCoverUploaded?.call(coverId);
      if (mounted) AppToast.show(context, '封面上传成功');
    } catch (e) {
      debugPrint('[PlaylistNameDialog] upload cover error: $e');
      if (mounted) {
        AppToast.show(context, '封面上传失败', type: ToastType.error);
      }
    }
  }

  Future<void> _submit() async {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty && widget.fallbackName == null) return;
    final name = trimmed.isEmpty ? widget.fallbackName! : trimmed;
    await widget.onSubmit(name);
  }

  Future<void> _submitAndClose() async {
    await _submit();
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// 封面占位图（未选择时显示"随机封面"提示）
  Widget _coverPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 28,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 4),
          Text(
            '随机封面',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return AppSheetPanel(
      title: widget.title,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 封面选择：默认随机封面（占位图），点击从本地相册选择并裁剪上传
          Center(
            child: GestureDetector(
              onTap: _pickCover,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: theme.appPanelColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant,
                    width: 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _coverId != null && _coverId!.isNotEmpty
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          CachedNetworkImage(
                            imageUrl: FeiNiuApiClient.instance.coverUrl(
                              _coverId!,
                              size: 200,
                            ),
                            httpHeaders:
                                FeiNiuApiClient.imageAuthHeaders(),
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => _coverPlaceholder(),
                          ),
                          const Positioned(
                            right: 6,
                            bottom: 6,
                            child: CircleAvatar(
                              radius: 14,
                              backgroundColor: Colors.black54,
                              child: Icon(
                                Icons.edit_rounded,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      )
                    : _coverPlaceholder(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '歌单名称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submitAndClose(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withAlpha(20)
                          : Colors.grey.withAlpha(26),
                      foregroundColor: isDark ? Colors.white70 : Colors.black87,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      elevation: 0,
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      elevation: 0,
                    ),
                    onPressed: _submitAndClose,
                    child: Text(
                      widget.confirmText,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
