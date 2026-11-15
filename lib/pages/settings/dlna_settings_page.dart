import 'package:flutter/material.dart';

import '../../app/state/settings_cast_state.dart';
import '../../components/index.dart';

/// DLNA 投屏设置页。
class DlnaSettingsPage extends StatefulWidget {
  const DlnaSettingsPage({super.key});

  @override
  State<DlnaSettingsPage> createState() => _DlnaSettingsPageState();
}

class _DlnaSettingsPageState extends State<DlnaSettingsPage> {
  @override
  void initState() {
    super.initState();
    DlnaCastSettings.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = AppPageScaffold.scrollableBottomPadding(
      context,
      showMiniPlayer: false,
    );
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '投屏（DLNA）',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '投屏设置',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: DlnaCastSettings.enabled,
                builder: (context, enabled, _) {
                  return AppSettingTile(
                    title: '启用 DLNA 投屏',
                    subtitle: '将音乐推送到局域网内的 DLNA 设备',
                    trailing: Switch.adaptive(
                      value: enabled,
                      onChanged: (value) {
                        DlnaCastSettings.setEnabled(value);
                      },
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          const AppSettingSection(
            title: '使用说明',
            children: [
              AppSettingTile(
                title: '如何使用',
                subtitle:
                    '播放页右上角点击投屏图标，选择设备即可投屏。'
                    '投屏后手机端可遥控播放/暂停/进度/音量，音量键调节电视音量。'
                    '设备离线或在电视端停止时会自动断开，手机保持暂停。',
              ),
              AppSettingTile(
                title: '支持格式',
                subtitle:
                    '优先推送原始音频；设备声明不支持该格式或无法起播时，'
                    '自动改用服务器转码的 MP3 流重试一次。',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
