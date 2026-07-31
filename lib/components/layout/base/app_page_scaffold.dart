import 'package:flutter/material.dart';

import '../../../app/state/settings_state.dart';
import 'app_background.dart';
import '../../player/mini_player/mini_player_bar.dart';
import '../modern_navigation_bar.dart';

class AppPageScaffold extends StatefulWidget {
  static const double modernNavHeight = 52.0;

  static double scrollableBottomPadding(
    BuildContext context, {
    bool hasBottomNav = false,
    bool showMiniPlayer = true,
    double minPadding = 24,
  }) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final miniPlayerPadding = showMiniPlayer
        ? MiniPlayerBar.estimatedHeight
        : 0.0;
    final bottomNavPadding = hasBottomNav ? modernNavHeight : 0.0;
    return bottomInset + miniPlayerPadding + bottomNavPadding + minPadding;
  }

  final PreferredSizeWidget? appBar;
  final Widget body;
  final bool extendBodyBehindAppBar;
  final bool useSafeArea;
  final bool resizeToAvoidBottomInset;
  final bool keepBottomOverlayFixed;
  final bool ignoreKeyboardInsets;
  final int? bottomNavIndex;
  final ValueChanged<int>? onBottomNavTap;
  final Widget? drawer;
  final bool showMiniPlayer;

  const AppPageScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.extendBodyBehindAppBar = false,
    this.useSafeArea = true,
    this.resizeToAvoidBottomInset = false,
    this.keepBottomOverlayFixed = false,
    this.ignoreKeyboardInsets = false,
    this.bottomNavIndex,
    this.onBottomNavTap,
    this.drawer,
    this.showMiniPlayer = true,
  });

  @override
  State<AppPageScaffold> createState() => AppPageScaffoldState();
}

class AppPageScaffoldState extends State<AppPageScaffold>
    with SingleTickerProviderStateMixin {
  static const Duration _drawerDuration = Duration(milliseconds: 240);

  late final AnimationController _drawerController = AnimationController(
    vsync: this,
    duration: _drawerDuration,
  );
  bool _draggingDrawer = false;

  /// True while the drawer is mid-slide; the mini player's backdrop blur is
  /// paused then so the moving page doesn't force an expensive re-blur on
  /// every animation frame.
  final ValueNotifier<bool> _drawerAnimating = ValueNotifier(false);

  bool get _hasDrawer => widget.drawer != null;

  void openDrawer() {
    if (!_hasDrawer) return;
    if (AppLayoutSettings.tabletMode.value) return;
    _drawerController.forward();
  }

  void closeDrawer() {
    if (!_hasDrawer) return;
    if (AppLayoutSettings.tabletMode.value) return;
    _drawerController.reverse();
  }

  @override
  void dispose() {
    _drawerAnimating.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.body;
    if (widget.useSafeArea) {
      content = SafeArea(child: content);
    }
    if (widget.ignoreKeyboardInsets) {
      final mq = MediaQuery.of(context);
      content = MediaQuery(
        data: mq.copyWith(viewInsets: EdgeInsets.zero),
        child: content,
      );
    }

    final hasBottomNav =
        widget.bottomNavIndex != null && widget.onBottomNavTap != null;
    final bottomBar = hasBottomNav
        ? ModernNavigationBar(
            currentIndex: widget.bottomNavIndex!,
            onTap: widget.onBottomNavTap!,
          )
        : null;
    final miniPlayer = widget.showMiniPlayer
        ? MiniPlayerBar(
            padding: hasBottomNav
                ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            blurPaused: _drawerAnimating,
          )
        : null;

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final miniPlayerBottom = hasBottomNav
        ? (AppPageScaffold.modernNavHeight + bottomInset)
        : bottomInset;
    final keyboardInset = widget.resizeToAvoidBottomInset
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    final effectiveMiniPlayerBottom = widget.keepBottomOverlayFixed
        ? miniPlayerBottom - keyboardInset
        : miniPlayerBottom;

    final drawerWidth = (MediaQuery.sizeOf(context).width * 0.62).clamp(
      220.0,
      300.0,
    );

    return ValueListenableBuilder<bool>(
      valueListenable: AppLayoutSettings.tabletMode,
      builder: (context, tabletMode, _) {
        Widget buildBody({required bool includeMiniPlayer}) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              content,
              if (miniPlayer != null && includeMiniPlayer)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: effectiveMiniPlayerBottom,
                  child: miniPlayer,
                ),
            ],
          );
        }

        Widget page = Scaffold(
          resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
          extendBody: bottomBar != null,
          extendBodyBehindAppBar: widget.extendBodyBehindAppBar,
          backgroundColor: Colors.transparent,
          appBar: widget.appBar,
          body: buildBody(includeMiniPlayer: !tabletMode),
          bottomNavigationBar: bottomBar == null
              ? null
              : Material(type: MaterialType.transparency, child: bottomBar),
        );

        if (tabletMode || !_hasDrawer) {
          return AppBackground(child: page);
        }
        if (miniPlayer != null) {
          page = Scaffold(
            resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
            extendBody: bottomBar != null,
            extendBodyBehindAppBar: widget.extendBodyBehindAppBar,
            backgroundColor: Colors.transparent,
            appBar: widget.appBar,
            body: buildBody(includeMiniPlayer: false),
            bottomNavigationBar: bottomBar == null
                ? null
                : Material(type: MaterialType.transparency, child: bottomBar),
          );
        }
        final stack = AppBackground(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedBuilder(
                animation: _drawerController,
                builder: (context, child) {
                  final value = _drawerController.value;
                  return Transform.translate(
                    offset: Offset(-drawerWidth + drawerWidth * value, 0),
                    child: child,
                  );
                },
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(
                    child: SizedBox(width: drawerWidth, child: widget.drawer),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _drawerController,
                builder: (context, child) {
                  final value = _drawerController.value;
                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (_) {
                      _draggingDrawer = true;
                    },
                    onHorizontalDragUpdate: (details) {
                      if (!_draggingDrawer) return;
                      final delta = details.primaryDelta ?? 0;
                      if (delta == 0) return;
                      if (_drawerController.value == 0 && delta < 0) return;
                      if (_drawerController.value == 1 && delta > 0) return;
                      final next =
                          (_drawerController.value + delta / drawerWidth).clamp(
                            0.0,
                            1.0,
                          );
                      _drawerController.value = next;
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_draggingDrawer) return;
                      _draggingDrawer = false;
                      if (_drawerController.value < 0.5) {
                        closeDrawer();
                      } else {
                        openDrawer();
                      }
                    },
                    child: Transform.translate(
                      offset: Offset(drawerWidth * value, 0),
                      child: child,
                    ),
                  );
                },
                child: RepaintBoundary(child: page),
              ),
              if (miniPlayer != null)
                AnimatedBuilder(
                  animation: _drawerController,
                  builder: (context, child) {
                    final value = _drawerController.value;
                    final animating = value > 0.0 && value < 1.0;
                    if (animating != _drawerAnimating.value) {
                      _drawerAnimating.value = animating;
                    }
                    return Positioned(
                      left: drawerWidth * value,
                      right: 0,
                      bottom: effectiveMiniPlayerBottom,
                      child: child!,
                    );
                  },
                  child: miniPlayer,
                ),
              AnimatedBuilder(
                animation: _drawerController,
                builder: (context, child) {
                  if (_drawerController.value == 0) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    left: drawerWidth,
                    top: 0,
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: closeDrawer,
                      onHorizontalDragUpdate: (details) {
                        final delta = details.primaryDelta ?? 0;
                        if (delta == 0) return;
                        final next =
                            (_drawerController.value + delta / drawerWidth)
                                .clamp(0.0, 1.0);
                        _drawerController.value = next;
                      },
                      onHorizontalDragEnd: (details) {
                        if (_drawerController.value < 0.5) {
                          closeDrawer();
                        } else {
                          openDrawer();
                        }
                      },
                      child: Container(color: Colors.transparent),
                    ),
                  );
                },
              ),
            ],
          ),
        );
        return stack;
      },
    );
  }
}
