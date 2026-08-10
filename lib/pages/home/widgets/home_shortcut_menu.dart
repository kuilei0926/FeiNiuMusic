import 'package:flutter/material.dart';

/// 首页功能入口卡片数据
class HomeShortcutItem {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// 快捷菜单的强调色，用于图标与选中态。
  final Color accent;

  const HomeShortcutItem({
    required this.icon,
    required this.label,
    this.onTap,
    this.accent = const Color(0xFF3B82F6),
  });
}

/// 首页快捷菜单 — 歌曲 / 歌手 / 专辑 / 风格。
///
/// 默认 4×1 一行排列（手机端）；`grid2x2` 时改为 2×2 四宫格（大屏顶部右侧），
/// 每个条目是圆形图标 + 文字标签，点击跳对应库页面。
class HomeShortcutMenu extends StatelessWidget {
  final List<HomeShortcutItem> items;

  /// 是否用 2×2 四宫格布局（大屏首页顶部右侧）。
  final bool grid2x2;

  const HomeShortcutMenu({
    super.key,
    required this.items,
    this.grid2x2 = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (grid2x2) {
      return Column(
        children: [
          for (var r = 0; r < 2; r++) ...[
            if (r > 0) const SizedBox(height: 8),
            Row(
              children: [
                for (var c = 0; c < 2; c++) ...[
                  if (c > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _ShortcutItem(
                      item: items[r * 2 + c],
                      scheme: scheme,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _ShortcutItem(item: items[i], scheme: scheme),
          ),
        ],
      ],
    );
  }
}

class _ShortcutItem extends StatelessWidget {
  final HomeShortcutItem item;
  final ColorScheme scheme;

  const _ShortcutItem({required this.item, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final accent = item.accent;
    final iconSize = 44.0;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: item.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 圆形图标容器
              Container(
                width: iconSize,
                height: iconSize,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(item.icon, size: iconSize * 0.5, color: accent),
              ),
              const SizedBox(height: 6),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
