import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../components/layout/modern_navigation_bar.dart';

/// 底栏模式下点击 tab 切换到本页时刷新数据。
///
/// 外壳用 [IndexedStack] 缓存各 tab 的 State，切换 tab 只是翻转 index，页面
/// 不会重建、initState 不再执行。本 mixin 借助外壳包好的 [PrimaryNavigationScope]
/// （InheritedWidget）：切换 tab 时 currentIndex 变化触发依赖更新，被激活的 tab
/// State 会收到 [didChangeDependencies] 回调，据此判断「现在轮到我」并刷新数据。
///
/// 用法：数据型 tab 页 State `with ... , PrimaryTabRefreshMixin`，并实现
/// [primaryTabIndex] 与 [onPrimaryTabActivated]。
mixin PrimaryTabRefreshMixin<T extends StatefulWidget> on State<T> {
  int? _lastSeenIndex;

  /// 本页在底栏中的序号（0~4）。
  int get primaryTabIndex;

  /// 页面被切到前台时执行的刷新。
  Future<void> onPrimaryTabActivated();

  /// 页面被切到后台时执行（如退出多选）。默认无操作。
  ///
  /// 底栏模式下 IndexedStack 缓存各 tab 的 State，切走时页面不销毁、多选等
  /// 瞬时状态会残留（见 multiSelect 的全局计数），借此钩子收尾。
  /// 注意：本回调在帧后触发（见 [didChangeDependencies]），实现里同步改
  /// ValueNotifier 是安全的。
  void onPrimaryTabDeactivated() {}

  @override
  void initState() {
    super.initState();
    // 记录当前所处的 tab：首页启动时以激活态构建（initState 已加载），
    // 预热构建的非激活页也以此为基准，避免首帧 didChangeDependencies 误触发。
    // getInheritedWidgetOfExactType 不注册依赖，initState 阶段可安全调用。
    _lastSeenIndex = context
        .getInheritedWidgetOfExactType<PrimaryNavigationScope>()
        ?.currentIndex;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = PrimaryNavigationScope.maybeOf(context);
    if (scope == null) return; // 非底栏模式
    final current = scope.currentIndex;
    if (current != primaryTabIndex) {
      _lastSeenIndex = current; // 切到别的 tab，记住位置
      // 延迟到帧后回调：didChangeDependencies 处于 build 阶段，若实现里同步
      // 修改 ValueNotifier（如退出多选时改 globalMultiSelectActive），会通知
      // 其监听者（如 shell 的共享底栏 ValueListenableBuilder，不在当前 build
      // 作用域内）触发 "setState() or markNeedsBuild() called during build"。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onPrimaryTabDeactivated();
      });
      return;
    }
    if (_lastSeenIndex == primaryTabIndex) return; // 本来就在当前 tab
    _lastSeenIndex = primaryTabIndex;
    if (mounted) unawaited(onPrimaryTabActivated());
  }
}
