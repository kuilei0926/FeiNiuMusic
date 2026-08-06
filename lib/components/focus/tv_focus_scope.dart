import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/utils/app_navigator.dart';
import '../../app/tv/tv_remote_actions.dart';

/// TV 根焦点域：包裹整个应用内容，提供遥控器方向键遍历 + 快捷键。
///
/// 只在 `tvEnabled` 时由 `MaterialApp.builder` 安装；手机端完全不参与。
///
/// 职责：
/// - [FocusTraversalGroup]（ReadingOrder 策略）：方向键按视觉阅读序移动焦点；
/// - 方向键边缘动作：任何节点按「右键」且右侧已无可聚焦目标时打开播放页；
/// - [TvRemoteActions]：非传输键快捷键（搜索/快进/快退）；
/// - 强制 Material 高亮策略为 `alwaysTraditional`：否则 touch 分类的输入
///   设备（TV 盒子）上 Material 不渲染焦点高亮，焦点环会不可见。
class TvFocusScope extends StatefulWidget {
  final Widget child;

  const TvFocusScope({super.key, required this.child});

  @override
  State<TvFocusScope> createState() => _TvFocusScopeState();
}

class _TvFocusScopeState extends State<TvFocusScope> {
  @override
  void initState() {
    super.initState();
    // Touch 分类设备（TV 盒子、模拟器）上 Material 默认不显示焦点高亮；
    // 强制传统模式让主题 focusColor 在所有设备上渲染。
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  @override
  void dispose() {
    // 退出 TV 模式时复位为 touch 策略，避免手机端残留传统焦点高亮。
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: buildTvShortcuts(),
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: TvRemoteActions(
          // TV 方向键边缘动作：任何节点按「右键」，若整棵焦点树里右侧已无
          // 任何可聚焦目标（focusInDirection 返回 false），直接打开播放页。
          // 输入框/滑块有更内层的 Shortcuts，聚焦时会先处理方向键，不会
          // 触发这里。左键不处理：侧栏由 parentScope 几何定位直达。
          child: Actions(
            actions: <Type, Action<Intent>>{
              DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
                onInvoke: (intent) {
                  final node = FocusManager.instance.primaryFocus;
                  if (node == null) return null;
                  if (intent.direction != TraversalDirection.right) {
                    // 非右键走默认方向键行为。
                    node.focusInDirection(intent.direction);
                    return null;
                  }
                  // 右键：先正常尝试向右移动；移到尽头（false）则打开播放页。
                  final moved = node.focusInDirection(
                    TraversalDirection.right,
                  );
                  if (!moved) {
                    AppNavigator.pushNamed(AppRoutes.player);
                  }
                  return null;
                },
              ),
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
