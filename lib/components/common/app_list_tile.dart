import 'package:flutter/material.dart';

import '../../app/state/settings_state.dart';

class AppListTile extends StatelessWidget {
  final Widget? leading;
  final String? title;
  final Widget? titleWidget;
  final String? subtitle;
  final Color? titleColor;
  final Color? subtitleColor;
  final Widget? trailing;
  final EdgeInsetsGeometry? contentPadding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool dense;
  final Color? backgroundColor;

  const AppListTile({
    super.key,
    this.leading,
    this.title,
    this.titleWidget,
    this.subtitle,
    this.titleColor,
    this.subtitleColor,
    this.trailing,
    this.contentPadding,
    this.onTap,
    this.onLongPress,
    this.dense = true,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final defaultTitleColor = theme.colorScheme.onSurface;
    final defaultSubtitleColor =
        isDark ? Colors.white70 : const Color.fromARGB(255, 100, 100, 100);
    final isTv = AppLayoutSettings.tvMode.value;

    return Material(
      color: backgroundColor ?? Colors.transparent,
      child: ListTile(
        dense: isTv ? false : dense,
        // TV 端加大列表行高度，方便遥控器聚焦命中与 3 米外阅读。
        minVerticalPadding: isTv ? 16 : null,
        contentPadding: isTv
            ? (contentPadding ??
                const EdgeInsets.symmetric(horizontal: 20, vertical: 4))
            : contentPadding,
        leading: leading,
        title: titleWidget ??
            (title != null
                ? Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor ?? defaultTitleColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: subtitleColor ?? defaultSubtitleColor,
                  fontSize: 12,
                ),
              )
            : null,
        trailing: trailing,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
