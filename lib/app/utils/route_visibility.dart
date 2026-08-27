import 'package:flutter/material.dart';

/// 全局路由观察者：跟踪当前可见的路由。
///
/// 供路由底层的持续动画（流光背景、封面旋转等）感知自身是否被新路由覆盖，
/// 被覆盖时暂停动画以释放 GPU 帧预算，避免页面切换转场期间掉帧。
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// 让动画控制器在路由被覆盖时自动暂停、重新可见时恢复。
///
/// 用法：让持有常驻动画的 State 同时 `with TickerProviderStateMixin,
/// AppRouteVisibilityMixin`，并覆写 [resumeVisibilityAnimation] 定义恢复行为
/// （默认 `controller.repeat()`）。当页面被 push 到其上（didPushNext）时暂停，
/// 回到当前页（didPopNext）时恢复。页面本身可见时动画不受影响。
mixin AppRouteVisibilityMixin<T extends StatefulWidget> on State<T>
    implements RouteAware {
  /// 需要随可见性暂停/恢复的动画控制器。
  AnimationController get visibilityController;

  /// 需要一起暂停的额外控制器（例如背景换色过渡）。
  Iterable<AnimationController> get additionalVisibilityControllers => const [];

  /// 页面重新成为当前路由时如何恢复动画。默认重新 repeat；
  /// 需要条件恢复（如仅播放中旋转封面）时覆写此方法。
  void resumeVisibilityAnimation() {
    visibilityController.repeat();
  }

  @override
  void didPush() {}

  @override
  void didPop() {}

  @override
  void didPushNext() {
    // 被其它路由覆盖：暂停动画，停止消耗 GPU 帧预算。
    visibilityController.stop();
    for (final controller in additionalVisibilityControllers) {
      controller.stop();
    }
  }

  @override
  void didPopNext() {
    // 重新回到当前页：恢复动画。
    if (mounted) resumeVisibilityAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToRoute();
  }

  /// 在 didChangeDependencies 里缓存路由引用（dispose 阶段不能再查祖先）。
  ModalRoute<void>? _subscribedRoute;

  void _subscribeToRoute() {
    final route = ModalRoute.of(context);
    if (route == null || identical(route, _subscribedRoute)) return;
    if (_subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _subscribedRoute = route;
    appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    final route = _subscribedRoute;
    if (route != null) {
      appRouteObserver.unsubscribe(this);
      _subscribedRoute = null;
    }
    super.dispose();
  }
}
