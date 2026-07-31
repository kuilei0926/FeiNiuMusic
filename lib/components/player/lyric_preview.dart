import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/widgets/lyric_view.dart';

import '../../../app/services/lyrics/lyrics_service.dart';
import '../../../app/services/lyrics/lyrics_view_colors.dart';

/// 播放页 / 底部控制栏的逐字歌词预览。
///
/// 直接复用歌词详情页的 [LyricView] 渲染管线（AnimationController 驱动 +
/// CustomPainter 高亮），保证与歌词页完全一致的流畅逐字动画，而不是自研一份
/// 高亮逻辑。为避免与歌词页（或其它预览实例）共享 LyricController 造成状态
/// 互相干扰，这里固定为「只读预览」：
///   - [disableTouchEvent]：禁用点按/拖动/选中，播放页的 onTap 跳转由外部
///     GestureDetector 承接；
///   - 关闭行切换动画与选中恢复，不响应全局 switch/resume 事件；
///   - 不注册 onTapLine（不做点歌词 seek）。
///
/// 布局上：LyricView 会把当前播放行滚动到锚点并显示完整上下文，这里通过
/// [clipBehavior] 裁剪到固定高度，视觉上呈现"当前行 + 前后若干行"的迷你窗口，
/// 逐字高亮随进度平滑前进。
class LyricPreview extends StatelessWidget {
  /// 固定预览高度。
  final double height;

  /// 迷你预览的文本对齐方式。
  final TextAlign textAlign;

  /// 迷你预览的对齐。
  final CrossAxisAlignment contentAlignment;

  /// 是否显示翻译行。
  final bool showTranslation;

  /// 基础（未高亮）字号。
  final double fontSize;

  /// 当前播放行字号。
  final double activeFontSize;

  const LyricPreview({
    super.key,
    required this.height,
    this.textAlign = TextAlign.center,
    this.contentAlignment = CrossAxisAlignment.center,
    this.showTranslation = true,
    this.fontSize = 16,
    this.activeFontSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    final lyrics = LyricsService.instance;
    // 监听歌词页设置变化（颜色/字体/翻译等），重建 LyricView 使配色实时同步，
    // 与歌词详情页的行为保持一致。
    return ListenableBuilder(
      listenable: Listenable.merge([
        lyrics.viewSettingsTick,
        lyrics.viewInactiveColor,
        lyrics.viewActiveColor,
        lyrics.viewHighlightColor,
      ]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final onSurface = theme.colorScheme.onSurface;
        final isLight = theme.brightness == Brightness.light;

        final inactiveColor = LyricsViewColors.customColorOrDefault(
          lyrics.viewInactiveColor.value,
          LyricsViewColors.defaultInactiveColor(context),
        );
        final activeColor = LyricsViewColors.customColorOrDefault(
          lyrics.viewActiveColor.value,
          LyricsViewColors.defaultActiveColor(context),
        );
        final highlightColor = LyricsViewColors.customColorOrDefault(
          lyrics.viewHighlightColor.value,
          LyricsViewColors.defaultHighlightColor(context),
        );
        final karaokeBaseColor = LyricsViewColors.karaokeBaseColor(
          context,
          inactiveColor: inactiveColor,
        );

        // 与歌词详情页保持同一份 LyricStyle 构造，但锁定为只读预览。
        final style = LyricStyle(
          textStyle: TextStyle(
            color: inactiveColor,
            fontSize: fontSize,
            height: 1.3,
          ),
          activeStyle: TextStyle(
            color: karaokeBaseColor,
            fontSize: activeFontSize,
            fontWeight: FontWeight.w700,
            height: 1.3,
          ),
          translationStyle: showTranslation
              ? TextStyle(
                  color: isLight
                      ? const Color(0xFF7A7A7A)
                      : onSurface.withValues(alpha: 0.35),
                  fontSize: fontSize * 0.85,
                  height: 1.2,
                )
              : const TextStyle(
                  color: Colors.transparent,
                  fontSize: 0,
                  height: 0,
                ),
          translationActiveColor: showTranslation
              ? onSurface.withValues(alpha: 0.9)
              : Colors.transparent,
          lineTextAlign: textAlign,
          contentAlignment: contentAlignment,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 12,
          ),
          lineGap: 14,
          translationLineGap: showTranslation ? 8 : 0,
          selectionAnchorPosition: 0.5,
          activeAnchorPosition: 0.5,
          selectionAlignment: MainAxisAlignment.center,
          activeAlignment: MainAxisAlignment.center,
          scrollDuration: const Duration(milliseconds: 380),
          scrollCurve: Curves.easeOutCubic,
          selectedColor: activeColor,
          selectedTranslationColor: onSurface.withValues(alpha: 0.9),
          selectionAutoResumeDuration: const Duration(milliseconds: 200),
          // 只读预览：长时间停留在当前行，不自动切走
          activeAutoResumeDuration: const Duration(days: 365),
          disableTouchEvent: true,
          // 关闭行切换动画：避免多个 LyricView 实例共同响应全局 switch 事件
          enableSwitchAnimation: false,
          activeHighlightGradient: LinearGradient(
            colors: [
              highlightColor.withValues(alpha: 1.0),
              highlightColor.withValues(alpha: 1.0),
            ],
          ),
          activeHighlightExtraFadeWidth: 0,
        );

        return ClipRect(
          child: SizedBox(
            height: height,
            child: LyricView(
              controller: lyrics.controller,
              style: style,
            ),
          ),
        );
      },
    );
  }
}
