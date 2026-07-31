import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/player_service.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';
import '../player/widgets/player_background.dart';
import '../login/login_page.dart';

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
        );
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          appBar: AppTopBar(
            title: '设置',
            showBackButton: !useBottomNavigation,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
            children: [
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
                  AppSettingTile(
                    title: 'FN Connect',
                    subtitle: '连接偏好、当前连接与候选链路管理',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      Navigator.pushNamed(context, AppRoutes.fnConnectSettings);
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
                    title: '通知设置',
                    subtitle: '媒体通知显示与按钮偏好',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.notificationSettings,
                    ),
                  ),
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
                    title: '歌词设置',
                    subtitle: '状态栏歌词与显示偏好',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.lyricsSettings),
                  ),
                  AppSettingTile(
                    title: '听歌统计',
                    subtitle: '日历与播放数据概览',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.listeningStats),
                  ),
                  AppSettingTile(
                    title: '缓存设置',
                    subtitle: '管理音频缓存与存储空间',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.cacheSettings),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '启动',
                children: [
                  AppSettingTile(
                    title: '启动设置',
                    subtitle: '控制APP启动后的行为',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.launchSettings),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AppSettingSection(
                title: '应用',
                children: [
                  AppSettingTile(
                    title: '版本信息',
                    subtitle: '版本号、检查更新与调试日志',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        Navigator.pushNamed(context, AppRoutes.versionInfo),
                  ),
                  AppSettingTile(
                    title: '退出登录',
                    subtitle: '退出当前账号并返回登录页',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('退出登录'),
                          content: const Text('确定退出当前账号吗？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('确定'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        // 退出登录前先停止音乐播放
                        await PlayerService.instance.stopAndClear();
                        await AuthService.instance.logout();
                        if (!context.mounted) return;
                        Navigator.of(context).pushAndRemoveUntil(
                          MaterialPageRoute(builder: (_) => const LoginPage()),
                          (route) => false,
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          bottomNavIndex: null,
        );
      },
    );
  }
}
