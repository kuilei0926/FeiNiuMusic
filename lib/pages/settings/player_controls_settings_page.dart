import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../components/index.dart';

class PlayerControlsSettingsPage extends StatefulWidget {
  const PlayerControlsSettingsPage({super.key});

  @override
  State<PlayerControlsSettingsPage> createState() =>
      _PlayerControlsSettingsPageState();
}

class _PlayerControlsSettingsPageState
    extends State<PlayerControlsSettingsPage> {
  @override
  void initState() {
    super.initState();
    PlayerBottomActionSettings.ensureLoaded();
    MiniPlayerInfoSettings.ensureLoaded();
    AppPlaybackQueueSettings.ensureLoaded();
  }

  _BottomActionConfig _actionConfigByKey(String key) {
    switch (key) {
      case 'playback_mode':
        return _BottomActionConfig(
          key: key,
          title: '随机/顺序按钮',
          subtitle: '控制播放模式切换',
          notifier: PlayerBottomActionSettings.showPlaybackMode,
          onChanged: PlayerBottomActionSettings.setShowPlaybackMode,
        );
      case 'sleep_timer':
        return _BottomActionConfig(
          key: key,
          title: '定时按钮',
          subtitle: '显示睡眠定时入口',
          notifier: PlayerBottomActionSettings.showSleepTimer,
          onChanged: PlayerBottomActionSettings.setShowSleepTimer,
        );
      case 'playlist':
        return _BottomActionConfig(
          key: key,
          title: '播放队列按钮',
          subtitle: '查看与调整播放队列',
          notifier: PlayerBottomActionSettings.showPlaylist,
          onChanged: PlayerBottomActionSettings.setShowPlaylist,
        );
      default:
        return _BottomActionConfig(
          key: 'more',
          title: '更多按钮',
          subtitle: '显示歌曲详情入口',
          notifier: PlayerBottomActionSettings.showMore,
          onChanged: PlayerBottomActionSettings.setShowMore,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '播放器控制',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '播放行为',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: MiniPlayerInfoSettings.showLyricsInSubtitle,
                builder: (context, enabled, _) {
                  return AppSettingTile(
                    title: '播放器控件显示歌词',
                    subtitle: '开启后用当前歌词替代歌手名，长歌词会随播放自动滚动',
                    trailing: Switch.adaptive(
                      value: enabled,
                      onChanged: (value) {
                        MiniPlayerInfoSettings.setShowLyricsInSubtitle(value);
                      },
                    ),
                  );
                },
              ),
              ValueListenableBuilder<int>(
                valueListenable: AppPlaybackQueueSettings.maxQueueLength,
                builder: (context, limit, _) {
                  return AppSettingSlider(
                    title: '播放队列上限',
                    description: '播放队列最多保留的歌曲数，超出后自动裁剪（10–1000）',
                    value: limit.toDouble(),
                    min: AppPlaybackQueueSettings.minQueueLimit.toDouble(),
                    max: AppPlaybackQueueSettings.maxQueueLimit.toDouble(),
                    divisions:
                        (AppPlaybackQueueSettings.maxQueueLimit -
                                AppPlaybackQueueSettings.minQueueLimit) ~/
                            10,
                    valueText: '$limit 首',
                    onChanged: (value) {
                      AppPlaybackQueueSettings.setMaxQueueLength(value.round());
                    },
                  );
                },
              ),
            ],
          ),
          AppSettingSection(
            title: '底部操作栏',
            children: [
              ValueListenableBuilder<List<String>>(
                valueListenable: PlayerBottomActionSettings.actionOrder,
                builder: (context, order, _) {
                  return ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: (oldIndex, newIndex) {
                      final next = List<String>.from(order);
                      final item = next.removeAt(oldIndex);
                      next.insert(newIndex, item);
                      PlayerBottomActionSettings.setActionOrder(next);
                    },
                    itemCount: order.length,
                    itemBuilder: (context, index) {
                      final key = order[index];
                      final config = _actionConfigByKey(key);
                      return AppSettingTile(
                        key: ValueKey(key),
                        title: config.title,
                        subtitle: config.subtitle,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder<bool>(
                              valueListenable: config.notifier,
                              builder: (context, enabled, _) {
                                return Switch.adaptive(
                                  value: enabled,
                                  onChanged: (value) {
                                    config.onChanged(value);
                                  },
                                );
                              },
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Icon(Icons.drag_handle_rounded),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
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

class _BottomActionConfig {
  final String key;
  final String title;
  final String subtitle;
  final ValueNotifier<bool> notifier;
  final Future<void> Function(bool) onChanged;

  const _BottomActionConfig({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.notifier,
    required this.onChanged,
  });
}
