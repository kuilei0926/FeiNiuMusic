import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';
import '../../components/index.dart';
import '../../components/player/player_style_preview.dart';
import '../player/widgets/player_background.dart';

class PlayerAppearanceSettingsPage extends StatefulWidget {
  const PlayerAppearanceSettingsPage({super.key});

  @override
  State<PlayerAppearanceSettingsPage> createState() =>
      _PlayerAppearanceSettingsPageState();
}

class _PlayerAppearanceSettingsPageState
    extends State<PlayerAppearanceSettingsPage> {
  @override
  void initState() {
    super.initState();
    PlayerBackgroundSettings.ensureLoaded();
    PlayerStyleSettings.ensureLoaded();
  }

  String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  Widget _modeTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = selected
        ? scheme.primary
        : (isDark ? Colors.white12 : Colors.black12);
    final iconColor = selected
        ? scheme.primary
        : (isDark ? Colors.white70 : Colors.black54);
    final textColor = selected
        ? scheme.primary
        : (isDark ? Colors.white70 : Colors.black87);
    final background = selected
        ? scheme.primary.withAlpha(31)
        : Colors.transparent;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 12, color: textColor)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeRow(
    BuildContext context, {
    required ThemeMode selected,
    required ValueChanged<ThemeMode> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          _modeTile(
            context,
            icon: Icons.phone_android,
            label: _themeLabel(ThemeMode.system),
            selected: selected == ThemeMode.system,
            onTap: () => onChanged(ThemeMode.system),
          ),
          const SizedBox(width: 8),
          _modeTile(
            context,
            icon: Icons.light_mode_outlined,
            label: _themeLabel(ThemeMode.light),
            selected: selected == ThemeMode.light,
            onTap: () => onChanged(ThemeMode.light),
          ),
          const SizedBox(width: 8),
          _modeTile(
            context,
            icon: Icons.dark_mode_outlined,
            label: _themeLabel(ThemeMode.dark),
            selected: selected == ThemeMode.dark,
            onTap: () => onChanged(ThemeMode.dark),
          ),
        ],
      ),
    );
  }

  Widget _styleGrid(BuildContext context, PlayerStylePreset selected) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const spacing = 10.0;
          final itemWidth = (constraints.maxWidth - spacing) / 2;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: PlayerStylePreset.values.map((preset) {
              return SizedBox(
                width: itemWidth,
                child: _PlayerStyleCard(
                  preset: preset,
                  selected: preset == selected,
                  onTap: () {
                    // 仅切换样式，不触碰「圆形封面」设置：海报模式下该开关被隐藏，
                    // 切回默认时保留切换前的圆形/方形状态。
                    PlayerStyleSettings.setStylePreset(preset);
                  },
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding =
        AppPageScaffold.scrollableBottomPadding(context, showMiniPlayer: false);
    return AppPageScaffold(
      extendBodyBehindAppBar: true,
      appBar: const AppTopBar(
        title: '播放器外观',
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      showMiniPlayer: false,
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
        children: [
          AppSettingSection(
            title: '外观设置',
            children: [
              ValueListenableBuilder<PlayerStylePreset>(
                valueListenable: PlayerStyleSettings.stylePreset,
                builder: (context, selected, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
                        child: Text('播放器样式'),
                      ),
                      _styleGrid(context, selected),
                    ],
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable:
                    PlayerBackgroundSettings.dynamicGradientEnabled,
                builder: (context, enabled, _) {
                  return AppSettingSwitchTile(
                    title: '动态流光',
                    subtitle: '背景随封面颜色流动变化',
                    value: enabled,
                    onChanged: (value) {
                      PlayerBackgroundSettings.setDynamicGradientEnabled(value);
                    },
                  );
                },
              ),
              ValueListenableBuilder<bool>(
                valueListenable:
                    PlayerBackgroundSettings.dynamicGradientEnabled,
                builder: (context, enabled, _) {
                  if (!enabled) {
                    return const SizedBox.shrink();
                  }
                  return AppSettingTile(
                    title: '流光设置',
                    subtitle: '封面流光与渐变参数',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.gradientSettings,
                    ),
                  );
                },
              ),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: PlayerBackgroundSettings.playbackThemeMode,
                builder: (context, mode, _) {
                  return _modeRow(
                    context,
                    selected: mode,
                    onChanged: (value) {
                      PlayerBackgroundSettings.setPlaybackThemeMode(value);
                    },
                  );
                },
              ),
              // 海报模式为大封面全屏布局，与圆形/旋转封面互斥：隐藏这两个
              // 开关（保留其存储值），切回默认模式时原样恢复。
              ValueListenableBuilder<PlayerStylePreset>(
                valueListenable: PlayerStyleSettings.stylePreset,
                builder: (context, preset, _) {
                  if (preset == PlayerStylePreset.poster) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    children: [
                      ValueListenableBuilder<bool>(
                        valueListenable: PlayerBackgroundSettings.roundCover,
                        builder: (context, enabled, _) {
                          return AppSettingSwitchTile(
                            title: '圆形封面',
                            subtitle: '播放页封面以圆形显示',
                            value: enabled,
                            onChanged: (value) {
                              PlayerBackgroundSettings.setRoundCover(value);
                            },
                          );
                        },
                      ),
                      ValueListenableBuilder<bool>(
                        valueListenable: PlayerBackgroundSettings.roundCover,
                        builder: (context, roundEnabled, _) {
                          if (!roundEnabled) {
                            return const SizedBox.shrink();
                          }
                          return ValueListenableBuilder<bool>(
                            valueListenable:
                                PlayerBackgroundSettings.rotateCover,
                            builder: (context, enabled, _) {
                              return AppSettingSwitchTile(
                                title: '旋转封面',
                                subtitle: '播放时封面缓慢旋转',
                                value: enabled,
                                onChanged: (value) {
                                  PlayerBackgroundSettings.setRotateCover(value);
                                },
                              );
                            },
                          );
                        },
                      ),
                    ],
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

class _PlayerStyleCard extends StatelessWidget {
  final PlayerStylePreset preset;
  final bool selected;
  final VoidCallback onTap;

  const _PlayerStyleCard({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: selected ? 0.22 : 0.12,
                      ),
                      blurRadius: selected ? 16 : 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: PlayerStylePreview(preset: preset, selected: selected),
              ),
              if (selected)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            preset.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? scheme.primary : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            preset.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
            ),
          ),
        ],
      ),
    );
  }
}
