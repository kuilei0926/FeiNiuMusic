import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/router/app_router.dart';
import '../../../app/services/player_service.dart';
import '../../../app/state/settings_state.dart';
import '../../../app/state/song_state.dart';
import '../../feedback/app_toast.dart';
import '../../player/vinyl_disc.dart';
import '../../player/vinyl_player_sheet.dart';
import '../../../pages/player/widgets/player_bottom_panel.dart';
import '../modern_navigation_bar.dart';
import 'bottom_island_layout.dart';
import 'island_surface.dart';

BottomIslandLayout resolveBottomIslandLayout(
  BuildContext context, {
  bool hasNavigation = true,
  bool showPlayer = true,
  bool visible = true,
  bool keepVisibleWithKeyboard = false,
}) => BottomIslandLayout.resolve(
  style: BottomIslandSettings.style.value,
  width: MediaQuery.sizeOf(context).width,
  textScale: MediaQuery.textScalerOf(context).scale(14) / 14,
  bottomInset: MediaQuery.paddingOf(context).bottom,
  hasNavigation: hasNavigation,
  showPlayer: showPlayer,
  isVisible: visible,
  keyboardVisible: MediaQuery.viewInsetsOf(context).bottom > 0,
  keepVisibleWithKeyboard: keepVisibleWithKeyboard,
  isLargeLayout: AppLayoutSettings.effectiveTabletMode,
  useLiquidGlass: AppGlassSettings.effectiveEnabled,
);

class BottomIslandHost extends StatefulWidget {
  final bool hasNavigation;
  final bool showPlayer;
  final bool keepVisibleWithKeyboard;
  final ValueChanged<int>? onSelected;

  const BottomIslandHost({
    super.key,
    this.hasNavigation = true,
    this.showPlayer = true,
    this.keepVisibleWithKeyboard = false,
    this.onSelected,
  });

  @override
  State<BottomIslandHost> createState() => _BottomIslandHostState();
}

class _BottomIslandHostState extends State<BottomIslandHost> {
  bool _opening = false;
  bool _commandBusy = false;

  Future<void> _command(Future<void> Function() command) async {
    if (_commandBusy) return;
    _commandBusy = true;
    try {
      await command();
    } catch (error) {
      if (mounted) AppToast.show(context, '播放操作失败，请重试', type: ToastType.error);
    } finally {
      _commandBusy = false;
    }
  }

  Future<void> _open({bool queue = false}) async {
    if (_opening || PlayerService.instance.currentSong.value == null) return;
    _opening = true;
    final navigator = Navigator.of(context);
    try {
      if (queue) {
        // Keep the lock until the queue's modal route has been removed.
        final route = ModalBottomSheetRoute<void>(
          builder: (_) => PlayerPlaylistSheet(player: PlayerService.instance),
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
        );
        await navigator.push(route);
        await route.completed;
        return;
      }
      final route = ModalBottomSheetRoute<VinylSheetAction>(
        builder: (_) => VinylPlayerSheet(player: PlayerService.instance),
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
      );
      final action = await navigator.push(route);
      await route.completed;
      if (!mounted ||
          !navigator.mounted ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      switch (action) {
        case VinylSheetAction.fullPlayer:
          await navigator.pushNamed(AppRoutes.player);
        case VinylSheetAction.queue:
          final queueRoute = ModalBottomSheetRoute<void>(
            builder: (_) => PlayerPlaylistSheet(player: PlayerService.instance),
            isScrollControlled: true,
            useSafeArea: true,
            backgroundColor: Colors.transparent,
          );
          await navigator.push(queueRoute);
          await queueRoute.completed;
        case null:
          break;
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      BottomIslandSettings.style,
      AppLayoutSettings.effectiveTabletModeNotifier,
      AppGlassSettings.liquidGlassEnabled,
      primaryNavigationIndex,
    ]),
    builder: (context, _) {
      final layout = resolveBottomIslandLayout(
        context,
        hasNavigation: widget.hasNavigation,
        showPlayer: widget.showPlayer,
        keepVisibleWithKeyboard: widget.keepVisibleWithKeyboard,
      );
      if (layout.occupiedHeight == 0) return const SizedBox.shrink();
      final player = PlayerService.instance;
      return ValueListenableBuilder<SongEntity?>(
        valueListenable: player.currentSong,
        builder: (context, song, _) => AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 260),
          layoutBuilder: (child, previous) => Stack(
            alignment: Alignment.bottomCenter,
            children: [
              for (final old in previous)
                ExcludeSemantics(
                  child: IgnorePointer(
                    child: TickerMode(enabled: false, child: old),
                  ),
                ),
              ?child,
            ],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .06),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: BottomIslandView(
            key: ValueKey(layout.effectiveStyle),
            layout: layout,
            selectedIndex: primaryNavigationIndex.value,
            song: song,
            player: player,
            onSelected:
                widget.onSelected ??
                (index) => navigateToPrimaryDestination(context, index),
            onOpen: () => _open(),
            onQueue: () => _open(queue: true),
            onPlay: () => _command(player.togglePlayPause),
            onNext: () => _command(player.next),
          ),
        ),
      );
    },
  );
}

/// Also used by settings previews. A null player never loads audio or artwork.
class BottomIslandView extends StatelessWidget {
  final BottomIslandLayout layout;
  final int selectedIndex;
  final SongEntity? song;
  final PlayerService? player;
  final bool preview;
  final ValueChanged<int>? onSelected;
  final VoidCallback? onOpen;
  final VoidCallback? onPlay;
  final VoidCallback? onNext;
  final VoidCallback? onQueue;

  const BottomIslandView({
    super.key,
    required this.layout,
    this.selectedIndex = 0,
    this.song,
    this.player,
    this.preview = false,
    this.onSelected,
    this.onOpen,
    this.onPlay,
    this.onNext,
    this.onQueue,
  });

  Widget _surface(Widget child) =>
      IslandSurface(preview: preview, child: child);

  Widget _disc(double size) {
    if (player == null) return VinylDisc(song: song, size: size);
    return ValueListenableBuilder<bool>(
      valueListenable: player!.isPlaying,
      builder: (context, playing, _) =>
          VinylDisc(song: song, playing: playing, size: size),
    );
  }

  Widget _info(
    BuildContext context, {
    bool title = true,
    double discSize = 40,
  }) => InkWell(
    key: const ValueKey('island-open-player'),
    borderRadius: BorderRadius.circular(28),
    onTap: song != null || preview ? onOpen : null,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: Center(child: _disc(discSize)),
          ),
          if (title) ...[
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song?.title ?? (preview ? '黑胶 · 随心听' : '选择歌曲开始播放'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    song?.artistDisplayName ?? (preview ? '飞牛音乐' : '从音乐库选择歌曲'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _play(BuildContext context) {
    Widget button(PlaybackSnapshot? snap) {
      final playing = snap?.isPlaying ?? false;
      final total = snap?.duration?.inMilliseconds ?? 0;
      final progress = total > 0
          ? (snap!.position.inMilliseconds / total).clamp(0.0, 1.0)
          : 0.0;
      return SizedBox(
        width: 48,
        height: 48,
        child: IconButton(
          key: const ValueKey('island-play-pause'),
          tooltip: playing ? '暂停' : '播放',
          onPressed: song != null || preview ? onPlay : null,
          padding: const EdgeInsets.all(6),
          icon: CustomPaint(
            foregroundPainter: _ProgressRing(
              progress: preview ? .42 : progress,
              color: Theme.of(context).colorScheme.primary,
            ),
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: snap?.isLoading == true
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 20,
                      ),
              ),
            ),
          ),
        ),
      );
    }

    return player == null
        ? button(null)
        : ValueListenableBuilder<PlaybackSnapshot>(
            valueListenable: player!.snapshot,
            builder: (context, snap, _) => button(snap),
          );
  }

  Widget _discRing(BuildContext context) {
    Widget ring(PlaybackSnapshot? snap) {
      final total = snap?.duration?.inMilliseconds ?? 0;
      final progress = total > 0
          ? (snap!.position.inMilliseconds / total).clamp(0.0, 1.0)
          : 0.0;
      return CustomPaint(
        foregroundPainter: _ProgressRing(
          progress: preview ? .42 : progress,
          color: Theme.of(context).colorScheme.primary,
        ),
        child: SizedBox(width: 64, height: 64, child: Center(child: _disc(56))),
      );
    }

    return player == null
        ? ring(null)
        : ValueListenableBuilder<PlaybackSnapshot>(
            valueListenable: player!.snapshot,
            builder: (context, snap, _) => ring(snap),
          );
  }

  Widget _tab(
    BuildContext context,
    int index, {
    bool label = false,
    bool inlineLabel = false,
  }) {
    final selected = selectedIndex == index;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: primaryNavigationLabels[index],
      child: Tooltip(
        message: primaryNavigationLabels[index],
        child: InkWell(
          key: ValueKey('island-tab-$index'),
          borderRadius: BorderRadius.circular(24),
          onTap: onSelected == null ? null : () => onSelected!(index),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: selected ? scheme.primary.withValues(alpha: .12) : null,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Flex(
              direction: inlineLabel ? Axis.horizontal : Axis.vertical,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  primaryNavigationIcons[index],
                  size: 20,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (label && inlineLabel) const SizedBox(width: 4),
                if (label)
                  Text(
                    primaryNavigationLabels[index],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navigation(
    BuildContext context,
    List<int> indices, {
    bool labels = true,
  }) => Row(
    children: [
      for (final index in indices)
        Expanded(child: _tab(context, index, label: labels)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hasNav = layout.navigationIndices.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    Widget content;
    if (layout.effectiveStyle == BottomIslandStyle.legacy) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (layout.playerVisible)
            SizedBox(
              height: layout.playerHeight,
              child: _surface(
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(child: _info(context)),
                      _play(context),
                    ],
                  ),
                ),
              ),
            ),
          if (hasNav)
            SizedBox(
              height: layout.navigationHeight,
              child: _navigation(context, layout.navigationIndices),
            ),
        ],
      );
    } else if (!hasNav || !layout.playerVisible) {
      content = _surface(
        SizedBox(
          height: layout.contentHeight,
          child: !hasNav
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(child: _info(context)),
                      _play(context),
                      IconButton(
                        tooltip: '播放队列',
                        onPressed: song == null ? null : onQueue,
                        icon: const Icon(Icons.queue_music_rounded),
                      ),
                    ],
                  ),
                )
              : _navigation(context, layout.navigationIndices),
        ),
      );
    } else {
      content = switch (layout.effectiveStyle) {
        BottomIslandStyle.c1 => _surface(
          SizedBox(
            height: layout.contentHeight,
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _info(context, title: constraints.maxWidth >= 354),
                    ),
                    _play(context),
                    for (final index in layout.navigationIndices)
                      _tab(
                        context,
                        index,
                        label:
                            selectedIndex == index &&
                            constraints.maxWidth >= 350,
                        inlineLabel: true,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        BottomIslandStyle.c2 => SizedBox(
          height: layout.contentHeight,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _surface(
                  SizedBox(
                    height: math.max(64, layout.navigationHeight),
                    child: Row(
                      children: [
                        Expanded(child: _navigation(context, const [0, 1])),
                        const SizedBox(width: 76),
                        Expanded(child: _navigation(context, const [3, 4])),
                      ],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: math.min(MediaQuery.sizeOf(context).width - 64, 280),
                  height: layout.playerHeight,
                  child: _surface(
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: song == null ? null : onOpen,
                              child: Center(
                                child: Text(
                                  song?.title ??
                                      (preview ? '黑胶 · 随心听' : '选择歌曲开始播放'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                          _play(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: layout.playerHeight + 8,
                left: 0,
                right: 0,
                child: Center(
                  child: InkWell(
                    key: const ValueKey('island-open-player'),
                    customBorder: const CircleBorder(),
                    onTap: song == null ? null : onOpen,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.surface,
                        border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: .25),
                        ),
                      ),
                      child: _discRing(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        BottomIslandStyle.c3 => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: layout.playerHeight,
              child: Row(
                children: [
                  Expanded(
                    child: _surface(
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          children: [
                            Expanded(child: _info(context, discSize: 36)),
                            _play(context),
                            if (MediaQuery.sizeOf(context).width >= 390)
                              IconButton(
                                tooltip: '下一首',
                                onPressed: song == null ? null : onNext,
                                icon: const Icon(
                                  Icons.skip_next_rounded,
                                  size: 20,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _surface(
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: IconButton(
                        key: const ValueKey('island-queue'),
                        tooltip: '播放队列',
                        onPressed: song == null ? null : onQueue,
                        icon: const Icon(Icons.queue_music_rounded, size: 20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: layout.navigationHeight,
              child: _navigation(context, layout.navigationIndices),
            ),
          ],
        ),
        BottomIslandStyle.legacy => const SizedBox.shrink(),
      };
    }
    return Padding(
      key: ValueKey('bottom-island-${layout.effectiveStyle.name}'),
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        layout.bottomGap + layout.bottomInset,
      ),
      child: SizedBox(height: layout.contentHeight, child: content),
    );
  }
}

class _ProgressRing extends CustomPainter {
  final double progress;
  final Color color;
  _ProgressRing({required this.progress, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect, paint..color = color.withValues(alpha: .12));
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_ProgressRing oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}
