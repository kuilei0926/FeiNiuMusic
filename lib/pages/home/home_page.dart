import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_page_route.dart';
import '../../app/router/app_router.dart';
import '../../app/services/feiniu/api_client.dart';
import '../../app/services/feiniu/api_models.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/feiniu/track_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../app/tv/tv_layout.dart';
import '../../app/utils/api_cache_manager.dart';
import '../../app/utils/primary_tab_refresh_mixin.dart';
import '../../components/index.dart';
import '../library/library_detail_pages.dart';
import '../library/playlists_page.dart';
import '../songs/song_detail_sheet.dart';
import '../songs/songs_page.dart';
import 'widgets/home_cover_carousel.dart';
import 'widgets/home_hero_banner.dart';
import 'widgets/home_quick_actions.dart';
import 'widgets/home_section_header.dart';
import 'widgets/home_shortcut_menu.dart';

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
    'favorites': favorites?.map((s) => s.toMap()).toList(),
    'recentSongs': recentSongs?.map((s) => s.toMap()).toList(),
    'recentAlbums': recentAlbums?.map((a) => a.toJson()).toList(),
    'playlists': playlists?.map((p) => p.toJson()).toList(),
    'recentTracks': recentTracks?.map((s) => s.toMap()).toList(),
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

/// 首页播放数据源：决定点播放时按队列上限请求哪个 API 填充完整队列。
enum _HomePlaySource {
  favorites,
  recentHistory,
  recentTracks,
}

/// 飞牛首页 — 云端音乐仪表板
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SignalsMixin, PrimaryTabRefreshMixin {
  final FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final FeiNiuTrackService _trackService = FeiNiuTrackService.instance;
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
    _maybeShowTvEdgeHint();
  }

  /// TV 首次启动：展示「按右键打开播放页」提示（只一次，会话级别持久化）。
  void _maybeShowTvEdgeHint() {
    if (!AppLayoutSettings.tvMode.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!await AppLayoutSettings.consumeTvEdgeHint()) return;
      if (!mounted) return;
      AppToast.show(context, '遥控器：按 ← 打开侧栏，按 → 打开播放页');
    });
  }

  @override
  int get primaryTabIndex => 0;

  @override
  Future<void> onPrimaryTabActivated() async {
    if (mounted) await _loadAll();
  }

  Future<void> _loadAll({bool forceRefresh = false}) async {
    const homeCacheScope = 'home';
    const homeCacheKey = 'dashboard';

    // 缓存永久保留（读取 ignoreTtl，TTL 不淘汰），但只用于快速渲染：
    // 命中后立即展示，同时继续在后台异步刷新数据，完成后覆盖缓存。
    if (!forceRefresh) {
      final cachedJson = await ApiCacheManager.instance.getPersisted(
        homeCacheScope,
        homeCacheKey,
      );
      if (cachedJson != null && mounted) {
        try {
          final cached = _HomeCacheData.fromJson(
            jsonDecode(cachedJson) as Map<String, dynamic>,
          );
          if (!mounted) return;
          if (cached.favorites != null) {
            _favoriteSongs.value = cached.favorites!;
          }
          if (cached.recentSongs != null) {
            _recentSongs.value = cached.recentSongs!;
          }
          if (cached.recentAlbums != null) {
            _recentAlbums.value = cached.recentAlbums!;
          }
          if (cached.playlists != null) {
            _playlists.value = cached.playlists!;
          }
          if (cached.recentTracks != null) {
            _recentTracks.value = cached.recentTracks!;
          }
          _loading.value = false;
          _preloadHomeCovers();
        } catch (e, stack) {
          // 缓存解析失败则忽略，但记录到调试日志便于排查
          debugPrint('[HomePage] cache parse error: $e\n$stack');
        }
      }
    }

    // 后台异步刷新最新数据（缓存渲染后继续执行），完成后写回缓存
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
      // 写回缓存（永久保留，下次启动仍用于渲染）
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
      // Hero Banner 主视觉 — 大尺寸首帧
      if (_heroSong != null &&
          _heroSong!.coverId != null &&
          _heroSong!.coverId!.isNotEmpty)
        api.coverUrl(_heroSong!.coverId!, size: 800, updatedAt: _heroSong!.updatedAt),
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
          api.coverUrl(a.coverId!, size: 300),
      // 歌单封面
      for (final p in _playlists.value.take(10))
        if (p.coverId != null && p.coverId!.isNotEmpty)
          api.coverUrl(p.coverId!, size: 300, updatedAt: p.updatedAt),
    ];
    for (final url in coverUrls) {
      if (!mounted) break;
      try {
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(url, headers: headers),
            context,
          ),
        );
      } catch (_) {
        // 外壳可能正在卸载：deactivate 到 unmount 之间的窗口内 State.mounted
        // 仍为 true（_element 尚未置空），但元素已失活，precacheImage 内部的
        // DefaultAssetBundle.of(context) 会抛 "Looking up a deactivated
        // widget's ancestor"。封面预加载是尽力而为的缓存预热，跳过即可。
      }
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
        queue.add(
          _trackService.trackToSongEntity(response.next!.track.toJson()),
        );
      }
      debugPrint(
        '[HomePage] loadRoam roamId=$roamId current=${track.id} '
        'queue=[${queue.map((s) => s.id).join(',')}]',
      );
      if (mounted) {
        _roamId.value = roamId;
        _roamSong.value = track;
        _roamQueue.value = queue;
      }
    } catch (e, stack) {
      debugPrint('[HomePage] roam error: $e\n$stack');
    }
  }

  /// 漫游刷新：换一首漫游歌曲（不打断播放）。
  ///
  /// 用 roam-next 拉取下一首，更新 Banner 显示与 _roamId 供队列扩展器使用。
  /// 若当前正在漫游播放，则把新歌插入「下一首」，播完当前后自然接上。
  Future<void> _refreshRoam() async {
    final currentRoamId = _roamId.value;
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final song = await _fetchNextRoamSong(deviceId, currentRoamId);
      if (song == null || !mounted) return;
      _roamSong.value = song;
      // 正在漫游播放时，把新歌插到当前之后，播完自然接上
      if (_player.isPlaying.value && _player.queueExtender != null) {
        await _player.insertNext([song]);
        _roamQueue.value = [..._roamQueue.value, song];
      } else {
        _roamQueue.value = [song];
      }
    } catch (e, stack) {
      debugPrint('[HomePage] refresh roam error: $e\n$stack');
    }
  }

  /// 拉取下一首漫游歌曲并推进 roamId。
  /// 无 roamId 时用 roam-start 取起始曲（fallback），否则 roam-next。
  Future<SongEntity?> _fetchNextRoamSong(
    String deviceId,
    String? currentRoamId,
  ) async {
    try {
      if (currentRoamId == null || currentRoamId.isEmpty) {
        final start = await _api.getRoamStart(deviceId);
        _roamId.value = start.current.roamId;
        return _trackService.trackToSongEntity(
          start.current.track.toJson(),
        );
      }
      final next = await _api.getRoamNext(deviceId, currentRoamId);
      if (next.next == null) return null;
      _roamId.value = next.next!.roamId;
      return _trackService.trackToSongEntity(next.next!.track.toJson());
    } catch (e) {
      debugPrint('[HomePage] fetch next roam error: $e');
      AppToast.showGlobal('获取漫游歌曲失败', type: ToastType.error);
      return null;
    }
  }

  Future<void> _loadFavorites() async {
    try {
      // 首页只展示前几首，轻量加载 10 首；点播放时再按队列上限拉完整列表
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
      final pageData = await _api.getAlbumList(
        page: 1,
        size: 10,
        sort: 'newTrackAddedAt,desc',
      );
      if (mounted) _recentAlbums.value = pageData.list;
    } catch (e, stack) {
      debugPrint('[HomePage] albums error: $e\n$stack');
    }
  }

  Future<void> _loadPlaylists() async {
    try {
      final pageData = await _api.getPlaylistList(page: 1, size: 10);
      if (mounted) _playlists.value = pageData.list;
    } catch (e, stack) {
      debugPrint('[HomePage] playlists error: $e\n$stack');
    }
  }

  Future<void> _loadRecentTracks() async {
    try {
      final pageData = await _api.getTrackList(
        page: 1,
        size: 10,
        sort: 'createdAt,desc',
      );
      final songs = pageData.list
          .map((t) => _trackService.trackToSongEntity(t.toJson()))
          .toList();
      if (mounted) _recentTracks.value = songs;
    } catch (e, stack) {
      debugPrint('[HomePage] recent tracks error: $e\n$stack');
    }
  }

  /// 长按歌曲 → 弹出与歌曲页同款的长按面板
  void _showSongDetail(SongEntity song) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(song: song),
    );
  }

  /// 漫游播放 — 播放首页当前显示的漫游歌曲，播完后自动下一首随机。
  ///
  /// 用 [_heroSong] 兜底：漫游歌未加载时（接口失败/卡住），Banner 显示的是
  /// 收藏/最近兜底歌，点击播放必须与其一致，否则「显示歌 ≠ 实际播放」。
  void _playRoam() {
    final song = _heroSong;
    if (song == null) {
      debugPrint('[HomePage] playRoam: no song available');
      return;
    }
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

      final song = _trackService.trackToSongEntity(
        response.next!.track.toJson(),
      );
      return [song];
    } catch (e) {
      debugPrint('[HomePage] roam extend error: $e');
      return [];
    }
  }

  Future<void> _extendAndPlay(SongEntity first) async {
    try {
      // 直接用 banner 当前漫游链：_loadRoam 已用 getRoamStart 拿到
      // current（显示歌）+ next，并存于 _roamQueue / _roamId。用这套队列
      // 播放既保证播的是 banner 显示的歌，又保证队列、roamId 同一条链，
      // 点下一曲不会新开队列。
      var songs = _roamQueue.value;
      if (songs.isEmpty) {
        songs = [first];
      }
      final roamId = _roamId.value;
      if (mounted) {
        // mode: shuffle + roamId 直接传入 playQueue：playQueue 内部会清空
        // 再恢复 roamId，消除「返回后手动恢复」的时序窗口，确保点下一曲时
        // 走 roam-next 追加分支而非 getRoamStart 新开队列。
        debugPrint(
          '[HomePage] extendAndPlay queue=${songs.map((s) => s.title).join(',')} '
          'roamId=$roamId',
        );
        await _player.playQueue(
          songs,
          0,
          mode: PlaybackMode.shuffle,
          roamChainId: roamId,
        );
        debugPrint('[HomePage] extendAndPlay done, roamId=$roamId');
        // 后续走 PlayerService 内部漫游扩展逻辑（随机模式下播完/切歌追加下一首）
        _player.queueExtender = _roamQueueExtender;
      }
    } catch (e) {
      debugPrint('[HomePage] roam play error: $e');
      await _player.playQueue(
        [first],
        0,
        mode: PlaybackMode.shuffle,
        roamChainId: _roamId.value,
      );
      _player.queueExtender = _roamQueueExtender;
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

  /// 漫游歌曲为空时，用第一首收藏/最近歌曲兜底，保证 Hero 始终有内容
  SongEntity? get _heroSong {
    final roam = _roamSong.value;
    if (roam != null) return roam;
    if (_favoriteSongs.value.isNotEmpty) return _favoriteSongs.value.first;
    if (_recentSongs.value.isNotEmpty) return _recentSongs.value.first;
    if (_recentTracks.value.isNotEmpty) return _recentTracks.value.first;
    return null;
  }

  void _openPlaylistsPage() {
    Navigator.of(context).pushNamed(AppRoutes.playlists);
  }

  void _openSongsPage() {
    // 从首页「最新歌曲」进入：一次性按创建时间降序（不回写偏好，仅本次有效）
    Navigator.of(context).push(
      buildAppPageRoute<void>(
        (_) => const SongsPage(
          initialSortKey: 'duration',
          initialAscending: false,
        ),
      ),
    );
  }

  void _openArtistsPage() {
    Navigator.of(context).pushNamed(AppRoutes.artists);
  }

  void _openAlbumsPage() {
    Navigator.of(context).pushNamed(AppRoutes.albums);
  }

  void _openGenresPage() {
    Navigator.of(context).pushNamed(AppRoutes.genres);
  }

  void _openRecentPage() {
    Navigator.of(context).pushNamed(AppRoutes.recent);
  }

  void _openFavoritePage() {
    Navigator.of(context).pushNamed(AppRoutes.favorites);
  }

  /// 直接播放一个列表（收藏/最近播放）。列表为空时退回漫游随机播放。
  ///
  /// [source] 指定首页数据源：列表只是 10 首预览，播放时按队列上限
  /// 请求完整列表填充队列，而不是只播预览的 10 首。
  void _playFromList(List<SongEntity> songs, _HomePlaySource source) {
    if (songs.isEmpty) {
      _playRoam();
      return;
    }
    unawaited(_playListWithFullFetch(songs, source, playIndex: 0));
  }

  /// 从首页歌曲行播放：队列用完整列表（若已拉过完整列表则直接复用）。
  void _playHomeSong(SongEntity song, List<SongEntity> preview) {
    unawaited(
      _playListWithFullFetch(preview, _HomePlaySource.recentTracks, song: song),
    );
  }

  /// 按队列长度上限请求完整列表填充队列后播放。
  ///
  /// 首页只展示前 10 首（轻量加载），点播放时才拉完整列表做队列：
  /// - [source] 决定走哪个 API（收藏/最近/最新歌曲）
  /// - 已有完整列表缓存（[fullCache]）时直接复用，避免重复请求
  Future<void> _playListWithFullFetch(
    List<SongEntity> preview,
    _HomePlaySource source, {
    SongEntity? song,
    int playIndex = 0,
    List<SongEntity>? fullCache,
  }) async {
    var queue = fullCache ?? preview;
    if (fullCache == null) {
      try {
        final limit = AppPlaybackQueueSettings.maxQueueLength.value;
        final full = await _fetchFullSource(source, limit);
        if (full.isNotEmpty) queue = full;
      } catch (e) {
        debugPrint('[HomePage] fetch full queue error: $e');
      }
    }
    if (!mounted) return;
    if (song != null) {
      final idx = queue.indexWhere((s) => s.id == song.id);
      _player.playQueue(queue, idx >= 0 ? idx : 0);
    } else {
      final idx = playIndex.clamp(0, queue.length - 1);
      _player.playQueue(queue, idx);
    }
  }

  /// 请求某一数据源的完整列表（按队列上限）。
  Future<List<SongEntity>> _fetchFullSource(
    _HomePlaySource source,
    int limit,
  ) async {
    final tracks = switch (source) {
      _HomePlaySource.favorites => await _api.getFavoriteList(size: limit),
      _HomePlaySource.recentHistory => await _api.getPlayHistory(
        page: 1,
        size: limit,
      ),
      _HomePlaySource.recentTracks => await _api.getTrackList(
        page: 1,
        size: limit,
        sort: 'createdAt,desc',
      ),
    };
    return tracks.list
        .map((t) => _trackService.trackToSongEntity(t.toJson()))
        .toList();
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
          leading: useBottomNavigation || AppLayoutSettings.tvMode.value
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
            final heroSong = _heroSong;
            return RefreshIndicator(
              onRefresh: () => _loadAll(forceRefresh: true),
              child: ListView(
                padding: AppLayoutSettings.tvMode.value
                    ? TvLayout.pagePadding()
                    : const EdgeInsets.fromLTRB(20, 8, 20, 160),
                children: [
                  // 1. Hero Banner — 漫游/今日推荐，封面是绝对主角
                  if (heroSong != null)
                    HomeHeroBanner(
                      song: heroSong,
                      onPlay: _playRoam,
                      onRefresh: _refreshRoam,
                    ),

                  if (heroSong != null) const SizedBox(height: 16),

                  // 1.5 快捷菜单 — 歌曲 / 歌手 / 专辑 / 风格（4×1）
                  HomeShortcutMenu(
                    items: [
                      HomeShortcutItem(
                        icon: Icons.music_note_rounded,
                        label: '歌曲',
                        accent: const Color(0xFF3B82F6),
                        onTap: _openSongsPage,
                      ),
                      HomeShortcutItem(
                        icon: Icons.people_rounded,
                        label: '歌手',
                        accent: const Color(0xFF14B8A6),
                        onTap: _openArtistsPage,
                      ),
                      HomeShortcutItem(
                        icon: Icons.album_rounded,
                        label: '专辑',
                        accent: const Color(0xFFA855F7),
                        onTap: _openAlbumsPage,
                      ),
                      HomeShortcutItem(
                        icon: Icons.music_video_rounded,
                        label: '风格',
                        accent: const Color(0xFFF97316),
                        onTap: _openGenresPage,
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // 2. 功能入口 — 收藏 / 最近播放，各带直接播放按钮
                  HomeQuickActions(
                    actions: [
                      HomeQuickAction(
                        icon: Icons.history_rounded,
                        title: '最近播放',
                        subtitle: '接着上次听',
                        accent: const Color(0xFF14B8A6),
                        onTap: _openRecentPage,
                        onPlay: () =>
                            _playFromList(_recentSongs.value, _HomePlaySource.recentHistory),
                      ),
                      HomeQuickAction(
                        icon: Icons.favorite_rounded,
                        title: '收藏',
                        subtitle: '我的最爱',
                        accent: const Color(0xFFEC4899),
                        onTap: _openFavoritePage,
                        onPlay: () =>
                            _playFromList(_favoriteSongs.value, _HomePlaySource.favorites),
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // 3. 我的歌单 — 横向封面轮播（尺寸小于专辑）
                  if (_playlists.value.isNotEmpty) ...[
                    HomeSectionHeader(
                      title: '我的歌单',
                      onViewAll: _openPlaylistsPage,
                    ),
                    HomeCoverCarousel(
                      coverSize: AppLayoutSettings.tvMode.value ? 140 : 100,
                      borderRadius: 14,
                      centerText: true,
                      items: [
                        for (final p in _playlists.value)
                          HomeCoverItem(
                            coverId: p.coverId,
                            updatedAt: p.updatedAt,
                            title: p.name,
                            // 歌单没有数量副标题，空串不占行，避免卡片下方留白
                            subtitle: '',
                            onTap: () => _openPlaylistDetail(p),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 4. 最新歌曲 — 紧凑竖排行列表
                  if (_recentTracks.value.isNotEmpty) ...[
                    HomeSectionHeader(
                      title: '最新歌曲',
                      onViewAll: _openSongsPage,
                    ),
                    _CompactSongList(
                      songs: _recentTracks.value,
                      onTap: (song) => _playHomeSong(song, _recentTracks.value),
                      onLongPress: _showSongDetail,
                    ),
                    const SizedBox(height: 16),
                  ],

                  // 5. 最新专辑 — 横向大封面轮播
                  if (_recentAlbums.value.isNotEmpty) ...[
                    HomeSectionHeader(
                      title: '最新专辑',
                      onViewAll: () {
                        Navigator.of(context).pushNamed(AppRoutes.albums);
                      },
                    ),
                    HomeCoverCarousel(
                      coverSize: AppLayoutSettings.tvMode.value ? 168 : 128,
                      borderRadius: 16,
                      items: [
                        for (final a in _recentAlbums.value)
                          HomeCoverItem(
                            coverId: a.coverId,
                            title: a.name,
                            subtitle: a.trackCount != null
                                ? '${a.trackCount} 首'
                                : '',
                            onTap: () => _openAlbumDetail(a),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],

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

// MARK: - 紧凑歌曲列表

/// 最新歌曲 — 紧凑竖排行列表（封面 44 + 两行文字 + 播放按钮）
class _CompactSongList extends StatelessWidget {
  final List<SongEntity> songs;
  final ValueChanged<SongEntity> onTap;
  final ValueChanged<SongEntity>? onLongPress;

  const _CompactSongList({
    required this.songs,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTv = AppLayoutSettings.tvMode.value;
    final artworkSize = isTv ? 56.0 : 44.0;
    final displaySongs = songs.take(5).toList();
    return Column(
      children: List.generate(displaySongs.length, (i) {
        final song = displaySongs[i];
        return Padding(
          padding: EdgeInsets.only(bottom: i < displaySongs.length - 1 ? 6 : 0),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onTap(song),
              onLongPress: onLongPress == null ? null : () => onLongPress!(song),
              child: Padding(
                // TV 端加大行高与封面，方便遥控器聚焦。
                padding: EdgeInsets.symmetric(
                  horizontal: isTv ? 12 : 6,
                  vertical: isTv ? 8 : 5,
                ),
                child: Row(
                  children: [
                    ArtworkWidget(
                      song: song,
                      size: artworkSize,
                      borderRadius: 10,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
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
                          const SizedBox(height: 1),
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
                    Icon(
                      Icons.play_circle_outline_rounded,
                      size: 28,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
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
