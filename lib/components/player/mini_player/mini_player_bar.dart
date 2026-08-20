import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../app/services/lyrics/lyrics_service.dart';
import '../../../app/services/player_service.dart';
import '../../../app/router/app_router.dart';
import '../../../app/state/settings_state.dart';
import '../../../app/state/song_state.dart';
import '../../../app/theme/app_glass_theme.dart';
import '../../common/artwork_widget.dart';
import '../../common/glass_gate.dart';
import '../../player/lyric_preview.dart';
import '../../../pages/player/player_page.dart';
import '../../../pages/player/widgets/player_bottom_panel.dart';

class MiniPlayerBar extends StatelessWidget {
  static const double estimatedHeight = 70.0;

  final PlayerService player;
  final VoidCallback? onOpenPlayer;
  final VoidCallback? onOpenQueue;
  final EdgeInsetsGeometry padding;
  final double artworkSize;
  final double borderRadius;
  final List<BoxShadow>? boxShadow;
  final bool enableSwipe;
  final Widget? trailing;

  MiniPlayerBar({
    super.key,
    PlayerService? player,
    this.onOpenPlayer,
    this.onOpenQueue,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.artworkSize = 48,
    this.borderRadius = 20,
    this.boxShadow,
    this.enableSwipe = true,
    this.trailing,
  }) : player = player ?? PlayerService.instance;

  @override
  Widget build(BuildContext context) {
    // Follow the same panel blur slider as cards/settings panels so the
    // bottom music bar (which the setting description explicitly names) reacts
    // to the "高斯模糊强度" slider instead of a hardcoded blur.
    return ValueListenableBuilder<bool>(
      valueListenable: AppBackgroundSettings.panelBlurEnabled,
      builder: (context, blurEnabled, _) {
        final baseStrength =
            blurEnabled
                ? AppBackgroundSettings.panelBlurStrength.value
                : 0.0;
        return _buildBar(context, baseStrength);
      },
    );
  }

  Widget _buildBar(BuildContext context, double blurStrength) {
    // Only rebuild the bar chrome when the SONG changes — not on every position
    // tick. Position/playing are consumed by the leaf play-button & subtitle
    // widgets, which have their own snapshot listeners.
    return ValueListenableBuilder<SongEntity?>(
      valueListenable: player.currentSong,
      builder: (context, song, child) {
        final hasSong = song != null;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final openPlayer =
            onOpenPlayer ??
            () {
              final isTabletLayout = AppLayoutSettings.effectiveTabletMode;
              final navigator = Navigator.of(
                context,
                rootNavigator: isTabletLayout,
              );
              navigator.push(_playerRoute());
            };
        final openQueue =
            onOpenQueue ?? () => showPlayerPlaylistSheet(context, player);

        final isDark = theme.brightness == Brightness.dark;
        final isBlurred = blurStrength > 0;
        final bgColor = isBlurred
            ? (isDark
                  ? Colors.black.withValues(alpha: 0.06)
                  : Colors.white.withValues(alpha: 0.08))
            : scheme.surface.withValues(alpha: 0.85);

        final border = Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : scheme.outlineVariant.withValues(alpha: 0.42),
          width: 0.8,
        );

        final defaultShadow = [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.10),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ];

        // 内容层（不含背景）：Material + InkWell + 内部 Row。
        // 玻璃分支直接放进 GlassContainer，由 shader 提供背景；实色分支
        // 外套带底色容器。共用同一子树保证两种外观内容一致。
        final inner = Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(borderRadius),
            onTap: openPlayer,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 7,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // When the drawer squeezes this bar, drop the trailing
                  // queue button and shrink the artwork/play button so the
                  // Row never overflows (which painted overflow stripes).
                  final tight = constraints.maxWidth < 91;
                  final compact = tight || constraints.maxWidth < 145;
                  final resolvedArtworkSize = tight
                      ? 36.0
                      : (compact ? 40.0 : artworkSize);
                  final resolvedArtworkRadius = compact ? 9.0 : 10.0;
                  final playSize = compact ? 34.0 : 38.0;
                  return Row(
                    children: [
                      Expanded(
                        child: MiniPlayerInfo(
                          song: song,
                          enableSwipe: enableSwipe,
                          player: player,
                          onOpenPlayer: openPlayer,
                          // 封面一并放入滑动区域：左右滑动切歌时封面随标题/歌词
                          // 一起位移，而不是只有文字滑动。
                          artwork: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                resolvedArtworkRadius,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: 0.12,
                                  ),
                                  blurRadius: 6,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                            child: MiniPlayerArtwork(
                              song: song,
                              size: resolvedArtworkSize,
                              borderRadius: resolvedArtworkRadius,
                            ),
                          ),
                          artworkGap: tight ? 8 : 11,
                        ),
                      ),
                      SizedBox(width: tight ? 4 : 6),
                      MiniPlayerPlayButton(
                        player: player,
                        size: playSize,
                        enabled: hasSong,
                      ),
                      if (!compact) ...[
                        const SizedBox(width: 4),
                        trailing ??
                            MiniPlayerQueueButton(
                              onPressed: hasSong ? openQueue : null,
                              color: scheme.onSurface,
                            ),
                        const SizedBox(width: 2),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        );

        final content = Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(borderRadius),
            border: border,
          ),
          child: inner,
        );

        // 玻璃面只作为「背景层」：GlassContainer 内不放内容，只放一个占满的
        // 空子层贡献玻璃形状/尺寸。内容（inner，含逐字歌词/进度环）作为
        // Stack 中的兄弟层叠在玻璃之上，与玻璃自己的 RepaintBoundary 分离。
        // 否则逐字歌词每帧重绘都在玻璃的 RepaintBoundary 内，会带动整块
        // 玻璃 blur+shader 重新采样（与下方 original 分支把 BackdropFilter
        // 与内容分层、避免动画触发整页重新模糊是同一思路）。
        final glassSurface = GlassContainer(
          shape: LiquidRoundedRectangle(borderRadius: borderRadius),
          clipBehavior: Clip.antiAlias,
          // 与底栏同款深折射参数，但玻璃罩更透（白 24% → 白 10%）：迷你播放器
          // 是大面积全宽面板，同样不透明度会罩成一片白雾（「像高斯模糊」），
          // 降低罩子后背后内容透出更多、折射可见，才有玻璃的通透感。
          settings: kAppGlassSurfaceSettings.copyWith(
            glassColor: const Color(0x1AFFFFFF),
          ),
          // 独立渲染层 + 尽量走 premium 完整折射管线（Lightweight 2D shader
          // 折射弱，容易退化成只有模糊）。
          useOwnLayer: true,
          quality: GlassQuality.premium,
          child: const SizedBox.expand(),
        );

        return Padding(
          padding: padding,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              boxShadow: boxShadow ?? defaultShadow,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(borderRadius),
              child: GlassGate(
                original: isBlurred
                    ? Stack(
                        children: [
                          // 毛玻璃与内容分层：BackdropFilter 只负责把底下的
                          // 页面背景模糊，内容（含逐字歌词）作为锐利层叠在毛玻璃
                          // 之上。若把内容放进 BackdropFilter 内部，逐字歌词每帧
                          // 动画都会触发整页重新模糊，底栏就会卡顿；分层后动画
                          // 重绘只重绘内容层，不碰模糊层。
                          Positioned.fill(
                            child: RepaintBoundary(
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: blurStrength,
                                  sigmaY: blurStrength,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                          content,
                        ],
                      )
                    : content,
                // 液体玻璃变体：玻璃面采样背后的页面背景做实时模糊，内容层
                // （含逐字歌词动画）作为锐利层叠在玻璃之上、独立于玻璃的
                // RepaintBoundary —— 动画重绘不触发玻璃重新采样。
                glass: Stack(
                  children: [
                    Positioned.fill(child: glassSurface),
                    inner,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Route _playerRoute() {
    return PageRouteBuilder(
      settings: const RouteSettings(name: AppRoutes.player),
      opaque: false,
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, secondaryAnimation) =>
          const PlayerPage(),
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        final offset = Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(curved);
        // Slight scale + fade so the player "lifts" into place rather than just
        // sliding up flatly.
        final scale = Tween<double>(begin: 0.97, end: 1.0).animate(curved);
        final fade = CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        );
        return SlideTransition(
          position: offset,
          child: FadeTransition(
            opacity: fade,
            child: ScaleTransition(
              scale: scale,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class MiniPlayerArtwork extends StatelessWidget {
  final SongEntity? song;
  final double size;
  final double borderRadius;

  const MiniPlayerArtwork({
    super.key,
    required this.song,
    required this.size,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (song == null) {
      return _ArtworkFallback(
        size: size,
        borderRadius: borderRadius,
        color: scheme.surfaceContainerHighest,
      );
    }
    return ArtworkWidget(
      song: song!,
      size: size,
      borderRadius: borderRadius,
      placeholder: _ArtworkFallback(
        size: size,
        borderRadius: borderRadius,
        color: scheme.surfaceContainerHighest,
      ),
    );
  }
}

class _ArtworkFallback extends StatelessWidget {
  final double size;
  final double borderRadius;
  final Color color;

  const _ArtworkFallback({
    required this.size,
    required this.borderRadius,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Center(
        child: Icon(Icons.music_note, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class MiniPlayerInfo extends StatelessWidget {
  final SongEntity? song;
  final bool enableSwipe;
  final PlayerService player;
  final VoidCallback onOpenPlayer;

  /// 封面 widget（可空）。非空时随滑动区域一起位移，使左右滑切歌时封面与
  /// 标题/歌词同步滑动。
  final Widget? artwork;

  /// 封面与标题/歌词之间的间距。
  final double artworkGap;

  const MiniPlayerInfo({
    super.key,
    required this.song,
    required this.enableSwipe,
    required this.player,
    required this.onOpenPlayer,
    this.artwork,
    this.artworkGap = 11,
  });

  @override
  Widget build(BuildContext context) {
    MiniPlayerInfoSettings.ensureLoaded();
    if (!enableSwipe) {
      return _InfoContent(
        song: song,
        player: player,
        onOpenPlayer: onOpenPlayer,
        artwork: artwork,
        artworkGap: artworkGap,
      );
    }
    return _SwipeableInfo(
      song: song,
      player: player,
      onOpenPlayer: onOpenPlayer,
      artwork: artwork,
      artworkGap: artworkGap,
    );
  }
}

class _InfoContent extends StatelessWidget {
  final SongEntity? song;
  final PlayerService player;
  final VoidCallback onOpenPlayer;
  final Widget? artwork;
  final double artworkGap;

  const _InfoContent({
    required this.song,
    required this.player,
    required this.onOpenPlayer,
    this.artwork,
    this.artworkGap = 11,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (song == null) {
      final noSongText = Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '未选择歌曲',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
      final artwork = this.artwork;
      if (artwork == null) {
        return noSongText;
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          artwork,
          SizedBox(width: artworkGap),
          Expanded(child: noSongText),
        ],
      );
    }
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          song!.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        ValueListenableBuilder<bool>(
          valueListenable: MiniPlayerInfoSettings.showLyricsInSubtitle,
          builder: (context, showLyrics, _) {
            return ValueListenableBuilder<String?>(
              valueListenable: LyricsService.instance.currentLineText,
              builder: (context, currentLyric, _) {
                final lyric = currentLyric?.trim() ?? '';
                final subtitle = showLyrics && lyric.isNotEmpty
                    ? lyric
                    : song!.artistDisplayName;
                return _MiniPlayerSubtitleText(
                  text: subtitle,
                  useProgressMarquee: showLyrics && lyric.isNotEmpty,
                  style: const TextStyle(fontSize: 11.5),
                );
              },
            );
          },
        ),
      ],
    );
    final artwork = this.artwork;
    if (artwork == null) {
      return info;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        artwork,
        SizedBox(width: artworkGap),
        Expanded(child: info),
      ],
    );
  }
}

class _SwipeableInfo extends StatefulWidget {
  final SongEntity? song;
  final PlayerService player;
  final VoidCallback onOpenPlayer;
  final Widget? artwork;
  final double artworkGap;

  const _SwipeableInfo({
    required this.song,
    required this.player,
    required this.onOpenPlayer,
    this.artwork,
    this.artworkGap = 11,
  });

  @override
  State<_SwipeableInfo> createState() => _SwipeableInfoState();
}

class _SwipeableInfoState extends State<_SwipeableInfo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double>? _animation;
  double _dragOffsetX = 0;
  VoidCallback? _animationCompleted;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed ||
              status == AnimationStatus.dismissed) {
            final cb = _animationCompleted;
            _animationCompleted = null;
            _animation = null;
            if (cb != null) {
              cb();
            }
          }
        });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _runAnimation({
    required double begin,
    required double end,
    Curve curve = Curves.easeOut,
    Duration duration = const Duration(milliseconds: 200),
    VoidCallback? onCompleted,
  }) {
    _controller.duration = duration;
    _animation = Tween<double>(
      begin: begin,
      end: end,
    ).animate(CurvedAnimation(parent: _controller, curve: curve));
    _animationCompleted = onCompleted;
    _controller.forward(from: 0);
  }

  void _animateBack() {
    final begin = _dragOffsetX;
    _runAnimation(
      begin: begin,
      end: 0,
      curve: Curves.easeOutCubic,
      duration: const Duration(milliseconds: 260),
      onCompleted: () {
        if (mounted) {
          setState(() {
            _dragOffsetX = 0;
          });
        } else {
          _dragOffsetX = 0;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSong = widget.song != null;
    final scheme = Theme.of(context).colorScheme;
    // 滑动提示：右滑（上一曲）→ 左侧浮现「上一曲」；左滑（下一曲）→
    // 右侧浮现「下一曲」。提示固定贴条的两端（不随内容位移），滑动时
    // 在原位淡入，松手/回弹时随内容一起淡出。
    final hintStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
      letterSpacing: 0.5,
    );
    final hintBg = BoxDecoration(
      color: scheme.primary.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(999),
    );

    return ClipRect(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onOpenPlayer,
        onHorizontalDragUpdate: (details) {
          if (!hasSong) return;
          setState(() {
            final delta = details.primaryDelta ?? 0;
            _dragOffsetX = (_dragOffsetX + delta).clamp(-80.0, 80.0);
          });
        },
        onHorizontalDragEnd: (details) {
          if (!hasSong) {
            _animateBack();
            return;
          }
          final offset = _dragOffsetX;
          const threshold = 60.0;
          if (offset.abs() >= threshold) {
            if (offset < 0) {
              widget.player.next();
            } else {
              widget.player.previous();
            }
          }
          _animateBack();
        },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            // 用动画值（回弹期间）否则用拖动值（拖动中），
            // 让提示随回弹动画一起淡出，而不是动画结束才消失。
            final currentOffset = _animation?.value ?? _dragOffsetX;
            final prevOpacity =
                hasSong && currentOffset > 0
                    ? (currentOffset / 60.0).clamp(0.0, 1.0)
                    : 0.0;
            final nextOpacity =
                hasSong && currentOffset < 0
                    ? ((-currentOffset) / 60.0).clamp(0.0, 1.0)
                    : 0.0;
            return Stack(
              children: [
                // 左侧「上一曲」提示：右滑时在原位淡入
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: prevOpacity,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: hintBg,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.skip_previous_rounded,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 4),
                              Text('上一曲', style: hintStyle),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 右侧「下一曲」提示：左滑时在原位淡入
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: nextOpacity,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: hintBg,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('下一曲', style: hintStyle),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.skip_next_rounded,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 可滑动内容：随位移移动（带动画回弹）
                Align(
                  alignment: Alignment.centerLeft,
                  child: Transform.translate(
                    offset: Offset(currentOffset, 0),
                    child: child,
                  ),
                ),
              ],
            );
          },
          child: _InfoContent(
            song: widget.song,
            player: widget.player,
            onOpenPlayer: widget.onOpenPlayer,
            artwork: widget.artwork,
            artworkGap: widget.artworkGap,
          ),
        ),
      ),
    );
  }
}

class _MiniPlayerSubtitleText extends StatelessWidget {
  final String text;
  final bool useProgressMarquee;
  final TextStyle style;

  const _MiniPlayerSubtitleText({
    required this.text,
    required this.useProgressMarquee,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    if (!useProgressMarquee || text.trim().isEmpty) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    final lyrics = LyricsService.instance;
    final model = lyrics.controller.lyricNotifier.value;
    final index = lyrics.controller.activeIndexNotifiter.value;
    if (model == null || index < 0 || index >= model.lines.length) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final line = model.lines[index];
    if (line.text.trim().isEmpty) {
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }

    // 与播放页/歌词页完全相同的逐字渲染管线（LyricView + LyricLineHightlightMixin）。
    // activeLineOnly 只绘制当前播放行，单行高度即成为迷你单行逐字歌词，
    // 逐字动画与播放页逐帧一致。
    final baseFontSize = style.fontSize ?? 11.5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        // 超长歌词：LyricView 的行 TextPainter 无 maxLines:1，会在容器宽度内
        // 自动换行成两行，而这里裁剪到单行高度会把第二行中间截断。检测到
        // 超宽时按比例缩小字号，保证歌词单行放下，保留逐字动画与完整内容。
        // 若缩小到下限仍放不下（极端超长），回退单行省略号避免"两行裁中间"。
        final (fontSize, fits) = _measureFit(
          text: text,
          baseFontSize: baseFontSize,
          maxWidth: available,
        );
        if (!fits) {
          return Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        return LyricPreview(
          height: fontSize * 1.3,
          textAlign: TextAlign.start,
          contentAlignment: CrossAxisAlignment.start,
          showTranslation: false,
          fontSize: fontSize,
          activeFontSize: fontSize,
          contentPadding: EdgeInsets.zero,
          activeLineOnly: true,
        );
      },
    );
  }

  /// 测量歌词单行宽度，超出 [maxWidth] 时按比例缩小字号。
  /// 返回 (目标字号, 是否单行放得下)。
  ///
  /// 注意必须用「加粗字重」测量：LyricPreview 的当前播放行以
  /// FontWeight.w700 渲染（见 lyric_preview.dart 的 activeStyle），加粗字比
  /// 常规字更宽。若用常规字重测量，会误判「刚好放得下」而实际渲染溢出，
  /// 触发 LyricLayout.compute 折行成两行，被单行窗口裁到两行中间（半截字）。
  /// 额外留 2% 安全边距兜底字距/绘制舍入等微小偏差。
  (double, bool) _measureFit({
    required String text,
    required double baseFontSize,
    required double maxWidth,
  }) {
    double widthAt(double size) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: style.copyWith(fontSize: size, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    final fitWidth = maxWidth * 0.98;
    if (widthAt(baseFontSize) <= fitWidth || maxWidth <= 0) {
      return (baseFontSize, true);
    }
    final ratio = fitWidth / widthAt(baseFontSize);
    final shrunk = (baseFontSize * ratio).clamp(baseFontSize * 0.6, baseFontSize);
    // 缩小到下限后仍超宽 → 放不下，回退省略号
    if (widthAt(shrunk) > fitWidth) {
      return (baseFontSize, false);
    }
    return (shrunk, true);
  }
}

class MiniPlayerPlayButton extends StatelessWidget {
  final PlayerService player;
  final double size;
  final bool enabled;

  const MiniPlayerPlayButton({
    super.key,
    required this.player,
    required this.size,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<PlaybackSnapshot>(
      valueListenable: player.snapshot,
      builder: (context, snapshot, child) {
        final totalMs = snapshot.duration?.inMilliseconds ?? 0;
        final progress = totalMs <= 0
            ? 0.0
            : snapshot.position.inMilliseconds / totalMs;
        final playing = snapshot.isPlaying;
        final loading = snapshot.isLoading;
        return SizedBox(
          width: size,
          height: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: size,
                  height: size,
                  child: CircularProgressIndicator(
                    value: enabled ? progress.clamp(0.0, 1.0) : 0.0,
                    strokeWidth: 1.8,
                    backgroundColor: scheme.outline.withValues(alpha: 0.12),
                    color: scheme.primary,
                    strokeCap: StrokeCap.round,
                  ),
                ),
                if (loading && enabled)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: scheme.primary,
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(
                      playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: scheme.onSurface,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: enabled ? player.togglePlayPause : null,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class MiniPlayerQueueButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Color color;

  const MiniPlayerQueueButton({
    super.key,
    required this.onPressed,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton(
        icon: Icon(Icons.queue_music_rounded, color: color, size: 24),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: onPressed,
      ),
    );
  }
}
