import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppNavigationStyle { drawer, bottomBar }

class AppLayoutSettings {
  static const String _prefsTabletMode = 'setting_tablet_mode';
  static const String _prefsNavigationStyle = 'setting_navigation_style';
  static const String _prefsForceTvMode = 'setting_force_tv_mode';
  static const String _prefsTvEdgeHintShown = 'setting_tv_edge_hint_shown';
  static const String _prefsTrackChangeNotify = 'setting_track_change_notify';
  static const String _prefsTrackChangeToastDurationMs =
      'setting_track_change_toast_duration_ms';

  /// TV 首次启动的「向右打开播放页」提示是否已展示过。
  static bool _tvEdgeHintShown = true;

  /// 用户手动开关的平板模式（设置页「平板模式」）。
  static final ValueNotifier<bool> tabletMode = ValueNotifier(false);
  static final ValueNotifier<AppNavigationStyle> navigationStyle =
      ValueNotifier(AppNavigationStyle.drawer);

  /// 强制 TV 模式（设置页「TV 模式」开关，持久化）。
  ///
  /// 供开发/调试：在手机或非 TV 设备上手动开启 TV 布局 + 遥控器焦点导航，
  /// 方便直接预览 TV 页面效果。与自动检测是「或」关系。
  static final ValueNotifier<bool> forceTvMode = ValueNotifier(false);

  /// TV 模式：由 [TvDetection] 自动检测，或用户手动强制开启。
  /// 由 [syncTvMode] 计算合并，不直接持久化（forceTvMode 才是持久化来源）。
  static final ValueNotifier<bool> tvMode = ValueNotifier(false);

  /// 有效平板模式：用户开关或 TV 模式任一为真。
  ///
  /// TV 与平板共用同一套桌面式布局外壳；TV 只是额外强制开启 + 焦点导航。
  static bool get effectiveTabletMode => tabletMode.value || tvMode.value;

  /// 切歌通知开关：切歌时应用内弹出「正在播放」提示。
  static final ValueNotifier<bool> trackChangeNotify = ValueNotifier(false);

  /// 切歌提示展示时长（毫秒），默认 3s，范围 2s–10s。
  static final ValueNotifier<int> trackChangeToastDurationMs =
      ValueNotifier(3000);

  /// 播放页路由当前是否激活（由 PlayerPage initState/dispose 置位）。
  /// TabletLayoutHost 据此在 TV 模式隐藏侧栏与迷你播放器。
  static final ValueNotifier<bool> playerRouteActive = ValueNotifier(false);

  /// [effectiveTabletMode] 的响应式版本：任一来源变化时通知。
  static final ValueNotifier<bool> effectiveTabletModeNotifier =
      _CombinedNotifier();

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    tabletMode.value = prefs.getBool(_prefsTabletMode) ?? false;
    final savedNavigationStyle = prefs.getString(_prefsNavigationStyle);
    navigationStyle.value = AppNavigationStyle.values.firstWhere(
      (style) => style.name == savedNavigationStyle,
      orElse: () => AppNavigationStyle.drawer,
    );
    forceTvMode.value = prefs.getBool(_prefsForceTvMode) ?? false;
    _tvEdgeHintShown = prefs.getBool(_prefsTvEdgeHintShown) ?? false;
    trackChangeNotify.value = prefs.getBool(_prefsTrackChangeNotify) ?? false;
    trackChangeToastDurationMs.value = _clampTrackChangeDuration(
      prefs.getInt(_prefsTrackChangeToastDurationMs) ?? 3000,
    );
  }

  /// 钳制切歌提示时长到 2s–10s。
  static int _clampTrackChangeDuration(int ms) => ms.clamp(2000, 10000);

  /// 是否应展示 TV 首次启动提示（未展示过）。展示后自动置位并持久化，
  /// 保证每次启动只提醒一次。
  static Future<bool> consumeTvEdgeHint() async {
    if (_tvEdgeHintShown) return false;
    _tvEdgeHintShown = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTvEdgeHintShown, true);
    return true;
  }

  /// 合并自动检测与手动强制：`tvMode = 自动检测 || 手动强制`。
  ///
  /// main() 在 [TvDetection.ensureLoaded] 后调用一次；设置页开关切换时再调用，
  /// 让 TV 布局/焦点系统即时生效（各监听方已用 ValueListenableBuilder 订阅）。
  static void syncTvMode() {
    tvMode.value = TvDetectionAutoValue.value || forceTvMode.value;
  }

  static Future<void> setTabletMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTabletMode, enabled);
    tabletMode.value = enabled;
  }

  static Future<void> setForceTvMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsForceTvMode, enabled);
    forceTvMode.value = enabled;
    syncTvMode();
  }

  static Future<void> setNavigationStyle(AppNavigationStyle style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsNavigationStyle, style.name);
    navigationStyle.value = style;
  }

  static Future<void> setTrackChangeNotify(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTrackChangeNotify, enabled);
    trackChangeNotify.value = enabled;
  }

  static Future<void> setTrackChangeToastDurationMs(int ms) async {
    final clamped = _clampTrackChangeDuration(ms);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsTrackChangeToastDurationMs, clamped);
    trackChangeToastDurationMs.value = clamped;
  }

  /// 测试用：重置懒加载与内存状态。
  @visibleForTesting
  static void resetForTest() {
    _loading = null;
    tabletMode.value = false;
    navigationStyle.value = AppNavigationStyle.drawer;
    forceTvMode.value = false;
    tvMode.value = false;
    _tvEdgeHintShown = true;
    trackChangeNotify.value = false;
    trackChangeToastDurationMs.value = 3000;
    playerRouteActive.value = false;
  }
}

/// 自动检测结果（TvDetection.result）的桥接。避免 settings_layout_state 直接
/// 依赖 TvDetection，造成状态类间耦合；由 main() 在检测完成后赋值。
class TvDetectionAutoValue {
  TvDetectionAutoValue._();

  static bool value = false;
}

/// 合成 [effectiveTabletMode] 的 notifier：监听两个来源并广播布尔值。
class _CombinedNotifier extends ValueNotifier<bool> {
  _CombinedNotifier() : super(_currentValue()) {
    AppLayoutSettings.tabletMode.addListener(_update);
    AppLayoutSettings.tvMode.addListener(_update);
  }

  static bool _currentValue() => AppLayoutSettings.effectiveTabletMode;

  void _update() {
    value = _currentValue();
  }
}
