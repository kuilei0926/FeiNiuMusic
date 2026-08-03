import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../app/services/lyrics/lyrics_service.dart';
import '../../components/index.dart';

class LyricsSettingsPage extends StatefulWidget {
  const LyricsSettingsPage({super.key});

  @override
  State<LyricsSettingsPage> createState() => _LyricsSettingsPageState();
}

class _LyricsSettingsPageState extends State<LyricsSettingsPage>
    with SignalsMixin {
  static const String _prefsMeizuLyrics = 'lyrics_meizu_enabled';
  static const String _prefsLyriconEnabled = 'lyrics_lyricon_enabled';
  static const String _prefsLyriconForceKaraoke = 'lyrics_lyricon_force_karaoke';
  static const String _prefsLyriconHideTranslation =
      'lyrics_lyricon_hide_translation';

  late final _meizuLyrics = createSignal(false);
  late final _lyriconEnabled = createSignal(false);
  late final _lyriconForceKaraoke = createSignal(false);
  late final _lyriconHideTranslation = createSignal(false);
  late final _loading = createSignal(true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _meizuLyrics.value = prefs.getBool(_prefsMeizuLyrics) ?? false;
    _lyriconEnabled.value = prefs.getBool(_prefsLyriconEnabled) ?? false;
    _lyriconForceKaraoke.value =
        prefs.getBool(_prefsLyriconForceKaraoke) ?? false;
    _lyriconHideTranslation.value =
        prefs.getBool(_prefsLyriconHideTranslation) ?? false;
    await LyricsService.instance.refreshSettings();
    _loading.value = false;
  }

  Future<void> _updateBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    await LyricsService.instance.refreshSettings();
  }

  void _setMeizuLyrics(bool value) async {
    _meizuLyrics.value = value;
    _updateBool(_prefsMeizuLyrics, value);
  }

  void _setLyriconEnabled(bool value) {
    _lyriconEnabled.value = value;
    _updateBool(_prefsLyriconEnabled, value);
  }

  void _setLyriconForceKaraoke(bool value) {
    _lyriconForceKaraoke.value = value;
    _updateBool(_prefsLyriconForceKaraoke, value);
  }

  void _setLyriconHideTranslation(bool value) {
    _lyriconHideTranslation.value = value;
    _updateBool(_prefsLyriconHideTranslation, value);
  }

  @override
  Widget build(BuildContext context) {
    return Watch.builder(
      builder: (context) {
        if (_loading.value) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: const AppTopBar(
            title: '歌词设置',
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          showMiniPlayer: false,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              AppSettingSection(
                title: '状态栏歌词',
                children: [
                  AppSettingSwitchTile(
                    title: '魅族状态栏歌词',
                    subtitle: '需要系统或插件支持，不然请勿开启',
                    value: _meizuLyrics.value,
                    onChanged: _setMeizuLyrics,
                  ),
                  AppSettingSwitchTile(
                    title: 'Lyricon 服务',
                    subtitle: '为状态栏歌词应用提供服务支持',
                    value: _lyriconEnabled.value,
                    onChanged: _setLyriconEnabled,
                  ),
                  if (_lyriconEnabled.value)
                    AppSettingSwitchTile(
                      title: '强制逐字',
                      subtitle: '使用软件逐字模拟，一般不用开启',
                      value: _lyriconForceKaraoke.value,
                      onChanged: _setLyriconForceKaraoke,
                    ),
                  if (_lyriconEnabled.value)
                    AppSettingSwitchTile(
                      title: '隐藏歌词翻译',
                      subtitle: '仅发送原文歌词',
                      value: _lyriconHideTranslation.value,
                      onChanged: _setLyriconHideTranslation,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
