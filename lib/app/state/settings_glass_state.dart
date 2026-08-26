import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/android_platform_service.dart';
import 'settings_background_state.dart';
import 'settings_layout_state.dart';

/// 液体玻璃（liquid_glass_widgets）设置状态。
///
/// 与现有「高斯模糊」（[AppBackgroundSettings]）**互斥**：
/// 开启液体玻璃会自动关闭高斯模糊，反之亦然；两者不会同时生效。
/// 开启时各界面渲染液体玻璃材质；关闭时回退为原有 BackdropFilter/实色方案。
///
/// 默认仅在 Android 13+（API 33+）开启，其余平台（含更早 Android 版本）
/// 默认关闭；老用户保留自己的选择。开启后可调 [glassBlurStrength] /
/// [glassThickness] 等参数。
class AppGlassSettings {
  static const String _prefsLiquidGlassEnabled =
      'setting_liquid_glass_enabled';
  static const String _prefsGlassBlur = 'setting_liquid_glass_blur';
  static const String _prefsGlassThickness =
      'setting_liquid_glass_thickness';

  /// 默认开关：仅 Android 13+（API 33+）默认开启，其余平台默认关闭。
  ///
  /// 初始为 false（保守值），在 [_doLoad] 按平台/系统版本校正后，
  /// 作为「新装用户」（无历史设置）的默认值；老用户保留自己持久化的选择。
  static bool defaultLiquidGlassEnabled = false;

  /// 液体玻璃总开关（Android 13+ 默认开启，其余平台默认关闭）。
  static final ValueNotifier<bool> liquidGlassEnabled =
      ValueNotifier(defaultLiquidGlassEnabled);

  /// 玻璃模糊强度（0-16，默认 3 = 与底栏玻璃观感一致的浅模糊）。
  static final ValueNotifier<double> glassBlurStrength = ValueNotifier(3);

  /// 玻璃厚度（0-30，默认 30 = 与底栏玻璃观感一致的深折射）：影响折射强度
  /// 与边缘高光。
  static final ValueNotifier<double> glassThickness = ValueNotifier(30);

  /// 生效值：总开关开启 **且** 非 TV 模式。
  ///
  /// TV 模式整体排除液体玻璃：玻璃组件自带 FocusNode / 键盘焦点处理，
  /// 会与 App 的 TV 方向键几何遍历（TvFocusScope / TvPlayerFocusScope）冲突。
  static bool get effectiveEnabled {
    return liquidGlassEnabled.value && !AppLayoutSettings.tvMode.value;
  }

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    // 先确保高斯模糊已加载（main.dart 中亦在其后调用，这里是兜底），
    // 互斥校正需要读取 panelBlurEnabled 的最终值。
    await AppBackgroundSettings.ensureLoaded();
    // 默认开关：仅 Android 13+（API 33+）默认开启，其余平台（含更早
    // Android 版本）默认关闭。sdkInt() 非 Android 平台返回 0。
    defaultLiquidGlassEnabled =
        await AndroidPlatformService.instance.sdkInt() >= 33;
    final prefs = await SharedPreferences.getInstance();
    liquidGlassEnabled.value =
        prefs.getBool(_prefsLiquidGlassEnabled) ?? defaultLiquidGlassEnabled;
    glassBlurStrength.value =
        (prefs.getDouble(_prefsGlassBlur) ?? 3).clamp(0.0, 16.0);
    glassThickness.value =
        (prefs.getDouble(_prefsGlassThickness) ?? 30).clamp(0.0, 30.0);
    // 互斥校正：若旧数据两者同时为开（历史版本允许同开），液体玻璃优先——
    // 关闭高斯模糊并持久化，保证重启后仍互斥。
    if (liquidGlassEnabled.value &&
        AppBackgroundSettings.panelBlurEnabled.value) {
      await AppBackgroundSettings.setPanelBlurEnabled(false);
    }
  }

  static Future<void> setLiquidGlassEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsLiquidGlassEnabled, enabled);
    liquidGlassEnabled.value = enabled;
    // 互斥：开启液体玻璃时关闭高斯模糊。
    if (enabled) {
      await AppBackgroundSettings.setPanelBlurEnabled(false);
    }
  }

  static Future<void> setGlassBlur(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final next = value.clamp(0.0, 16.0);
    await prefs.setDouble(_prefsGlassBlur, next);
    glassBlurStrength.value = next;
  }

  static Future<void> setGlassThickness(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final next = value.clamp(0.0, 30.0);
    await prefs.setDouble(_prefsGlassThickness, next);
    glassThickness.value = next;
  }
}
