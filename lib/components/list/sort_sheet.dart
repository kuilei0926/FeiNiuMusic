import 'package:flutter/material.dart';

import '../../app/state/settings_layout_state.dart';
import '../common/app_list_tile.dart';
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

    // 整行选项：图标 + 名称居左，选中项右侧打勾并高亮为主题色。
    Widget optionRow({
      required String label,
      required IconData icon,
      required bool selected,
      required VoidCallback onTap,
    }) {
      final color = selected ? primaryColor : secondaryTextColor;
      return AppListTile(
        leading: Icon(icon, size: 20, color: color),
        title: label,
        titleColor: color,
        trailing: selected
            ? Icon(Icons.check_rounded, size: 20, color: primaryColor)
            : null,
        onTap: onTap,
      );
    }

    return AppSheetPanel(
      title: widget.title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in widget.options)
            optionRow(
              label: option.label,
              icon: option.icon,
              selected: _currentKey == option.key,
              onTap: () => updateKey(option.key),
            ),
          const SheetSectionTitle('排序方式'),
          optionRow(
            label: '升序',
            icon: Icons.arrow_upward,
            selected: _ascending,
            onTap: () => updateAscending(true),
          ),
          optionRow(
            label: '降序',
            icon: Icons.arrow_downward,
            selected: !_ascending,
            onTap: () => updateAscending(false),
          ),
          if (widget.extra != null) widget.extra!,
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
