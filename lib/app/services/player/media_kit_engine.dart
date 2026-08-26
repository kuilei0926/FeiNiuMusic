import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as mk;

import 'player_engine.dart';

/// media_kit 会在播放列表中的**每一首**结束时短暂上报 completed=true，
/// 随后自行推进到下一项；业务层只应在物理播放列表最后一项结束时处理完成，
/// 否则会与 media_kit 的自动推进叠加，造成一次跳过两首。
@visibleForTesting
EngineProcessingState mediaKitProcessingState({
  required bool buffering,
  required bool completed,
  required int playlistIndex,
  required int playlistLength,
}) {
  final reachedPlaylistEnd =
      playlistLength > 0 && playlistIndex >= playlistLength - 1;
  if (completed && reachedPlaylistEnd) {
    return EngineProcessingState.completed;
  }
  if (buffering) return EngineProcessingState.buffering;
  return EngineProcessingState.ready;
}

/// completed 与 playlist 来自不同的异步流；completed 回调执行时原生状态里的
/// 索引可能已经抢先切到下一首，因此优先使用 playlist 流已交付的索引。
@visibleForTesting
int mediaKitCompletedPlaylistIndex({
  required int? observedIndex,
  required int nativeIndex,
}) => observedIndex ?? nativeIndex;

/// 部分 FLAC 在尾部附带非音频字节时，FFmpeg 会先报一条解码错误，紧接着
/// 正常 EOF。这个错误不应触发“重载当前歌曲”，否则会带着末尾进度重开并
/// 形成反复暂停；真正发生在歌曲中段的解码错误仍交给业务层恢复。
@visibleForTesting
bool mediaKitIsTrailingDecodeError({
  required String message,
  required bool completed,
  required Duration position,
  required Duration duration,
}) {
  if (!message.toLowerCase().contains('error decoding audio')) return false;
  if (completed) return true;
  if (duration <= Duration.zero) return false;
  return duration - position <= const Duration(seconds: 2);
}

/// CUE 整轨曲目用 `Media(start:)` 裁剪播放时，mpv 上报的 position 是**整轨
/// 文件**的绝对时间（如第 3 首从 50 分钟起，position 就报 50:00+），而时长
/// 同样是整轨的。时间轴需要把 mpv 绝对时间换算成裁剪段内的相对时间：
/// `normalizeCroppedPosition` 做 position 换算（不低于 0），`seek` 反向加回
/// 起始偏移得到 mpv 需要的整轨绝对位置。非裁剪曲目（start 为 null/零）原样
/// 透传，行为不变。just_audio 端由 ClippingAudioSource 天然上报相对时间，
/// 无需此换算。
@visibleForTesting
Duration normalizeCroppedPosition(Duration raw, Duration? start) {
  if (start == null || start <= Duration.zero) return raw;
  final normalized = raw - start;
  return normalized < Duration.zero ? Duration.zero : normalized;
}

@visibleForTesting
Duration absoluteCroppedSeekTarget(Duration relative, Duration? start) {
  if (start == null || start <= Duration.zero) return relative;
  return relative + start;
}

/// [PlayerEngine] 的 media_kit（libmpv + FFmpeg）实现。
///
/// 负责 ExoPlayer 受限的格式（FLAC 32KB 帧缓冲上限、DSF/DSD/APE/WMA 等）。
/// FFmpeg 解码不受 32KB 限制；服务器转码的 FLAC HLS（m3u8）经
/// `Media.httpHeaders`（写入 mpv `http-header-fields`）携带 Cookie，
/// m3u8 及其分段都继承认证头。
///
/// media_kit 自身不申请 Android 音频焦点（无 AudioManager 逻辑），
/// 焦点完全由 App 的 audio_session 掌管，因此与 just_audio 不会双焦点冲突。
class MediaKitEngine implements PlayerEngine {
  mk.Player? _player;
  bool _disposed = false;
  int? _observedPlaylistIndex;
  int _loadGeneration = 0;
  bool _playRequested = false;
  int? _recoveringEofIndex;

  // 归一化流：用 Subject 桥接 media_kit 原生流，让 PlayerService 只订阅一次。
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration?>.broadcast();
  final _bufferedCtl = StreamController<Duration>.broadcast();
  final _playbackStateCtl = StreamController<EnginePlaybackState>.broadcast();
  final _errorCtl = StreamController<EngineError>.broadcast();
  final _indexCtl = StreamController<int?>.broadcast();

  @override
  EngineKind get kind => EngineKind.mediaKit;

  /// 懒创建原生 [mk.Player]：首个 media_kit `loadQueue` 时才初始化，
  /// 避免 App 启动即多占一个 native handle（libmpv 加载 + 事件循环）。
  /// 初始化失败（原生库缺失/损坏）抛异常，由调用方（PlayerService）降级
  /// 回 just_audio，避免闪退。
  @override
  Future<void> init() async {
    if (_player != null || _disposed) return;
    // 默认 error 级别：mpv trace 会在每个音频帧打 demux/缓存日志（即便未播放
    // 也会刷屏，拖慢低端设备）。需要诊断 media_kit 加载/解码问题时再临时开 trace。
    final player = mk.Player(
      configuration: const mk.PlayerConfiguration(
        logLevel: mk.MPVLogLevel.error,
      ),
    );
    _player = player;
    // media_kit 默认启用 mpv cache-on-disk。macOS 沙盒与部分 Windows 环境
    // （无法访问 mpv 默认缓存目录）下 mpv 创建其文件缓存失败，日志为
    // "Failed to create file cache"，随后 FLAC 流可能在曲末报 invalid frame
    // header。关闭磁盘层，仅保留既有 32MB 内存 demux 缓存；应用自己的
    // StreamCacheService 仍负责完整歌曲落盘。
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows) {
      try {
        final dynamic nativePlayer = player.platform;
        await nativePlayer.setProperty('cache-on-disk', 'no');
      } catch (e) {
        debugPrint('[MediaKitEngine] disable disk cache failed: $e');
      }
    }
    // 订阅 mpv 原生日志：仅保留错误级别（PlayerConfiguration.logLevel=error），
    // 诊断加载/解码失败的具体原因。不依赖 kDebugMode：release 版经 DebugLogService
    // 设置页「调试模式」同样可捕获，便于排查线上偶发播放失败。
    player.stream.log.listen((log) {
      debugPrint('[mpv:${log.prefix}] ${log.text}');
    });
    _wire(player);
  }

  void _wire(mk.Player player) {
    player.stream.position.listen((v) {
      if (!_positionCtl.isClosed) {
        // CUE 裁剪曲目：mpv 报整轨绝对位置，换算为裁剪段内相对时间。
        _positionCtl.add(normalizeCroppedPosition(v, _currentItemStart()));
      }
    });
    player.stream.duration.listen((v) {
      if (!_durationCtl.isClosed) _durationCtl.add(v);
    });
    player.stream.buffer.listen((v) {
      if (!_bufferedCtl.isClosed) _bufferedCtl.add(v);
    });
    player.stream.playing.listen((playing) {
      if (!_playbackStateCtl.isClosed) {
        // EOF 时 media_kit 先广播 playing=false，再广播 completed=true。
        // completed 只由下方 completed 流归一化，避免队尾完成被处理两次。
        _playbackStateCtl.add(
          EnginePlaybackState(
            playing: playing,
            processingState: player.state.buffering
                ? EngineProcessingState.buffering
                : EngineProcessingState.ready,
          ),
        );
      }
    });
    player.stream.buffering.listen((buffering) {
      if (!_playbackStateCtl.isClosed) {
        _playbackStateCtl.add(
          EnginePlaybackState(
            playing: player.state.playing,
            processingState: buffering
                ? EngineProcessingState.buffering
                : EngineProcessingState.ready,
          ),
        );
      }
    });
    player.stream.completed.listen((completed) {
      final playlist = player.state.playlist;
      // `completed` 与 `playlist` 是两个异步 StreamController。mpv 在一首
      // 结束后会先 enqueue completed=true，再立即把 PlayerState.playlist
      // 更新到下一首；因此此回调执行时直接读 playlist.index 可能已经是
      // 下一首，倒数第二首会被误判为整个 run 已完成。使用 playlist 流已经
      // 按事件顺序交付的索引，才能确定这次 EOF 实际属于哪一首。
      final completedIndex = mediaKitCompletedPlaylistIndex(
        observedIndex: _observedPlaylistIndex,
        nativeIndex: playlist.index,
      );
      final processingState = mediaKitProcessingState(
        buffering: player.state.buffering,
        completed: completed,
        playlistIndex: completedIndex,
        playlistLength: playlist.medias.length,
      );
      if (completed &&
          processingState != EngineProcessingState.completed &&
          _playRequested) {
        // mpv 正常情况下会自行进入下一项；部分 macOS/libmpv 时序下公开状态
        // 会停在 playing=false + completed=true。延后一拍确认，仍未继续时精确
        // 重开 EOF 的下一项。不能调用 Player.play()（completed=true 时会回到
        // playlist index 0），也不能直接 next()（mpv 已自动前进时会跳过一首）。
        unawaited(
          _recoverIntermediateEof(
            player,
            completedIndex: completedIndex,
            generation: _loadGeneration,
          ),
        );
      }
      if (kDebugMode && processingState == EngineProcessingState.completed) {
        // 诊断：media_kit 可能在加载失败时也置 completed（mpv 端无法播放），
        // 导致 PlayerService 把它当"播完"前进而不是走 error 恢复。
        debugPrint(
          '[MediaKitEngine] playlist completed index=$completedIndex '
          'nativeIndex=${playlist.index}',
        );
      }
      if (!_playbackStateCtl.isClosed) {
        _playbackStateCtl.add(
          EnginePlaybackState(
            playing: player.state.playing,
            processingState: processingState,
          ),
        );
      }
    });
    player.stream.playlist.listen((playlist) {
      _observedPlaylistIndex = playlist.index;
      if (!_indexCtl.isClosed) _indexCtl.add(playlist.index);
    });
    player.stream.error.listen((msg) {
      // 始终输出（release 可经 DebugLogService 捕获），让偶发播放失败可诊断。
      final state = player.state;
      final trailingDecodeError = mediaKitIsTrailingDecodeError(
        message: msg,
        completed: state.completed,
        position: state.position,
        duration: state.duration,
      );
      if (trailingDecodeError) {
        debugPrint(
          '[MediaKitEngine] ignored trailing decode error '
          'index=${state.playlist.index} '
          'position=${state.position.inMilliseconds} '
          'duration=${state.duration.inMilliseconds}',
        );
        return;
      }
      debugPrint('[MediaKitEngine] error="$msg" index=${state.playlist.index}');
      if (_errorCtl.isClosed) return;
      // mpv 错误不带索引；附加当前播放列表索引，让 PlayerService 能定位
      // 失败歌曲并触发恢复/降级。
      final idx = state.playlist.index;
      _errorCtl.add(
        EngineError(
          message: msg,
          index: idx >= 0 && idx < state.playlist.medias.length ? idx : null,
        ),
      );
    });
  }

  /// 当前播放项若带 `Media(start:)` 裁剪（CUE 整轨曲目），返回其起始偏移；
  /// 否则返回 null。mpv 的 position/duration 都是整轨绝对时间，裁剪段内
  /// 的时间轴以该偏移为基准换算（见 [normalizeCroppedPosition]）。
  Duration? _currentItemStart() {
    final p = _player;
    if (p == null) return null;
    final medias = p.state.playlist.medias;
    final idx = p.state.playlist.index;
    if (idx < 0 || idx >= medias.length) return null;
    final start = medias[idx].start;
    if (start == null || start <= Duration.zero) return null;
    return start;
  }

  Future<void> _recoverIntermediateEof(
    mk.Player player, {
    required int completedIndex,
    required int generation,
  }) async {
    if (_recoveringEofIndex == completedIndex) return;
    _recoveringEofIndex = completedIndex;
    try {
      // 给 mpv 的正常 playlist 自动前进与 START_FILE 事件一个短暂窗口。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (_disposed ||
          generation != _loadGeneration ||
          !_playRequested ||
          !identical(player, _player) ||
          player.state.playing) {
        return;
      }

      final playlist = player.state.playlist;
      final targetIndex = completedIndex + 1;
      if (targetIndex < 0 || targetIndex >= playlist.medias.length) return;
      // 用户/业务层已经切到更后面的歌曲时，旧 EOF 恢复任务不得倒退播放。
      if (playlist.index > targetIndex) return;

      _observedPlaylistIndex = targetIndex;
      await player.open(
        mk.Playlist(playlist.medias, index: targetIndex),
        play: true,
      );
      debugPrint(
        '[MediaKitEngine] recovered intermediate EOF '
        'completedIndex=$completedIndex targetIndex=$targetIndex',
      );
    } catch (e) {
      debugPrint('[MediaKitEngine] intermediate EOF recovery failed: $e');
    } finally {
      if (_recoveringEofIndex == completedIndex) {
        _recoveringEofIndex = null;
      }
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _playRequested = false;
    _loadGeneration++;
    await _closeControllers();
    final p = _player;
    _player = null;
    if (p != null) {
      try {
        await p.dispose();
      } catch (_) {}
    }
  }

  Future<void> _closeControllers() async {
    await _positionCtl.close();
    await _durationCtl.close();
    await _bufferedCtl.close();
    await _playbackStateCtl.close();
    await _errorCtl.close();
    await _indexCtl.close();
  }

  /// media_kit `Player.open` 的硬超时。mpv 对**本地文件**应在几百毫秒内完成
  /// open；超时说明 mpv 卡在协议/解码初始化（如媒体无法识别、HLS 无法解析），
  /// 继续等待只会让 PlayerService 的 `_activateLogicalIndexLocked` 挂起——
  /// 上游 playQueue 超时后会并发地把队列**第一首**重新路由进 just_audio，
  /// 表现为「点了 DSF 歌却把 index 0 的旧歌加载进 ExoPlayer 报 Source error、
  /// 媒体信息已切换但进度条不动、旧音频不停止」。
  ///
  /// 超时抛 [TimeoutException]，PlayerService 捕获后走 `_fallbackToJustAudioForCurrent`
  /// 降级回 just_audio 直连（本地文件路径，ExoPlayer 尽力解码 + 缓存秒播），
  /// 不让播放器卡死。
  static const Duration openTimeout = Duration(seconds: 10);

  @override
  Future<void> loadQueue({
    required List<EngineItem> items,
    required int index,
    Duration? initialPosition,
    bool preload = false,
  }) async {
    await init();
    final player = _player!;
    _playRequested = false;
    _loadGeneration++;
    final medias = items
        .cast<MediaKitItem>()
        .map((e) => e.media)
        .toList(growable: false);
    final safeIndex = index.clamp(0, medias.length - 1);
    // 在 open 的 playlist 事件异步送达前，completed 判定也必须有正确种子。
    _observedPlaylistIndex = safeIndex;
    await player
        .open(mk.Playlist(medias, index: safeIndex), play: false)
        .timeout(openTimeout);
    if (initialPosition != null && initialPosition > Duration.zero) {
      // 恢复播放位置对 CUE 曲目是相对时间：加回该曲起始偏移换算成整轨
      // 绝对位置再让 mpv 定位（否则会 seek 到整轨文件前面的部分）。
      await player.seek(
        absoluteCroppedSeekTarget(initialPosition, medias[safeIndex].start),
      );
    }
  }

  @override
  Future<void> play() async {
    final p = _player;
    if (p == null) return;
    _playRequested = true;
    await p.play();
  }

  @override
  Future<void> pause() async {
    final p = _player;
    if (p == null) return;
    _playRequested = false;
    await p.pause();
  }

  @override
  Future<void> stop() async {
    final p = _player;
    if (p == null) return;
    _playRequested = false;
    _loadGeneration++;
    try {
      await p.stop();
    } catch (_) {}
  }

  @override
  Future<void> seek(Duration position) async {
    final p = _player;
    if (p == null) return;
    // CUE 裁剪曲目：相对 seek 目标换算回整轨绝对位置，mpv 才能定位到
    // 裁剪段内正确的点（否则会落到整轨文件的前面部分）。
    await p.seek(absoluteCroppedSeekTarget(position, _currentItemStart()));
  }

  @override
  Future<void> seekToNext() async {
    final p = _player;
    if (p == null) return;
    await p.next();
  }

  @override
  Future<void> seekToPrevious() async {
    final p = _player;
    if (p == null) return;
    await p.previous();
  }

  @override
  Future<void> skipToIndex(int index) async {
    final p = _player;
    if (p == null) return;
    final medias = p.state.playlist.medias;
    if (index < 0 || index >= medias.length) return;
    // media_kit 无公开"跳索引"API：以当前播放列表为蓝本，在目标索引处重开。
    // open(play: 当前状态) 保持播放/暂停语义。
    await p.open(mk.Playlist(medias, index: index), play: p.state.playing);
  }

  @override
  Future<void> setLoopMode(EngineLoopMode mode) async {
    final p = _player;
    if (p == null) return;
    final m = switch (mode) {
      EngineLoopMode.none => mk.PlaylistMode.none,
      EngineLoopMode.single => mk.PlaylistMode.single,
      EngineLoopMode.all => mk.PlaylistMode.loop,
    };
    await p.setPlaylistMode(m);
  }

  @override
  Future<void> setVolume(double volume) async {
    final p = _player;
    if (p == null) return;
    // media_kit 的 volume 是 0..100 的百分比（mpv `volume` 属性，默认 100），
    // 而引擎接口约定 0..1 归一化音量，这里换算。
    await p.setVolume(volume.clamp(0.0, 1.0) * 100);
  }

  @override
  Future<void> setSpeed(double speed) async {
    final p = _player;
    if (p == null) return;
    try {
      await p.setRate(speed);
    } catch (_) {}
  }

  @override
  Future<void> insertItem(int index, EngineItem item) async {
    final p = _player;
    if (p == null) return;
    await p.add((item as MediaKitItem).media);
  }

  @override
  Future<void> insertItems(int index, List<EngineItem> items) async {
    final p = _player;
    if (p == null) return;
    for (final item in items) {
      await p.add((item as MediaKitItem).media);
    }
  }

  @override
  Future<void> removeItem(int index) async {
    final p = _player;
    if (p == null) return;
    await p.remove(index);
  }

  @override
  Future<void> moveItem(int from, int to) async {
    final p = _player;
    if (p == null) return;
    await p.move(from, to);
  }

  @override
  Duration get position {
    final p = _player;
    if (p == null) return Duration.zero;
    return normalizeCroppedPosition(p.state.position, _currentItemStart());
  }

  @override
  int? get currentIndex {
    final p = _player;
    return p?.state.playlist.index;
  }

  @override
  int get sequenceLength {
    final p = _player;
    return p?.state.playlist.medias.length ?? 0;
  }

  @override
  bool get hasLoadedSource =>
      _player != null && _player!.state.playlist.medias.isNotEmpty;

  @override
  bool get playing => _player?.state.playing ?? false;

  @override
  EngineProcessingState get processingState {
    final p = _player;
    if (p == null) return EngineProcessingState.idle;
    if (p.state.buffering) return EngineProcessingState.buffering;
    if (p.state.completed) return EngineProcessingState.completed;
    if (p.state.playlist.medias.isEmpty) return EngineProcessingState.idle;
    return EngineProcessingState.ready;
  }

  @override
  EngineLoopMode get loopMode {
    final p = _player;
    if (p == null) return EngineLoopMode.none;
    return switch (p.state.playlistMode) {
      mk.PlaylistMode.none => EngineLoopMode.none,
      mk.PlaylistMode.single => EngineLoopMode.single,
      mk.PlaylistMode.loop => EngineLoopMode.all,
    };
  }

  @override
  Stream<Duration> get positionStream => _positionCtl.stream;

  @override
  Stream<Duration?> get durationStream => _durationCtl.stream;

  @override
  Stream<Duration> get bufferedPositionStream => _bufferedCtl.stream;

  @override
  Stream<EnginePlaybackState> get playbackStateStream =>
      _playbackStateCtl.stream;

  @override
  Stream<EngineError> get errorStream => _errorCtl.stream;

  @override
  Stream<int?> get currentIndexStream => _indexCtl.stream;
}
