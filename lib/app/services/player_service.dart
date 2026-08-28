import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'db/dao/song_dao.dart';
import 'audio/stream_cache_service.dart';
import 'cast/dlna_cast_service.dart';
import 'feiniu/api_client.dart';
import 'feiniu/api_models.dart';
import 'feiniu/auth_service.dart';
import 'feiniu/cue_service.dart';
import 'feiniu/track_service.dart';
import 'feiniu/transcode_service.dart';
import 'network_connection_service.dart';
import 'player/just_audio_engine.dart';
import 'player/media_kit_engine.dart';
import 'player/playback_router.dart';
import 'player/player_engine.dart';
import 'stats_service.dart';
import 'listening_recorder_service.dart';
import 'volume_schedule_service.dart';
import '../state/settings_state.dart';
import '../state/song_state.dart';
import '../../components/feedback/app_toast.dart';
export '../state/player_state.dart';
import '../state/player_state.dart';

class PlayerService with WidgetsBindingObserver {
  static final PlayerService instance = PlayerService._internal();
  static const Duration _resolvedSourceTtl = Duration(minutes: 10);
  static const Duration _playingPersistInterval = Duration(seconds: 1);
  static const Duration _idlePersistDelay = Duration(milliseconds: 200);

  final _state = AppPlayerState.instance;

  /// 常驻的 just_audio 引擎（ExoPlayer/MediaCodec）：MP3/AAC/Opus 等。
  /// 与 [_mediaKitEngine] 并列，避免反复重建 ExoPlayer。
  /// `late` 使 [_activeEngine] 能引用同一实例。
  late final JustAudioEngine _justAudioEngine = JustAudioEngine();

  /// 当前活跃的播放引擎：只有它出声、只有它的流驱动状态。
  /// 播放 MP3/AAC/Opus 时是 [_justAudioEngine]；播放 FLAC/DSF（media_kit
  /// 格式）时切换为 MediaKitEngine。引擎切换只在歌曲边界发生。
  late PlayerEngine _activeEngine = _defaultEngine();

  /// media_kit 引擎（libmpv + FFmpeg）：FLAC/DSF 等。懒创建：
  /// 首次播放 media_kit 格式时才实例化原生 Player，省启动开销。
  MediaKitEngine? _mediaKitEngine;

  /// 默认播放引擎。桌面端（Windows/macOS/Linux）全量走 media_kit：
  /// - Windows：just_audio（ExoPlayer）无原生实现；
  /// - macOS：流需携带认证头，AVPlayer 不可靠；
  /// 直接以 media_kit 为默认引擎，避免构造 just_audio。
  PlayerEngine _defaultEngine() {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      return _mediaKitEngine ??= MediaKitEngine();
    }
    return _justAudioEngine;
  }

  /// 与逻辑队列平行的引擎类型列表。构建队列时并发解析，
  /// 之后任意逻辑索引都能算出所在引擎与同引擎连续段（run）。
  List<EngineKind> _engineKinds = [];

  /// 与逻辑队列平行的「是否转码单例」标记：true 的索引是转码歌曲，
  /// 必须**独立成 run（size 1）**，播放到才发转码请求（最多 1 个活动会话）。
  /// 与 [_engineKinds] 同步赋值（[_computeEngineKinds] 一起返回）。
  List<bool> _engineTranscodeFlags = [];

  /// 转码全部失败的歌曲 id（会话内）。转码 HLS 播放失败（非 flac→mp3 降级
  /// 能救回的）后标记，不再对这首歌重转码，回退直连（防死循环）。
  final Set<String> _transcodeFailedSongIds = {};

  /// 当前正在播的转码 HLS 地址 + 其 codec：该歌播完时后台拼接下载成完整
  /// 文件（`StreamCacheService.cacheTranscodedSong`），第二次起零流量。
  String? _activeTranscodeHlsUrl;
  String? _activeTranscodeCodec;

  /// 当前引擎 run 在逻辑队列中的起始索引。引擎 currentIndexStream 给的是
  /// 引擎内（run 内）索引，映射回逻辑索引需加该偏移。
  int _activeRunStart = 0;

  /// 升级到 media_kit 的歌曲（just_audio 解码 FLAC 帧超限 `Buffer too small`
  /// 时当场升级，由 FFmpeg 无损解码）。会话内持续生效。
  final Set<String> _mediaKitEscalateSongIds = {};

  /// 手动切换解码器覆盖表：`Map<songId, EngineKind>`（会话级）。用户点歌曲信息
  /// 面板的解码 tag 手动指定引擎时写入，_computeEngineKinds 命中后优先于
  /// routeForSong 默认路由。**仅当前歌曲命中**，不参与现有自动升级
  /// （_mediaKitEscalateSongIds）与无声看门狗（_silenceWatchEscalatedSongIds）
  /// 逻辑；切歌后新歌曲 id 不命中即失效。
  final Map<String, EngineKind> _forcedEngineKinds = {};

  /// 用户在歌曲信息面板转码格式里选了「直连」的歌曲 id（会话级）。这些歌
  /// 强制不转码、直接播放原始流（_computeEngineKinds / _sourceForSong 跳过
  /// 转码分支），回到默认引擎路由。
  final Set<String> _forceDirectSongIds = {};

  /// media_kit 连续解码失败的歌曲 id（会话内）。第二次失败即跳过该歌
  /// （前进/回卷），避免媒体损坏时无限重试刷屏。
  final Set<String> _mediaKitFailedSongIds = {};

  /// 无声看门狗：对「codec 未知 + 可疑容器」的 just_audio 歌曲，播放确认后
  /// 若位置照常推进但可能无声（ExoPlayer 设备解码器静默失败），升级 media_kit
  /// 重播。升级后不再重复处理：media_kit（FFmpeg）解码即出声，失败走 mpv
  /// errorStream 由既有 `_mediaKitFailedSongIds` 兜底跳过。
  String? _silenceWatchSongId;
  Timer? _silenceWatchTimer;

  /// 已由看门狗升级过 media_kit 的歌曲 id（会话级）。用于去重与日志。
  final Set<String> _silenceWatchEscalatedSongIds = {};
  static const Duration _silenceGrace = Duration(seconds: 3);
  static const Duration _silenceMinAdvance = Duration(seconds: 1);

  /// 网络缓慢提示计时器：media_kit 播无损大文件缓冲超时时触发一次提示。
  Timer? _slowNetworkTimer;
  bool _slowNetworkNotified = false;

  /// Wi-Fi/蜂窝切换会改变转码路由。短暂防抖后保留当前进度重载当前 run，
  /// 避免 just_audio 已预载的后续歌曲继续沿用切换前的直连/转码策略。
  Timer? _networkRouteRefreshTimer;
  bool _wifiDirectPolicyActive = false;

  final SongDao _songDao = SongDao.instance;
  final StatsService _statsService = StatsService.instance;
  final ListeningRecorderService _recorder = ListeningRecorderService.instance;
  AudioSession? _audioSession;
  Timer? _statsFlushTimer;

  ValueNotifier<Duration> get position => _state.position;
  ValueNotifier<Duration?> get duration => _state.duration;
  ValueNotifier<Duration> get bufferedPosition => _state.bufferedPosition;
  ValueNotifier<bool> get isPlaying => _state.isPlaying;
  ValueNotifier<bool> get isLoading => _state.isLoading;
  ValueNotifier<List<SongEntity>> get queue => _state.queue;
  ValueNotifier<int> get currentIndex => _state.currentIndex;
  ValueNotifier<SongEntity?> get currentSong => _state.currentSong;
  ValueNotifier<PlaybackSnapshot> get snapshot => _state.snapshot;
  ValueNotifier<PlaybackMode> get playbackMode => _state.playbackMode;
  ValueNotifier<String?> get sleepTimerDisplayText =>
      _state.sleepTimerDisplayText;
  ValueNotifier<bool> get sleepUntilSongEnd => _state.sleepUntilSongEnd;
  ValueNotifier<EngineKind> get decoderEngine => _state.decoderEngine;

  /// 是否正在 DLNA 投屏（遥控模式）。投屏时 UI 据此把播放控制转到投屏设备。
  ValueNotifier<bool> get isCasting => _state.isCasting;

  /// 当前播放速度倍率（0.1–5.0，1.0 为正常）。UI 经此读取/监听。
  ValueNotifier<double> get speed => AppPlaybackSpeedSettings.speed;

  /// 该歌是否被用户在转码格式里选了「直连」（会话级强制不转码）。
  bool isTranscodeDirect(String songId) => _forceDirectSongIds.contains(songId);

  /// 该歌转码是否已完全失败（会话内不再尝试转码，回落直连）。
  bool isTranscodeFailed(String songId) =>
      _transcodeFailedSongIds.contains(songId);

  Signal<Duration> get positionSignal => _state.positionSignal;
  Signal<Duration?> get durationSignal => _state.durationSignal;
  Signal<Duration> get bufferedPositionSignal => _state.bufferedPositionSignal;
  Signal<bool> get isPlayingSignal => _state.isPlayingSignal;
  Signal<bool> get isLoadingSignal => _state.isLoadingSignal;
  Signal<List<SongEntity>> get queueSignal => _state.queueSignal;
  Signal<int> get currentIndexSignal => _state.currentIndexSignal;
  Signal<SongEntity?> get currentSongSignal => _state.currentSongSignal;
  Signal<PlaybackSnapshot> get snapshotSignal => _state.snapshotSignal;
  Signal<PlaybackMode> get playbackModeSignal => _state.playbackModeSignal;
  Signal<String?> get sleepTimerDisplayTextSignal =>
      _state.sleepTimerDisplayTextSignal;
  Signal<bool> get sleepUntilSongEndSignal => _state.sleepUntilSongEndSignal;
  Signal<EngineKind> get decoderEngineSignal => _state.decoderEngineSignal;
  Signal<bool> get isCastingSignal => _state.isCastingSignal;

  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  Timer? _sleepTimer;
  Timer? _persistTimer;
  Timer? _backgroundAudioKeepAliveTimer;
  _PlaybackRestoreState? _restoreSession;
  Future<void>? _restorePrepareFuture;
  DateTime? _sleepEndAt;
  final Map<String, int> _durationPersistedMs = {};
  final Map<String, _ResolvedRemoteSource> _resolvedRemoteSources = {};
  final Map<String, Future<Uri>> _sourceResolveInflight = {};
  final Set<String> _precacheChainInFlight = {};
  bool _restoringState = false;
  bool _isSeeking = false;
  Duration? _seekTarget;
  bool _audioInterrupted = false;
  bool _wasPlayingBeforeInterruption = false;
  int _seekSeq = 0;
  DateTime _lastPersistTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastSnapshotEmit;
  Timer? _snapshotTimer;
  int _prefetchTriggeredIndex = -1;
  bool _recoveringCurrentSource = false;

  /// roam 追加请求串行化：>0 表示有请求进行中或待处理
  int _roamAppendQueuedCount = 0;

  /// 在途的 roam 追加请求 Future：非 null 表示追加仍在进行。
  /// 与 _roamAppendQueuedCount 不同，调用方可 await 它等待追加完成
  /// （next 在队尾需等追加完成再前进，避免物理源未填满时 seekToNext
  /// 越过队尾被 LoopMode.all 回卷到队首）。
  Future<void>? _roamAppendInFlight;

  /// 切换到随机模式但当前队列还不是漫游队列（roamId 为空）时置 true，
  /// 表示当前歌曲播完/切到队尾后应启动漫游（roam-start 拉新链），
  /// 而不是继续顺序播放原列表。
  bool _roamStartPending = false;

  /// 队列代次标记：每次 playQueue/startRoamPlayback 递增。
  /// 用于丢弃仍在途的漫游追加请求，防止其覆盖用户新选择的队列。
  int _queueGeneration = 0;

  /// 引擎加载串行化锁：`_activateLogicalIndex` 内部有多个异步间隙
  /// （`_resolveEngineItem` / `loadQueue` / `setLoopMode`），并发调用会让
  /// 两个 `setAudioSources` 在 just_audio 上互相中断（`PlayerInterruptedException`，
  /// 表现为 `Loading interrupted` / 跳歌）。所有加载经此锁排队执行。
  /// 链式：`_loadQueueLock` 持有当前在途 Future，后续调用 await 它再执行，
  /// 天然保证同一时刻只有一个加载在途。
  Future<void> _loadQueueLock = Future.value();

  /// 本次 `_activateLogicalIndex` 期望加载的逻辑索引。
  /// `currentIndexStream` 监听器用它过滤 setAudioSources 期间的过渡广播
  /// （just_audio `_broadcastSequence` 保留旧 currentIndex，会导致 UI 先跳走
  /// 又跳回）。`loadQueue` 返回后清除，随后由引擎实际索引校准。
  int? _pendingLoadLogicalIndex;

  Future<List<SongEntity>> Function()? queueExtender;
  bool _isExtendingQueue = false;

  /// Current roam ID for shuffle mode (roam-next API chain)
  String? roamId;

  /// 漫游模式：当前队列由 roam-next 服务器链驱动（roamId 非空）。
  /// 区别于本地随机（playShuffle，roamId 为空）——漫游的队列是服务端随机链，
  /// 手动增删会破坏链的连续性，因此漫游队列不允许删除歌曲。
  bool get roamActive => roamId != null && roamId!.isNotEmpty;

  static const String _prefsQueueKey = 'playback_queue_v1';
  static const String _prefsIndexKey = 'playback_index_v1';
  static const String _prefsPositionKey = 'playback_position_v1';
  static const String _prefsModeKey = 'playback_mode_v1';
  static const String _prefsWasPlayingKey = 'playback_was_playing_v1';
  static const String _prefsSongIdKey = 'playback_song_id_v1';
  static const String _prefsRoamIdKey = 'playback_roam_id_v1';

  bool get hasLoadedAudioSource => _activeEngine.hasLoadedSource;

  void _debugLog(String message) {
    // 不依赖 kDebugMode：release 版同样输出，供设置页「调试模式」开启后
    // 排查线上问题（DebugLogService 通过覆盖 debugPrint 捕获）。
    debugPrint('[PlayerService] $message');
  }

  PlayerService._internal() {
    WidgetsBinding.instance.addObserver(this);
    _wifiDirectPolicyActive = AppTranscodeSettings.directOnWifi.value &&
        NetworkConnectionService.instance.isWifiConnected;
    NetworkConnectionService.instance.wifiConnected.addListener(
      _scheduleNetworkRouteRefresh,
    );
    AppTranscodeSettings.directOnWifi.addListener(
      _scheduleNetworkRouteRefresh,
    );
    _initFuture = _init();
  }

  void _scheduleNetworkRouteRefresh() {
    final active = AppTranscodeSettings.directOnWifi.value &&
        NetworkConnectionService.instance.isWifiConnected;
    if (active == _wifiDirectPolicyActive) return;
    _wifiDirectPolicyActive = active;
    if (queue.value.isEmpty || currentIndex.value < 0 || isCasting.value) return;
    _networkRouteRefreshTimer?.cancel();
    _networkRouteRefreshTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_refreshNetworkTranscodeRoute());
    });
  }

  Future<void> _refreshNetworkTranscodeRoute() async {
    try {
      await _initFuture;
      if (isCasting.value) return;
      final list = queue.value;
      final idx = currentIndex.value;
      if (list.isEmpty || idx < 0 || idx >= list.length) return;

      final seekPosition = position.value;
      final wasPlaying = isPlaying.value;
      final song = list[idx];
      _debugLog(
        'network route refresh wifi='
        '${NetworkConnectionService.instance.isWifiConnected} song=${song.title}',
      );

      // 旧 HLS 不再代表当前网络策略，先清掉播放完成后的后台缓存标记并释放会话。
      _activeTranscodeHlsUrl = null;
      _activeTranscodeCodec = null;
      await FeiNiuTranscodeService.instance.quitFor(song.id);

      await _activateLogicalIndex(
        idx,
        initialPosition: seekPosition > Duration.zero ? seekPosition : null,
      );
      if (wasPlaying) await _startPlayback();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PlayerService] network route refresh failed: $e');
      }
    }
  }

  /// 初始化（含恢复旧播放会话）完成的 Future。所有播放操作先 await 它，
  /// 避免在初始化完成前被调用导致与恢复流程的 setAudioSources 并发交错、
  /// 播放器物理 loop/shuffle 状态被覆盖。
  late final Future<void> _initFuture;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _stopBackgroundAudioKeepAlive();
      // 后台期间 Timer 挂起，resume 立即重检定时音量（时间窗可能已跨越）。
      VolumeScheduleService.instance.checkNow();
      // 投屏遥控模式：isPlaying 是投屏设备的播放状态，本机引擎并未在播。
      // 若这里按 isPlaying 恢复本机，会把「电视在播」误当成「手机在播」，
      // 后台切回时手机突然出声（和电视同时播）。投屏期间一律不恢复本机。
      if (isPlaying.value && !isCasting.value) {
        unawaited(_ensureAudiblePlayback());
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _syncPositionFromPlayer();
      _persistPlaybackStateNow();
      _statsService.flush();
      _recorder.onLifecyclePause();
      if (isPlaying.value) {
        _startBackgroundAudioKeepAlive();
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _syncPositionFromPlayer();
      _persistPlaybackStateNow();
      _statsService.flush();
      _recorder.onLifecyclePause();
    }
  }

  Future<void> _hydrateAndSetCurrentSong(SongEntity song) async {
    currentSong.value = song;
  }

  Future<void> _init() async {
    _restoringState = true;
    _persistTimer?.cancel();
    _debugLog('init start');
    await AppPlaybackVolumeSettings.ensureLoaded();
    await AppPlaybackSpeedSettings.ensureLoaded();
    await VolumeScheduleService.instance.ensureStarted();
    await WebDavPlaybackSettings.ensureLoaded();
    await AppCacheSettings.ensureLoaded();
    await AppLaunchPlaybackSettings.ensureLoaded();
    await AppPlaybackQueueSettings.ensureLoaded();
    await AppPlaybackAudioFocusSettings.ensureLoaded();
    final session = await AudioSession.instance;
    _audioSession = session;
    await _applyAudioSessionConfiguration();
    AppPlaybackAudioFocusSettings.exclusiveFocus.addListener(
      _handleExclusiveFocusChanged,
    );
    _interruptionSub = session.interruptionEventStream.listen(
      _handleAudioInterruption,
    );
    _becomingNoisySub = session.becomingNoisyEventStream.listen((_) {
      unawaited(_pausePlayback());
    });
    // 首次启动的默认播放模式。若用户已在初始化完成前点了首页漫游
    // （playQueue 已递增 _queueGeneration），跳过此默认值，避免把用户
    // 刚设好的随机模式改回列表循环。
    if (_queueGeneration == 0) {
      // 双引擎架构下 loop 用 none（逻辑层驱动回卷），与 _applyPlaybackMode 一致。
      await _activeEngine.setLoopMode(EngineLoopMode.none);
      playbackMode.value = PlaybackMode.loop;
      _debugLog('init default mode -> loop (gen=0)');
    }
    _wireEngine(_activeEngine);
    AppPlaybackVolumeSettings.volume.addListener(_handleAppVolumeChanged);
    AppPlaybackSpeedSettings.speed.addListener(_handlePlaybackSpeedChanged);
    await _applyAppVolume(AppPlaybackVolumeSettings.volume.value);
    await _applyEngineSpeed(_activeEngine);
    // 用户可能在播放器初始化完成前就点了首页漫游（playQueue 递增
    // _queueGeneration）。_restorePlaybackState 内部按 generation 判断，
    // 一旦用户已开始新播放就跳过恢复，避免覆盖用户刚选的漫游队列/模式。
    try {
      await _restorePlaybackState();
    } finally {
      _restoringState = false;
    }
    _registerCastHooks();
    _emitSnapshot(force: true);
    _debugLog('init completed');
  }

  /// 注册 DLNA 投屏钩子：开始投屏时暂停本机、断开时恢复本机续播。
  void _registerCastHooks() {
    final cast = DlnaCastService.instance;
    cast.onCastStart = () {
      _debugLog('cast start -> pause local engine');
      isCasting.value = true;
      unawaited(_pausePlayback());
    };
    cast.onCastProgress = (position, playing) {
      // 把投屏设备的位置/状态同步到本机 UI 状态（进度条/播放按钮）。
      this.position.value = position;
      isPlaying.value = playing;
      _emitSnapshot(force: true);
      // 随机/漫游模式：投屏播放接近末尾时**提前预填**队列（对齐非投屏路径
      // _maybePrefetchByRemaining 的提前量），避免播完后才发请求导致间隙。
      _maybePrefetchCastQueue();
    };
    cast.onCastCompleted = () {
      // 投屏设备播完当前歌曲：推进逻辑队列（含随机/漫游自动填充），
      // 把下一首推送到投屏设备。
      unawaited(_advanceCastToNext());
    };
    cast.onCastDisconnect = () {
      _debugLog('cast disconnect -> resume local playback');
      isCasting.value = false;
      // 无歌曲则不动。
      if (currentSong.value == null) return;
      unawaited(() async {
        try {
          final target = currentSong.value;
          // 从投屏设备断点续播：onCastProgress 已把 position.value 同步成
          // 电视当前播放位置，重载本机引擎时作为 initialPosition 传入，保证
          // 断开后手机从电视的进度接着播（无论投屏期间是否切过歌）。
          final resumePosition = position.value;
          final targetIdx = queue.value.indexWhere((s) => s.id == target!.id);
          await _reloadQueue(
            queue.value,
            targetIdx,
            play: false,
            initialPosition: resumePosition,
          );
          await _startPlayback();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('PlayerService cast disconnect resume failed: $e');
          }
        }
      }());
    };
  }

  /// 订阅一个引擎的归一化流。每个处理器开头用 `identical(engine, _activeEngine)`
  /// 守卫：只有当前活跃引擎的事件才驱动状态，闲置引擎的静止事件
  /// （position 0 / playing false）不会覆盖 UI。
  ///
  /// 在引擎切换（_activateLogicalIndex）时对新引擎调用一次。对同一引擎
  /// 幂等：已订阅过直接返回（just_audio 的流是单订阅，重复订阅会抛错）。
  final Set<PlayerEngine> _wiredEngines = {};
  void _wireEngine(PlayerEngine engine) {
    if (!_wiredEngines.add(engine)) return;
    engine.positionStream.listen((value) {
      if (!identical(engine, _activeEngine)) return;
      // 投屏遥控模式：位置由投屏设备轮询驱动，忽略本机引擎的位置事件
      // （投屏续播/预填会重载引擎队列，可能广播 position=0 把进度条打回起点）。
      if (isCasting.value) return;
      if (_isSeeking) {
        // End the seek freeze early once the player reports a position near the
        // requested target, instead of blanking the progress bar for a fixed
        // delay after every seek.
        final target = _seekTarget;
        if (target != null && (value - target).inMilliseconds.abs() <= 600) {
          _isSeeking = false;
          _seekTarget = null;
        } else {
          return;
        }
      }
      if (_shouldIgnoreZeroPosition(value)) {
        return;
      }
      position.value = value;
      _maybePrefetchByRemaining(value);
      _emitSnapshot();
    });
    engine.durationStream.listen((value) {
      if (!identical(engine, _activeEngine)) return;
      // 投屏遥控模式：时长沿用投屏起始歌曲，忽略引擎的时长事件。
      if (isCasting.value) return;
      final song = currentSong.value;
      // CUE 整轨曲目：media_kit（Windows/FLAC 直连）用 Media(start/end) 裁剪，
      // 但 mpv 上报的是**整轨文件**时长而非裁剪段时长，时长显示会变成整轨的。
      // 位置部分已在 media_kit 引擎层按 Media.start 换算成裁剪段内相对时间
      //（normalizeCroppedPosition），这里按曲目自身 duration 覆盖时长，与
      // just_audio 的 ClippingAudioSource（上报裁剪后时长）行为一致；也避免
      // 把整轨时长误持久化进曲目。
      final effective =
          song != null && song.isCue && (song.durationMs ?? 0) > 0
              ? Duration(milliseconds: song.durationMs!)
              : value;
      duration.value = effective;
      final ms = effective?.inMilliseconds ?? 0;
      if (song != null && ms > 0) {
        _maybePersistPlaybackDuration(song, ms);
      }
      _emitSnapshot(force: true);
    });
    engine.bufferedPositionStream.listen((value) {
      if (!identical(engine, _activeEngine)) return;
      // 投屏遥控模式：忽略本机引擎的缓冲进度。
      if (isCasting.value) return;
      bufferedPosition.value = value;
      _emitSnapshot(force: true);
    });
    engine.playbackStateStream.listen((state) {
      if (!identical(engine, _activeEngine)) return;
      // 投屏遥控模式：播放/暂停状态由投屏设备轮询驱动，忽略本机引擎事件
      // （引擎暂停/重载会广播 playing=false 覆盖投屏设备的播放状态）。
      if (isCasting.value) return;
      final wasPlaying = isPlaying.value;
      isPlaying.value = state.playing;
      // 加载中（loading/buffering）视为加载态，驱动播放按钮转圈
      final loading =
          state.processingState == EngineProcessingState.loading ||
          state.processingState == EngineProcessingState.buffering;
      if (loading != isLoading.value) {
        isLoading.value = loading;
      }
      _emitSnapshot(force: true);
      if (wasPlaying && !state.playing) {
        _schedulePersistPlaybackState(immediate: true);
      }
      // 顺序模式/漫游：当前曲目播完且队列没有可播的下一首时自动追加。
      // 引擎 run 不自动回卷，completed 统一由 _handleEngineCompleted 驱动前进。
      if (state.processingState == EngineProcessingState.completed &&
          playbackMode.value != PlaybackMode.single &&
          _roamAppendQueuedCount <= 0) {
        unawaited(_handleEngineCompleted(engine));
      }
      // 无损大文件（media_kit 直连原始流）对网络要求高：缓冲超时提示网络缓慢。
      // 仅当前激活的 media_kit 引擎 + 缓冲态持续超过阈值时提示一次（去重）。
      if (identical(engine, _mediaKitEngine) && loading) {
        _maybeNotifySlowNetwork();
      } else {
        _cancelSlowNetworkTimer();
      }
    });
    engine.errorStream.listen((error) {
      if (!identical(engine, _activeEngine)) return;
      unawaited(_handlePlayerError(error));
    });
    engine.currentIndexStream.listen((idx) {
      if (!identical(engine, _activeEngine)) return;
      if (idx == null) return;
      // 投屏遥控模式：本机引擎暂停，其索引全是旧队列的噪音（投屏续播/预填
      // 会 insertItem/重载引擎队列，触发 currentIndex=0 广播把 UI 打回第一首）。
      // 投屏期间手机当前歌曲完全由投屏流程驱动，忽略引擎索引事件。
      if (isCasting.value) return;
      // 恢复期间（_restoringState=true）忽略所有 indexStream 过渡事件：
      // preload=false 的 setAudioSources 在 just_audio 上会走 _IdleAudioPlayer，
      // 它异步广播 sequenceState.currentIndex=0（seed 值）——但当前歌曲已由
      // _activateLogicalIndexLocked 显式 _activateSong(logicalIndex) 设好，
      // 这些 0/过渡广播都是噪音，放行会把 UI 打回 run 起点（「第 N 首重启
      // 变第 1 首」）。恢复完成后 _restoringState 置 false，真实切歌正常驱动。
      if (_restoringState) return;
      // setAudioSources 替换队列期间，just_audio 会广播过渡 currentIndex
      // （_broadcastSequence 保留旧 currentIndex，只有 sequence 变化）。
      // 这些过渡广播会触发 _activateSong 把 UI 切到旧歌——「点歌跳一遍」。
      // 用「引擎内索引 → 逻辑索引」与期望值校验：不一致的过渡广播直接忽略，
      // 真实播放索引由 loadQueue 返回后的 _reconcileEngineIndex 校准。
      final expectedLogical = _pendingLoadLogicalIndex;
      if (expectedLogical != null && expectedLogical >= 0) {
        final logicalIdx = _activeRunStart + idx;
        if (logicalIdx != expectedLogical) return;
      }
      final logicalIdx = _activeRunStart + idx;
      if (logicalIdx >= queue.value.length) return;
      _activateSong(logicalIdx);
      final list = queue.value;
      // 切歌时扩展队列（顺序/单曲模式）：每次切到新歌，若队列快播完就请求
      // 下一首填充，保证切到队尾时已有新歌可播，没有「结束前预加载」概念。
      if (playbackMode.value != PlaybackMode.shuffle &&
          logicalIdx >= 0 &&
          list.isNotEmpty &&
          logicalIdx >= list.length - 2) {
        unawaited(_autoExtendQueue());
      }
      // 漫游/随机模式：切到新歌时，若它是队列最后一首（没有可播的下一首了），
      // 就请求追加一首到队尾。漫游走 roam-next；本地随机（playShuffle）走
      // queueExtender；刚切换的「待启动漫游」在此启动。
      if (playbackMode.value == PlaybackMode.shuffle &&
          logicalIdx >= 0 &&
          list.isNotEmpty &&
          logicalIdx == list.length - 1 &&
          _roamAppendQueuedCount <= 0) {
        if (_roamStartPending) {
          _roamStartPending = false;
          unawaited(_startRoamFromPending());
        } else {
          final id = roamId;
          if (id != null && id.isNotEmpty) {
            unawaited(_extendRoamQueue());
          } else {
            unawaited(_autoExtendQueue());
          }
        }
      }
    });
    // loop/shuffle 物理流不再需要：PlaybackMode 是应用层唯一真源，
    // 引擎加载队列后由 setLoopMode 显式应用。media_kit 引擎没有对应流。
  }

  /// 引擎 `completed` 统一处理：驱动跨引擎前进 / 队尾回卷 / 漫游补链。
  /// 这是双引擎架构下循环语义的核心——run 不自动回卷，逻辑层驱动一切。
  Future<void> _handleEngineCompleted(PlayerEngine engine) async {
    if (!identical(engine, _activeEngine)) return;
    if (playbackMode.value == PlaybackMode.single) return; // 引擎自行重复
    _recorder.markCompleted(); // 完整播完：报告埋点标记 completed=1
    // 当前歌播完：若它是转码 HLS，后台把全部分片拼接下载成完整文件，
    // 第二次重播命中本地零流量。fire-and-forget，不阻塞切歌。
    final activeHls = _activeTranscodeHlsUrl;
    final activeCodec = _activeTranscodeCodec;
    if (activeHls != null && activeCodec != null) {
      final curSong = currentSong.value;
      if (curSong != null) {
        StreamCacheService.instance.cacheTranscodedSong(
          curSong.id,
          activeCodec,
          activeHls,
        );
      }
    }
    _activeTranscodeHlsUrl = null;
    _activeTranscodeCodec = null;
    final list = queue.value;
    final idx = currentIndex.value;
    if (idx < 0 || list.isEmpty) return;
    if (idx >= list.length - 1) {
      // 逻辑队尾：漫游补链；loop 回卷到逻辑队首（可能跨引擎）。
      if (playbackMode.value == PlaybackMode.shuffle) {
        if (_roamStartPending) {
          _roamStartPending = false;
          await _startRoamFromPending();
          return;
        }
        await _autoExtendQueue();
        if (queue.value.length > list.length) {
          await _advanceToLogicalIndex(idx + 1, resumePlayback: true);
        }
        return;
      }
      if (playbackMode.value == PlaybackMode.loop) {
        await _activateLogicalIndex(0);
        try {
          await _activeEngine.play();
        } catch (_) {}
      }
      return;
    }
    await _advanceToLogicalIndex(idx + 1, resumePlayback: true);
  }

  /// 前进到逻辑索引 [logicalIndex]：同 run 内无缝 next；跨 run 切换引擎。
  Future<void> _advanceToLogicalIndex(
    int logicalIndex, {
    bool? resumePlayback,
  }) async {
    final list = queue.value;
    if (logicalIndex < 0 || logicalIndex >= list.length) return;
    final cur = currentIndex.value;
    final shouldResume = resumePlayback ?? isPlaying.value;
    // 同 run 判定用 _runBounds 覆盖范围（转码歌是单例 run，相邻两首转码歌
    // 引擎相同但不在同一 run，必须走重新激活而不是 seekToNext）。
    if (cur >= 0 && cur < list.length) {
      final bounds = _runBounds(logicalIndex);
      final sameRun = cur >= bounds.start && cur <= bounds.end;
      if (sameRun) {
        await _activeEngine.seekToNext();
        if (shouldResume && !_activeEngine.playing) {
          try {
            await _activeEngine.play();
          } catch (_) {}
        }
        return;
      }
    }
    await _activateLogicalIndex(logicalIndex);
    if (shouldResume) {
      try {
        // loadQueue(play:false) 后无条件发送新的播放意图。不能依赖异步流可能
        // 尚未刷新的 playing getter，否则 macOS 曲末切 run 时会误以为仍在播。
        await _startPlayback();
      } catch (_) {}
    }
  }

  /// 计算队列中每个逻辑索引所属引擎（并发解析格式）与转码标记。
  ///
  /// 返回 `(kinds, transcodeFlags)`：
  /// - 已升级到 media_kit 的歌曲（FLAC 帧超限）强制走 media_kit；
  /// - 用户手动指定解码器 → 照旧；
  /// - **需要转码的歌 → 强制 justAudio + flag=true**（转码 HLS 只能
  ///   ExoPlayer 播，且每首独立成 run）；
  /// - 其余 → `routeForSong` 默认路由，flag=false。
  Future<({List<EngineKind> kinds, List<bool> transcodeFlags})>
  _computeEngineKinds(List<SongEntity> songs) async {
    final results = await Future.wait(
      songs.map((s) async {
        if (_mediaKitEscalateSongIds.contains(s.id)) {
          // _debugLog('engineKind ${s.title} -> mediaKit (escalated)');
          return (kind: EngineKind.mediaKit, transcode: false);
        }
        // 用户手动指定的解码器（歌曲信息面板点解码 tag 切换）。放在 escalate
        // 之后：自动升级（解码失败/无声）仍优先，手动切换失败由现有兜底接管。
        final forced = _forcedEngineKinds[s.id];
        if (forced != null) {
          // _debugLog('engineKind ${s.title} -> ${forced.name} (manual)');
          return (kind: forced, transcode: false);
        }
        // 转码歌强制 just_audio（HLS 只能 ExoPlayer 播）。转码失败标记后
        // 回落到下方 routeForSong（DSF→mediaKit 直连，FLAC→justAudio 直连）。
        // 用户在面板选「直连」的歌（_forceDirectSongIds）跳过转码分支。
        if (!_forceDirectSongIds.contains(s.id) &&
            !_transcodeFailedSongIds.contains(s.id) &&
            await FeiNiuTranscodeService.instance.shouldTranscode(s)) {
          _debugLog('engineKind ${s.title} -> justAudio (transcode)');
          return (kind: EngineKind.justAudio, transcode: true);
        }
        final kind = await routeForSong(s);
        // 只打印走 media_kit 的异常路由（正常 just_audio 不刷屏），用于
        // 确诊「为什么普通歌进了 media_kit」。
        if (kDebugMode && kind == EngineKind.mediaKit) {
          final fmt = FeiNiuTranscodeService.instance.resolvedFormatForSync(s);
          // debugPrint(
          //   '[PlayerService] engineKind ${s.title} fmt=$fmt -> mediaKit',
          // );
        }
        return (kind: kind, transcode: false);
      }),
    );
    return (
      kinds: results.map((r) => r.kind).toList(growable: false),
      transcodeFlags: results.map((r) => r.transcode).toList(growable: false),
    );
  }

  /// 把 [_computeEngineKinds] 的返回同时写入引擎类型与转码标记两列。
  void _applyEngineKinds(
    ({List<EngineKind> kinds, List<bool> transcodeFlags}) computed,
  ) {
    _engineKinds = computed.kinds;
    _engineTranscodeFlags = computed.transcodeFlags;
  }

  /// 计算逻辑索引 [logicalIndex] 所在同引擎连续段（run）。
  ({int start, int end, int localIndex, EngineKind kind}) _runBounds(
    int logicalIndex, {
    List<EngineKind>? kinds,
    List<bool>? transcodeFlags,
  }) {
    final k = kinds ?? _engineKinds;
    final tc = transcodeFlags ?? _engineTranscodeFlags;
    final kind = k[logicalIndex];
    // 转码歌曲独立成单例 run（size 1）：just_audio 一次 setAudioSources 会
    // 预载整 run，若把多首转码歌并入同 run，会并行打爆转码会话。单例保证
    // 每次激活只对当前这一首转码，且相邻同引擎歌不并入。
    if (logicalIndex < tc.length && tc[logicalIndex]) {
      return (
        start: logicalIndex,
        end: logicalIndex,
        localIndex: 0,
        kind: kind,
      );
    }
    var s = logicalIndex;
    while (s > 0 && k[s - 1] == kind && !(s - 1 < tc.length && tc[s - 1])) {
      s--;
    }
    var e = logicalIndex;
    while (e < k.length - 1 &&
        k[e + 1] == kind &&
        !(e + 1 < tc.length && tc[e + 1])) {
      e++;
    }
    return (start: s, end: e, localIndex: logicalIndex - s, kind: kind);
  }

  /// 激活逻辑索引 [logicalIndex]：把所在 run 的 items 加载到对应引擎并播放。
  ///
  /// 引擎切换时先暂停旧引擎，再加载新 run；记录 [_currentRun] 用于
  /// 引擎流事件映射回逻辑索引。
  ///
  /// **并发保护**：所有调用经 [_loadQueueLock] 串行化，避免两个
  /// `setAudioSources` 在 just_audio 上互相中断（`Loading interrupted`）。
  /// 每个调用在锁链尾部追加自己，返回后更新锁链，天然排队。
  Future<void> _activateLogicalIndex(
    int logicalIndex, {
    Duration? initialPosition,
  }) async {
    final prev = _loadQueueLock;
    final completer = Completer<void>();
    _loadQueueLock = completer.future;
    try {
      await prev;
      await _activateLogicalIndexLocked(logicalIndex, initialPosition);
    } finally {
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// [_activateLogicalIndex] 的实际加载主体（已被锁串行化，无并发）。
  ///
  /// **引擎路由在锁内重算**：`_engineKinds` 的赋值只在锁内发生，锁外调用方
  /// 算的 kinds 只是提示（用于提前构建 run），真正的路由以进入锁后、用
  /// 当前 `queue.value` 重算的结果为准。这消除了「锁外多个调用方互相覆盖
  /// `_engineKinds`，锁内因长度相同而不重算 → 用过期的 kinds 把 dsf 歌加载
  /// 进 justAudio → ExoPlayer 解不了 → Source error → 跳歌」的竞态。
  ///
  /// `_computeEngineKinds` 内部走 `resolvedFormatFor`（会话缓存 + inflight
  /// 去重），重算对已解析的歌零网络开销。
  Future<void> _activateLogicalIndexLocked(
    int logicalIndex,
    Duration? initialPosition,
  ) async {
    if (kDebugMode) {
      debugPrint(
        '[PlayerService] activateLocked idx=$logicalIndex '
        'restoring=$_restoringState gen=$_queueGeneration',
      );
    }
    // 进入锁后再次检查队列代次：恢复流程排进锁后、真正加载前，用户可能
    // 已开始新的播放（playQueue 递增 _queueGeneration）。此时丢弃本次加载，
    // 避免恢复流程把旧会话队列加载进播放器，覆盖用户刚选的队列。
    if (_restoringState && _queueGeneration != 0) {
      if (kDebugMode) {
        debugPrint('[PlayerService] activateLocked SKIPPED (restoring)');
      }
      return;
    }
    final list = queue.value;
    if (list.isEmpty || logicalIndex < 0 || logicalIndex >= list.length) {
      if (kDebugMode) {
        debugPrint('[PlayerService] activateLocked SKIPPED (bad idx)');
      }
      return;
    }
    // 转码会话释放：切歌前先 quit 掉**非当前歌**的转码会话，保证服务端
    // 始终 ≤1 个活动转码会话（播放到哪首才给哪首转码）。当前歌的会话保留
    // 到本 run 加载完成（_sourceForSong 命中缓存直接复用）。fire-and-forget
    // 不阻塞加载。
    final newId = list[logicalIndex].id;
    final toQuit = FeiNiuTranscodeService.instance.activeTranscodeIds
        .where((id) => id != newId)
        .toList();
    if (toQuit.isNotEmpty) {
      unawaited(FeiNiuTranscodeService.instance.quitForIds(toQuit));
    }
    // 从进入锁这一刻起就设置期望索引：切换引擎时旧引擎（如正在播上一首的
    // just_audio）可能广播 currentIndex 过渡事件（pause/准备释放时），
    // currentIndexStream 监听器用 _pendingLoadLogicalIndex 过滤它们。必须
    // 在 pause 旧引擎之前设置，否则「song changed to 旧歌」会先于加载发生。
    _pendingLoadLogicalIndex = logicalIndex;
    // 引擎路由始终在锁内用当前队列重算（不依赖锁外的赋值/长度缓存）。
    final computed = await _computeEngineKinds(list);
    _engineKinds = computed.kinds;
    _engineTranscodeFlags = computed.transcodeFlags;
    final bounds = _runBounds(logicalIndex);
    final targetKind = bounds.kind;
    final target = _engineFor(targetKind);
    if (kDebugMode) {
      debugPrint(
        '[PlayerService] activateLocked kind=$targetKind '
        'run=[${bounds.start},${bounds.end}] local=${bounds.localIndex}',
      );
    }

    // 切换引擎：停止旧引擎，避免双音源/旧音频线程占用输出。
    // 无论旧引擎是 just_audio 还是 media_kit 都必须 stop（不只是 pause）：
    // pause 只暂停播放，ExoPlayer 的 AudioTrack/解码器线程仍占用音频会话，
    // 导致新引擎的 loadQueue/play 后旧音频继续从旧引擎输出（进度条不更新、
    // 播的还是旧歌）。
    final switching = !identical(target, _activeEngine);
    if (switching) {
      try {
        await _activeEngine.stop();
      } catch (_) {}
    }

    // **先切换引擎，再解析条目**：media_kit 的 `_mediaForSong`（直连流/本地
    // 文件解析）虽不阻塞下载，但仍有异步间隙。先切引擎（停旧引擎）后，解析
    // 期间播放器已切到新歌加载态、无旧音，play() 打在正确引擎上。
    _activeEngine = target;
    _activeRunStart = bounds.start;
    // 同步当前解码引擎（UI"更多面板"标签）。
    _state.decoderEngine.value = target.kind;
    // 首次激活该引擎时订阅其流（_wireEngine 幂等）。
    _wireEngine(target);
    // 立即切到新歌的 UI 状态（歌名/封面/进度归零），不等源解析完。
    _activateSong(logicalIndex);
    isLoading.value = true;
    _emitSnapshot(force: true);

    final items = <EngineItem>[];
    // **并发解析 run 内所有歌曲**：串行 `await _resolveEngineItem` 对百首级
    // run（如恢复一个 just_audio 大队列）会逐首阻塞，`_sourceForSong` 每首
    // 都查缓存/可能解析格式，恢复流程被拉得很慢，UI 一直转圈。并发后
    // 197 首歌的解析从「串行数秒」降到「并行一次网络往返」。当前激活歌曲
    // 仍标记 waitForLocal，其余歌曲不阻塞首播。
    final runItems = await Future.wait(
      List.generate(bounds.end - bounds.start + 1, (offset) {
        final i = bounds.start + offset;
        return _resolveEngineItem(
          list[i],
          targetKind,
          waitForLocal: i == logicalIndex,
        );
      }),
    );
    items.addAll(runItems);
    final localIndex = bounds.localIndex;

    try {
      await target
          .loadQueue(
            items: items,
            index: localIndex,
            initialPosition: initialPosition,
            preload: false,
          )
          .timeout(MediaKitEngine.openTimeout + const Duration(seconds: 2));
    } catch (e) {
      _pendingLoadLogicalIndex = null;
      if (kDebugMode) {
        debugPrint('PlayerService loadQueue failed on ${target.kind}: $e');
      }
      // media_kit 格式（DSF/APE/WMA/FLAC…）**不可降级回 just_audio**——它们
      // 正是 ExoPlayer 解不了的格式，降级必然立刻 Source error（日志里
      // `recover ... song=Granmon` 刷屏就是这么来的）。这里的失败抛给上游，
      // 由调用方的错误处理（如 _handlePlayerError）负责重试同一引擎；若反复
      // 失败则跳过该歌（skip），不把播放器卡死在不可播的源上。
      rethrow;
    }
    _pendingLoadLogicalIndex = null;
    // loadQueue 返回后校准：以引擎实际 currentIndex 为准。
    //
    // 只在引擎**确实加载了源**（非 idle）时校准。preload=false 的
    // setAudioSources（just_audio 未播放时走 _setPlatformActive(false)，
    // 不执行 source._shuffle(initialIndex:)）会把 currentIndex 保持在种子值
    // null → getter 返回 0，此时 currentIndex 是"列表首项"而非"我们请求的
    // localIndex"。若用 0 校准会覆盖第 597 行已设对的 logicalIndex（UI 跳回
    // run 起点），持久化错位 → 重启后恢复错歌曲。引擎 idle = 未加载，跳过。
    if (target.processingState != EngineProcessingState.idle) {
      final actualIdx = target.currentIndex;
      if (actualIdx != null && actualIdx >= 0) {
        final actualLogical = _activeRunStart + actualIdx;
        if (actualLogical >= 0 && actualLogical < queue.value.length) {
          _activateSong(actualLogical);
        }
      }
    }
    await target.setLoopMode(
      playbackMode.value == PlaybackMode.single
          ? EngineLoopMode.single
          : EngineLoopMode.none,
    );
    await _applyEngineVolume(target);
    await _applyEngineSpeed(target);
  }

  /// 按引擎类型返回引擎实例（media_kit 懒创建）。
  PlayerEngine _engineFor(EngineKind kind) {
    if (kind == EngineKind.justAudio) return _justAudioEngine;
    return _mediaKitEngine ??= MediaKitEngine();
  }

  /// 把歌曲解析为指定引擎的条目。
  Future<EngineItem> _resolveEngineItem(
    SongEntity song,
    EngineKind kind, {
    bool waitForLocal = false,
  }) async {
    if (kind == EngineKind.mediaKit) {
      return MediaKitItem(
        await _mediaForSong(song, waitForLocal: waitForLocal),
      );
    }
    return JustAudioItem(await _sourceForSong(song));
  }

  /// media_kit 播放源。
  ///
  /// **直连原始流优先**：直接播放 `/track/stream` 返回的**原始文件流**
  /// （DSF/APE/WMA…），mpv 用 FFmpeg 原生解码这些格式（`Media(uri,
  /// httpHeaders:)` 把 Cookie 经 mpv `http-header-fields` 传给重定向后的
  /// 最终源）。真流式、无转码、无下载，首播即起。
  ///
  /// **本地完整文件仅命中已有缓存时使用**：`Media(file)` 本地解码（FFmpeg
  /// 软解，无 32KB 硬件 FLAC 限制、无认证问题），seek 秒响应。未缓存不等待
  /// 下载——直接流式。
  ///
  /// 说明：**不使用服务器转码 HLS**。mpv 附带的 FFmpeg 音频库（
  /// `media_kit_libs_audio`）没有编入 HLS demuxer，转码的 fMP4 HLS
  /// （`init.mp4` + `.m4s`）播不了（`Failed to recognize file format`）。
  Future<mk.Media> _mediaForSong(
    SongEntity song, {
    bool waitForLocal = false,
  }) async {
    // CUE 整轨曲目：跳过本地缓存（命中会拿到整轨文件，缺失会让后台把整轨
    // 下载一份），直连流 + Media(start/end) 裁剪定位。offset 解析失败时退化为
    // 不裁剪（整轨从头播，保持现状容错）。
    final isCue = song.isCue;
    int? cueOffset;
    if (isCue) {
      cueOffset =
          song.cueOffsetMs ?? await FeiNiuCueService.instance.offsetMsFor(song);
    }

    // 1) 本地缓存文件（已存在 → 立即命中，零等待）。
    if (!isCue && StreamCacheService.instance.isEnabled) {
      try {
        final existing = await StreamCacheService.instance.completeFileFor(
          song.id,
          song: song,
        );
        if (existing != null) {
          return mk.Media(existing.path);
        }
      } catch (_) {}
    }

    // 2) 默认：直连原始文件流（mpv 用 FFmpeg 原生解码 DSF/APE/WMA…）。
    //    不使用转码 HLS（mpv 的 FFmpeg 音频库无 HLS demuxer，播不了 fMP4）。
    final uri = FeiNiuApiClient.instance.streamUrl(song.id);
    // 仅为当前激活歌曲后台下载完整缓存。run 内其它歌曲只创建轻量 Media，
    // 下一首由既有链式预缓存负责；否则 macOS 全队列走 media_kit 时会把整段
    // 队列一次性排入下载，DSD 大文件会让待下载任务长期积压。
    // CUE 整轨曲目跳过下载（否则每首各缓存一份整轨镜像）。
    if (waitForLocal && !isCue && StreamCacheService.instance.isEnabled) {
      StreamCacheService.instance.cacheSong(song);
    }
    if (isCue && cueOffset != null) {
      final offset = Duration(milliseconds: cueOffset);
      final end = Duration(milliseconds: cueOffset + (song.durationMs ?? 0));
      return mk.Media(
        uri,
        start: offset,
        end: end,
        httpHeaders: FeiNiuApiClient.imageAuthHeaders(),
      );
    }
    return mk.Media(uri, httpHeaders: FeiNiuApiClient.imageAuthHeaders());
  }

  Future<void> _applyEngineVolume(PlayerEngine engine) async {
    try {
      await engine.setVolume(
        AppPlaybackVolumeSettings.volume.value.clamp(0, 1),
      );
    } catch (_) {}
  }

  /// 把当前持久化倍速应用到指定引擎。任何倍速变更都经这里落引擎。
  Future<void> _applyEngineSpeed(PlayerEngine engine) async {
    try {
      await engine.setSpeed(
        AppPlaybackSpeedSettings.speed.value
            .clamp(
              AppPlaybackSpeedSettings.minSpeed,
              AppPlaybackSpeedSettings.maxSpeed,
            )
            .toDouble(),
      );
    } catch (_) {}
  }

  void _handlePlaybackSpeedChanged() {
    unawaited(_applyEngineSpeed(_activeEngine));
  }

  void _handleAppVolumeChanged() {
    unawaited(_applyAppVolume(AppPlaybackVolumeSettings.volume.value));
  }

  Future<void> _applyAppVolume(double value) async {
    try {
      await _activeEngine.setVolume(value.clamp(0, 1).toDouble());
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerService set volume failed: $e');
    }
  }

  Future<void> playQueue(
    List<SongEntity> songs,
    int startIndex, {
    PlaybackMode? mode,
    String? roamChainId,
  }) async {
    // 递增队列代次必须在等待 _initFuture 之前：恢复流程（_restorePlaybackState）
    // 用 _queueGeneration 判断「用户是否已开始新的播放」来决定是否放弃恢复。
    // 若递增放在 await _initFuture 之后，恢复流程永远看不到用户点播放（playQueue
    // 还卡在等 _initFuture），会把旧会话队列加载进播放器，与用户刚选的队列并发
    // setAudioSources → just_audio 抛 PlayerInterruptedException（Loading interrupted）。
    _queueGeneration++;
    // 用户显式新建播放队列：清除本会话 media_kit「无法播放」黑名单，让
    // 偶发失败（网络抖动/服务器慢/音频设备瞬时不可用）的歌曲在重新点播时
    // 有机会再试，而不是整个会话内一直被跳过。升级标记
    // （_mediaKitEscalateSongIds）是结构性路由决定，不在此清除。
    _mediaKitFailedSongIds.clear();
    // 等待初始化（含旧播放会话恢复）完成，避免 setAudioSources 与恢复流程
    // 并发交错导致播放器物理 loop/shuffle 状态被覆盖。
    await _initFuture;
    _clearRestoreSession();
    queueExtender = null;
    _isExtendingQueue = false;
    // 注意：显式用 this.roamId 强调这是成员字段赋值。历史上参数 roamId 曾
    // 遮蔽成员字段，导致 this.roamId 无法被正确恢复（roamId 永远清空），
    // 漫游续链时用错 roamId。参数现在命名 roamChainId 以彻底避免遮蔽，
    // 此处保留 this. 作为防御与文档。
    // ignore: unnecessary_this
    this.roamId = null;
    // 调用方传入漫游链时（如首页漫游点 banner），在清空后立即恢复，
    // 消除「playQueue 返回后手动恢复」的时序窗口：期间若有队列扩展触发，
    // roamId 非空走追加分支，不会 getRoamStart 新开队列。
    if (roamChainId != null && roamChainId.isNotEmpty) {
      // ignore: unnecessary_this
      this.roamId = roamChainId;
    }
    final playable = songs
        .where((s) => (s.uri ?? '').trim().isNotEmpty)
        .toList();
    if (playable.isEmpty) return;
    final targetId = startIndex >= 0 && startIndex < songs.length
        ? songs[startIndex].id
        : null;
    var actualIndex = targetId == null
        ? 0
        : playable.indexWhere((s) => s.id == targetId);
    if (actualIndex < 0) actualIndex = 0;
    // 队列长度上限：新建队列即截断到设置上限以内
    final capped = _capQueue(playable, actualIndex);
    if (capped != null) {
      playable
        ..clear()
        ..addAll(capped.$1);
      actualIndex = capped.$2;
    }
    _debugLog(
      'playQueue size=${playable.length} startIndex=$startIndex actualIndex=$actualIndex song=${playable[actualIndex].title}',
    );
    _applyLogicalQueue(playable, actualIndex);

    // 投屏遥控模式：点漫游/新队列 = 更新逻辑队列 + 把起始歌曲推送到投屏设备。
    // 不加载/不启动本机引擎（本机已暂停），避免手机和电视各播各的。
    if (isCasting.value) {
      // 应用目标模式（漫游 shuffle / 默认 loop），让队列续播语义与本机一致。
      final targetMode = mode ?? PlaybackMode.loop;
      if (playbackMode.value != targetMode || mode != null) {
        playbackMode.value = targetMode;
      }
      _schedulePersistPlaybackState();
      _activateSong(actualIndex);
      _emitSnapshot(force: true);
      final song = currentSong.value;
      if (song != null) {
        await DlnaCastService.instance.loadSong(song);
      }
      return;
    }

    // 双引擎架构：计算引擎路由，只加载当前 run 到对应引擎。
    _applyEngineKinds(await _computeEngineKinds(playable));

    String? loadFailReason;
    Future<bool> loadCurrentRunOnce() async {
      try {
        await _activateLogicalIndex(actualIndex);
        return true;
      } catch (e) {
        loadFailReason = e.toString();
        if (kDebugMode) {
          debugPrint('PlayerService.playQueue activate failed: $e');
        }
        final msg = loadFailReason!;
        final shouldRetry =
            msg.contains('404') ||
            msg.contains('InvalidResponseCodeException') ||
            msg.contains('Source error');
        if (!shouldRetry) return false;

        try {
          await _activeEngine.stop();
        } catch (_) {}

        final current = playable[actualIndex];
        _invalidateResolvedSource(current);
        await _resolvePlayableUri(current, forceRefresh: true);
        FeiNiuTranscodeService.instance.invalidate(current.id);

        try {
          await _activateLogicalIndex(actualIndex);
          return true;
        } catch (e2) {
          loadFailReason = e2.toString();
          if (kDebugMode) {
            debugPrint('PlayerService.playQueue activate retry failed: $e2');
          }
          return false;
        }
      }
    }

    final ok = await loadCurrentRunOnce();
    if (!ok) {
      try {
        await _activeEngine.stop();
      } catch (_) {}
      isPlaying.value = false;
      _emitSnapshot(force: true);
      // 初始播放失败不再静默：告诉用户原因（mpv 原始报错经 _briefFailureReason
      // 截断），区分「网络/源问题」还是「本机不可播」，避免反复盲试。
      AppToast.showGlobal(
        '播放失败：${playable[actualIndex].title}\n'
        '${_briefFailureReason(loadFailReason)}',
        type: ToastType.error,
      );
      return;
    }

    // 目标模式：调用方传入（如漫游 shuffle）则用传入值，否则默认 loop。
    // 在引擎加载之后立即应用模式，避免「playQueue 返回后再调
    // setPlaybackMode」的窗口里播完自动顺序切歌（表现为列表循环而非随机）。
    final targetMode = mode ?? PlaybackMode.loop;
    if (playbackMode.value != targetMode || mode != null) {
      await setPlaybackMode(targetMode);
    } else {
      await _applyPlaybackMode(targetMode);
    }

    try {
      await _activeEngine.play();
    } catch (e) {
      try {
        await _activeEngine.stop();
      } catch (_) {}
      isPlaying.value = false;
      _emitSnapshot();
      if (kDebugMode) {
        debugPrint('PlayerService.playQueue play failed: $e');
      }
    }
  }

  /// 按队列上限自动填充后播放。
  ///
  /// **立即切歌**：先用已加载的 [initialSongs] 播放（`currentSong` 立刻更新、
  /// 物理源立刻切换），**不等待**填满队列——消除「点歌后旧歌继续播、封面/歌名
  /// 延迟切换」的问题。队列填充改为后台异步进行：
  /// [fetchMore] 返回「第 (已加载页数 + page) 页」的歌曲列表（空列表表示
  /// 没有更多），闭包内写 `已加载页数 + page` 即可，且不应修改页面自身的分页状态。
  /// 注意：填充拉取的数据只用于队列，不会回写页面列表。
  Future<void> playQueueFilledToLimit(
    List<SongEntity> initialSongs,
    int startIndex, {
    PlaybackMode? mode,
    String? roamChainId,
    Future<List<SongEntity>> Function(int page)? fetchMore,
  }) async {
    final idx = startIndex >= 0 && startIndex < initialSongs.length
        ? startIndex
        : 0;
    // 立即播放：点歌即切歌，currentSong 同步更新，不等后台填充。
    await playQueue(initialSongs, idx, mode: mode, roamChainId: roamChainId);
    // 后台异步填充队列到上限（不阻塞播放切换）。
    if (fetchMore == null) return;
    final cap = _queueCap;
    if (initialSongs.length >= cap) return;
    final gen = _queueGeneration;
    unawaited(_fillQueueInBackground(initialSongs, fetchMore, cap, gen));
  }

  /// 后台分页填充队列到上限 [cap]。仅在队列代次未变（用户未切换播放）时
  /// 才追加，避免把歌曲拼到用户新选的队列上。填充使用与正常队列增长相同的
  /// [_appendToQueue]（逻辑 + 物理源同步、超长截断），只是从关键路径挪到后台。
  Future<void> _fillQueueInBackground(
    List<SongEntity> base,
    Future<List<SongEntity>> Function(int page) fetchMore,
    int cap,
    int gen,
  ) async {
    final acc = <SongEntity>[];
    var page = 1;
    while (base.length + acc.length < cap) {
      try {
        final next = await fetchMore(page++);
        if (next.isEmpty) break;
        acc.addAll(next);
      } catch (_) {
        break; // 网络/分页失败即停止填充，不影响已开始的播放
      }
    }
    if (acc.isEmpty) return;
    if (gen != _queueGeneration) return; // 用户已切换播放，丢弃本次填充
    await _appendToQueue(acc);
  }

  void _maybePrefetchByRemaining(Duration positionValue) {
    if (!WebDavPlaybackSettings.prefetchEnabled.value) return;
    final total = duration.value;
    if (total == null || total.inMilliseconds <= 0) return;
    final remaining = total - positionValue;
    if (remaining.inSeconds > 30) return;
    final idx = currentIndex.value;
    if (idx < 0 || idx == _prefetchTriggeredIndex) return;
    _prefetchTriggeredIndex = idx;
    _prefetchUpcoming();
  }

  Future<void> _prefetchUpcoming() async {
    if (!WebDavPlaybackSettings.prefetchEnabled.value) return;
    final list = queue.value;
    final startIndex = currentIndex.value;
    if (startIndex < 0 || list.isEmpty) return;
    final nextIndex = startIndex + 1;
    if (nextIndex < 0 || nextIndex >= list.length) return;
    final song = list[nextIndex];
    _debugLog('prefetch upcoming index=$nextIndex song=${song.title}');

    // 提前解析下一首歌的播放 URL，使 HTTP 连接就绪，切歌时无缝衔接
    await _warmupSource(song);

    // 预加载下一首歌的 800px 封面图，切歌时封面立显
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      // 恢复播放/初始化窗口内根元素可能尚未挂载（rootElement 为 null），
      // 封面预热尽力而为：挂载后才调用，否则跳过。
      final root = WidgetsBinding.instance.rootElement;
      if (root != null) {
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(
              FeiNiuApiClient.instance.coverUrl(
                song.coverId!,
                size: FeiNiuApiClient.coverRequestSize,
                updatedAt: song.updatedAt,
              ),
              headers: FeiNiuApiClient.imageAuthHeaders(),
            ),
            root,
          ),
        );
      }
    }
  }

  /// 链式预缓存下一首：当前歌曲缓存下载完成后才自动缓存下一首（非时间触发）。
  ///
  /// 漫游/随机模式同样生效：新模型下队列即真源（顺序播放，_extendRoamQueue
  /// 已把下一首追加到队尾），_nextSongForIndex 返回的正是即将播放的下一首。
  Future<void> _precacheNextChained(
    SongEntity current,
    List<SongEntity> list,
    int index,
  ) async {
    if (!AppCacheSettings.precacheNextSong.value) return;
    if (!_precacheChainInFlight.add(current.id)) return; // 去重
    try {
      // 链式节点：等待当前歌缓存下载完成（已完整则立即返回）。
      // 漫游模式下若当前曲尚未被缓存（在线播放），等待其流式下载完成，
      // 完成后立即预加载下一曲的文件，切歌时无缝衔接。
      await StreamCacheService.instance.waitForComplete(
        current.id,
        song: current,
      );
      if (!AppCacheSettings.precacheNextSong.value) return; // 等待中开关被关
      final next = _nextSongForIndex(list, index);
      if (next == null || next.id == current.id) return; // 队列尾/防御
      StreamCacheService.instance.precacheSong(next);
    } finally {
      _precacheChainInFlight.remove(current.id);
    }
  }

  Future<void> removeSongsById(
    List<String> ids, {
    bool playNextIfCurrentRemoved = true,
  }) async {
    if (ids.isEmpty) return;
    final toRemove = ids.toSet();

    final current = currentSong.value;
    final oldQueue = queue.value;

    if (current != null && toRemove.contains(current.id)) {
      final remaining = oldQueue
          .where((s) => !toRemove.contains(s.id))
          .toList();
      if (remaining.isEmpty) {
        await stopAndClear();
        return;
      }
      if (!playNextIfCurrentRemoved) {
        await stopAndClear();
        return;
      }
      var nextIndex = currentIndex.value;
      if (nextIndex < 0) nextIndex = 0;
      if (nextIndex >= remaining.length) nextIndex = remaining.length - 1;
      await _reloadQueue(
        remaining,
        nextIndex,
        play: true,
        initialPosition: Duration.zero,
      );
      return;
    }

    if (oldQueue.isEmpty) return;
    final remaining = oldQueue.where((s) => !toRemove.contains(s.id)).toList();
    if (remaining.length == oldQueue.length) return;

    if (current == null) {
      queue.value = remaining;
      currentIndex.value = remaining.isEmpty ? -1 : 0;
      currentSong.value = remaining.isEmpty ? null : remaining.first;
      _emitSnapshot();
      return;
    }

    final oldCurrentIndex = currentIndex.value;
    if (oldCurrentIndex < 0 ||
        oldCurrentIndex >= oldQueue.length ||
        oldQueue[oldCurrentIndex].id != current.id) {
      await stopAndClear();
      return;
    }
    final wasPlaying = isPlaying.value;
    final enginePosition = _activeEngine.position;
    final resumePosition = enginePosition > Duration.zero
        ? enginePosition
        : position.value;
    final removedIndices = <int>[
      for (var i = 0; i < oldQueue.length; i++)
        if (toRemove.contains(oldQueue[i].id)) i,
    ];
    final nextIndex =
        oldCurrentIndex -
        removedIndices.where((i) => i < oldCurrentIndex).length;

    // 原生播放器只装载当前同引擎 run。若逻辑队列与引擎队列仍严格对齐，
    // 直接原地删除条目，让当前媒体与解码管线保持不动，播放位置自然保留。
    // 删除跨引擎边界歌曲可能把前后两个 run 合并；这种情况下物理队列不完整，
    // 才回退到带断点位置的全量重载。
    final canPlanInPlace =
        _engineKinds.length == oldQueue.length &&
        _engineTranscodeFlags.length == oldQueue.length &&
        _activeRunStart <= oldCurrentIndex &&
        oldCurrentIndex < _activeRunStart + _activeEngine.sequenceLength;
    if (!canPlanInPlace) {
      await _reloadQueue(
        remaining,
        nextIndex,
        play: wasPlaying,
        initialPosition: resumePosition,
      );
      return;
    }

    final oldBounds = _runBounds(oldCurrentIndex);
    final remainingKinds = <EngineKind>[
      for (var i = 0; i < _engineKinds.length; i++)
        if (!toRemove.contains(oldQueue[i].id)) _engineKinds[i],
    ];
    final remainingTranscodeFlags = <bool>[
      for (var i = 0; i < _engineTranscodeFlags.length; i++)
        if (!toRemove.contains(oldQueue[i].id)) _engineTranscodeFlags[i],
    ];
    final newBounds = _runBounds(
      nextIndex,
      kinds: remainingKinds,
      transcodeFlags: remainingTranscodeFlags,
    );
    final loadedRunAfterRemoval = <SongEntity>[
      for (var i = oldBounds.start; i <= oldBounds.end; i++)
        if (!toRemove.contains(oldQueue[i].id)) oldQueue[i],
    ];
    final newRun = remaining.sublist(newBounds.start, newBounds.end + 1);
    final runStillAligned =
        oldBounds.start == _activeRunStart &&
        oldBounds.kind == _activeEngine.kind &&
        oldBounds.end - oldBounds.start + 1 == _activeEngine.sequenceLength &&
        loadedRunAfterRemoval.length == newRun.length &&
        List.generate(
          newRun.length,
          (i) => loadedRunAfterRemoval[i].id == newRun[i].id,
        ).every((same) => same);
    if (!runStillAligned) {
      await _reloadQueue(
        remaining,
        nextIndex,
        play: wasPlaying,
        initialPosition: resumePosition,
      );
      return;
    }

    final localIndicesToRemove =
        removedIndices
            .where((i) => i >= oldBounds.start && i <= oldBounds.end)
            .map((i) => i - oldBounds.start)
            .toList()
          ..sort((a, b) => b.compareTo(a));

    _pendingLoadLogicalIndex = nextIndex;
    queue.value = remaining;
    _engineKinds = remainingKinds;
    _engineTranscodeFlags = remainingTranscodeFlags;
    _activeRunStart = newBounds.start;
    try {
      for (final localIndex in localIndicesToRemove) {
        await _activeEngine.removeItem(localIndex);
      }
      _activateSong(nextIndex);
      _emitSnapshot(force: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService remove queue item in place failed: $e');
      }
      await _reloadQueue(
        remaining,
        nextIndex,
        play: wasPlaying,
        initialPosition: resumePosition,
      );
    } finally {
      _pendingLoadLogicalIndex = null;
    }
  }

  Future<void> stopAndClear() async {
    _debugLog('stopAndClear');
    _clearRestoreSession();
    queueExtender = null;
    _isExtendingQueue = false;
    roamId = null;
    // 释放全部服务器转码会话（fire-and-forget，不阻塞停止流程）。
    unawaited(FeiNiuTranscodeService.instance.quitAll());
    _stopBackgroundAudioKeepAlive();
    _statsFlushTimer?.cancel();
    await _statsService.flush();
    try {
      await _activeEngine.stop();
    } catch (_) {}
    // 停掉非活跃引擎，确保双引擎都不出声、不占用资源。
    if (_mediaKitEngine != null && !identical(_mediaKitEngine, _activeEngine)) {
      try {
        await _mediaKitEngine!.stop();
      } catch (_) {}
    }
    await _setAudioSessionActive(false);
    isPlaying.value = false;
    position.value = Duration.zero;
    duration.value = null;
    bufferedPosition.value = Duration.zero;
    queue.value = const [];
    currentIndex.value = -1;
    currentSong.value = null;
    _emitSnapshot(force: true);
    await _clearPersistedPlaybackState();
  }

  Future<void> _reloadQueue(
    List<SongEntity> songs,
    int startIndex, {
    required bool play,
    Duration? initialPosition,
  }) async {
    _clearRestoreSession();
    final playable = songs
        .where((s) => (s.uri ?? '').trim().isNotEmpty)
        .toList();
    if (playable.isEmpty) {
      await stopAndClear();
      return;
    }
    var actualIndex = startIndex;
    if (actualIndex < 0) actualIndex = 0;
    if (actualIndex >= playable.length) actualIndex = playable.length - 1;

    _applyLogicalQueue(playable, actualIndex);

    _applyEngineKinds(await _computeEngineKinds(playable));
    try {
      await _activateLogicalIndex(
        actualIndex,
        initialPosition: initialPosition,
      );
    } catch (e) {
      await stopAndClear();
      if (kDebugMode) {
        debugPrint('PlayerService._reloadQueue activate failed: $e');
      }
      return;
    }

    if (play) {
      try {
        await _startPlayback();
      } catch (e) {
        await stopAndClear();
        if (kDebugMode) {
          debugPrint('PlayerService._reloadQueue play failed: $e');
        }
      }
    } else {
      try {
        await _pausePlayback();
      } catch (_) {}
    }
  }

  Future<void> _handlePlayerError(EngineError error) async {
    if (_recoveringCurrentSource) return;
    final list = queue.value;
    if (list.isEmpty) return;

    // media_kit 的 mpv 错误常在播放列表尚未建立时上报（playlist.index 无效），
    // 此时 index 为 null。用当前歌曲兜底：仍能定位到失败歌曲并触发降级/恢复，
    // 避免「mpv 识别不了 HLS → index null → 错误被吞 → 静默跳下一首」。
    // EngineError.index 按 PlayerEngine 契约是当前物理 run 内索引，必须映射
    // 回逻辑队列；直接当逻辑索引会在 runStart != 0 时恢复到另一首歌曲。
    var failedIndex = error.index == null
        ? null
        : _activeRunStart + error.index!;
    if (failedIndex == null || failedIndex < 0 || failedIndex >= list.length) {
      failedIndex = currentIndex.value;
    }
    if (failedIndex < 0 || failedIndex >= list.length) {
      if (kDebugMode) {
        debugPrint(
          'PlayerService player error without valid index: ${error.message}',
        );
      }
      return;
    }

    final failedSong = list[failedIndex];
    final rawUri = (failedSong.uri ?? '').trim();
    if (!rawUri.startsWith('http')) {
      if (kDebugMode) {
        debugPrint(
          'PlayerService player error on non-remote source: ${error.message}',
        );
      }
      return;
    }

    // 双引擎架构错误处理：
    // - just_audio 解码 FLAC 帧超限（`Buffer too small`）→ 升级到 media_kit
    //   （FFmpeg 无损解码，无 32KB 限制）。
    // - media_kit 解码失败（mpv demux 错误）→ 重试同一原始流，连续失败跳过
    //   该歌（前进/回卷），不卡死在不可播的源上。
    // 两种都避免反复重试死循环（会话级标记）。
    _recoveringCurrentSource = true;
    try {
      final isMediaKitError = _activeEngine.kind == EngineKind.mediaKit;
      final errorMsg = error.message;
      final isFlacTooLarge =
          !isMediaKitError &&
          (errorMsg.contains('InsufficientCapacity') ||
              errorMsg.contains('Buffer too small'));
      // 系统解码器失败（非 FLAC 帧超限）：
      // `MediaCodecAudioRenderer error` / `Decoder failed` / `CodecException` /
      // `0x80000000`。ExoPlayer 选中某解码器（如高通 C2 软解 c2.qti.alac.sw
      // .decoder）后失败不会自动换解码器，重试 just_audio 必然再失败（日志里
      // ALAC 反复失败卡死）。升级 media_kit（FFmpeg 软解）保证可播。
      final isSystemDecoderFail =
          !isMediaKitError &&
          (errorMsg.contains('MediaCodecAudioRenderer') ||
              errorMsg.contains('Decoder failed') ||
              errorMsg.contains('CodecException') ||
              errorMsg.contains('0x80000000') ||
              errorMsg.contains('0xffffffff'));

      _debugLog(
        'recover current source index=$failedIndex song=${failedSong.title} '
        'engine=${_activeEngine.kind} error=$errorMsg',
      );

      final wasPlaying = isPlaying.value;
      final seekPos = failedIndex == currentIndex.value
          ? position.value
          : Duration.zero;

      // 转码歌（just_audio 播 HLS）解析失败：优先降级音质，而非直接升级/跳过。
      // - 生效 codec 是 flac 且未降级 → 降级 mp3 重新转码（flac→mp3→直连）。
      // - 已是 mp3/opus 或已降级仍失败 → 完全失败：标记退直连（不重转码，
      //   防死循环）。
      if (!isMediaKitError &&
          FeiNiuTranscodeService.instance.activeTranscodeIds.contains(
            failedSong.id,
          )) {
        final codec = FeiNiuTranscodeService.instance.effectiveCodecFor(
          failedSong.id,
        );
        if (codec == 'flac' &&
            !FeiNiuTranscodeService.instance.isDowngradedToMp3(failedSong.id)) {
          _debugLog(
            'transcode ${failedSong.title} flac decode failed -> downgrade mp3',
          );
          FeiNiuTranscodeService.instance.markDowngradeToMp3(failedSong.id);
          _quitTranscodeFor(failedSong.id);
          _applyEngineKinds(await _computeEngineKinds(list));
          await _activateLogicalIndex(
            failedIndex,
            initialPosition: seekPos > Duration.zero ? seekPos : null,
          );
          if (wasPlaying) {
            await _startPlayback();
          }
          return;
        }
        _transcodeFailedSongIds.add(failedSong.id);
        _quitTranscodeFor(failedSong.id);
        // 落回下方分支：isFlacTooLarge/isSystemDecoderFail 走 media_kit 直连，
        // 普通 just_audio 失败走直连，DSF 等回落 routeForSong → mediaKit 直连。
      }

      if (isFlacTooLarge || isSystemDecoderFail) {
        // FLAC 帧超限 / 系统解码器失败 → 升级 media_kit（FFmpeg 软解，
        // 无 32KB 限制、无设备解码器差异）。
        _mediaKitEscalateSongIds.add(failedSong.id);
        _quitTranscodeFor(failedSong.id);
        _applyEngineKinds(await _computeEngineKinds(list));
        await _activateLogicalIndex(
          failedIndex,
          initialPosition: seekPos > Duration.zero ? seekPos : null,
        );
        if (wasPlaying) {
          await _startPlayback();
        }
        return;
      }

      if (isMediaKitError) {
        // media_kit 解码失败（mpv demux 错误）：**不能降级回 just_audio**
        // （走 media_kit 的格式 ExoPlayer 解不了）。
        //
        // 直连原始流（/track/stream）失败通常意味着 mpv 认不出该格式或流
        // 有问题。策略：第一次失效转码缓存后重试同一原始流；连续两次失败
        // → 跳过该歌（前进/回卷），不卡死在不可播的源上。
        if (_mediaKitFailedSongIds.contains(failedSong.id)) {
          _mediaKitFailedSongIds.add(failedSong.id);
          await _skipFailedSong(failedSong, wasPlaying, reason: errorMsg);
          return;
        }
        _mediaKitFailedSongIds.add(failedSong.id);
        _quitTranscodeFor(failedSong.id);
        _applyEngineKinds(await _computeEngineKinds(list));
        await _activateLogicalIndex(
          failedIndex,
          initialPosition: seekPos > Duration.zero ? seekPos : null,
        );
        if (wasPlaying) {
          await _startPlayback();
        }
        return;
      }

      // just_audio 其他错误：通用恢复——失效缓存、重载当前 run。
      _invalidateResolvedSource(failedSong);
      await _resolvePlayableUri(failedSong, forceRefresh: true);
      _quitTranscodeFor(failedSong.id);
      _applyEngineKinds(await _computeEngineKinds(list));
      _applyLogicalQueue(list, failedIndex);
      await _activateLogicalIndex(
        failedIndex,
        initialPosition: seekPos > Duration.zero ? seekPos : null,
      );
      if (wasPlaying) {
        await _startPlayback();
      } else {
        await _pausePlayback();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService current source recovery failed: $e');
      }
    } finally {
      _recoveringCurrentSource = false;
    }
  }

  /// 清除某首歌的转码状态并释放服务器转码会话（播放出错强制刷新时调用）。
  /// 会话内保留失败/降级标记，避免死循环重试。
  ///
  /// 只有该歌**确实登记了活动转码会话**（activeTranscodeIds）才发 quit POST，
  /// 避免对未转码的歌（如 just_audio 直连 DSF 解码失败）空发 quit 请求。
  void _quitTranscodeFor(String songId) {
    final svc = FeiNiuTranscodeService.instance;
    if (svc.activeTranscodeIds.contains(songId)) {
      unawaited(svc.quitFor(songId));
    }
    svc.invalidate(songId);
  }

  /// media_kit 连续失败后跳过该歌：前进到下一首；队尾则按 loop 回卷/停止。
  /// 在 [_handlePlayerError] 的恢复块内调用（`_recoveringCurrentSource` 已置位，
  /// 不会再触发重复恢复）。跳过用 [_advanceToLogicalIndex] / [_activateLogicalIndex]，
  /// 由恢复块 finally 释放 `_recoveringCurrentSource`。
  /// 截断播放器原始报错为适合 toast 展示的短句（多行取首行 + 超长加省略号）。
  static String _briefFailureReason(String? reason) {
    if (reason == null || reason.isEmpty) return '无法播放';
    final trimmed = reason.trim();
    final firstLine = trimmed.contains('\n')
        ? trimmed.substring(0, trimmed.indexOf('\n'))
        : trimmed;
    return firstLine.length > 40 ? '${firstLine.substring(0, 40)}…' : firstLine;
  }

  Future<void> _skipFailedSong(
    SongEntity failedSong,
    bool wasPlaying, {
    String? reason,
  }) async {
    if (kDebugMode) {
      debugPrint(
        'PlayerService skip failed media_kit song: ${failedSong.title} '
        'reason=$reason',
      );
    }
    // 不静默跳歌：让用户看到失败原因（mpv 原始报错可能很长，截断后展示）。
    // 依赖设置页「调试模式」的完整日志可进一步定位。
    AppToast.showGlobal(
      '播放失败：${failedSong.title}\n${_briefFailureReason(reason)}',
      type: ToastType.error,
    );
    final list = queue.value;
    final idx = currentIndex.value;
    if (list.isEmpty || idx < 0 || idx >= list.length) return;
    if (idx >= list.length - 1) {
      // 逻辑队尾：loop 回卷到队首（可能跨引擎）。
      if (playbackMode.value == PlaybackMode.loop) {
        await _activateLogicalIndex(0);
        if (wasPlaying) {
          try {
            await _activeEngine.play();
          } catch (_) {}
        }
      } else {
        // 无循环且队尾：停住，不静默回卷。
        try {
          await _activeEngine.stop();
        } catch (_) {}
        isPlaying.value = false;
        _emitSnapshot(force: true);
      }
      return;
    }
    await _advanceToLogicalIndex(idx + 1, resumePlayback: wasPlaying);
  }

  /// 是否应为当前歌曲启动无声看门狗。
  ///
  /// - just_audio 引擎：仅当 codec **未知**且容器可能内嵌风险 codec
  ///   （m4a/mp4/aac…）时 arm——这类歌 ExoPlayer 设备解码器可能静默失败。
  ///   codec 已知（eac3/alac 等）已由路由层直接走 media_kit，无需看门狗；
  ///   普通 flac/mp3/ogg 容器不 arm，避免误报。
  /// - media_kit 引擎：不再 arm——升级后由 mpv errorStream 兜底，避免把
  ///   「media_kit 已正常出声」误判为再次无声。
  bool _shouldArmSilenceWatch() {
    if (_recoveringCurrentSource || _restoringState) return false;
    final song = currentSong.value;
    if (song == null) return false;
    if (_activeEngine.kind != EngineKind.justAudio) return false;
    // 已升级过 → 不重复处理。
    if (_silenceWatchEscalatedSongIds.contains(song.id)) return false;
    return song.codec == null &&
        FeiNiuTranscodeService.isRiskySilenceContainer(song.format);
  }

  /// 歌曲切换时重新启动无声看门狗。取消旧 timer，按条件决定是否 arm。
  void _restartSilenceWatch() {
    _silenceWatchTimer?.cancel();
    _silenceWatchTimer = null;
    _silenceWatchSongId = null;
    if (!_shouldArmSilenceWatch()) return;
    final song = currentSong.value;
    if (song == null) return;
    _silenceWatchSongId = song.id;
    _silenceWatchTimer = Timer(_silenceGrace, _maybeHandleSilence);
  }

  /// 无声看门狗到点：判断「位置照常推进但可能无声」，升级 media_kit 重播。
  Future<void> _maybeHandleSilence() async {
    _silenceWatchTimer = null;
    // 守卫：歌未变、仍在播、位置确有推进、不在错误恢复中。
    final song = currentSong.value;
    if (song == null || _silenceWatchSongId != song.id) return;
    if (_recoveringCurrentSource || _restoringState) return;
    if (!isPlaying.value || !_activeEngine.playing) return;
    if (position.value < _silenceMinAdvance) return;

    _debugLog(
      'possible silent playback song=${song.title} '
      'pos=${position.value}',
    );
    final seekPos = position.value;
    final wasPlaying = isPlaying.value;
    _silenceWatchEscalatedSongIds.add(song.id);

    _recoveringCurrentSource = true;
    try {
      // 仅该歌升级 media_kit 重播（复用 FLAC 帧超限升级路径）。
      _mediaKitEscalateSongIds.add(song.id);
      FeiNiuTranscodeService.instance.invalidate(song.id);
      _applyEngineKinds(await _computeEngineKinds(queue.value));
      await _activateLogicalIndex(
        currentIndex.value,
        initialPosition: seekPos > Duration.zero ? seekPos : null,
      );
      if (wasPlaying) {
        await _startPlayback();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService silence recovery failed: $e');
      }
    } finally {
      _recoveringCurrentSource = false;
    }
  }

  Future<void> togglePlayPause() async {
    if (isCasting.value) {
      // 投屏遥控模式：由投屏设备当前状态决定播放/暂停。
      final cast = DlnaCastService.instance;
      if (isPlaying.value) {
        await cast.pause();
        isPlaying.value = false;
      } else {
        await cast.play();
        isPlaying.value = true;
      }
      _emitSnapshot(force: true);
      return;
    }
    if (_activeEngine.playing) {
      await _pausePlayback();
    } else {
      await _startPlayback();
    }
  }

  Future<void> play() async {
    if (isCasting.value) {
      // 投屏遥控模式：转发到投屏设备
      await DlnaCastService.instance.play();
      return;
    }
    await _startPlayback();
  }

  /// 无损大文件（media_kit 直连原始流）缓冲超时 → 提示网络缓慢（一次）。
  /// 缓冲开始后启动 [Duration] 阈值计时器，超时仍未解除缓冲则弹全局 toast。
  static const Duration _slowNetworkThreshold = Duration(seconds: 4);

  void _maybeNotifySlowNetwork() {
    if (_slowNetworkTimer != null || _slowNetworkNotified) return;
    _slowNetworkTimer = Timer(_slowNetworkThreshold, () {
      _slowNetworkNotified = true;
      _slowNetworkTimer = null;
      // 无 BuildContext 全局 toast：根 Navigator 未就绪时静默丢弃。
      AppToast.showGlobal('网络缓慢，正在缓冲…');
    });
  }

  void _cancelSlowNetworkTimer() {
    _slowNetworkTimer?.cancel();
    _slowNetworkTimer = null;
    _slowNetworkNotified = false;
  }

  Future<void> pause() async {
    if (isCasting.value) {
      await DlnaCastService.instance.pause();
      return;
    }
    await _pausePlayback();
  }

  Future<void> next() async {
    if (isCasting.value) {
      // 投屏遥控模式：先在逻辑队列前进到下一首（随机/漫游自动填充），
      // 再把新歌推送到投屏设备。
      await _advanceCastToNext();
      return;
    }
    _clearRestoreSession();
    final list = queue.value;
    final idx = currentIndex.value;
    if (list.isEmpty || idx < 0) return;
    // 漫游/随机模式：切到队尾时若未预填，先追加一首再前进。
    if (playbackMode.value == PlaybackMode.shuffle) {
      // 刚切到随机、待启动漫游：手动切下一曲也应创建漫游新队列。
      if (_roamStartPending) {
        _roamStartPending = false;
        await _startRoamFromPending();
        return;
      }
      // 队尾无下一首：先拉取追加。等待追加完成（含在途请求）再前进，
      // 避免 run 无源可切时 next 停在队尾。
      if (idx >= list.length - 1) {
        await _extendRoamQueue();
        final afterList = queue.value;
        if (idx >= afterList.length - 1) {
          return; // 追加失败（网络异常）且仍无可播下一首：停留队尾
        }
      }
    }
    final targetIdx = idx + 1;
    if (targetIdx >= queue.value.length) {
      // 逻辑队尾：loop 回卷到队首（可能跨引擎）。
      if (playbackMode.value == PlaybackMode.loop) {
        await _activateLogicalIndex(0);
        try {
          await _activeEngine.play();
        } catch (_) {}
      }
      return;
    }
    await _advanceToLogicalIndex(targetIdx);
  }

  /// 投屏设备播完当前歌曲后的续播：推进逻辑队列（随机/漫游模式自动填充），
  /// 把下一首推送到投屏设备。
  Future<void> _advanceCastToNext() async {
    // 随机/漫游模式：队尾无下一首时先追加，保证队列不枯竭。
    final list = queue.value;
    final idx = currentIndex.value;
    if (list.isEmpty || idx < 0) return;
    if (playbackMode.value == PlaybackMode.shuffle && idx >= list.length - 1) {
      // 漫游链：roam-next 追加；本地随机（playShuffle）：queueExtender 追加。
      if (roamActive) {
        await _extendRoamQueue();
      } else {
        await _autoExtendQueue();
      }
    }
    var targetIdx = currentIndex.value + 1;
    if (targetIdx >= queue.value.length) {
      if (playbackMode.value == PlaybackMode.loop) {
        targetIdx = 0;
      } else {
        return; // 无可播下一首
      }
    }
    _activateSong(targetIdx);
    _emitSnapshot(force: true);
    final song = currentSong.value;
    if (song != null) {
      await DlnaCastService.instance.loadSong(song);
    }
  }

  /// 投屏播放接近末尾时提前预填随机/漫游队列（避免播完后才发请求导致间隙）。
  ///
  /// 投屏时本机引擎暂停，currentIndexStream 不会触发预填；这里在位置轮询
  /// 里当剩余时间 < 30s 且队列快到队尾时，提前追加下一首（与本地播放的
  /// _maybePrefetchByRemaining 提前量一致）。
  bool _castPrefetchInFlight = false;

  void _maybePrefetchCastQueue() {
    if (playbackMode.value != PlaybackMode.shuffle) return;
    if (_castPrefetchInFlight) return;
    final list = queue.value;
    final idx = currentIndex.value;
    if (list.isEmpty || idx < 0) return;
    // 剩余 < 30s 或已在最后一首 → 预填
    final durationSec = duration.value?.inSeconds ?? 0;
    final positionSec = position.value.inSeconds;
    final nearEnd =
        (durationSec > 0 && positionSec >= durationSec - 30) ||
        idx >= list.length - 1;
    if (!nearEnd) return;
    // 队尾已有下一首则无需预填（只要不是最后一首就有 next）
    if (idx < list.length - 1) return;

    _castPrefetchInFlight = true;
    unawaited(() async {
      try {
        if (roamActive) {
          await _extendRoamQueue();
        } else {
          await _autoExtendQueue();
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('PlayerService cast prefetch failed: $e');
        }
      } finally {
        _castPrefetchInFlight = false;
      }
    }());
  }

  /// 漫游队列扩展：请求 roam-next 把下一首追加到队尾（每次只追加一首）。
  /// 供切到队尾（_indexSub / next / 播完 completed）时调用，保证队列实时增长。
  ///
  /// 重启后持久化的 roamId 可能在服务端已过期（roam-next 抛异常），此时
  /// 回退到 roam-start 重建新链再追加，避免「队列不增长 → 播完回卷 → 列表循环」。
  Future<void> _extendRoamQueue() async {
    // 追加已在途：返回同一个 Future，调用方可 await 它等待本次追加完成。
    final inflight = _roamAppendInFlight;
    if (inflight != null) return inflight;
    if (_roamAppendQueuedCount > 0) return;
    final gen = _queueGeneration;
    _roamAppendQueuedCount = 1;
    final future = _doExtendRoamQueue(gen);
    _roamAppendInFlight = future;
    try {
      await future;
    } finally {
      _roamAppendInFlight = null;
    }
  }

  Future<void> _doExtendRoamQueue(int gen) async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();

      // 尝试用当前链推进；失败（roamId 过期）则重建新链
      FeiNiuRoamNextResponse? response;
      if (roamId != null && roamId!.isNotEmpty) {
        try {
          response = await FeiNiuApiClient.instance.getRoamNext(
            deviceId,
            roamId!,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('PlayerService extendRoamQueue roam-next expired: $e');
          }
          response = null;
        }
      } else {
        response = null;
      }

      // roamId 为空或 roam-next 失败 → roam-start 重建新链
      final String newRoamId;
      final SongEntity? appendedTrack;
      if (response == null ||
          response.next == null ||
          response.current == null) {
        final startResponse = await FeiNiuApiClient.instance.getRoamStart(
          deviceId,
        );
        newRoamId = startResponse.current.roamId;
        appendedTrack = startResponse.next != null
            ? FeiNiuTrackService.instance.trackToSongEntity(
                startResponse.next!.track.toJson(),
              )
            : null;
      } else {
        // 推进 roamId：roam-next 返回 previous/current/next。下一次请求应基于
        // current 的 roamId（用户实测：用 relativeRoamId=current.roamId 才拿到
        // 正确的再下一首），若用 next.roamId 会跳过歌曲。
        newRoamId = response.current!.roamId;
        appendedTrack = response.next != null
            ? FeiNiuTrackService.instance.trackToSongEntity(
                response.next!.track.toJson(),
              )
            : null;
      }

      roamId = newRoamId;
      // 队列已被替换，丢弃本次追加
      if (gen != _queueGeneration) return;

      final nextTrack = appendedTrack;
      if (nextTrack == null) return;
      final baseQueue = queue.value;
      final alreadyInQueue = baseQueue.any((s) => s.id == nextTrack.id);
      if (alreadyInQueue) return;
      final allSongs = [...baseQueue, nextTrack];

      // 引擎感知的追加：先更新逻辑队列与引擎路由；若追加的歌曲与当前 run
      // 同引擎，增量插入当前引擎（避免整段重建），否则只更新逻辑状态——
      // 真正播到边界时由逻辑层切换引擎加载。
      final nextTranscodes =
          !_forceDirectSongIds.contains(nextTrack.id) &&
          !_transcodeFailedSongIds.contains(nextTrack.id) &&
          await FeiNiuTranscodeService.instance.shouldTranscode(nextTrack);
      final appendedKind = nextTranscodes
          ? EngineKind.justAudio
          : await routeForSong(nextTrack);
      final curKind =
          currentIndex.value >= 0 && currentIndex.value < _engineKinds.length
          ? _engineKinds[currentIndex.value]
          : EngineKind.justAudio;
      queue.value = allSongs;
      if (_engineKinds.length != baseQueue.length) {
        _applyEngineKinds(await _computeEngineKinds(baseQueue));
      }
      _engineKinds = [..._engineKinds, appendedKind];
      _engineTranscodeFlags = [..._engineTranscodeFlags, nextTranscodes];

      // 转码歌不入当前 run 的物理增量插入：它是独立单例 run，播放到它时由
      // _activateLogicalIndex 重新激活加载（单首转码）。
      if (!nextTranscodes &&
          identical(_activeEngine.kind, curKind) &&
          appendedKind == curKind) {
        try {
          final item = await _resolveEngineItem(nextTrack, appendedKind);
          await _activeEngine.insertItem(_activeEngine.sequenceLength, item);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('PlayerService extendRoamQueue insertItem failed: $e');
          }
          // 插入失败回退：仅保留逻辑队列（物理边界切换时重建）
        }
      }
      queue.value = allSongs;
      // 追加后超长按上限截断（保留当前歌曲，裁掉最旧的前部）。
      // 裁剪会把当前歌曲重映射到新索引（裁掉前部后落到 0/靠前位置），
      // 必须同步 currentIndex/currentSong，否则索引与实际歌曲逐次错位，
      // 持久化的播放位置/歌名在重启后恢复错乱。
      final curIdx = currentIndex.value;
      final capped = _capQueue(allSongs, curIdx);
      if (capped != null) {
        queue.value = capped.$1;
        if (capped.$2 != curIdx) {
          _activateSong(capped.$2);
        }
      }
      // 后台预加载下一曲文件：漫游模式下队列即真源，下一首已确定，
      // 提前把文件缓存好，切歌时无缝衔接。
      if (AppCacheSettings.precacheNextSong.value &&
          StreamCacheService.instance.isEnabled) {
        StreamCacheService.instance.precacheSong(nextTrack);
      }
      _debugLog(
        'extendRoamQueue: appended=${nextTrack.id} queue=[${queue.value.map((s) => s.id).join(',')}]',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService extendRoamQueue error: $e');
      }
    } finally {
      _roamAppendQueuedCount--;
    }
  }

  /// 播完兜底：当前曲目播完且队列无可播下一首时，追加一首再继续。
  /// 待启动漫游：当前播放列表被切换为随机模式后，当前曲目播完/切到队尾时
  /// 调用。用 roam-start 拉取新漫游链替换当前队列并继续播放，实现
  /// 「列表循环 → 随机」的平滑过渡（播完当前歌后开始漫游）。
  Future<void> _startRoamFromPending() async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await FeiNiuApiClient.instance.getRoamStart(deviceId);

      final songs = <SongEntity>[
        FeiNiuTrackService.instance.trackToSongEntity(
          response.current.track.toJson(),
        ),
      ];
      if (response.next != null) {
        songs.add(
          FeiNiuTrackService.instance.trackToSongEntity(
            response.next!.track.toJson(),
          ),
        );
      }
      // 用漫游新队列替换当前列表循环队列，保持随机模式与 roamId。
      // playQueue 会设 shuffle 模式、恢复 roamId，播完自动 roam-next 续接。
      await playQueue(
        songs,
        0,
        mode: PlaybackMode.shuffle,
        roamChainId: response.current.roamId,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService startRoamFromPending error: $e');
      }
    }
  }

  Future<void> previous() async {
    if (isCasting.value) {
      // 投屏遥控模式：先在逻辑队列后退到上一首，再把新歌推送到投屏设备。
      final list = queue.value;
      final idx = currentIndex.value;
      if (list.isEmpty || idx < 0) return;
      final targetIdx = idx == 0
          ? (playbackMode.value == PlaybackMode.loop ? list.length - 1 : 0)
          : idx - 1;
      _activateSong(targetIdx);
      _emitSnapshot(force: true);
      final song = currentSong.value;
      if (song != null) {
        await DlnaCastService.instance.loadSong(song);
      }
      return;
    }
    _clearRestoreSession();
    final list = queue.value;
    final idx = currentIndex.value;
    if (list.isEmpty || idx < 0) return;
    if (idx == 0) {
      // 逻辑队首：loop 回卷到队尾（可能跨引擎）；否则重播当前曲。
      if (playbackMode.value == PlaybackMode.loop) {
        await _activateLogicalIndex(list.length - 1);
        try {
          await _activeEngine.play();
        } catch (_) {}
      } else {
        await _activeEngine.seek(Duration.zero);
      }
      return;
    }
    final wasPlaying = _activeEngine.playing;
    final prev = idx - 1;
    // 同 run 判定用 _runBounds 覆盖范围（转码歌是单例 run，prev 虽同引擎但
    // 不在当前 run 时必须走重新激活，不能 seekToPrevious 跨到别首转码歌）。
    final bounds = _runBounds(idx);
    final sameRun = prev >= bounds.start && prev <= bounds.end;
    if (sameRun) {
      await _activeEngine.seekToPrevious();
    } else {
      await _activateLogicalIndex(prev);
      if (wasPlaying) {
        try {
          await _activeEngine.play();
        } catch (_) {}
      }
    }
  }

  Future<void> seek(Duration position) async {
    if (isCasting.value) {
      // 投屏遥控模式：转发 seek 到投屏设备，并同步本地 UI 位置
      await DlnaCastService.instance.seek(position);
      this.position.value = position;
      _emitSnapshot(force: true);
      return;
    }
    _clearRestoreSession();
    _seekSeq++;
    final currentSeq = _seekSeq;
    _isSeeking = true;
    _seekTarget = position;
    this.position.value = position;
    _emitSnapshot(force: true);
    try {
      await _activeEngine.seek(position);
      // Bounded settle: returns as soon as the position listener observes a
      // near-target position (usually well under 100ms), capped at 600ms so a
      // misbehaving backend can't freeze the bar indefinitely.
      final start = DateTime.now();
      while (currentSeq == _seekSeq &&
          _isSeeking &&
          DateTime.now().difference(start).inMilliseconds < 600) {
        await Future.delayed(const Duration(milliseconds: 32));
      }
    } finally {
      if (currentSeq == _seekSeq) {
        _isSeeking = false;
        _seekTarget = null;
        // Force one last update from the player to ensure sync
        _syncPositionFromPlayer();
        _emitSnapshot(force: true);
        await _persistPlaybackStateNow();
      }
    }
  }

  Future<void> skipToIndex(int index) async {
    if (isCasting.value) {
      // 投屏遥控模式：点队列歌曲 = 逻辑切歌 + 推送到投屏设备。
      final list = queue.value;
      if (index < 0 || index >= list.length) return;
      _activateSong(index);
      _emitSnapshot(force: true);
      final song = currentSong.value;
      if (song != null) {
        await DlnaCastService.instance.loadSong(song);
      }
      return;
    }
    _clearRestoreSession();
    final list = queue.value;
    if (index < 0 || index >= list.length) return;
    if (index >= _engineKinds.length) {
      _applyEngineKinds(await _computeEngineKinds(list));
    }
    // 同 run → 引擎内索引；跨 run → 激活新 run（转码歌为单例 run，
    // 命中 _runBounds 仅当恰好是当前正在播的这首，否则走激活）。
    final bounds = _runBounds(index);
    final cur = currentIndex.value;
    final sameRun = cur >= 0 && cur >= bounds.start && cur <= bounds.end;
    if (sameRun &&
        index >= _activeRunStart &&
        index < _activeRunStart + _activeEngine.sequenceLength) {
      await _activeEngine.skipToIndex(index - _activeRunStart);
    } else {
      await _activateLogicalIndex(index);
      try {
        await _activeEngine.play();
      } catch (_) {}
    }
  }

  Future<void> playNext(SongEntity song) async {
    final uri = (song.uri ?? '').trim();
    if (uri.isEmpty) return;

    final oldQueue = queue.value;
    final idx = currentIndex.value;
    final current = currentSong.value;
    if (oldQueue.isEmpty || current == null || idx < 0) {
      await playQueue([song], 0);
      return;
    }

    final insertAt = (idx + 1).clamp(0, oldQueue.length);
    var nextQueue = List<SongEntity>.from(oldQueue);
    nextQueue.insert(insertAt, song);

    // 队列长度上限：插入后超长则裁掉尾部，走全量重建（原地 insertAudioSource
    // 无法同步裁剪已被裁掉的尾部源）
    final capped = _capQueue(nextQueue, idx);
    if (capped != null) {
      nextQueue = capped.$1;
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _reloadQueue(
        nextQueue,
        idx,
        play: wasPlaying,
        initialPosition: pos,
      );
      return;
    }

    // 插入的歌曲可能路由到另一引擎：更新逻辑队列 + 引擎路由，
    // 重建当前 run 即可（同 run 内增量插入由 loadQueue 处理）。
    _applyLogicalQueue(nextQueue, idx);
    _applyEngineKinds(await _computeEngineKinds(nextQueue));
    try {
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _activateLogicalIndex(idx, initialPosition: pos);
      if (wasPlaying && !_activeEngine.playing) {
        await _activeEngine.play();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService.playNext activate failed: $e');
      }
      // 重建失败（罕见）回退全量 _reloadQueue，保证队列一致
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _reloadQueue(
        nextQueue,
        idx,
        play: wasPlaying,
        initialPosition: pos,
      );
      return;
    }
  }

  Future<void> insertNext(List<SongEntity> songs) async {
    final toInsert = songs
        .where((s) => (s.uri ?? '').trim().isNotEmpty)
        .toList();
    if (toInsert.isEmpty) return;

    final oldQueue = queue.value;
    final idx = currentIndex.value;
    final current = currentSong.value;
    if (oldQueue.isEmpty || current == null || idx < 0) {
      await playQueue(toInsert, 0);
      return;
    }

    final insertAt = (idx + 1).clamp(0, oldQueue.length);
    var nextQueue = List<SongEntity>.from(oldQueue);
    nextQueue.insertAll(insertAt, toInsert);

    // 队列长度上限：插入后超长则裁掉尾部，走全量重建
    final capped = _capQueue(nextQueue, idx);
    if (capped != null) {
      nextQueue = capped.$1;
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _reloadQueue(
        nextQueue,
        idx,
        play: wasPlaying,
        initialPosition: pos,
      );
      return;
    }

    // 插入的歌曲可能路由到另一引擎：更新逻辑队列 + 引擎路由，
    // 重建当前 run 即可。
    _applyLogicalQueue(nextQueue, idx);
    _applyEngineKinds(await _computeEngineKinds(nextQueue));
    try {
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _activateLogicalIndex(idx, initialPosition: pos);
      if (wasPlaying && !_activeEngine.playing) {
        await _activeEngine.play();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService.insertNext activate failed: $e');
      }
      // 重建失败（罕见）回退全量 _reloadQueue，保证队列一致
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _reloadQueue(
        nextQueue,
        idx,
        play: wasPlaying,
        initialPosition: pos,
      );
      return;
    }
  }

  /// 漫游随机播放：roam-start 获取随机曲目 → playQueue 播放 → 切换随机模式
  Future<void> startRoamPlayback() async {
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await FeiNiuApiClient.instance.getRoamStart(deviceId);

      final songs = <SongEntity>[
        FeiNiuTrackService.instance.trackToSongEntity(
          response.current.track.toJson(),
        ),
      ];
      if (response.next != null) {
        songs.add(
          FeiNiuTrackService.instance.trackToSongEntity(
            response.next!.track.toJson(),
          ),
        );
      }

      await playQueue(
        songs,
        0,
        mode: PlaybackMode.shuffle,
        roamChainId: response.current.roamId,
      );
      // playQueue 已按传入 mode 设置随机模式、恢复 roamId；漫游模式靠
      // _extendRoamQueue（roamId 非空时路由到 roam-next）在队尾自动追加下一首。
    } catch (e) {
      _debugLog('startRoamPlayback error: $e');
    }
  }

  /// 本地随机播放：把整个列表本地乱序后作为播放队列播放，
  /// 播到末尾时自动把原列表重新乱序续接，不依赖服务器漫游。
  Future<void> playShuffle(List<SongEntity> songs) async {
    final base = songs.where((s) => (s.uri ?? '').trim().isNotEmpty).toList();
    if (base.isEmpty) return;
    final playable = [...base]..shuffle(Random());
    await playQueue(playable, 0);
    // 本地乱序队列直接进入随机模式（run 不自动回卷，播完逻辑层续接）
    try {
      await _applyPlaybackMode(PlaybackMode.shuffle);
      playbackMode.value = PlaybackMode.shuffle;
      _schedulePersistPlaybackState();
    } catch (e) {
      if (kDebugMode) debugPrint('playShuffle applyPlaybackMode error: $e');
    }
    // 播完末尾自动把原列表重新乱序续接
    queueExtender = () async => ([...base]..shuffle(Random()));
  }

  Future<void> cyclePlaybackMode() async {
    final current = playbackMode.value;
    final next = switch (current) {
      PlaybackMode.shuffle => PlaybackMode.loop,
      PlaybackMode.loop => PlaybackMode.single,
      PlaybackMode.single => PlaybackMode.shuffle,
    };

    await setPlaybackMode(next);
  }

  Future<void> setPlaybackMode(PlaybackMode mode) async {
    await _initFuture;
    // 先写状态再同步播放器：playbackMode 是唯一真源，
    // 播放器异步调用即使挂起/失败也不影响 UI 状态与漫游逻辑。
    playbackMode.value = mode;
    _debugLog('setPlaybackMode -> ${mode.name}');
    _schedulePersistPlaybackState();
    try {
      if (mode == PlaybackMode.shuffle) {
        // 进入随机模式：run 不自动回卷，播完由逻辑层 roam 补链。
        // 若当前队列不是漫游队列（roamId 为空），标记「当前曲播完后启动漫游」，
        // 让播完/切到队尾时走 roam-start 而非继续顺序播原列表。
        _roamStartPending = roamId == null || roamId!.isEmpty;
        await _applyPlaybackMode(mode);
      } else {
        _roamStartPending = false;
        await _applyPlaybackMode(mode);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('setPlaybackMode(${mode.name}) error: $e');
    }
  }

  /// 设置播放速度倍率。值先持久化（吸附到档位），再应用到当前引擎；
  /// 引擎异步失败不影响 UI 状态。
  Future<void> setSpeed(double speed) async {
    await _initFuture;
    AppPlaybackSpeedSettings.setSpeed(speed);
    _debugLog('setSpeed -> $speed');
    await _applyEngineSpeed(_activeEngine);
  }

  /// 手动切换当前歌曲的解码引擎（系统解码 just_audio / FFmpeg media_kit），
  /// 并立即用新引擎重载当前曲（保持播放/暂停状态与进度）。
  ///
  /// 覆盖写进 [_forcedEngineKinds]，仅当前歌曲命中、优先于默认路由；
  /// **不参与**现有自动升级（_mediaKitEscalateSongIds）与无声看门狗逻辑，
  /// 切歌后新歌曲不命中即自动失效。
  Future<void> setDecoderEngine(EngineKind kind) async {
    final song = currentSong.value;
    final idx = currentIndex.value;
    if (song == null || idx < 0) return;
    if (kind == _activeEngine.kind) return; // 已是目标引擎，无操作
    final seekPos = position.value;
    final wasPlaying = isPlaying.value;
    _debugLog('setDecoderEngine ${song.title} -> ${kind.name}');
    _forcedEngineKinds[song.id] = kind;
    // 清除转码/格式缓存，让新引擎按原始格式重新解析（media_kit 直连原始流）。
    FeiNiuTranscodeService.instance.invalidate(song.id);
    _applyEngineKinds(await _computeEngineKinds(queue.value));
    await _activateLogicalIndex(
      idx,
      initialPosition: seekPos > Duration.zero ? seekPos : null,
    );
    if (wasPlaying) await _startPlayback();
  }

  /// 切换转码格式（歌曲信息面板转码 tag 点击）：本歌**强制**按该格式转码，
  /// **不依赖全局「开启转码」开关**——直接请求转码地址播放；传 null 清除
  /// 强制，恢复按全局设置判定。仅当前歌曲有效（会话级，按 songId 命中）。
  ///
  /// 与 [setTranscodeDirect] 互斥：选转码格式即取消该歌的直连覆盖。
  Future<void> setTranscodeOverride(TranscodeFormat? format) async {
    final song = currentSong.value;
    final idx = currentIndex.value;
    if (song == null || idx < 0) return;
    final svc = FeiNiuTranscodeService.instance;
    _debugLog('setTranscodeOverride ${song.title} -> ${format?.name ?? 'global'}');
    svc.setForcedTranscodeCodec(song.id, format?.name);
    // 强制转码与强制直连互斥：选了转码格式就取消该歌的直连覆盖。
    _forceDirectSongIds.remove(song.id);
    // 清除该歌的转码缓存/降级标记/失败标记，允许按新格式重新转码。
    svc.invalidate(song.id);
    svc.clearDowngradeFor(song.id);
    _transcodeFailedSongIds.remove(song.id);
    final seekPos = position.value;
    final wasPlaying = isPlaying.value;
    _applyEngineKinds(await _computeEngineKinds(queue.value));
    await _activateLogicalIndex(
      idx,
      initialPosition: seekPos > Duration.zero ? seekPos : null,
    );
    if (wasPlaying) await _startPlayback();
  }

  /// 歌曲面板转码格式选「直连」：该歌本会话强制直连原始流（不转码），
  /// 回到默认引擎路由（FLAC→just_audio，DSF→media_kit）。同时清除该歌的
  /// 强制转码覆盖（与 [setTranscodeOverride] 互斥）。
  Future<void> setTranscodeDirect() async {
    final song = currentSong.value;
    final idx = currentIndex.value;
    if (song == null || idx < 0) return;
    _debugLog('setTranscodeDirect ${song.title}');
    _forceDirectSongIds.add(song.id);
    FeiNiuTranscodeService.instance.setForcedTranscodeCodec(song.id, null);
    FeiNiuTranscodeService.instance.invalidate(song.id);
    FeiNiuTranscodeService.instance.clearDowngradeFor(song.id);
    _transcodeFailedSongIds.remove(song.id);
    final seekPos = position.value;
    final wasPlaying = isPlaying.value;
    _applyEngineKinds(await _computeEngineKinds(queue.value));
    await _activateLogicalIndex(
      idx,
      initialPosition: seekPos > Duration.zero ? seekPos : null,
    );
    if (wasPlaying) await _startPlayback();
  }

  bool get isSleepTimerActive => _sleepTimer != null;

  Duration? get sleepRemaining {
    final end = _sleepEndAt;
    if (end == null) return null;
    return end.difference(DateTime.now());
  }

  void setSleepTimer(Duration duration) {
    _scheduleSleepTimer(duration, untilSongEnd: false);
  }

  void setSleepTimerToSongEnd() {
    final d = duration.value;
    if (d == null || d <= Duration.zero) {
      cancelSleepTimer();
      return;
    }
    final remaining = d - position.value;
    if (remaining <= Duration.zero) {
      cancelSleepTimer();
      _activeEngine.pause();
      return;
    }
    _scheduleSleepTimer(remaining, untilSongEnd: true);
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepEndAt = null;
    sleepUntilSongEnd.value = false;
    sleepTimerDisplayText.value = null;
  }

  void _scheduleSleepTimer(Duration duration, {required bool untilSongEnd}) {
    cancelSleepTimer();
    sleepUntilSongEnd.value = untilSongEnd;
    _sleepEndAt = DateTime.now().add(duration);
    _updateSleepTimerText();
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final end = _sleepEndAt;
      if (end == null) return;
      final remaining = end.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        cancelSleepTimer();
        await _pausePlayback();
        return;
      }
      _updateSleepTimerText();
    });
  }

  void _updateSleepTimerText() {
    final end = _sleepEndAt;
    if (end == null) {
      sleepTimerDisplayText.value = null;
      return;
    }
    final remaining = end.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      sleepTimerDisplayText.value = null;
      return;
    }
    final totalMinutes = remaining.inMinutes;
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    sleepTimerDisplayText.value =
        '$hours:${minutes.toString().padLeft(2, '0')}';
  }

  Future<void> clearQueue() async {
    // 漫游模式队列由服务端随机链驱动，不允许手动清空。
    if (roamActive) return;
    await stopAndClear();
  }

  Future<void> removeFromQueue(int index) async {
    // 漫游模式队列由服务端随机链驱动，不允许手动删除歌曲。
    if (roamActive) return;
    final list = queue.value;
    if (index < 0 || index >= list.length) return;
    await removeSongsById([list[index].id]);
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final oldQueue = List<SongEntity>.from(queue.value);
    if (oldQueue.isEmpty) return;
    if (oldIndex < 0 || oldIndex >= oldQueue.length) return;
    // newIndex 为移除 oldIndex 元素后的目标下标（0..oldQueue.length），
    // 由调用方（ReorderableListView.onReorderItem）负责调整。
    if (newIndex < 0 || newIndex > oldQueue.length) return;
    final targetIndex = newIndex;
    if (targetIndex == oldIndex) return;

    final item = oldQueue.removeAt(oldIndex);
    oldQueue.insert(targetIndex, item);

    // 就地移动音频源（同 run 内），避免重建整个播放管线（避免当前播放卡顿）。
    // 先同步逻辑队列，让 _indexSub 在 currentIndexStream 变化时能取到最新顺序。
    queue.value = oldQueue;
    _applyEngineKinds(await _computeEngineKinds(oldQueue));
    _emitSnapshot(force: true);
    // 移动跨引擎边界时无法就地移动（引擎物理队列不同源），走全量重建。
    final crossesEngine =
        oldIndex < _engineKinds.length &&
        targetIndex < _engineKinds.length &&
        _engineKinds[oldIndex] != _engineKinds[targetIndex];
    if (crossesEngine) {
      final current = currentSong.value;
      final currentId = current?.id;
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      var startIndex = 0;
      if (currentId != null) {
        final idx = oldQueue.indexWhere((s) => s.id == currentId);
        if (idx >= 0) startIndex = idx;
      }
      await _reloadQueue(
        oldQueue,
        startIndex,
        play: wasPlaying,
        initialPosition: pos,
      );
      return;
    }
    try {
      await _activeEngine.moveItem(oldIndex, targetIndex);
    } catch (e) {
      // 移动失败（罕见）：回退为全量重建以恢复逻辑队列与实际源一致。
      if (kDebugMode) debugPrint('PlayerService reorderQueue move failed: $e');
      final current = currentSong.value;
      final currentId = current?.id;
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      var startIndex = 0;
      if (currentId != null) {
        final idx = oldQueue.indexWhere((s) => s.id == currentId);
        if (idx >= 0) startIndex = idx;
      }
      await _reloadQueue(
        oldQueue,
        startIndex,
        play: wasPlaying,
        initialPosition: pos,
      );
    }
  }

  void _emitSnapshot({bool force = false}) {
    if (force) {
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      _applySnapshot();
      return;
    }

    final now = DateTime.now();
    final last = _lastSnapshotEmit;

    // If enough time has passed, emit immediately
    if (last == null ||
        now.difference(last) >= const Duration(milliseconds: 250)) {
      _snapshotTimer?.cancel();
      _snapshotTimer = null;
      _applySnapshot();
      return;
    }

    // If a timer is already scheduled, do nothing (it will fire at the correct time)
    if (_snapshotTimer != null && _snapshotTimer!.isActive) {
      return;
    }

    final delay = const Duration(milliseconds: 250) - now.difference(last);
    _snapshotTimer = Timer(delay, _applySnapshot);
  }

  void _applySnapshot() {
    _lastSnapshotEmit = DateTime.now();
    final nextSnapshot = PlaybackSnapshot(
      song: currentSong.value,
      queue: queue.value,
      index: currentIndex.value,
      isPlaying: isPlaying.value,
      isLoading: isLoading.value,
      position: position.value,
      duration: duration.value,
      bufferedPosition: bufferedPosition.value,
    );
    snapshot.value = nextSnapshot;
    _statsService.onSnapshot(nextSnapshot);
    _recorder.onSnapshot(nextSnapshot);
    _schedulePersistPlaybackState();
    // 定期刷写统计到数据库（每 15s），确保 app 被杀时数据不丢
    _statsFlushTimer?.cancel();
    _statsFlushTimer = Timer(const Duration(seconds: 15), () {
      _statsService.flush();
    });
  }

  Future<void> _restorePlaybackState() async {
    final session = await _readPersistedPlaybackState();
    if (session == null) return;
    // 读取持久化状态期间用户可能已开始新的播放（playQueue 递增 _queueGeneration），
    // 放弃恢复，避免用旧队列覆盖用户刚选的队列与播放模式。
    if (_queueGeneration != 0) return;
    _debugLog('restorePlaybackState queue=${session.queue.length}');

    final shouldAutoPlayOnLaunch =
        AppLaunchPlaybackSettings.shouldAutoPlayOnAppLaunch();
    _restorePlaybackUiState(session);
    _restorePrepareFuture = _prepareRestoredAudioSource(session);
    await _restorePrepareFuture;

    if (shouldAutoPlayOnLaunch) {
      try {
        _debugLog('restorePlaybackState autoPlay');
        // 自动播放的兜底：_startPlayback 内部已用 playbackStateStream 确认
        // 播放开始（不再死等 play() 的 Future），此处再留一层总超时，确保
        // 极端情况下 _init 也能完成（否则 _initFuture 永不完成 → 所有
        // playQueue 卡死，点击歌曲无响应）。超时放行，不强停引擎——引擎
        // 可能正在正常播放，只是状态确认因网络慢而未及时到达。
        await _startPlayback().timeout(const Duration(seconds: 8));
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Auto play on app launch failed: $e');
        }
        // 仅在引擎确实没在播时清理：避免误杀正在正常播放的音频。
        if (!_activeEngine.playing && !isPlaying.value) {
          _clearRestoreSession();
          try {
            await _activeEngine.stop();
          } catch (_) {}
        }
      }
    }

    // 不自动播放：恢复完成但引擎停在「已加载未播放」，此时若引擎未发 ready
    // 事件（源列表大或含不可解析源），isLoading 可能一直为 true，UI 停在转圈。
    // 恢复完成后显式清一次，让 UI 回到「已暂停」而非「加载中」。
    isLoading.value = false;
    _emitSnapshot(force: true);

    try {
      await _setAudioSessionActive(false);
    } catch (_) {}
    _statsService.flush();
  }

  Future<_PlaybackRestoreState?> _readPersistedPlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsQueueKey);
    if (raw == null || raw.trim().isEmpty) return null;

    List<SongEntity> restoredQueue = [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        restoredQueue = decoded
            .whereType<Map>()
            .map((e) => SongEntity.fromMap(e.cast<String, dynamic>()))
            .where((s) => (s.uri ?? '').trim().isNotEmpty)
            .toList();
      }
    } catch (_) {
      return null;
    }
    if (restoredQueue.isEmpty) return null;

    final savedIndex = prefs.getInt(_prefsIndexKey) ?? 0;
    final savedPositionMs = prefs.getInt(_prefsPositionKey) ?? 0;
    final savedMode = prefs.getString(_prefsModeKey);
    final savedSongId = prefs.getString(_prefsSongIdKey);
    final savedRoamId = prefs.getString(_prefsRoamIdKey);
    final mode = _playbackModeFromString(savedMode) ?? PlaybackMode.loop;
    var actualIndex = savedIndex;
    if (savedSongId != null && savedSongId.isNotEmpty) {
      final idx = restoredQueue.indexWhere((s) => s.id == savedSongId);
      if (idx >= 0) actualIndex = idx;
    }
    if (actualIndex < 0) actualIndex = 0;
    if (actualIndex >= restoredQueue.length) {
      actualIndex = restoredQueue.length - 1;
    }
    final songId = restoredQueue[actualIndex].id;
    return _PlaybackRestoreState(
      queue: restoredQueue,
      index: actualIndex,
      songId: songId,
      position: Duration(
        milliseconds: savedPositionMs < 0 ? 0 : savedPositionMs,
      ),
      mode: mode,
      wasPlaying: prefs.getBool(_prefsWasPlayingKey) ?? false,
      roamId: savedRoamId,
    );
  }

  void _restorePlaybackUiState(_PlaybackRestoreState session) {
    _restoreSession = session;
    // 恢复漫游链：随机模式重启后下一曲仍沿用同一个随机队列，而不是重新 roam-start
    roamId = session.roamId;
    _applyLogicalQueue(session.queue, session.index);
    playbackMode.value = session.mode;
    _debugLog('restoreUiState -> mode=${session.mode.name}');
    position.value = session.position;
    bufferedPosition.value = Duration.zero;
    final song = session.currentSong;
    duration.value = song.durationMs != null
        ? Duration(milliseconds: song.durationMs!)
        : null;
    isPlaying.value = false;
    _emitSnapshot(force: true);
    // 预热当前曲 800px 封面：恢复播放进播放页时封面立显，不闪转圈。
    // 磁盘已有缓存 → 秒显；无缓存 → 提前下载（与 _prefetchUpcoming 同路径）。
    if (song.coverId != null && song.coverId!.isNotEmpty) {
      // 恢复流程在 _init（构造后立即触发）的同步段执行，此时根元素可能尚未
      // 挂载（rootElement 为 null）。封面预热尽力而为：挂载后才调用，
      // 否则跳过——封面会在播放页构建时正常加载。
      final root = WidgetsBinding.instance.rootElement;
      if (root != null) {
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(
              FeiNiuApiClient.instance.coverUrl(
                song.coverId!,
                size: FeiNiuApiClient.coverRequestSize,
                updatedAt: song.updatedAt,
              ),
              headers: FeiNiuApiClient.imageAuthHeaders(),
            ),
            root,
          ),
        );
      }
    }
  }

  Future<void> _prepareRestoredAudioSource(
    _PlaybackRestoreState session,
  ) async {
    try {
      // 双引擎架构：按 run 加载恢复的当前曲所在引擎。
      _applyEngineKinds(await _computeEngineKinds(session.queue));
      // 构建源期间用户可能已开始新的播放：放弃 apply，避免 setAudioSources
      // 覆盖用户刚选的队列。
      if (_queueGeneration != 0) {
        session.prepareFailed = true;
        return;
      }
      await _activateLogicalIndex(
        session.index,
        initialPosition: session.position,
      );
      if (session.position > Duration.zero) {
        await _seekRestoredPosition(session.position);
      }
      // 加载源期间用户可能已点漫游开始播放（_queueGeneration 已递增）：
      // 放弃把旧会话的循环模式应用到播放器，避免覆盖漫游设好的模式。
      if (_queueGeneration != 0) {
        session.prepareFailed = true;
        return;
      }
      await _applyPlaybackMode(session.mode);
      session
        ..sourcePrepared = true
        ..seekApplied = true;
      position.value = session.position;
      // 漫游/随机模式：若恢复的当前曲目已在队尾（index 到末尾），播完会
      // 停住（run 不自动回卷）。这里提前补一首，保证恢复后队列实时增长。
      if (session.mode == PlaybackMode.shuffle &&
          roamId != null &&
          roamId!.isNotEmpty) {
        final restoredList = session.queue;
        final restoredIndex = session.index;
        if (restoredIndex >= restoredList.length - 1) {
          unawaited(_extendRoamQueue());
        }
      }
      _emitSnapshot(force: true);
    } catch (e) {
      if (kDebugMode) debugPrint('Error restoring playback state: $e');
      session.prepareFailed = true;
    }
  }

  /// 发起播放并确认「已真正开始播」。
  ///
  /// 不能死等 `engine.play()` 的 Future：just_audio 在 `preload:false` 的
  /// 平台激活路径下，即使音频已正常播出（ExoPlayer 解码 + AudioTrack 输出），
  /// `play()` 的 playCompleter 也可能永不完成（已知竞态）。死等会卡死调用方
  /// （曾导致 `_initFuture` 永不完成、点击歌曲全部无响应）。
  ///
  /// 正确做法：`play()` 启动时引擎会乐观广播 `playing=true`，监听引擎的
  /// `playbackStateStream` 等首个 playing=true 即可可靠确认播放开始——
  /// 不依赖 play() 的 Future，也不会挂起。对 play() 本身只做短超时等待，
  /// 超时不视为失败（音频由状态流确认在播）。
  Future<void> _startPlayback() async {
    _debugLog('startPlayback song=${currentSong.value?.title ?? 'none'}');
    final active = await _setAudioSessionActive(true);
    if (!active) {
      throw Exception('Failed to activate audio session');
    }
    final engine = _activeEngine;
    // 状态确认在 play() 之前订阅：just_audio 在 play() 开头就乐观广播
    // playing=true，先订阅才不会漏掉该事件。
    final stateConfirmed = engine.playing
        ? Future<void>.value()
        : engine.playbackStateStream
              .firstWhere((s) => s.playing)
              .timeout(const Duration(seconds: 5))
              .then((_) {}, onError: (_) {});
    try {
      // play() 的 Future 可能永不完成（平台激活竞态）：短超时等待，超时
      // 不视为失败——播放请求已发出，是否在播由 stateConfirmed 确认。
      await engine.play().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // 播放请求已发出，播放状态由 stateConfirmed 等待确认。
    } catch (e) {
      // play() 显式抛错（如源不可播）：仅当引擎确实没在播时才视为失败。
      if (!engine.playing && !isPlaying.value) rethrow;
      if (kDebugMode) {
        debugPrint('PlayerService startPlayback play request failed: $e');
      }
    }
    // 等待播放状态确认（正常路径在 play() 乐观广播后即完成，毫秒级；
    // 超时也只是放行，不阻塞、不产生副作用）。
    await stateConfirmed;
    _completeRestoreSessionIfReady();
    _startBackgroundAudioKeepAliveIfNeeded();
  }

  Future<void> _pausePlayback() async {
    _debugLog('pausePlayback song=${currentSong.value?.title ?? 'none'}');
    // 暂停不检测无声：取消看门狗，避免暂停态误触发升级。
    _silenceWatchTimer?.cancel();
    _silenceWatchTimer = null;
    _silenceWatchSongId = null;
    _stopBackgroundAudioKeepAlive();
    await _activeEngine.pause();
    _syncPositionFromPlayer(
      allowZeroOverride: !(_restoreSession?.protectPosition ?? false),
    );
    await _persistPlaybackStateNow();
    // 暂停时不释放音频 session，保留 ExoPlayer 缓冲区，
    // 这样再次 seek/play 时能秒播而无需重新缓冲。
    // await _setAudioSessionActive(false);
  }

  void _handleAudioInterruption(AudioInterruptionEvent event) {
    _debugLog(
      'audio interruption begin=${event.begin} type=${event.type.name}',
    );
    if (event.begin) {
      _audioInterrupted = true;
      _wasPlayingBeforeInterruption = isPlaying.value;
      return;
    }
    final shouldResume = _audioInterrupted && _wasPlayingBeforeInterruption;
    _audioInterrupted = false;
    _wasPlayingBeforeInterruption = false;
    if (shouldResume) {
      unawaited(_resumeAfterAudioInterruption());
    }
  }

  Future<void> _resumeAfterAudioInterruption() async {
    // 投屏遥控模式：本机引擎不在播，音频中断恢复不应让手机出声。
    if (isCasting.value) return;
    try {
      final active = await _setAudioSessionActive(true);
      if (!active) return;
      if (!_activeEngine.playing && currentSong.value != null) {
        await _activeEngine.play();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService interruption resume failed: $e');
      }
    }
  }

  void _startBackgroundAudioKeepAliveIfNeeded() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      _startBackgroundAudioKeepAlive();
    }
  }

  void _startBackgroundAudioKeepAlive() {
    if (_backgroundAudioKeepAliveTimer?.isActive ?? false) return;
    _backgroundAudioKeepAliveTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) {
        if (!isPlaying.value) {
          _stopBackgroundAudioKeepAlive();
          return;
        }
        unawaited(_setAudioSessionActive(true));
      },
    );
  }

  void _stopBackgroundAudioKeepAlive() {
    _backgroundAudioKeepAliveTimer?.cancel();
    _backgroundAudioKeepAliveTimer = null;
  }

  Future<void> _ensureAudiblePlayback() async {
    // 投屏遥控模式：本机引擎不在播（在投屏设备上），不恢复本机出声。
    if (isCasting.value) return;
    if (!isPlaying.value || currentSong.value == null) return;
    try {
      await _setAudioSessionActive(true);
      final processing = _activeEngine.processingState;
      if (processing == EngineProcessingState.idle) {
        final list = queue.value;
        final idx = currentIndex.value;
        if (list.isNotEmpty && idx >= 0 && idx < list.length) {
          final pos = position.value;
          await _activateLogicalIndex(idx, initialPosition: pos);
        }
      }
      if (!_activeEngine.playing) {
        await _activeEngine.play();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService ensure audible playback failed: $e');
      }
    }
  }

  Future<void> _seekRestoredPosition(Duration restored) async {
    _isSeeking = true;
    position.value = restored;
    _emitSnapshot(force: true);
    try {
      // 引擎未加载（idle，preload=false 的恢复场景）时跳过真实 seek：
      // just_audio 的 seek 会调 resetInitialSeekValues 清掉 setAudioSources
      // 保留的 _PluginLoadRequest.initialIndex/initialPosition——而 play 激活
      // 时正是靠它恢复正确索引+位置。idle 下 seek 只写 _IdleAudioPlayer 内部
      // 状态、不落真机，位置由 _activateLogicalIndex(initialPosition:) 已传入
      // _PluginLoadRequest，play 激活时由 load 的 initialPosition 应用。跳过
      // 它才能保证 play 不从第 1 首（种子 currentIndex=0）开始播。
      if (_activeEngine.processingState != EngineProcessingState.idle) {
        await _activeEngine.seek(restored);
      }
    } finally {
      _isSeeking = false;
      if (_activeEngine.position > Duration.zero) {
        position.value = _activeEngine.position;
      } else {
        position.value = restored;
      }
      _emitSnapshot(force: true);
    }
  }

  void _completeRestoreSessionIfReady() {
    final session = _restoreSession;
    if (session == null) return;
    if (!session.seekApplied) return;
    _restoreSession = null;
    _restorePrepareFuture = null;
  }

  void _clearRestoreSession() {
    _restoreSession = null;
    _restorePrepareFuture = null;
  }

  Future<bool> _setAudioSessionActive(bool active) async {
    final session = _audioSession ?? await AudioSession.instance;
    _audioSession = session;
    try {
      _debugLog('audioSession setActive($active)');
      return await session.setActive(active);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService audio session setActive($active) failed: $e');
      }
      return !active;
    }
  }

  /// 按「不与其他应用一起播放」开关构建并应用音频会话配置。
  ///
  /// 关闭（默认）：与其他应用一起播放——Android 用 `gainTransientMayDuck`
  /// 请求音频焦点（启动时压低其他应用音量而非暂停，不会独占），iOS 附加
  /// `mixWithOthers`。
  /// 开启：独占焦点 `gain`——启动播放会暂停其他应用的音频。
  /// 配置为全局默认值，just_audio 的 play()/media_kit 引擎都会沿用；
  /// 开启后切歌/续播仍保持独占（不重复调用 configure）。
  Future<void> _applyAudioSessionConfiguration() async {
    final session = _audioSession ?? await AudioSession.instance;
    _audioSession = session;
    final exclusive = AppPlaybackAudioFocusSettings.exclusiveFocus.value;
    final config = exclusive
        ? const AudioSessionConfiguration.music()
        : const AudioSessionConfiguration.music().copyWith(
            avAudioSessionCategoryOptions:
                AVAudioSessionCategoryOptions.mixWithOthers,
            androidAudioFocusGainType:
                AndroidAudioFocusGainType.gainTransientMayDuck,
          );
    try {
      await session.configure(config);
      _debugLog('audioSession configure exclusive=$exclusive');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService audio session configure failed: $e');
      }
    }
  }

  void _handleExclusiveFocusChanged() {
    // 配置为全局默认值，无需重取焦点：当前播放会沿用它，
    // 下次播放/切歌由各引擎用新配置请求焦点。
    unawaited(_applyAudioSessionConfiguration());
  }

  PlaybackMode? _playbackModeFromString(String? value) {
    switch (value) {
      case 'shuffle':
        return PlaybackMode.shuffle;
      case 'loop':
        return PlaybackMode.loop;
      case 'single':
        return PlaybackMode.single;
      default:
        return null;
    }
  }

  Future<void> _applyPlaybackMode(PlaybackMode mode) async {
    // 双引擎架构下 run 不自动回卷：loop 用 none（逻辑层驱动回卷），
    // single 用 single（引擎重复当前曲）。shuffle 也用 none（播完逻辑层补链）。
    final engineMode = mode == PlaybackMode.single
        ? EngineLoopMode.single
        : EngineLoopMode.none;
    await _activeEngine.setLoopMode(engineMode);
  }

  void _schedulePersistPlaybackState({bool immediate = false}) {
    if (_restoringState) return;

    if (immediate) {
      _persistTimer?.cancel();
      _persistTimer = null;
      unawaited(_persistPlaybackStateNow());
      return;
    }

    if (isPlaying.value) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastPersistTime);
      if (elapsed >= _playingPersistInterval) {
        _persistTimer?.cancel();
        _persistTimer = null;
        unawaited(_persistPlaybackStateNow());
        return;
      }

      if (_persistTimer != null && _persistTimer!.isActive) return;
      _persistTimer = Timer(_playingPersistInterval - elapsed, () {
        _persistTimer = null;
        unawaited(_persistPlaybackStateNow());
      });
      return;
    }

    _persistTimer?.cancel();
    _persistTimer = Timer(_idlePersistDelay, () {
      _persistTimer = null;
      unawaited(_persistPlaybackStateNow());
    });
  }

  bool _shouldIgnoreZeroPosition(Duration value) {
    final session = _restoreSession;
    return session != null &&
        session.protectPosition &&
        value == Duration.zero &&
        position.value > Duration.zero;
  }

  _PlaybackRestoreState? _restoreSessionForSong(SongEntity song) {
    final session = _restoreSession;
    if (session == null) return null;
    if (session.songId != song.id) return null;
    return session;
  }

  void _syncPositionFromPlayer({bool allowZeroOverride = true}) {
    if (_isSeeking) return;
    final playerPosition = _activeEngine.position;
    if (playerPosition < Duration.zero) return;
    if (!allowZeroOverride &&
        playerPosition == Duration.zero &&
        position.value > Duration.zero) {
      return;
    }
    position.value = playerPosition;
  }

  Future<void> _persistPlaybackStateNow() async {
    _persistTimer?.cancel();
    _persistTimer = null;
    await _persistPlaybackState();
  }

  Future<void> _persistPlaybackState() async {
    _lastPersistTime = DateTime.now();
    final list = queue.value;
    if (list.isEmpty || currentIndex.value < 0) {
      await _clearPersistedPlaybackState();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final serialized = jsonEncode(list.map((e) => e.toMap()).toList());
    await prefs.setString(_prefsQueueKey, serialized);
    await prefs.setInt(_prefsIndexKey, currentIndex.value);
    await prefs.setInt(
      _prefsPositionKey,
      _positionForPersistence().inMilliseconds,
    );
    await prefs.setString(_prefsModeKey, playbackMode.value.name);
    await prefs.setBool(_prefsWasPlayingKey, isPlaying.value);
    // 持久化漫游链 ID：随机模式重启后 next/播完沿用同一个随机队列
    final roam = roamId;
    if (roam == null || roam.isEmpty) {
      await prefs.remove(_prefsRoamIdKey);
    } else {
      await prefs.setString(_prefsRoamIdKey, roam);
    }
    final songId = currentSong.value?.id;
    if (songId == null || songId.isEmpty) {
      await prefs.remove(_prefsSongIdKey);
    } else {
      await prefs.setString(_prefsSongIdKey, songId);
    }
  }

  Duration _positionForPersistence() {
    final session = _restoreSession;
    if (session != null && session.protectPosition) {
      if (_activeEngine.position > Duration.zero) return _activeEngine.position;
      return session.position;
    }
    return position.value;
  }

  Future<void> _clearPersistedPlaybackState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsQueueKey);
    await prefs.remove(_prefsIndexKey);
    await prefs.remove(_prefsPositionKey);
    await prefs.remove(_prefsModeKey);
    await prefs.remove(_prefsWasPlayingKey);
    await prefs.remove(_prefsSongIdKey);
    await prefs.remove(_prefsRoamIdKey);
  }

  Map<String, String>? _headersFromSong(SongEntity song) {
    final raw = (song.headersJson ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  SongEntity? _nextSongForIndex(List<SongEntity> list, int index) {
    final nextIndex = index + 1;
    if (nextIndex < 0 || nextIndex >= list.length) return null;
    return list[nextIndex];
  }

  void _warmupPlaybackSources(SongEntity current, {SongEntity? nextSong}) {
    unawaited(_warmupSource(current));
    if (nextSong != null) {
      unawaited(_warmupSource(nextSong));
    }
  }

  Future<void> _warmupSource(SongEntity song) async {
    final rawUri = (song.uri ?? '').trim();
    if (!rawUri.startsWith('http')) return;
    try {
      await _resolvePlayableUri(song);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService warmup source failed for ${song.title}: $e');
      }
    }
  }

  void _invalidateResolvedSource(SongEntity song) {
    _resolvedRemoteSources.remove(song.id);
    _sourceResolveInflight.remove(song.id);
  }

  Future<void> _autoExtendQueue() async {
    // 漫游模式走 _extendRoamQueue（roam-next）；本地随机（playShuffle）与
    // 顺序模式共用 queueExtender。防止与 _extendRoamQueue 并发重复追加。
    if (_roamAppendQueuedCount > 0) return;
    if (_isExtendingQueue) return;
    final extender = queueExtender;
    if (extender == null) return;

    _isExtendingQueue = true;
    try {
      final newSongs = await extender();
      if (newSongs.isEmpty) return;
      await _appendToQueue(newSongs);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService autoExtendQueue error: $e');
      }
    } finally {
      _isExtendingQueue = false;
    }
  }

  Future<void> _appendToQueue(List<SongEntity> newSongs) async {
    if (newSongs.isEmpty) return;

    final oldQueue = queue.value;
    final currentIdx = currentIndex.value;
    final pos = position.value;
    final wasPlaying = isPlaying.value;

    var allSongs = [...oldQueue, ...newSongs];
    // 追加后可能超长：按上限截断（保留当前歌曲，裁掉最旧的前部）
    final capped = _capQueue(allSongs, currentIdx);
    var newCurrentIdx = currentIdx;
    if (capped != null) {
      allSongs = capped.$1;
      newCurrentIdx = capped.$2;
    }
    queue.value = allSongs;

    // 重建引擎路由并重载当前 run（保持位置/播放态）。
    _applyEngineKinds(await _computeEngineKinds(allSongs));
    try {
      await _activateLogicalIndex(newCurrentIdx, initialPosition: pos);
      if (wasPlaying && !_activeEngine.playing) {
        await _activeEngine.play();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService appendToQueue error: $e');
      }
    }
  }

  /// 全局队列长度上限（设置项），用于截断新队列/追加/插播。
  int get _queueCap {
    final limit = AppPlaybackQueueSettings.maxQueueLength.value;
    return limit.clamp(1, 10000);
  }

  /// 把 [songs] 截断到上限以内，返回 (截断后列表, 新的当前索引)；
  /// 无需截断时返回 null。
  ///
  /// 保证当前歌曲（index 处）永不被裁掉：
  /// - 当前歌曲已处于末尾 cap 个区间 → 保留尾部（新追加的歌不丢），丢掉最旧的前部
  /// - 否则 → 保留当前歌曲及之后的 cap 首，丢掉更早的
  (List<SongEntity>, int)? _capQueue(List<SongEntity> songs, int index) {
    final cap = _queueCap;
    if (songs.length <= cap) return null;
    final idx = index < 0 ? 0 : index;
    final tailStart = songs.length - cap;
    if (idx >= tailStart) {
      return (songs.sublist(tailStart), idx - tailStart);
    }
    final end = (idx + cap).clamp(0, songs.length);
    return (songs.sublist(idx, end), 0);
  }

  void _applyLogicalQueue(List<SongEntity> songs, int currentQueueIndex) {
    queue.value = songs;
    if (songs.isEmpty) {
      currentIndex.value = -1;
      currentSong.value = null;
      _emitSnapshot(force: true);
      return;
    }
    // Clamp defensively: callers can pass an index derived from a since-changed
    // queue (e.g. error handling after the queue shrank), which would throw.
    final safeIndex = currentQueueIndex.clamp(0, songs.length - 1);
    currentIndex.value = safeIndex;
    currentSong.value = songs[safeIndex];
    _maybeProbeSong(songs[safeIndex]);
    _hydrateAndSetCurrentSong(songs[safeIndex]);
    _emitSnapshot(force: true);
  }

  /// 歌曲激活：更新当前歌曲 UI 状态（封面/歌名/进度）、统计上报、预热与预缓存。
  /// 由 _indexSub（真实切歌/重建）调用。
  void _activateSong(int idx) {
    currentIndex.value = idx;
    _prefetchTriggeredIndex = -1;
    final list = queue.value;
    if (idx >= 0 && idx < list.length) {
      final song = list[idx];
      final previousSongId = currentSong.value?.id;
      final songChanged = previousSongId != song.id;
      currentSong.value = song;
      StreamCacheService.instance.currentSongId = song.id;
      if (songChanged) {
        final restoredPosition = _restoreSessionForSong(song)?.position;
        position.value = restoredPosition ?? Duration.zero;
        bufferedPosition.value = Duration.zero;
        duration.value = song.durationMs != null
            ? Duration(milliseconds: song.durationMs!)
            : null;
      }
      _maybeProbeSong(song);
      _scheduleDeferredProbe(song);
      _hydrateAndSetCurrentSong(song);
      if (songChanged) {
        unawaited(FeiNiuApiClient.instance.reportTrackPlay(song.id));
      }
      _warmupPlaybackSources(song, nextSong: _nextSongForIndex(list, idx));
      if (songChanged && StreamCacheService.instance.isEnabled) {
        unawaited(_precacheNextChained(song, list, idx));
      }
      if (songChanged && song.coverId != null && song.coverId!.isNotEmpty) {
        // 引擎 song-changed 事件可能在恢复播放/初始化窗口内到达，此时根元素
        // 可能尚未挂载（rootElement 为 null）。封面预热尽力而为，跳过即可。
        final root = WidgetsBinding.instance.rootElement;
        if (root != null) {
          unawaited(
            precacheImage(
              CachedNetworkImageProvider(
                FeiNiuApiClient.instance.coverUrl(
                  song.coverId!,
                  size: FeiNiuApiClient.coverRequestSize,
                  updatedAt: song.updatedAt,
                ),
                headers: FeiNiuApiClient.imageAuthHeaders(),
              ),
              root,
            ),
          );
        }
      }
    } else {
      position.value = Duration.zero;
      bufferedPosition.value = Duration.zero;
      duration.value = null;
    }
    // 歌曲切换：重新 arm 无声看门狗（取消旧 timer，按新歌条件决定）。
    _restartSilenceWatch();
    _emitSnapshot(force: true);
  }

  String _headersFingerprint(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return '';
    final pairs = headers.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return pairs.map((e) => '${e.key}=${e.value}').join('&');
  }

  Future<Uri> _resolvePlayableUri(
    SongEntity song, {
    bool forceRefresh = false,
  }) async {
    final rawUri = (song.uri ?? '').trim();
    if (!rawUri.startsWith('http')) {
      return Uri.file(rawUri);
    }

    final headers = _headersFromSong(song);
    final headersKey = _headersFingerprint(headers);
    if (forceRefresh) {
      _invalidateResolvedSource(song);
    }

    final cached = _resolvedRemoteSources[song.id];
    if (cached != null &&
        cached.rawUri == rawUri &&
        cached.headersFingerprint == headersKey &&
        !cached.isExpired) {
      return cached.proxyUri;
    }

    final inflight = _sourceResolveInflight[song.id];
    if (inflight != null) return inflight;

    final future = () async {
      final api = FeiNiuApiClient.instance;
      final streamUrl = api.streamUrl(song.id);
      final finalUri = Uri.parse(streamUrl);
      _resolvedRemoteSources[song.id] = _ResolvedRemoteSource(
        rawUri: rawUri,
        headersFingerprint: headersKey,
        proxyUri: finalUri,
        resolvedAt: DateTime.now(),
      );
      return finalUri;
    }();

    _sourceResolveInflight[song.id] = future;
    future.whenComplete(() => _sourceResolveInflight.remove(song.id));
    return future;
  }

  void _maybeProbeSong(SongEntity song) {
    // 音频探测逻辑已移除，保留此调用点占位以便未来扩展。
  }

  void _scheduleDeferredProbe(SongEntity song) {
    unawaited(_deferredProbe(song));
  }

  Future<void> _deferredProbe(SongEntity song) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final current = currentSong.value;
    if (current == null || current.id != song.id) return;
    _maybeProbeSong(current);
  }

  void _maybePersistPlaybackDuration(SongEntity song, int durationMs) {
    final existing = song.durationMs ?? 0;
    if (existing > 0) return;
    final prev = _durationPersistedMs[song.id] ?? 0;
    if (prev == durationMs) return;
    _durationPersistedMs[song.id] = durationMs;
    _persistSongUpdate(song, durationMs: durationMs);
  }

  /// 歌曲元数据变更后更新本地持久化与当前播放状态（编辑歌曲保存后调用）。
  ///
  /// - [SongDao.upsertSongs] 持久化（重启后保持新标题/封面等）；
  /// - 若 [queue] 中存在同 id 歌曲则就地替换（迷你播放器/播放页/媒体通知
  ///   立即显示新元数据）；
  /// - 若替换的正是当前播放歌曲，失效已解析的播放源并重新预热（封面/标题
  ///   变化不影响已加载音频源，但需让播放页监听的新实体生效）。
  Future<void> updateSongMetadata(SongEntity updated) async {
    if (updated.id.isEmpty) return;
    await _songDao.upsertSongs([updated]);

    final list = queue.value;
    final idx = list.indexWhere((e) => e.id == updated.id);
    if (idx >= 0) {
      final updatedQueue = [...list];
      updatedQueue[idx] = updated;
      queue.value = updatedQueue;
    }

    final current = currentSong.value;
    if (current != null && current.id == updated.id) {
      _invalidateResolvedSource(updated);
      currentSong.value = updated;
      _warmupPlaybackSources(
        updated,
        nextSong: _nextSongForIndex(queue.value, currentIndex.value),
      );
      _emitSnapshot(force: true);
    }
  }

  Future<void> _persistSongUpdate(
    SongEntity song, {
    int? durationMs,
    String? title,
    String? artist,
    String? album,
    int? bitrate,
    int? sampleRate,
    int? fileSize,
    String? format,
  }) async {
    final next = SongEntity(
      id: song.id,
      title: title ?? song.title,
      artist: artist ?? song.artist,
      album: album ?? song.album,
      uri: song.uri,
      headersJson: song.headersJson,
      durationMs: durationMs ?? song.durationMs,
      bitrate: bitrate ?? song.bitrate,
      sampleRate: sampleRate ?? song.sampleRate,
      fileSize: fileSize ?? song.fileSize,
      format: format ?? song.format,
    );

    await _songDao.upsertSongs([next]);

    final list = queue.value;
    final idx = list.indexWhere((e) => e.id == song.id);
    if (idx >= 0) {
      final updatedQueue = [...list];
      updatedQueue[idx] = next;
      queue.value = updatedQueue;
    }

    final current = currentSong.value;
    if (current != null && current.id == song.id) {
      currentSong.value = next;
      _warmupPlaybackSources(
        next,
        nextSong: _nextSongForIndex(queue.value, currentIndex.value),
      );
      _emitSnapshot(force: true);
    }
  }

  Future<AudioSource> _sourceForSong(
    SongEntity song, {
    bool forceRefresh = false,
  }) async {
    final api = FeiNiuApiClient.instance;
    if (api.baseUrl.isNotEmpty) {
      // 播放出错重试时删除损坏/过期的缓存，强制走远端
      if (forceRefresh) {
        await StreamCacheService.instance.invalidate(song.id);
        FeiNiuTranscodeService.instance.invalidate(song.id);
      }

      // CUE 整轨曲目：不命中/不写入整轨文件下载缓存（否则每首 CUE 曲会把
      // 同一镜像各缓存一份），直接直连流，由下方 ClippingAudioSource 裁剪。
      final isCue = song.isCue;

      // 命中优先级（转码歌）：
      // 1. 原始完整缓存 → 本地文件（零带宽，最高优先）
      // 2. 转码完整缓存（tc_<id>_<codec>.mp4）→ 本地文件（零流量）
      // 3. 转码 HLS 在线（m3u8 → ExoPlayer 播 fMP4）
      // 4. 流式缓存源 / 直连（现有兜底）
      if (!isCue && StreamCacheService.instance.isEnabled) {
        final complete = await StreamCacheService.instance.completeFileFor(
          song.id,
          song: song,
        );
        if (complete != null) {
          return AudioSource.file(complete.path);
        }
      }

      // 转码歌：优先命中转码完整缓存（本地文件零流量），否则在线 HLS。
      // 转码失败/未启用时返回 null 落回下方现有路径。转码独立于下载缓存开关
      // （即使下载缓存关闭也走转码）。面板选「直连」的歌跳过转码。
      // **CUE 曲也走转码**：服务器按 guid 返回裁切好的单曲 HLS，无需裁剪；
      // 转码失败才落回下方 CUE 直连 + ClippingAudioSource 裁剪。
      if (!_forceDirectSongIds.contains(song.id) &&
          !_transcodeFailedSongIds.contains(song.id)) {
        final hls = await _transcodedSourceFor(song);
        if (hls != null) return hls;
      }

      if (!isCue && StreamCacheService.instance.isEnabled) {
        // 未缓存 → 缓存源（播放时边播边下载，缓存命中后次次秒播）
        return StreamCacheService.instance.sourceForSong(song);
      }
      final streamUrl = api.streamUrl(song.id);
      final headers = FeiNiuApiClient.imageAuthHeaders();
      final base = AudioSource.uri(Uri.parse(streamUrl), headers: headers);
      if (!isCue) return base;

      // 裁剪到 [offset, offset+duration)：ClippingAudioSource 上报裁剪后相对
      // 位置/时长，并在裁剪末尾触发 completed（自动切歌/单曲循环天然正确）。
      // end 一律裁剪（即使 offset=0 也要在曲目边界停，否则会放完整轨）。
      final offsetMs =
          song.cueOffsetMs ?? await FeiNiuCueService.instance.offsetMsFor(song);
      final durationMs = song.durationMs ?? 0;
      final start = offsetMs != null && offsetMs > 0
          ? Duration(milliseconds: offsetMs)
          : null;
      return ClippingAudioSource(
        child: base,
        start: start,
        end: Duration(milliseconds: (offsetMs ?? 0) + durationMs),
      );
    }
    final rawUri = (song.uri ?? '').trim();
    return AudioSource.file(rawUri);
  }

  /// 构建转码歌的播放源：
  /// 1. 转码完整缓存（`tc_<id>_<codec>.mp4`）→ `AudioSource.file`（零流量）
  /// 2. 否则转码 HLS 在线（`transcodeHlsUrlFor` → m3u8 → ExoPlayer），并
  ///    在返回后登记「播完后台拼接下载」。
  ///
  /// 返回 null 表示：不转码（`shouldTranscode` false，走直连）或**转码请求
  /// 失败**（此时标记 `_transcodeFailedSongIds`，下次路由回落直连，避免
  /// DSF/APE 等原 media_kit 格式在 just_audio 上解码失败 → 无限重试转码）。
  Future<AudioSource?> _transcodedSourceFor(SongEntity song) async {
    final svc = FeiNiuTranscodeService.instance;
    final codec = svc.effectiveCodecFor(song.id);

    // 1) 转码完整缓存命中 → 本地文件零流量。
    final cached = await StreamCacheService.instance.transcodeCompleteFileFor(
      song.id,
      codec,
    );
    if (cached != null) {
      if (kDebugMode) {
        debugPrint(
          '[PlayerService] transcode ${song.title} -> LOCAL ${cached.path}',
        );
      }
      return AudioSource.file(cached.path);
    }

    // 2) 需要转码判定：不转 → 直接直连（不标记，正常回落）。
    if (!await svc.shouldTranscode(song)) return null;

    // 3) 在线 HLS。
    final hlsUrl = await svc.transcodeHlsUrlFor(song);
    if (hlsUrl == null) {
      // 需要转码但转码请求失败 → 标记失败，本会话不再重试转码（回落
      // routeForSong：DSF→mediaKit 直连，普通→just_audio 直连）。
      _transcodeFailedSongIds.add(song.id);
      if (kDebugMode) {
        debugPrint('[PlayerService] transcode ${song.title} FAILED -> direct');
      }
      return null;
    }
    if (kDebugMode) {
      debugPrint('[PlayerService] transcode ${song.title} -> HLS $hlsUrl');
    }
    // 记录转码 HLS 地址：播完该歌时后台拼接下载成完整文件（第二次起零流量）。
    // 不在构建源时立即下载，避免首次播放双倍带宽。
    _activeTranscodeHlsUrl = hlsUrl;
    _activeTranscodeCodec = codec;
    return AudioSource.uri(
      Uri.parse(hlsUrl),
      headers: FeiNiuApiClient.imageAuthHeaders(),
    );
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    NetworkConnectionService.instance.wifiConnected.removeListener(
      _scheduleNetworkRouteRefresh,
    );
    AppTranscodeSettings.directOnWifi.removeListener(
      _scheduleNetworkRouteRefresh,
    );
    _networkRouteRefreshTimer?.cancel();
    _networkRouteRefreshTimer = null;
    // 释放全部服务器转码会话（fire-and-forget）。
    unawaited(FeiNiuTranscodeService.instance.quitAll());
    AppPlaybackVolumeSettings.volume.removeListener(_handleAppVolumeChanged);
    AppPlaybackSpeedSettings.speed.removeListener(_handlePlaybackSpeedChanged);
    AppPlaybackAudioFocusSettings.exclusiveFocus.removeListener(
      _handleExclusiveFocusChanged,
    );
    cancelSleepTimer();
    _silenceWatchTimer?.cancel();
    _silenceWatchTimer = null;
    _statsFlushTimer?.cancel();
    _statsService.flush();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    _stopBackgroundAudioKeepAlive();
    await _setAudioSessionActive(false);
    // 桌面端（Windows/macOS/Linux）just_audio 从未构造
    // （_defaultEngine 走 media_kit），访问 late final 会反构造一个
    // AudioPlayer 报错，须跳过。
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      await _justAudioEngine.dispose();
    }
    await _mediaKitEngine?.dispose();
    _mediaKitEngine = null;
  }
}

class _ResolvedRemoteSource {
  final String rawUri;
  final String headersFingerprint;
  final Uri proxyUri;
  final DateTime resolvedAt;

  const _ResolvedRemoteSource({
    required this.rawUri,
    required this.headersFingerprint,
    required this.proxyUri,
    required this.resolvedAt,
  });

  bool get isExpired =>
      DateTime.now().difference(resolvedAt) > PlayerService._resolvedSourceTtl;
}

class _PlaybackRestoreState {
  final List<SongEntity> queue;
  final int index;
  final String songId;
  final Duration position;
  final PlaybackMode mode;
  final bool wasPlaying;
  final String? roamId;
  bool sourcePrepared;
  bool seekApplied;
  bool prepareFailed;

  _PlaybackRestoreState({
    required this.queue,
    required this.index,
    required this.songId,
    required this.position,
    required this.mode,
    required this.wasPlaying,
    required this.roamId,
  }) : sourcePrepared = false,
       seekApplied = false,
       prepareFailed = false;

  SongEntity get currentSong => queue[index];

  bool get protectPosition => !seekApplied && position > Duration.zero;
}
