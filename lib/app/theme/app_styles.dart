import 'package:flutter/material.dart';

import '../state/settings_background_state.dart';
import '../state/settings_theme_state.dart';

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class CoverPageTransitionsBuilder extends PageTransitionsBuilder {
  const CoverPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Incoming page: ease in from the right with a short fade.
    // 轻量化转场：滑动幅度更小、淡入更早到位，配合 AppPageRoute 缩短时长后
    // 进入/返回更干脆，避免长距离滑动的拖拽感。
    final inCurve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final slideIn = inCurve.drive(
      Tween(begin: const Offset(0.10, 0), end: Offset.zero),
    );
    final fadeIn = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
      reverseCurve: const Interval(0.4, 1.0, curve: Curves.easeIn),
    );

    Widget result = SlideTransition(
      position: slideIn,
      child: FadeTransition(opacity: fadeIn, child: child),
    );

    // Outgoing page (covered by a new route): subtle parallax to the left so
    // the stack feels layered instead of a flat cross-slide.
    if (secondaryAnimation.status != AnimationStatus.dismissed) {
      final outCurve = CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      result = SlideTransition(
        position: outCurve.drive(
          Tween(begin: Offset.zero, end: const Offset(-0.05, 0)),
        ),
        child: result,
      );
    }
    return result;
  }
}

extension AppThemeSurfaceX on ThemeData {
  bool get hasAmbientBackground {
    final backgroundPath = AppBackgroundSettings.backgroundImagePath.value;
    return AppBackgroundSettings.pageGlowEnabled.value ||
        (backgroundPath != null && backgroundPath.trim().isNotEmpty);
  }

  /// 模糊时用纯黑/纯白极低不透明度打底，背景清晰透出；
  /// 无模糊时保持原有半透明面板（85%）。
  Color get appPanelColor {
    final panelBlur = AppBackgroundSettings.panelBlurStrength.value;
    final hasBlur = panelBlur > 0;
    if (hasBlur) {
      // 启用高斯模糊：底色几乎透明，模糊效果靠 BackdropFilter 实现
      final isDark = brightness == Brightness.dark;
      return isDark
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.white.withValues(alpha: 0.06);
    }
    // 无模糊时保持原有半透明面板
    final isDark = brightness == Brightness.dark;
    final base = isDark
        ? Color.alphaBlend(
            colorScheme.primary.withValues(alpha: 0.08),
            colorScheme.surfaceContainerHigh,
          )
        : Color.alphaBlend(
            colorScheme.primary.withValues(alpha: 0.12),
            Colors.white,
          );
    return base.withValues(alpha: 0.85);
  }

  Color get appPanelShadowColor {
    if (AppThemeSettings.visualStyle.value == AppVisualStyle.miuix) {
      return Colors.transparent;
    }
    final isDark = brightness == Brightness.dark;
    return isDark
        ? Colors.black.withValues(alpha: 0.35)
        : colorScheme.primary.withValues(alpha: 0.16);
  }

  Color get appPanelBorderColor {
    if (AppThemeSettings.visualStyle.value == AppVisualStyle.miuix) {
      return Colors.transparent;
    }
    final isDark = brightness == Brightness.dark;
    return isDark
        ? colorScheme.outline.withValues(alpha: 0.36)
        : colorScheme.primary.withValues(alpha: 0.12);
  }

  Color get appPanelElevatedColor {
    if (AppThemeSettings.visualStyle.value == AppVisualStyle.miuix) {
      return colorScheme.surfaceContainerHigh;
    }
    final base = appPanelColor;
    if (base.a <= 0) return Colors.transparent;
    final overlay = brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.25);
    return Color.alphaBlend(overlay, base);
  }
}
