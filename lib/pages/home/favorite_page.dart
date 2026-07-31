import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../components/index.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/theme/app_styles.dart';

class FavoritePage extends StatefulWidget {
  const FavoritePage({super.key});

  @override
  State<FavoritePage> createState() => _FavoritePageState();
}

class _FavoritePageState extends State<FavoritePage> with SignalsMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final FeiNiuFavoriteService _favoriteService = FeiNiuFavoriteService.instance;
  final PlayerService _player = PlayerService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _allSongs = createSignal<List<SongEntity>>([]);
  late final _songs = createSignal<List<SongEntity>>([]);
  late final _loading = createSignal(true);
  late final _isRefreshing = createSignal(false);
  late final _sortKey = createSignal('favoriteAt');
  late final _ascending = createSignal(false);
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchVisible = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    const cacheKey = 'all';

    Future<List<SongEntity>> fetch() async {
      final pageData = await _api.getFavoriteList(
        page: 1,
        size: -1,
        sort: '${_sortKey.value},${_ascending.value ? 'asc' : 'desc'}',
      );
      return pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
    }

    if (forceRefresh) {
      _isRefreshing.value = true;
      try {
        final songs = await fetch();
        if (mounted) {
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
    _player.playQueue(songs, index);
  }

  Future<void> _unfavoriteSong(SongEntity song, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定取消收藏「${song.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await _favoriteService.unfavorite(song.id);
        if (!mounted) return;
        final updated = List<SongEntity>.from(_allSongs.value)..removeAt(index);
        _allSongs.value = updated;
        _applyFilter();
      } catch (e) {
        if (!mounted) return;
        AppToast.show(context, '操作失败', type: ToastType.error);
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) => AppPageScaffold(
        key: _scaffoldKey,
        extendBodyBehindAppBar: true,
        drawer: useBottomNavigation
            ? null
            : SideMenu(
                onCloseDrawer: () => _scaffoldKey.currentState?.openDrawer(),
              ),
        bottomNavIndex: useBottomNavigation ? 3 : null,
        onBottomNavTap: useBottomNavigation
            ? (index) => navigateToPrimaryDestination(context, index)
            : null,
        appBar: AppTopBar(
          title: '收藏',
          showBackButton: false,
          isRefreshing: _isRefreshing.value,
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: useBottomNavigation
              ? null
              : IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          actions: [
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
                                onTap: () => _player.playShuffle(_songs.value),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: Icon(
                                    Icons.shuffle_rounded,
                                    size: 18,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              Text(
                                '共 ${_allSongs.value.length} 首',
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 160),
                            itemCount: songs.length,
                            itemBuilder: (context, index) {
                              final song = songs[index];
                              return InkWell(
                                onTap: () => _playSong(index),
                                onLongPress: () => _unfavoriteSong(song, index),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    children: [
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
