import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首次启动引导页完成状态。
///
/// 与登录态无关：未标记完成则启动一律显示引导页（含老用户升级后首次打开，
/// 缺省为 false）；完成后（setCompleted）永不再显示。
class AppOnboardingSettings {
  static const String _prefsCompleted = 'app_onboarding_completed';

  static final ValueNotifier<bool> completed = ValueNotifier(false);

  /// 本次启动是否为「新用户首次启动」（启动时引导尚未完成）。
  ///
  /// 在 [ensureLoaded] 时记录（main() runApp 前，PlayerService 恢复播放的
  /// _restorePlaybackState 也在其后异步运行）。首次启动用户在引导页勾选的
  /// 启动设置（自动打开播放界面 / 进入应用自动播放）文案为「从下次启动生效」，
  /// 因此本次 session 内两个行为都必须抑制，等下次启动（isFirstLaunchSession
  /// 为 false）才生效。用「启动时」的快照而非「当前」的 completed，避免竞态：
  /// 异步恢复流程可能跑到引导完成之后才读标记，那时 completed 已变 true。
  static bool isFirstLaunchSession = false;

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    final wasCompleted = prefs.getBool(_prefsCompleted) ?? false;
    completed.value = wasCompleted;
    isFirstLaunchSession = !wasCompleted;
  }

  /// 标记引导完成：写持久化标记后更新 notifier，
  /// _AppStartupGate 外层监听随即切换到登录页/主外壳。
  static Future<void> setCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsCompleted, true);
    completed.value = true;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    completed.value = false;
    isFirstLaunchSession = false;
  }
}
