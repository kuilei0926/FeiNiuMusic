import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 服务端增强（FnMusicEnhance）设置。
///
/// FnMusicEnhance 是运行在飞牛 NAS 上的服务端增强应用，监听 38200 端口，
/// 提供歌词读写与歌手/专辑编辑（改名 + 封面写入）。仅非中继（5ddd.com）
/// 连接下可用。认证使用飞牛音乐登录 token（`FeiNiuApiClient.token`），
/// 无需额外密钥。
class LyricCompanionSettings {
  static const String _prefsEnabled = 'lyric_companion_enabled';

  /// 服务端增强开关。
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  static bool _loaded = false;

  static bool get loaded => _loaded;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefsEnabled) ?? false;
    _loaded = true;
  }

  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabled, value);
  }
}
