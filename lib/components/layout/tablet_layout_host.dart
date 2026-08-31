import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';
import '../feedback/app_toast.dart';
import '../focus/tv_focusable.dart';
import 'base/app_background.dart';
import '../list/song_multi_select_mixin.dart' show globalMultiSelectActive;
import '../player/mini_player/mini_player_bar.dart';
import 'side_menu.dart';

class TabletLayoutHost extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  const TabletLayoutHost({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  @override
  State<TabletLayoutHost> createState() => _TabletLayoutHostState();
}

class _TabletLayoutHostState extends State<TabletLayoutHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  @override
  void initState() {
    super.initState();
    if (AppLayoutSettings.effectiveTabletMode) {
      _controller.value = 1;
    }
    AppLayoutSettings.effectiveTabletModeNotifier.addListener(_handleModeChanged);
  }

  @override
  void dispose() {
    AppLayoutSettings.effectiveTabletModeNotifier
        .removeListener(_handleModeChanged);
    _controller.dispose();
    super.dispose();
  }

  void _handleModeChanged() {
    if (!mounted) return;
    final enabled = AppLayoutSettings.effectiveTabletMode;
    if (enabled) {
      // TV 模式进入即钉住，不做 260ms 展开动画，避免每次启动都闪一遍。
      if (AppLayoutSettings.tvMode.value) {
        _controller.value = 1;
      } else {
        _controller.forward();
      }
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final width = MediaQuery.sizeOf(context).width;
        // TV 用更宽的 10-foot 侧栏；手机/平板保持原 200-300 钳制。
        final drawerWidth = AppLayoutSettings.tvMode.value
            ? (width * 0.28).clamp(320.0, 360.0)
            : (width * 0.32).clamp(200.0, 300.0);
        final pageOffset = drawerWidth * t;
        final scale = 1 - (0.02 * t);
        final contentWidth = (width - pageOffset).clamp(0.0, width);
        final bottomInset = MediaQuery.paddingOf(context).bottom;
        final pageRadius = 24.0 * t;
        final pageShadow = Theme.of(context).brightness == Brightness.dark
            ? Colors.black.withValues(alpha: 0.28 * t)
            : Colors.black.withValues(alpha: 0.08 * t);

        return _RootBackHandler(
          navigatorKey: widget.navigatorKey,
          child: AppBackground(
            child: ValueListenableBuilder<bool>(
              valueListenable: AppLayoutSettings.playerRouteActive,
              builder: (context, playerActive, _) {
                // TV 模式且播放页激活 → 隐藏侧栏与迷你播放器（只盖不卸载，
                // 返回后自动还原）。手机/平板非 TV 恒 false，行为不变。
                final hideChrome = AppLayoutSettings.tvMode.value && playerActive;
                // 隐藏 chrome 时内容区铺满全屏：去掉左偏移/宽度收缩/缩放/圆角/
                // 阴影，让播放页延伸到屏幕左边，不留空白。
                final effOffset = hideChrome ? 0.0 : pageOffset;
                final effContentWidth = hideChrome ? width : contentWidth;
                final effScale = hideChrome ? 1.0 : scale;
                final effRadius = hideChrome ? 0.0 : pageRadius;
                final effShadow = hideChrome
                    ? Colors.transparent
                    : pageShadow;
                final effBlur = hideChrome ? 0.0 : 28 * t;
                final effShadowOffset = hideChrome ? Offset.zero : Offset(0, 10 * t);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRect(
                        child: Padding(
                          key: const ValueKey('tv-player-content-offset'),
                          padding: EdgeInsets.only(left: effOffset),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: effContentWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(effRadius),
                                  boxShadow: [
                                    BoxShadow(
                                      color: effShadow,
                                      blurRadius: effBlur,
                                      offset: effShadowOffset,
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(effRadius),
                                  child: Transform.scale(
                                    scale: effScale,
                                    alignment: Alignment.centerLeft,
                                    child: child,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: -drawerWidth + drawerWidth * t,
                      top: 0,
                      bottom: 0,
                      width: drawerWidth,
                      child: IgnorePointer(
                        key: const ValueKey('tv-player-hide-sidebar'),
                        ignoring: hideChrome,
                        child: Opacity(
                          opacity: hideChrome ? 0 : 1,
                          child: IgnorePointer(
                            ignoring: t == 0,
                            child: SideMenu(
                              onNavigate: _handleNavigate,
                              onPush: _handlePush,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (AppLayoutSettings.effectiveTabletMode)
                      // 隐藏迷你播放器的场景（平板/TV/Windows 由外壳统一渲染，
                      // 手机端各页已用 showMiniPlayer 自行控制）：
                      //   1. 多选：底部有操作栏，迷你播放器会挡住它；
                      //   2. 模态底部面板（歌曲信息 sheet）：外壳在 Navigator 外，
                      //      sheet 盖不住迷你播放器，会挡住 sheet 底部按钮；
                      //   3. 页面声明隐藏迷你播放器（设置页等 showMiniPlayer:false）。
                      ValueListenableBuilder<int>(
                        valueListenable: globalMultiSelectActive,
                        builder: (context, multiSelectCount, _) {
                          return ValueListenableBuilder<bool>(
                            valueListenable: AppLayoutSettings.modalSheetActive,
                            builder: (context, sheetActive, _) {
                              return ValueListenableBuilder<int>(
                                valueListenable:
                                    AppLayoutSettings.miniPlayerSuppressedCount,
                                builder: (context, suppressedCount, _) {
                                  final hideMini =
                                      hideChrome ||
                                      multiSelectCount > 0 ||
                                      sheetActive ||
                                      suppressedCount > 0;
                                  return Positioned(
                                    // 迷你播放器左侧对齐侧边栏右缘，不覆盖侧边栏
                                    // （侧边栏底部「设置」等入口需可点击）。动画期间随
                                    // 侧边栏一起滑入/滑出。
                                    left: drawerWidth * t,
                                    right: 0,
                                    bottom: bottomInset,
                                    child: IgnorePointer(
                                      key: const ValueKey(
                                        'tv-player-hide-miniplayer',
                                      ),
                                      ignoring: hideMini,
                                      child: Opacity(
                                        opacity: hideMini ? 0 : 1,
                                        child: _buildMiniPlayer(),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ),
        );
      },
      child: widget.child,
    );
  }

  void _handleNavigate(String route) {
    widget.navigatorKey.currentState?.pushNamedAndRemoveUntil(
      route,
      (route) => false,
    );
  }

  void _handlePush(String route) {
    widget.navigatorKey.currentState?.pushNamed(route);
  }

  /// 底部迷你播放器。TV 模式下：
  /// - 用 [TvFocusable] 包装成一个焦点目标（内部 InkWell/播放钮的焦点节点
  ///   被屏蔽），DPAD 聚焦整条 bar → Enter 打开播放页；
  /// - 内部的 `onTap` 仍打开播放页，与 Enter 一致。
  Widget _buildMiniPlayer() {
    final bar = MiniPlayerBar(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
    if (!AppLayoutSettings.tvMode.value) return bar;
    return TvFocusable(
      borderRadius: BorderRadius.circular(24),
      onActivate: () => _handlePush(AppRoutes.player),
      child: bar,
    );
  }
}

/// Routes system back gestures for the nested base [Navigator]:
/// - while there are in-app pages to go back to, it pops the nested navigator
///   (mirrors [NavigatorPopHandler], which keeps HarmonyOS/Android
///   predictive-back reliable by reflecting the subtree's real pop-ability);
/// - when already at the home page, the first back shows a hint and only the
///   second back within 2s actually exits to the desktop.
class _RootBackHandler extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const _RootBackHandler({required this.navigatorKey, required this.child});

  @override
  State<_RootBackHandler> createState() => _RootBackHandlerState();
}

class _RootBackHandlerState extends State<_RootBackHandler> {
  // Whether the nested navigator currently has a route to pop.
  bool _subtreeCanPop = false;
  // Set after the first "exit" back press so the next one really leaves.
  bool _armedToExit = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _armExitWindow() {
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        _armedToExit = false;
        return;
      }
      setState(() => _armedToExit = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 只有「已进入待退出」才放行系统返回；未待退出时无论是否在首页都由我们
    // 拦截（子页面手动 maybePop，首页弹 toast 并进入待退出）。
    // 不能用 `_subtreeCanPop ? false : _armedToExit`：本 PopScope 自身的
    // canPop=false 会让嵌套 Navigator 的 canPop() 误报为 true（willHandlePopInternally），
    // 首次进入时第一次返回会走 maybePop 冒泡、什么都不弹也不出 toast。
    return PopScope(
      // 根路由没有可弹出的上级路由，始终拦截返回并在回调中决定是返回
      // 子页面、提示用户，还是交给系统退到后台。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_armedToExit && !_subtreeCanPop) {
          // 根路由没有可弹出的上级页面，不能依赖 Navigator.pop() 退出。
          // 显式交给系统处理，Android 会结束当前 Activity 并回到桌面。
          await SystemNavigator.pop();
          return;
        }
        if (_subtreeCanPop) {
          final popped = await (widget.navigatorKey.currentState?.maybePop() ??
              Future.value(false));
          // 确实弹出子页面 → 正常返回；否则（maybePop 冒泡到根 = 在首页）
          // 落到下面的待退出提示。
          if (popped) return;
          if (!mounted) return;
        }
        // 在首页（或 maybePop 冒泡无果）：进入待退出 + 弹提示，第二次返回真正退出。
        // 先武装退出再弹 toast：提示只是辅助，即使 toast 异常（如 overlay 暂不可用）
        // 也不能阻断 _armedToExit，否则第二次返回永远无法退出到桌面。
        setState(() => _armedToExit = true);
        _armExitWindow();
        try {
          AppToast.showGlobal('再按一次返回键退回桌面');
        } catch (_) {
          // toast 失败不阻塞退出逻辑（武装已生效）。
        }
      },
      child: NotificationListener<NavigationNotification>(
        onNotification: (notification) {
          final next = notification.canHandlePop;
          if (next != _subtreeCanPop) {
            setState(() {
              _subtreeCanPop = next;
              // Left the home page → cancel any pending exit arming.
              if (next) {
                _armedToExit = false;
                _resetTimer?.cancel();
              }
            });
          }
          return false;
        },
        child: widget.child,
      ),
    );
  }
}
