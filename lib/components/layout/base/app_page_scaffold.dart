import 'package:flutter/material.dart';

import '../../../app/state/settings_state.dart';
import '../../../app/utils/primary_shell_scope.dart';
import 'app_background.dart';
import '../../player/mini_player/mini_player_bar.dart';
import '../modern_navigation_bar.dart';

class AppPageScaffold extends StatefulWidget {
  static const double modernNavHeight = 84.0;

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

  /// 隐藏底部导航栏（如多选时：导航栏悬浮在页面内容上方，会盖住底部
  /// 多选操作栏，与 [showMiniPlayer] 同理按需隐藏）。
  final bool hideBottomNav;

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
    this.hideBottomNav = false,
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
    // 页面声明隐藏迷你播放器（设置页、全屏页等）时，上报给平板/TV/Windows
    // 外壳（外壳统一渲染迷你播放器，无视页面的 showMiniPlayer 参数）。
    // 计数式：页面栈上可能有多个 AppPageScaffold，任一隐藏则外壳隐藏。
    // 延迟到帧后：initState 在 Navigator build 中执行，同步 notify 外壳的
    // ValueListenableBuilder 会触发 "setState during build"。
    if (!widget.showMiniPlayer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLayoutSettings.miniPlayerSuppressedCount.value += 1;
      });
    }
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
    if (!widget.showMiniPlayer) {
      // 帧后递减：dispose 常在 widget tree 锁定期执行，同步 notify 会触发
      // "setState when widget tree was locked"。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppLayoutSettings.miniPlayerSuppressedCount.value =
            (AppLayoutSettings.miniPlayerSuppressedCount.value - 1).clamp(
              0,
              1 << 30,
            );
      });
    }
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

    final hasBottomNav = !widget.hideBottomNav &&
        widget.bottomNavIndex != null &&
        widget.onBottomNavTap != null;
    // shell 主 tab 页由 shell 渲染唯一一份共享底栏（见 app_router.dart 的
    // _PrimaryNavigationShell），页面自身不再渲染，否则 IndexedStack 里每个
    // tab 页各持一份 GlassTabBar / TabIndicatorState，切换后胶囊会从各页
    // 过期的 tabXAlign 起跳（闪一下旧选中项）。Detail/独立路由页面不在
    // PrimaryShellMarker 内，仍按各自 bottomNavIndex 渲染自己的底栏。
    final bottomBar = hasBottomNav && !PrimaryShellMarker.isInside(context)
        ? ModernNavigationBar(onTap: widget.onBottomNavTap!)
        : null;
    final miniPlayer = widget.showMiniPlayer
        ? MiniPlayerBar(
            padding: hasBottomNav
                ? const EdgeInsets.fromLTRB(16, 4, 16, 0)
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          )
        : null;

    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // 有底栏时迷你播放器停在胶囊上方，此值即与胶囊顶的间隙（贴近不重叠）。
    const miniPlayerLift = 5.0;
    // 无底栏时底部没有胶囊，迷你播放器需要额外抬离底部，避开系统手势条 /
    // 大圆角边缘，悬浮更透气。
    const miniPlayerBottomLift = 10.0;
    final lift = hasBottomNav ? miniPlayerLift : miniPlayerBottomLift;
    // 玻璃开启时胶囊只占槽位中间（上方留 kGlassNavPillTopGap 空隙），迷你
    // 播放器对齐胶囊顶（减去该空隙），避免把空隙误当成间隙；非玻璃分支是
    // 占满槽位的实色栏，不减。该值随开关/TV 变化由下方 ListenableBuilder
    // 触发重算。
    final glassPillTopGap = AppGlassSettings.effectiveEnabled
        ? kGlassNavPillTopGap
        : 0.0;
    final miniPlayerBottom = hasBottomNav
        ? (AppPageScaffold.modernNavHeight - glassPillTopGap + bottomInset)
        : bottomInset;
    final keyboardInset = widget.resizeToAvoidBottomInset
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    final effectiveMiniPlayerBottom = (widget.keepBottomOverlayFixed
        ? miniPlayerBottom - keyboardInset
        : miniPlayerBottom) + lift;

    final drawerWidth = (MediaQuery.sizeOf(context).width * 0.56).clamp(
      200.0,
      300.0,
    );

    return ListenableBuilder(
      listenable: Listenable.merge([
        AppLayoutSettings.effectiveTabletModeNotifier,
        AppGlassSettings.liquidGlassEnabled,
        AppLayoutSettings.tvMode,
      ]),
      builder: (context, _) {
        final tabletMode =
            AppLayoutSettings.effectiveTabletModeNotifier.value;
        Widget buildBody({required bool includeMiniPlayer}) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              content,
              // 底栏悬浮 overlay：叠在页面内容上方而非 Scaffold 的
              // bottomNavigationBar 槽位，玻璃层因此能实时采样到背后的
              // 页面内容（透明空隙透出页面 = 真正的 iOS 26 悬浮胶囊），
              // 而不是停在槽位里采样到空白层（表现为白色背景）。
              if (bottomBar != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: bottomBar,
                ),
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
          extendBodyBehindAppBar: widget.extendBodyBehindAppBar,
          backgroundColor: Colors.transparent,
          appBar: widget.appBar,
          body: buildBody(includeMiniPlayer: !tabletMode),
        );

        if (tabletMode || !_hasDrawer) {
          return AppBackground(child: page);
        }
        if (miniPlayer != null) {
          page = Scaffold(
            resizeToAvoidBottomInset: widget.resizeToAvoidBottomInset,
            extendBodyBehindAppBar: widget.extendBodyBehindAppBar,
            backgroundColor: Colors.transparent,
            appBar: widget.appBar,
            body: buildBody(includeMiniPlayer: false),
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
