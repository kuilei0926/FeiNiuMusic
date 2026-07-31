import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../app/state/settings_playback_state.dart';
import '../../components/index.dart';

class LaunchSettingsPage extends StatefulWidget {
  const LaunchSettingsPage({super.key});

  @override
  State<LaunchSettingsPage> createState() => _LaunchSettingsPageState();
}

class _LaunchSettingsPageState extends State<LaunchSettingsPage> {
  @override
  void initState() {
    super.initState();
    AppLaunchNavigationSettings.ensureLoaded();
    AppLaunchPlaybackSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(context);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '启动设置',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '启动行为',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable:
                    AppLaunchNavigationSettings.autoOpenPlayerOnLaunch,
                builder: (context, enabled, _) {
                  return AppSettingTile(
                    title: '启动软件自动打开播放界面',
                    subtitle: '控制APP启动后的行为',
                    trailing: Switch.adaptive(
                      value: enabled,
                      onChanged: (value) {
                        AppLaunchNavigationSettings
                            .setAutoOpenPlayerOnLaunch(value);
                      },
                    ),
                  );
                },
              ),
              const SizedBox(height: 2),
              ValueListenableBuilder<bool>(
                valueListenable:
                    AppLaunchPlaybackSettings.autoPlayOnAppLaunch,
                builder: (context, enabled, _) {
                  return AppSettingTile(
                    title: '进入应用自动播放',
                    subtitle: '打开应用后自动开始播放当前歌曲',
                    trailing: Switch.adaptive(
                      value: enabled,
                      onChanged: (value) {
                        AppLaunchPlaybackSettings
                            .setAutoPlayOnAppLaunch(value);
                      },
                    ),
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
