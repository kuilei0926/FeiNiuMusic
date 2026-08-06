import 'dart:async';
import 'dart:convert';
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
import 'feiniu/api_client.dart';
import 'feiniu/api_models.dart';
import 'feiniu/auth_service.dart';
import 'feiniu/cue_service.dart';
import 'feiniu/track_service.dart';
import 'feiniu/transcode_service.dart';
import 'player/just_audio_engine.dart';
import 'player/media_kit_engine.dart';
import 'player/playback_router.dart';
import 'player/player_engine.dart';
import 'stats_service.dart';
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
  late PlayerEngine _activeEngine = _justAudioEngine;

  /// media_kit 引擎（libmpv + FFmpeg）：FLAC/DSF 等。懒创建：
  /// 首次播放 media_kit 格式时才实例化原生 Player，省启动开销。
  MediaKitEngine? _mediaKitEngine;

  /// 与逻辑队列平行的引擎类型列表。构建队列时并发解析，
  /// 之后任意逻辑索引都能算出所在引擎与同引擎连续段（run）。
  List<EngineKind> _engineKinds = [];

  /// 当前引擎 run 在逻辑队列中的起始索引。引擎 currentIndexStream 给的是
  /// 引擎内（run 内）索引，映射回逻辑索引需加该偏移。
  int _activeRunStart = 0;

  /// 升级到 media_kit 的歌曲（just_audio 解码 FLAC 帧超限 `Buffer too small`
  /// 时当场升级，由 FFmpeg 无损解码）。会话内持续生效。
  final Set<String> _mediaKitEscalateSongIds = {};

  /// media_kit 连续解码失败的歌曲 id（会话内）。第二次失败即跳过该歌
  /// （前进/回卷），避免媒体损坏时无限重试刷屏。
  final Set<String> _mediaKitFailedSongIds = {};

  /// 网络缓慢提示计时器：media_kit 播无损大文件缓冲超时时触发一次提示。
  Timer? _slowNetworkTimer;
  bool _slowNetworkNotified = false;

  final SongDao _songDao = SongDao.instance;
  final StatsService _statsService = StatsService.instance;
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
    if (!kDebugMode) return;
    debugPrint('[PlayerService] $message');
  }

  PlayerService._internal() {
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _init();
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
      if (isPlaying.value) {
        unawaited(_ensureAudiblePlayback());
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _syncPositionFromPlayer();
      _persistPlaybackStateNow();
      _statsService.flush();
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
    await VolumeScheduleService.instance.ensureStarted();
    await WebDavPlaybackSettings.ensureLoaded();
    await AppCacheSettings.ensureLoaded();
    await AppLaunchPlaybackSettings.ensureLoaded();
    await AppPlaybackQueueSettings.ensureLoaded();
    final session = await AudioSession.instance;
    _audioSession = session;
    await session.configure(const AudioSessionConfiguration.music());
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
    await _applyAppVolume(AppPlaybackVolumeSettings.volume.value);
    // 用户可能在播放器初始化完成前就点了首页漫游（playQueue 递增
    // _queueGeneration）。_restorePlaybackState 内部按 generation 判断，
    // 一旦用户已开始新播放就跳过恢复，避免覆盖用户刚选的漫游队列/模式。
    try {
      await _restorePlaybackState();
    } finally {
      _restoringState = false;
    }
    _emitSnapshot(force: true);
    _debugLog('init completed');
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
      duration.value = value;
      final song = currentSong.value;
      final ms = value?.inMilliseconds ?? 0;
      if (song != null && ms > 0) {
        _maybePersistPlaybackDuration(song, ms);
      }
      _emitSnapshot(force: true);
    });
    engine.bufferedPositionStream.listen((value) {
      if (!identical(engine, _activeEngine)) return;
      bufferedPosition.value = value;
      _emitSnapshot(force: true);
    });
    engine.playbackStateStream.listen((state) {
      if (!identical(engine, _activeEngine)) return;
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
          await _advanceToLogicalIndex(idx + 1);
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
    await _advanceToLogicalIndex(idx + 1);
  }

  /// 前进到逻辑索引 [logicalIndex]：同引擎 run 内无缝 next；跨 run 切换引擎。
  Future<void> _advanceToLogicalIndex(int logicalIndex) async {
    final list = queue.value;
    if (logicalIndex < 0 || logicalIndex >= list.length) return;
    final cur = currentIndex.value;
    final wasPlaying = isPlaying.value;
    if (cur >= 0 &&
        cur < _engineKinds.length &&
        logicalIndex < _engineKinds.length &&
        _engineKinds[logicalIndex] == _engineKinds[cur]) {
      await _activeEngine.seekToNext();
    } else {
      await _activateLogicalIndex(logicalIndex);
    }
    if (wasPlaying && !_activeEngine.playing) {
      try {
        await _activeEngine.play();
      } catch (_) {}
    }
  }

  /// 计算队列中每个逻辑索引所属引擎（并发解析格式）。
  /// 已升级到 media_kit 的歌曲（FLAC 帧超限）强制走 media_kit。
  Future<List<EngineKind>> _computeEngineKinds(List<SongEntity> songs) async {
    return Future.wait(
      songs.map((s) async {
        if (_mediaKitEscalateSongIds.contains(s.id)) {
          _debugLog('engineKind ${s.title} -> mediaKit (escalated)');
          return EngineKind.mediaKit;
        }
        final kind = await routeForSong(s);
        // 只打印走 media_kit 的异常路由（正常 just_audio 不刷屏），用于
        // 确诊「为什么普通歌进了 media_kit」。
        if (kDebugMode && kind == EngineKind.mediaKit) {
          final fmt = FeiNiuTranscodeService.instance.resolvedFormatForSync(s);
          debugPrint(
            '[PlayerService] engineKind ${s.title} fmt=$fmt -> mediaKit',
          );
        }
        return kind;
      }),
    );
  }

  /// 计算逻辑索引 [logicalIndex] 所在同引擎连续段（run）。
  ({int start, int end, int localIndex, EngineKind kind}) _runBounds(
    int logicalIndex, {
    List<EngineKind>? kinds,
  }) {
    final k = kinds ?? _engineKinds;
    final kind = k[logicalIndex];
    var s = logicalIndex;
    while (s > 0 && k[s - 1] == kind) s--;
    var e = logicalIndex;
    while (e < k.length - 1 && k[e + 1] == kind) e++;
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
    // 从进入锁这一刻起就设置期望索引：切换引擎时旧引擎（如正在播上一首的
    // just_audio）可能广播 currentIndex 过渡事件（pause/准备释放时），
    // currentIndexStream 监听器用 _pendingLoadLogicalIndex 过滤它们。必须
    // 在 pause 旧引擎之前设置，否则「song changed to 旧歌」会先于加载发生。
    _pendingLoadLogicalIndex = logicalIndex;
    // 引擎路由始终在锁内用当前队列重算（不依赖锁外的赋值/长度缓存）。
    _engineKinds = await _computeEngineKinds(list);
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
    // loadQueue 返回后校准：以引擎实际 currentIndex 为准（等待匹配期望值）。
    final actualIdx = target.currentIndex;
    if (actualIdx != null && actualIdx >= 0) {
      final actualLogical = _activeRunStart + actualIdx;
      if (actualLogical >= 0 && actualLogical < queue.value.length) {
        _activateSong(actualLogical);
      }
    }
    await target.setLoopMode(
      playbackMode.value == PlaybackMode.single
          ? EngineLoopMode.single
          : EngineLoopMode.none,
    );
    await _applyEngineVolume(target);
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
      if (kDebugMode) {
        debugPrint(
          '[PlayerService] resolveEngineItem ${song.title} -> mediaKit '
          'waitLocal=$waitForLocal',
        );
      }
      return MediaKitItem(
        await _mediaForSong(song, waitForLocal: waitForLocal),
      );
    }
    if (kDebugMode) {
      debugPrint(
        '[PlayerService] resolveEngineItem ${song.title} -> justAudio',
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
          if (kDebugMode) {
            debugPrint(
              '[PlayerService] mediaForSong ${song.title} -> LOCAL '
              'path=${existing.path}',
            );
          }
          return mk.Media(existing.path);
        }
      } catch (_) {}
    }

    // 2) 默认：直连原始文件流（mpv 用 FFmpeg 原生解码 DSF/APE/WMA…）。
    //    不使用转码 HLS（mpv 的 FFmpeg 音频库无 HLS demuxer，播不了 fMP4）。
    final uri = FeiNiuApiClient.instance.streamUrl(song.id);
    if (kDebugMode) {
      debugPrint(
        '[PlayerService] mediaForSong ${song.title} waitLocal=$waitForLocal '
        'uri=$uri',
      );
    }
    // 后台触发完整下载缓存（不阻塞播放）：本次流式播放的同时把整首下载到
    // 本地，下次播同一首命中缓存 `Media(file)` 秒播（media_kit 直连流本身
    // 不留缓存，必须显式下载）。下载失败静默忽略，不影响本次播放。
    // CUE 整轨曲目跳过该下载（否则每首各缓存一份整轨镜像）。
    if (!isCue && StreamCacheService.instance.isEnabled) {
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

    // 双引擎架构：计算引擎路由，只加载当前 run 到对应引擎。
    _engineKinds = await _computeEngineKinds(playable);

    Future<bool> loadCurrentRunOnce() async {
      try {
        await _activateLogicalIndex(actualIndex);
        return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('PlayerService.playQueue activate failed: $e');
        }
        final msg = e.toString();
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
      unawaited(
        precacheImage(
          CachedNetworkImageProvider(
            FeiNiuApiClient.instance.coverUrl(
              song.coverId!,
              size: 800,
              updatedAt: song.updatedAt,
            ),
            headers: FeiNiuApiClient.imageAuthHeaders(),
          ),
          WidgetsBinding.instance.rootElement!,
        ),
      );
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

    final nextIndex = remaining.indexWhere((s) => s.id == current.id);
    if (nextIndex < 0) {
      await stopAndClear();
      return;
    }
    final wasPlaying = isPlaying.value;
    final pos = position.value;
    await _reloadQueue(
      remaining,
      nextIndex,
      play: wasPlaying,
      initialPosition: pos,
    );
  }

  Future<void> stopAndClear() async {
    _debugLog('stopAndClear');
    _clearRestoreSession();
    queueExtender = null;
    _isExtendingQueue = false;
    roamId = null;
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

    _engineKinds = await _computeEngineKinds(playable);
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
    var failedIndex = error.index;
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

      _debugLog(
        'recover current source index=$failedIndex song=${failedSong.title} '
        'engine=${_activeEngine.kind} error=$errorMsg',
      );

      final wasPlaying = isPlaying.value;
      final seekPos = failedIndex == currentIndex.value
          ? position.value
          : Duration.zero;

      if (isFlacTooLarge) {
        // FLAC 帧超限 → 升级 media_kit（FFmpeg 无损解码，无 32KB 限制，
        // 直连原始 FLAC 流）。
        _mediaKitEscalateSongIds.add(failedSong.id);
        FeiNiuTranscodeService.instance.invalidate(failedSong.id);
        _engineKinds = await _computeEngineKinds(list);
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
          await _skipFailedSong(failedSong, wasPlaying);
          return;
        }
        _mediaKitFailedSongIds.add(failedSong.id);
        FeiNiuTranscodeService.instance.invalidate(failedSong.id);
        _engineKinds = await _computeEngineKinds(list);
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
      FeiNiuTranscodeService.instance.invalidate(failedSong.id);
      _engineKinds = await _computeEngineKinds(list);
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

  /// media_kit 连续失败后跳过该歌：前进到下一首；队尾则按 loop 回卷/停止。
  /// 在 [_handlePlayerError] 的恢复块内调用（`_recoveringCurrentSource` 已置位，
  /// 不会再触发重复恢复）。跳过用 [_advanceToLogicalIndex] / [_activateLogicalIndex]，
  /// 由恢复块 finally 释放 `_recoveringCurrentSource`。
  Future<void> _skipFailedSong(SongEntity failedSong, bool wasPlaying) async {
    if (kDebugMode) {
      debugPrint(
        'PlayerService skip failed media_kit song: ${failedSong.title}',
      );
    }
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
    await _advanceToLogicalIndex(idx + 1);
  }

  Future<void> togglePlayPause() async {
    if (_activeEngine.playing) {
      await _pausePlayback();
    } else {
      await _startPlayback();
    }
  }

  Future<void> play() async {
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
    await _pausePlayback();
  }

  Future<void> next() async {
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
      final appendedKind = await routeForSong(nextTrack);
      final curKind =
          currentIndex.value >= 0 && currentIndex.value < _engineKinds.length
          ? _engineKinds[currentIndex.value]
          : EngineKind.justAudio;
      queue.value = allSongs;
      if (_engineKinds.length != baseQueue.length) {
        _engineKinds = await _computeEngineKinds(baseQueue);
      }
      _engineKinds = [..._engineKinds, appendedKind];

      if (identical(_activeEngine.kind, curKind) && appendedKind == curKind) {
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
      // 追加后超长按上限截断（保留当前歌曲）
      final curIdx = currentIndex.value;
      final capped = _capQueue(allSongs, curIdx);
      if (capped != null) {
        queue.value = capped.$1;
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
    if (prev >= _activeRunStart &&
        prev < _engineKinds.length &&
        _engineKinds[prev] == _activeEngine.kind) {
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
    _clearRestoreSession();
    final list = queue.value;
    if (index < 0 || index >= list.length) return;
    if (index >= _engineKinds.length) {
      _engineKinds = await _computeEngineKinds(list);
    }
    // 同 run → 引擎内索引；跨 run → 激活新 run。
    if (index >= _activeRunStart &&
        index < _activeRunStart + _activeEngine.sequenceLength &&
        _engineKinds[index] == _activeEngine.kind) {
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
    _engineKinds = await _computeEngineKinds(nextQueue);
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
    _engineKinds = await _computeEngineKinds(nextQueue);
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
    _engineKinds = await _computeEngineKinds(oldQueue);
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
        await _startPlayback();
        return;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Auto play on app launch failed: $e');
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
  }

  Future<void> _prepareRestoredAudioSource(
    _PlaybackRestoreState session,
  ) async {
    try {
      // 双引擎架构：按 run 加载恢复的当前曲所在引擎。
      _engineKinds = await _computeEngineKinds(session.queue);
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

  Future<void> _startPlayback() async {
    _debugLog('startPlayback song=${currentSong.value?.title ?? 'none'}');
    final active = await _setAudioSessionActive(true);
    if (!active) {
      throw Exception('Failed to activate audio session');
    }
    await _activeEngine.play();
    _completeRestoreSessionIfReady();
    _startBackgroundAudioKeepAliveIfNeeded();
  }

  Future<void> _pausePlayback() async {
    _debugLog('pausePlayback song=${currentSong.value?.title ?? 'none'}');
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
      await _activeEngine.seek(restored);
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
    _engineKinds = await _computeEngineKinds(allSongs);
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
        unawaited(
          precacheImage(
            CachedNetworkImageProvider(
              FeiNiuApiClient.instance.coverUrl(
                song.coverId!,
                size: 800,
                updatedAt: song.updatedAt,
              ),
              headers: FeiNiuApiClient.imageAuthHeaders(),
            ),
            WidgetsBinding.instance.rootElement!,
          ),
        );
      }
    } else {
      position.value = Duration.zero;
      bufferedPosition.value = Duration.zero;
      duration.value = null;
    }
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

      // 本地不支持的格式（DSF/APE/WMA…）与 FLAC 由 media_kit 引擎处理
      // （见 _mediaForSong / _activateLogicalIndex），just_audio 只播
      // MP3/AAC/Opus 等可直接解码的格式，这里直接走缓存/直连。
      if (!isCue && StreamCacheService.instance.isEnabled) {
        // 缓存命中 → 直接用本地文件（拖动进度条秒播）
        final complete = await StreamCacheService.instance.completeFileFor(
          song.id,
          song: song,
        );
        if (complete != null) {
          return AudioSource.file(complete.path);
        }
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

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    AppPlaybackVolumeSettings.volume.removeListener(_handleAppVolumeChanged);
    cancelSleepTimer();
    _statsFlushTimer?.cancel();
    _statsService.flush();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    _stopBackgroundAudioKeepAlive();
    await _setAudioSessionActive(false);
    await _justAudioEngine.dispose();
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
