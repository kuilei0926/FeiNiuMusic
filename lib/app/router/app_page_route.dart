import 'package:flutter/material.dart';

/// 应用统一的页面路由：在 [MaterialPageRoute] 基础上缩短转场时长，
/// 让二级页面（设置子页、详情页等）的进入/返回更快、更轻快。
class AppPageRoute<T> extends MaterialPageRoute<T> {
  AppPageRoute({
    required super.builder,
    super.settings,
  });

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);
}

PageRoute<T> buildAppPageRoute<T>(
  WidgetBuilder builder, {
  RouteSettings? settings,
}) {
  return AppPageRoute<T>(builder: builder, settings: settings);
}
