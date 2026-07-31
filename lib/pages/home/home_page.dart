import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:signals/signals.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/feiniu/playlist_service.dart';
import '../../app/services/feiniu/roam_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../components/index.dart';
import '../library/library_detail_pages.dart';
import '../library/playlists_page.dart';

/// 首页缓存
class _HomeCacheData {
  final List<SongEntity>? favorites;
  final List<SongEntity>? recentSongs;
  final List<FeiNiuAlbum>? recentAlbums;
  final List<FeiNiuPlaylist>? playlists;
  final List<SongEntity>? recentTracks;

  _HomeCacheData({
    this.favorites,
    this.recentSongs,
    this.recentAlbums,
    this.playlists,
    this.recentTracks,
  });

  bool get isEmpty =>
      (favorites == null || favorites!.isEmpty) &&
      (recentSongs == null || recentSongs!.isEmpty) &&
      (recentAlbums == null || recentAlbums!.isEmpty) &&
      (playlists == null || playlists!.isEmpty) &&
      (recentTracks == null || recentTracks!.isEmpty);

  Map<String, dynamic> toJson() => {
        'favorites':
            favorites?.map((s) => s.toMap()).toList(),
        'recentSongs':
            recentSongs?.map((s) => s.toMap()).toList(),
        'recentAlbums':
            recentAlbums?.map((a) => a.toJson()).toList(),
        'playlists':
            playlists?.map((p) => p.toJson()).toList(),
        'recentTracks':
            recentTracks?.map((s) => s.toMap()).toList(),
      };

  static _HomeCacheData fromJson(Map<String, dynamic> json) => _HomeCacheData(
        favorites: (json['favorites'] as List?)
            ?.map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
            .toList(),
        recentSongs: (json['recentSongs'] as List?)
            ?.map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
            .toList(),
        recentAlbums: (json['recentAlbums'] as List?)
            ?.map((e) => FeiNiuAlbum.fromJson(e as Map<String, dynamic>))
            .toList(),
        playlists: (json['playlists'] as List?)
            ?.map((e) => FeiNiuPlaylist.fromJson(e as Map<String, dynamic>))
            .toList(),
        recentTracks: (json['recentTracks'] as List?)
            ?.map((e) => SongEntity.fromMap(e as Map<String, dynamic>))
            .toList(),
      );
}

/// 飞牛首页 — 云端音乐仪表板
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SignalsMixin {
  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuRoamService _roam = FeiNiuRoamService.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
  final FeiNiuPlaylistService _playlistService =
      FeiNiuPlaylistService.instance;
  final FeiNiuFavoriteService _favoriteService =
      FeiNiuFavoriteService.instance;
  final PlayerService _player = PlayerService.instance;
  final GlobalKey<AppPageScaffoldState> _scaffoldKey =
      GlobalKey<AppPageScaffoldState>();

  late final _loading = createSignal(true);
  late final _roamSong = createSignal<SongEntity?>(null);
  late final _roamId = createSignal<String?>(null);
  late final _roamQueue = createSignal<List<SongEntity>>([]);
  late final _favoriteSongs = createSignal<List<SongEntity>>([]);
  late final _recentSongs = createSignal<List<SongEntity>>([]);
  late final _recentAlbums = createSignal<List<FeiNiuAlbum>>([]);
  late final _playlists = createSignal<List<FeiNiuPlaylist>>([]);
  late final _recentTracks = createSignal<List<SongEntity>>([]);
  late final _isRefreshing = createSignal(false);

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    const homeCacheScope = 'home';
    const homeCacheKey = 'dashboard';

    // 先尝试加载缓存
    final cachedJson = await ApiCacheManager.instance
        .getPersisted(homeCacheScope, homeCacheKey);
    if (cachedJson != null && mounted) {
      try {
        final cached = _HomeCacheData.fromJson(
            jsonDecode(cachedJson) as Map<String, dynamic>);
        if (!mounted) return;
        if (cached.favorites != null) _favoriteSongs.value = cached.favorites!;
        if (cached.recentSongs != null) _recentSongs.value = cached.recentSongs!;
        if (cached.recentAlbums != null) _recentAlbums.value = cached.recentAlbums!;
        if (cached.playlists != null) _playlists.value = cached.playlists!;
        if (cached.recentTracks != null) _recentTracks.value = cached.recentTracks!;
        _loading.value = false;
        _preloadHomeCovers();
      } catch (e, stack) {
        // 缓存解析失败则忽略，但记录到调试日志便于排查
        debugPrint('[HomePage] cache parse error: $e\n$stack');
      }
    }

    // 后台异步拉取最新数据
    _isRefreshing.value = !_loading.value; // 非首次加载才显示右上角转圈
    await Future.wait([
      _loadRoam(),
      _loadFavorites(),
      _loadRecentHistory(),
      _loadRecentAlbums(),
      _loadPlaylists(),
      _loadRecentTracks(),
    ]);
    if (mounted) {
      _loading.value = false;
      _isRefreshing.value = false;
      _preloadHomeCovers();
      debugPrint(
        '[HomePage] loadAll done: '
        'favorites=${_favoriteSongs.value.length} '
        'history=${_recentSongs.value.length} '
        'albums=${_recentAlbums.value.length} '
        'playlists=${_playlists.value.length} '
        'tracks=${_recentTracks.value.length}',
      );
      // 写缓存
      try {
        final data = _HomeCacheData(
          favorites: _favoriteSongs.value,
          recentSongs: _recentSongs.value,
          recentAlbums: _recentAlbums.value,
          playlists: _playlists.value,
          recentTracks: _recentTracks.value,
        );
        await ApiCacheManager.instance.set(
          scope: homeCacheScope,
          key: homeCacheKey,
          jsonData: jsonEncode(data.toJson()),
          ttlMs: 300000,
        );
      } catch (e, stack) {
        debugPrint('[HomePage] cache write error: $e\n$stack');
      }
    }
  }

  void _preloadHomeCovers() {
    if (!mounted) return;
    final api = FeiNiuApiClient.instance;
    final headers = FeiNiuApiClient.imageAuthHeaders();
    // 预加载首页所有可见封面（最多 40 张）
    final coverUrls = <String>[
      // 收藏歌曲封面
      for (final s in _favoriteSongs.value.take(9))
        if (s.coverId != null && s.coverId!.isNotEmpty)
          api.coverUrl(s.coverId!, size: 120, updatedAt: s.updatedAt),
      // 最近播放封面
      for (final s in _recentSongs.value.take(9))
        if (s.coverId != null && s.coverId!.isNotEmpty)
          api.coverUrl(s.coverId!, size: 120, updatedAt: s.updatedAt),
      // 最近添加歌曲封面
      for (final s in _recentTracks.value.take(9))
        if (s.coverId != null && s.coverId!.isNotEmpty)
          api.coverUrl(s.coverId!, size: 120, updatedAt: s.updatedAt),
      // 专辑封面 — FeiNiuAlbum 无 updatedAt
      for (final a in _recentAlbums.value.take(10))
        if (a.coverId != null && a.coverId!.isNotEmpty)
          api.coverUrl(a.coverId!, size: 120),
      // 歌单封面
      for (final p in _playlists.value.take(10))
        if (p.coverId != null && p.coverId!.isNotEmpty)
          api.coverUrl(p.coverId!, size: 120, updatedAt: p.updatedAt),
    ];
    for (final url in coverUrls) {
      unawaited(precacheImage(
        CachedNetworkImageProvider(url, headers: headers),
        context,
      ));
    }
  }

  Future<void> _loadRoam() async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await _api.getRoamStart(deviceId);
      final roamId = response.current.roamId;
      final track = _trackService.trackToSongEntity(
        response.current.track.toJson(),
      );
      // 把起始曲和下一曲都加到漫游队列
      final queue = <SongEntity>[track];
      if (response.next != null) {
        queue.add(_trackService.trackToSongEntity(
          response.next!.track.toJson(),
        ));
      }
      if (mounted) {
        _roamId.value = roamId;
        _roamSong.value = track;
        _roamQueue.value = queue;
      }
    } catch (e, stack) {
      debugPrint('[HomePage] roam error: $e\n$stack');
    }
  }

  Future<void> _loadFavorites() async {
    try {
      final pageData = await _api.getFavoriteList(size: 10);
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      if (mounted) _favoriteSongs.value = songs;
    } catch (e, stack) {
      debugPrint('[HomePage] favorites error: $e\n$stack');
    }
  }

  Future<void> _loadRecentHistory() async {
    try {
      final pageData = await _api.getPlayHistory(page: 1, size: 10);
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      if (mounted) _recentSongs.value = songs;
    } catch (e, stack) {
      debugPrint('[HomePage] history error: $e\n$stack');
    }
  }

  Future<void> _loadRecentAlbums() async {
    try {
      final pageData =
          await _api.getAlbumList(page: 1, size: 10, sort: 'newTrackAddedAt,desc');
      if (mounted) _recentAlbums.value = pageData.list;
    } catch (e, stack) {
      debugPrint('[HomePage] albums error: $e\n$stack');
    }
  }

  Future<void> _loadPlaylists() async {
    try {
      final pageData = await _api.getPlaylistList();
      if (mounted) _playlists.value = pageData.list;
    } catch (e, stack) {
      debugPrint('[HomePage] playlists error: $e\n$stack');
    }
  }

  Future<void> _loadRecentTracks() async {
    try {
      final pageData =
          await _api.getTrackList(page: 1, size: 10, sort: 'createdAt,desc');
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      if (mounted) _recentTracks.value = songs;
    } catch (e, stack) {
      debugPrint('[HomePage] recent tracks error: $e\n$stack');
    }
  }

  void _playSong(SongEntity song, [List<SongEntity>? queue]) {
    final q = queue ?? [song];
    final idx = q.indexWhere((s) => s.id == song.id);
    _player.playQueue(q, idx >= 0 ? idx : 0);
  }

  /// 漫游播放 — 播放首页当前显示的漫游歌曲，播完后自动下一首随机
  void _playRoam() {
    final song = _roamSong.value;
    if (song == null) return;
    unawaited(_extendAndPlay(song));
  }

  /// 漫游队列扩展器 — 每次队列快播完时调用 roam-next 获取新歌曲追加
  Future<List<SongEntity>> _roamQueueExtender() async {
    try {
      final roamId = _roamId.value;
      if (roamId == null || roamId.isEmpty) return [];

      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await _api.getRoamNext(deviceId, roamId);
      if (response.next == null) return [];

      // 更新 roamId 以便下一次扩展
      _roamId.value = response.next!.roamId;

      final song = _trackService.trackToSongEntity(response.next!.track.toJson());
      return [song];
    } catch (e) {
      debugPrint('[HomePage] roam extend error: $e');
      return [];
    }
  }

  Future<void> _extendAndPlay(SongEntity first) async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await _api.getRoamStart(deviceId);
      // 更新 roamId 供队列扩展器和 PlayerService 随机模式使用
      _roamId.value = response.current.roamId;
      _player.roamId = response.current.roamId;
      final songs = <SongEntity>[first];
      if (response.next != null) {
        songs.add(_trackService.trackToSongEntity(
          response.next!.track.toJson(),
        ));
      }
      if (mounted) {
        // 必须在 playQueue 之后设置扩展器，因为 playQueue 会清除它
        await _player.playQueue(songs, 0);
        // playQueue 会清空 roamId，恢复它
        _player.roamId = response.current.roamId;
        // 切换到随机播放模式，后续走 _appendRoamAndPlay 逻辑
        await _player.setPlaybackMode(PlaybackMode.shuffle);
        _player.queueExtender = _roamQueueExtender;
      }
    } catch (e) {
      debugPrint('[HomePage] roam play error: $e');
      await _player.playQueue([first], 0);
      _player.queueExtender = _roamQueueExtender;
      await _player.setPlaybackMode(PlaybackMode.shuffle);
    }
  }

  void _openAlbumDetail(FeiNiuAlbum album) {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => AlbumDetailPage(albumName: album.name, albumGuid: album.guid),
      ),
    );
  }

  void _openPlaylistDetail(FeiNiuPlaylist playlist) {
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => PlaylistDetailPage(playlistId: playlist.guid),
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
          title: '首页',
          showBackButton: false,
          centerTitle: false,
          isRefreshing: _isRefreshing.value,
          leading: useBottomNavigation
              ? null
              : IconButton(
                  icon: const Icon(Icons.menu_rounded),
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          backgroundColor: Colors.transparent,
          elevation: 0,
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
            return RefreshIndicator(
              onRefresh: _loadAll,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 160),
                children: [
                  // 1. 漫游卡片
                  if (_roamSong.value != null)
                    _HomeSectionCard(
                      title: '漫游',
                      child: _RoamCard(
                        song: _roamSong.value!,
                        onPlay: _playRoam,
                      ),
                    ),
                  const SizedBox(height: 16),

                  // 2. 收藏
                  if (_favoriteSongs.value.isNotEmpty)
                    _HomeSectionCard(
                      title: '收藏',
                      child: _SongGridList(
                        songs: _favoriteSongs.value,
                        onTap: (song) => _playSong(song, _favoriteSongs.value),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // 3. 最近播放
                  if (_recentSongs.value.isNotEmpty)
                    _HomeSectionCard(
                      title: '最近播放',
                      child: _SongGridList(
                        songs: _recentSongs.value,
                        onTap: (song) => _playSong(song, _recentSongs.value),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // 4. 最近添加歌曲
                  if (_recentTracks.value.isNotEmpty)
                    _HomeSectionCard(
                      title: '最近添加歌曲',
                      child: _SongGridList(
                        songs: _recentTracks.value,
                        onTap: (song) =>
                            _playSong(song, _recentTracks.value),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // 5. 最近添加专辑
                  if (_recentAlbums.value.isNotEmpty)
                    _HomeSectionCard(
                      title: '最近添加专辑',
                      child: _AlbumHorizontalList(
                        albums: _recentAlbums.value,
                        onTap: _openAlbumDetail,
                      ),
                    ),
                  const SizedBox(height: 16),

                  // 6. 歌单
                  if (_playlists.value.isNotEmpty)
                    _HomeSectionCard(
                      title: '歌单',
                      child: _PlaylistHorizontalList(
                        playlists: _playlists.value,
                        onTap: _openPlaylistDetail,
                      ),
                    ),
                  const SizedBox(height: 24),

                  // 空状态
                  if (_favoriteSongs.value.isEmpty &&
                      _recentSongs.value.isEmpty &&
                      _recentAlbums.value.isEmpty)
                    const _HomeEmptyState(text: '还没有数据，下拉刷新试试'),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// MARK: - Helper Widgets

class _HomeSectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _HomeSectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6, right: 2, bottom: 10),
          child: Text(
            title,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _SongGridList extends StatelessWidget {
  final List<SongEntity> songs;
  final ValueChanged<SongEntity> onTap;

  const _SongGridList({required this.songs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 竖排3列：第1列 1,4,7... 第2列 2,5,8... 第3列 3,6,9...
    final cols = 3;
    final rows = ((songs.length - 1) ~/ cols) + 1;
    final displayRows = rows > 3 ? 3 : rows;
    return SizedBox(
      height: 62.0 * displayRows + 6.0 * (displayRows - 1),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: List.generate(displayRows, (row) {
            return Padding(
              padding: EdgeInsets.only(top: row > 0 ? 6 : 0),
              child: Row(
                children: List.generate(cols, (col) {
                  final index = col * displayRows + row;
                  if (index >= songs.length) return const SizedBox(width: 180);
                  final song = songs[index];
                  return Padding(
                    padding: EdgeInsets.only(right: col < cols - 1 ? 10 : 0),
                    child: SizedBox(
                      width: 170,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onTap(song),
                        child: Row(
                          children: [
                            Stack(
                              children: [
                                ArtworkWidget(
                                  song: song,
                                  size: 56,
                                  borderRadius: 10,
                                ),
                                Positioned(
                                  right: 2,
                                  bottom: 2,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      color: Colors.white,
                                      size: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
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
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _AlbumHorizontalList extends StatelessWidget {
  final List<FeiNiuAlbum> albums;
  final ValueChanged<FeiNiuAlbum> onTap;

  const _AlbumHorizontalList({required this.albums, required this.onTap});

  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 145,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: albums.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final album = albums[i];
          final coverUrl = album.coverId != null
              ? FeiNiuApiClient.instance.coverUrl(album.coverId!, size: 120)
              : null;
          return SizedBox(
            width: 100,
            child: GestureDetector(
              onTap: () => onTap(album),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: coverUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CachedNetworkImage(
                              imageUrl: coverUrl,
                              httpHeaders: _authHeaders(),
                              width: 100,
                              height: 100,
                              memCacheWidth: 100,
                              memCacheHeight: 100,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => _albumPlaceholder(theme, album.name),
                              errorWidget: (_, __, ___) => _albumPlaceholder(theme, album.name),
                            ),
                          )
                        : _albumPlaceholder(theme, album.name),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (album.trackCount != null)
                    Text(
                      '${album.trackCount} 首',
                      style: TextStyle(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _albumPlaceholder(ThemeData theme, String name) {
    return Center(
      child: Text(
        name.isNotEmpty ? name.characters.first.toUpperCase() : '?',
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _PlaylistHorizontalList extends StatelessWidget {
  final List<FeiNiuPlaylist> playlists;
  final ValueChanged<FeiNiuPlaylist> onTap;

  const _PlaylistHorizontalList(
      {required this.playlists, required this.onTap});

  Map<String, String> _authHeaders() => FeiNiuApiClient.imageAuthHeaders();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 145,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: playlists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final playlist = playlists[i];
          final coverUrl = playlist.coverId != null
              ? FeiNiuApiClient.instance
                  .coverUrl(playlist.coverId!, size: 120, updatedAt: playlist.updatedAt)
              : null;
          return SizedBox(
            width: 100,
            child: GestureDetector(
              onTap: () => onTap(playlist),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: coverUrl != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: CachedNetworkImage(
                              imageUrl: coverUrl,
                              httpHeaders: _authHeaders(),
                              width: 100,
                              height: 100,
                              memCacheWidth: 100,
                              memCacheHeight: 100,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => _playlistPlaceholder(theme),
                              errorWidget: (_, __, ___) => _playlistPlaceholder(theme),
                            ),
                          )
                        : _playlistPlaceholder(theme),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (playlist.trackCount > 0)
                    Text(
                      '${playlist.trackCount} 首',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _playlistPlaceholder(ThemeData theme) {
    return Center(
      child: Icon(Icons.queue_music_rounded, color: theme.colorScheme.primary, size: 40),
    );
  }
}

class _RoamCard extends StatelessWidget {
  final SongEntity song;
  final VoidCallback onPlay;

  const _RoamCard({required this.song, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = const Color(0xFF38A3A5);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onPlay,
      child: Row(
        children: [
          Stack(
            children: [
              ArtworkWidget(
                song: song,
                size: 64,
                borderRadius: 12,
              ),
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: accent,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
        ],
      ),
    );
  }
}

class _HomeEmptyState extends StatelessWidget {
  final String text;

  const _HomeEmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
