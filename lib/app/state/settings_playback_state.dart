import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_onboarding_state.dart';
import 'settings_volume_schedule_state.dart';

class AppPlaybackVolumeSettings {
  static const String _prefsVolume = 'player_app_volume';

  static final ValueNotifier<double> volume = ValueNotifier(1);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    volume.value = (prefs.getDouble(_prefsVolume) ?? 1).clamp(0, 1);
  }

  static Future<void> setVolume(double value) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = value.clamp(0, 1).toDouble();
    await prefs.setDouble(_prefsVolume, normalized);
    volume.value = normalized;
    // 手动调节音量 → 记录恢复目标（仅未在生效时段内；内部自带防抖）。
    // 定时音量时间段结束或开关关闭后，恢复到这个值。
    await AppVolumeScheduleSettings.persistManualVolume(normalized);
  }
}

class WebDavPlaybackSettings {
  static const String _prefsPrefetchEnabled = 'webdav_prefetch_enabled';
  static const String _prefsSegmentedEnabled = 'webdav_segmented_enabled';
  static const String _prefsSegmentConcurrency = 'webdav_segment_concurrency';

  static final ValueNotifier<bool> prefetchEnabled = ValueNotifier(true);
  static final ValueNotifier<bool> segmentedEnabled = ValueNotifier(true);
  static final ValueNotifier<int> segmentConcurrency = ValueNotifier(4);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    prefetchEnabled.value = prefs.getBool(_prefsPrefetchEnabled) ?? true;
    segmentedEnabled.value = prefs.getBool(_prefsSegmentedEnabled) ?? true;
    segmentConcurrency.value = (prefs.getInt(_prefsSegmentConcurrency) ?? 4)
        .clamp(1, 8);
  }

  static Future<void> setPrefetchEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsPrefetchEnabled, enabled);
    prefetchEnabled.value = enabled;
  }

  static Future<void> setSegmentedEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsSegmentedEnabled, enabled);
    segmentedEnabled.value = enabled;
  }

  static Future<void> setSegmentConcurrency(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final value = count.clamp(1, 8);
    await prefs.setInt(_prefsSegmentConcurrency, value);
    segmentConcurrency.value = value;
  }
}

class AppLaunchPlaybackSettings {
  static const String _prefsAutoPlayOnAppLaunch =
      'player_auto_play_on_app_launch';

  static final ValueNotifier<bool> autoPlayOnAppLaunch = ValueNotifier(false);

  /// 判断本次启动是否应自动播放。
  ///
  /// 首次启动（[AppOnboardingSettings.isFirstLaunchSession]，启动时引导未完成）：
  /// 用户在引导页勾选「进入应用自动播放」只是写入持久化，必须等**下次启动**
  /// 才生效（引导页文案「这些设置从下次启动生效」），本次启动恢复流程不自动播放。
  ///
  /// 老用户（引导已完成，开关一直开着）重启时 isFirstLaunchSession 为 false，
  /// 正常生效。用启动时的快照判断，避免异步恢复流程读到引导完成后的状态。
  static bool shouldAutoPlayOnAppLaunch() {
    if (AppOnboardingSettings.isFirstLaunchSession) {
      return false;
    }
    return autoPlayOnAppLaunch.value;
  }

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    autoPlayOnAppLaunch.value =
        prefs.getBool(_prefsAutoPlayOnAppLaunch) ?? false;
  }

  static Future<void> setAutoPlayOnAppLaunch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoPlayOnAppLaunch, enabled);
    autoPlayOnAppLaunch.value = enabled;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    autoPlayOnAppLaunch.value = false;
  }
}

/// Whether to automatically check for app updates on launch and prompt the user.
class AppLaunchUpdateSettings {
  static const String _prefsAutoCheckUpdate = 'app_auto_check_update_on_launch';

  static final ValueNotifier<bool> autoCheckUpdateOnLaunch = ValueNotifier(
    true,
  );
  static bool hasCheckedUpdateThisSession = false;

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    autoCheckUpdateOnLaunch.value =
        prefs.getBool(_prefsAutoCheckUpdate) ?? true;
  }

  static Future<void> setAutoCheckUpdateOnLaunch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoCheckUpdate, enabled);
    autoCheckUpdateOnLaunch.value = enabled;
  }
}

class PlayerBottomActionSettings {
  static const String _prefsShowPlaybackMode =
      'player_bottom_show_playback_mode';
  static const String _prefsShowSleepTimer = 'player_bottom_show_sleep_timer';
  static const String _prefsShowPlaylist = 'player_bottom_show_playlist';
  static const String _prefsShowMore = 'player_bottom_show_more';
  static const String _prefsActionOrder = 'player_bottom_action_order';

  static const List<String> _defaultActionOrder = [
    'playback_mode',
    'sleep_timer',
    'playlist',
    'more',
  ];

  static final ValueNotifier<bool> showPlaybackMode = ValueNotifier(true);
  static final ValueNotifier<bool> showSleepTimer = ValueNotifier(true);
  static final ValueNotifier<bool> showPlaylist = ValueNotifier(true);
  static final ValueNotifier<bool> showMore = ValueNotifier(true);
  static final ValueNotifier<List<String>> actionOrder = ValueNotifier(
    _defaultActionOrder,
  );

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    showPlaybackMode.value = prefs.getBool(_prefsShowPlaybackMode) ?? true;
    showSleepTimer.value = prefs.getBool(_prefsShowSleepTimer) ?? true;
    showPlaylist.value = prefs.getBool(_prefsShowPlaylist) ?? true;
    showMore.value = prefs.getBool(_prefsShowMore) ?? true;
    actionOrder.value = _normalizeOrder(prefs.getStringList(_prefsActionOrder));
  }

  static Future<void> setActionOrder(List<String> order) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = _normalizeOrder(order);
    await prefs.setStringList(_prefsActionOrder, normalized);
    actionOrder.value = normalized;
  }

  static List<String> _normalizeOrder(List<String>? raw) {
    final seen = <String>{};
    final result = <String>[];
    if (raw != null) {
      for (final key in raw) {
        if (_defaultActionOrder.contains(key) && seen.add(key)) {
          result.add(key);
        }
      }
    }
    for (final key in _defaultActionOrder) {
      if (seen.add(key)) {
        result.add(key);
      }
    }
    return result;
  }

  static Future<void> setShowPlaybackMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowPlaybackMode, enabled);
    showPlaybackMode.value = enabled;
  }

  static Future<void> setShowSleepTimer(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowSleepTimer, enabled);
    showSleepTimer.value = enabled;
  }

  static Future<void> setShowPlaylist(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowPlaylist, enabled);
    showPlaylist.value = enabled;
  }

  static Future<void> setShowMore(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowMore, enabled);
    showMore.value = enabled;
  }
}

class MiniPlayerInfoSettings {
  static const String _prefsShowLyricsInSubtitle =
      'mini_player_show_lyrics_in_subtitle';

  static final ValueNotifier<bool> showLyricsInSubtitle = ValueNotifier(true);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    showLyricsInSubtitle.value =
        prefs.getBool(_prefsShowLyricsInSubtitle) ?? true;
  }

  static Future<void> setShowLyricsInSubtitle(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsShowLyricsInSubtitle, enabled);
    showLyricsInSubtitle.value = enabled;
  }
}

/// 播放队列长度上限：所有队列写入点（新队列、追加、插播）都会把队列
/// 截断到该上限以内，全局生效。10–1000，默认 200。
class AppPlaybackQueueSettings {
  static const String _prefsMaxQueueLength = 'player_queue_max_length';

  static const int defaultMaxQueueLength = 200;
  static const int minQueueLimit = 10;
  static const int maxQueueLimit = 1000;

  static final ValueNotifier<int> maxQueueLength = ValueNotifier(
    defaultMaxQueueLength,
  );

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_prefsMaxQueueLength);
    maxQueueLength.value = (stored ?? defaultMaxQueueLength)
        .clamp(minQueueLimit, maxQueueLimit);
  }

  static Future<void> setMaxQueueLength(int value) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = value.clamp(minQueueLimit, maxQueueLimit);
    await prefs.setInt(_prefsMaxQueueLength, normalized);
    maxQueueLength.value = normalized;
  }
}

/// 启动后是否自动打开播放界面
class AppLaunchNavigationSettings {
  static const String _prefsAutoOpenPlayerOnLaunch =
      'app_auto_open_player_on_launch';

  static final ValueNotifier<bool> autoOpenPlayerOnLaunch =
      ValueNotifier(false);

  /// 本次 session 是否已处理过「启动自动打开播放界面」。
  ///
  /// 首次启动引导页勾选该开关时，设置立即写入持久化，但必须等**下次启动**
  /// 才生效（引导页文案「这些设置从下次启动生效」）。通过标记「在引导完成
  /// 当次 session 内不自动打开」，区分「开关一直开着、本次是重启」与「本次
  /// 才在引导页打开、是首次启动」。
  static bool _hasHandledNavigationThisSession = false;

  static bool get hasHandledNavigationThisSession =>
      _hasHandledNavigationThisSession;

  /// 判断本次启动首帧后是否应自动打开播放页，并标记已处理（一次性）。
  ///
  /// 门控首帧只调用一次（app.dart _scheduleAutoOpenPlayer 的 isLoggedIn
  /// 分支仅首帧触发一次）。首次启动（isFirstLaunchSession，引导页刚勾选该
  /// 开关）不自动打开（等下次启动）；老用户重启正常生效。切换账号重建外壳
  /// 不会重复触发。
  static bool shouldAutoOpenPlayerOnLaunch() {
    if (_hasHandledNavigationThisSession) {
      return false;
    }
    _hasHandledNavigationThisSession = true;
    if (AppOnboardingSettings.isFirstLaunchSession) {
      return false;
    }
    return autoOpenPlayerOnLaunch.value;
  }

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    autoOpenPlayerOnLaunch.value =
        prefs.getBool(_prefsAutoOpenPlayerOnLaunch) ?? false;
  }

  static Future<void> setAutoOpenPlayerOnLaunch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoOpenPlayerOnLaunch, enabled);
    autoOpenPlayerOnLaunch.value = enabled;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存 + 会话标记），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    autoOpenPlayerOnLaunch.value = false;
    _hasHandledNavigationThisSession = false;
  }
}
