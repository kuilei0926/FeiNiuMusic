import 'dart:async';

import 'package:media_kit/media_kit.dart' as mk;

import 'player_engine.dart';

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
    final player = mk.Player();
    _player = player;
    _wire(player);
  }

  void _wire(mk.Player player) {
    player.stream.position.listen((v) {
      if (!_positionCtl.isClosed) _positionCtl.add(v);
    });
    player.stream.duration.listen((v) {
      if (!_durationCtl.isClosed) _durationCtl.add(v);
    });
    player.stream.buffer.listen((v) {
      if (!_bufferedCtl.isClosed) _bufferedCtl.add(v);
    });
    player.stream.playing.listen((playing) {
      if (!_playbackStateCtl.isClosed) {
        _playbackStateCtl.add(EnginePlaybackState(
          playing: playing,
          processingState: player.state.buffering
              ? EngineProcessingState.buffering
              : (player.state.completed
                  ? EngineProcessingState.completed
                  : EngineProcessingState.ready),
        ));
      }
    });
    player.stream.buffering.listen((buffering) {
      if (!_playbackStateCtl.isClosed) {
        _playbackStateCtl.add(EnginePlaybackState(
          playing: player.state.playing,
          processingState: buffering
              ? EngineProcessingState.buffering
              : EngineProcessingState.ready,
        ));
      }
    });
    player.stream.completed.listen((completed) {
      if (!_playbackStateCtl.isClosed) {
        _playbackStateCtl.add(EnginePlaybackState(
          playing: player.state.playing,
          processingState: completed
              ? EngineProcessingState.completed
              : EngineProcessingState.ready,
        ));
      }
    });
    player.stream.playlist.listen((playlist) {
      if (!_indexCtl.isClosed) _indexCtl.add(playlist.index);
    });
    player.stream.error.listen((msg) {
      if (_errorCtl.isClosed) return;
      // mpv 错误不带索引；附加当前播放列表索引，让 PlayerService 能定位
      // 失败歌曲并触发恢复/降级。
      final idx = player.state.playlist.index;
      _errorCtl.add(EngineError(
        message: msg,
        index: idx >= 0 && idx < player.state.playlist.medias.length
            ? idx
            : null,
      ));
    });
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
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

  @override
  Future<void> loadQueue({
    required List<EngineItem> items,
    required int index,
    Duration? initialPosition,
    bool preload = false,
  }) async {
    await init();
    final player = _player!;
    final medias = items
        .cast<MediaKitItem>()
        .map((e) => e.media)
        .toList(growable: false);
    final safeIndex = index.clamp(0, medias.length - 1);
    await player.open(
      mk.Playlist(medias, index: safeIndex),
      play: false,
    );
    if (initialPosition != null && initialPosition > Duration.zero) {
      await player.seek(initialPosition);
    }
  }

  @override
  Future<void> play() async {
    final p = _player;
    if (p == null) return;
    await p.play();
  }

  @override
  Future<void> pause() async {
    final p = _player;
    if (p == null) return;
    await p.pause();
  }

  @override
  Future<void> stop() async {
    final p = _player;
    if (p == null) return;
    try {
      await p.stop();
    } catch (_) {}
  }

  @override
  Future<void> seek(Duration position) async {
    final p = _player;
    if (p == null) return;
    await p.seek(position);
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
    await p.open(
      mk.Playlist(medias, index: index),
      play: p.state.playing,
    );
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
  Future<void> moveItem(int from, int to) async {
    final p = _player;
    if (p == null) return;
    await p.move(from, to);
  }

  @override
  Duration get position {
    final p = _player;
    return p?.state.position ?? Duration.zero;
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
  bool get hasLoadedSource => _player != null && _player!.state.playlist.medias.isNotEmpty;

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
  Stream<EnginePlaybackState> get playbackStateStream => _playbackStateCtl.stream;

  @override
  Stream<EngineError> get errorStream => _errorCtl.stream;

  @override
  Stream<int?> get currentIndexStream => _indexCtl.stream;
}
