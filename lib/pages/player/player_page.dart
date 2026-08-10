import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_model.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/favorite_service.dart';
import '../../app/services/lyrics/lyrics_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../app/state/song_state.dart';
import '../../app/utils/route_visibility.dart';
import '../../components/common/artwork_widget.dart';
import '../../components/feedback/app_toast.dart';
import '../../components/player/lyric_preview.dart';
import 'lyrics/lyric_view.dart';
import 'widgets/player_background.dart';
import 'widgets/player_bottom_panel.dart';
import 'widgets/player_header.dart';
import 'tv_player_focus_scope.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  final PlayerService _player = PlayerService.instance;
  final PageController _pageController = PageController();
  late final AnimationController _dismissController;
  // Drives only the dismiss transform wrapper, so dragging doesn't rebuild the
  // whole player tree (background, header, lyrics, controls) every frame.
  final ValueNotifier<double> _dismissOffset = ValueNotifier(0);
  double? _dismissDragStartY;

  /// TV 遥控下键的落点：底部操作栏（随机/定时等按钮）的焦点节点。
  final FocusNode _bottomPanelFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 播放页路由激活标记：TV 模式据此隐藏侧栏与迷你播放器。
    // 延迟到首帧后设置：initState 在 build 阶段执行，此时直接改
    // playerRouteActive 会通知祖先的 ValueListenableBuilder 触发
    // markNeedsBuild → "setState() called during build" 崩溃
    // （栈：_PlayerPageState.initState → _ValueListenableBuilderState._valueChanged）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        AppLayoutSettings.playerRouteActive.value = true;
      }
    });
    _dismissController =
        AnimationController.unbounded(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          if (!mounted) return;
          _dismissOffset.value = _dismissController.value;
        });
  }

  void _handleDismissDragStart(DragStartDetails details) {
    _dismissController.stop();
    _dismissDragStartY = details.globalPosition.dy;
  }

  void _handleDismissDragUpdate(DragUpdateDetails details) {
    final startY = _dismissDragStartY;
    if (startY == null) return;
    final offset = details.globalPosition.dy - startY;
    if (offset <= 0) return;
    final maxOffset = MediaQuery.sizeOf(context).height;
    final clamped = offset.clamp(0.0, maxOffset);
    _dismissOffset.value = clamped;
    _dismissController.value = clamped;
  }

  void _handleDismissDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss = _dismissOffset.value > 72 || velocity > 700;
    final startOffset = _dismissOffset.value;
    _dismissDragStartY = null;
    if (shouldDismiss) {
      final screenHeight = MediaQuery.sizeOf(context).height;
      final remaining = (screenHeight - startOffset).clamp(120.0, screenHeight);
      _dismissController.duration = Duration(
        milliseconds: velocity > 0
            ? (remaining / velocity * 1000).clamp(120, 240).round()
            : 180,
      );
      _dismissController.value = startOffset;
      _dismissController
          .animateTo(screenHeight, curve: Curves.easeOutCubic)
          .whenComplete(() {
            if (!mounted) return;
            _closePlayer();
          });
      return;
    }
    _dismissController.duration = const Duration(milliseconds: 220);
    _dismissController.value = startOffset;
    _dismissController.animateBack(0, curve: Curves.easeOutCubic);
  }

  void _handleDismissDragCancel() {
    if (_dismissOffset.value == 0) return;
    _dismissDragStartY = null;
    _dismissController.duration = const Duration(milliseconds: 220);
    _dismissController.value = _dismissOffset.value;
    _dismissController.animateBack(0, curve: Curves.easeOutCubic);
  }

  void _closePlayer() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (rootNavigator.canPop()) {
      rootNavigator.pop();
      return;
    }
    // 自动打开场景：PlayerPage 是唯一路由，回到首页
    navigator.pushReplacementNamed(AppRoutes.home);
  }

  @override
  void dispose() {
    _dismissController.dispose();
    _pageController.dispose();
    _dismissOffset.dispose();
    _bottomPanelFocus.dispose();
    // 卸载阶段（finalizeTree → _unmountAll）widget tree 已锁定，这里直接给
    // playerRouteActive 赋值会 notify 仍挂在树上的祖先 ValueListenableBuilder
    // （tablet_layout_host）→ markNeedsBuild → "setState() called when widget
    // tree was locked"。且异常中断 _unmountAll，播放页子树残留未卸载。
    // 与 initState 对称，延迟到帧后写，避开锁定期。
    final routeActive = AppLayoutSettings.playerRouteActive;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      routeActive.value = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统返回键：可退时正常 pop，不可退时（自动打开场景）走 _closePlayer 回到首页
    final isTv = AppLayoutSettings.tvMode.value;
    final Widget page = PopScope(
      canPop: Navigator.of(context).canPop(),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closePlayer();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: ValueListenableBuilder<double>(
          valueListenable: _dismissOffset,
          builder: (context, dragOffset, child) {
            final dismissProgress = (dragOffset / 120).clamp(0.0, 1.0);
            return Transform.translate(
              offset: Offset(0, dragOffset),
              child: Opacity(
                opacity: 1 - dismissProgress * 0.08,
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(dismissProgress * 24),
                  ),
                  child: child,
                ),
              ),
            );
          },
          child: Stack(
            children: [
              RepaintBoundary(
                child: PlayerBackground(songSignal: _player.currentSongSignal),
              ),
              PlayerTheme(
                child: ValueListenableBuilder<PlayerStylePreset>(
                  valueListenable: PlayerStyleSettings.stylePreset,
                  builder: (context, stylePreset, _) {
                    final isPoster = stylePreset == PlayerStylePreset.poster;
                    // 平板横屏：桌面式布局（左侧封面+控制、右侧歌词块），
                    // 自带顶部 header，外层全宽 header 隐藏，避免重复占位
                    // 把右侧歌词块推到下方留出大片空白。
                    final mq = MediaQuery.of(context);
                    final isTabletLandscape =
                        AppLayoutSettings.effectiveTabletMode &&
                        (AppLayoutSettings.tvMode.value ||
                            mq.orientation == Orientation.landscape) &&
                        mq.size.width >= 900;
                    // Poster 关闭顶部/底部 SafeArea 让封面延伸到屏幕边缘
                    // （覆盖状态栏/导航栏），歌词页再手动补回 inset 避免文字
                    // 滑入系统栏下方。
                    final topInset = MediaQuery.paddingOf(context).top;
                    final bottomInset = MediaQuery.paddingOf(context).bottom;
                    return SafeArea(
                      top: !isPoster && !isTabletLandscape,
                      bottom: !isPoster,
                      child: Column(
                        children: [
                          GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onVerticalDragStart: _handleDismissDragStart,
                            onVerticalDragUpdate: _handleDismissDragUpdate,
                            onVerticalDragEnd: _handleDismissDragEnd,
                            onVerticalDragCancel: _handleDismissDragCancel,
                            child: isPoster || isTabletLandscape
                                ? const SizedBox.shrink()
                                : PlayerHeader(
                                    songSignal: _player.currentSongSignal,
                                    stylePreset: stylePreset,
                                  ),
                          ),
                          Expanded(
                            child: PageView(
                              controller: _pageController,
                              onPageChanged: (page) {
                                // 离开歌词页（切回封面页）时释放全局拖动选中状态：
                                // LyricController 是全局单例，歌词页拖动选中后若直接
                                // 横滑回封面页，残留状态会传染给共享 controller 的
                                // 歌词预览（底栏迷你歌词/海报预览）。
                                if (page != 1) {
                                  LyricsService.instance.controller
                                      .stopSelection();
                                }
                              },
                              children: [
                                _PlayerView(
                                  player: _player,
                                  bottomPanelFocus: _bottomPanelFocus,
                                  onTapLyrics: () =>
                                      _pageController.animateToPage(
                                        1,
                                        duration: const Duration(
                                          milliseconds: 280,
                                        ),
                                        curve: Curves.easeOut,
                                      ),
                                ),
                                isPoster
                                    ? Padding(
                                        // SafeArea 已关闭，歌词页手动补回顶部/底部 inset，
                                        // 防止歌词行滑入状态栏或系统导航栏下方。
                                        padding: EdgeInsets.only(
                                          top: topInset,
                                          bottom: bottomInset,
                                        ),
                                        child: const PlayerLyricsView(
                                          showControls: true,
                                          fadeEdges: true,
                                        ),
                                      )
                                    : const PlayerLyricsView(
                                        showControls: true,
                                        fadeEdges: true,
                                      ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Windows 桌面端没有系统返回键，播放页左上角放一个返回按钮，
              // 点击关闭播放页（等价于手机的下滑返回/系统返回）。其他平台不显示。
              if (Platform.isWindows)
                Positioned(
                  top: 8,
                  left: 12,
                  child: SafeArea(
                    child: IconButton(
                      tooltip: '返回',
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      icon: Icon(
                        Icons.arrow_back_rounded,
                        size: 24,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.72),
                      ),
                      onPressed: _closePlayer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!isTv) return page;
    // TV 模式：包播放页遥控焦点域（OK 播放暂停 / 长按切歌 / 下键落底部操作栏）。
    return TvPlayerFocusScope(
      bottomActionsFocusNode: _bottomPanelFocus,
      onTogglePlayPause: () => _player.togglePlayPause(),
      onPrevious: _player.previous,
      onNext: _player.next,
      child: page,
    );
  }
}

class _PlayerView extends StatelessWidget {
  final PlayerService player;
  final VoidCallback onTapLyrics;
  final FocusNode? bottomPanelFocus;

  const _PlayerView({
    required this.player,
    required this.onTapLyrics,
    this.bottomPanelFocus,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PlayerStylePreset>(
      valueListenable: PlayerStyleSettings.stylePreset,
      builder: (context, stylePreset, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
          builder: (context, effectiveTabletMode, _) {
            final mq = MediaQuery.of(context);
            // TV 恒横屏，无需 orientation 门；普通平板仍需横屏 + 宽度门槛。
            final isTabletLandscape =
                effectiveTabletMode &&
                (AppLayoutSettings.tvMode.value ||
                    mq.orientation == Orientation.landscape) &&
                mq.size.width >= 900;
            if (!isTabletLandscape) {
              if (stylePreset == PlayerStylePreset.poster) {
                return _PosterPlayerLayout(player: player);
              }
              return _MobilePlayerLayout(
                player: player,
                stylePreset: stylePreset,
                onTapLyrics: onTapLyrics,
                bottomPanelFocus: bottomPanelFocus,
              );
            }
            return _TabletLandscapePlayerLayout(
              player: player,
              stylePreset: stylePreset,
              onTapLyrics: onTapLyrics,
              bottomPanelFocus: bottomPanelFocus,
            );
          },
        );
      },
    );
  }
}

class _MobilePlayerLayout extends StatelessWidget {
  final PlayerService player;
  final PlayerStylePreset stylePreset;
  final VoidCallback onTapLyrics;
  final FocusNode? bottomPanelFocus;

  const _MobilePlayerLayout({
    required this.player,
    required this.stylePreset,
    required this.onTapLyrics,
    this.bottomPanelFocus,
  });

  @override
  Widget build(BuildContext context) {
    // 封面占满「面板上方」的全部剩余空间并居中；封面本身会按可用高度收缩
    // （见 _PlayerArtwork），矮屏/大字体机型下也不会把下方控制区挤出屏幕。
    return Column(
      children: [
        Expanded(
          child: Center(
            child: _PlayerArtwork(
              songSignal: player.currentSongSignal,
              stylePreset: stylePreset,
            ),
          ),
        ),
        PlayerBottomPanel(
          player: player,
          stylePreset: stylePreset,
          onTapLyrics: onTapLyrics,
          bottomPanelFocus: bottomPanelFocus,
        ),
      ],
    );
  }
}

class _TabletLandscapePlayerLayout extends StatelessWidget {
  final PlayerService player;
  final PlayerStylePreset stylePreset;
  final VoidCallback onTapLyrics;
  final FocusNode? bottomPanelFocus;

  const _TabletLandscapePlayerLayout({
    required this.player,
    required this.stylePreset,
    required this.onTapLyrics,
    this.bottomPanelFocus,
  });

  @override
  Widget build(BuildContext context) {
    const lyricRadius = 24.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Column(
              children: [
                const Spacer(),
                Expanded(
                  flex: 8,
                  child: Center(
                    child: _PlayerArtwork(
                      songSignal: player.currentSongSignal,
                      stylePreset: stylePreset,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                PlayerHeader(
                  songSignal: player.currentSongSignal,
                  stylePreset: stylePreset,
                ),
                const SizedBox(height: 8),
                // Playback controls were missing entirely in tablet landscape.
                // Reuse the panel (without its mini-lyrics, since full lyrics
                // already show on the right).
                PlayerBottomPanel(
                  player: player,
                  stylePreset: stylePreset,
                  onTapLyrics: onTapLyrics,
                  showMiniLyrics: false,
                  bottomPanelFocus: bottomPanelFocus,
                ),
                const Spacer(),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(lyricRadius),
              child: Container(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.16),
                child: const PlayerLyricsView(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterPlayerLayout extends StatelessWidget {
  final PlayerService player;

  const _PosterPlayerLayout({required this.player});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mq = MediaQuery.of(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // 海报大封面高度：默认取屏幕 46%（与 1.4.1 一致），但矮屏/大字体机型
    // 下必须给底部控制区留足空间，否则底部内容溢出被裁掉。
    final heroIdeal = (mq.size.height * 0.46).clamp(270.0, 430.0);
    final heroMax = mq.size.height - 356.0;
    final hero = heroIdeal > heroMax ? heroMax : heroIdeal;
    final headerPad = mq.size.height < 760 ? 12.0 : 18.0;
    final bottomPad = bottomInset > 20 ? bottomInset + 8.0 : 18.0;
    return Watch.builder(
      builder: (context) {
        final song = player.currentSongSignal.value;
        final title = song?.title.trim().isNotEmpty == true
            ? song!.title.trim()
            : '未知歌曲';
        final artist = song?.artistDisplayName.isNotEmpty == true
            ? song!.artistDisplayName
            : '未知歌手';
        return Column(
          children: [
            _PosterArtwork(
              songSignal: player.currentSongSignal,
              player: player,
              heroHeight: hero,
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(
                  24,
                  headerPad,
                  24,
                  bottomPad,
                ),
                // Transparent so the cover-color + 流光 background shows through,
                // matching the lyrics page (no solid white panel).
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeletonizer(
                      enabled: song == null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 23,
                              fontWeight: FontWeight.w800,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: scheme.onSurface.withValues(alpha: 0.86),
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 歌词预览：弹性占满「标题之下、控制区之上」的剩余空间，
                    // 空间不足时收缩（含收缩到 0），底栏永不溢出。
                    const SizedBox(height: 12),
                    Expanded(
                      child: Skeletonizer(
                        enabled: song == null,
                        child: _PosterLyricsPreview(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 收藏 / 队列按钮（与 1.4.1 一致，位于进度条上方）
                    _PosterMetaRow(player: player, song: song),
                    const SizedBox(height: 2),
                    _PosterSeekBar(player: player),
                    const SizedBox(height: 20),
                    PosterControls(player: player),
                    // 底部留白：让控制栏整体抬离屏幕底部
                    SizedBox(height: bottomInset > 20 ? 16 : 28),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PosterArtwork extends StatelessWidget {
  final Signal<SongEntity?> songSignal;
  final PlayerService player;

  /// 封面高度（由 [PosterPlayerLayout] 按屏幕高度与底部预留计算）。
  final double heroHeight;

  const _PosterArtwork({
    required this.songSignal,
    required this.player,
    required this.heroHeight,
  });

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        final song = songSignal.value;
        return SizedBox(
          height: heroHeight,
          width: double.infinity,
          // Fade the cover's bottom to transparent so it dissolves into the
          // cover-color + 流光 background below (instead of a hard edge / white).
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0.0, 0.72, 1.0],
            ).createShader(rect),
            child: Stack(
              fit: StackFit.expand,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    // 防御：尺寸钳制为正的有限值，避免横竖屏切换/首帧瞬态时
                    // boxSize 为 0 或 NaN，连锁导致 ShaderMask/RotationTransition
                    // 产生 Matrix4 非有限值 / RRect NaN 崩溃。
                    final maxW = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : 0.0;
                    final maxH = constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : 0.0;
                    final boxSize = (maxW > maxH ? maxW : maxH).clamp(1.0, 2000.0);
                    final child = song == null
                        ? Skeletonizer(
                            enabled: true,
                            child: _ArtworkPlaceholder(
                              border: BorderRadius.zero,
                              label: '',
                            ),
                          )
                        : ArtworkWidget(
                            song: song,
                            size: boxSize,
                            // 海报模式为大封面全屏布局：无论「圆形封面」开关如何
                            // 均整幅方形铺满、不旋转（旋转仅对圆形封面有意义）。
                            borderRadius: 0,
                            preferOriginal: true,
                            keepPreviousUntilLoaded: true,
                            placeholder: Skeletonizer(
                              enabled: true,
                              child: _ArtworkPlaceholder(
                                border: BorderRadius.zero,
                                label: song.title,
                              ),
                            ),
                          );
                    return ClipRect(
                      child: OverflowBox(
                        maxWidth: boxSize,
                        maxHeight: boxSize,
                        child: child,
                      ),
                    );
                  },
                ),
                // Subtle top scrim so status-bar icons stay legible over art.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x1A000000), Colors.transparent],
                      stops: [0.0, 0.22],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PosterLyricsPreview extends StatelessWidget {
  const _PosterLyricsPreview();

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        final lyrics = LyricsService.instance;
        final snap = lyrics.snapshotSignal.value;
        final model = lyrics.lyricModelSignal.value;
        final lines = model?.lines ?? const <LyricLine>[];
        // No skeleton: keep blank while loading a new song's lyrics, show the
        // real lines as soon as they arrive.
        if (snap.status == LyricsLoadStatus.loading && lines.isEmpty) {
          return const SizedBox.shrink();
        }
        if (lines.isEmpty) {
          // Don't echo the song title/artist here — they already show in the
          // header above; use neutral placeholders to avoid duplication.
          return const Align(
            alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PosterLyricLine(text: '暂无歌词', active: true),
                SizedBox(height: 8),
                _PosterLyricLine(text: '纯音乐或未匹配到歌词', active: false),
                SizedBox(height: 8),
                _PosterLyricLine(text: ' ', active: false),
              ],
            ),
          );
        }

        // 复用歌词页的 LyricView 渲染管线（AnimationController 驱动 +
        // CustomPainter 高亮），保证与歌词页一致的流畅逐字动画。
        // 外层用 LayoutBuilder 读取实际可用高度：海报布局中该预览区是弹性
        // 空间（Expanded），矮屏/大字体机型下会收缩而不是溢出。
        // contentPadding: EdgeInsets.zero —— 外层 Container 已带 24 水平内边距，
        // 避免歌词再右移 24 与标题错位（左对齐、左侧不留空白）。
        // 高度防御：LayoutBuilder 在某瞬态可能拿到 Infinity，若直接传给 LyricView
        // 会连锁出 Matrix4/NaN 崩溃，这里钳制为「有界上限」。
        return LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : 118.0;
            return LyricPreview(
              height: h.clamp(0.0, 1000.0),
              textAlign: TextAlign.start,
              contentAlignment: CrossAxisAlignment.start,
              showTranslation: true,
              fontSize: 15,
              activeFontSize: 18,
              contentPadding: EdgeInsets.zero,
              // 上下边缘渐隐，歌词行滑出边界时淡出而非硬截断
              fadeEdges: true,
            );
          },
        );
      },
    );
  }
}

class _PosterLyricLine extends StatelessWidget {
  final String text;
  final bool active;

  const _PosterLyricLine({required this.text, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: active
            ? scheme.onSurface.withValues(alpha: 0.92)
            : scheme.onSurfaceVariant.withValues(alpha: 0.68),
        fontSize: active ? 18 : 15,
        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
        height: 1.15,
      ),
    );
  }
}

class _PosterMetaRow extends StatelessWidget {
  final PlayerService player;
  final SongEntity? song;

  const _PosterMetaRow({required this.player, required this.song});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        _PosterFavoriteButton(song: song),
        const Spacer(),
        IconButton(
          visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          icon: Icon(
            Icons.menu_rounded,
            color: scheme.onSurface.withValues(alpha: 0.72),
            size: 24,
          ),
          onPressed: () => showPlayerPlaylistSheet(context, player),
        ),
      ],
    );
  }
}

class _PosterFavoriteButton extends StatefulWidget {
  final SongEntity? song;

  const _PosterFavoriteButton({required this.song});

  @override
  State<_PosterFavoriteButton> createState() => _PosterFavoriteButtonState();
}

class _PosterFavoriteButtonState extends State<_PosterFavoriteButton> {
  final FeiNiuFavoriteService _favoriteService = FeiNiuFavoriteService.instance;
  bool _isFavorite = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadFavoriteState();
  }

  @override
  void didUpdateWidget(covariant _PosterFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.id != widget.song?.id) {
      _loadFavoriteState();
    }
  }

  Future<void> _loadFavoriteState() async {
    final song = widget.song;
    if (song == null) {
      if (mounted) {
        setState(() {
          _isFavorite = false;
          _loading = false;
        });
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final favIds = await _favoriteService.getFavoriteIds();
      if (!mounted || widget.song?.id != song.id) return;
      setState(() {
        _isFavorite = favIds.contains(song.id);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final song = widget.song;
    if (_loading || song == null) return;
    setState(() => _loading = true);
    try {
      if (_isFavorite) {
        await _favoriteService.unfavorite(song.id);
        if (!mounted) return;
        setState(() {
          _isFavorite = false;
          _loading = false;
        });
        AppToast.show(context, '已取消收藏');
      } else {
        await _favoriteService.favorite(song.id);
        if (!mounted) return;
        setState(() {
          _isFavorite = true;
          _loading = false;
        });
        AppToast.show(context, '已收藏');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      icon: Icon(
        _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        color: _isFavorite
            ? Colors.deepOrangeAccent
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72),
        size: 24,
      ),
      onPressed: widget.song == null || _loading ? null : _toggleFavorite,
    );
  }
}

class _PosterSeekBar extends StatefulWidget {
  final PlayerService player;

  const _PosterSeekBar({required this.player});

  @override
  State<_PosterSeekBar> createState() => _PosterSeekBarState();
}

class _PosterSeekBarState extends State<_PosterSeekBar> with SignalsMixin {
  late final _dragValue = createSignal<double?>(null);

  String _format(Duration? duration) {
    final total = duration?.inSeconds ?? 0;
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Watch.builder(
      builder: (context) {
        final position = widget.player.positionSignal.value;
        final duration = widget.player.durationSignal.value;
        final buffered = widget.player.bufferedPositionSignal.value;
        final totalMs = duration?.inMilliseconds ?? 0;
        final max = totalMs <= 0 ? 1.0 : totalMs.toDouble();
        final currentMs = position.inMilliseconds.clamp(0, max.toInt()).toInt();
        final value = (_dragValue.value ?? currentMs.toDouble()).clamp(0, max);
        final bufferedRatio = totalMs > 0
            ? (buffered.inMilliseconds / totalMs).clamp(0.0, 1.0)
            : 0.0;
        return Column(
          children: [
            // 进度条
            // Slider 轨道两端默认按 overlayRadius 内缩。这里把 overlayRadius 设为 0，
            // 轨道占满全宽，两端恰好与上方收藏/队列图标外缘对齐。
            // （不用负 padding / OverflowBox 扩展，避免布局异常。）
            SizedBox(
              height: 24,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: bufferedRatio,
                          backgroundColor: Colors.transparent,
                          valueColor: AlwaysStoppedAnimation(
                            scheme.onSurface.withValues(alpha: 0.22),
                          ),
                          minHeight: 3,
                        ),
                      ),
                    ),
                  ),
                  // 播放进度滑块
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      trackShape: const RoundedRectSliderTrackShape(),
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 0,
                      ),
                      activeTrackColor: scheme.onSurface.withValues(
                        alpha: 0.64,
                      ),
                      inactiveTrackColor: scheme.onSurface.withValues(
                        alpha: 0.13,
                      ),
                      thumbColor: scheme.onSurface,
                    ),
                    child: Slider(
                      value: value.toDouble(),
                      min: 0,
                      max: max,
                      onChanged: totalMs <= 0
                          ? null
                          : (next) => _dragValue.value = next,
                      onChangeEnd: totalMs <= 0
                          ? null
                          : (next) {
                              _dragValue.value = null;
                              widget.player.seek(
                                Duration(milliseconds: next.round()),
                              );
                            },
                    ),
                  ),
                ],
              ),
            ),
            // 时间标签：位于进度条下方，两端对齐
            Padding(
              padding: EdgeInsets.zero,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _format(Duration(milliseconds: currentMs)),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _format(duration),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PlayerArtwork extends StatelessWidget {
  final Signal<SongEntity?> songSignal;
  final PlayerStylePreset stylePreset;

  const _PlayerArtwork({required this.songSignal, required this.stylePreset});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
      builder: (context, effectiveTabletMode, _) {
        final isTabletLayout =
            effectiveTabletMode &&
            MediaQuery.sizeOf(context).width >= 720;
        final isTv = AppLayoutSettings.tvMode.value;
        return Watch.builder(
          builder: (context) {
            final song = songSignal.value;
            final spec = _ArtworkSpec.fromPreset(
              stylePreset,
              isTabletLayout,
              isTv,
            );
            final border = BorderRadius.circular(spec.borderRadius);
            final maxSize = spec.maxSize;
            if (song == null) {
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: spec.horizontalInset),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 矮屏/大字体机型：可用高度可能比宽度小，封面按高度收缩，
                    // 避免把下方控制区挤出屏幕（原布局固定 Spacer 会在溢出时
                    // 塌缩成 0，导致封面贴顶、居中失效、底栏消失）。
                    final width = constraints.maxWidth;
                    final boxSize = width < maxSize ? width : maxSize;
                    final size =
                        boxSize < constraints.maxHeight ? boxSize : constraints.maxHeight;
                    return Center(
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: _ArtworkShadowContainer(
                          border: border,
                          child: _ArtworkPlaceholder(border: border, label: ''),
                        ),
                      ),
                    );
                  },
                ),
              );
            }
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: spec.horizontalInset),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final boxSize = width < maxSize ? width : maxSize;
                  final size =
                      boxSize < constraints.maxHeight ? boxSize : constraints.maxHeight;
                  final borderRadius =
                      PlayerBackgroundSettings.roundCover.value ? size / 2 : 12.0;
                  return Center(
                    child: SizedBox(
                      width: size,
                      height: size,
                      child: _ArtworkShadowContainer(
                        border: border,
                        child: _RotatingArtwork(
                          song: song,
                          buildArtwork: (context, onCoverAvailable) =>
                              ArtworkWidget(
                                song: song,
                                size: size,
                                borderRadius: borderRadius,
                                preferOriginal: true,
                                keepPreviousUntilLoaded: true,
                                onCoverAvailableChanged: onCoverAvailable,
                                placeholder: _ArtworkPlaceholder(
                                  border: border,
                                  label: song.title,
                                ),
                              ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _ArtworkSpec {
  final double borderRadius;
  final double horizontalInset;
  final double maxSize;

  const _ArtworkSpec({
    required this.borderRadius,
    required this.horizontalInset,
    required this.maxSize,
  });

  factory _ArtworkSpec.fromPreset(
    PlayerStylePreset preset,
    bool isTablet, [
    bool isTv = false,
  ]) {
    switch (preset) {
      case PlayerStylePreset.poster:
        // TV 大屏放开封面上限，让封面用满可用空间（横向布局下高度充足）。
        return _ArtworkSpec(
          borderRadius: 0,
          horizontalInset: 0,
          maxSize: isTv ? 640 : (isTablet ? 360 : double.infinity),
        );
      case PlayerStylePreset.classic:
        return _ArtworkSpec(
          borderRadius: 12,
          horizontalInset: 32,
          maxSize: isTv ? 560 : (isTablet ? 320 : double.infinity),
        );
    }
  }
}

class _ArtworkShadowContainer extends StatelessWidget {
  final BorderRadius border;
  final Widget child;

  const _ArtworkShadowContainer({required this.border, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(borderRadius: border, child: child);
  }
}

/// 封面旋转门控：仅当显示真实封面图时才旋转。
///
/// 通过 [ArtworkWidget.onCoverAvailableChanged] 获知当前是否显示真实封面：
/// 加载中 / 加载失败（文字占位图 / 骨架）时保持静止，只有真实封面在
/// 播放中才旋转。播放状态与「旋转封面」开关变化时自动启停旋转。
class _RotatingArtwork extends StatefulWidget {
  /// 当前歌曲（null 表示无歌曲，显示占位图，不旋转）。
  final SongEntity? song;

  /// 构建封面内容（真实封面或占位图）。
  ///
  /// [onCoverAvailableChanged] 由 [ArtworkWidget] 在真实封面解码成功时回调
  /// true，占位 / 加载失败时回调 false。
  final Widget Function(BuildContext, ValueChanged<bool>) buildArtwork;

  const _RotatingArtwork({required this.song, required this.buildArtwork});

  @override
  State<_RotatingArtwork> createState() => _RotatingArtworkState();
}

class _RotatingArtworkState extends State<_RotatingArtwork> {
  bool _hasRealCover = false;

  void _setCoverAvailable(bool ok) {
    if (_hasRealCover == ok) return;
    setState(() => _hasRealCover = ok);
  }

  @override
  void didUpdateWidget(_RotatingArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.song?.id == oldWidget.song?.id) return;
    // 切歌：重置封面可用状态。新封面加载期间显示占位（不旋转），
    // 解码成功后 imageBuilder 上报 true 才恢复旋转。
    if (_hasRealCover) _setCoverAvailable(false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        PlayerService.instance.isPlaying,
        PlayerBackgroundSettings.rotateCover,
      ]),
      builder: (context, _) {
        final playing = PlayerService.instance.isPlaying.value;
        final rotateEnabled = PlayerBackgroundSettings.rotateCover.value;
        final artwork = widget.buildArtwork(context, _setCoverAvailable);
        if (rotateEnabled && _hasRealCover) {
          return _RotatingCover(playing: playing, child: artwork);
        }
        return artwork;
      },
    );
  }
}

class _RotatingCover extends StatefulWidget {
  final bool playing;
  final Widget child;

  const _RotatingCover({required this.playing, required this.child});

  @override
  State<_RotatingCover> createState() => _RotatingCoverState();
}

class _RotatingCoverState extends State<_RotatingCover>
    with SingleTickerProviderStateMixin, AppRouteVisibilityMixin {
  late AnimationController _controller;

  @override
  AnimationController get visibilityController => _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(_RotatingCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing && !oldWidget.playing) {
      _controller.repeat();
    } else if (!widget.playing && oldWidget.playing) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void resumeVisibilityAnimation() {
    // 仅播放中恢复旋转；暂停状态被覆盖后回来仍保持静止。
    if (widget.playing) _controller.repeat();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(turns: _controller, child: widget.child);
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  final BorderRadius border;
  final String label;

  const _ArtworkPlaceholder({required this.border, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = label.trim().isEmpty ? '?' : label.trim().substring(0, 1);
    return Container(
      decoration: BoxDecoration(
        borderRadius: border,
        color: scheme.primary.withValues(alpha: 0.12),
      ),
      child: Center(
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }
}
