import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';
import '../../components/common/setting_widgets.dart';
import '../../components/focus/tv_focusable.dart';
import '../../components/layout/base/app_background.dart';
import '../../components/player/player_style_preview.dart';
import '../player/widgets/player_background.dart';

/// 首次启动引导页。
///
/// 全屏分页引导，让用户直接选择外观与启动设置（选择即时生效），
/// 无需跳转设置页。作为 [MaterialApp.home] 首路由由 _AppStartupGate 渲染，
/// 完成后调用 [AppOnboardingSettings.setCompleted]，门控随即替换子树卸载本页。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _controller = PageController();
  int _currentPage = 0;
  static const int _totalPages = 4;

  @override
  void initState() {
    super.initState();
    // 幂等预加载本页会读写到的设置类（大部分 main() 已加载，重复调用无害）。
    // PlayerBackgroundSettings / AppLaunchPlaybackSettings 不在 main() 预加载列表，
    // 必须在这里补加载，否则页3/页4 开关读到默认值而非用户保存值。
    AppOnboardingSettings.ensureLoaded();
    AppThemeSettings.ensureLoaded();
    AppLayoutSettings.ensureLoaded();
    PlayerStyleSettings.ensureLoaded();
    PlayerBackgroundSettings.ensureLoaded();
    AppLaunchNavigationSettings.ensureLoaded();
    AppLaunchPlaybackSettings.ensureLoaded();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goNext() {
    if (_currentPage < _totalPages - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _finish() async {
    // 首次使用 + 大屏（TV/平板）：自动开启切歌弹窗，让切歌时在顶部看到
    // 「正在播放」提示。仅在首次引导会话生效，老用户不改动任何开关。
    final size = MediaQuery.sizeOf(context);
    await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
      isFirstLaunch: AppOnboardingSettings.isFirstLaunchSession,
      isTv: AppLayoutSettings.tvMode.value,
      shortestSide: size.shortestSide,
    );
    await AppOnboardingSettings.setCompleted();
    // 无需手动跳转：门控监听 completed，notifier 更新后自动替换子树卸载本页
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _currentPage == _totalPages - 1;
    // 首次引导必须滑到末页点「开始使用」才算完成（无跳过入口）；
    // 中途按系统返回键退出 App 时不写完成标记，下次启动仍会重新弹出引导页。
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: PageView(
            controller: _controller,
            onPageChanged: (i) => setState(() => _currentPage = i),
            children: const [
              _WelcomePage(),
              _AppearancePage(),
              _PlayerAppearancePage(),
              _LaunchPage(),
            ],
          ),
        ),
        bottomNavigationBar: _BottomBar(
          currentPage: _currentPage,
          totalPages: _totalPages,
          isLast: isLast,
          onNext: isLast ? () => _finish() : _goNext,
        ),
      ),
    );
  }
}

/// 固定底栏：圆点指示器 + 主按钮（无跳过入口，首次引导必须走完）。
class _BottomBar extends StatelessWidget {
  final int currentPage;
  final int totalPages;
  final bool isLast;
  final VoidCallback onNext;

  const _BottomBar({
    required this.currentPage,
    required this.totalPages,
    required this.isLast,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(totalPages, (i) {
                final active = i == currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  width: active ? 24 : 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: active ? scheme.primary : scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: onNext,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(isLast ? '开始使用' : '下一步'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分页公共头部：图标圆底 + 标题 + 副标题。
class _PageHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _PageHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const SizedBox(height: 24),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Icon(icon, size: 36, color: scheme.primary),
        ),
        const SizedBox(height: 20),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
      ],
    );
  }
}

/// 页1：欢迎 + 主题模式三选。
class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const SizedBox(height: 64),
        // 应用 LOGO（强制 1:1 正方形 + 圆角裁切，避免容器约束变化导致变形）
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: SizedBox(
              width: 96,
              height: 96,
              child: Image.asset(
                'assets/icon/app_icon.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        Text(
          '欢迎使用飞牛音乐',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '先从个性化你的音乐体验开始\n下面的选择都可以随时在设置里调整',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 主题模式三选卡片（样式对齐设置页的 _modeTile/_modeRow）。
class _ThemeModeSelector extends StatelessWidget {
  final ThemeMode selected;
  final ValueChanged<ThemeMode> onChanged;

  const _ThemeModeSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _modeTile(
          context,
          icon: Icons.phone_android,
          label: '跟随系统',
          selected: selected == ThemeMode.system,
          onTap: () => onChanged(ThemeMode.system),
        ),
        const SizedBox(width: 10),
        _modeTile(
          context,
          icon: Icons.light_mode_outlined,
          label: '浅色',
          selected: selected == ThemeMode.light,
          onTap: () => onChanged(ThemeMode.light),
        ),
        const SizedBox(width: 10),
        _modeTile(
          context,
          icon: Icons.dark_mode_outlined,
          label: '深色',
          selected: selected == ThemeMode.dark,
          onTap: () => onChanged(ThemeMode.dark),
        ),
      ],
    );
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
  final background = selected ? scheme.primary.withAlpha(31) : Colors.transparent;
  return Expanded(
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
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

/// 页2：应用外观 —— 主题模式 + 主题强调色 + 导航方式。
class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const _PageHeader(
          icon: Icons.palette_outlined,
          title: '应用外观',
          subtitle: '选择主题模式、主题色与导航方式',
        ),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: AppThemeSettings.themeMode,
          builder: (context, mode, _) => _ThemeModeSelector(
            selected: mode,
            onChanged: (value) => AppThemeSettings.setThemeMode(value),
          ),
        ),
        const SizedBox(height: 24),
        ValueListenableBuilder<Color?>(
          valueListenable: AppThemeSettings.themeSeedColor,
          builder: (context, seed, _) => _SeedColorPalette(selected: seed),
        ),
        const SizedBox(height: 28),
        ValueListenableBuilder<AppNavigationStyle>(
          valueListenable: AppLayoutSettings.navigationStyle,
          builder: (context, style, _) => _NavigationStyleSelector(
            selected: style,
            onChanged: (value) => AppLayoutSettings.setNavigationStyle(value),
          ),
        ),
      ],
    );
  }
}

/// 主题强调色预设色板（与设置页色板同一份颜色，改色需同步设置页）。
class _SeedColorPalette extends StatelessWidget {
  final Color? selected;

  const _SeedColorPalette({required this.selected});

  static const List<Color> _presetColors = [
    Color(0xFF3B82F6), // 默认蓝
    Color(0xFF22C55E),
    Color(0xFFA855F7),
    Color(0xFFF97316),
    Color(0xFFEF4444),
    Color(0xFFEC4899),
    Color(0xFF14B8A6),
    Color(0xFF6366F1),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '主题色',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: _presetColors.map((color) {
            final isSelected =
                (selected?.toARGB32() ?? 0xFF3B82F6) == color.toARGB32();
            Widget swatch = GestureDetector(
              onTap: () {
                // 点选固定色需先关闭动态颜色，否则主题色不生效
                AppThemeSettings.setDynamicColorEnabled(false).then((_) {
                  AppThemeSettings.setThemeSeedColor(color);
                });
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSelected ? scheme.onSurface : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: isSelected
                    ? const Icon(Icons.check_rounded, color: Colors.white, size: 22)
                    : null,
              ),
            );
            // TV 模式：色板是 GestureDetector（非 Material），需焦点环可聚焦。
            if (AppLayoutSettings.tvMode.value) {
              swatch = TvFocusable(
                borderRadius: BorderRadius.circular(24),
                onActivate: () {
                  AppThemeSettings.setDynamicColorEnabled(false).then((_) {
                    AppThemeSettings.setThemeSeedColor(color);
                  });
                },
                child: swatch,
              );
            }
            return swatch;
          }).toList(),
        ),
      ],
    );
  }
}

/// 导航方式二选卡片。
class _NavigationStyleSelector extends StatelessWidget {
  final AppNavigationStyle selected;
  final ValueChanged<AppNavigationStyle> onChanged;

  const _NavigationStyleSelector({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            '导航方式',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _navTile(
                context,
                icon: Icons.menu_open_rounded,
                label: '侧边栏',
                selected: selected == AppNavigationStyle.drawer,
                onTap: () => onChanged(AppNavigationStyle.drawer),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _navTile(
                context,
                icon: Icons.space_dashboard_outlined,
                label: '底部导航',
                selected: selected == AppNavigationStyle.bottomBar,
                onTap: () => onChanged(AppNavigationStyle.bottomBar),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

Widget _navTile(
  BuildContext context, {
  required IconData icon,
  required String label,
  required bool selected,
  VoidCallback? onTap,
}) {
  final scheme = Theme.of(context).colorScheme;
  final borderColor = selected
      ? scheme.primary
      : (Theme.of(context).brightness == Brightness.dark
          ? Colors.white12
          : Colors.black12);
  return InkWell(
    borderRadius: BorderRadius.circular(14),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: selected ? scheme.primary.withAlpha(31) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 24,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? scheme.primary : scheme.onSurface,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 页3：播放器外观 —— 播放器样式 + 圆形封面。
class _PlayerAppearancePage extends StatelessWidget {
  const _PlayerAppearancePage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const _PageHeader(
          icon: Icons.play_circle_outline_rounded,
          title: '播放器外观',
          subtitle: '选择你喜欢的播放页样式',
        ),
        ValueListenableBuilder<PlayerStylePreset>(
          valueListenable: PlayerStyleSettings.stylePreset,
          builder: (context, preset, _) => _PlayerStyleSelector(
            selected: preset,
            onChanged: (value) {
              // 仅切换样式，不触碰「圆形封面」设置：海报模式下该开关被隐藏，
              // 切回默认时保留切换前的圆形/方形状态。
              PlayerStyleSettings.setStylePreset(value);
            },
          ),
        ),
        const SizedBox(height: 24),
        // 海报歌词为整幅大封面，圆形封面开关无意义，选中海报时隐藏
        ValueListenableBuilder<PlayerStylePreset>(
          valueListenable: PlayerStyleSettings.stylePreset,
          builder: (context, preset, _) {
            if (preset == PlayerStylePreset.poster) {
              return const SizedBox.shrink();
            }
            return ValueListenableBuilder<bool>(
              valueListenable: PlayerBackgroundSettings.roundCover,
              builder: (context, enabled, _) => AppSettingSwitchTile(
                title: '圆形封面',
                subtitle: '播放页封面以圆形显示',
                value: enabled,
                onChanged: (value) =>
                    PlayerBackgroundSettings.setRoundCover(value),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 播放器样式二选卡片（classic / poster）。
class _PlayerStyleSelector extends StatelessWidget {
  final PlayerStylePreset selected;
  final ValueChanged<PlayerStylePreset> onChanged;

  const _PlayerStyleSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // 每张卡片等宽（Spacer 占位）+ 尾部留 10px 间距，保证两个预览图
    // 宽度一致 → AspectRatio 高度一致，避免 classic/poster 卡片大小不一。
    // TV 端：两卡并排 + 遥控器导航，限制整体宽度防止预览占满横屏。
    final isTv = AppLayoutSettings.tvMode.value;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: PlayerStylePreset.values.map((preset) {
        final isSelected = preset == selected;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: _styleCard(context, preset, isSelected, onChanged),
          ),
        );
      }).toList(),
    );
    if (!isTv) return row;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: row,
      ),
    );
  }
}

Widget _styleCard(
  BuildContext context,
  PlayerStylePreset preset,
  bool selected,
  ValueChanged<PlayerStylePreset> onChanged,
) {
  final scheme = Theme.of(context).colorScheme;
  final card = GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => onChanged(preset),
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
  // TV 模式：卡片是 GestureDetector（非 Material），需 TvFocusable 焦点环
  // 才能被遥控器聚焦；确认键（Enter）触发同样的选择。
  if (AppLayoutSettings.tvMode.value) {
    return TvFocusable(
      borderRadius: BorderRadius.circular(16),
      onActivate: () => onChanged(preset),
      child: card,
    );
  }
  return card;
}

/// 页4：启动设置。
class _LaunchPage extends StatelessWidget {
  const _LaunchPage();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const _PageHeader(
          icon: Icons.rocket_launch_outlined,
          title: '启动设置',
          subtitle: '决定 App 打开后的行为\n这些设置从下次启动生效',
        ),
        const SizedBox(height: 8),
        ValueListenableBuilder<bool>(
          valueListenable:
              AppLaunchNavigationSettings.autoOpenPlayerOnLaunch,
          builder: (context, enabled, _) => AppSettingSwitchTile(
            title: '启动软件自动打开播放界面',
            subtitle: 'APP启动后自动进入播放页面',
            value: enabled,
            onChanged: (value) =>
                AppLaunchNavigationSettings.setAutoOpenPlayerOnLaunch(value),
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<bool>(
          valueListenable: AppLaunchPlaybackSettings.autoPlayOnAppLaunch,
          builder: (context, enabled, _) => AppSettingSwitchTile(
            title: '进入应用自动播放',
            subtitle: '打开应用后自动开始播放当前歌曲',
            value: enabled,
            onChanged: (value) =>
                AppLaunchPlaybackSettings.setAutoPlayOnAppLaunch(value),
          ),
        ),
      ],
    );
  }
}
