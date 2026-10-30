import 'package:flutter/material.dart';

import '../../app/services/player_service.dart';
import '../../app/services/lyrics/lyrics_service.dart';
import '../../app/state/song_state.dart';
import '../../pages/player/widgets/player_favorite_button.dart';
import '../feedback/app_toast.dart';
import 'vinyl_disc.dart';

enum VinylSheetAction { queue, fullPlayer }

/// The owner waits for this route's completed future before executing an action.
class VinylPlayerSheet extends StatefulWidget {
  final PlayerService player;
  const VinylPlayerSheet({super.key, required this.player});

  @override
  State<VinylPlayerSheet> createState() => _VinylPlayerSheetState();
}

class _VinylPlayerSheetState extends State<VinylPlayerSheet> {
  bool _leaving = false;
  bool _busy = false;
  double? _dragMs;
  String? _dragSongId;

  void _leave(VinylSheetAction action) {
    if (_leaving) return;
    _leaving = true;
    Navigator.of(context).pop(action);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _leaving) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) AppToast.show(context, '播放操作失败，请重试', type: ToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _time(Duration value) {
    final seconds = value.inSeconds.clamp(0, 359999);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: .72,
      minChildSize: .45,
      maxChildSize: .95,
      expand: false,
      builder: (context, controller) => Material(
        color: scheme.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: '收起播放器',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  const Expanded(
                    child: Text('正在播放', textAlign: TextAlign.center),
                  ),
                  ValueListenableBuilder<SongEntity?>(
                    valueListenable: player.currentSong,
                    builder: (context, song, _) => SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(child: PlayerFavoriteButton(song: song)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<SongEntity?>(
                valueListenable: player.currentSong,
                builder: (context, song, _) => Column(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: player.isPlaying,
                      builder: (context, playing, _) => SizedBox(
                        width: 192,
                        height: 190,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            VinylDisc(song: song, playing: playing, size: 168),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IgnorePointer(
                                child: AnimatedRotation(
                                  turns: playing ? .02 : -.05,
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 300),
                                  alignment: Alignment.topCenter,
                                  child: const Icon(
                                    Icons.show_chart_rounded,
                                    size: 68,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Text(
                      song?.title ?? '选择歌曲开始播放',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      song?.artistDisplayName ?? '',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String?>(
                valueListenable: LyricsService.instance.currentLineText,
                builder: (context, line, _) => Text(
                  line == null || line.trim().isEmpty ? '暂无歌词' : line,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.primary),
                ),
              ),
              const SizedBox(height: 16),
              ValueListenableBuilder<PlaybackSnapshot>(
                valueListenable: player.snapshot,
                builder: (context, snap, _) {
                  final total = snap.duration?.inMilliseconds.toDouble() ?? 0;
                  final validDrag = _dragSongId == snap.song?.id
                      ? _dragMs
                      : null;
                  final current =
                      (validDrag ?? snap.position.inMilliseconds.toDouble())
                          .clamp(0.0, total > 0 ? total : 1.0);
                  return Column(
                    children: [
                      Slider(
                        value: current,
                        min: 0,
                        max: total > 0 ? total : 1,
                        semanticFormatterCallback: (value) =>
                            _time(Duration(milliseconds: value.round())),
                        onChanged: total <= 0 || snap.song == null || _busy
                            ? null
                            : (value) => setState(() {
                                _dragSongId = snap.song?.id;
                                _dragMs = value;
                              }),
                        onChangeEnd: (value) {
                          final id = _dragSongId;
                          setState(() {
                            _dragMs = null;
                            _dragSongId = null;
                          });
                          if (id != null &&
                              player.currentSong.value?.id == id) {
                            _run(
                              () => player.seek(
                                Duration(milliseconds: value.round()),
                              ),
                            );
                          }
                        },
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_time(Duration(milliseconds: current.round()))),
                          Text(
                            total > 0
                                ? _time(Duration(milliseconds: total.round()))
                                : '--:--',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ValueListenableBuilder<PlaybackMode>(
                            valueListenable: player.playbackMode,
                            builder: (context, mode, _) => IconButton(
                              tooltip: switch (mode) {
                                PlaybackMode.shuffle => '随机播放',
                                PlaybackMode.single => '单曲循环',
                                PlaybackMode.loop => '列表循环',
                              },
                              onPressed: _busy
                                  ? null
                                  : () => _run(player.cyclePlaybackMode),
                              icon: Icon(switch (mode) {
                                PlaybackMode.shuffle => Icons.shuffle_rounded,
                                PlaybackMode.single => Icons.repeat_one_rounded,
                                PlaybackMode.loop => Icons.repeat_rounded,
                              }),
                            ),
                          ),
                          IconButton(
                            tooltip: '上一首',
                            onPressed: snap.song == null || _busy
                                ? null
                                : () => _run(player.previous),
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                          SizedBox(
                            width: 64,
                            height: 64,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                padding: EdgeInsets.zero,
                                shape: const CircleBorder(),
                              ),
                              onPressed: snap.song == null || _busy
                                  ? null
                                  : () => _run(player.togglePlayPause),
                              child: snap.isLoading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      snap.isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 32,
                                    ),
                            ),
                          ),
                          IconButton(
                            tooltip: '下一首',
                            onPressed: snap.song == null || _busy
                                ? null
                                : () => _run(player.next),
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                          IconButton(
                            key: const ValueKey('vinyl-sheet-queue'),
                            tooltip: '播放队列',
                            onPressed: () => _leave(VinylSheetAction.queue),
                            icon: const Icon(Icons.queue_music_rounded),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                key: const ValueKey('vinyl-sheet-full-player'),
                onPressed: () => _leave(VinylSheetAction.fullPlayer),
                icon: const Icon(Icons.open_in_full_rounded),
                label: const Text('打开完整播放页'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
