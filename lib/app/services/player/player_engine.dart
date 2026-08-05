import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart' as mk;

/// 播放引擎抽象。目前存在两种实现：
/// - [JustAudioEngine]：ExoPlayer（MediaCodec），处理 MP3/AAC/Opus 等。
/// - MediaKitEngine：libmpv + FFmpeg，处理 FLAC/DSF 等。
///
/// PlayerService 持有唯一逻辑队列，把队列交给当前曲目所属引擎播放；
/// 引擎切换只在歌曲边界发生。
///
/// 接口统一为**引擎无关**的归一化类型（EngineProcessingState / EnginePlaybackState
/// / EngineError / EngineLoopMode），两个引擎内部各自把原生状态翻译过来。
/// 队列条目用 sealed [EngineItem]（[JustAudioItem] / [MediaKitItem]），
/// 已按引擎路由好，不会混用。
abstract interface class PlayerEngine {
  EngineKind get kind;

  /// 创建原生播放器并做好默认配置。幂等，可重复调用。
  Future<void> init();

  Future<void> dispose();

  /// 将整队已路由到本引擎的条目交给播放器。[index] 为引擎内索引。
  Future<void> loadQueue({
    required List<EngineItem> items,
    required int index,
    Duration? initialPosition,
    bool preload = false,
  });

  // ---- 传输控制 ----
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> seekToNext();
  Future<void> seekToPrevious();

  /// 跳到引擎内指定索引并从头播放。
  Future<void> skipToIndex(int index);
  Future<void> setLoopMode(EngineLoopMode mode);
  Future<void> setVolume(double volume);

  // ---- 队列原地修改（同 run 增量路径） ----
  Future<void> insertItem(int index, EngineItem item);
  Future<void> insertItems(int index, List<EngineItem> items);
  Future<void> moveItem(int from, int to);

  // ---- 查询 ----
  Duration get position;
  int? get currentIndex;
  int get sequenceLength;
  bool get hasLoadedSource;
  bool get playing;
  EngineProcessingState get processingState;
  EngineLoopMode get loopMode;

  // ---- 归一化流（引擎内部持有原生订阅，向上转发） ----
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<Duration> get bufferedPositionStream;
  Stream<EnginePlaybackState> get playbackStateStream;
  Stream<EngineError> get errorStream;
  Stream<int?> get currentIndexStream;
}

/// 引擎类型：决定歌曲由哪个播放引擎解码。
enum EngineKind { justAudio, mediaKit }

/// 引擎内播放处理状态（归一化，隐藏 just_audio / media_kit 差异）。
enum EngineProcessingState { idle, loading, ready, buffering, completed }

/// 引擎播放状态快照（归一化）。
class EnginePlaybackState {
  final bool playing;
  final EngineProcessingState processingState;
  const EnginePlaybackState({required this.playing, required this.processingState});
}

/// 引擎错误（归一化）。[index] 为引擎内索引，未知/当前曲为 null。
class EngineError {
  final String message;
  final int? index;
  const EngineError({required this.message, this.index});
}

/// 循环/重复模式（归一化）。
enum EngineLoopMode {
  /// 播放到队尾即停（不自动回卷）。跨引擎回卷由 PlayerService 逻辑层驱动。
  none,

  /// 单曲循环。
  single,

  /// 整个队列循环。
  all,
}

/// 已为特定引擎解析好的队列条目。
sealed class EngineItem {}

/// just_audio 的队列条目：一个 [AudioSource]（直连流 / 缓存文件 / 缓存源）。
class JustAudioItem extends EngineItem {
  final AudioSource source;
  JustAudioItem(this.source);
}

/// media_kit 的队列条目：一个 [Media]（URL + httpHeaders）。
class MediaKitItem extends EngineItem {
  final mk.Media media;
  MediaKitItem(this.media);
}
