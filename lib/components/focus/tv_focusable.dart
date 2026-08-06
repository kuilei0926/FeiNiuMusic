import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// TV 焦点环包装：给可聚焦控件加一圈明显的主题色描边 + 轻微放大，
/// 并在获得焦点时响应遥控器确认键（Enter/Space/Select）。
///
/// 使用方式（`tvEnabled` 时套用）：
/// ```dart
/// TvFocusable(
///   borderRadius: BorderRadius.circular(16),
///   onActivate: onTap,   // 与 child 的 InkWell.onTap 相同，Enter 触发
///   child: InkWell(onTap: onTap, child: card),
/// )
/// ```
///
/// 设计要点：
/// - 自身即唯一的焦点目标：`descendantsAreFocusable: false` 屏蔽 child 内部
///   InkWell/ListTile 自带的焦点节点，避免同一个控件出现两个焦点目标导致
///   方向键遍历跳变。child 的点击手势不受影响（手势不依赖焦点）。
/// - 获得焦点时按键 Enter/Space/Select → 调 [onActivate]。未提供则只画环。
/// - Material 控件（InkWell/ListTile）在 TV 模式下已通过主题 `focusColor`
///   显示焦点色（无需本组件）；本组件用于 hero/轮播/网格卡等需要描边强调
///   的可聚焦元素。
class TvFocusable extends StatefulWidget {
  final Widget child;
  final BorderRadius? borderRadius;
  final double ringWidth;
  final bool autofocus;
  final VoidCallback? onActivate;

  const TvFocusable({
    super.key,
    required this.child,
    this.borderRadius,
    this.ringWidth = 3,
    this.autofocus = false,
    this.onActivate,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  final FocusNode _ownNode = FocusNode();

  @override
  void dispose() {
    _ownNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final isActivate = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space;
    if (!isActivate) return KeyEventResult.ignored;
    widget.onActivate?.call();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      focusNode: _ownNode,
      autofocus: widget.autofocus,
      descendantsAreFocusable: false,
      descendantsAreTraversable: false,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: _handleKey,
      child: AnimatedScale(
        scale: _focused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: _focused
                ? Border.all(color: Colors.white, width: 3)
                : Border.all(color: Colors.transparent, width: 3),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.30),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          // 焦点态：主题色半透明铺底，让 3 米外也能一眼看到选中项。
          // 白色描边保证在浅色/深色主题上都清晰。
          child: _focused
              ? Stack(
                  children: [
                    widget.child,
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.28),
                          borderRadius: widget.borderRadius,
                        ),
                      ),
                    ),
                  ],
                )
              : widget.child,
        ),
      ),
    );
  }
}
