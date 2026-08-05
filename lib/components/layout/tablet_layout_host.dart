import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';
import '../feedback/app_toast.dart';
import '../focus/tv_focusable.dart';
import 'base/app_background.dart';
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
                return Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRect(
                        child: Padding(
                          padding: EdgeInsets.only(left: pageOffset),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: contentWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(pageRadius),
                                  boxShadow: [
                                    BoxShadow(
                                      color: pageShadow,
                                      blurRadius: 28 * t,
                                      offset: Offset(0, 10 * t),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(pageRadius),
                                  child: Transform.scale(
                                    scale: scale,
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
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: bottomInset,
                        child: IgnorePointer(
                          key: const ValueKey('tv-player-hide-miniplayer'),
                          ignoring: hideChrome,
                          child: Opacity(
                            opacity: hideChrome ? 0 : 1,
                            child: _buildMiniPlayer(),
                          ),
                        ),
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
    // canPop=false → we intercept the back; canPop=true → let the system exit.
    final canPop = _subtreeCanPop ? false : _armedToExit;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_subtreeCanPop) {
          widget.navigatorKey.currentState?.maybePop();
          return;
        }
        // At home, not yet armed: prompt and arm a real exit for the next back.
        AppToast.show(context, '再返回一次退回桌面');
        setState(() => _armedToExit = true);
        _armExitWindow();
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
