import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../app/theme/app_styles.dart';

/// Solid-but-optionally-transparent panel container.
///
/// Previously this used `BackdropFilter` to blur whatever was underneath, but
/// the blur was expensive, its "on/off" switch made the transparency slider
/// look broken, and users just wanted a panel whose opacity they could tune.
/// The widget name is kept for backwards compatibility with all the call
/// sites — think of it now as "the app's standard panel", not a blur.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadiusGeometry borderRadius;
  final Color? color;
  final Color? borderColor;
  final Color? shadowColor;
  final List<BoxShadow>? boxShadow;
  // Kept for source compatibility — no longer honoured. Left as `double?` so
  // callers can keep passing their old `blurSigma:` args without a compile
  // error, and so a future replacement (e.g. a subtle inner highlight tied to
  // this value) could reuse the parameter.
  final double? blurSigma;
  final VoidCallback? onTap;
  final double? height;
  /// 是否允许本面板使用背景高斯模糊。
  ///
  /// - null（默认）= 跟随全局「面板模糊」总开关与强度
  /// - false = 强制不用背景模糊，渲染纯色半透明面板
  ///
  /// 滚动列表内的面板（如设置分组）必须显式传 false：滚动时背景逐帧变化，
  /// BackdropFilter 会每帧重采样整块区域，是滚动掉帧的主因。
  final bool? backdropBlur;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.color,
    this.borderColor,
    this.shadowColor,
    this.boxShadow,
    this.blurSigma,
    this.onTap,
    this.height,
    this.backdropBlur,
  });

  BorderRadius get _resolvedBorderRadius {
    final value = borderRadius;
    if (value is BorderRadius) return value;
    return BorderRadius.circular(20);
  }

  @override
  Widget build(BuildContext context) {
    // 显式关闭背景模糊：直接渲染纯色半透明面板，不订阅两个全局
    // ValueNotifier，也不包 BackdropFilter（避免滚动列表内逐帧重采样掉帧）。
    if (backdropBlur == false) {
      return _buildPanel(context, 0.0);
    }
    // Listen to panelBlurStrength + panelBlurEnabled so dragging the
    // "高斯模糊强度" slider or toggling the master switch updates every panel
    // instantly, without needing to leave and re-enter the page.
    return ValueListenableBuilder<double>(
      valueListenable: AppBackgroundSettings.panelBlurStrength,
      builder: (context, blurStrength, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: AppBackgroundSettings.panelBlurEnabled,
          builder: (context, blurEnabled, _) {
            final effective =
                blurEnabled ? blurStrength : 0.0;
            return _buildPanel(context, effective);
          },
        );
      },
    );
  }

  Widget _buildPanel(BuildContext context, double blurStrength) {
    final theme = Theme.of(context);
    final hasBlur = blurStrength > 0;
    // 本面板实际是否模糊决定底色：模糊时近透明（靠 BackdropFilter），
    // 不模糊时用不透明半透明实色，避免「无模糊却近透明」导致面板看不见。
    final resolvedColor = color ??
        (hasBlur ? theme.appPanelColor : theme.appPanelColorSolid);
    final resolvedBorderColor = borderColor ?? theme.appPanelBorderColor;
    final resolvedShadowColor = shadowColor ?? theme.appPanelShadowColor;
    final isInvisible = resolvedColor.a <= 0;
    final resolvedShadow =
        boxShadow ??
        (isInvisible
            ? const <BoxShadow>[]
            : [
                BoxShadow(
                  color: resolvedShadowColor,
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ]);

    final panel = Container(
      height: height,
      decoration: BoxDecoration(
        color: resolvedColor,
        borderRadius: _resolvedBorderRadius,
        border: isInvisible ? null : Border.all(color: resolvedBorderColor),
        boxShadow: resolvedShadow,
      ),
      child: padding == null
          ? child
          : Padding(padding: padding!, child: child),
    );

    final material = Material(
      color: Colors.transparent,
      child: onTap == null
          ? panel
          : InkWell(
              borderRadius: _resolvedBorderRadius,
              onTap: onTap,
              child: panel,
            ),
    );

    Widget result = ClipRRect(
      borderRadius: _resolvedBorderRadius,
      child: material,
    );

    // 启用高斯模糊时叠加 BackdropFilter。
    // 用 RepaintBoundary 把模糊合成隔离到独立图层：页面切换转场期间
    // 底层页面在滑动/淡出时，模糊结果被图层缓存复用，不再逐帧全屏重采样，
    // 显著降低掉帧（BackdropFilter 的模糊采样是页面切换卡顿的主要来源）。
    if (blurStrength > 0) {
      result = ClipRRect(
        borderRadius: _resolvedBorderRadius,
        child: RepaintBoundary(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: blurStrength, sigmaY: blurStrength),
            child: result,
          ),
        ),
      );
    }

    return result;
  }
}
