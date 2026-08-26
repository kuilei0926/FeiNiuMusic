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
import '../../app/state/settings_layout_state.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/deferred_page_init_mixin.dart';
import '../../components/index.dart';
import '../../pages/search/search_page.dart';
import 'library_detail_pages.dart';
import 'library_metadata.dart';

class ArtistsPage extends StatefulWidget {
  const ArtistsPage({super.key});

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

const String artistsPrefsSortKey = 'artists_sort_key_v1';
const String artistsPrefsSortAscending = 'artists_sort_ascending_v1';
const String artistsPrefsFilterUnknown = 'artists_filter_unknown_v1';
const String artistsDefaultSortKey = 'songCount';
const bool artistsDefaultAscending = false;
const bool artistsDefaultFilterUnknown = false;

class ArtistGroup {
  final String name;
  final int songCount;
  final int albumCount;
  final FeiNiuArtist artist;

  ArtistGroup.fromFeiNiuArtist(FeiNiuArtist a)
      : name = a.name,
        songCount = a.trackCount ?? 0,
        albumCount = a.albumCount ?? 0,
        artist = a;

  ArtistGroup.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        songCount = json['songCount'] as int? ?? 0,
        albumCount = json['albumCount'] as int? ?? 0,
        artist = FeiNiuArtist.fromJson(json['artist'] as Map<String, dynamic>);

  Map<String, dynamic> toJson() => {
        'name': name,
        'songCount': songCount,
        'albumCount': albumCount,
        'artist': artist.toJson(),
      };
}

class _ArtistsPageState extends State<ArtistsPage>
    with SignalsMixin, DeferredPageInitMixin {
  static const double _itemExtent = 64;
  static const String _prefsSortKey = artistsPrefsSortKey;
  static const String _prefsSortAscending = artistsPrefsSortAscending;
  static const String _prefsFilterUnknown = artistsPrefsFilterUnknown;

  final ScrollController _controller = ScrollController();
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _loading = createSignal(true);
  late final _loadingMore = createSignal(false);
  late final _isRefreshing = createSignal(false);
  late final _groups = createSignal<List<ArtistGroup>>([]);
  late final _sortKey = createSignal(artistsDefaultSortKey);
  late final _ascending = createSignal(artistsDefaultAscending);
  late final _filterUnknown = createSignal(false);

  int _currentPage = 1;
  bool _hasMore = true;
  int _total = 0;
  static const int _pageSize = 100;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleScroll);
    scheduleDeferredInit();
  }

  @override
  Future<void> runDeferredInit() async {
    await _init();
  }

  void _handleScroll() {
    if (!_controller.hasClients || !_hasMore || _loadingMore.value) return;
    final maxScroll = _controller.position.maxScrollExtent;
    final offset = _controller.offset;
    if (maxScroll - offset < 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore.value || !_hasMore) return;
    _loadingMore.value = true;
    _currentPage++;
    try {
      final pageData = await FeiNiuApiClient.instance.getArtistList(
        page: _currentPage,
        size: _pageSize,
      );
      if (!mounted) return;
      _total = pageData.total;
      final totalKnown = _total > 0;
      _hasMore = totalKnown
          ? _groups.value.length + pageData.list.length < _total
          : pageData.list.length >= _pageSize;
      final groups = pageData.list
          .map((a) => ArtistGroup.fromFeiNiuArtist(a))
          .toList();
      _groups.value = [..._groups.value, ...groups];
    } catch (_) {
      _currentPage--;
    } finally {
      if (mounted) _loadingMore.value = false;
    }
  }

  void _applyMetadataUpdate(String guid, LibraryEntityMetadata metadata) {
    if (!_groups.value.any((group) => group.artist.guid == guid)) return;
    final artists = replaceArtistMetadata(
      _groups.value.map((group) => group.artist).toList(),
      guid,
      metadata,
    );
    final groups = artists.map(ArtistGroup.fromFeiNiuArtist).toList();
    _groups.value = groups;

    unawaited(
      ApiCacheManager.instance.set(
        scope: 'artist_list',
        key: 'page=1&size=$_pageSize',
        jsonData: jsonEncode(
          groups.take(_pageSize).map((group) => group.toJson()).toList(),
        ),
      ),
    );
  }

  Future<void> _init() async {
    await _loadPrefs();
    await _load();
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    var key = (prefs.getString(_prefsSortKey) ?? artistsDefaultSortKey).trim();
    if (key.isEmpty) key = artistsDefaultSortKey;
    final asc =
        prefs.getBool(_prefsSortAscending) ?? artistsDefaultAscending;
    final filterUnknown = prefs.getBool(_prefsFilterUnknown) ?? false;
    _sortKey.value = key;
    _ascending.value = asc;
    _filterUnknown.value = filterUnknown;
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsSortKey, _sortKey.value);
    await prefs.setBool(_prefsSortAscending, _ascending.value);
    await prefs.setBool(_prefsFilterUnknown, _filterUnknown.value);
  }

  void _preloadCovers(List<ArtistGroup> groups, {int count = 30}) {
    if (groups.isEmpty || !mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();
    final memoryCacheSize = coverMemoryCacheDimensionOf(context, 160);
    for (final g in groups.take(count)) {
      if (g.artist.coverId != null && g.artist.coverId!.isNotEmpty) {
        final url = api.coverUrl(g.artist.coverId!, size: FeiNiuApiClient.coverRequestSize, updatedAt: null);
        unawaited(precacheImage(
          ResizeImage.resizeIfNeeded(
            memoryCacheSize,
            memoryCacheSize,
            CachedNetworkImageProvider(url, headers: headers),
          ),
          context,
        ));
      }
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    _currentPage = 1;
    _hasMore = true;
    const cacheKey = 'page=1&size=100';

    Future<List<ArtistGroup>> fetch() async {
      final pageData = await FeiNiuApiClient.instance.getArtistList(
        page: 1,
        size: _pageSize,
      );
      _total = pageData.total;
      _hasMore = _total > 0
          ? pageData.list.length < _total
          : pageData.list.length >= _pageSize;
      final groups = pageData.list
          .map((a) => ArtistGroup.fromFeiNiuArtist(a))
          .toList();
      _sortGroups(groups);
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
          scope: 'artist_list',
          key: cacheKey,
          jsonData: jsonEncode(groups.map((g) => g.toJson()).toList()),
        );
      } finally {
        if (mounted) _isRefreshing.value = false;
      }
      return;
    }

    _isRefreshing.value = true;
    try {
      void onData(List<ArtistGroup>? data) {
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
        scope: 'artist_list',
        key: cacheKey,
        fetch: fetch,
        fromJson: (json) => (jsonDecode(json) as List)
            .map((e) => ArtistGroup.fromJson(e as Map<String, dynamic>))
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
    } catch (_) {
      if (!mounted) return;
      _isRefreshing.value = false;
      if (_groups.value.isEmpty) _groups.value = [];
      _loading.value = false;
    }
  }

  void _sortGroups(List<ArtistGroup> groups) {
    if (_filterUnknown.value) {
      groups.removeWhere((g) => g.name == '未知歌手');
    }

    int compare(ArtistGroup a, ArtistGroup b) {
      if (_sortKey.value == 'songCount') {
        return a.songCount.compareTo(b.songCount);
      }
      if (_sortKey.value == 'albumCount') {
        return a.albumCount.compareTo(b.albumCount);
      }
      return pinyinKey(a.name).compareTo(pinyinKey(b.name));
    }

    groups.sort(compare);
    if (!_ascending.value) {
      groups.replaceRange(0, groups.length, groups.reversed);
    }
    if (!_filterUnknown.value) {
      final idx = groups.indexWhere((g) => g.name == '未知歌手');
      if (idx >= 0) {
        final unknown = groups.removeAt(idx);
        groups.insert(0, unknown);
      }
    }
  }

  void _showSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SortSheet(
          title: '歌手排序',
          options: const [
            SortOption(key: 'name', label: '名称', icon: Icons.sort_by_alpha),
            SortOption(key: 'songCount', label: '歌曲数', icon: Icons.music_note_outlined),
            SortOption(key: 'albumCount', label: '专辑数', icon: Icons.album_outlined),
          ],
          currentKey: _sortKey.value,
          ascending: _ascending.value,
          onSelectKey: (value) {
            _sortKey.value = value;
            _groups.value = _groups.value.toList();
            _sortGroups(_groups.value);
            _savePrefs();
          },
          onSelectAscending: (value) {
            _ascending.value = value;
            _groups.value = _groups.value.toList();
            _sortGroups(_groups.value);
            _savePrefs();
          },
          extra: Watch.builder(
            builder: (context) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('过滤未知歌手'),
                    value: _filterUnknown.value,
                    onChanged: (v) {
                      _filterUnknown.value = v;
                      _groups.value = _groups.value.toList();
                      _sortGroups(_groups.value);
                      _savePrefs();
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context) {
    final theme = Theme.of(context);
    final groups = _groups.value;
    final isDark = theme.brightness == Brightness.dark;

    if (_loading.value) {
      return const Center(child: CircularProgressIndicator());
    }

    if (groups.isEmpty) {
      return Center(
        child: Text(
          '暂无歌手',
          style: TextStyle(
            color: isDark ? Colors.white70 : const Color.fromARGB(255, 110, 110, 110),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(forceRefresh: true),
      child: MediaListView(
        controller: _controller,
        itemCount: groups.length + (_loadingMore.value ? 1 : 0),
        itemExtent: _itemExtent,
        // 加载更多时不替换整个列表（避免重建 ListView 丢失滚动位置导致跳回顶部），
        // 加载指示器由 itemBuilder 末尾的“转圈条目”承载。
        isLoading: false,
        emptyText: '暂无歌手',
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 160),
        indexLabelBuilder: (index) {
          if (index >= groups.length) return '';
          final name = groups[index].name;
          if (name == '未知歌手') return '↑';
          return IndexUtils.leadingLetter(name);
        },
        itemBuilder: (context, index) {
          if (index >= groups.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            );
          }

          final g = groups[index];
          return MediaListTile(
            leading: _ArtistAvatar(
              coverId: g.artist.coverId,
              name: g.name,
              size: 44,
            ),
            title: g.name,
            subtitle: '专辑：${g.albumCount}  歌曲：${g.songCount}',
            selected: false,
            multiSelect: false,
            isHighlighted: false,
            onTap: () {
              Navigator.of(context).push(
                buildAppPageRoute(
                  (_) => ArtistDetailPage(
                    artistName: g.name,
                    artistGuid: g.artist.guid,
                    onMetadataChanged: (metadata) {
                      if (!mounted) return;
                      _applyMetadataUpdate(g.artist.guid, metadata);
                    },
                  ),
                ),
              );
            },
            onLongPress: () {},
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        appBar: AppTopBar(
          title: '歌手',
          isRefreshing: _isRefreshing.value,
          leading: useBottomNavigation || AppLayoutSettings.tvMode.value
              ? null
              : IconButton(
                  icon: Icon(
                    useBottomNavigation ? Icons.arrow_back_rounded : Icons.menu_rounded,
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
              onPressed: () => Navigator.pushNamed(context, AppRoutes.search, arguments: SearchCategory.artist),
            ),
          ],
        ),
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.closeDrawer(),
              ),
        body: _buildGrid(context),
        bottomNavIndex: useBottomNavigation ? 0 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
      ),
    );
  }
}

class _ArtistAvatar extends StatelessWidget {
  final String? coverId;
  final String name;
  final double size;

  const _ArtistAvatar({
    required this.coverId,
    required this.name,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final radius = size / 2;
    final initial = name.isNotEmpty ? name.characters.first : '?';
    final memoryCacheSize = coverMemoryCacheDimensionOf(context, size);

    if (coverId != null && coverId!.isNotEmpty) {
      final coverUrl = FeiNiuApiClient.instance.coverUrl(
        coverId!,
        size: FeiNiuApiClient.coverRequestSize,
      );
      // 有封面图：完整显示图片，不叠加首字母
      return CircleAvatar(
        radius: radius,
        backgroundImage: ResizeImage.resizeIfNeeded(
          memoryCacheSize,
          memoryCacheSize,
          CachedNetworkImageProvider(
            coverUrl,
            headers: FeiNiuApiClient.imageAuthHeaders(),
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: radius,
      child: Text(initial),
    );
  }
}
