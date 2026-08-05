import 'package:flutter/foundation.dart';
import 'package:signals/signals.dart';
import 'song_state.dart';
import '../services/player/player_engine.dart';

enum PlaybackMode {
  shuffle,
  loop,
  single,
}

class PlaybackSnapshot {
  final SongEntity? song;
  final List<SongEntity> queue;
  final int index;
  final bool isPlaying;
  final bool isLoading;
  final Duration position;
  final Duration? duration;
  final Duration bufferedPosition;

  const PlaybackSnapshot({
    required this.song,
    required this.queue,
    required this.index,
    required this.isPlaying,
    this.isLoading = false,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
  });

  factory PlaybackSnapshot.initial() {
    return const PlaybackSnapshot(
      song: null,
      queue: [],
      index: -1,
      isPlaying: false,
      isLoading: false,
      position: Duration.zero,
      duration: null,
      bufferedPosition: Duration.zero,
    );
  }
}

class AppPlayerState {
  // Singleton pattern to be easily accessible, but also can be instantiated if needed
  static final AppPlayerState instance = AppPlayerState._internal();

  AppPlayerState._internal() {
    _initListeners();
  }

  // ValueNotifiers (for Flutter UI binding if needed directly)
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration?> duration = ValueNotifier(null);
  final ValueNotifier<Duration> bufferedPosition = ValueNotifier(Duration.zero);
  final ValueNotifier<bool> isPlaying = ValueNotifier(false);
  final ValueNotifier<bool> isLoading = ValueNotifier(false);
  final ValueNotifier<List<SongEntity>> queue = ValueNotifier(const []);
  final ValueNotifier<int> currentIndex = ValueNotifier(-1);
  final ValueNotifier<SongEntity?> currentSong = ValueNotifier(null);
  final ValueNotifier<PlaybackSnapshot> snapshot =
      ValueNotifier(PlaybackSnapshot.initial());
  final ValueNotifier<PlaybackMode> playbackMode =
      ValueNotifier(PlaybackMode.loop);
  final ValueNotifier<String?> sleepTimerDisplayText = ValueNotifier(null);
  final ValueNotifier<bool> sleepUntilSongEnd = ValueNotifier(false);

  /// 当前歌曲使用的解码引擎（just_audio / media_kit）。
  /// UI 在"更多面板"展示当前解码方式。
  final ValueNotifier<EngineKind> decoderEngine =
      ValueNotifier(EngineKind.justAudio);

  // Signals (for reactive state management)
  final positionSignal = signal(Duration.zero);
  final durationSignal = signal<Duration?>(null);
  final bufferedPositionSignal = signal(Duration.zero);
  final isPlayingSignal = signal(false);
  final isLoadingSignal = signal(false);
  final queueSignal = signal<List<SongEntity>>([]);
  final currentIndexSignal = signal(-1);
  final currentSongSignal = signal<SongEntity?>(null);
  final snapshotSignal = signal(PlaybackSnapshot.initial());
  final playbackModeSignal = signal(PlaybackMode.loop);
  final sleepTimerDisplayTextSignal = signal<String?>(null);
  final sleepUntilSongEndSignal = signal(false);
  final decoderEngineSignal = signal(EngineKind.justAudio);

  void _initListeners() {
    position.addListener(() => positionSignal.value = position.value);
    duration.addListener(() => durationSignal.value = duration.value);
    bufferedPosition.addListener(
      () => bufferedPositionSignal.value = bufferedPosition.value,
    );
    isPlaying.addListener(() => isPlayingSignal.value = isPlaying.value);
    isLoading.addListener(() => isLoadingSignal.value = isLoading.value);
    queue.addListener(() => queueSignal.value = queue.value);
    currentIndex.addListener(
        () => currentIndexSignal.value = currentIndex.value);
    currentSong.addListener(
        () => currentSongSignal.value = currentSong.value);
    snapshot.addListener(() => snapshotSignal.value = snapshot.value);
    playbackMode.addListener(
      () => playbackModeSignal.value = playbackMode.value,
    );
    sleepTimerDisplayText.addListener(
      () => sleepTimerDisplayTextSignal.value = sleepTimerDisplayText.value,
    );
    sleepUntilSongEnd.addListener(
      () => sleepUntilSongEndSignal.value = sleepUntilSongEnd.value,
    );
    decoderEngine.addListener(() {
      decoderEngineSignal.value = decoderEngine.value;
    });
  }
  
  void dispose() {
    position.dispose();
    duration.dispose();
    bufferedPosition.dispose();
    isPlaying.dispose();
    isLoading.dispose();
    queue.dispose();
    currentIndex.dispose();
    currentSong.dispose();
    snapshot.dispose();
    playbackMode.dispose();
    sleepTimerDisplayText.dispose();
    sleepUntilSongEnd.dispose();
    decoderEngine.dispose();
  }
}
