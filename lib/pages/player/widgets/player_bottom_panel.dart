import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../../app/router/app_page_route.dart';
import '../../../app/router/app_router.dart';
import '../../../app/services/lyrics/lyrics_service.dart';
import '../../../app/services/player_service.dart';
import '../../../app/state/settings_state.dart';
import '../../../app/state/song_state.dart';
import '../../../components/common/artwork_widget.dart';
import '../../../components/common/labeled_slider.dart';
import '../../../components/common/playing_bars.dart';
import '../../../components/feedback/app_toast.dart';
import '../../../components/player/lyric_preview.dart';
import '../../library/library_detail_pages.dart';
import '../../songs/song_detail_sheet.dart';
import 'player_background.dart';

class PlayerBottomPanel extends StatelessWidget {
  final PlayerService player;
  final PlayerStylePreset stylePreset;
  final VoidCallback onTapLyrics;
  final bool showMiniLyrics;
  final FocusNode? bottomPanelFocus;

  const PlayerBottomPanel({
    super.key,
    required this.player,
    required this.stylePreset,
    required this.onTapLyrics,
    this.showMiniLyrics = true,
    this.bottomPanelFocus,
  });

  @override
  Widget build(BuildContext context) {
    PlayerBottomActionSettings.ensureLoaded();
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomSpacing = bottomInset > 20 ? bottomInset + 16.0 : 30.0;
    // 包一层 Focus 作为 TV 遥控下键的落点句柄：自身不可聚焦/不可遍历，
    // 只用于 TvPlayerFocusScope 找底部操作栏第一个按钮。
    return Focus(
      focusNode: bottomPanelFocus,
      canRequestFocus: false,
      skipTraversal: true,
      child: Column(
        children: [
          if (showMiniLyrics)
            _MiniLyricsPreview(onTap: onTapLyrics, stylePreset: stylePreset),
          _PlayerSeekBar(player: player, stylePreset: stylePreset),
          const SizedBox(height: 20),
          PlayerControls(player: player, stylePreset: stylePreset),
          const SizedBox(height: 30),
          BottomActions(player: player, stylePreset: stylePreset),
          SizedBox(height: bottomSpacing),
        ],
      ),
    );
  }
}

class _MiniLyricsPreview extends StatefulWidget {
  final VoidCallback onTap;
  final PlayerStylePreset stylePreset;

  const _MiniLyricsPreview({required this.onTap, required this.stylePreset});

  @override
  State<_MiniLyricsPreview> createState() => _MiniLyricsPreviewState();
}

class _MiniLyricsPreviewState extends State<_MiniLyricsPreview>
    with SignalsMixin {
  static const String _prefsMiniEnabled = 'mini_lyrics_enabled';
  static const String _prefsShowTranslation = 'lyrics_view_show_translation';
  static const String _prefsMiniAlignment = 'mini_lyrics_alignment';

  late final _enabled = createSignal(true);
  late final _showTranslation = createSignal(true);
  late final _alignment = createSignal('center');

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    LyricsService.instance.viewSettingsTick.addListener(_onSettingsTick);
  }

  @override
  void dispose() {
    LyricsService.instance.viewSettingsTick.removeListener(_onSettingsTick);
    super.dispose();
  }

  void _onSettingsTick() {
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _enabled.value = prefs.getBool(_prefsMiniEnabled) ?? true;
    _showTranslation.value = prefs.getBool(_prefsShowTranslation) ?? true;
    _alignment.value = prefs.getString(_prefsMiniAlignment) ?? 'center';
  }

  @override
  Widget build(BuildContext context) {
    // Theme 在 Watch.builder 外捕获：signals 的 computed 在元素卸载后仍可能因
    // 歌词/播放状态更新而重算 builder，此时 context 已 deactivated，
    // 在 builder 内调 Theme.of 会抛 "Looking up a deactivated widget's ancestor"。
    final scheme = Theme.of(context).colorScheme;
    return Watch.builder(
      builder: (context) {
        if (!_enabled.value) {
          return const SizedBox.shrink();
        }
        final lyrics = LyricsService.instance;
        final snap = lyrics.snapshotSignal.value;
        final model = lyrics.lyricModelSignal.value;
        final lines = model?.lines ?? const <LyricLine>[];
        final alignment = _alignment.value;
        final previewHeight = switch (widget.stylePreset) {
          PlayerStylePreset.poster => 118.0,
          PlayerStylePreset.classic => 110.0,
        };
        final textAlign = alignment == 'left'
            ? TextAlign.left
            : alignment == 'right'
            ? TextAlign.right
            : TextAlign.center;
        final crossAlign = alignment == 'left'
            ? CrossAxisAlignment.start
            : alignment == 'right'
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.center;

        return Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: SizedBox(
                  height: previewHeight,
                  child: Center(
                    child: () {
                      // While loading a new song's lyrics, keep the area blank
                      // (no skeleton) — show the real lines as soon as they
                      // arrive. If lyrics are already present, keep showing them.
                      if (snap.status == LyricsLoadStatus.loading &&
                          lines.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      if (lines.isEmpty) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '暂无歌词',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: scheme.onSurface.withValues(alpha: 0.9),
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '纯音乐或未匹配到歌词',
                              style: TextStyle(
                                fontSize: 14,
                                color: scheme.onSurfaceVariant.withValues(
                                  alpha: 0.6,
                                ),
                              ),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        );
                      }

                      // 复用歌词页的 LyricView 渲染管线（AnimationController 驱动 +
                      // CustomPainter 高亮），保证与歌词页一致的流畅逐字动画。
                      return LyricPreview(
                        height: previewHeight,
                        textAlign: textAlign,
                        contentAlignment: crossAlign,
                        showTranslation: _showTranslation.value,
                        fontSize: 15,
                        activeFontSize: 18,
                        // 上下边缘渐隐，歌词行滑出边界时淡出而非硬截断
                        fadeEdges: true,
                      );
                    }(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _PlayerSeekBar extends StatefulWidget {
  final PlayerService player;
  final PlayerStylePreset stylePreset;

  const _PlayerSeekBar({required this.player, required this.stylePreset});

  @override
  State<_PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<_PlayerSeekBar> with SignalsMixin {
  late final _dragValue = createSignal<double?>(null);

  String _format(Duration? duration) {
    final total = duration?.inSeconds ?? 0;
    if (total <= 0) return '00:00';
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    // Theme 在 Watch.builder 外捕获：signals 的 computed 在元素卸载后仍可能因
    // position/buffered 更新而重算 builder，此时 context 已 deactivated，
    // 在 builder 内调 Theme.of 会抛 "Looking up a deactivated widget's ancestor"。
    final scheme = Theme.of(context).colorScheme;
    return Watch.builder(
      builder: (context) {
        final position = widget.player.positionSignal.value;
        final duration = widget.player.durationSignal.value;
        final buffered = widget.player.bufferedPositionSignal.value;
        final trackHeight = switch (widget.stylePreset) {
          PlayerStylePreset.poster => 4.0,
          PlayerStylePreset.classic => 2.0,
        };
        final totalMs = duration?.inMilliseconds ?? 0;
        final max = totalMs <= 0 ? 1.0 : totalMs.toDouble();
        final currentMs = position.inMilliseconds.clamp(0, max.toInt()).toInt();
        final sliderValue = _dragValue.value ?? currentMs.toDouble();
        final bufferedRatio = totalMs > 0
            ? (buffered.inMilliseconds / totalMs).clamp(0.0, 1.0)
            : 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              SizedBox(
                height: 24,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 缓冲进度（轨道下层半透明条）
                    // horizontal: 12 与 Slider 轨道两端内缩（overlayRadius=12）对齐
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10.5,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: bufferedRatio,
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation(
                              scheme.onSurface.withValues(alpha: 0.18),
                            ),
                            minHeight: 3,
                          ),
                        ),
                      ),
                    ),
                    // 播放进度滑块
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: trackHeight,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                        activeTrackColor: scheme.onSurface,
                        inactiveTrackColor: scheme.onSurfaceVariant.withValues(
                          alpha: 0.25,
                        ),
                        thumbColor: scheme.onSurface,
                      ),
                      child: Slider(
                        value: sliderValue.clamp(0, max).toDouble(),
                        min: 0,
                        max: max,
                        onChanged: totalMs <= 0
                            ? null
                            : (value) => _dragValue.value = value,
                        onChangeEnd: totalMs <= 0
                            ? null
                            : (value) {
                                _dragValue.value = null;
                                widget.player.seek(
                                  Duration(milliseconds: value.round()),
                                );
                              },
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _format(Duration(milliseconds: currentMs)),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                    Text(
                      _format(duration),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class PlayerControls extends StatelessWidget {
  final PlayerService player;
  final PlayerStylePreset stylePreset;

  const PlayerControls({
    super.key,
    required this.player,
    required this.stylePreset,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTv = AppLayoutSettings.tvMode.value;
    final iconColor = scheme.primary.withValues(alpha: 0.86);
    final buttonBg = scheme.primaryContainer.withValues(alpha: 0.92);
    final mainButtonSize = switch (stylePreset) {
      PlayerStylePreset.poster => isTv ? 88.0 : 72.0,
      PlayerStylePreset.classic => isTv ? 80.0 : 64.0,
    };
    return Watch.builder(
      builder: (context) {
        final playing = player.isPlayingSignal.value;
        final loading = player.isLoadingSignal.value;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: isTv ? 64 : 48,
              icon: Icon(Icons.skip_previous_rounded, color: iconColor),
              onPressed: player.previous,
            ),
            SizedBox(width: isTv ? 28 : 20),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: buttonBg,
              ),
              child: IconButton(
                iconSize: mainButtonSize,
                // TV 模式进播放页默认聚焦播放按钮：OK 即暂停，下键走自然遍历。
                autofocus: AppLayoutSettings.tvMode.value,
                icon: loading
                    ? SizedBox(
                        width: mainButtonSize,
                        height: mainButtonSize,
                        child: CircularProgressIndicator(
                          strokeWidth: mainButtonSize * 0.055,
                          color: scheme.onPrimaryContainer,
                        ),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: scheme.onPrimaryContainer,
                      ),
                onPressed: player.togglePlayPause,
              ),
            ),
            const SizedBox(width: 20),
            IconButton(
              iconSize: isTv ? 64 : 48,
              icon: Icon(Icons.skip_next_rounded, color: iconColor),
              onPressed: player.next,
            ),
          ],
        );
      },
    );
  }
}

class BottomActions extends StatelessWidget {
  final PlayerService player;
  final PlayerStylePreset stylePreset;

  const BottomActions({
    super.key,
    required this.player,
    required this.stylePreset,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = scheme.onSurfaceVariant.withValues(alpha: 0.85);
    return Watch.builder(
      builder: (context) {
        final mode = player.playbackModeSignal.value;
        final text = player.sleepTimerDisplayTextSignal.value;
        final icon = switch (mode) {
          PlaybackMode.shuffle => Icons.shuffle,
          PlaybackMode.loop => Icons.repeat,
          PlaybackMode.single => Icons.repeat_one,
        };
        return AnimatedBuilder(
          animation: Listenable.merge([
            PlayerBottomActionSettings.showPlaybackMode,
            PlayerBottomActionSettings.showSleepTimer,
            PlayerBottomActionSettings.showPlaylist,
            PlayerBottomActionSettings.showMore,
            PlayerBottomActionSettings.actionOrder,
          ]),
          builder: (context, _) {
            final actions = <Widget>[];
            final order = PlayerBottomActionSettings.actionOrder.value;
            for (final key in order) {
              switch (key) {
                case 'playback_mode':
                  if (PlayerBottomActionSettings.showPlaybackMode.value) {
                    actions.add(
                      IconButton(
                        icon: Icon(icon, color: iconColor),
                        onPressed: () => player.cyclePlaybackMode(),
                      ),
                    );
                  }
                  break;
                case 'sleep_timer':
                  if (PlayerBottomActionSettings.showSleepTimer.value) {
                    actions.add(
                      Stack(
                        alignment: Alignment.center,
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            icon: Icon(Icons.alarm, color: iconColor),
                            onPressed: () => _showSleepTimerSheet(context),
                          ),
                          if (text != null)
                            Positioned(
                              bottom: -8,
                              child: Text(
                                text,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: iconColor.withValues(alpha: 0.8),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }
                  break;
                case 'playlist':
                  if (PlayerBottomActionSettings.showPlaylist.value) {
                    actions.add(
                      IconButton(
                        icon: Icon(
                          Icons.format_list_bulleted,
                          color: iconColor,
                        ),
                        onPressed: () => _showPlaylistSheet(context),
                      ),
                    );
                  }
                  break;
                default:
                  if (PlayerBottomActionSettings.showMore.value) {
                    actions.add(
                      IconButton(
                        icon: Icon(Icons.more_horiz, color: iconColor),
                        onPressed: () => _showSongDetailSheet(context),
                      ),
                    );
                  }
                  break;
              }
            }
            if (actions.isEmpty) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: actions,
              ),
            );
          },
        );
      },
    );
  }

  void _showSleepTimerSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SleepTimerSheet(player: player),
    );
  }

  void _showPlaylistSheet(BuildContext context) {
    showPlayerPlaylistSheet(context, player);
  }

  void _showSongDetailSheet(BuildContext context) {
    final song = player.currentSong.value;
    if (song == null) {
      AppToast.show(context, '暂无歌曲');
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SongDetailSheet(
        song: song,
        // 播放器右下角「⋯」打开：显示音量/倍速/解码器等播放控制
        showPlayerControls: true,
        onOpenPlayerAppearanceSettings: () {
          Navigator.of(context).pushNamed(AppRoutes.playerAppearanceSettings);
        },
        onOpenArtist: (artistName) {
          Navigator.of(context).push(
            buildAppPageRoute(
              (_) => ArtistDetailPage(
                artistName: artistName,
                artistGuid: song.firstArtistGuid,
              ),
            ),
          );
        },
        onOpenAlbum: (albumName) {
          Navigator.of(context).push(
            buildAppPageRoute(
              (_) => AlbumDetailPage(
                albumName: albumName,
                albumGuid: song.albumGuid,
              ),
            ),
          );
        },
      ),
    );
  }
}

void showPlayerPlaylistSheet(BuildContext context, PlayerService player) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _PlaylistSheet(player: player),
  );
}

Color _primaryTextColor(bool useDarkText) {
  return useDarkText
      ? Colors.black.withValues(alpha: 0.88)
      : Colors.white.withValues(alpha: 0.92);
}

Color _secondaryTextColor(bool useDarkText, double alpha) {
  return useDarkText
      ? Colors.black.withValues(alpha: alpha)
      : Colors.white.withValues(alpha: alpha);
}

class _PlayerSheetView extends StatelessWidget {
  final PlayerService player;
  final double height;
  final Color maskColor;
  final Color dragHandleColor;
  final Widget header;
  final Widget body;

  const _PlayerSheetView({
    required this.player,
    required this.height,
    required this.maskColor,
    required this.dragHandleColor,
    required this.header,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: Stack(
          children: [
            PlayerBackground(songSignal: player.currentSongSignal),
            RepaintBoundary(
              child: ValueListenableBuilder<bool>(
                valueListenable: AppBackgroundSettings.panelBlurEnabled,
                builder: (context, blurEnabled, _) {
                  return ValueListenableBuilder<double>(
                    valueListenable: AppBackgroundSettings.panelBlurStrength,
                    builder: (context, blurStrength, _) {
                      final effective = blurEnabled ? blurStrength : 0.0;
                      final mask = Container(color: maskColor);
                      if (effective <= 0) return mask;
                      return RepaintBoundary(
                        child: BackdropFilter(
                          filter: ui.ImageFilter.blur(
                            sigmaX: effective,
                            sigmaY: effective,
                          ),
                          child: mask,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Column(
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 32,
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: dragHandleColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                header,
                body,
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SleepTimerSheet extends StatefulWidget {
  final PlayerService player;

  const _SleepTimerSheet({required this.player});

  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> with SignalsMixin {
  late final _minutes = createSignal(30.0);

  @override
  void initState() {
    super.initState();
    final remaining = widget.player.sleepRemaining;
    if (remaining != null && remaining > const Duration(minutes: 1)) {
      _minutes.value = remaining.inMinutes.clamp(5, 120).toDouble();
    }
  }

  String _formatMinutes(num minutes) {
    final totalMinutes = minutes.round();
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    return '$hours:${mins.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final preferLightBackground =
        Theme.of(context).brightness == Brightness.light;
    final useDarkText = preferLightBackground;
    final textColor = _primaryTextColor(useDarkText);
    final secondaryTextColor = _secondaryTextColor(useDarkText, 0.7);
    final maskColor = Theme.of(context).colorScheme.surface;

    final sheetHeight = MediaQuery.sizeOf(context).height * 0.4;
    return Watch.builder(
      builder: (context) {
        final minutes = _minutes.value;
        final untilSongEnd = widget.player.sleepUntilSongEndSignal.value;
        final text = widget.player.sleepTimerDisplayTextSignal.value;
        final isActive = text != null && text.isNotEmpty;
        return SafeArea(
          child: _PlayerSheetView(
            player: widget.player,
            height: sheetHeight,
            maskColor: maskColor,
            dragHandleColor: secondaryTextColor.withValues(alpha: 0.2),
            header: _SleepTimerHeader(
              textColor: textColor,
              secondaryTextColor: secondaryTextColor,
            ),
            body: Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LabeledSlider(
                        title: '定时时长',
                        value: minutes,
                        min: 5,
                        max: 120,
                        divisions: 115,
                        tickCount: 116,
                        valueText: _formatMinutes(minutes),
                        label: '${minutes.round()} 分钟',
                        onChanged: (v) => _minutes.value = v,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '播完整首歌后关闭',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: textColor),
                            ),
                          ),
                          Switch.adaptive(
                            value: untilSongEnd,
                            onChanged: (value) {
                              if (value) {
                                widget.player.setSleepTimerToSongEnd();
                              } else {
                                widget.player.cancelSleepTimer();
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () {
                            Navigator.pop(context);
                            widget.player.setSleepTimer(
                              Duration(minutes: minutes.round()),
                            );
                          },
                          child: const Text('开始定时'),
                        ),
                      ),
                      if (isActive)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Center(
                            child: TextButton(
                              onPressed: () {
                                Navigator.pop(context);
                                widget.player.cancelSleepTimer();
                              },
                              child: const Text('取消定时'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SleepTimerHeader extends StatelessWidget {
  final Color textColor;
  final Color secondaryTextColor;

  const _SleepTimerHeader({
    required this.textColor,
    required this.secondaryTextColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: SizedBox(
            height: 34,
            child: Center(
              child: Text(
                '定时',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          color: secondaryTextColor.withValues(alpha: 0.18),
        ),
      ],
    );
  }
}

class _PlaylistSheet extends StatefulWidget {
  final PlayerService player;

  const _PlaylistSheet({required this.player});

  @override
  State<_PlaylistSheet> createState() => _PlaylistSheetState();
}

class _PlaylistSheetState extends State<_PlaylistSheet> {
  static const double _itemExtent = 64;
  late final ScrollController _controller;
  int _lastIndex = -1;

  double _calcOffset(int index, int length) {
    if (index <= 0 || length <= 0) return 0;
    final startIndex = (index - 2).clamp(0, length - 1);
    return startIndex * _itemExtent;
  }

  @override
  void initState() {
    super.initState();
    _lastIndex = widget.player.currentIndexSignal.value;
    _controller = ScrollController(
      initialScrollOffset: _calcOffset(
        _lastIndex,
        widget.player.queueSignal.value.length,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 快速调整播放队列长度上限：弹出滑块对话框，改完立即全局生效。
  void _showQueueLimitDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => _QueueLimitDialog(player: widget.player),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preferLightBackground =
        Theme.of(context).brightness == Brightness.light;
    final useDarkText = preferLightBackground;
    final textColor = _primaryTextColor(useDarkText);
    final secondaryTextColor = _secondaryTextColor(useDarkText, 0.7);
    final maskColor = scheme.surface;
    // Theme / MediaQuery 在 Watch.builder 外捕获：signals 的 computed 在元素
    // 卸载后仍可能重算 builder，此时在 builder 内访问继承组件会抛
    // "Looking up a deactivated widget's ancestor"，被包装成 SignalEffectException。
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.8;

    return Watch.builder(
      builder: (context) {
        final queue = widget.player.queueSignal.value;
        final currentIndex = widget.player.currentIndexSignal.value;
        final mode = widget.player.playbackModeSignal.value;
        final playing = widget.player.isPlayingSignal.value;
        // 漫游队列由服务端随机链驱动，不允许删除歌曲；本地随机仍可删除。
        final roamActive = widget.player.roamActive;
        final total = queue.length;
        final current = currentIndex >= 0 ? currentIndex + 1 : 0;
        if (currentIndex != _lastIndex && currentIndex >= 0) {
          _lastIndex = currentIndex;
          final offset = _calcOffset(_lastIndex, total);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_controller.hasClients) {
              _controller.animateTo(
                offset,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
              );
            }
          });
        }

        return SafeArea(
          child: _PlayerSheetView(
            player: widget.player,
            height: sheetHeight,
            maskColor: maskColor,
            dragHandleColor: secondaryTextColor.withValues(alpha: 0.2),
            header: _PlaylistHeader(
              total: total,
              current: current,
              mode: mode,
              roamActive: roamActive,
              accent: scheme.primary,
              textColor: textColor,
              secondaryTextColor: secondaryTextColor,
              onClear: widget.player.clearQueue,
              onCycleMode: widget.player.cyclePlaybackMode,
              onAdjustLimit: () => _showQueueLimitDialog(context),
            ),
            body: Expanded(
              child: total == 0
                  ? Center(
                      child: Text(
                        '暂无歌曲',
                        style: TextStyle(color: secondaryTextColor),
                      ),
                    )
                  : RepaintBoundary(
                      child: Column(
                        children: [
                          if (mode == PlaybackMode.shuffle)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    size: 14,
                                    color: secondaryTextColor.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '随机模式下由系统随机选歌，队列不可排序',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: secondaryTextColor.withValues(
                                          alpha: 0.7,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: ReorderableListView.builder(
                              scrollController: _controller,
                              itemExtent: _itemExtent,
                              buildDefaultDragHandles: false,
                              proxyDecorator: (child, index, animation) {
                                return AnimatedBuilder(
                                  animation: animation,
                                  builder: (context, child) {
                                    final animValue = Curves.easeInOut.transform(
                                      animation.value,
                                    );
                                    final elevation = ui.lerpDouble(
                                      0,
                                      6,
                                      animValue,
                                    )!;
                                    return Material(
                                      elevation: elevation,
                                      color: Colors.transparent,
                                      shadowColor: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      child: child,
                                    );
                                  },
                                  child: child,
                                );
                              },
                              // 随机（漫游）模式下队列顺序无意义，禁用拖拽排序。
                              // 注意不能传 null：ReorderableListView.builder 的构造
                              // 断言要求 onReorderItem 非 null（否则断言失败，且因
                              // 处于 Watch.builder 内会被包装成 SignalEffectException）。
                              onReorderItem: (oldIndex, newIndex) {
                                if (mode == PlaybackMode.shuffle) return;
                                widget.player.reorderQueue(
                                  oldIndex,
                                  newIndex,
                                );
                              },
                              itemCount: total,
                              itemBuilder: (context, index) {
                                if (index < 0 || index >= queue.length) {
                                  return const SizedBox.shrink();
                                }
                                final song = queue[index];
                                final isCurrent = index == currentIndex;
                                return RepaintBoundary(
                                  key: ValueKey('${song.id}_$index'),
                                  child: _QueueItem(
                                    song: song,
                                    index: index,
                                    isCurrent: isCurrent,
                                    playing: playing,
                                    canDelete: !roamActive,
                                    canReorder: mode != PlaybackMode.shuffle,
                                    accent: scheme.primary,
                                    textColor: textColor,
                                    secondaryTextColor: secondaryTextColor,
                                    onTap: () => widget.player.skipToIndex(
                                      index,
                                    ),
                                    onRemove: () => widget.player
                                        .removeFromQueue(index),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _PlaylistHeader extends StatelessWidget {
  final int total;
  final int current;
  final PlaybackMode mode;
  final bool roamActive;
  final Color textColor;
  final Color secondaryTextColor;
  final Color accent;
  final VoidCallback onClear;
  final VoidCallback onCycleMode;
  final VoidCallback onAdjustLimit;

  const _PlaylistHeader({
    required this.total,
    required this.current,
    required this.mode,
    required this.roamActive,
    required this.textColor,
    required this.secondaryTextColor,
    required this.accent,
    required this.onClear,
    required this.onCycleMode,
    required this.onAdjustLimit,
  });

  @override
  Widget build(BuildContext context) {
    final (IconData modeIcon, String modeLabel) = switch (mode) {
      PlaybackMode.shuffle => (Icons.shuffle_rounded, '随机播放'),
      PlaybackMode.single => (Icons.repeat_one_rounded, '单曲循环'),
      PlaybackMode.loop => (Icons.repeat_rounded, '列表循环'),
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '播放队列',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 3),
                    InkWell(
                      onTap: onCycleMode,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: 2,
                          bottom: 2,
                          right: 6,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(modeIcon, size: 16, color: secondaryTextColor),
                            const SizedBox(width: 5),
                            Text(
                              '$modeLabel · $current/$total',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: secondaryTextColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onAdjustLimit,
                style: TextButton.styleFrom(
                  foregroundColor: secondaryTextColor,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  Icons.tune_rounded,
                  size: 18,
                  color: secondaryTextColor,
                ),
                label: Text(
                  '上限',
                  style: TextStyle(fontSize: 13, color: secondaryTextColor),
                ),
              ),
              // 漫游模式队列由服务端随机链驱动，不允许手动清空，隐藏清空按钮。
              if (!roamActive)
                TextButton.icon(
                  onPressed: onClear,
                  style: TextButton.styleFrom(
                    foregroundColor: secondaryTextColor,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    Icons.delete_sweep_rounded,
                    size: 19,
                    color: secondaryTextColor,
                  ),
                  label: Text(
                    '清空',
                    style: TextStyle(fontSize: 13, color: secondaryTextColor),
                  ),
                ),
            ],
          ),
        ),
        Container(
          height: 1,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          color: secondaryTextColor.withValues(alpha: 0.18),
        ),
      ],
    );
  }
}

/// A single row in the play-queue sheet: cover thumbnail + title/artist, with a
/// highlighted background and animated equalizer bars for the current song.
class _QueueItem extends StatelessWidget {
  final SongEntity song;
  final int index;
  final bool isCurrent;
  final bool playing;
  final bool canDelete;
  final bool canReorder;
  final Color accent;
  final Color textColor;
  final Color secondaryTextColor;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueItem({
    required this.song,
    required this.index,
    required this.isCurrent,
    required this.playing,
    required this.canDelete,
    required this.canReorder,
    required this.accent,
    required this.textColor,
    required this.secondaryTextColor,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = isCurrent ? accent : textColor;
    final artistColor = isCurrent
        ? accent.withValues(alpha: 0.78)
        : secondaryTextColor.withValues(alpha: 0.82);
    final artist = song.artistDisplayName.isEmpty
        ? '未知歌手'
        : song.artistDisplayName;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Material(
        color: isCurrent ? accent.withValues(alpha: 0.13) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
            child: Row(
              children: [
                _buildCover(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title.trim().isEmpty ? '未知歌曲' : song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 15,
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: artistColor, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (canDelete)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.close_rounded,
                      color: secondaryTextColor.withValues(alpha: 0.8),
                      size: 20,
                    ),
                    onPressed: onRemove,
                  ),
                if (canReorder)
                  ReorderableDelayedDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.drag_handle_rounded,
                        color: secondaryTextColor.withValues(alpha: 0.55),
                        size: 20,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover() {
    const size = 44.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ArtworkWidget(song: song, size: size, borderRadius: 8),
          if (isCurrent)
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.black.withValues(alpha: 0.38),
              ),
              child: Center(
                child: PlayingBars(color: Colors.white, animating: playing),
              ),
            ),
        ],
      ),
    );
  }
}

/// 播放队列长度上限快速调整对话框：拖动滑块即改即存，全局生效。
class _QueueLimitDialog extends StatelessWidget {
  final PlayerService player;

  const _QueueLimitDialog({required this.player});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('播放队列上限'),
      content: ValueListenableBuilder<int>(
        valueListenable: AppPlaybackQueueSettings.maxQueueLength,
        builder: (context, limit, _) {
          return SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前队列 ${player.queue.value.length} 首 · 上限 $limit 首',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Slider(
                  value: limit.toDouble().clamp(
                        AppPlaybackQueueSettings.minQueueLimit.toDouble(),
                        AppPlaybackQueueSettings.maxQueueLimit.toDouble(),
                      ),
                  min: AppPlaybackQueueSettings.minQueueLimit.toDouble(),
                  max: AppPlaybackQueueSettings.maxQueueLimit.toDouble(),
                  divisions:
                      (AppPlaybackQueueSettings.maxQueueLimit -
                              AppPlaybackQueueSettings.minQueueLimit) ~/
                          10,
                  label: '$limit 首',
                  onChanged: (value) {
                    AppPlaybackQueueSettings.setMaxQueueLength(value.round());
                  },
                ),
                Text(
                  '队列超出上限时自动裁剪，对后续播放全局生效',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 海报模式播放控件：模式 + 上一首/播放/下一首 + 更多（含操作栏入口）。
class PosterControls extends StatelessWidget {
  final PlayerService player;

  /// 是否让首尾图标对齐轨道两端（海报页封面侧：顺序播放 / 更多 落在进度条
  /// 两端，配合外层 [_posterTrackInset] 内缩与轨道对齐）。歌词页保持
  /// 居中分布（spaceAround）不变。
  final bool alignToTrack;

  const PosterControls({
    super.key,
    required this.player,
    this.alignToTrack = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconColor = scheme.onSurface.withValues(alpha: 0.72);
    return Watch.builder(
      builder: (context) {
        final playing = player.isPlayingSignal.value;
        final mode = player.playbackModeSignal.value;
        final modeIcon = switch (mode) {
          PlaybackMode.shuffle => Icons.shuffle_rounded,
          PlaybackMode.loop => Icons.repeat_rounded,
          PlaybackMode.single => Icons.repeat_one_rounded,
        };
        return Row(
          mainAxisAlignment: alignToTrack
              ? MainAxisAlignment.spaceBetween
              : MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              iconSize: 30,
              color: iconColor,
              icon: Icon(modeIcon),
              onPressed: player.cyclePlaybackMode,
            ),
            IconButton(
              iconSize: 40,
              color: iconColor,
              icon: const Icon(Icons.skip_previous_rounded),
              onPressed: player.previous,
            ),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.onSurface,
              ),
              child: IconButton(
                iconSize: 36,
                color: scheme.surface,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                onPressed: player.togglePlayPause,
              ),
            ),
            IconButton(
              iconSize: 40,
              color: iconColor,
              icon: const Icon(Icons.skip_next_rounded),
              onPressed: player.next,
            ),
            IconButton(
              iconSize: 30,
              color: iconColor,
              icon: const Icon(Icons.more_vert_rounded),
              onPressed: () => showPosterSongDetailSheet(context, player),
            ),
          ],
        );
      },
    );
  }
}

/// 海报模式底部「更多」按钮：弹出歌曲详情面板
void showPosterSongDetailSheet(BuildContext context, PlayerService player) {
  final song = player.currentSong.value;
  if (song == null) {
    AppToast.show(context, '暂无歌曲');
    return;
  }
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => SongDetailSheet(
      song: song,
      // 海报模式底部「更多」：显示播放控制
      showPlayerControls: true,
      onOpenPlayerAppearanceSettings: () {
        Navigator.of(context).pushNamed(AppRoutes.playerAppearanceSettings);
      },
      onOpenArtist: (artistName) {
        Navigator.of(context).push(
          buildAppPageRoute(
            (_) => ArtistDetailPage(
              artistName: artistName,
              artistGuid: song.firstArtistGuid,
            ),
          ),
        );
      },
      onOpenAlbum: (albumName) {
        Navigator.of(context).push(
          buildAppPageRoute(
            (_) => AlbumDetailPage(
              albumName: albumName,
              albumGuid: song.albumGuid,
            ),
          ),
        );
      },
    ),
  );
}
