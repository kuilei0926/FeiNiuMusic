import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../components/index.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_layout_state.dart';
import '../../app/state/settings_playback_state.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/primary_tab_refresh_mixin.dart';
import '../../app/theme/app_styles.dart';
import '../library/library_detail_pages.dart';
import '../songs/song_detail_sheet.dart';

class FavoritePage extends StatefulWidget {
  const FavoritePage({super.key});

  @override
  State<FavoritePage> createState() => _FavoritePageState();
}

class _FavoritePageState extends State<FavoritePage>
    with SignalsMixin, SongMultiSelectMixin, PrimaryTabRefreshMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  @override
  List<SongEntity> get multiSelectSongs => _songs.value;

  @override
  void Function(List<String> removedIds)? get onSongsRemovedFromFavorite =>
      _handleSongsRemovedFromFavorite;

  void _handleSongsRemovedFromFavorite(List<String> removedIds) {
    if (removedIds.isEmpty) return;
    final idSet = removedIds.toSet();
    _allSongs.value =
        _allSongs.value.where((s) => !idSet.contains(s.id)).toList();
    _applyFilter();
  }

  late final _allSongs = createSignal<List<SongEntity>>([]);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _loading = createSignal(true);
  late final _isRefreshing = createSignal(false);
  late final _loadingMore = createSignal(false);
  late final _sortKey = createSignal('favoriteAt');
  late final _ascending = createSignal(false);
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchVisible = false;

  static const int _pageSize = 100;
  int _currentPage = 1;
  int _total = 0;
  bool _hasMore = true;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _load();
  }

  @override
  int get primaryTabIndex => 3;

  @override
  Future<void> onPrimaryTabActivated() async {
    if (mounted) await _load();
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

  /// 拉取下一页并追加到列表。返回是否有新增数据。
  /// 供滚动加载（_loadMore）与「按数量加载」（_loadMoreToTarget）共用。
  Future<bool> _fetchAndAppendNextPage() async {
    _currentPage++;
    try {
      final pageData = await _api.getFavoriteList(
        page: _currentPage,
        size: _pageSize,
        sort: '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}',
      );
      if (!mounted) return false;
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      _total = pageData.total;
      _allSongs.value = [..._allSongs.value, ...songs];
      _hasMore = _allSongs.value.length < _total;
      _applyFilter();
      return songs.isNotEmpty;
    } catch (_) {
      _currentPage--;
      return false;
    }
  }

  /// 按目标数量加载：循环整页 _pageSize 直到达到 target 或没有更多。
  Future<void> _loadMoreToTarget(int target) async {
    if (_loadingMore.value || target <= _allSongs.value.length) return;
    _loadingMore.value = true;
    try {
      while (mounted && _allSongs.value.length < target && _hasMore) {
        if (!await _fetchAndAppendNextPage()) break;
      }
    } finally {
      if (mounted) _loadingMore.value = false;
    }
  }

  /// 点击数量显示 → 弹出输入对话框，按用户指定的数量加载。
  Future<void> _showLoadMoreDialog() async {
    final loaded = _allSongs.value.length;
    if (_total <= loaded) return;
    final target = await LoadMoreCountDialog.show(
      context,
      currentCount: loaded,
      maxTotal: _total,
      title: '收藏加载更多',
    );
    if (target == null || !mounted || target <= loaded) return;
    await _loadMoreToTarget(target);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    // 分页后首屏只拿第 1 页。缓存 key 保持不变，新的分页数据会直接覆盖旧缓存。
    const cacheKey = 'all';

    Future<List<SongEntity>> fetch() async {
      final pageData = await _api.getFavoriteList(
        page: 1,
        size: _pageSize,
        sort: '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}',
      );
      if (mounted) {
        _total = pageData.total;
        _hasMore = pageData.list.length < _total;
      }
      return pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
    }

    if (forceRefresh) {
      _isRefreshing.value = true;
      try {
        final songs = await fetch();
        if (mounted) {
          _currentPage = 1;
          _allSongs.value = songs;
          _applyFilter();
          _loading.value = false;
        }
        await ApiCacheManager.instance.set(
          scope: 'favorites',
          key: cacheKey,
          jsonData: jsonEncode(songs.map((s) => s.toMap()).toList()),
        );
      } finally {
        if (mounted) _isRefreshing.value = false;
      }
      return;
    }

    _isRefreshing.value = true;
    try {
      void onData(List<SongEntity>? data) {
        if (mounted) {
          if (data != null) {
            _currentPage = 1;
            _allSongs.value = data;
            _applyFilter();
            _loading.value = false;
          }
          _isRefreshing.value = false; // 后台刷新完成
        }
      }

      final cached = await ApiCacheManager.instance.cacheThenNetwork(
        scope: 'favorites',
        key: cacheKey,
        fetch: fetch,
        fromJson: (json) => (jsonDecode(json) as List)
            .map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
            .toList(),
        toJson: (data) => jsonEncode(data.map((s) => s.toMap()).toList()),
        fetchCallback: onData,
      );

      if (cached != null) {
        // 缓存命中 → 全屏转圈消失，右上角转圈保持直到后台刷新结束
        if (mounted) {
          _currentPage = 1;
          _allSongs.value = cached;
          _applyFilter();
          _loading.value = false;
        }
      }
    } catch (e) {
      debugPrint('[FavoritePage] load error: $e');
      if (mounted) {
        _isRefreshing.value = false;
        if (_allSongs.value.isEmpty) _loading.value = false;
      }
    }
  }

  void _applyFilter() {
    final all = _allSongs.value;
    if (_searchQuery.isEmpty) {
      _songs.value = all;
    } else {
      final q = _searchQuery.toLowerCase();
      _songs.value = all.where((s) {
        return s.title.toLowerCase().contains(q) ||
            s.artistDisplayName.toLowerCase().contains(q);
      }).toList();
    }
  }

  void _playSong(int index) {
    final songs = _songs.value;
    if (songs.isEmpty) return;
    // 已加载数据不足队列上限时，自动分页拉取后续收藏填充到上限。
    // 搜索激活时过滤后的子集与服务端分页顺序不对应，无法可靠续取，跳过填充。
    _player.playQueueFilledToLimit(
      songs,
      index,
      fetchMore: _searchQuery.isNotEmpty ? null : _fetchFavoritePage,
    );
  }

  /// 拉取「已加载页之后」的第 [page] 页收藏（供 playQueueFilledToLimit 的
  /// fetchMore 使用，每次只返回一页，填充循环由 PlayerService 驱动）。
  Future<List<SongEntity>> _fetchFavoritePage(int page) async {
    final pageData = await _api.getFavoriteList(
      page: _currentPage + page,
      size: _pageSize,
      sort: '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}',
    );
    return pageData.list
        .map((t) => _trackService.trackToSongEntity(t.toJson()))
        .toList();
  }

  /// 随机播放全部收藏：先按队列上限循环拉满，再本地乱序。
  /// 搜索激活时跳过填充（过滤子集无法分页续取）。
  Future<void> _playShuffleFilled() async {
    if (_searchQuery.isNotEmpty) {
      _player.playShuffle(_songs.value);
      return;
    }
    final full = List<SongEntity>.from(_songs.value);
    final cap = AppPlaybackQueueSettings.maxQueueLength.value.clamp(10, 1000);
    var page = 1;
    while (full.length < cap) {
      final pageData = await _api.getFavoriteList(
        page: _currentPage + page,
        size: _pageSize,
        sort: '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}',
      );
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      if (songs.isEmpty) break;
      full.addAll(songs);
      page++;
    }
    if (full.length > cap) full.removeRange(cap, full.length);
    _player.playShuffle(full);
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '收藏排序',
          options: const [
            SortOption(key: 'favoriteAt', label: '收藏日期', icon: Icons.favorite),
            SortOption(
              key: 'title',
              label: '歌曲名',
              icon: Icons.music_note_outlined,
            ),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _load(forceRefresh: true);
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _load(forceRefresh: true);
          },
        );
      },
    );
  }

  /// 长按歌曲 → 弹出与歌曲页同款的长按面板（SongDetailSheet），
  /// 并附带「取消收藏」（取消后从列表移除）。
  void _showSongDetail(SongEntity song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(
        song: song,
        onOpenArtist: (name) {
          final artistGuid = song.firstArtistGuid;
          if (artistGuid != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ArtistDetailPage(
                  artistName: name,
                  artistGuid: artistGuid,
                ),
              ),
            );
          }
        },
        onOpenAlbum: (name) {
          final guid = song.albumGuid;
          if (guid != null) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AlbumDetailPage(
                  albumName: name,
                  albumGuid: guid,
                ),
              ),
            );
          }
        },
        extraActions: [
          AppListTile(
            leading: Icon(
              Icons.favorite_border_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: '取消收藏',
            titleColor: Theme.of(context).colorScheme.error,
            onTap: () async {
              try {
                await FeiNiuFavoriteService.instance.unfavorite(song.id);
                if (!mounted) return;
                final updated = List<SongEntity>.from(_allSongs.value)
                  ..removeWhere((s) => s.id == song.id);
                _allSongs.value = updated;
                _applyFilter();
                AppToast.show(context, '已取消收藏');
              } catch (e) {
                if (!mounted) return;
                AppToast.show(context, '操作失败', type: ToastType.error);
              }
              if (!mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        showMiniPlayer: !isMultiSelecting,
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 3 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        appBar: AppTopBar(
          title: isMultiSelecting ? '已选 $selectedCount 首' : '收藏',
          showBackButton: false,
          isRefreshing: _isRefreshing.value && !isMultiSelecting,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: useBottomNavigation || AppLayoutSettings.tvMode.value
              ? null
              : (isMultiSelecting
                  ? IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: exitMultiSelect,
                    )
                  : IconButton(
                      icon: const Icon(Icons.menu_rounded),
                      onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    )),
          actions: isMultiSelecting
              ? [
                  SelectAllButton(
                    isAllSelected: selectedCount == multiSelectSongs.length,
                    selectedCount: selectedCount,
                    totalCount: multiSelectSongs.length,
                    onTap: toggleSelectAll,
                  ),
                  MultiSelectToggleButton(
                    enabled: true,
                    onTap: exitMultiSelect,
                  ),
                ]
              : [
                  IconButton(
                    icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
                    onPressed: () {
                      setState(() {
                        _searchVisible = !_searchVisible;
                        if (!_searchVisible) {
                          _searchController.clear();
                          _searchQuery = '';
                          _applyFilter();
                        }
                      });
                    },
                  ),
                  SortActionButton(onTap: _showSortSheet),
                  MultiSelectToggleButton(
                    enabled: false,
                    onTap: toggleMultiSelect,
                  ),
                ],
        ),
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
                    _applyFilter();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索收藏...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                              _applyFilter();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: theme.appPanelColor,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
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
                builder: (context) {
                  if (_loading.value) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final songs = _songs.value;
                  if (songs.isEmpty) {
                    return Center(
                      child: Text(
                        '还没有收藏歌曲',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    );
                  }

                  return RefreshIndicator(
                    onRefresh: () => _load(forceRefresh: true),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Row(
                            children: [
                              InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => _playShuffleFilled(),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    Icons.shuffle_rounded,
                                    size: 18,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              LoadMoreCountText(
                                text: '共 ${_allSongs.value.length} 首',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                                onTap: (_hasMore && _total > 0)
                                    ? _showLoadMoreDialog
                                    : null,
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 160),
                            itemCount:
                                songs.length + (_loadingMore.value ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= songs.length) {
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
                              final song = songs[index];
                              final selected = isSongSelected(song.id);
                              return InkWell(
                                onTap: () => isMultiSelecting
                                    ? toggleSongSelection(song.id)
                                    : _playSong(index),
                                onLongPress: isMultiSelecting
                                    ? null
                                    : () => _showSongDetail(song),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    children: [
                                      if (isMultiSelecting) ...[
                                        Icon(
                                          selected
                                              ? Icons.check_circle
                                              : Icons.circle_outlined,
                                          size: 20,
                                          color: selected
                                              ? scheme.primary
                                              : theme.disabledColor,
                                        ),
                                        const SizedBox(width: 12),
                                      ],
                                      ArtworkWidget(
                                        song: song,
                                        size: 48,
                                        borderRadius: 8,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              song.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              song.artistDisplayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: scheme.onSurfaceVariant,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (isMultiSelecting)
                          buildMultiSelectBar(
                            includeFavorite: false,
                            includeRemoveFavorite: true,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
