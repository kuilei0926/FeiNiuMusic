import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shad;

import '../components/dialog/app_update_dialog.dart';
import '../components/focus/tv_focus_scope.dart';
import '../components/layout/tablet_layout_host.dart';
import '../pages/login/login_page.dart';
import '../pages/onboarding/onboarding_page.dart';
import 'navigator_key.dart';
import 'router/app_page_route.dart';
import 'router/app_router.dart';
import 'services/app_update_service.dart';
import 'services/feiniu/account_store.dart';
import 'services/feiniu/auth_service.dart';
import 'state/settings_state.dart';
import 'theme/app_styles.dart';
import 'theme/app_visual_theme.dart';
import 'utils/app_navigator.dart';
import 'utils/route_visibility.dart';

class FeiNiuMusicApp extends StatelessWidget {
  const FeiNiuMusicApp({super.key});

  ThemeData _applyDynamic(
    ThemeData base,
    ColorScheme? scheme,
    AppVisualStyle visualStyle,
    bool isTv,
  ) {
    final appliedScheme = scheme ?? base.colorScheme;
    if (visualStyle == AppVisualStyle.miuix) {
      return buildMiuixMaterialTheme(base, appliedScheme, isTv: isTv);
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
                        return ValueListenableBuilder<bool>(
                          valueListenable: AppLayoutSettings.tvMode,
                          builder: (context, isTv, _) {
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
                          isTv,
                        );
                        final darkTheme = _applyDynamic(
                          darkBase,
                          dynamicEnabled ? darkDynamic : null,
                          visualStyle,
                          isTv,
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

                        return _TvOrientationSync(
                          tv: isTv,
                          child: MaterialApp(
                          title: '飞牛音乐',
                          navigatorKey: appNavigatorKey,
                          theme: lightTheme,
                          darkTheme: darkTheme,
                          themeMode: mode,
                          scrollBehavior: const AppScrollBehavior(),
                          home: _AppStartupGate(
                            tv: isTv,
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
                            // TV 模式：根焦点域（方向键遍历 + 快捷键）。
                            // 手机端 isTv=false，完全绕开，行为不变。
                            if (isTv) {
                              content = TvFocusScope(child: content);
                            }
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
                          ),
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
      },
    );
  }
}

/// TV 模式方向同步：`tv` 变化时锁定/解锁横屏。
///
/// 自动检测或手动开关任一改变 tvMode，这里都会响应：TV 开启锁横屏，
/// 关闭恢复竖屏（手机默认）。手机端 tv=false 时是 no-op。
class _TvOrientationSync extends StatefulWidget {
  final bool tv;
  final Widget child;

  const _TvOrientationSync({required this.tv, required this.child});

  @override
  State<_TvOrientationSync> createState() => _TvOrientationSyncState();
}

class _TvOrientationSyncState extends State<_TvOrientationSync> {
  @override
  void didUpdateWidget(_TvOrientationSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tv == widget.tv) return;
    _applyOrientation(widget.tv);
  }

  @override
  void initState() {
    super.initState();
    // 首帧应用一次，覆盖 main() 里未处理的手动开关场景。
    _applyOrientation(widget.tv);
  }

  void _applyOrientation(bool tv) {
    SystemChrome.setPreferredOrientations(
      tv
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// APP 启动门控
///
/// 登录状态切换门控：
/// - 未登录 → LoginPage
/// - 已登录 → 直接进主页面（后台探测在 main() 中异步执行，不阻塞首页渲染）
class _AppStartupGate extends StatefulWidget {
  final bool tv;
  final Route<dynamic> Function(RouteSettings) onGenerateRoute;

  const _AppStartupGate({required this.tv, required this.onGenerateRoute});

  @override
  State<_AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<_AppStartupGate> {
  bool _scheduledAutoCheck = false;
  bool _scheduledAutoOpenPlayer = false;

  /// 当前账号对应的嵌套基础 Navigator key（随账号变化重建）。
  /// 自动打开播放页必须压到该嵌套导航器上（门控自身的 context 会解析到根
  /// 导航器，压根导航器会盖住门控，破坏登录/登出回退到门控的规则）。
  GlobalKey<NavigatorState>? _baseNavKey;

  /// 账号 → 嵌套基础 Navigator key。key 用 [GlobalObjectKey] 并依赖
  /// `identical()` 判等（见 framework.dart GlobalObjectKey.==），因此必须
  /// **复用同一个 key 实例**：若每次 build 都新建 `'base-nav-$accountId'`
  /// 字符串，identical 恒为 false，任何触发门控重建的事件（如 dynamic_color
  /// 动态取色异步到达、主题切换）都会让嵌套 Navigator 以新 key 重新挂载，
  /// 导航栈被清零回 /home —— 启动自动打开的播放页就这样被冲掉。
  /// 同一账号复用同一个 key 实例后，重建只是普通 rebuild，Navigator 连同
  /// 已压栈的路由原样保留。
  final Map<String, GlobalKey<NavigatorState>> _baseNavKeys = {};

  /// 取账号对应的 key：首次为该账号创建并缓存，之后复用同一实例。
  GlobalKey<NavigatorState> _navKeyFor(String accountId) {
    return _baseNavKeys.putIfAbsent(accountId, () {
      return GlobalObjectKey<NavigatorState>('base-nav-$accountId');
    });
  }

  @override
  Widget build(BuildContext context) {
    // 首次启动引导门控：未完成引导一律全屏显示，与登录态无关；
    // 完成后（completed=true）才进入下方登录/外壳逻辑。
    return ValueListenableBuilder<bool>(
      valueListenable: AppOnboardingSettings.completed,
      builder: (context, onboardingCompleted, _) {
        if (!onboardingCompleted) {
          return const OnboardingPage();
        }
        return ValueListenableBuilder<bool>(
          valueListenable: AuthService.instance.isLoggedIn,
          builder: (context, isLoggedIn, _) {
            if (!isLoggedIn) {
              return const LoginPage();
            }
            // 已登录进入主界面：首帧后自动检查更新（仅一次/会话，开关开启且有
            // 新版本才弹窗，不阻塞渲染）。登录后才触发，避免登录页被更新弹窗遮挡。
            if (!_scheduledAutoCheck) {
              _scheduledAutoCheck = true;
              _scheduleAutoCheckUpdate();
            }
            // 启动后自动打开播放界面：在门控（非登录态）首帧后跳转，覆盖
            // 抽屉/底部栏/平板所有导航模式。仅本次 session 首次生效；
            // 切换账号重建外壳不会重复跳转。
            if (!_scheduledAutoOpenPlayer) {
              _scheduledAutoOpenPlayer = true;
              _scheduleAutoOpenPlayer();
            }
            // 切换账号时 isLoggedIn 保持 true（门控不重建），但整个外壳需按当前
            // 账号重建：给外壳换 key → 所有存活页面卸载重建 → initState 重跑 →
            // 用新 token/服务器地址拉取数据；导航栈同时重置回首页。
            // 注意：嵌套 Navigator 的 GlobalKey 必须随账号变化（GlobalObjectKey 值相等性）。
            // 若沿用固定的 baseNavigatorKey，Flutter 会把旧 Navigator 连同整个页面树
            // reparent 到新子树（GlobalKey 重挂），页面不会重挂载、数据不会刷新。
            return ValueListenableBuilder<String?>(
              valueListenable: AccountStore.instance.currentAccountId,
              builder: (context, accountId, _) {
                // 同账号复用同一个 key 实例（GlobalObjectKey 用 identical 判等），
                // 避免每次 build 新建 key 导致嵌套 Navigator 被整体重挂、导航栈清零。
                final navKey = _navKeyFor(accountId ?? 'none');
                _baseNavKey = navKey;
                // 注册全局嵌套导航器：TV 遥控器快捷键（搜索键）压栈用。
                AppNavigator.attach(navKey);
                return KeyedSubtree(
                  key: ValueKey('shell-${accountId ?? 'none'}'),
                  child: TabletLayoutHost(
                    navigatorKey: navKey,
                    child: Navigator(
                      key: navKey,
                      // 挂载 appRouteObserver：应用内所有路由都在此嵌套 Navigator
                      // 上，注册后 AppRouteVisibilityMixin（didPushNext/didPopNext）
                      // 才能按文档生效，播放页/流光预览的路由可见性暂停才有意义。
                      observers: [appRouteObserver],
                      // TV 方向键跨块：路由 scope 默认 directionalEdgeBehavior
                      // 是 stop，横向/纵向到边缘就停住，进不了左侧侧边栏、也下不到
                      // 迷你播放器。TV 时放开为 parentScope，让最外层 WidgetsApp
                      // 的 ReadingOrder 策略按几何位置找到侧栏/迷你播放器。
                      routeDirectionalTraversalEdgeBehavior: widget.tv
                          ? TraversalEdgeBehavior.parentScope
                          : kDefaultRouteDirectionalTraversalEdgeBehavior,
                      initialRoute: AppRouter.initialRoute,
                      onGenerateRoute: widget.onGenerateRoute,
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 启动后延迟自动检查更新：给首页首帧留出渲染空间，检查在后台静默进行，
  /// 有新版本时才弹窗提示。整个会话只检查一次。
  void _scheduleAutoCheckUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _autoCheckUpdate();
    });
  }

  /// 启动后自动打开播放界面：用户开启该开关时，给首帧留出渲染空间后
  /// 再压栈播放页（仅本次 session 首次）。放在门控而非各页面/外壳里，
  /// 确保抽屉 / 底部栏 / 平板等所有导航模式都能生效。
  ///
  /// 必须压到当前账号的嵌套基础导航器上，不能压根导航器（根导航器会被
  /// 门控盖住，破坏登录/登出回退到门控的规则）。
  ///
  /// 用 [AppLaunchNavigationSettings.shouldAutoOpenPlayerOnLaunch] 判断：
  /// 首次启动引导页刚勾选该开关、引导完成的当次不自动打开（等下次启动），
  /// 且本次 session 只判断一次（切换账号重建外壳不重复跳转）。
  void _scheduleAutoOpenPlayer() {
    if (!AppLaunchNavigationSettings.shouldAutoOpenPlayerOnLaunch()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nav = _baseNavKey?.currentState;
      if (nav == null) return;
      nav.pushNamed(AppRoutes.player);
    });
  }

  Future<void> _autoCheckUpdate() async {
    await AppLaunchUpdateSettings.ensureLoaded();
    if (!AppLaunchUpdateSettings.autoCheckUpdateOnLaunch.value) return;
    if (AppLaunchUpdateSettings.hasCheckedUpdateThisSession) return;
    AppLaunchUpdateSettings.hasCheckedUpdateThisSession = true;
    try {
      final current = await AppUpdateService.instance.currentVersion();
      final info = await AppUpdateService.instance.checkLatest(current);
      if (!mounted || !info.hasUpdate) return;
      await showAppUpdateDialog(
        context,
        info: info,
        currentVersion: current,
      );
    } catch (_) {
      // 静默失败：自动检查失败不打扰用户，手动检查仍可用
    }
  }
}
