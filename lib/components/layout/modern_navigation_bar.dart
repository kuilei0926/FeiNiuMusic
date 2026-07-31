import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app/router/app_router.dart';
import '../../app/state/settings_state.dart';

const _primaryNavigationRoutes = <String>[
  AppRoutes.home,
  AppRoutes.songs,
  AppRoutes.recent,
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
  final routeName = _primaryNavigationRoutes[index];
  if (ModalRoute.of(context)?.settings.name == routeName) return;
  final pageBuilder = AppRouter.routes[routeName];
  if (pageBuilder == null) return;
  Navigator.of(context).pushAndRemoveUntil(
    PageRouteBuilder<void>(
      settings: RouteSettings(name: routeName),
      pageBuilder: (context, animation, secondaryAnimation) =>
          pageBuilder(context),
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
    (route) => false,
  );
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
          valueListenable: AppLayoutSettings.tabletMode,
          builder: (context, tabletMode, _) {
            return builder(
              context,
              style == AppNavigationStyle.bottomBar && !tabletMode,
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

  static const List<String> _labels = ['首页', '歌曲', '最近', '收藏', '设置'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // Follow the same panel blur slider used by cards/setting panels so
    // the bottom bar visually belongs to the same surface family.
    return ValueListenableBuilder<double>(
      valueListenable: AppBackgroundSettings.panelBlurStrength,
      builder: (context, _, __) {
        final blurStrength = AppBackgroundSettings.panelBlurStrength.value;
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
              height: 52,
              child: Row(
                children: List.generate(_labels.length, (index) {
                  final selected = currentIndex == index;
                  return Expanded(
                    child: _NavItem(
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
  }
}

class _NavItem extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeColor = scheme.onSurface;
    final inactiveColor = scheme.onSurfaceVariant.withValues(alpha: 0.7);

    return InkWell(
      onTap: onTap,
      // Silence the platform click sound so tab switches don't punctuate the
      // music the user is playing.
      enableFeedback: false,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      child: Center(
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          style: TextStyle(
            color: selected ? activeColor : inactiveColor,
            fontSize: selected ? 16 : 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.2,
          ),
          child: Text(label, maxLines: 1),
        ),
      ),
    );
  }
}
