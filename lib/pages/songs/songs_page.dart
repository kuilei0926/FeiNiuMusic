import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_layout_state.dart';
import '../../app/state/settings_lyric_companion.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/deferred_page_init_mixin.dart';
import '../../app/utils/primary_tab_refresh_mixin.dart';
import '../../components/index.dart';
import '../search/search_page.dart';
import '../library/library_detail_pages.dart';
import '../library/folders_page.dart';
import 'song_detail_sheet.dart';

/// 音乐库（原歌曲页面）- 从飞牛 API 分页加载并展示所有歌曲
class SongsPage extends StatefulWidget {
  /// 一次性排序覆盖（如首页「最新歌曲」入口传入的"创建时间降序"）。
  /// 优先级高于持久化偏好，但**不会**回写 SharedPreferences，仅本次进入有效。
  final String? initialSortKey;
  final bool? initialAscending;

  const SongsPage({
    super.key,
    this.initialSortKey,
    this.initialAscending,
  });

  @override
  State<SongsPage> createState() => _SongsPageState();
}

class _SongsPageState extends State<SongsPage>
    with SignalsMixin, DeferredPageInitMixin, SongMultiSelectMixin, PrimaryTabRefreshMixin {
  static const String _prefsSortKey = 'songs_sort_key';
  static const String _prefsSortAsc = 'songs_sort_asc';
  static const double _itemExtent = 64;
  static const int _pageSize = 100;

  @override
  List<SongEntity> get multiSelectSongs => _songs.value;

  final ScrollController _listController = ScrollController();
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;

  int _currentPage = 1;
  int _totalSongs = 0;
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _isLoading = createSignal(true);
  late final _sortKey = createSignal('title');
  late final _ascending = createSignal(true);
  late final _currentId = createSignal<String?>(null);
  late final _isLoadingMore = createSignal(false);
  late final _isRefreshing = createSignal(false);

  bool _hasMoreSongs = true;

  @override
  void initState() {
    super.initState();
    scheduleDeferredInit();
    _listController.addListener(_handleScroll);
    PlayerService.instance.currentSong.addListener(_handlePlayerSongChanged);
  }

  @override
  Future<void> runDeferredInit() async {
    await _restoreSortPrefs();
    await _loadSongs();
  }

  @override
  int get primaryTabIndex => 2;

  @override
  Future<void> onPrimaryTabActivated() async {
    if (mounted) await _loadSongs();
  }

  @override
  void onPrimaryTabDeactivated() {
    // 返回键切到首页时 IndexedStack 不会销毁本页，多选状态残留会让全局
    // 计数不清零、共享底栏一直隐藏；切走即退出多选。
    if (isMultiSelecting) exitMultiSelect();
  }

  @override
  void dispose() {
    PlayerService.instance.currentSong.removeListener(_handlePlayerSongChanged);
    _listController.removeListener(_handleScroll);
    _listController.dispose();
    super.dispose();
  }

  String _apiSortParam() {
    final key = _sortKey.value;
    final order = _ascending.value ? 'asc' : 'desc';
    switch (key) {
      case 'title':
        return 'title,$order';
      case 'artist':
        return 'createdAt,$order'; // API 不支持按歌手排序
      case 'duration':
        return 'createdAt,$order';
      default:
        return 'createdAt,$order';
    }
  }

  String _cacheKey() => 'page=1&size=$_pageSize&sort=${_apiSortParam()}';

  void _preloadCovers(List<SongEntity> songs, {int count = 20}) {
    if (songs.isEmpty || !mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();
    final memoryCacheSize = coverMemoryCacheDimensionOf(context, 48);
    int loaded = 0, skipped = 0;
    for (final song in songs.take(count)) {
      if (song.coverId != null && song.coverId!.isNotEmpty) {
        final url = api.coverUrl(song.coverId!, size: FeiNiuApiClient.coverRequestSize, updatedAt: song.updatedAt);
        final provider = ResizeImage.resizeIfNeeded(
          memoryCacheSize,
          memoryCacheSize,
          CachedNetworkImageProvider(url, headers: headers),
        );
        unawaited(precacheImage(
          provider,
          context,
        ).then((_) => loaded++).catchError((e) {
          debugPrint('[SongsPage] cover precache failed song=${song.title} coverId=${song.coverId}: $e');
          return 0; // 预缓存失败静默，不阻断后续封面
        }));
      } else {
        skipped++;
      }
    }
    if (loaded > 0 || skipped > 0) {
      debugPrint('[SongsPage] preloadCovers count=${songs.length} loaded=$loaded skipped=$skipped');
    }
  }

  Future<void> _loadSongs({bool forceRefresh = false}) async {
    debugPrint('[SongsPage] _loadSongs forceRefresh=$forceRefresh sort=${_apiSortParam()}');
    _currentPage = 1;
    _hasMoreSongs = true;

    Future<List<SongEntity>> fetch() async {
      final sort = _apiSortParam();
      debugPrint('[SongsPage] fetch page=1 size=$_pageSize sort=$sort');
      try {
        final pageData = await _api.getTrackList(
          page: 1,
          size: _pageSize,
          sort: sort,
        );
        debugPrint('[SongsPage] fetch ok total=${pageData.total} items=${pageData.list.length}');
        final songs = pageData.list
            .map((t) {
              try {
                return _trackService.trackToSongEntity(t.toJson());
              } catch (e) {
                debugPrint('[SongsPage] trackToSongEntity error: $e');
                rethrow;
              }
            })
            .toList();
        _totalSongs = pageData.total;
        _hasMoreSongs = _totalSongs > 0
            ? songs.length < _totalSongs
            : songs.length >= _pageSize;
        return songs;
      } catch (e) {
        debugPrint('[SongsPage] fetch error: $e');
        rethrow;
      }
    }

    if (forceRefresh) {
      _isRefreshing.value = true;
      try {
        final songs = await fetch();
        if (mounted) {
          _songs.value = songs;
          _isLoading.value = false;
          _preloadCovers(songs);
        }
        await ApiCacheManager.instance.set(
          scope: 'track_list',
          key: _cacheKey(),
          jsonData: jsonEncode(songs.map((s) => s.toMap()).toList()),
        );
        debugPrint('[SongsPage] forceRefresh done, songs=${songs.length}');
      } catch (e) {
        debugPrint('[SongsPage] forceRefresh error: $e');
      } finally {
        if (mounted) _isRefreshing.value = false;
      }
      return;
    }

    // 非 forceRefresh 模式：有缓存秒加载，无缓存同步等网络
    _isRefreshing.value = true;
    try {
      void onData(List<SongEntity>? data) {
        if (mounted) {
          if (data != null) {
            debugPrint('[SongsPage] onData songs=${data.length}');
            _songs.value = data;
            _isLoading.value = false;
            _preloadCovers(data);
          }
          _isRefreshing.value = false; // 后台刷新完成（成功或失败都关掉右上角转圈）
        }
      }

      final cached = await ApiCacheManager.instance.cacheThenNetwork(
        scope: 'track_list',
        key: _cacheKey(),
        fetch: fetch,
        fromJson: (json) {
          try {
            final list = (jsonDecode(json) as List)
                .map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
                .toList();
            debugPrint('[SongsPage] cache parse ok, items=${list.length}');
            return list;
          } catch (e) {
            debugPrint('[SongsPage] cache parse error: $e');
            rethrow;
          }
        },
        toJson: (data) {
          final json = jsonEncode(data.map((s) => s.toMap()).toList());
          debugPrint('[SongsPage] toJson items=${data.length} size=${json.length}B');
          return json;
        },
        fetchCallback: onData,
      );

      if (cached != null) {
        // 缓存命中 → 全屏转圈消失，右上角转圈保持直到后台刷新结束
        debugPrint('[SongsPage] cache hit, songs=${cached.length}, background refresh started');
        if (mounted) {
          _songs.value = cached;
          _isLoading.value = false;
          _preloadCovers(cached);
          // _isRefreshing 保持 true，后台刷新完成后 onData 会关掉
        }
      } else {
        debugPrint('[SongsPage] cache miss, loaded from network');
      }
    } catch (e) {
      debugPrint('[SongsPage] load error type=${e.runtimeType}: $e');
      if (mounted) {
        _isRefreshing.value = false;
        if (_songs.value.isEmpty) {
          _isLoading.value = false;
          debugPrint('[SongsPage] no cached data, showing empty state');
        } else {
          debugPrint('[SongsPage] has stale data on screen, hiding refresher');
        }
      }
    }
  }

  Future<void> _loadMoreSongs() async {
    if (_isLoadingMore.value || !_hasMoreSongs) return;
    _isLoadingMore.value = true;
    await _fetchAndAppendNextPage();
    if (mounted) _isLoadingMore.value = false;
  }

  /// 拉取下一页并追加到列表。返回是否有新增数据。
  /// 供滚动加载（_loadMoreSongs）与「按数量加载」（_loadMoreToTarget）共用。
  Future<bool> _fetchAndAppendNextPage() async {
    _currentPage++;
    try {
      final sort = _apiSortParam();
      final pageData = await _api.getTrackList(
        page: _currentPage,
        size: _pageSize,
        sort: sort,
      );
      debugPrint(
        '[SongsPage] loadMore ok total=${pageData.total} items=${pageData.list.length}',
      );
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      _totalSongs = pageData.total;
      _hasMoreSongs = _totalSongs > 0
          ? _songs.value.length + songs.length < _totalSongs
          : songs.length >= _pageSize;
      debugPrint(
        '[SongsPage] loadMore hasMore=$_hasMoreSongs currentTotal=${_songs.value.length}',
      );
      if (mounted) {
        _songs.value = [..._songs.value, ...songs];
      }
      return songs.isNotEmpty;
    } catch (e) {
      _currentPage--;
      debugPrint('[SongsPage] loadMore error type=${e.runtimeType}: $e');
      return false;
    }
  }

  /// 按目标数量加载：循环整页 _pageSize 直到达到 target 或没有更多。
  /// 已加载数始终保持 _pageSize 的整数倍（或等于 total），
  /// 保证播放队列 fetchMore 的 `page: _currentPage + page` 偏移不错位。
  Future<void> _loadMoreToTarget(int target) async {
    if (_isLoadingMore.value || target <= _songs.value.length) return;
    _isLoadingMore.value = true;
    try {
      while (mounted && _songs.value.length < target && _hasMoreSongs) {
        if (!await _fetchAndAppendNextPage()) break;
      }
    } finally {
      if (mounted) _isLoadingMore.value = false;
    }
  }

  /// 点击数量显示 → 弹出输入对话框，按用户指定的数量加载。
  Future<void> _showLoadMoreDialog() async {
    final loaded = _songs.value.length;
    if (_totalSongs <= loaded) return;
    final target = await LoadMoreCountDialog.show(
      context,
      currentCount: loaded,
      maxTotal: _totalSongs,
      title: '歌曲加载更多',
    );
    if (target == null || !mounted || target <= loaded) return;
    await _loadMoreToTarget(target);
  }

  Future<void> _restoreSortPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final sortKey = prefs.getString(_prefsSortKey);
    final sortAsc = prefs.getBool(_prefsSortAsc);
    if (!mounted) return;
    if (sortKey != null && sortKey.isNotEmpty) {
      _sortKey.value = sortKey;
    }
    if (sortAsc != null) {
      _ascending.value = sortAsc;
    }
    // 一次性排序覆盖：仅本次进入生效，不改写持久化偏好。
    // 首页「最新歌曲」入口要求默认按创建时间降序。
    if (widget.initialSortKey != null) {
      _sortKey.value = widget.initialSortKey!;
    }
    if (widget.initialAscending != null) {
      _ascending.value = widget.initialAscending!;
    }
  }

  Future<void> _saveSortPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSortKey, _sortKey.value);
    await prefs.setBool(_prefsSortAsc, _ascending.value);
  }

  void _handleScroll() {
    if (!_listController.hasClients) return;
    final offset = _listController.offset;
    final maxScroll = _listController.position.maxScrollExtent;
    if (maxScroll > 0 && offset >= maxScroll - 200) {
      _loadMoreSongs();
    }
  }

  void _handlePlayerSongChanged() {
    if (!mounted) return;
    final song = PlayerService.instance.currentSong.value;
    _currentId.value = song?.id;
  }

  void _openSearch() {
    Navigator.pushNamed(context, AppRoutes.search, arguments: SearchCategory.song);
  }

  /// 打开文件夹视图（服务端增强）。未开启时引导到设置页。
  void _openFolders() {
    if (LyricCompanionSettings.enabled.value) {
      Navigator.of(context).push(
        buildAppPageRoute((_) => const FoldersPage()),
      );
    } else {
      AppToast.show(
        context,
        '请先在设置 → 元数据管理开启「服务端增强」',
        type: ToastType.error,
      );
    }
  }

  void _playSong(int index) {
    final songs = _songs.value;
    if (songs.isEmpty) return;
    // 已加载数据不足队列上限时，自动分页拉取后续歌曲填充到上限
    _player.playQueueFilledToLimit(
      songs,
      index,
      fetchMore: (page) async {
        final sort = _apiSortParam();
        final pageData = await _api.getTrackList(
          page: _currentPage + page,
          size: _pageSize,
          sort: sort,
        );
        return pageData.list
            .map((t) => _trackService.trackToSongEntity(t.toJson()))
            .toList();
      },
    );
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '歌曲排序',
          options: const [
            SortOption(key: 'title', label: '歌曲名', icon: Icons.music_note_outlined),
            SortOption(key: 'duration', label: '创建时间', icon: Icons.access_time),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _saveSortPrefs();
            _loadSongs(forceRefresh: true);
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _saveSortPrefs();
            _loadSongs(forceRefresh: true);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => Watch.builder(
        builder: (_) => AppPageScaffold(
          key: _scaffoldKey,
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: isMultiSelecting ? '已选 $selectedCount 首' : '歌曲',
            showBackButton: false,
            centerTitle: false,
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
                    const SizedBox(width: 4),
                  ]
                : [
                    if (_isRefreshing.value)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                    MultiSelectToggleButton(
                      enabled: false,
                      onTap: toggleMultiSelect,
                    ),
                    SortActionButton(onTap: _showSortSheet),
                    IconButton(
                      tooltip: '搜索',
                      icon: const Icon(Icons.search_rounded),
                      onPressed: _openSearch,
                    ),
                    const SizedBox(width: 4),
                  ],
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          drawer: useBottomNavigation
              ? null
              : SideMenu(
                  onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
                ),
          bottomNavIndex: useBottomNavigation ? 2 : null,
          onBottomNavTap: useBottomNavigation
              ? (index) => navigateToPrimaryDestination(context, index)
              : null,
          showMiniPlayer: !isMultiSelecting,
          body: Watch.builder(
            builder: (context) {
              if (_isLoading.value) {
                return const Center(child: CircularProgressIndicator());
              }

              final songs = _songs.value;
              if (songs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.music_note_outlined,
                        size: 64,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '暂无歌曲',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                );
              }

              return RefreshIndicator(
                onRefresh: () => _loadSongs(forceRefresh: true),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _player.startRoamPlayback(),
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
                            text: '共 $_totalSongs 首',
                            style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                            onTap: _hasMoreSongs ? _showLoadMoreDialog : null,
                          ),
                          const Spacer(),
                          // 文件夹视图入口（服务端增强）
                          InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: _openFolders,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Icon(
                                Icons.folder_outlined,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _listController,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
                        itemCount: songs.length + (_isLoadingMore.value ? 1 : 0),
                        itemExtent: _itemExtent,
                        addAutomaticKeepAlives: true,
                        scrollCacheExtent: ScrollCacheExtent.pixels(300),
                        itemBuilder: (context, index) {
                          if (index >= songs.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                            );
                          }

                          final song = songs[index];
                          final isCurrent = _currentId.value == song.id;
                          final isPlaying =
                              isCurrent && _player.isPlaying.value;
                          final selected = isSongSelected(song.id);

                          return _SongListTile(
                            song: song,
                            isCurrent: isCurrent,
                            isPlaying: isPlaying,
                            multiSelect: isMultiSelecting,
                            selected: selected,
                            onTap: () => isMultiSelecting
                                ? toggleSongSelection(song.id)
                                : _playSong(index),
                            onLongPress: isMultiSelecting
                                ? null
                                : () => _showSongDetail(song),
                          );
                        },
                      ),
                    ),
                    if (isMultiSelecting) buildMultiSelectBar(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _showSongDetail(SongEntity song) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(
        song: song,
        onUpdated: (_) => _loadSongs(forceRefresh: true),
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
      ),
    );
  }
}

class _SongListTile extends StatelessWidget {
  final SongEntity song;
  final bool isCurrent;
  final bool isPlaying;
  final bool multiSelect;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _SongListTile({
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    this.multiSelect = false,
    this.selected = false,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final leading = ArtworkWidget(
      song: song,
      size: 48,
      borderRadius: 8,
    );
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            if (multiSelect) ...[
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.disabledColor,
              ),
              const SizedBox(width: 12),
            ],
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isCurrent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artistDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (isPlaying)
              Container(
                margin: const EdgeInsets.only(left: 4),
                child: PlayingBars(
                  color: theme.colorScheme.primary,
                  animating: true,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
