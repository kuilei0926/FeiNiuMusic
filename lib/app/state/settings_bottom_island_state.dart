import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BottomIslandStyle { legacy, c1, c2, c3 }

class BottomIslandSettings {
  static const String _prefsStyle = 'setting_bottom_island_style_v1';

  static final ValueNotifier<BottomIslandStyle> style = ValueNotifier(
    BottomIslandStyle.legacy,
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
      if (!prefs.containsKey(_prefsStyle)) {
        // Must run before startup services write preferences. An incomplete
        // onboarding flag alone cannot distinguish older installs from new ones.
        final initialStyle = prefs.getKeys().isEmpty
            ? BottomIslandStyle.c1
            : BottomIslandStyle.legacy;
        await _persist(prefs, initialStyle);
      }
      style.value = _decode(prefs.get(_prefsStyle));
      _loaded = true;
    } catch (error, stack) {
      style.value = BottomIslandStyle.legacy;
      if (kDebugMode) {
        debugPrint('[BottomIslandSettings] load failed: $error\n$stack');
      }
    }
  }

  static BottomIslandStyle _decode(Object? value) => switch (value) {
    'c1' => BottomIslandStyle.c1,
    'c2' => BottomIslandStyle.c2,
    'c3' => BottomIslandStyle.c3,
    _ => BottomIslandStyle.legacy,
  };

  static Future<void> setStyle(BottomIslandStyle value) {
    final write = (_pendingWrite ?? Future<void>.value()).then((_) async {
      await ensureLoaded();
      if (!_loaded) {
        throw StateError('无法读取底栏设置，请重试');
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
    BottomIslandStyle value,
  ) async {
    try {
      if (!await prefs.setString(_prefsStyle, value.name)) {
        throw StateError('无法保存底栏设置，请重试');
      }
    } catch (error, stack) {
      // SharedPreferences updates its cache before the platform write succeeds.
      try {
        await prefs.reload();
      } catch (reloadError) {
        if (kDebugMode) {
          debugPrint('[BottomIslandSettings] reload failed: $reloadError');
        }
      }
      if (kDebugMode) {
        debugPrint('[BottomIslandSettings] save failed: $error\n$stack');
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _loaded = false;
    _loading = null;
    _pendingWrite = null;
    style.value = BottomIslandStyle.legacy;
  }
}
