import 'package:flutter/material.dart';

import '../../app/services/android_platform_service.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool _supportsCustomActions = true;

  @override
  void initState() {
    super.initState();
    MediaNotificationSettings.ensureLoaded();
    _loadCapabilities();
  }

  Future<void> _loadCapabilities() async {
    final supported = await AndroidPlatformService.instance
        .supportsNotificationCustomActions();
    if (!mounted) return;
    setState(() => _supportsCustomActions = supported);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '通知设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '媒体通知',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.showLyrics,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '通知显示歌词',
                    subtitle: '在媒体通知里显示当前歌词行',
                    value: enabled,
                    onChanged: (value) {
                      MediaNotificationSettings.setShowLyrics(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.lyricOnTop,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '歌词首行显示',
                    subtitle: '上方歌词，下方歌名与歌手名',
                    value: enabled,
                    onChanged: (value) {
                      MediaNotificationSettings.setLyricOnTop(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.showCloseAction,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '显示关闭按钮',
                    subtitle: _supportsCustomActions
                        ? '在通知上展示关闭应用按钮'
                        : '当前设备暂不可用自定义通知按钮',
                    value: _supportsCustomActions && enabled,
                    onChanged: _supportsCustomActions
                        ? (value) {
                            MediaNotificationSettings.setShowCloseAction(value);
                          }
                        : null,
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaNotificationSettings.showFavoriteAction,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '显示收藏按钮',
                    subtitle: _supportsCustomActions
                        ? '在通知上展示收藏/取消收藏'
                        : '当前设备暂不可用自定义通知按钮',
                    value: _supportsCustomActions && enabled,
                    onChanged: _supportsCustomActions
                        ? (value) {
                            MediaNotificationSettings.setShowFavoriteAction(
                              value,
                            );
                          }
                        : null,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
