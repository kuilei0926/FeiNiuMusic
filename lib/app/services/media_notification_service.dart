import 'dart:async';
import 'dart:io' as io;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/lyrics/lyrics_service.dart';
import '../services/feiniu/api_client.dart';
import '../services/feiniu/favorite_service.dart';
import '../state/song_state.dart';
import '../state/settings_state.dart';
import 'android_platform_service.dart';
import 'media_notification_car_lyrics.dart';
import 'player_service.dart';

class MediaNotificationService {
  static AudioHandler? _audioHandler;
  static VoidCallback? _initListener;
  static bool _initStarted = false;

  static Future<void> init({bool force = false}) async {
    if (_audioHandler != null || _initStarted) return;
    await MediaNotificationSettings.ensureLoaded();
    final player = PlayerService.instance;
    final snap = player.snapshot.value;
    if (!force && snap.song == null && !snap.isPlaying) {
      // Android Auto / 系统媒体中心通过 MediaBrowserService 发现应用：
      // 即使当前没有播放内容也要注册 MediaSession，否则首次连接车机时
      // 启动器里看不到本应用（要等用户手动播一首歌才会出现）。
      // 其他平台保持原有延迟注册行为。
      if (io.Platform.isAndroid) {
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
    _debugLog('init start');
    try {
      _audioHandler = await AudioService.init(
        builder: () => _FeiNiuAudioHandler(PlayerService.instance),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.feiniu.music.playback',
          androidNotificationChannelName: '音乐播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidShowNotificationBadge: false,
        ),
      );
      _debugLog('init completed');
    } finally {
      _initStarted = false;
    }
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
  String? _lastMediaItemKey;
  String? _lastPlaybackStateKey;
  bool _supportsCustomActions = true;
  bool _notificationPermissionRequested = false;

  // 封面本地缓存
  String? _coverDirPath;
  String? _lastCoverId;
  Uri? _cachedCoverUri;

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
      coverId, size: 120, updatedAt: updatedAt,
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
      final cacheFile = await _coverCache.getSingleFile(url,
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

  MediaItem _itemFromSong(SongEntity song) {
    final lyricLine = MediaNotificationSettings.showLyrics.value
        ? _currentLyricLine
        : null;
    final titleText = song.title.trim();
    final artistText = song.artistDisplayName.trim();
    final songAndArtist = artistText.isEmpty
        ? titleText
        : '$titleText · $artistText';
    final albumName = song.albumDisplayName;

    // artUri: Android 优先使用本地文件 URI。
    Uri? artUri;
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      if (_cachedCoverUri != null) {
        artUri = _cachedCoverUri;
      } else {
        // 本地封面尚未就绪时发远程 URL，audio_service 会自动下载并缓存
        artUri = Uri.tryParse(
          FeiNiuApiClient.instance.coverUrl(song.coverId!, size: 120, updatedAt: song.updatedAt),
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
        ? <String, dynamic>{
            'android.media.metadata.LYRICS': carLyricLine ?? '',
          }
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

  PlaybackState _stateFromSnap(PlaybackSnapshot snap) {
    final playing = snap.isPlaying;
    final showClose =
        _supportsCustomActions &&
        MediaNotificationSettings.showCloseAction.value;
    final showFavorite =
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
      speed: 1.0,
      queueIndex: snap.index >= 0 ? snap.index : null,
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

    // 核心改动：先发 MediaItem（远程 URL + artHeaders），
    // audio_service 内部会自动下载封面转为 Bitmap 通知栏显示。
    // 同时后台获取本地缓存路径，进一步替换为 file://。
    if (songChanged) {
      final song = snap.song;
      final oldCoverId = _lastCoverId;
      _cachedCoverUri = null;
      if (song != null &&
          song.coverId != null &&
          song.coverId!.isNotEmpty &&
          song.coverId != oldCoverId) {
        _lastCoverId = song.coverId;
        // 先发送 MediaItem（带 artHeaders，audio_service 会自动下载缓存封面）
        _syncQueue(snap);
        _syncMediaItem();
        // 后台异步下载本地封面，缓存后替换 MediaItem 为 file:// URI
        if (io.Platform.isAndroid) {
          _syncAndUpdateCover(song);
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
    }
  }

  /// 获取本地封面后立即刷新通知，确保通知栏从第一次渲染就用本地文件。
  Future<void> _syncAndUpdateCover(SongEntity song) async {
    if (song.coverId == null || song.coverId!.isEmpty) return;
    _debugLog('syncAndUpdateCover song=${song.title} coverId=${song.coverId}');
    final localUri = await _getLocalCoverUri(
      song.coverId!,
      updatedAt: song.updatedAt,
    );
    _debugLog('syncAndUpdateCover localUri=$localUri');
    if (localUri != null && song.id == _lastSongId) {
      _cachedCoverUri = localUri;
    }
    // 拿到本地封面（或返回 null）后再同步队列和当前曲目
    _syncQueue(player.snapshot.value);
    _syncMediaItem();
  }

  /// 后台尝试将封面替换为本地文件。
  /// 优先使用 CachedNetworkImage 已有的磁盘缓存（不发起网络请求），
  /// 缓存不存在时通过 flutter_cache_manager 下载至本地缓存。
  void _syncQueue(PlaybackSnapshot snap) {
    final queueKey = snap.queue.map((song) => song.id).join('|');
    if (queueKey == _lastQueueKey) return;
    _lastQueueKey = queueKey;
    queue.add(snap.queue.map(_itemFromSong).toList());
  }

  void _syncMediaItem() {
    final current = player.snapshot.value.song;
    final item = current != null ? _itemFromSong(current) : null;
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
