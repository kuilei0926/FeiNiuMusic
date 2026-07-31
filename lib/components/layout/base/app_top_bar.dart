import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/router/app_router.dart';
import '../../../app/state/settings_fn_state.dart';
import '../../../app/state/settings_theme_state.dart';
import '../../../app/theme/app_fonts.dart';

class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final Widget? titleWidget;
  final Widget? leading;
  final List<Widget>? actions;
  final bool? centerTitle;
  final bool showBackButton;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double elevation;
  final double? height;
  final PreferredSizeWidget? bottom;
  final bool? isRefreshing;

  const AppTopBar({
    super.key,
    this.title,
    this.titleWidget,
    this.leading,
    this.actions,
    this.centerTitle,
    this.showBackButton = true,
    this.backgroundColor,
    this.foregroundColor,
    this.elevation = 0,
    this.height,
    this.bottom,
    this.isRefreshing,
  });

  @override
  Size get preferredSize => Size.fromHeight(
    (height ??
            (AppThemeSettings.visualStyle.value == AppVisualStyle.miuix
                ? 56
                : 48)) +
        (bottom?.preferredSize.height ?? 0),
  );

  @override
  Widget build(BuildContext context) {
    final miuix = AppThemeSettings.visualStyle.value == AppVisualStyle.miuix;
    final resolvedHeight = height ?? (miuix ? 56 : 48);
    final titleStyle = AppFonts.topBarTitleStyle(Theme.of(context).textTheme)
        .copyWith(
          fontSize: miuix ? 22 : null,
          fontWeight: miuix ? FontWeight.w700 : null,
          letterSpacing: miuix ? -0.2 : null,
        );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
    );
    final resolvedActions = <Widget>[...(actions ?? const [])];
    if (isRefreshing == true) {
      resolvedActions.insert(
        0,
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: foregroundColor,
            ),
          ),
        ),
      );
    }
    resolvedActions.add(const _ConnectionFailedAction());
    return AppBar(
      title:
          titleWidget ??
          (title != null ? Text(title!, style: titleStyle) : null),
      leading: leading,
      actions: resolvedActions,
      centerTitle: centerTitle ?? !miuix,
      automaticallyImplyLeading: showBackButton,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      elevation: elevation,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: resolvedHeight,
      bottom: bottom,
      systemOverlayStyle: overlayStyle,
    );
  }
}

/// 连接失败提示（AppBar 标题右侧的 actions 区域）
///
/// 当 [AppFnConnectionSettings.serverConnected] 为 false 时显示，
/// 点击跳转连接设置页处理。不占用额外布局空间。
class _ConnectionFailedAction extends StatelessWidget {
  const _ConnectionFailedAction();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFnId = (AppFnConnectionSettings.lastFnId ?? '').isNotEmpty;
    return ValueListenableBuilder<bool>(
      valueListenable: AppFnConnectionSettings.serverConnected,
      builder: (context, connected, _) {
        if (connected) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: IconButton(
            tooltip: '服务器连接失败，点击处理',
            onPressed: () {
              Navigator.pushNamed(
                context,
                isFnId ? AppRoutes.fnConnectSettings : AppRoutes.settings,
              );
            },
            icon: Icon(
              Icons.wifi_off_rounded,
              size: 18,
              color: colorScheme.error,
            ),
          ),
        );
      },
    );
  }
}
