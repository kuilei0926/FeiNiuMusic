import 'package:flutter/material.dart';

import '../../../app/state/settings_background_state.dart';

/// 首页模块底色透明度独立于内容，避免文字与封面一起变淡。
class HomePanel extends StatelessWidget {
  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;
  final Clip clipBehavior;

  const HomePanel({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.clipBehavior = Clip.antiAlias,
  });

  @override
  Widget build(BuildContext context) {
    final base = color ?? Theme.of(context).colorScheme.surfaceContainerLow;
    return AnimatedBuilder(
      animation: Listenable.merge([
        AppBackgroundSettings.backgroundImagePath,
        AppBackgroundSettings.homeCardOpacity,
      ]),
      child: child,
      builder: (context, child) => Material(
        color: base.withValues(
          alpha: base.a * AppBackgroundSettings.effectiveHomeCardOpacity,
        ),
        borderRadius: borderRadius,
        clipBehavior: clipBehavior,
        child: child,
      ),
    );
  }
}
