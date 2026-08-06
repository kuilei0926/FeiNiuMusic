import 'package:flutter/material.dart';

/// 全局嵌套基础导航器访问器。
///
/// `_AppStartupGate` 为每个账号构建嵌套 `Navigator`（独立于根导航器）。
/// TV 遥控器快捷键（如搜索键）需要压栈到该嵌套导航器上，而不是根导航器
/// （根导航器会被门控盖住，破坏登录/登出回退规则）。门控挂载时通过
/// [attach] 注册其嵌套 key，服务/快捷键即可用 [push]/[pushNamed] 导航。
class AppNavigator {
  AppNavigator._();

  static GlobalKey<NavigatorState>? _baseNavKey;

  /// 由 `_AppStartupGateState` 在 build 时注册当前账号的嵌套导航 key。
  static void attach(GlobalKey<NavigatorState>? key) {
    _baseNavKey = key;
  }

  /// 当前账号的嵌套导航器，未挂载时为 null。
  static NavigatorState? get state => _baseNavKey?.currentState;

  /// 向嵌套导航器压栈（无嵌套导航器时安全失败）。
  static void pushNamed(String routeName, {Object? arguments}) {
    _baseNavKey?.currentState?.pushNamed(routeName, arguments: arguments);
  }
}
