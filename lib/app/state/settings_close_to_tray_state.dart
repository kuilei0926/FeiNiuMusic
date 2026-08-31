import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 桌面端「关闭按钮隐藏到托盘」设置（Windows/macOS 共用，默认开启）。
///
/// - [enabled] 开启时点击窗口关闭按钮隐藏到系统托盘而不是退出应用。
class CloseToTraySettings {
  static const String _prefsEnabled = 'close_to_tray_enabled';

  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  static Future<void>? _loading;

  static Future<void> ensureLoaded() => _loading ??= _doLoad();

  static Future<void> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
    enabled.value = value;
  }

  /// 测试专用：重置内存状态（清空懒加载缓存），供测试 setUp 复用。
  static void resetForTest() {
    _loading = null;
    enabled.value = true;
  }
}
