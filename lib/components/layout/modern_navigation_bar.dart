import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';

const _primaryNavigationRoutes = <String>[
  AppRoutes.home,
  AppRoutes.playlists,
  AppRoutes.songs,
  AppRoutes.favorites,
  AppRoutes.profile,
];

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
  final int currentIndex;
  final ValueChanged<int> onTap;

  const ModernNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  static const List<String> _labels = ['首页', '歌单', '歌曲', '收藏', '我的'];
  static const List<IconData> _icons = [
    Icons.home_rounded,
    Icons.queue_music_rounded,
    Icons.music_note_rounded,
    Icons.favorite_rounded,
    Icons.person_rounded,
  ];

  @override
  Widget build(BuildContext context) {
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
              height: 60,
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
