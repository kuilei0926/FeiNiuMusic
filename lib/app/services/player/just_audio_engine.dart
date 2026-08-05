import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'player_engine.dart';

/// [PlayerEngine] 的 just_audio（ExoPlayer / MediaCodec）实现。
///
/// 薄封装：持有唯一的 just_audio [AudioPlayer]，把所有方法与流归一化转发。
///
/// `useProxyForRequestHeaders: false` 让 HLS/音频源的请求头（Cookie）由
/// Android ExoPlayer 原生发送（DefaultHttpDataSource），而不是走 just_audio
/// 的 Dart 本地代理（代理不解析 `#EXT-X-MAP`，且会用 Dart HttpClient 连 NAS
/// IPv6 导致不可达）。
class JustAudioEngine implements PlayerEngine {
  JustAudioEngine() : _player = AudioPlayer(useProxyForRequestHeaders: false);

  final AudioPlayer _player;

  @override
  EngineKind get kind => EngineKind.justAudio;

  @override
  Future<void> init() async {
    // ExoPlayer 无需额外初始化；原生流由 PlayerService 订阅本引擎的转发流。
  }

  @override
  Future<void> dispose() => _player.dispose();

  @override
  Future<void> loadQueue({
    required List<EngineItem> items,
    required int index,
    Duration? initialPosition,
    bool preload = false,
  }) {
    final sources = items
        .cast<JustAudioItem>()
        .map((e) => e.source)
        .toList(growable: false);
    return _player.setAudioSources(
      sources,
      initialIndex: index,
      initialPosition: initialPosition,
      preload: preload,
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> seekToNext() => _player.seekToNext();

  @override
  Future<void> seekToPrevious() => _player.seekToPrevious();

  @override
  Future<void> skipToIndex(int index) =>
      _player.seek(Duration.zero, index: index);

  @override
  Future<void> setLoopMode(EngineLoopMode mode) {
    final loop = switch (mode) {
      EngineLoopMode.single => LoopMode.one,
      EngineLoopMode.all => LoopMode.all,
      EngineLoopMode.none => LoopMode.off,
    };
    return _player.setLoopMode(loop);
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> insertItem(int index, EngineItem item) =>
      _player.insertAudioSource(index, (item as JustAudioItem).source);

  @override
  Future<void> insertItems(int index, List<EngineItem> items) {
    final sources = items
        .cast<JustAudioItem>()
        .map((e) => e.source)
        .toList(growable: false);
    return _player.insertAudioSources(index, sources);
  }

  @override
  Future<void> moveItem(int from, int to) => _player.moveAudioSource(from, to);

  @override
  Duration get position => _player.position;

  @override
  int? get currentIndex => _player.currentIndex;

  @override
  int get sequenceLength => _player.sequence.length;

  @override
  bool get hasLoadedSource => _player.audioSource != null;

  @override
  bool get playing => _player.playing;

  @override
  EngineProcessingState get processingState => switch (_player.processingState) {
        ProcessingState.idle => EngineProcessingState.idle,
        ProcessingState.loading => EngineProcessingState.loading,
        ProcessingState.ready => EngineProcessingState.ready,
        ProcessingState.buffering => EngineProcessingState.buffering,
        ProcessingState.completed => EngineProcessingState.completed,
      };

  @override
  EngineLoopMode get loopMode => switch (_player.loopMode) {
        LoopMode.off => EngineLoopMode.none,
        LoopMode.one => EngineLoopMode.single,
        LoopMode.all => EngineLoopMode.all,
      };

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<Duration> get bufferedPositionStream =>
      _player.bufferedPositionStream;

  @override
  Stream<EnginePlaybackState> get playbackStateStream =>
      _player.playerStateStream.map((s) => EnginePlaybackState(
            playing: s.playing,
            processingState: switch (s.processingState) {
              ProcessingState.idle => EngineProcessingState.idle,
              ProcessingState.loading => EngineProcessingState.loading,
              ProcessingState.ready => EngineProcessingState.ready,
              ProcessingState.buffering => EngineProcessingState.buffering,
              ProcessingState.completed => EngineProcessingState.completed,
            },
          ));

  @override
  Stream<EngineError> get errorStream => _player.errorStream.map(
      (e) => EngineError(message: e.message ?? '', index: e.index));

  @override
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
}
