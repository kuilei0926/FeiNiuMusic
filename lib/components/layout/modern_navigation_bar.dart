import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';
import '../../app/theme/app_glass_theme.dart';
import '../common/glass_gate.dart';

const _primaryNavigationRoutes = <String>[
  AppRoutes.home,
  AppRoutes.playlists,
  AppRoutes.songs,
  AppRoutes.favorites,
  AppRoutes.profile,
];

/// 玻璃底栏胶囊上方的悬浮空隙（= [GlassTabBar.bottom] 的 verticalPadding）。
///
/// 胶囊只占槽位中间（上下各留此空隙）；AppPageScaffold 计算迷你播放器停靠
/// 位置时减去它、对齐胶囊顶，否则胶囊上方的空隙会被误当成迷你播放器与
/// 底栏的间隙（观感上离得远）。
const double kGlassNavPillTopGap = 14;

final ValueNotifier<int> primaryNavigationIndex = ValueNotifier<int>(0);
bool primaryNavigationShellActive = false;

void navigateToPrimaryDestination(BuildContext context, int index) {
  if (index < 0 || index >= _primaryNavigationRoutes.length) return;
  final scope = PrimaryNavigationScope.maybeOf(context);
  if (scope != null) {
    scope.onSelected(index);
    return;
  }
  if (primaryNavigationShellActive &&
      AppLayoutSettings.navigationStyle.value == AppNavigationStyle.bottomBar) {
    primaryNavigationIndex.value = index;
    Navigator.of(context).popUntil(
      (route) => route.settings.name == AppRoutes.home || route.isFirst,
    );
    return;
  }
  // 抽屉/无底部栏模式：作为普通页面压栈，返回键可回到来源页。
  // 不要用 pushAndRemoveUntil —— 那会清空整个路由栈（包括首页），
  // 导致从首页点进来后无法按返回回到首页。
  final routeName = _primaryNavigationRoutes[index];
  if (ModalRoute.of(context)?.settings.name == routeName) return;
  Navigator.of(context).pushNamed(routeName);
}

class PrimaryNavigationScope extends InheritedWidget {
  final int currentIndex;
  final ValueChanged<int> onSelected;

  const PrimaryNavigationScope({
    super.key,
    required this.currentIndex,
    required this.onSelected,
    required super.child,
  });

  static PrimaryNavigationScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PrimaryNavigationScope>();
  }

  @override
  bool updateShouldNotify(PrimaryNavigationScope oldWidget) {
    return currentIndex != oldWidget.currentIndex ||
        onSelected != oldWidget.onSelected;
  }
}

class AppNavigationModeBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, bool useBottomNavigation) builder;

  const AppNavigationModeBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppNavigationStyle>(
      valueListenable: AppLayoutSettings.navigationStyle,
      builder: (context, style, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: AppLayoutSettings.effectiveTabletModeNotifier,
          builder: (context, effectiveTabletMode, _) {
            return builder(
              context,
              style == AppNavigationStyle.bottomBar && !effectiveTabletMode,
            );
          },
        );
      },
    );
  }
}

class ModernNavigationBar extends StatelessWidget {
  const ModernNavigationBar({
    super.key,
    required this.onTap,
  });

  /// 底部导航点击回调（导航到对应 tab）。
  final ValueChanged<int> onTap;

  static const List<String> _labels = ['首页', '歌单', '歌曲', '收藏', '我的'];
  static const List<IconData> _icons = [
    Icons.home_rounded,
    Icons.queue_music_rounded,
    Icons.music_note_rounded,
    Icons.favorite_rounded,
    Icons.person_rounded,
  ];

  /// 液体玻璃分支：SF Symbols 字形（包内置 demo 同款 CupertinoIcons 实心图标）。
  static const List<IconData> _glassIcons = [
    CupertinoIcons.house_fill,
    CupertinoIcons.square_stack_fill,
    CupertinoIcons.music_note_list,
    CupertinoIcons.heart_fill,
    CupertinoIcons.person_fill,
  ];

  @override
  Widget build(BuildContext context) {
    // 高亮索引统一由全局 [primaryNavigationIndex] 驱动，而不是各页面传入的
    // currentIndex（bottomNavIndex）。二级详情页把 bottomNavIndex 硬编码成 0，
    // 从其它 tab 进入详情页时底栏会错误高亮「首页」；shell 每次切页（_select）
    // 与 navigateToPrimaryDestination 都会同步 primaryNavigationIndex，这里
    // 监听它即可始终反映真实激活的 tab（含 push 出的详情页）。
    return ValueListenableBuilder<int>(
      valueListenable: primaryNavigationIndex,
      builder: (context, index, _) => GlassGate(
        original: _buildOriginal(context, index),
        glass: _buildGlass(context, index),
      ),
    );
  }

  Widget _buildOriginal(BuildContext context, int currentIndex) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // Follow the same panel blur slider used by cards/setting panels so
    // the bottom bar visually belongs to the same surface family.
    return ValueListenableBuilder<bool>(
      valueListenable: AppBackgroundSettings.panelBlurEnabled,
      builder: (context, blurEnabled, _) {
        return ValueListenableBuilder<double>(
          valueListenable: AppBackgroundSettings.panelBlurStrength,
          builder: (context, _, _) {
            final blurStrength = blurEnabled
                ? AppBackgroundSettings.panelBlurStrength.value
                : 0.0;
            final isBlurred = blurStrength > 0;
        final barColor = isBlurred
            ? (isDark
                ? Colors.black.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.04))
            : scheme.surface.withValues(alpha: 0.85);
        Widget navBar = Material(
          color: barColor,
          elevation: 0,
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 84,
              child: Row(
                children: List.generate(_labels.length, (index) {
                  final selected = currentIndex == index;
                  return Expanded(
                    child: _NavItem(
                      icon: _icons[index],
                      label: _labels[index],
                      selected: selected,
                      onTap: () => onTap(index),
                    ),
                  );
                }),
              ),
            ),
          ),
        );
        // 启用高斯模糊时包裹 BackdropFilter。
        // RepaintBoundary 隔离模糊合成图层：页面切换转场期间底层内容变化时，
        // 模糊结果被图层缓存复用，避免逐帧全屏重采样造成掉帧。
        if (blurStrength > 0) {
          navBar = ClipRect(
            child: RepaintBoundary(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: blurStrength, sigmaY: blurStrength),
                child: navBar,
              ),
            ),
          );
        }
        return navBar;
          },
        );
      },
    );
  }

  /// 液体玻璃变体：iOS 26 风格浮动玻璃胶囊底部导航。
  ///
  /// 大体沿用包内置 demo 的参考配置（见 liquid_glass_widgets example.dart）：
  /// 实心 SF Symbols 图标（CupertinoIcons）+ 图标/文字着色走包默认（label 色），
  /// 只显式补一个 [GlassTabBar.indicatorColor]（10% label 灰）——MaterialApp
  /// 下包默认的动态色解析可能让选中胶囊不可见，显式指定后与 CupertinoApp 里
  /// demo 的克制浅灰胶囊观感一致。
  ///
  /// 尺寸：胶囊 56 + 上下悬浮空隙 14×2 = 84，正好等于
  /// [AppPageScaffold.modernNavHeight]，槽位/迷你播放器抬升/滚动留白数学零改动。
  /// 胶囊无内部 SafeArea，外层补 `SafeArea(top: false)` 悬浮在 Home 指示条上方。
  Widget _buildGlass(BuildContext context, int index) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 选中胶囊色：与包内置 demo（CupertinoApp）一致 —— label 色 10% 半透明。
    // MaterialApp 下没有显式 CupertinoTheme，包默认的动态色 .withValues 可能
    // 解析出不可见的胶囊，这里显式按明暗取 10% 黑/白，保证亮暗都清晰可见。
    final pillColor = isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.10);
    return SafeArea(
      top: false,
      child: GlassTabBar.bottom(
        tabs: [
          for (var i = 0; i < _labels.length; i++)
            GlassTab(
              icon: Icon(_glassIcons[i]),
              label: _labels[i],
            ),
        ],
        selectedIndex: index,
        onTabSelected: onTap,
        // 显式传入共享表面参数（见 kAppGlassSurfaceSettings）：与全局其它玻璃
        // 统一观感，并防止包升级改动内部默认值导致底栏漂移。
        settings: kAppGlassSurfaceSettings,
        // 悬浮：胶囊上下各留 kGlassNavPillTopGap 空隙（槽位 56 + 14×2 = 84），
        // 内容从胶囊四周透出，视觉上像 demo（GlassScaffold 底栏）一样飘浮。
        barHeight: 56,
        verticalPadding: kGlassNavPillTopGap,
        horizontalPadding: 20,
        indicatorColor: pillColor,
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = scheme.primary;
    final inactiveColor = scheme.onSurfaceVariant.withValues(alpha: 0.7);

    return InkWell(
      onTap: onTap,
      // Silence the platform click sound so tab switches don't punctuate the
      // music the user is playing.
      enableFeedback: false,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: selected ? 14 : 10,
              vertical: 4,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    icon,
                    key: ValueKey(selected),
                    size: 22,
                    color: selected ? activeColor : inactiveColor,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    color: selected ? activeColor : inactiveColor,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                  child: Text(label, maxLines: 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
