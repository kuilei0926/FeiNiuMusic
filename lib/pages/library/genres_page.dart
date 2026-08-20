import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_layout_state.dart';
import '../../app/state/song_state.dart';
import '../../app/theme/app_styles.dart';
import '../../app/tv/tv_layout.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../components/index.dart';
import '../songs/song_detail_sheet.dart';

class GenresPage extends StatefulWidget {
  const GenresPage({super.key});

  @override
  State<GenresPage> createState() => _GenresPageState();
}

const String genresPrefsSortKey = 'genres_sort_key_v1';
const String genresPrefsSortAscending = 'genres_sort_ascending_v1';
const String genresPrefsGridColumns = 'genres_grid_columns_v1';
const String genresDefaultSortKey = 'trackCount';
const bool genresDefaultAscending = false;

class _GenresPageState extends State<GenresPage> with SignalsMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();
  final ScrollController _scrollController = ScrollController();

  late final _loading = createSignal(true);
  late final _loadingMore = createSignal(false);
  late final _genres = createSignal<List<FeiNiuGenre>>([]);
  late final _sortKey = createSignal(genresDefaultSortKey);
  late final _ascending = createSignal(genresDefaultAscending);
  late final _gridColumns = createSignal(2);

  /// genreGUID → 该风格第一首歌曲封面 coverId
  late final _genreCovers = createSignal<Map<String, String?>>({});

  // 本地搜索(样式对齐最近播放页): 仅过滤已加载列表
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchVisible = false;

  static const int _pageSize = 100;
  int _currentPage = 1;
  int _total = 0;
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

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _init();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || !_hasMore || _loadingMore.value)
      return;
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
      final sort = '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}';
      final pageData = await _api.getGenreList(
        page: _currentPage,
        size: _pageSize,
        sort: sort,
      );
      if (!mounted) return;
      _total = pageData.total;
      _genres.value = [..._genres.value, ...pageData.list];
      _hasMore = _genres.value.length < _total;
      unawaited(_fetchFirstSongCovers(pageData.list));
    } catch (_) {
      _currentPage--;
    } finally {
      if (mounted) _loadingMore.value = false;
    }
  }

  /// 并发拉取每个风格的第一首歌曲封面，存入 [_genreCovers]。
  ///
  /// 卡片圆心叠加的专辑封面即来自此映射；单个风格失败不影响其余。
  /// 封面映射整体走持久缓存（genreGUID → coverId）：断网时直接读缓存渲染，
  /// 已尝试过的风格（无论有无封面）不再重复请求。
  Future<void> _fetchFirstSongCovers(List<FeiNiuGenre> genres) async {
    if (genres.isEmpty || !mounted) return;
    const scope = 'genres';
    const key = 'covers';
    // 断网兜底：先读已缓存的封面映射立即渲染，再对缺失风格后台拉取。
    try {
      final cachedJson = await ApiCacheManager.instance.getPersisted(
        scope,
        key,
      );
      if (cachedJson != null) {
        final cached = (jsonDecode(cachedJson) as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as String?),
        );
        final map = Map<String, String?>.from(_genreCovers.value)
          ..addAll(cached);
        _genreCovers.value = map;
      }
    } catch (e) {
      debugPrint('[GenresPage] covers cache read error: $e');
    }
    // 只请求映射里还没有的风格（已含 null 表示已尝试过，避免重复请求）
    final missing = genres
        .where((g) => !_genreCovers.value.containsKey(g.guid))
        .toList();
    if (missing.isEmpty || !mounted) return;
    final results = await Future.wait(
      missing.map((g) async {
        try {
          final pageData = await _api.getGenreTracks(
            genreGUID: g.guid,
            page: 1,
            size: 1,
          );
          final first = pageData.list.isNotEmpty ? pageData.list.first : null;
          return (guid: g.guid, coverId: first?.coverId);
        } catch (_) {
          return (guid: g.guid, coverId: null);
        }
      }),
    );
    if (!mounted) return;
    final map = Map<String, String?>.from(_genreCovers.value);
    for (final r in results) {
      map[r.guid] = r.coverId;
    }
    _genreCovers.value = map;
    // 写回持久缓存（永久，与列表缓存一致）
    try {
      await ApiCacheManager.instance.set(
        scope: scope,
        key: key,
        jsonData: jsonEncode(map),
      );
    } catch (e) {
      debugPrint('[GenresPage] covers cache write error: $e');
    }
  }

  Future<void> _init() async {
    await _loadPrefs();
    await _load();
  }

  Future<void> _loadPrefs() async {
    // 在首个 await 前取宽，避免跨异步间隙使用 BuildContext。
    final width = AppLayoutSettings.tvMode.value
        ? MediaQuery.sizeOf(context).width
        : 0.0;
    final prefs = await SharedPreferences.getInstance();
    var key = (prefs.getString(genresPrefsSortKey) ?? genresDefaultSortKey)
        .trim();
    if (key.isEmpty) key = genresDefaultSortKey;
    _sortKey.value = key;
    _ascending.value =
        prefs.getBool(genresPrefsSortAscending) ?? genresDefaultAscending;
    // TV 模式：列数按屏幕宽度自适应，不读移动端持久化值（互不串味）。
    if (AppLayoutSettings.tvMode.value) {
      _gridColumns.value = TvLayout.gridColumns(width);
    } else {
      var cols = prefs.getInt(genresPrefsGridColumns) ?? 2;
      if (cols < 2) cols = 2;
      if (cols > 4) cols = 4;
      _gridColumns.value = cols;
    }
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(genresPrefsSortKey, _sortKey.value);
    await prefs.setBool(genresPrefsSortAscending, _ascending.value);
    // TV 模式的列数选择不写入移动端持久化，避免污染手机端偏好。
    if (!AppLayoutSettings.tvMode.value) {
      await prefs.setInt(genresPrefsGridColumns, _gridColumns.value);
    }
  }

  Future<void> _load() async {
    _loading.value = true;
    final sort = '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}';
    const scope = 'genres';
    final key = 'list-$sort';
    // 断网兜底：先读本地持久缓存立即渲染，再后台刷新最新数据。
    try {
      final cachedJson = await ApiCacheManager.instance.getPersisted(
        scope,
        key,
      );
      if (cachedJson != null && mounted) {
        try {
          final cached = jsonDecode(cachedJson) as List;
          final genres = cached
              .map((e) => FeiNiuGenre.fromJson(e as Map<String, dynamic>))
              .toList();
          _currentPage = 1;
          _total = genres.length;
          _hasMore = false;
          _genres.value = genres;
          _loading.value = false; // 缓存命中先渲染，网络刷新在后台完成
        } catch (e) {
          debugPrint('[GenresPage] cache parse error: $e');
        }
      }
    } catch (e) {
      debugPrint('[GenresPage] cache read error: $e');
    }
    try {
      final pageData = await _api.getGenreList(
        page: 1,
        size: _pageSize,
        sort: sort,
      );
      if (mounted) {
        _currentPage = 1;
        _total = pageData.total;
        _hasMore = pageData.list.length < _total;
        _genres.value = pageData.list;
        unawaited(_fetchFirstSongCovers(pageData.list));
      }
      try {
        await ApiCacheManager.instance.set(
          scope: scope,
          key: key,
          jsonData: jsonEncode(pageData.list.map((g) => g.toJson()).toList()),
        );
      } catch (e) {
        debugPrint('[GenresPage] cache write error: $e');
      }
    } catch (e) {
      debugPrint('[GenresPage] load error: $e');
    }
    if (mounted) _loading.value = false;
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '风格排序',
          options: const [
            SortOption(key: 'name', label: '风格名', icon: Icons.sort_by_alpha),
            SortOption(
              key: 'trackCount',
              label: '歌曲数',
              icon: Icons.music_note_outlined,
            ),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _savePrefs();
            _load();
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _savePrefs();
            _load();
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
    final scheme = Theme.of(context).colorScheme;

    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '风格',
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
                      : () => _scaffoldKey.currentState?.openDrawer(),
                ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            SortActionButton(onTap: _showSortSheet),
            IconButton(
              tooltip: _searchVisible ? '关闭搜索' : '搜索',
              icon: Icon(_searchVisible ? Icons.search_off : Icons.search),
              onPressed: () {
                setState(() {
                  _searchVisible = !_searchVisible;
                  if (!_searchVisible) {
                    _searchController.clear();
                    _searchQuery = '';
                  }
                });
              },
            ),
          ],
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        body: Watch.builder(
          builder: (context) {
            if (_loading.value) {
              return const Center(child: CircularProgressIndicator());
            }

            final allGenres = _genres.value;
            if (allGenres.isEmpty) {
              return Center(
                child: Text(
                  '暂无风格',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              );
            }

            final q = _searchQuery.trim().toLowerCase();
            final genres = q.isEmpty
                ? allGenres
                : allGenres
                      .where((g) => g.name.toLowerCase().contains(q))
                      .toList();

            return Column(
              children: [
                if (_searchVisible)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                    child: TextField(
                      controller: _searchController,
                      autofocus: true,
                      onChanged: (v) => setState(() => _searchQuery = v),
                      decoration: InputDecoration(
                        hintText: '搜索风格...',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: Theme.of(context).appPanelColor,
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
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: genres.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              const SizedBox(height: 160),
                              Center(
                                child: Text(
                                  '无匹配的风格',
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : CustomScrollView(
                            controller: _scrollController,
                            slivers: [
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 8),
                              ),
                              SliverPadding(
                                padding: AppLayoutSettings.tvMode.value
                                    ? TvLayout.pagePadding()
                                    : const EdgeInsets.fromLTRB(12, 0, 12, 160),
                                sliver: SliverGrid(
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      if (index >= genres.length) {
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
                                      final g = genres[index];
                                      final theme = Theme.of(context);
                                      final coverId =
                                          _genreCovers.value[g.guid];
                                      return InkWell(
                                        key: ValueKey(g.guid),
                                        borderRadius: BorderRadius.circular(16),
                                        onTap: () {
                                          Navigator.of(context).push(
                                            buildAppPageRoute(
                                              (_) => GenreDetailPage(genre: g),
                                            ),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(4),
                                          child: Column(
                                            children: [
                                              // 封面缩小并居中，名称与歌曲数在下方居中
                                              Expanded(
                                                child: Center(
                                                  child: AspectRatio(
                                                    aspectRatio: 1,
                                                    child: _GenreCover(
                                                      coverId: coverId,
                                                      borderRadius: 16,
                                                      genreName: g.name,
                                                      placeholder:
                                                          const SizedBox.shrink(),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                g.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  height: 1.2,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${g.trackCount} 首',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                                style: theme.textTheme.bodySmall
                                                    ?.copyWith(
                                                      fontSize: 12,
                                                      color: theme
                                                          .textTheme
                                                          .bodySmall
                                                          ?.color
                                                          ?.withValues(
                                                            alpha: 0.7,
                                                          ),
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                    childCount:
                                        genres.length +
                                        (_loadingMore.value ? 1 : 0),
                                  ),
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: _adaptiveGridColumns(
                                          context,
                                        ),
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
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 风格封面：用 genre_bg 圆形底图做背景，圆心叠加该风格第一首歌曲的圆形封面。
///
/// 无封面数据时只显示圆形底图（底图本身已含圆形专辑占位）。
class _GenreCover extends StatelessWidget {
  final String? coverId;
  final double borderRadius;
  final String genreName;
  final Widget placeholder;

  const _GenreCover({
    required this.coverId,
    required this.borderRadius,
    required this.genreName,
    required this.placeholder,
  });

  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 自适应父约束取方形边长；Image.asset 需要具体尺寸
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        if (side <= 0) return const SizedBox.shrink();
        final size = side.clamp(0.0, 600.0);
        final bg = Image.asset(
          'assets/preview/genre_bg.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
        );

        // 圆心专辑封面直径取底图的 60%，比底图内圆形区域略小，视觉更协调
        final coverSize = size * 0.6;
        Widget? centerCover;
        if (coverId != null && coverId!.isNotEmpty) {
          final coverUrl = FeiNiuApiClient.instance.coverUrl(
            coverId!,
            size: FeiNiuApiClient.coverRequestSize,
          );
          centerCover = ClipOval(
            child: CachedNetworkImage(
              imageUrl: coverUrl,
              httpHeaders: _authHeaders(),
              width: coverSize,
              height: coverSize,
              fit: BoxFit.cover,
              placeholder: (context, url) =>
                  _circlePlaceholder(theme, coverSize),
              errorWidget: (context, url, error) =>
                  _circlePlaceholder(theme, coverSize),
            ),
          );
        } else {
          centerCover = _circlePlaceholder(theme, coverSize);
        }

        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(child: bg),
              centerCover,
            ],
          ),
        );
      },
    );
  }

  /// 圆形占位：底色 + 风格名首字母
  Widget _circlePlaceholder(ThemeData theme, double circleSize) {
    return Container(
      width: circleSize,
      height: circleSize,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        genreName.isNotEmpty ? genreName.characters.first.toUpperCase() : '?',
        style: TextStyle(
          fontSize: circleSize * 0.4,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class GenreDetailPage extends StatefulWidget {
  final FeiNiuGenre genre;

  const GenreDetailPage({super.key, required this.genre});

  @override
  State<GenreDetailPage> createState() => _GenreDetailPageState();
}

class _GenreDetailPageState extends State<GenreDetailPage>
    with SignalsMixin, SongMultiSelectMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final PlayerService _player = PlayerService.instance;

  @override
  List<SongEntity> get multiSelectSongs => _songs.value;

  late final _loading = createSignal(true);
  late final _loadingMore = createSignal(false);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _sortKey = createSignal('createdAt');
  late final _ascending = createSignal(false);
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
    if (!_scrollController.hasClients || !_hasMore || _loadingMore.value)
      return;
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
      final pageData = await _api.getGenreTracks(
        genreGUID: widget.genre.guid,
        page: _currentPage,
        size: _pageSize,
        sort: _apiSortParam(),
      );
      if (!mounted) return false;
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t))
          .toList();
      _total = pageData.total;
      _songs.value = [..._songs.value, ...songs];
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
      title: '风格歌曲加载更多',
    );
    if (target == null || !mounted || target <= loaded) return;
    await _loadMoreToTarget(target);
  }

  String _apiSortParam() {
    return '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}';
  }

  Future<void> _load({bool forceRefresh = false}) async {
    _loading.value = true;
    try {
      final pageData = await _api.getGenreTracks(
        genreGUID: widget.genre.guid,
        page: 1,
        size: _pageSize,
        sort: _apiSortParam(),
      );
      if (!mounted) return;
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t))
          .toList();
      _currentPage = 1;
      _total = pageData.total;
      _hasMore = songs.length < _total;
      _songs.value = songs;
    } catch (e) {
      debugPrint('[GenreDetailPage] load error: $e');
    }
    if (mounted) _loading.value = false;
  }

  /// 拉取「已加载页之后」的第 [page] 页流派歌曲（供填充播放使用）。
  Future<List<SongEntity>> _fetchGenrePage(int page) async {
    final pageData = await _api.getGenreTracks(
      genreGUID: widget.genre.guid,
      page: _currentPage + page,
      size: _pageSize,
      sort: _apiSortParam(),
    );
    return pageData.list
        .map((t) => _trackService.trackToSongEntity(t))
        .toList();
  }

  /// 播放该流派歌曲：已加载数据不足队列上限时，自动分页拉取填充到上限。
  void _playSong(int index) {
    final songs = _songs.value;
    if (songs.isEmpty) return;
    _player.playQueueFilledToLimit(songs, index, fetchMore: _fetchGenrePage);
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '排序',
          options: const [
            SortOption(
              key: 'createdAt',
              label: '添加日期',
              icon: Icons.access_time,
            ),
            SortOption(key: 'artistName', label: '歌手', icon: Icons.person),
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      showMiniPlayer: !isMultiSelecting,
      appBar: AppTopBar(
        title: isMultiSelecting ? '已选 $selectedCount 首' : widget.genre.name,
        leading: isMultiSelecting
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: exitMultiSelect,
              )
            : null,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: isMultiSelecting
            ? [
                SelectAllButton(
                  isAllSelected: selectedCount == multiSelectSongs.length,
                  selectedCount: selectedCount,
                  totalCount: multiSelectSongs.length,
                  onTap: toggleSelectAll,
                ),
                MultiSelectToggleButton(enabled: true, onTap: exitMultiSelect),
              ]
            : [
                SortActionButton(onTap: _showSortSheet),
                MultiSelectToggleButton(
                  enabled: false,
                  onTap: toggleMultiSelect,
                ),
              ],
      ),
      body: Watch.builder(
        builder: (context) {
          if (_loading.value) {
            return const Center(child: CircularProgressIndicator());
          }

          final songs = _songs.value;
          if (songs.isEmpty) {
            return Center(
              child: Text(
                '暂无歌曲',
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
                  alignment: Alignment.centerLeft,
                  child: LoadMoreCountText(
                    text: '共 ${_songs.value.length} 首',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                    onTap: (_hasMore && _total > 0)
                        ? _showLoadMoreDialog
                        : null,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 160),
                    itemCount: songs.length + (_loadingMore.value ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= songs.length) {
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
                      final song = songs[index];
                      final selected = isSongSelected(song.id);
                      return InkWell(
                        onTap: () => isMultiSelecting
                            ? toggleSongSelection(song.id)
                            : _playSong(index),
                        onLongPress: isMultiSelecting
                            ? null
                            : () {
                                showModalBottomSheet<void>(
                                  context: context,
                                  backgroundColor: Colors.transparent,
                                  isScrollControlled: true,
                                  builder: (_) => SongDetailSheet(song: song),
                                );
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
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
                                      : Theme.of(context).disabledColor,
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                if (isMultiSelecting) buildMultiSelectBar(),
              ],
            ),
          );
        },
      ),
    );
  }
}
