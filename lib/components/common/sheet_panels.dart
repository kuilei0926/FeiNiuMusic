import 'package:flutter/material.dart';

import '../../app/state/settings_layout_state.dart';
import '../../app/theme/app_visual_theme.dart';

class AppSheetPanel extends StatefulWidget {
  final String? title;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final bool expand;

  const AppSheetPanel({
    super.key,
    this.title,
    required this.child,
    this.padding,
    this.expand = false,
  });

  @override
  State<AppSheetPanel> createState() => _AppSheetPanelState();
}

class _AppSheetPanelState extends State<AppSheetPanel> {
  @override
  void initState() {
    super.initState();
    // 模态底部面板打开：平板/TV/Windows 外壳据此隐藏迷你播放器
    // （外壳在 Navigator 外，面板盖不住它，会挡住面板底部按钮）。
    // 延迟到帧后置位：initState 可能在 build 阶段执行，同步通知外壳
    // ValueListenableBuilder 会触发 "setState during build"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLayoutSettings.modalSheetActive.value = true;
    });
  }

  @override
  void dispose() {
    // 帧后复位：dispose 常在 widget tree 锁定期（面板关闭动画）执行，
    // 同步 notify 祖先会触发 "setState when widget tree was locked"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLayoutSettings.modalSheetActive.value = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final miuix = context.usesMiuix;
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.cardTheme.color ?? theme.cardColor;
    final secondaryTextColor = isDark
        ? Colors.white70
        : const Color.fromARGB(255, 100, 100, 100);

    return Material(
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(miuix ? 30 : 22),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: secondaryTextColor.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            if (widget.title != null)
              Padding(
                padding: EdgeInsets.fromLTRB(20, miuix ? 18 : 16, 20, 10),
                child: Text(
                  widget.title!,
                  style: miuix
                      ? theme.textTheme.titleLarge?.copyWith(fontSize: 20)
                      : TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                ),
              ),
            if (widget.expand)
              Expanded(
                child: Padding(
                  padding: widget.padding ?? EdgeInsets.zero,
                  child: widget.child,
                ),
              )
            else
              Padding(
                padding: widget.padding ?? EdgeInsets.zero,
                child: widget.child,
              ),
          ],
        ),
      ),
    );
  }
}
