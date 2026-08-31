import 'dart:async';
import 'dart:io' as io;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/lyrics/lyrics_service.dart';
import '../services/feiniu/api_client.dart';
import '../services/feiniu/api_models.dart';
import '../services/feiniu/favorite_service.dart';
import '../services/feiniu/track_service.dart';
import '../state/song_state.dart';
import '../state/settings_state.dart';
import 'android_platform_service.dart';
import 'cover_local_cache.dart';
import 'media_notification_car_lyrics.dart';
import 'player_service.dart';

class MediaNotificationService {
  static AudioHandler? _audioHandler;
  static VoidCallback? _initListener;
  static bool _initStarted = false;

  /// AudioService.init 单次握手超时。Android Auto 场景下 configure 存在竞态
  /// （后台引擎先绑定 MediaBrowserService 时，configureResult 可能永远等不到
  /// onServiceConnected），挂起会让启动界面卡死、车机浏览转圈。超时后按
  /// [_retryAfter] 自动重试——竞态在首次连接完成后重试通常立即成功。
  static const Duration _initTimeout = Duration(seconds: 10);
  static const Duration _retryAfter = Duration(seconds: 3);
  static int _initAttempts = 0;
  static Timer? _retryTimer;

  static Future<void> init({bool force = false}) async {
    // Android 走 MediaSession / 通知栏，iOS/macOS 走 MPNowPlayingInfoCenter；
    // 其他平台没有 audio_service 原生实现，播放本身不依赖它。
    if (!io.Platform.isAndroid && !io.Platform.isIOS && !io.Platform.isMacOS) {
      return;
    }
    if (_audioHandler != null || _initStarted) return;
    await MediaNotificationSettings.ensureLoaded();
    final player = PlayerService.instance;
    final snap = player.snapshot.value;
    if (!force && snap.song == null && !snap.isPlaying) {
      // Android Auto / 系统媒体中心通过 MediaBrowserService 发现应用；
      // iOS/macOS 也应提前建立 AudioHandler，首次播放时才能立即把媒体信息
      // 发布到 MPNowPlayingInfoCenter。
      // 即使当前没有播放内容也要注册 MediaSession，否则首次连接车机时
      // 启动器里看不到本应用（要等用户手动播一首歌才会出现）。
      // 其他平台保持原有延迟注册行为。
      if (io.Platform.isAndroid || io.Platform.isIOS || io.Platform.isMacOS) {
        try {
          await _initHandler();
        } catch (e) {
          _debugLog('eager init failed, will retry on first play: $e');
        }
      }
      if (_initListener == null) {
        _initListener = () {
          final current = player.snapshot.value;
          if (current.song == null && !current.isPlaying) return;
          if (_initListener != null) {
            player.snapshot.removeListener(_initListener!);
            _initListener = null;
          }
          init(force: true);
        };
        player.snapshot.addListener(_initListener!);
      }
      return;
    }
    await _initHandler();
  }

  static Future<void> _initHandler() async {
    if (_audioHandler != null || _initStarted) return;
    _initStarted = true;
    _retryTimer?.cancel();
    _debugLog('init start (attempt ${_initAttempts + 1})');
    try {
      // 竞态兜底：AudioService.init 在 Android Auto 后台引擎场景可能挂起
      // （configure 等不到 onServiceConnected）。加超时避免启动界面/车机
      // 被永久卡死；失败进入 _scheduleRetry。
      _audioHandler = await AudioService.init(
        builder: () => _FeiNiuAudioHandler(PlayerService.instance),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.feiniu.music.playback',
          androidNotificationChannelName: '音乐播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidShowNotificationBadge: false,
          androidBrowsableRootExtras: <String, dynamic>{
            AndroidContentStyle.supportedKey: true,
            AndroidContentStyle.browsableHintKey:
                AndroidContentStyle.listItemHintValue,
          },
        ),
      ).timeout(_initTimeout);
      _initAttempts = 0;
      _debugLog('init completed');
    } catch (e) {
      _debugLog('AudioService.init failed/timeout: $e');
      _scheduleRetry();
    } finally {
      _initStarted = false;
    }
  }

  /// 定时重试。竞态在连接建立后重试通常立即成功；最多重试若干次避免无限循环。
  static void _scheduleRetry() {
    if (_initAttempts >= 5) {
      _debugLog('give up init after $_initAttempts attempts');
      return;
    }
    _initAttempts++;
    _retryTimer?.cancel();
    _retryTimer = Timer(_retryAfter, () {
      unawaited(_initHandler());
    });
  }

  static void _debugLog(String message) {
    debugPrint('[MediaNotification] $message');
  }
}

class _FeiNiuAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final PlayerService player;
  static const String _actionCloseApp = 'close_app';
  static const String _actionFavorite = 'favorite';
  String? _currentLyricLine;
  String? _lastSongId;
  bool _isFavorite = false;
  String? _lastQueueKey;
  List<String> _publishedQueueIds = const <String>[];
  String? _roamQueueAnchorId;
  List<SongEntity>? _stableRoamQueue;
  String? _lastMediaItemKey;
  String? _lastPlaybackStateKey;
  bool _supportsCustomActions = true;
  bool _notificationPermissionRequested = false;

  // 封面本地缓存
  String? _coverDirPath;
  String? _lastCoverId;
  Uri? _cachedCoverUri;

  /// 当前曲目封面本地文件路径。当前曲目的 Metadata 用 `file://` 指向它
  /// （对齐 NagoMusic 实机验证方案），audio_service 按 artCacheFile 让原生
  /// 侧内嵌 ALBUM_ART Bitmap；妙播媒体卡片读内嵌 Bitmap 显示封面。
  String? _cachedCoverPath;

  /// 切歌时是否正在解析当前歌曲封面。解析期间抑制 [_syncMediaItem]，
  /// 避免把「无 Bitmap」的 Metadata 先发布给系统（HyperOS 妙播卡片一旦
  /// 以无封面状态渲染，后续 artUri 更新不会刷新）。
  bool _coverResolving = false;

  /// 切歌时等待封面解析的最大时长。缓存命中是瞬时操作；超时后回退远程
  /// URL 兜底，避免封面下载拖慢媒体卡片的标题/歌手显示。
  static const Duration _coverResolveTimeout = Duration(seconds: 2);

  /// 媒体会话封面下载尺寸。120px 会被小米图像管线判为「small resolution」
  /// （日志：JpegXmCodec::isSupported returns false for small resolution），
  /// 妙播媒体卡片不渲染。用 512px 内嵌 Bitmap（客户端按需缩放）并作为
  /// ALBUM_ART_URI 指向的较大版本。
  static const int _systemCoverSize = FeiNiuApiClient.coverRequestSize;

  final Map<String, _CarBrowseSong> _browseSongs = <String, _CarBrowseSong>{};
  Future<void>? _apiAuthReady;

  static const String _browseHomeId = 'car:home';
  static const String _browseTracksId = 'car:home:tracks';
  static const String _browseArtistsId = 'car:home:artists';
  static const String _browseAlbumsId = 'car:home:albums';
  static const String _browseGenresId = 'car:home:genres';
  static const String _browseHistoryId = 'car:history';
  static const String _browseFavoritesId = 'car:favorites';
  static const String _browseRoamId = 'car:roam';
  static const String _browseRoamStartId = 'car:roam:start';
  static const String _browseSearchId = 'car:search';
  static const String _browseArtistPrefix = 'car:artist:';
  static const String _browseAlbumPrefix = 'car:album:';
  static const String _browseGenrePrefix = 'car:genre:';
  static const String _carDrawableUriPrefix =
      'android.resource://com.feiniu.music/drawable/';
  static const String _defaultAlbumArtworkName = 'ic_car_album';

  _FeiNiuAudioHandler(this.player) {
    player.snapshot.addListener(_syncFromPlayer);
    LyricsService.instance.currentLineText.addListener(_onLyricLineChanged);
    MediaNotificationSettings.showLyrics.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.lyricOnTop.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.showCloseAction.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.showFavoriteAction.addListener(
      _onNotificationSettingsChanged,
    );
    MediaNotificationSettings.carBluetoothLyrics.addListener(
      _onNotificationSettingsChanged,
    );
    _currentLyricLine = LyricsService.instance.currentLineText.value;
    _loadPlatformCapabilities();
    _syncFromPlayer();
  }

  Future<void> _loadPlatformCapabilities() async {
    _supportsCustomActions = await AndroidPlatformService.instance
        .supportsNotificationCustomActions();
    _debugLog('supports custom actions=$_supportsCustomActions');
    _lastPlaybackStateKey = null;
    _syncPlaybackState(player.snapshot.value);
  }

  void _debugLog(String message) {
    // 使用 debugPrint 让日志在 DebugLogService 开启时可见
    debugPrint('[MediaNotification] $message');
  }

  // ---- 封面图本地缓存 ----

  /// flutter_cache_manager（CachedNetworkImage 共用）实例，
  /// 封面图在 App 内已被 CachedNetworkImage 下载过，直接拿本地文件即可。
  static final DefaultCacheManager _coverCache = DefaultCacheManager();

  Future<String> _coverDir() async {
    if (_coverDirPath == null) {
      final dir = await getTemporaryDirectory();
      _coverDirPath = '${dir.path}/notification_covers';
      await io.Directory(_coverDirPath!).create(recursive: true);
    }
    return _coverDirPath!;
  }

  /// 从 flutter_cache_manager 获取本地封面文件。
  /// Android 系统通知栏加载 artUri 时不携带 Cookie 认证头，
  /// 所以必须使用本地文件 URI 而不是远程 API URL。
  Future<Uri?> _getLocalCoverUri(String coverId, {int? updatedAt}) async {
    final url = FeiNiuApiClient.instance.coverUrl(
      coverId,
      size: _systemCoverSize,
      updatedAt: updatedAt,
    );
    _debugLog('getLocalCoverUri coverId=$coverId url=$url');

    // 1. 先查 flutter_cache_manager 已有缓存（CachedNetworkImage 可能已下载过）
    try {
      final cacheObject = await _coverCache.getFileFromCache(url);
      if (cacheObject != null) {
        final cachedPath = cacheObject.file.path;
        _debugLog('cache hit path=$cachedPath');
        final cachedFile = io.File(cachedPath);
        if (await cachedFile.exists()) {
          return Uri.file(cachedPath);
        }
        _debugLog('cache file not found on disk path=$cachedPath');
      } else {
        _debugLog('cache miss');
      }
    } catch (e) {
      _debugLog('get local cover from cache failed: $e');
    }

    // 2. 让 flutter_cache_manager 下载到缓存（带认证头，完成后加入缓存池）
    try {
      // getSingleFile 返回 package:file 的 File 对象，与 dart:io File 不兼容
      final cacheFile = await _coverCache.getSingleFile(
        url,
        headers: FeiNiuApiClient.imageAuthHeaders(),
      );
      final localPath = cacheFile.path;
      _debugLog('getSingleFile ok path=$localPath');
      final localFile = io.File(localPath);
      if (await localFile.exists()) {
        return Uri.file(localPath);
      }
      _debugLog('getSingleFile file not found on disk');
    } catch (e) {
      _debugLog('get local cover via cache manager failed: $e');
    }

    // 3. fallback：下载到 notification_covers 目录（自签名证书兼容）
    try {
      final dir = await _coverDir();
      final suffix = updatedAt != null && updatedAt > 0 ? '_$updatedAt' : '';
      final filePath = '$dir/${coverId}_512$suffix.jpg';
      final file = io.File(filePath);
      if (await file.exists()) {
        _debugLog('fallback file exists path=$filePath');
        return Uri.file(filePath);
      }

      _debugLog('fallback downloading url=$url');
      final httpClient = io.HttpClient()
        ..badCertificateCallback = (_, _, _) => true;
      try {
        final request = await httpClient.getUrl(Uri.parse(url));
        if (FeiNiuApiClient.instance.token.isNotEmpty) {
          final headers = FeiNiuApiClient.instance.authHeaders();
          for (final entry in headers.entries) {
            request.headers.set(entry.key, entry.value);
          }
        }
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          _debugLog('fallback download ok size=${bytes.length}');
          await file.writeAsBytes(bytes);
          return Uri.file(filePath);
        }
        _debugLog('fallback download failed status=${response.statusCode}');
      } finally {
        httpClient.close(force: true);
      }
    } catch (e) {
      _debugLog('cover download fallback failed: $e');
    }
    _debugLog('getLocalCoverUri returning null');
    return null;
  }

  // ---- MediaItem / PlaybackState 构建 ----

  /// [current] 为 true 表示构建「当前播放曲目」的 MediaItem：artUri 用
  /// file:// 本地路径（对齐 NagoMusic 实机验证的方案），audio_service 按
  /// artCacheFile 让原生侧内嵌 ALBUM_ART Bitmap，妙播媒体卡片直接读内嵌
  /// Bitmap。队列/浏览条目（[current] 为 false）仍用 content://，供
  /// Android Auto 等外部进程读取。
  MediaItem _itemFromSong(SongEntity song, {bool current = false}) {
    final lyricLine = MediaNotificationSettings.showLyrics.value
        ? _currentLyricLine
        : null;
    final titleText = song.title.trim();
    final artistText = song.artistDisplayName.trim();
    final songAndArtist = artistText.isEmpty
        ? titleText
        : '$titleText · $artistText';
    final albumName = song.albumDisplayName;

    // artUri: 当前曲目优先 file:// 本地路径；队列/浏览用 content://。
    Uri? artUri;
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      if (current && _cachedCoverPath != null && _cachedCoverPath!.isNotEmpty) {
        artUri = Uri.file(_cachedCoverPath!);
      } else if (_cachedCoverUri != null) {
        artUri = _cachedCoverUri;
      } else {
        // 本地封面尚未就绪时发远程 URL，audio_service 会自动下载并缓存
        artUri = Uri.tryParse(
          FeiNiuApiClient.instance.coverUrl(
            song.coverId!,
            size: _systemCoverSize,
            updatedAt: song.updatedAt,
          ),
        );
      }
    }

    final lyricOnTop = MediaNotificationSettings.lyricOnTop.value;
    // 车载蓝牙歌词：独立于通知歌词（showLyrics/lyricOnTop），直接从
    // LyricsService 当前行读取。开关关 → extras 为 null（不发歌词）；
    // 开关开但无歌词 → 发空串，让车机清除之前显示的行。
    final carLyricsEnabled = MediaNotificationSettings.carBluetoothLyrics.value;
    final isCurrentSong = player.snapshot.value.song?.id == song.id;
    final carLyricLine = carLyricsEnabled && isCurrentSong
        ? LyricsService.instance.currentLineText.value
        : null;
    final carLyricsExtras = carLyricsEnabled
        ? <String, dynamic>{'android.media.metadata.LYRICS': carLyricLine ?? ''}
        : null;
    // 车机只认 AVRCP 标准属性（TITLE/ARTIST/...），extras 里的 LYRICS 到不了车机。
    // 用 title 携带当前歌词行，车机在 TITLE 位置显示歌词；关闭时回退真实歌名。
    final carLyricsOverride = carLyricsTitleOverride(
      carLyricsEnabled: carLyricsEnabled,
      isCurrentSong: isCurrentSong,
      currentCarLyricLine: carLyricLine,
    );
    if (lyricOnTop && lyricLine != null) {
      return MediaItem(
        id: song.id,
        title: carLyricsOverride ?? lyricLine,
        artist: songAndArtist,
        album: albumName,
        artUri: artUri,
        duration: song.durationMs != null
            ? Duration(milliseconds: song.durationMs!)
            : null,
        displayTitle: lyricLine,
        displaySubtitle: songAndArtist,
        displayDescription: artistText.isEmpty ? null : artistText,
        artHeaders: FeiNiuApiClient.imageAuthHeaders(),
        extras: carLyricsExtras,
      );
    }
    final effectiveArtist = lyricLine ?? song.artistDisplayName;
    return MediaItem(
      id: song.id,
      title: carLyricsOverride ?? song.title,
      artist: carLyricsOverride != null ? songAndArtist : effectiveArtist,
      album: albumName,
      artUri: artUri,
      duration: song.durationMs != null
          ? Duration(milliseconds: song.durationMs!)
          : null,
      displayTitle: song.title,
      displaySubtitle: lyricLine,
      displayDescription: lyricLine != null ? song.artistDisplayName : null,
      // audio_service 加载 artUri 时使用这些 HTTP 请求头（用于服务器认证）
      artHeaders: FeiNiuApiClient.imageAuthHeaders(),
      extras: carLyricsExtras,
    );
  }

  List<MediaItem> _rootBrowseItems() {
    return <MediaItem>[
      _browseCategory(id: _browseHomeId, title: '主页', subtitle: '歌曲、歌手、专辑、风格'),
      _browseCategory(id: _browseHistoryId, title: '最近', subtitle: '最近播放的音乐'),
      _browseCategory(id: _browseFavoritesId, title: '收藏', subtitle: '已收藏的音乐'),
      _browseCategory(id: _browseRoamId, title: '漫游模式', subtitle: '发现下一首喜欢的歌'),
    ];
  }

  List<MediaItem> _homeBrowseItems() {
    return <MediaItem>[
      _browseSection(id: _browseTracksId, title: '歌曲'),
      _browseSection(id: _browseArtistsId, title: '歌手'),
      _browseSection(id: _browseAlbumsId, title: '专辑'),
      _browseSection(id: _browseGenresId, title: '风格'),
    ];
  }

  MediaItem _browseCategory({
    required String id,
    required String title,
    required String subtitle,
  }) {
    return MediaItem(
      id: id,
      title: title,
      playable: false,
      artUri: _browseCategoryArtwork(id),
      displayTitle: title,
      displaySubtitle: subtitle,
      extras: const <String, dynamic>{
        AndroidContentStyle.browsableHintKey:
            AndroidContentStyle.listItemHintValue,
      },
    );
  }

  Uri? _browseCategoryArtwork(String id) {
    final drawableName = switch (id) {
      _browseHomeId => 'ic_car_home',
      _browseHistoryId => 'ic_car_history',
      _browseFavoritesId => 'ic_car_favorite',
      _browseRoamId => 'ic_car_roam',
      _ => null,
    };
    if (drawableName == null) return null;
    return Uri.parse('$_carDrawableUriPrefix$drawableName');
  }

  Uri get _defaultAlbumArtwork =>
      Uri.parse('$_carDrawableUriPrefix$_defaultAlbumArtworkName');

  Future<Uri> _browseArtwork(String? coverId) async {
    if (coverId == null || coverId.isEmpty) return _defaultAlbumArtwork;
    try {
      final localPath = await CoverLocalCache.downloadToLocal(coverId);
      return await CoverLocalCache.contentUriForPath(localPath) ??
          _defaultAlbumArtwork;
    } catch (error) {
      _debugLog('load car browse artwork failed: $error');
      return _defaultAlbumArtwork;
    }
  }

  MediaItem _browseSection({required String id, required String title}) {
    return MediaItem(
      id: id,
      title: title,
      playable: false,
      extras: const <String, dynamic>{
        AndroidContentStyle.browsableHintKey:
            AndroidContentStyle.listItemHintValue,
      },
    );
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId.startsWith(_browseArtistPrefix)) {
      return _loadBrowseSongs(
        parentMediaId: parentMediaId,
        songs: _loadArtistSongs(
          parentMediaId.substring(_browseArtistPrefix.length),
        ),
      );
    }
    if (parentMediaId.startsWith(_browseAlbumPrefix)) {
      return _loadBrowseSongs(
        parentMediaId: parentMediaId,
        songs: _loadAlbumSongs(
          parentMediaId.substring(_browseAlbumPrefix.length),
        ),
      );
    }
    if (parentMediaId.startsWith(_browseGenrePrefix)) {
      return _loadBrowseSongs(
        parentMediaId: parentMediaId,
        songs: _loadGenreSongs(
          parentMediaId.substring(_browseGenrePrefix.length),
        ),
      );
    }
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        return _rootBrowseItems();
      case _browseHomeId:
        return _homeBrowseItems();
      case _browseTracksId:
        return _loadBrowseSongs(
          parentMediaId: _browseTracksId,
          songs: _loadTracks(),
        );
      case _browseArtistsId:
        return _loadArtists();
      case _browseAlbumsId:
        return _loadAlbums();
      case _browseGenresId:
        return _loadGenres();
      case AudioService.recentRootId:
      case _browseHistoryId:
        return _loadBrowseSongs(
          parentMediaId: _browseHistoryId,
          songs: _loadHistorySongs(),
        );
      case _browseFavoritesId:
        return _loadBrowseSongs(
          parentMediaId: _browseFavoritesId,
          songs: _loadFavoriteSongs(),
        );
      case _browseRoamId:
        return <MediaItem>[
          const MediaItem(
            id: _browseRoamStartId,
            title: '开始音乐漫游',
            artist: '根据你的音乐库随机播放',
            playable: true,
            extras: <String, dynamic>{
              AndroidContentStyle.playableHintKey:
                  AndroidContentStyle.listItemHintValue,
            },
          ),
        ];
      default:
        return const <MediaItem>[];
    }
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final browseSong = _browseSongs[mediaId];
    if (browseSong != null) return browseSong.mediaItem;
    for (final song in player.snapshot.value.queue) {
      if (song.id == mediaId) return _itemFromSong(song);
    }
    return null;
  }

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const <MediaItem>[];
    return _loadBrowseSongs(
      parentMediaId: _browseSearchId,
      songs: _loadSearchSongs(normalizedQuery),
    );
  }

  Future<List<SongEntity>> _loadHistorySongs() async {
    await _ensureApiAuth();
    final pageData = await FeiNiuApiClient.instance.getPlayHistory(
      page: 1,
      size: 40,
    );
    return pageData.list
        .map(FeiNiuTrackService.instance.trackToSongEntity)
        .toList();
  }

  Future<List<SongEntity>> _loadFavoriteSongs() async {
    await _ensureApiAuth();
    final pageData = await FeiNiuApiClient.instance.getFavoriteList(
      page: 1,
      size: 40,
    );
    return pageData.list
        .map(FeiNiuTrackService.instance.trackToSongEntity)
        .toList();
  }

  Future<List<SongEntity>> _loadTracks() async {
    await _ensureApiAuth();
    final pageData = await FeiNiuApiClient.instance.getTrackList(
      page: 1,
      size: 100,
    );
    return pageData.list
        .map(FeiNiuTrackService.instance.trackToSongEntity)
        .toList();
  }

  Future<List<SongEntity>> _loadArtistSongs(String artistId) async {
    await _ensureApiAuth();
    final pageData = await FeiNiuApiClient.instance.getArtistTracks(
      artistGUID: artistId,
      page: 1,
      size: 100,
    );
    return pageData.list
        .map(FeiNiuTrackService.instance.trackToSongEntity)
        .toList();
  }

  Future<List<SongEntity>> _loadAlbumSongs(String albumId) async {
    await _ensureApiAuth();
    final pageData = await FeiNiuApiClient.instance.getAlbumTracks(
      albumGUID: albumId,
      page: 1,
      size: 100,
    );
    return pageData.list
        .map(FeiNiuTrackService.instance.trackToSongEntity)
        .toList();
  }

  Future<List<SongEntity>> _loadGenreSongs(String genreId) async {
    await _ensureApiAuth();
    final pageData = await FeiNiuApiClient.instance.getGenreTracks(
      genreGUID: genreId,
      page: 1,
      size: 100,
    );
    return pageData.list
        .map(FeiNiuTrackService.instance.trackToSongEntity)
        .toList();
  }

  Future<List<MediaItem>> _loadArtists() async {
    try {
      await _ensureApiAuth();
      final pageData = await FeiNiuApiClient.instance.getArtistList(
        page: 1,
        size: 100,
      );
      return await _mapWithConcurrency(pageData.list, _artistItem);
    } catch (error) {
      _debugLog('load car artists failed: $error');
      return const <MediaItem>[];
    }
  }

  Future<List<MediaItem>> _loadAlbums() async {
    try {
      await _ensureApiAuth();
      final pageData = await FeiNiuApiClient.instance.getAlbumList(
        page: 1,
        size: 100,
      );
      return await _mapWithConcurrency(pageData.list, _albumItem);
    } catch (error) {
      _debugLog('load car albums failed: $error');
      return const <MediaItem>[];
    }
  }

  Future<List<MediaItem>> _loadGenres() async {
    try {
      await _ensureApiAuth();
      final pageData = await FeiNiuApiClient.instance.getGenreList(
        page: 1,
        size: 100,
      );
      return pageData.list.map(_genreItem).toList();
    } catch (error) {
      _debugLog('load car genres failed: $error');
      return const <MediaItem>[];
    }
  }

  Future<List<T>> _mapWithConcurrency<S, T>(
    List<S> values,
    Future<T> Function(S value) mapper, {
    int maxConcurrent = 6,
  }) async {
    if (values.isEmpty) return <T>[];
    // 专辑和歌手列表最多各 100 项；限流避免首次进入车机页面时并发下载
    // 过多封面，既拖慢 NAS，也会挤占当前歌曲的封面请求。
    final results = List<T?>.filled(values.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < values.length) {
        final index = nextIndex++;
        results[index] = await mapper(values[index]);
      }
    }

    await Future.wait(
      List<Future<void>>.generate(
        values.length < maxConcurrent ? values.length : maxConcurrent,
        (_) => worker(),
      ),
    );
    return List<T>.generate(values.length, (index) => results[index]!);
  }

  Future<MediaItem> _artistItem(FeiNiuArtist artist) async {
    final hasArtwork = artist.coverId != null && artist.coverId!.isNotEmpty;
    return MediaItem(
      id: '$_browseArtistPrefix${artist.guid}',
      title: artist.name,
      artist: artist.trackCount == null ? null : '${artist.trackCount} 首歌曲',
      playable: false,
      artUri: hasArtwork ? await _browseArtwork(artist.coverId) : null,
      extras: <String, dynamic>{
        AndroidContentStyle.browsableHintKey: hasArtwork
            ? AndroidContentStyle.categoryGridItemHintValue
            : AndroidContentStyle.listItemHintValue,
      },
    );
  }

  Future<MediaItem> _albumItem(FeiNiuAlbum album) async {
    return MediaItem(
      id: '$_browseAlbumPrefix${album.guid}',
      title: album.name,
      artist: album.trackCount == null ? null : '${album.trackCount} 首歌曲',
      playable: false,
      artUri: await _browseArtwork(album.coverId),
      extras: const <String, dynamic>{
        AndroidContentStyle.browsableHintKey:
            AndroidContentStyle.categoryGridItemHintValue,
      },
    );
  }

  MediaItem _genreItem(FeiNiuGenre genre) {
    return MediaItem(
      id: '$_browseGenrePrefix${genre.guid}',
      title: genre.name,
      artist: '${genre.trackCount} 首歌曲',
      playable: false,
      extras: const <String, dynamic>{
        AndroidContentStyle.browsableHintKey:
            AndroidContentStyle.listItemHintValue,
      },
    );
  }

  Future<List<SongEntity>> _loadSearchSongs(String query) async {
    await _ensureApiAuth();
    return FeiNiuTrackService.instance.searchTracks(query);
  }

  Future<void> _ensureApiAuth() {
    return _apiAuthReady ??= FeiNiuApiClient.instance.tryLoadAuth().then(
      (_) {},
    );
  }

  Future<List<MediaItem>> _loadBrowseSongs({
    required String parentMediaId,
    required Future<List<SongEntity>> songs,
  }) async {
    try {
      return _cacheBrowseSongs(
        parentMediaId: parentMediaId,
        songs: await songs,
      );
    } catch (error) {
      _debugLog('load car browse data failed for $parentMediaId: $error');
      return const <MediaItem>[];
    }
  }

  List<MediaItem> _cacheBrowseSongs({
    required String parentMediaId,
    required List<SongEntity> songs,
  }) {
    _browseSongs.removeWhere(
      (_, entry) => entry.parentMediaId == parentMediaId,
    );
    final queue = List<SongEntity>.unmodifiable(
      songs.where((song) => (song.uri ?? '').trim().isNotEmpty),
    );
    return List<MediaItem>.generate(queue.length, (index) {
      final song = queue[index];
      final mediaId = '$parentMediaId:track:$index:${song.id}';
      final item = _browseSongItem(song, mediaId);
      _browseSongs[mediaId] = _CarBrowseSong(
        parentMediaId: parentMediaId,
        mediaItem: item,
        queue: queue,
        index: index,
      );
      return item;
    });
  }

  MediaItem _browseSongItem(SongEntity song, String mediaId) {
    final artist = song.artistDisplayName.trim();
    return MediaItem(
      id: mediaId,
      title: song.title,
      artist: artist.isEmpty ? null : artist,
      album: song.albumDisplayName,
      artUri: song.coverId == _lastCoverId ? _cachedCoverUri : null,
      duration: song.durationMs == null
          ? null
          : Duration(milliseconds: song.durationMs!),
      playable: true,
      displayTitle: song.title,
      displaySubtitle: artist.isEmpty ? song.albumDisplayName : artist,
      extras: const <String, dynamic>{
        AndroidContentStyle.playableHintKey:
            AndroidContentStyle.listItemHintValue,
      },
    );
  }

  Future<void> _playBrowseMediaId(String mediaId) async {
    if (mediaId == _browseRoamStartId) {
      await player.startRoamPlayback();
      return;
    }
    final browseSong = _browseSongs[mediaId];
    if (browseSong != null) {
      await player.playQueue(browseSong.queue, browseSong.index);
      return;
    }
    final queue = player.snapshot.value.queue;
    final index = queue.indexWhere((song) => song.id == mediaId);
    if (index >= 0) await player.playQueue(queue, index);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) {
    return _playBrowseMediaId(mediaId);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) {
    return _playBrowseMediaId(mediaItem.id);
  }

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final results = await search(query, extras);
    if (results.isNotEmpty) await _playBrowseMediaId(results.first.id);
  }

  PlaybackState _stateFromSnap(PlaybackSnapshot snap) {
    final playing = snap.isPlaying;
    final queueIndex = _publishedQueueIds.indexOf(snap.song?.id ?? '');
    // 自定义按键（关闭/收藏）只有 Android 通知栏有实现。iOS/macOS 的
    // MPRemoteCommandCenter 没有 custom action：若把 MediaControl.custom
    // 放进 controls，其 action 枚举恰好落到 changeRepeatMode 命令位，
    // 锁屏/控制中心会出现一个点按无响应的「单曲循环」按钮。故仅 Android 下发。
    final isAndroid = io.Platform.isAndroid;
    final showClose =
        isAndroid &&
        _supportsCustomActions &&
        MediaNotificationSettings.showCloseAction.value;
    final showFavorite =
        isAndroid &&
        _supportsCustomActions &&
        MediaNotificationSettings.showFavoriteAction.value;
    final favoriteIcon = _isFavorite
        ? 'drawable/audio_service_favorite_on'
        : 'drawable/audio_service_favorite';
    final controls = <MediaControl>[
      MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ];
    if (showClose) {
      controls.add(
        MediaControl.custom(
          name: _actionCloseApp,
          androidIcon: 'drawable/audio_service_close',
          label: '关闭',
        ),
      );
    }
    if (showFavorite) {
      controls.add(
        MediaControl.custom(
          name: _actionFavorite,
          androidIcon: favoriteIcon,
          label: _isFavorite ? '已收藏' : '收藏',
        ),
      );
    }
    final processing = snap.queue.isEmpty
        ? AudioProcessingState.idle
        : AudioProcessingState.ready;
    return PlaybackState(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processing,
      playing: playing,
      updatePosition: snap.position,
      bufferedPosition: snap.bufferedPosition,
      // 系统媒体进度按 speed 外推剩余播放时间：倍速播放时必须同步真实倍率，
      // 否则通知栏/Android Auto 的进度条以 1× 估算、随倍速漂移。
      speed: player.speed.value,
      queueIndex: queueIndex >= 0 ? queueIndex : null,
    );
  }

  // ---- 同步方法 ----

  // 通知权限在首次真正开始播放时才请求（保持原有交互），
  // 避免应用启动时（仅注册 MediaSession 用于 Android Auto 发现）
  // 就弹出系统权限对话框。
  void _requestNotificationPermissionIfNeeded(PlaybackSnapshot snap) {
    if (_notificationPermissionRequested || !snap.isPlaying) return;
    _notificationPermissionRequested = true;
    if (!io.Platform.isAndroid) return;
    Permission.notification.status.then((status) {
      if (!status.isGranted) {
        _debugLog('requesting Android notification permission');
        Permission.notification.request();
      }
    });
  }

  void _syncFromPlayer() {
    final snap = player.snapshot.value;
    _requestNotificationPermissionIfNeeded(snap);
    final songId = snap.song?.id;
    final songChanged = songId != _lastSongId;
    if (songId != _lastSongId) {
      _lastSongId = songId;
      _currentLyricLine = null;
      _debugLog('song changed to ${snap.song?.title ?? 'none'}');
    }

    if (songChanged) {
      final song = snap.song;
      _cachedCoverUri = null;
      if (song != null && song.coverId != null && song.coverId!.isNotEmpty) {
        _lastCoverId = song.coverId;
        if (io.Platform.isAndroid) {
          // HyperOS 媒体卡片只在首次渲染 Metadata 时读取 ALBUM_ART（Bitmap），
          // 之后仅更新 artUri（哪怕换成 content://）也不会刷新封面图。
          // 因此这里等本地封面解析完成（content:// / file://，audio_service
          // 原生侧会把它转成 Bitmap 嵌入 Metadata）再发布队列 + 当前曲目，
          // 避免任何「无 Bitmap」的 Metadata 先进入系统被妙播固定成无封面。
          // 解析期间 _syncMediaItem 由 _coverResolving 抑制。
          _publishWithLocalArt(song);
        } else {
          _syncQueue(snap);
          _syncMediaItem();
        }
      } else {
        _syncQueue(snap);
        _syncMediaItem();
      }
    } else {
      _syncQueue(snap);
      _syncMediaItem();
    }
    _syncPlaybackState(snap);
    if (songChanged) {
      _refreshFavoriteState();
      _prewarmQueueCovers(snap);
    }
  }

  /// 后台预下载队列接下来几首歌的封面（按 [_systemCoverSize]）。封面首请求
  /// 会触发服务端生成、可能 >2s；切歌时 `_resolveLocalArtUri` 只有 2s 超时。
  /// 预下载后切到这些歌时封面已在本地缓存，解析瞬时完成，妙播/通知拿到内嵌
  /// Bitmap 的 Metadata，而不是回退远程 URL。
  void _prewarmQueueCovers(PlaybackSnapshot snap) {
    final queue = snap.queue;
    if (queue.length < 2) return;
    final next = queue.skip(1).take(3);
    for (final song in next) {
      final coverId = song.coverId;
      if (coverId == null || coverId.isEmpty) continue;
      unawaited(
        CoverLocalCache.downloadToLocal(
          coverId,
          updatedAt: song.updatedAt,
          size: _systemCoverSize,
        ),
      );
    }
  }

  /// 封面就绪后再发布队列 + MediaItem，保证首次进入系统的 Metadata 内含
  /// ALBUM_ART Bitmap（HyperOS 需要）。最多等 [_coverResolveTimeout]，
  /// 超时/失败回退远程 URL（Android Auto 仍有 audio_service 自带下载兜底），
  /// 并后台继续解析、完成后重发本地封面。
  Future<void> _publishWithLocalArt(SongEntity song) async {
    _coverResolving = true;
    ({String? path, Uri? contentUri})? resolved;
    try {
      resolved = await _resolveLocalCover(song).timeout(_coverResolveTimeout);
    } catch (_) {
      _debugLog('resolve cover timeout, fallback to remote artUri');
    } finally {
      _coverResolving = false;
    }
    if (song.id != _lastSongId) return; // 已切歌，丢弃过期结果
    final localPath = resolved?.path;
    final hasLocal = localPath != null && localPath.isNotEmpty;
    if (hasLocal) {
      _cachedCoverPath = localPath;
      _cachedCoverUri = resolved?.contentUri;
    }
    // 队列与当前曲目都改用本地封面（_syncQueue 的 artUri 去重键保证这次会
    // 重新发布）：当前曲目 Metadata 用 file://（内嵌 Bitmap 供妙播），队列
    // 条目用 content://（供 Android Auto 跨进程读取）。
    _syncQueue(player.snapshot.value);
    _syncMediaItem();
    if (!hasLocal) {
      // 本地封面未就绪：已按远程 URL 发布兜底，后台完成后重发本地封面。
      unawaited(_syncAndUpdateCover(song));
    }
  }

  /// 解析封面到本地：返回本地文件路径 + 给外部进程（Android Auto）的
  /// content:// URI。路径用于当前曲目 Metadata 的 file:// artUri
  /// （audio_service 按 artCacheFile 让原生侧内嵌 ALBUM_ART Bitmap，
  /// 妙播媒体卡片读内嵌 Bitmap）。失败返回 (path: null, contentUri: null)。
  Future<({String? path, Uri? contentUri})> _resolveLocalCover(
    SongEntity song,
  ) async {
    final localPath = await CoverLocalCache.downloadToLocal(
      song.coverId!,
      updatedAt: song.updatedAt,
      size: _systemCoverSize,
    );
    if (localPath != null && localPath.isNotEmpty) {
      final contentUri = await CoverLocalCache.contentUriForPath(localPath);
      return (path: localPath, contentUri: contentUri);
    }
    // 回退：老路径下载（file:// 或 null）。
    final fallbackUri = await _getLocalCoverUri(
      song.coverId!,
      updatedAt: song.updatedAt,
    );
    if (fallbackUri != null && fallbackUri.scheme == 'file') {
      return (path: fallbackUri.toFilePath(), contentUri: null);
    }
    return (path: null, contentUri: fallbackUri);
  }

  /// 封面缓存完成后刷新媒体项，使车机和系统媒体客户端读取本地封面。
  Future<void> _syncAndUpdateCover(SongEntity song) async {
    if (song.coverId == null || song.coverId!.isEmpty) return;
    try {
      _debugLog(
        'syncAndUpdateCover song=${song.title} coverId=${song.coverId}',
      );
      final resolved = await _resolveLocalCover(song);
      _debugLog(
        'syncAndUpdateCover path=${resolved.path} contentUri=${resolved.contentUri}',
      );
      if (resolved.path != null && song.id == _lastSongId) {
        _cachedCoverPath = resolved.path;
        _cachedCoverUri = resolved.contentUri;
      }
      // 拿到本地封面（或返回 null）后再同步队列和当前曲目
      _syncQueue(player.snapshot.value);
      _syncMediaItem();
    } catch (error) {
      _debugLog('sync car cover failed: $error');
    }
  }

  /// 将应用内播放队列发布给系统媒体会话。
  void _syncQueue(PlaybackSnapshot snap) {
    final sessionQueue = _queueForMediaSession(snap);
    final items = sessionQueue.map(_itemFromSong).toList();
    // 去重键包含 artUri：封面解析完成后（远程 URL → content://）必须重新
    // 发布队列，否则外部客户端（Android Auto / 妙播）读到的队列条目仍是
    // 无法加载的远程 URL，卡片不显示封面。
    final queueKey = items
        .map((i) => '${i.id}|${i.artUri?.toString() ?? ''}')
        .join('|');
    if (queueKey == _lastQueueKey) return;
    _lastQueueKey = queueKey;
    _publishedQueueIds = sessionQueue.map((song) => song.id).toList();
    queue.add(items);
  }

  List<SongEntity> _queueForMediaSession(PlaybackSnapshot snap) {
    if (!player.roamActive || snap.queue.isEmpty) {
      _roamQueueAnchorId = null;
      _stableRoamQueue = null;
      return snap.queue;
    }
    final anchorId = snap.queue.first.id;
    if (_roamQueueAnchorId != anchorId || _stableRoamQueue == null) {
      _roamQueueAnchorId = anchorId;
      _stableRoamQueue = List<SongEntity>.unmodifiable(snap.queue.take(2));
    }
    return _stableRoamQueue!;
  }

  void _syncMediaItem() {
    final current = player.snapshot.value.song;
    // 封面解析中：等 _publishWithLocalArt 拿到本地封面（content://，原生侧
    // 会内嵌 ALBUM_ART Bitmap）再发布。此刻若发布，artUri 是远程 URL、
    // Metadata 无 Bitmap，HyperOS 妙播卡片一旦以无封面渲染就不再刷新。
    if (current != null &&
        current.coverId != null &&
        current.coverId!.isNotEmpty &&
        io.Platform.isAndroid &&
        _coverResolving) {
      return;
    }
    final item = current != null ? _itemFromSong(current, current: true) : null;
    // itemKey 必须包含车载歌词行：当「通知显示歌词」关闭时，title/artist/
    // displaySubtitle 不含歌词，连续歌词行会产生相同 itemKey 被去重吞掉，
    // 导致车机收不到歌词更新。
    final itemKey = item == null
        ? 'none'
        : [
            item.id,
            item.title,
            item.artist ?? '',
            item.displayTitle ?? '',
            item.displaySubtitle ?? '',
            item.artUri?.toString() ?? '',
            item.extras?['android.media.metadata.LYRICS'] ?? '',
          ].join('|');
    if (itemKey == _lastMediaItemKey) return;
    _lastMediaItemKey = itemKey;
    mediaItem.add(item);
  }

  void _syncPlaybackState(PlaybackSnapshot snap) {
    final next = _stateFromSnap(snap);
    final stateKey = [
      snap.song?.id ?? '',
      snap.index,
      snap.isPlaying,
      next.processingState.name,
      snap.position.inMilliseconds,
      snap.bufferedPosition.inMilliseconds,
      snap.duration?.inMilliseconds ?? -1,
      player.speed.value,
      _isFavorite,
      MediaNotificationSettings.showLyrics.value,
      MediaNotificationSettings.lyricOnTop.value,
      MediaNotificationSettings.showCloseAction.value,
      MediaNotificationSettings.showFavoriteAction.value,
      _supportsCustomActions,
    ].join('|');
    if (stateKey == _lastPlaybackStateKey) return;
    _lastPlaybackStateKey = stateKey;
    playbackState.add(next);
  }

  void _onLyricLineChanged() {
    _currentLyricLine = LyricsService.instance.currentLineText.value;
    _syncMediaItem();
  }

  void _onNotificationSettingsChanged() {
    if (!MediaNotificationSettings.showLyrics.value) {
      _currentLyricLine = null;
    } else {
      _currentLyricLine = LyricsService.instance.currentLineText.value;
    }
    _syncMediaItem();
    playbackState.add(_stateFromSnap(player.snapshot.value));
  }

  void _refreshFavoriteState() {
    final song = player.snapshot.value.song;
    if (song == null) return;
    // 从服务器查询收藏状态
    FeiNiuFavoriteService.instance.isFavorite(song.id).then((fav) {
      _updateFavorite(fav);
    });
  }

  void _updateFavorite(bool value) {
    if (_isFavorite == value) return;
    _isFavorite = value;
    _debugLog('favorite state changed: $_isFavorite');
    playbackState.add(_stateFromSnap(player.snapshot.value));
  }

  // ---- 通知按钮回调 ----

  @override
  Future<void> skipToNext() {
    _debugLog('skipToNext action');
    return player.next();
  }

  @override
  Future<void> skipToPrevious() {
    _debugLog('skipToPrevious action');
    return player.previous();
  }

  @override
  Future<void> seek(Duration position) {
    _debugLog('seek action ${position.inMilliseconds}ms');
    return player.seek(position);
  }

  @override
  Future<void> skipToQueueItem(int index) {
    _debugLog('skipToQueueItem action index=$index');
    // Android Auto / 系统媒体中心的队列列表点选曲目时调用，
    // 必须真正跳到对应索引（原实现恒为 next()，点队列无效）。
    return player.skipToIndex(index);
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    _debugLog('customAction name=$name');
    if (name == _actionCloseApp) {
      _debugLog('close action');
      await stop();
      return;
    }
    if (name == _actionFavorite) {
      final song = player.snapshot.value.song;
      if (song == null) return;
      if (_isFavorite) {
        _debugLog('favorite remove action song=${song.title}');
        try {
          await FeiNiuFavoriteService.instance.unfavorite(song.id);
          _updateFavorite(false);
        } catch (e) {
          _debugLog('unfavorite failed: $e');
        }
      } else {
        _debugLog('favorite add action song=${song.title}');
        try {
          await FeiNiuFavoriteService.instance.favorite(song.id);
          _updateFavorite(true);
        } catch (e) {
          _debugLog('favorite failed: $e');
        }
      }
      return;
    }
    return super.customAction(name, extras);
  }

  @override
  Future<void> play() {
    _debugLog('play action');
    return player.play();
  }

  @override
  Future<void> pause() {
    _debugLog('pause action');
    return player.pause();
  }

  @override
  Future<void> stop() {
    _debugLog('stop action');
    return player.stopAndClear();
  }
}

class _CarBrowseSong {
  const _CarBrowseSong({
    required this.parentMediaId,
    required this.mediaItem,
    required this.queue,
    required this.index,
  });

  final String parentMediaId;
  final MediaItem mediaItem;
  final List<SongEntity> queue;
  final int index;
}
