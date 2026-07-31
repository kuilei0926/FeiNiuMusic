import 'package:flutter/material.dart';

/// 歌词页与播放页逐字歌词共用的颜色解析，保证两侧配色一致。
class LyricsViewColors {
  LyricsViewColors._();

  /// 覆盖值不存在时返回默认色。
  static Color customColorOrDefault(int? value, Color fallback) {
    return value == null ? fallback : Color(value);
  }

  /// 非当前行歌词颜色。
  static Color defaultInactiveColor(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    return theme.brightness == Brightness.light
        ? const Color(0xFF8C8C8C)
        : onSurface.withValues(alpha: 0.45);
  }

  /// 非卡拉OK模式下当前行歌词颜色。
  static Color defaultActiveColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.light
        ? Colors.black
        : theme.colorScheme.onSurface;
  }

  /// 卡拉OK逐字高亮颜色。
  static Color defaultHighlightColor(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.light
        ? Colors.black
        : theme.colorScheme.primaryFixedDim;
  }

  /// 卡拉OK模式下当前行歌词的基础（未高亮）颜色。
  static Color karaokeBaseColor(BuildContext context, {Color? inactiveColor}) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.light
        ? (inactiveColor ?? defaultInactiveColor(context))
        : theme.colorScheme.onSurface.withValues(alpha: 0.85);
  }
}
