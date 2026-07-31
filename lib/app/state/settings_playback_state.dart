import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  static bool hasHandledAutoPlayThisSession = false;

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

/// 启动后是否自动打开播放界面
class AppLaunchNavigationSettings {
  static const String _prefsAutoOpenPlayerOnLaunch =
      'app_auto_open_player_on_launch';

  static final ValueNotifier<bool> autoOpenPlayerOnLaunch =
      ValueNotifier(false);

  /// 标记本次 session 是否已处理过启动跳转（仅启动首次生效）
  static bool hasHandledNavigationThisSession = false;

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
}
