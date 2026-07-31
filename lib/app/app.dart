import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;

import '../components/layout/tablet_layout_host.dart';
import '../pages/login/login_page.dart';
import 'router/app_page_route.dart';
import 'router/app_router.dart';
import 'services/feiniu/auth_service.dart';
import 'state/settings_state.dart';
import 'theme/app_styles.dart';
import 'theme/app_visual_theme.dart';
import 'utils/route_visibility.dart';

class FeiNiuMusicApp extends StatelessWidget {
  static final GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>();
  static final GlobalKey<NavigatorState> baseNavigatorKey =
      GlobalKey<NavigatorState>();

  const FeiNiuMusicApp({super.key});

  ThemeData _applyDynamic(
    ThemeData base,
    ColorScheme? scheme,
    AppVisualStyle visualStyle,
  ) {
    final appliedScheme = scheme ?? base.colorScheme;
    if (visualStyle == AppVisualStyle.miuix) {
      return buildMiuixMaterialTheme(base, appliedScheme);
    }
    final isDark = base.brightness == Brightness.dark;

    final scaffoldBg = isDark
        ? Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.04),
            appliedScheme.surface,
          )
        : Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.06),
            appliedScheme.surface,
          );

    final panelColor = isDark
        ? Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.08),
            appliedScheme.surfaceContainerHigh,
          )
        : Color.alphaBlend(
            appliedScheme.primary.withValues(alpha: 0.12),
            Colors.white,
          );

    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.35)
        : appliedScheme.primary.withValues(alpha: 0.16);

    return base.copyWith(
      colorScheme: appliedScheme,
      primaryColor: appliedScheme.primary,
      scaffoldBackgroundColor: scaffoldBg,
      cardColor: panelColor,
      cardTheme: base.cardTheme.copyWith(
        color: panelColor,
        shadowColor: shadowColor,
        elevation: 0,
      ),
      dialogTheme: base.dialogTheme.copyWith(backgroundColor: panelColor),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: panelColor,
        modalBackgroundColor: panelColor,
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        foregroundColor: appliedScheme.onSurface,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return ValueListenableBuilder<AppVisualStyle>(
          valueListenable: AppThemeSettings.visualStyle,
          builder: (context, visualStyle, _) {
            return ValueListenableBuilder<ThemeMode>(
              valueListenable: AppThemeSettings.themeMode,
              builder: (context, mode, _) {
                return ValueListenableBuilder<bool>(
                  valueListenable: AppThemeSettings.dynamicColorEnabled,
                  builder: (context, dynamicEnabled, _) {
                    return ValueListenableBuilder<Color?>(
                      valueListenable: AppThemeSettings.themeSeedColor,
                      builder: (context, seedColor, _) {
                        final baseSeed = seedColor ?? const Color(0xFF3B82F6);
                        final lightBase = ThemeData(
                          colorScheme: ColorScheme.fromSeed(
                            seedColor: baseSeed,
                            brightness: Brightness.light,
                          ),
                          useMaterial3: true,
                          pageTransitionsTheme: const PageTransitionsTheme(
                            builders: {
                              TargetPlatform.android:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.iOS: CoverPageTransitionsBuilder(),
                              TargetPlatform.macOS:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.windows:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.linux:
                                  CoverPageTransitionsBuilder(),
                            },
                          ),
                        );
                        final darkBase = ThemeData(
                          colorScheme: ColorScheme.fromSeed(
                            seedColor: baseSeed,
                            brightness: Brightness.dark,
                          ),
                          useMaterial3: true,
                          pageTransitionsTheme: const PageTransitionsTheme(
                            builders: {
                              TargetPlatform.android:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.iOS: CoverPageTransitionsBuilder(),
                              TargetPlatform.macOS:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.windows:
                                  CoverPageTransitionsBuilder(),
                              TargetPlatform.linux:
                                  CoverPageTransitionsBuilder(),
                            },
                          ),
                        );
                        final lightTheme = _applyDynamic(
                          lightBase,
                          dynamicEnabled ? lightDynamic : null,
                          visualStyle,
                        );
                        final darkTheme = _applyDynamic(
                          darkBase,
                          dynamicEnabled ? darkDynamic : null,
                          visualStyle,
                        );
                        final routes = AppRouter.routes;
                        Route<dynamic> onGenerateRoute(RouteSettings settings) {
                          final name = settings.name ?? AppRoutes.home;
                          final target =
                              routes[name] ?? routes[AppRoutes.home]!;
                          return buildAppPageRoute<dynamic>(
                            target,
                            settings: settings,
                          );
                        }

                        return MaterialApp(
                          title: '飞牛音乐',
                          navigatorKey: rootNavigatorKey,
                          theme: lightTheme,
                          darkTheme: darkTheme,
                          themeMode: mode,
                          scrollBehavior: const AppScrollBehavior(),
                          navigatorObservers: [appRouteObserver],
                          home: _AppStartupGate(
                            baseNavigatorKey: baseNavigatorKey,
                            onGenerateRoute: onGenerateRoute,
                          ),
                          onGenerateRoute: onGenerateRoute,
                          builder: (context, child) {
                            final theme = Theme.of(context);
                            final isDark = theme.brightness == Brightness.dark;
                            final navColor = theme.colorScheme.surface;
                            final overlay = SystemUiOverlayStyle(
                              statusBarColor: Colors.transparent,
                              statusBarIconBrightness: isDark
                                  ? Brightness.light
                                  : Brightness.dark,
                              statusBarBrightness: isDark
                                  ? Brightness.dark
                                  : Brightness.light,
                              systemNavigationBarColor: navColor,
                              systemNavigationBarIconBrightness: isDark
                                  ? Brightness.light
                                  : Brightness.dark,
                              systemNavigationBarDividerColor: navColor,
                            );
                            Widget content =
                                AnnotatedRegion<SystemUiOverlayStyle>(
                                  value: overlay,
                                  child: child ?? const SizedBox.shrink(),
                                );
                            if (visualStyle == AppVisualStyle.miuix) {
                              final shadMode = switch (mode) {
                                ThemeMode.light => shad.ThemeMode.light,
                                ThemeMode.dark => shad.ThemeMode.dark,
                                ThemeMode.system => shad.ThemeMode.system,
                              };
                              content = shad.ShadcnLayer(
                                theme: buildMiuixShadTheme(
                                  lightTheme.colorScheme,
                                ),
                                darkTheme: buildMiuixShadTheme(
                                  darkTheme.colorScheme,
                                ),
                                themeMode: shadMode,
                                scaling: const shad.AdaptiveScaling(),
                                child: content,
                              );
                            }
                            return content;
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// APP 启动门控
///
/// 登录状态切换门控：
/// - 未登录 → LoginPage
/// - 已登录 → 直接进主页面（后台探测在 main() 中异步执行，不阻塞首页渲染）
class _AppStartupGate extends StatefulWidget {
  final GlobalKey<NavigatorState> baseNavigatorKey;
  final Route<dynamic> Function(RouteSettings) onGenerateRoute;

  const _AppStartupGate({
    required this.baseNavigatorKey,
    required this.onGenerateRoute,
  });

  @override
  State<_AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<_AppStartupGate> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AuthService.instance.isLoggedIn,
      builder: (context, isLoggedIn, _) {
        if (!isLoggedIn) {
          return const LoginPage();
        }
        return TabletLayoutHost(
          navigatorKey: widget.baseNavigatorKey,
          child: Navigator(
            key: widget.baseNavigatorKey,
            initialRoute: AppRouter.initialRoute,
            onGenerateRoute: widget.onGenerateRoute,
          ),
        );
      },
    );
  }
}
