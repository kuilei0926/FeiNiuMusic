import 'package:flutter/material.dart';

import '../../../app/state/settings_state.dart';
import 'app_background.dart';
import '../../player/mini_player/mini_player_bar.dart';
import '../modern_navigation_bar.dart';

class AppPageScaffold extends StatefulWidget {
  static const double modernNavHeight = 60.0;

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

  /// 抽屉当前是否处于展开态（>0 视为展开）。驱动 PopScope 的 canPop，
  /// 只在开/关边界变化，不随动画每帧重建。
  bool _drawerOpen = false;

  bool get _hasDrawer => widget.drawer != null;

  void _setDrawerOpen(bool open) {
    if (_drawerOpen == open) return;
    _drawerOpen = open;
    // 立即重建 PopScope，让系统返回键行为随抽屉状态切换
    if (mounted) setState(() {});
  }

  void openDrawer() {
    if (!_hasDrawer) return;
    if (AppLayoutSettings.effectiveTabletMode) return;
    _drawerController.forward();
    _setDrawerOpen(true);
  }

  void closeDrawer() {
    if (!_hasDrawer) return;
    if (AppLayoutSettings.effectiveTabletMode) return;
    _drawerController.reverse();
  }

  /// 导航前同步收起抽屉：直接把抽屉控制器跳到关闭态。
  ///
  /// 侧边栏点菜单项跳转时，若只启动 [closeDrawer] 的 240ms 反向动画后立即
  /// push 新路由，抽屉动画会被路由转场（TickerMode 静音）打断停在中途；
  /// 返回当前页时侧边栏就会卡在展开/半展开状态。这里同步归零，保证导航
  /// 后抽屉必然处于关闭态。
  void closeDrawerImmediately() {
    if (!_hasDrawer) return;
    if (AppLayoutSettings.effectiveTabletMode) return;
    _drawerController.value = 0;
    _setDrawerOpen(false);
  }

  @override
  void initState() {
    super.initState();
    // 关闭动画播完（反向到底）时，把展开态同步为关闭。
    // 这样 closeDrawer() 的动画收尾后 PopScope 也能正确放行返回键。
    _drawerController.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && _drawerOpen) {
        _setDrawerOpen(false);
      }
    });
  }

  @override
  void dispose() {
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
          )
        : null;

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // 底部控制栏相对底部的额外抬升量：离开屏幕大圆角/手势条区域，
    // 让底栏悬浮更透气，不被大圆角边缘裁切。
    const miniPlayerLift = 8.0;
    final miniPlayerBottom = hasBottomNav
        ? (AppPageScaffold.modernNavHeight + bottomInset)
        : bottomInset;
    final keyboardInset = widget.resizeToAvoidBottomInset
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    final effectiveMiniPlayerBottom = (widget.keepBottomOverlayFixed
        ? miniPlayerBottom - keyboardInset
        : miniPlayerBottom) + miniPlayerLift;

    final drawerWidth = (MediaQuery.sizeOf(context).width * 0.56).clamp(
      200.0,
      300.0,
    );

    return ValueListenableBuilder<bool>(
      valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
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
                    // 用 Transform.translate 移动 mini player 而非 Positioned.left：
                    // Positioned.left 每帧变化会触发整个 Stack 重新 layout（真实重排 +
                    // 重绘），Transform 只是合成图层平移，配合 RepaintBoundary 缓存
                    // 后抽屉动画不逐帧重排 mini player 子树。
                    return Positioned(
                      left: 0,
                      right: 0,
                      bottom: effectiveMiniPlayerBottom,
                      child: Transform.translate(
                        offset: Offset(drawerWidth * value, 0),
                        child: child!,
                      ),
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
        // 抽屉展开时系统返回键应先收起抽屉，而不是直接退出当前页。
        // _drawerOpen 只在开/关边界变化，避免 PopScope 随动画每帧重建。
        return PopScope(
          canPop: !_drawerOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_drawerOpen) {
              closeDrawerImmediately();
            }
          },
          child: stack,
        );
      },
    );
  }
}
