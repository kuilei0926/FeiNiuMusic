import 'package:flutter/material.dart';

import '../../app/state/settings_layout_state.dart';
import '../common/sheet_panels.dart';

class SortOption {
  final String key;
  final String label;
  final IconData icon;

  const SortOption({
    required this.key,
    required this.label,
    required this.icon,
  });
}

class SortSheet extends StatefulWidget {
  final List<SortOption> options;
  final String currentKey;
  final bool ascending;
  final ValueChanged<String> onSelectKey;
  final ValueChanged<bool> onSelectAscending;
  final String title;
  final Widget? extra;

  const SortSheet({
    super.key,
    required this.options,
    required this.currentKey,
    required this.ascending,
    required this.onSelectKey,
    required this.onSelectAscending,
    this.title = '歌曲排序',
    this.extra,
  });

  @override
  State<SortSheet> createState() => _SortSheetState();
}

class _SortSheetState extends State<SortSheet> {
  late String _currentKey;
  late bool _ascending;

  @override
  void initState() {
    super.initState();
    _currentKey = widget.currentKey;
    _ascending = widget.ascending;
    // 排序面板作为模态底部面板打开：平板/TV/Windows 外壳据此隐藏迷你播放器
    // （外壳在 Navigator 外，sheet 盖不住它，会挡住 sheet 底部按钮）。
    // 延迟到帧后置位：本 initState 可能在 build 阶段执行，同步通知外壳
    // ValueListenableBuilder 会触发 "setState during build"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLayoutSettings.modalSheetActive.value = true;
    });
  }

  @override
  void dispose() {
    // 帧后复位：dispose 常在 widget tree 锁定期（sheet 关闭动画）执行，
    // 同步 notify 祖先会触发 "setState when widget tree was locked"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppLayoutSettings.modalSheetActive.value = false;
    });
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SortSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentKey != widget.currentKey) {
      _currentKey = widget.currentKey;
    }
    if (oldWidget.ascending != widget.ascending) {
      _ascending = widget.ascending;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final secondaryTextColor =
        isDark ? Colors.white70 : const Color.fromARGB(255, 100, 100, 100);
    final primaryColor = theme.colorScheme.primary;

    void updateKey(String value) {
      setState(() => _currentKey = value);
      widget.onSelectKey(value);
    }

    void updateAscending(bool value) {
      setState(() => _ascending = value);
      widget.onSelectAscending(value);
    }

    Widget sectionTitle(String text) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          text,
          style: TextStyle(
            color: secondaryTextColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    Widget buildGridOption({
      required String label,
      required IconData icon,
      required bool selected,
      required VoidCallback onTap,
      bool alignRight = false,
    }) {
      final color = selected ? primaryColor : secondaryTextColor;
      final bgColor = selected
          ? primaryColor.withValues(alpha: isDark ? 0.18 : 0.12)
          : Colors.transparent;
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: alignRight ? TextAlign.right : TextAlign.left,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget row(Widget left, Widget right) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              left,
              right,
            ],
          ),
        ),
      );
    }

    List<Widget> buildOptionRows() {
      final rows = <Widget>[];
      for (var i = 0; i < widget.options.length; i += 2) {
        final left = widget.options[i];
        final right = i + 1 < widget.options.length ? widget.options[i + 1] : null;
        rows.add(
          row(
            buildGridOption(
              label: left.label,
              icon: left.icon,
              selected: _currentKey == left.key,
              onTap: () => updateKey(left.key),
            ),
            right == null
                ? const SizedBox.shrink()
                : buildGridOption(
                    label: right.label,
                    icon: right.icon,
                    selected: _currentKey == right.key,
                    onTap: () => updateKey(right.key),
                    alignRight: true,
                  ),
          ),
        );
      }
      return rows;
    }

    return AppSheetPanel(
      title: widget.title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              final contentWidth =
                  (maxWidth - 56).clamp(0.0, maxWidth).toDouble();
              return Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: contentWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: buildOptionRows(),
                  ),
                ),
              );
            },
          ),
          sectionTitle('排序方式'),
          LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              final contentWidth =
                  (maxWidth - 96).clamp(0.0, maxWidth).toDouble();
              return Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: contentWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      buildGridOption(
                        label: '升序',
                        icon: Icons.arrow_upward,
                        selected: _ascending,
                        onTap: () => updateAscending(true),
                      ),
                      buildGridOption(
                        label: '降序',
                        icon: Icons.arrow_downward,
                        selected: !_ascending,
                        onTap: () => updateAscending(false),
                        alignRight: true,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          if (widget.extra != null) widget.extra!,
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
