import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../state/settings_state.dart';

/// 统一的玻璃表面观感（与底栏 [GlassTabBar.bottom] 内部校准值一致）。
///
/// 作为底栏显式传入的完整参数；同时 [appGlassTheme] 用同一组字段构造
/// theme 覆盖，保证所有继承 GlassTheme 的玻璃表面（迷你播放器 / 设置面板 /
/// 弹窗 / sheet / 交互件）与底栏完全同步：
/// - `thickness: 30` —— 深折射，玻璃后的图标/文字有明显光学位移；
/// - `blur: 3` —— 轻底色模糊（折射主导，而非单纯的毛玻璃）；
/// - `glassColor: 白 24%` —— 底栏校准的着色；
/// - 其余（光照角度 135°、折射率 1.59、饱和度 0.7、色差 0.3 等）同为底栏数值。
const LiquidGlassSettings kAppGlassSurfaceSettings = LiquidGlassSettings(
  thickness: 30,
  blur: 3,
  chromaticAberration: 0.3,
  lightIntensity: 0.6,
  refractiveIndex: 1.59,
  saturation: 0.7,
  ambientStrength: 1,
  lightAngle: 0.75 * math.pi,
  glassColor: Color(0x3DFFFFFF),
);

/// 构建 App 全局液体玻璃主题。
///
/// **重要**：theme 的表面字段**必须直接以底栏完整参数构造**，不能从包推荐
/// [GlassThemeVariant.light/dark.settings] `copyWith` 派生——包推荐 base 带
/// 额外的「通透」字段（whitenStrength / fresnelStrength / edgeAbsorption 等），
/// 会混进继承 theme 的表面容器，造成它们与底栏（LiquidGlassSettings 全默认
/// base）观感不一致（表现为迷你播放器等「像高斯模糊、不通透」）。
///
/// 这里用与 [kAppGlassSurfaceSettings] 相同的字段构造 partial override，
/// `applyTo(默认 base)` 后即与底栏完全一致；再叠加用户可调的模糊强度 / 厚度
/// （[AppGlassSettings]，默认即底栏数值 blur 3 / thickness 30）。辉光主色
/// [seed] 跟随 App 主题种子色。
GlassThemeData appGlassTheme(Color seed) {
  final blur = AppGlassSettings.glassBlurStrength.value;
  final thickness = AppGlassSettings.glassThickness.value;

  // 与 kAppGlassSurfaceSettings 同字段的 partial override（不继承包推荐 base）。
  GlassThemeSettings surfaceFor() => const GlassThemeSettings(
    thickness: 30,
    blur: 3,
    chromaticAberration: 0.3,
    lightIntensity: 0.6,
    refractiveIndex: 1.59,
    saturation: 0.7,
    ambientStrength: 1,
    lightAngle: 0.75 * math.pi,
    glassColor: Color(0x3DFFFFFF),
  ).copyWith(
    blur: blur,
    thickness: thickness,
  );

  return GlassThemeData(
    light: GlassThemeVariant.light.copyWith(
      settings: surfaceFor(),
      glowColors: GlassGlowColors(primary: seed),
    ),
    dark: GlassThemeVariant.dark.copyWith(
      settings: surfaceFor(),
      glowColors: GlassGlowColors(primary: seed),
    ),
  );
}
