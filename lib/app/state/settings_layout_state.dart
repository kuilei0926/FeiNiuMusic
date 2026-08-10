import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const String _prefsTrackChangeToastScale =
      'setting_track_change_toast_scale';
  static const String _prefsTrackChangeOverlayNotify =
      'setting_track_change_overlay_notify';

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

  /// 桌面端（Windows）恒用平板/大屏布局：侧边栏外壳，无需屏幕尺寸判定。
  static bool get _forceTabletOnDesktop =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 有效平板模式：Windows 桌面端恒为真；其余平台取用户开关或 TV 模式。
  ///
  /// TV 与平板共用同一套桌面式布局外壳；TV 只是额外强制开启 + 焦点导航。
  static bool get effectiveTabletMode =>
      _forceTabletOnDesktop || tabletMode.value || tvMode.value;

  /// 切歌通知开关：切歌时应用内弹出「正在播放」提示。
  static final ValueNotifier<bool> trackChangeNotify = ValueNotifier(false);

  /// 切歌通知·应用外通知子开关：后台播放切歌时用悬浮窗显示（需悬浮窗权限）。
  static final ValueNotifier<bool> trackChangeOverlayNotify = ValueNotifier(false);

  /// 切歌提示展示时长（毫秒），默认 3s，范围 2s–10s。
  static final ValueNotifier<int> trackChangeToastDurationMs =
      ValueNotifier(3000);

  /// 平板/TV 切歌卡片大小倍数，默认 1.0（当前大小），范围 1.0–3.0。
  static final ValueNotifier<double> trackChangeToastScale =
      ValueNotifier(1.0);

  /// 首次大屏默认值是否已应用过（同会话只应用一次）。
  static bool _firstUseLargeScreenApplied = false;

  /// 平板判定阈值：屏幕最短边（dp）≥ 该值视为平板（大屏）。
  ///
  /// 对齐 Android sw600dp 惯例：≥600dp 的屏幕（常见 7"+ 平板 / 折叠屏展开态）
  /// 走桌面式布局与切歌弹窗等大屏体验。
  static const double tabletMinShortestSide = 600;

  /// 是否为 TV 或平板（大屏）。
  ///
  /// TV 由 [tvMode] 判定（自动检测或手动强制）；平板用屏幕最短边 dp 判定，
  /// 传入 [shortestSide]（`MediaQuery.sizeOf(context).shortestSide` 即物理
  /// 最短边 / devicePixelRatio，dp 单位）。
  static bool isLargeScreen({
    required bool isTv,
    required double shortestSide,
  }) {
    return isTv || shortestSide >= tabletMinShortestSide;
  }

  /// 依据设备类型返回应启用的屏幕方向。
  ///
  /// - TV：恒横屏（左右两方向）；
  /// - 平板（最短边 ≥ [tabletMinShortestSide]）或手动开启平板模式：
  ///   四方向自由旋转（还原 1.2.9 之前的行为）；
  /// - 手机：锁竖屏。
  static List<DeviceOrientation> orientationsForDevice({
    required bool isTv,
    required double shortestSide,
    bool manualTabletMode = false,
  }) {
    if (isTv) {
      return const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    if (shortestSide >= tabletMinShortestSide || manualTabletMode) {
      return const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const [DeviceOrientation.portraitUp];
  }

  /// 当前窗口逻辑尺寸最短边（dp），无视图时返回 0。
  ///
  /// 用 `WidgetsBinding.instance.platformDispatcher.views` 读取首个视图的
  /// 物理尺寸 / devicePixelRatio，等价于 `MediaQuery.sizeOf(context).shortestSide`，
  /// 但无需 BuildContext，可在 runApp 前的 main() 中调用。
  static double currentShortestSide() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 0;
    final view = views.first;
    return (view.physicalSize / view.devicePixelRatio).shortestSide;
  }

  /// 首次使用：检测为 TV 或平板（大屏）时自动开启「切歌弹窗」开关。
  ///
  /// 首次引导会话（[isFirstLaunch] 为 true）且设备为大屏时，开启切歌通知，
  /// 让电视/平板在切歌时看到「正在播放」提示（设置页该开关注释即为大屏场景
  /// 设计）。仅首次生效，老用户重启不改动任何开关。
  ///
  /// 同会话只应用一次：应用后置位内部标记，用户随后手动关闭不会被重新开启；
  /// 由引导页完成时（main() 首帧前的门控）调用一次。
  static Future<void> applyFirstUseLargeScreenDefaults({
    required bool isFirstLaunch,
    required bool isTv,
    required double shortestSide,
  }) async {
    if (!isFirstLaunch) return;
    if (_firstUseLargeScreenApplied) return;
    if (!isLargeScreen(isTv: isTv, shortestSide: shortestSide)) return;
    // Windows 桌面端跳过：不自动开启切歌弹窗（保持默认关闭），
    // 用户如需可到设置页手动开启。
    if (_forceTabletOnDesktop) return;
    _firstUseLargeScreenApplied = true;
    await setTrackChangeNotify(true);
  }

  /// 播放页路由当前是否激活（由 PlayerPage initState/dispose 置位）。
  /// TabletLayoutHost 据此在 TV 模式隐藏侧栏与迷你播放器。
  static final ValueNotifier<bool> playerRouteActive = ValueNotifier(false);

  /// 模态底部面板（歌曲信息 sheet 等）当前是否打开。
  ///
  /// 手机端页面内渲染的迷你播放器会被模态 sheet（Navigator 路由）自然盖住；
  /// 但平板/TV/Windows 的迷你播放器由 TabletLayoutHost 外壳渲染，位于
  /// Navigator 之外，sheet 盖不住它，会挡住 sheet 底部的操作按钮。Sheet 类
  /// initState/dispose 置位/复位此信号，外壳据此隐藏迷你播放器。
  static final ValueNotifier<bool> modalSheetActive = ValueNotifier(false);

  /// 当前页面栈上「隐藏迷你播放器」的页面计数。
  ///
  /// 手机端各页面通过 `AppPageScaffold.showMiniPlayer: false`（设置页、播放页、
  /// 各种全屏页等）隐藏迷你播放器；但平板/TV/Windows 的迷你播放器由外壳
  /// 统一渲染，无视页面的该参数。AppPageScaffold 在 `showMiniPlayer == false`
  /// 时自增此计数、dispose 时自减，外壳据此隐藏迷你播放器。
  static final ValueNotifier<int> miniPlayerSuppressedCount = ValueNotifier(0);

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
    trackChangeOverlayNotify.value =
        prefs.getBool(_prefsTrackChangeOverlayNotify) ?? false;
    trackChangeToastDurationMs.value = _clampTrackChangeDuration(
      prefs.getInt(_prefsTrackChangeToastDurationMs) ?? 3000,
    );
    trackChangeToastScale.value = _clampTrackChangeScale(
      prefs.getDouble(_prefsTrackChangeToastScale) ?? 1.0,
    );
  }

  /// 钳制切歌提示时长到 2s–10s。
  static int _clampTrackChangeDuration(int ms) => ms.clamp(2000, 10000);

  /// 钳制切歌卡片大小倍数到 1.0–3.0。
  static double _clampTrackChangeScale(double scale) => scale.clamp(1.0, 3.0);

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

  static Future<void> setTrackChangeOverlayNotify(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsTrackChangeOverlayNotify, enabled);
    trackChangeOverlayNotify.value = enabled;
  }

  static Future<void> setTrackChangeToastDurationMs(int ms) async {
    final clamped = _clampTrackChangeDuration(ms);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsTrackChangeToastDurationMs, clamped);
    trackChangeToastDurationMs.value = clamped;
  }

  static Future<void> setTrackChangeToastScale(double scale) async {
    final clamped = _clampTrackChangeScale(scale);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsTrackChangeToastScale, clamped);
    trackChangeToastScale.value = clamped;
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
    trackChangeOverlayNotify.value = false;
    trackChangeToastDurationMs.value = 3000;
    trackChangeToastScale.value = 1.0;
    playerRouteActive.value = false;
    _firstUseLargeScreenApplied = false;
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
