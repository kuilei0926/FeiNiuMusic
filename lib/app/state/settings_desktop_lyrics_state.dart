import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 桌面歌词的显示设置。
///
/// 颜色使用 ARGB 整数保存，位置使用 `free`（自由拖动）或 `locked`（锁定）。
class DesktopLyricsSettings {
  static const String _prefsEnabled = 'desktop_lyrics_enabled';
  static const String _prefsFontFamily = 'desktop_lyrics_font_family';
  static const String _prefsFontSize = 'desktop_lyrics_font_size';
  static const String _prefsTextColor = 'desktop_lyrics_text_color';
  static const String _prefsHighlightColor = 'desktop_lyrics_highlight_color';
  static const String _prefsPosition = 'desktop_lyrics_position';
  static const String _prefsLockedPositionX =
      'desktop_lyrics_locked_position_x';
  static const String _prefsLockedPositionY =
      'desktop_lyrics_locked_position_y';

  static const String positionFree = 'free';
  static const String positionLocked = 'locked';

  /// Empty means using the current platform's native default font.
  static const String defaultFontFamily = '';
  static const double defaultFontSize = 24;
  static const int defaultTextColor = 0xFFFFFFFF;
  static const int defaultHighlightColor = 0xFF59F7E7;
  static const String defaultPosition = positionFree;

  static final ValueNotifier<bool> enabled = ValueNotifier(false);
  static final ValueNotifier<String> fontFamily = ValueNotifier(
    defaultFontFamily,
  );
  static final ValueNotifier<double> fontSize = ValueNotifier(defaultFontSize);
  static final ValueNotifier<int> textColor = ValueNotifier(defaultTextColor);
  static final ValueNotifier<int> highlightColor = ValueNotifier(
    defaultHighlightColor,
  );
  static final ValueNotifier<String> position = ValueNotifier(defaultPosition);

  static double? _lockedPositionX;
  static double? _lockedPositionY;

  static double? get lockedPositionX => _lockedPositionX;
  static double? get lockedPositionY => _lockedPositionY;

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    fontFamily.value = prefs.getString(_prefsFontFamily) ?? defaultFontFamily;
    fontSize.value = _clampFontSize(
      prefs.getDouble(_prefsFontSize) ?? defaultFontSize,
    );
    textColor.value = prefs.getInt(_prefsTextColor) ?? defaultTextColor;
    highlightColor.value =
        prefs.getInt(_prefsHighlightColor) ?? defaultHighlightColor;
    position.value = _normalizePosition(prefs.getString(_prefsPosition));
    _lockedPositionX = prefs.getDouble(_prefsLockedPositionX);
    _lockedPositionY = prefs.getDouble(_prefsLockedPositionY);
  }

  static Future<void> setEnabled(bool value) async {
    await _saveBool(_prefsEnabled, value);
    enabled.value = value;
  }

  static Future<void> setFontFamily(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsFontFamily);
      fontFamily.value = '';
      return;
    }
    await _saveString(_prefsFontFamily, normalized);
    fontFamily.value = normalized;
  }

  static Future<void> setFontSize(double value) async {
    final normalized = _clampFontSize(value);
    await _saveDouble(_prefsFontSize, normalized);
    fontSize.value = normalized;
  }

  static Future<void> setTextColor(int value) async {
    await _saveInt(_prefsTextColor, value);
    textColor.value = value;
  }

  static Future<void> setHighlightColor(int value) async {
    await _saveInt(_prefsHighlightColor, value);
    highlightColor.value = value;
  }

  static Future<void> setPosition(String value) async {
    final normalized = _normalizePosition(value);
    await _saveString(_prefsPosition, normalized);
    position.value = normalized;
  }

  static Future<void> setLockedPosition(double x, double y) async {
    if (!x.isFinite || !y.isFinite) return;
    await _saveDouble(_prefsLockedPositionX, x);
    await _saveDouble(_prefsLockedPositionY, y);
    _lockedPositionX = x;
    _lockedPositionY = y;
  }

  static double _clampFontSize(double value) => value.clamp(14.0, 48.0);

  static String _normalizePosition(String? value) {
    if (value == positionFree || value == positionLocked) return value!;
    return defaultPosition;
  }

  static Future<void> _saveBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  static Future<void> _saveString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  static Future<void> _saveDouble(String key, double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(key, value);
  }

  static Future<void> _saveInt(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  /// 测试专用：恢复内存默认值，并允许下一次重新读取模拟持久化数据。
  static void resetForTest() {
    _loading = null;
    enabled.value = false;
    fontFamily.value = defaultFontFamily;
    fontSize.value = defaultFontSize;
    textColor.value = defaultTextColor;
    highlightColor.value = defaultHighlightColor;
    position.value = defaultPosition;
    _lockedPositionX = null;
    _lockedPositionY = null;
  }
}
