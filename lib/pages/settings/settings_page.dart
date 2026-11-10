import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';
import '../player/widgets/player_background.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    PlayerBackgroundSettings.ensureLoaded();
    AppPlaybackVolumeSettings.ensureLoaded();
    PlayerBottomActionSettings.ensureLoaded();
    MediaNotificationSettings.ensureLoaded();
    StatusBarSettings.ensureLoaded();
    CloseToTraySettings.ensureLoaded();
    DesktopLyricsSettings.ensureLoaded();
    AppLayoutSettings.ensureLoaded();
    AppBackgroundSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) {
        final bottomPadding = AppPageScaffold.scrollableBottomPadding(
          context,
          hasBottomNav: useBottomNavigation,
          showMiniPlayer: false,
        );
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '设置',
            // 设置页总是被 push 成独立路由（从「我的」齿轮、连接失败入口或侧边栏进入），
            // 从不是底部导航的 tab，因此必须始终提供返回按钮——尤其 iOS 手机端
            // 底部导航模式下旧逻辑 `!useBottomNavigation` 会错误地隐藏它。
            showBackButton: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
              AppSettingSection(
                title: '账号',
                children: [
                  AppSettingTile(
                    title: '账号管理',
                    subtitle: '切换、重命名或添加已保存的账号',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.accounts),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '外观',
                children: [
                  AppSettingTile(
                    title: '应用外观',
                    subtitle: '主题与背景设置',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.appAppearanceSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '播放器外观',
                    subtitle: '流光与播放主题',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.playerAppearanceSettings,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '功能',
                children: [
                  // 仅通过 FNID 连接时才显示：候选链路管理只对 FNID 探测有意义，
                  // 通过链接直连时该入口无意义。lastFnId 为空即链接连接。
                  if ((AppFnConnectionSettings.lastFnId ?? '').isNotEmpty)
                    AppSettingTile(
                      title: 'FN Connect',
                      subtitle: '连接偏好、当前连接与候选链路管理',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        Navigator.pushNamed(
                          context,
                          AppRoutes.fnConnectSettings,
                        );
                      },
                    ),
                  AppSettingTile(
                    title: '播放器控制',
                    subtitle: '管理底部操作栏与按钮顺序',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.playerControlsSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '音量设置',
                    subtitle: '应用音量与定时音量',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.volumeScheduleSettings,
                    ),
                  ),
                  // 通知设置（媒体通知/通知歌词/悬浮窗）依赖 Android 媒体会话
                  // 与系统通知，桌面端无对应能力，隐藏入口（切歌弹窗应用内
                  // 默认开启，无需进设置页调整）。
                  if (Platform.isAndroid)
                    AppSettingTile(
                      title: '通知设置',
                      subtitle: '媒体通知显示与按钮偏好',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pushNamed(
                        context,
                        AppRoutes.notificationSettings,
                      ),
                    ),
                  // 歌词设置（状态栏歌词/车载蓝牙/灵动岛）依赖 Android 系统级
                  // 通知与媒体会话，桌面端无对应能力，隐藏入口。
                  if (Platform.isAndroid)
                    AppSettingTile(
                      title: '歌词设置',
                      subtitle: '控制歌词的呈现方式',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pushNamed(
                        context,
                        AppRoutes.lyricsSettings,
                      ),
                    ),
                  // 元数据管理（数据源搜索匹配）依赖服务端增强（FnMusicEnhance），
                  // 后端可达即可用（含 Windows 桌面端）。
                  AppSettingTile(
                    title: '元数据管理',
                    subtitle: '音乐元数据维护',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.metadataMatchSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: '启动设置',
                    subtitle: '控制APP启动后的行为',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.launchSettings),
                  ),
                  AppSettingTile(
                    title: '转码设置',
                    subtitle: '大文件/无损文件服务器转码播放',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.transcodeSettings,
                    ),
                  ),
                  AppSettingTile(
                    title: 'DLNA',
                    subtitle: '将音乐推送到局域网 DLNA 设备',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.dlnaSettings),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
                AppSettingSection(
                  title: '桌面端',
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: DesktopLyricsSettings.enabled,
                      builder: (context, enabled, _) {
                        return AppSettingSwitchTile(
                          title: '桌面歌词',
                          subtitle: enabled
                              ? '在其它窗口上方显示当前歌词，可拖动调整位置'
                              : '在桌面上显示当前播放歌词',
                          value: enabled,
                          onChanged: DesktopLyricsSettings.setEnabled,
                        );
                      },
                    ),
                    AppSettingTile(
                      title: '桌面歌词样式',
                      subtitle: '字体、字号、颜色、透明度与位置',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (_) => const _DesktopLyricsStyleSheet(),
                      ),
                    ),
                    if (Platform.isMacOS || Platform.isWindows)
                      ValueListenableBuilder<bool>(
                        valueListenable: CloseToTraySettings.enabled,
                        builder: (context, enabled, _) {
                          return AppSettingSwitchTile(
                            title: '关闭按钮隐藏到托盘',
                            subtitle: Platform.isMacOS
                                ? '状态栏播放状态开启时，点击关闭按钮隐藏到菜单栏'
                                : '点击窗口关闭按钮时隐藏到系统托盘，而不是退出应用',
                            value: enabled,
                            onChanged: (value) {
                              CloseToTraySettings.setEnabled(value);
                            },
                          );
                        },
                      ),
                    if (Platform.isMacOS)
                      ValueListenableBuilder<bool>(
                        valueListenable: StatusBarSettings.enabled,
                        builder: (context, enabled, _) {
                          return AppSettingSwitchTile(
                            title: '状态栏播放状态',
                            subtitle: '播放时显示当前歌词，无歌词或暂停时显示歌曲名',
                            value: enabled,
                            onChanged: (value) {
                              StatusBarSettings.setEnabled(value);
                            },
                          );
                        },
                      ),
                  ],
                ),
              if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
                const SizedBox(height: 16),
              AppSettingSection(
                title: '应用',
                children: [
                  AppSettingTile(
                    title: '数据备份',
                    subtitle: '备份账号、听歌统计与设置到本地或 WebDAV',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.backupRestore),
                  ),
                  AppSettingTile(
                    title: '版本信息',
                    subtitle: '版本号、检查更新与调试日志',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.versionInfo),
                  ),
                  // 权限管理仅 Android 有对应系统权限，桌面端隐藏入口。
                  if (Platform.isAndroid)
                    AppSettingTile(
                      title: '权限管理',
                      subtitle: '查看通知、音频与后台播放权限',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pushNamed(
                        context,
                        AppRoutes.permissionSettings,
                      ),
                    ),
                  AppSettingTile(
                    title: '缓存管理',
                    subtitle: '管理音频缓存与存储空间',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.cacheSettings),
                  ),
                ],
              ),
            ],
          ),
          bottomNavIndex: null,
          showMiniPlayer: false,
        );
      },
    );
  }
}

class _DesktopLyricsStyleSheet extends StatefulWidget {
  const _DesktopLyricsStyleSheet();

  @override
  State<_DesktopLyricsStyleSheet> createState() =>
      _DesktopLyricsStyleSheetState();
}

class _DesktopLyricsStyleSheetState extends State<_DesktopLyricsStyleSheet> {
  late final TextEditingController _textColorController;
  late final TextEditingController _highlightColorController;
  late double _fontSize;

  @override
  void initState() {
    super.initState();
    _textColorController = TextEditingController(
      text: _toHex(DesktopLyricsSettings.textColor.value),
    );
    _highlightColorController = TextEditingController(
      text: _toHex(DesktopLyricsSettings.highlightColor.value),
    );
    _fontSize = DesktopLyricsSettings.fontSize.value;
  }

  @override
  void dispose() {
    _textColorController.dispose();
    _highlightColorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('桌面歌词样式', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            SystemFontPicker(
              value: DesktopLyricsSettings.fontFamily.value,
              onChanged: (value) {
                DesktopLyricsSettings.setFontFamily(value);
                setState(() {});
              },
            ),
            const SizedBox(height: 8),
            AppSettingSlider(
              title: '字号',
              value: _fontSize,
              min: 14,
              max: 48,
              divisions: 34,
              valueText: '${_fontSize.round()} px',
              onChanged: (value) {
                setState(() => _fontSize = value);
                DesktopLyricsSettings.setFontSize(value);
              },
            ),
            const SizedBox(height: 4),
            _colorField(
              controller: _textColorController,
              label: '歌词颜色',
              onSubmitted: (value) =>
                  _saveColor(value, DesktopLyricsSettings.setTextColor),
            ),
            const SizedBox(height: 12),
            _colorField(
              controller: _highlightColorController,
              label: '高亮颜色',
              onSubmitted: (value) =>
                  _saveColor(value, DesktopLyricsSettings.setHighlightColor),
            ),
            const SizedBox(height: 12),
            Text(
              '歌词背景始终透明。直接拖动歌词调整位置，点击歌词右上角的小锁锁定或解锁；位置会自动记住。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _colorField({
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onSubmitted,
  }) {
    return TextField(
      controller: controller,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: label,
        hintText: '#FFFFFFFF 或 #80FFFFFF',
        border: const OutlineInputBorder(),
      ),
      onSubmitted: onSubmitted,
      onEditingComplete: () => onSubmitted(controller.text),
    );
  }

  void _saveColor(String value, Future<void> Function(int) setter) {
    final color = _parseColor(value);
    if (color == null) return;
    setter(color);
  }

  int? _parseColor(String value) {
    final normalized = value.trim().replaceFirst('#', '');
    final full = normalized.length == 6 ? 'FF$normalized' : normalized;
    if (full.length != 8) return null;
    return int.tryParse(full, radix: 16);
  }

  String _toHex(int value) =>
      '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
}
