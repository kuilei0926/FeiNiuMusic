import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'db/dao/song_dao.dart';
import 'audio/stream_cache_service.dart';
import 'feiniu/api_client.dart';
import 'feiniu/api_models.dart';
import 'feiniu/auth_service.dart';
import 'feiniu/track_service.dart';
import 'feiniu/transcode_service.dart';
import 'stats_service.dart';
import 'volume_schedule_service.dart';
import '../state/settings_state.dart';
import '../state/song_state.dart';
export '../state/player_state.dart';
import '../state/player_state.dart';

class PlayerService with WidgetsBindingObserver {
  static final PlayerService instance = PlayerService._internal();
  static const Duration _resolvedSourceTtl = Duration(minutes: 10);
  static const Duration _playingPersistInterval = Duration(seconds: 1);
  static const Duration _idlePersistDelay = Duration(milliseconds: 200);

  final _state = AppPlayerState.instance;

  /// `useProxyForRequestHeaders: false` 让 HLS/音频源的请求头（Cookie）由
  /// Android ExoPlayer 原生发送（DefaultHttpDataSource），而不是走 just_audio
  /// 的 Dart 本地代理。代理不解析 `#EXT-X-MAP`（m3u8 的 init.mp4 段），且会
  /// 用 Dart HttpClient 去连 NAS 的 IPv6 地址导致不可达，二者都会让转码 HLS
  /// 播放失败。
  final AudioPlayer _player = AudioPlayer(useProxyForRequestHeaders: false);
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

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<Duration>? _bufferSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlayerException>? _errorSub;
  StreamSubscription<LoopMode>? _loopModeSub;
  StreamSubscription<bool>? _shuffleSub;
  StreamSubscription<PositionDiscontinuity>? _positionDiscontinuitySub;
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
  int _lastPositionExtendIndex = -1;
  bool _recoveringCurrentSource = false;

  /// _appendRoamAndPlay 正在运行时跳过 _indexSub 的冗余状态同步
  bool _suppressIndexSync = false;

  /// roam 串行化计数：>0 表示有请求进行中或待处理
  int _roamAppendQueuedCount = 0;

  /// 切换为随机播放后，当前曲目播完时执行 roam 转换
  bool _roamTransitionPending = false;

  /// setPlaybackMode 正在执行时屏蔽 loopMode/shuffleMode 流监听，
  /// 防止 just_audio 异步事件把播放模式改回 loop/single
  bool _isApplyingPlaybackMode = false;

  /// 队列代次标记：每次 playQueue/startRoamPlayback 递增。
  /// 用于丢弃仍在途的漫游追加请求，防止其覆盖用户新选择的队列。
  int _queueGeneration = 0;

  Future<List<SongEntity>> Function()? queueExtender;
  bool _isExtendingQueue = false;

  /// Current roam ID for shuffle mode (roam-next API chain)
  String? roamId;

  static const String _prefsQueueKey = 'playback_queue_v1';
  static const String _prefsIndexKey = 'playback_index_v1';
  static const String _prefsPositionKey = 'playback_position_v1';
  static const String _prefsModeKey = 'playback_mode_v1';
  static const String _prefsWasPlayingKey = 'playback_was_playing_v1';
  static const String _prefsSongIdKey = 'playback_song_id_v1';
  static const String _prefsRoamIdKey = 'playback_roam_id_v1';

  bool get hasLoadedAudioSource => _player.audioSource != null;

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
      await _player.setLoopMode(LoopMode.all);
      playbackMode.value = PlaybackMode.loop;
      _debugLog('init default mode -> loop (gen=0)');
    }
    _positionSub = _player.positionStream.listen((value) {
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
      _maybeExtendByRemaining(value);
      _emitSnapshot();
    });
    _durationSub = _player.durationStream.listen((value) {
      duration.value = value;
      final song = currentSong.value;
      final ms = value?.inMilliseconds ?? 0;
      if (song != null && ms > 0) {
        _maybePersistPlaybackDuration(song, ms);
      }
      _emitSnapshot(force: true);
    });
    _bufferSub = _player.bufferedPositionStream.listen((value) {
      bufferedPosition.value = value;
      _emitSnapshot(force: true);
    });
    _stateSub = _player.playerStateStream.listen((state) {
      final wasPlaying = isPlaying.value;
      isPlaying.value = state.playing;
      // just_audio 加载中（loading/buffering）视为加载态，驱动播放按钮转圈
      final loading = state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering;
      if (loading != isLoading.value) {
        isLoading.value = loading;
      }
      _emitSnapshot(force: true);
      if (wasPlaying && !state.playing) {
        _schedulePersistPlaybackState(immediate: true);
      }
      // 随机模式：当前曲目自然播完且没有任何正在进行或队列中的填充请求时，自动触发填充
      if (state.processingState == ProcessingState.completed &&
          playbackMode.value == PlaybackMode.shuffle &&
          !_roamTransitionPending &&
          !_suppressIndexSync &&
          _roamAppendQueuedCount <= 0) {
        _roamTransitionPending = false;
        unawaited(_appendRoamAndPlay());
      }
    });
    _positionDiscontinuitySub = _player.positionDiscontinuityStream.listen((d) {
      // 刚切到随机模式时用 LoopMode.one 阻止自动切歌，当前曲目播完会原地循环，
      // 此时收到 autoAdvance 断点即表示当前曲目已播完，才开始拉取随机曲目。
      if (d.reason != PositionDiscontinuityReason.autoAdvance) return;
      if (!_roamTransitionPending) return;
      if (playbackMode.value != PlaybackMode.shuffle) return;
      _roamTransitionPending = false;
      unawaited(_appendRoamAndPlay());
    });
    _errorSub = _player.errorStream.listen((error) {
      unawaited(_handlePlayerError(error));
    });
    _indexSub = _player.currentIndexStream.listen((idx) {
      if (idx == null || _suppressIndexSync) return;
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
      // 队列快播完时自动扩展（仅顺序/单曲模式，随机模式由位置触发）
      if (playbackMode.value != PlaybackMode.shuffle &&
          idx >= 0 &&
          list.isNotEmpty &&
          idx >= list.length - 2) {
        unawaited(_autoExtendQueue());
      }
    });
    _loopModeSub = _player.loopModeStream.listen((loopMode) {
      if (_isApplyingPlaybackMode) return;
      // 随机模式下物理 LoopMode 必须是 one：播完当前曲发 autoAdvance 断点
      // 才触发 _appendRoamAndPlay 拉下一首随机。首次点漫游时 setAudioSources
      // 替换恢复的旧队列会触发 ExoPlayer 异步重建，把 loop 重置回 all（顺序播
      // 队列）。这里在流里兜底：随机模式下检测到物理不是 one 就立即纠正。
      if (playbackMode.value == PlaybackMode.shuffle) {
        if (loopMode != LoopMode.one) {
          _debugLog('shuffle loop reset to one (was ${loopMode.name})');
          _player.setLoopMode(LoopMode.one);
        }
        return;
      }
      playbackMode.value = loopMode == LoopMode.one
          ? PlaybackMode.single
          : PlaybackMode.loop;
      _debugLog('loopModeStream -> ${playbackMode.value.name}');
      _schedulePersistPlaybackState();
    });
    _shuffleSub = _player.shuffleModeEnabledStream.listen((enabled) {
      if (_isApplyingPlaybackMode) return;
      // We manage shuffle via roam-next API, not just_audio's internal shuffle.
      // Never let this stream override PlaybackMode.shuffle state.
      if (playbackMode.value == PlaybackMode.shuffle) {
        if (enabled) {
          _player.setShuffleModeEnabled(false);
        }
        return;
      }
      if (enabled) {
        playbackMode.value = PlaybackMode.shuffle;
        _player.setShuffleModeEnabled(false);
      } else {
        final loopMode = _player.loopMode;
        playbackMode.value = loopMode == LoopMode.one
            ? PlaybackMode.single
            : PlaybackMode.loop;
      }
      _debugLog('shuffleStream -> ${playbackMode.value.name}');
      _schedulePersistPlaybackState();
    });
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

  void _handleAppVolumeChanged() {
    unawaited(_applyAppVolume(AppPlaybackVolumeSettings.volume.value));
  }

  Future<void> _applyAppVolume(double value) async {
    try {
      await _player.setVolume(value.clamp(0, 1).toDouble());
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
    // 等待初始化（含旧播放会话恢复）完成，避免 setAudioSources 与恢复流程
    // 并发交错导致播放器物理 loop/shuffle 状态被覆盖。
    await _initFuture;
    _clearRestoreSession();
    _queueGeneration++;
    queueExtender = null;
    _isExtendingQueue = false;
    // 注意：显式用 this.roamId 强调这是成员字段赋值。历史上参数 roamId 曾
    // 遮蔽成员字段，导致 this.roamId 无法被正确恢复（roamId 永远清空），
    // 漫游续链时用错 roamId。参数现在命名 roamChainId 以彻底避免遮蔽，
    // 此处保留 this. 作为防御与文档。
    // ignore: unnecessary_this
    this.roamId = null;
    _roamTransitionPending = false;
    // 调用方传入漫游链时（如首页漫游点 banner），在清空后立即恢复，
    // 消除「playQueue 返回后手动恢复」的时序窗口：期间若有 _appendRoamAndPlay
    // 触发（播完/自动），roamId 非空走追加分支，不会 getRoamStart 新开队列。
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

    Future<bool> setSourcesOnce() async {
      try {
        final sourceQueue = await _buildPlaybackSourceQueue(playable);
        await _loadPlaybackSourceQueue(
          sourceQueue,
          initialIndex: actualIndex,
          // 当前歌曲先独占带宽，等剩余 < 30s 时再触发预加载
        );
        return true;
      } catch (e) {
        if (kDebugMode) {
          debugPrint('PlayerService.playQueue setAudioSources failed: $e');
        }
        final msg = e.toString();
        final shouldRetry =
            msg.contains('404') ||
            msg.contains('InvalidResponseCodeException') ||
            msg.contains('Source error');
        if (!shouldRetry) return false;

        try {
          await _player.stop();
        } catch (_) {}

        final current = playable[actualIndex];
        final uri = (current.uri ?? '').trim();
        if (uri.startsWith('http')) {}

        try {
          final sourceQueue = await _buildPlaybackSourceQueue(
            playable,
            forceRefreshSongId: current.id,
          );
          await _loadPlaybackSourceQueue(
            sourceQueue,
            initialIndex: actualIndex,
          );
          return true;
        } catch (e2) {
          if (kDebugMode) {
            debugPrint(
              'PlayerService.playQueue setAudioSources retry failed: $e2',
            );
          }
          return false;
        }
      }
    }

    final ok = await setSourcesOnce();
    if (!ok) {
      try {
        await _player.stop();
      } catch (_) {}
      isPlaying.value = false;
      _emitSnapshot(force: true);
      return;
    }

    // 目标模式：调用方传入（如漫游 shuffle）则用传入值，否则默认 loop。
    // 在 setAudioSources 之后立即设置物理状态，避免「playQueue 返回后再调
    // setPlaybackMode」的窗口里播完自动顺序切歌（表现为列表循环而非随机）。
    final targetMode = mode ?? PlaybackMode.loop;
    if (playbackMode.value != targetMode || mode != null) {
      await setPlaybackMode(targetMode);
    }

    try {
      await _player.play();
    } catch (e) {
      try {
        await _player.stop();
      } catch (_) {}
      isPlaying.value = false;
      _emitSnapshot();
      if (kDebugMode) {
        debugPrint('PlayerService.playQueue play failed: $e');
      }
    }
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

  void _maybeExtendByRemaining(Duration positionValue) {
    if (queueExtender == null) return;
    final total = duration.value;
    if (total == null || total.inMilliseconds <= 0) return;
    final remaining = total - positionValue;
    if (remaining.inSeconds > 15) return;
    final idx = currentIndex.value;
    if (idx < 0 || idx == _lastPositionExtendIndex) return;
    final list = queue.value;
    if (idx >= list.length - 2) {
      _lastPositionExtendIndex = idx;
      unawaited(_autoExtendQueue());
    }
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
  /// shuffle 模式下下一首由 roam API 决定，无法预知，跳过。
  Future<void> _precacheNextChained(
    SongEntity current,
    List<SongEntity> list,
    int index,
  ) async {
    if (!AppCacheSettings.precacheNextSong.value) return;
    if (!_precacheChainInFlight.add(current.id)) return; // 去重
    try {
      if (playbackMode.value == PlaybackMode.shuffle) return;
      // 链式节点：等待当前歌缓存下载完成（已完整则立即返回）
      await StreamCacheService.instance.waitForComplete(current.id);
      if (!AppCacheSettings.precacheNextSong.value) return; // 等待中开关被关
      if (playbackMode.value == PlaybackMode.shuffle) return; // 等待中模式被切
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
      await _player.stop();
    } catch (_) {}
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

    final sourceQueue = await _buildPlaybackSourceQueue(playable);
    try {
      await _loadPlaybackSourceQueue(sourceQueue, initialIndex: actualIndex);
    } catch (e) {
      await stopAndClear();
      if (kDebugMode) {
        debugPrint('PlayerService._reloadQueue setAudioSources failed: $e');
      }
      return;
    }

    final seekPos = initialPosition;
    if (seekPos != null && seekPos > Duration.zero) {
      try {
        await _player.seek(seekPos);
      } catch (_) {}
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

  Future<void> _handlePlayerError(PlayerException error) async {
    if (_recoveringCurrentSource) return;
    final failedIndex = error.index;
    final list = queue.value;
    if (failedIndex == null || failedIndex < 0 || failedIndex >= list.length) {
      if (kDebugMode) {
        debugPrint('PlayerService player error without valid index: $error');
      }
      return;
    }

    final failedSong = list[failedIndex];
    final rawUri = (failedSong.uri ?? '').trim();
    if (!rawUri.startsWith('http')) {
      if (kDebugMode) {
        debugPrint('PlayerService player error on non-remote source: $error');
      }
      return;
    }

    // 转码 FLAC 解码超限的安全处理：ExoPlayer 的输入缓冲（Android 平台
    // FLAC 解码器上限 32KB）装不下单个 FLAC 帧时抛
    // InsufficientCapacityException，错误信息形如 "Buffer too small (32768 < 94376)"。
    // 这是服务器按请求转出的无损 FLAC 帧过大导致的（codec 转 mp3 后帧变小），
    // 直接把该歌曲降级为 MP3 转码并重建，保证能播。
    final errorMsg = error.message ?? '';
    if (errorMsg.contains('InsufficientCapacity') ||
        errorMsg.contains('Buffer too small')) {
      FeiNiuTranscodeService.instance.degradeToMp3(failedSong.id);
      if (kDebugMode) {
        debugPrint(
          'PlayerService transcode FLAC too large, degrade ${failedSong.title} to MP3',
        );
      }
    }

    _recoveringCurrentSource = true;
    try {
      _debugLog(
        'recover current source index=$failedIndex song=${failedSong.title} error=${error.message}',
      );
      _invalidateResolvedSource(failedSong);
      await _resolvePlayableUri(failedSong, forceRefresh: true);

      final wasPlaying = isPlaying.value;
      final seekPos = failedIndex == currentIndex.value
          ? position.value
          : Duration.zero;
      final sourceQueue = await _buildPlaybackSourceQueue(
        list,
        forceRefreshSongId: failedSong.id,
      );
      _applyLogicalQueue(list, failedIndex);
      await _loadPlaybackSourceQueue(sourceQueue, initialIndex: failedIndex);
      if (seekPos > Duration.zero) {
        try {
          await _player.seek(seekPos);
        } catch (_) {}
      }
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

  Future<void> togglePlayPause() async {
    if (_player.playing) {
      await _pausePlayback();
    } else {
      await _startPlayback();
    }
  }

  Future<void> play() async {
    await _startPlayback();
  }

  Future<void> pause() async {
    await _pausePlayback();
  }

  Future<void> next() async {
    _clearRestoreSession();
    if (playbackMode.value == PlaybackMode.shuffle) {
      _roamTransitionPending = false;
      // 随机模式：调 _appendRoamAndPlay。roamId 非空时走追加分支——
      // 保留旧队列，roam-next 返回 current+next，追加到队尾、定位到 current
      // 播放、并推进 roamId。这样切到下一首的同时就请求到再下一首填充，
      // 不会出现「队尾空转/切歌后没有下一首」。
      await _appendRoamAndPlay();
      return;
    }
    // 离开随机模式 → 清除过渡标记
    _roamTransitionPending = false;
    final wasPlaying = _player.playing;
    await _player.seekToNext();
    if (!wasPlaying) {
      await _startPlayback();
    }
  }

  /// 随机模式：调 roam-start 或 roam-next 获取随机曲目
  /// 首次清空旧队列，后续保留旧队列只追加
  Future<void> _appendRoamAndPlay() async {
    if (_roamAppendQueuedCount > 0) {
      _roamAppendQueuedCount++;
      return;
    }
    final gen = _queueGeneration;
    _roamAppendQueuedCount = 1;
    _suppressIndexSync = true;
    try {
      final deviceId = await AuthService.instance.ensureDeviceId();

      final isFirst = roamId == null || roamId!.isEmpty;
      _debugLog(
        'appendRoamAndPlay isFirst=$isFirst roamId=${roamId ?? 'null'} '
        'gen=$gen queueGen=$_queueGeneration',
      );

      String newRoamId;
      dynamic roamTrackData;
      SongEntity? nextTrack;

      if (isFirst) {
        final startResponse = await FeiNiuApiClient.instance.getRoamStart(
          deviceId,
        );
        newRoamId = startResponse.current.roamId;
        roamTrackData = startResponse.current;
        if (startResponse.next != null) {
          nextTrack = FeiNiuTrackService.instance.trackToSongEntity(
            startResponse.next!.track.toJson(),
          );
        }
      } else {
        FeiNiuRoamNextResponse? response;
        try {
          response = await FeiNiuApiClient.instance.getRoamNext(
            deviceId,
            roamId!,
          );
        } catch (e) {
          // 重启后持久化的漫游链可能已在服务端过期（roam-next 返回非 0 code
          // 抛异常）。记录后走退化逻辑，避免随机模式下播完/点下一曲卡住。
          if (kDebugMode) {
            debugPrint('PlayerService roam-next expired, restart chain: $e');
          }
        }
        if (response == null || response.current == null) {
          final startResponse = await FeiNiuApiClient.instance.getRoamStart(
            deviceId,
          );
          newRoamId = startResponse.current.roamId;
          roamTrackData = startResponse.current;
          if (startResponse.next != null) {
            nextTrack = FeiNiuTrackService.instance.trackToSongEntity(
              startResponse.next!.track.toJson(),
            );
          }
        } else {
          newRoamId = response.current!.roamId;
          roamTrackData = response.current!;
          if (response.next != null) {
            nextTrack = FeiNiuTrackService.instance.trackToSongEntity(
              response.next!.track.toJson(),
            );
          }
        }
      }

      // 队列已被 playQueue/startRoamPlayback 替换，丢弃本次漫游追加
      if (gen != _queueGeneration) {
        _suppressIndexSync = false;
        return;
      }

      roamId = newRoamId;
      final track = FeiNiuTrackService.instance.trackToSongEntity(
        roamTrackData.track.toJson(),
      );

      // 首次清空旧队列，后续保留旧队列只追加。
      // roam-next 返回的 current 可能是上一轮的 next（已在队列里），也可能是
      // 全新的歌。正确做法：
      // - current 已在队列 → 复用其位置（避免重复），只追加 next；
      // - current 不在队列 → 追加 current + next。
      // 不能无条件把 current 从队尾去掉——那会在「播第一首切到第二首」时把
      // 第二首删掉，导致跳过第二首直接播第三首。
      final baseQueue = isFirst ? <SongEntity>[] : queue.value;
      final currentIndexInBase = track.id.isEmpty
          ? -1
          : baseQueue.indexWhere((s) => s.id == track.id);
      final List<SongEntity> newQueue;
      final int appendedIndex;
      if (currentIndexInBase >= 0) {
        // current 已在队列：保留原位，追加 next（若有）。
        newQueue = [
          ...baseQueue,
          if (nextTrack != null && nextTrack.id != track.id) nextTrack,
        ];
        appendedIndex = currentIndexInBase;
      } else {
        // current 不在队列：追加 current + next。
        newQueue = [
          ...baseQueue,
          track,
          if (nextTrack != null && nextTrack.id != track.id) nextTrack,
        ];
        appendedIndex = baseQueue.length;
      }

      // 用 _applyLogicalQueue 统一更新所有状态，只触发一次 UI 重建
      _suppressIndexSync = false;
      _debugLog(
        'appendRoamAndPlay build: baseQueue=[${baseQueue.map((s) => s.id).join(',')}] '
        'track=${track.id} currentIdxInBase=$currentIndexInBase '
        'nextTrack=${nextTrack?.id} newQueue=[${newQueue.map((s) => s.id).join(',')}] '
        'appendedIndex=$appendedIndex',
      );
      _applyLogicalQueue(newQueue, appendedIndex);

      final allSources = await Future.wait(
        newQueue.map((s) => _sourceForSong(s)),
      );
      await _player.setAudioSources(
        allSources,
        initialIndex: appendedIndex,
        initialPosition: Duration.zero,
        preload: true,
      );
      // 随机模式下物理 LoopMode 必须保持 one：播完当前曲发 autoAdvance 断点
      // 才触发 _appendRoamAndPlay 拉下一首随机。若设成 all，播完会顺序播放
      // 队列里的下一首（表现为列表循环而非随机）。setAudioSources 后需重设，
      // 因为加载新源可能重置播放器的 loop 状态。
      await _player.setLoopMode(
        playbackMode.value == PlaybackMode.shuffle
            ? LoopMode.one
            : LoopMode.all,
      );
      await _player.play();

      _maybeProbeSong(track);
      unawaited(FeiNiuApiClient.instance.reportTrackPlay(track.id));
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerService appendRoamAndPlay error: $e');
      if (!_player.playing) {
        try {
          await _player.seekToNext();
        } catch (_) {}
        if (!_player.playing) {
          try {
            await _player.play();
          } catch (_) {}
        }
      }
    } finally {
      _roamAppendQueuedCount--;
      if (_roamAppendQueuedCount > 0) {
        _roamAppendQueuedCount = 0;
        unawaited(_appendRoamAndPlay());
      }
    }
  }

  Future<void> previous() async {
    _clearRestoreSession();
    _roamTransitionPending = false;
    if (playbackMode.value == PlaybackMode.shuffle) {
      // 随机模式下 seekToPrevious 在物理 LoopMode.one 下切不动，同 next()，
      // 用 setAudioSources 重建定位到上一首。
      final list = queue.value;
      final idx = currentIndex.value;
      if (list.isNotEmpty && idx > 0) {
        _debugLog('previous(): shuffle reload index ${idx - 1}');
        final wasPlaying = _player.playing;
        final allSources = await Future.wait(
          list.map((s) => _sourceForSong(s)),
        );
        await _player.setAudioSources(
          allSources,
          initialIndex: idx - 1,
          initialPosition: Duration.zero,
          preload: true,
        );
        await _player.setLoopMode(LoopMode.one);
        if (wasPlaying && !_player.playing) {
          await _player.play();
        }
        return;
      }
    }
    final wasPlaying = _player.playing;
    await _player.seekToPrevious();
    if (!wasPlaying) {
      await _startPlayback();
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
      await _player.seek(position);
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
    await _player.seek(Duration.zero, index: index);
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
      await _reloadQueue(nextQueue, idx, play: wasPlaying, initialPosition: pos);
      return;
    }

    // 用 insertAudioSource 原地插入，避免 _reloadQueue 全量重建导致当前播放卡顿
    final source = await _sourceForSong(song);
    _applyLogicalQueue(nextQueue, idx);
    try {
      await _player.insertAudioSource(insertAt, source);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService.playNext insertAudioSource failed: $e');
      }
      // 插入失败（罕见）回退全量重建，保证队列一致
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _reloadQueue(nextQueue, idx, play: wasPlaying, initialPosition: pos);
      return;
    }

    if (playbackMode.value == PlaybackMode.shuffle) {
      await _player.setShuffleModeEnabled(true);
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
      await _reloadQueue(nextQueue, idx, play: wasPlaying, initialPosition: pos);
      return;
    }

    // 用 insertAudioSources 原地插入，避免 _reloadQueue 全量重建导致当前播放卡顿
    final sources = await Future.wait(
      toInsert.map((s) => _sourceForSong(s)),
    );
    _applyLogicalQueue(nextQueue, idx);
    try {
      await _player.insertAudioSources(insertAt, sources);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlayerService.insertNext insertAudioSources failed: $e');
      }
      // 插入失败（罕见）回退全量重建，保证队列一致
      final wasPlaying = isPlaying.value;
      final pos = position.value;
      await _reloadQueue(nextQueue, idx, play: wasPlaying, initialPosition: pos);
      return;
    }

    if (playbackMode.value == PlaybackMode.shuffle) {
      await _player.setShuffleModeEnabled(true);
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
      // playQueue 已按传入 mode 设置随机模式、恢复 roamId，播完自动拉下一首随机
      queueExtender = _defaultRoamQueueExtender;
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
    // 本地乱序队列直接进入随机模式（LoopMode.all 顺序播完整个乱序队列）
    _isApplyingPlaybackMode = true;
    try {
      await _applyPlaybackMode(PlaybackMode.shuffle);
      playbackMode.value = PlaybackMode.shuffle;
      _schedulePersistPlaybackState();
    } finally {
      _isApplyingPlaybackMode = false;
    }
    // 播完末尾自动把原列表重新乱序续接
    queueExtender = () async => ([...base]..shuffle(Random()));
  }

  /// 默认漫游队列扩展器 — 每次队列快播完时调用 roam-next 获取新歌曲追加
  Future<List<SongEntity>> _defaultRoamQueueExtender() async {
    try {
      final id = roamId;
      if (id == null || id.isEmpty) return [];

      final deviceId = await AuthService.instance.ensureDeviceId();
      final response = await FeiNiuApiClient.instance.getRoamNext(deviceId, id);
      if (response.next == null) return [];

      roamId = response.next!.roamId;

      final song = FeiNiuTrackService.instance.trackToSongEntity(
        response.next!.track.toJson(),
      );
      return [song];
    } catch (e) {
      _debugLog('defaultRoamQueueExtender error: $e');
      return [];
    }
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
    _isApplyingPlaybackMode = true;
    // 先写状态再同步播放器：playbackMode 是唯一真源，
    // 播放器异步调用即使挂起/失败也不影响 UI 状态与漫游逻辑。
    _roamTransitionPending = mode == PlaybackMode.shuffle;
    playbackMode.value = mode;
    _debugLog('setPlaybackMode -> ${mode.name}');
    _schedulePersistPlaybackState();
    try {
      if (mode == PlaybackMode.shuffle) {
        // 进入随机模式：保持当前曲目继续播放。用 LoopMode.one 阻止
        // just_audio 自动切歌，播完由 _appendRoamAndPlay 接管。
        await _player.setShuffleModeEnabled(false);
        await _player.setLoopMode(LoopMode.one);
      } else {
        await _applyPlaybackMode(mode);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('setPlaybackMode(${mode.name}) error: $e');
    } finally {
      _isApplyingPlaybackMode = false;
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
      _player.pause();
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
    await stopAndClear();
  }

  Future<void> removeFromQueue(int index) async {
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

    // 只就地移动音频源，不重建整个播放管线（避免正在播放的歌曲卡顿）。
    // 先同步逻辑队列，让 _indexSub 在 currentIndexStream 变化时能取到最新顺序。
    queue.value = oldQueue;
    _emitSnapshot(force: true);
    try {
      await _player.moveAudioSource(oldIndex, targetIndex);
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
        AppLaunchPlaybackSettings.autoPlayOnAppLaunch.value;
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
      final sourceQueue = await _buildPlaybackSourceQueue(session.queue);
      // 构建源期间用户可能已开始新的播放：放弃 apply，避免 setAudioSources
      // 覆盖用户刚选的队列、触发 index 流把播放模式改回 loop/single。
      if (_queueGeneration != 0) {
        session.prepareFailed = true;
        return;
      }
      await _loadPlaybackSourceQueue(
        sourceQueue,
        initialIndex: session.index,
        initialPosition: session.position,
        preload: true,
      );
      if (session.position > Duration.zero) {
        await _seekRestoredPosition(session.position);
      }
      // 加载源期间用户可能已点漫游开始播放（_queueGeneration 已递增）：
      // 放弃把旧会话的物理 loop/shuffle 状态应用到播放器，否则会把漫游
      // 设好的 LoopMode.one 改回 LoopMode.all，表现为列表循环而非随机。
      if (_queueGeneration != 0) {
        session.prepareFailed = true;
        return;
      }
      await _applyPlaybackMode(session.mode);
      session
        ..sourcePrepared = true
        ..seekApplied = true;
      position.value = session.position;
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
    await _player.play();
    _completeRestoreSessionIfReady();
    _startBackgroundAudioKeepAliveIfNeeded();
  }

  Future<void> _pausePlayback() async {
    _debugLog('pausePlayback song=${currentSong.value?.title ?? 'none'}');
    _stopBackgroundAudioKeepAlive();
    await _player.pause();
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
      if (!_player.playing && currentSong.value != null) {
        await _player.play();
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
      final processing = _player.processingState;
      if (processing == ProcessingState.idle) {
        final list = queue.value;
        final idx = currentIndex.value;
        if (list.isNotEmpty && idx >= 0 && idx < list.length) {
          final pos = position.value;
          final sourceQueue = await _buildPlaybackSourceQueue(list);
          await _loadPlaybackSourceQueue(
            sourceQueue,
            initialIndex: idx,
            initialPosition: pos,
            preload: true,
          );
        }
      }
      if (!_player.playing) {
        await _player.play();
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
      await _player.seek(restored);
    } finally {
      _isSeeking = false;
      if (_player.position > Duration.zero) {
        position.value = _player.position;
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
    if (mode == PlaybackMode.shuffle) {
      await _player.setLoopMode(LoopMode.all);
      await _player.setShuffleModeEnabled(false);
      return;
    }
    await _player.setLoopMode(
      mode == PlaybackMode.single ? LoopMode.one : LoopMode.all,
    );
    await _player.setShuffleModeEnabled(false);
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
    final playerPosition = _player.position;
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
      if (_player.position > Duration.zero) return _player.position;
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

    final allSources = await Future.wait(
      allSongs.map((s) => _sourceForSong(s)),
    );

    try {
      await _player.setAudioSources(
        allSources,
        initialIndex: newCurrentIdx,
        initialPosition: pos,
        preload: true,
      );

      // setAudioSources 会重置播放器 loop 状态。随机模式下必须锁回 one：
      // 播完当前曲发 autoAdvance 断点才触发 _appendRoamAndPlay 拉下一首随机，
      // 否则播完会顺序播放队列里的下一首（表现为列表循环）。
      if (playbackMode.value == PlaybackMode.shuffle) {
        await _player.setLoopMode(LoopMode.one);
      } else if (_player.shuffleModeEnabled) {
        await _player.setShuffleModeEnabled(true);
      }

      if (wasPlaying && !_player.playing) {
        await _player.play();
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

  Future<_PlaybackSourceQueue> _buildPlaybackSourceQueue(
    List<SongEntity> songs, {
    String? forceRefreshSongId,
  }) async {
    // 并行构造各源：转码/缓存路径涉及网络与文件 IO，串行会让大列表
    // 的队列构建逐个等待（尤其格式未知时逐个请求 metadata）。
    final sources = await Future.wait(
      songs.map((song) => _sourceForSong(
            song,
            forceRefresh:
                forceRefreshSongId != null && song.id == forceRefreshSongId,
          )),
    );
    return _PlaybackSourceQueue(
      songs: List<SongEntity>.from(songs),
      sources: sources,
    );
  }

  Future<void> _loadPlaybackSourceQueue(
    _PlaybackSourceQueue sourceQueue, {
    required int initialIndex,
    Duration? initialPosition,
    bool preload = false,
  }) async {
    await _player.setAudioSources(
      sourceQueue.sources,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      preload: preload,
    );
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

      // 本地不支持的格式 → 走服务器转码 HLS（不缓存、不落盘）。
      // 列表接口常不返回 audioSpec.format，先经 metadata 确认格式；
      // 转码或格式确认失败均回退直连，不中断播放。
      try {
        final format = await FeiNiuTranscodeService.instance
            .resolvedFormatFor(song);
        if (FeiNiuTranscodeService.instance.isTranscodeNeeded(format)) {
          final hlsUrl = await FeiNiuTranscodeService.instance.hlsUrlFor(song);
          if (hlsUrl != null) {
            return HlsAudioSource(
              Uri.parse(hlsUrl),
              headers: FeiNiuApiClient.imageAuthHeaders(),
            );
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('PlayerService transcode fallback for ${song.title}: $e');
        }
      }

      if (StreamCacheService.instance.isEnabled) {
        // 缓存命中 → 直接用本地文件（拖动进度条秒播）
        final complete = await StreamCacheService.instance.completeFileFor(
          song.id,
        );
        if (complete != null) {
          return AudioSource.file(complete.path);
        }
        // 未缓存 → 缓存源（播放时边播边下载，缓存命中后次次秒播）
        return StreamCacheService.instance.sourceForSong(song);
      }
      final streamUrl = api.streamUrl(song.id);
      final headers = FeiNiuApiClient.imageAuthHeaders();
      return AudioSource.uri(Uri.parse(streamUrl), headers: headers);
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
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _bufferSub?.cancel();
    await _stateSub?.cancel();
    await _indexSub?.cancel();
    await _errorSub?.cancel();
    await _loopModeSub?.cancel();
    await _shuffleSub?.cancel();
    await _positionDiscontinuitySub?.cancel();
    await _interruptionSub?.cancel();
    await _becomingNoisySub?.cancel();
    _stopBackgroundAudioKeepAlive();
    await _setAudioSessionActive(false);
    await _player.dispose();
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

class _PlaybackSourceQueue {
  final List<SongEntity> songs;
  final List<AudioSource> sources;

  const _PlaybackSourceQueue({required this.songs, required this.sources});
}
