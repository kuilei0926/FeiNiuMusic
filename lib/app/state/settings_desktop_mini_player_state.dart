import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DesktopMiniPlayerStyle { classic, vinyl }

class DesktopMiniPlayerSettings {
  static const String _prefsStyle = 'desktop_mini_player_style';

  static final ValueNotifier<DesktopMiniPlayerStyle> style = ValueNotifier(
    DesktopMiniPlayerStyle.classic,
  );

  static bool _loaded = false;
  static Future<void>? _loading;
  static Future<void>? _pendingWrite;

  static Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  static Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      style.value = _decode(prefs.get(_prefsStyle));
      _loaded = true;
    } catch (error, stack) {
      style.value = DesktopMiniPlayerStyle.classic;
      if (kDebugMode) {
        debugPrint('[DesktopMiniPlayerSettings] load failed: $error\n$stack');
      }
    }
  }

  static DesktopMiniPlayerStyle _decode(Object? value) => switch (value) {
    'vinyl' => DesktopMiniPlayerStyle.vinyl,
    _ => DesktopMiniPlayerStyle.classic,
  };

  static Future<void> setStyle(DesktopMiniPlayerStyle value) {
    final write = (_pendingWrite ?? Future<void>.value()).then((_) async {
      await ensureLoaded();
      if (!_loaded) {
        throw StateError('无法读取桌面播放条设置，请重试');
      }
      final prefs = await SharedPreferences.getInstance();
      await _persist(prefs, value);
      style.value = value;
    });
    // A failed write must not poison the queue for later selections. The
    // original future still reports the failure to the caller for UI feedback.
    _pendingWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  static Future<void> _persist(
    SharedPreferences prefs,
    DesktopMiniPlayerStyle value,
  ) async {
    try {
      if (!await prefs.setString(_prefsStyle, value.name)) {
        throw StateError('无法保存桌面播放条设置，请重试');
      }
    } catch (error, stack) {
      // SharedPreferences updates its cache before the platform write succeeds.
      try {
        await prefs.reload();
      } catch (reloadError) {
        if (kDebugMode) {
          debugPrint('[DesktopMiniPlayerSettings] reload failed: $reloadError');
        }
      }
      if (kDebugMode) {
        debugPrint('[DesktopMiniPlayerSettings] save failed: $error\n$stack');
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _loaded = false;
    _loading = null;
    _pendingWrite = null;
    style.value = DesktopMiniPlayerStyle.classic;
  }
}
