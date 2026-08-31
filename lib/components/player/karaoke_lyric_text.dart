import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_lyric/core/lyric_model.dart';

import '../../app/services/lyrics/lyrics_service.dart';
import '../../app/services/lyrics/lyrics_view_colors.dart';

const Duration _kHighlightTransitionDuration = Duration(milliseconds: 200);

/// 单行歌词的逐字高亮文本。
///
/// 基础样式绘制整行，高亮部分按单词时间戳从左侧渐进覆盖已唱部分，
/// 与歌词详情页保持一致：高亮宽度用短时线性动画平滑过渡，行结束立即铺满，
/// 同一行内正向播放时只增不减，高亮边界为硬边（无渐变淡出）。
/// 渲染使用缓存的 [TextPainter] + [CustomPainter]，每帧只重绘不重新布局，
/// 与歌词详情页相同，避免逐帧重建 Text/ShaderMask 造成的卡顿。
/// 没有单词时间戳时，会按字符把整行时长等分模拟逐字。
/// 未显式传入 [baseColor] / [highlightColor] 时，分别使用歌词页配置的
/// "普通歌词颜色"（卡拉OK基准色）与"逐字高亮颜色"。
class KaraokeLyricText extends StatefulWidget {
  /// 需要渲染的歌词行。
  final LyricLine line;

  /// 当前播放进度（一般传 `LyricsService.instance.controller.progressNotifier`）。
  final ValueListenable<Duration> position;

  /// 歌词整体校准偏移（对应 `controller.lyricOffset`）。
  final Duration offset;

  /// 该行结束时间；为 null 时回退为行开始 + 3 秒。
  final Duration? lineEnd;

  /// 基础（未高亮）文本样式。
  final TextStyle style;

  /// 基础（未高亮）颜色；为 null 时使用歌词页的卡拉OK基准色。
  final Color? baseColor;

  /// 逐字高亮颜色；为 null 时使用歌词页的"逐字高亮颜色"设置。
  final Color? highlightColor;

  final TextAlign textAlign;
  final TextDirection textDirection;
  final int? maxLines;
  final TextOverflow overflow;

  const KaraokeLyricText({
    super.key,
    required this.line,
    required this.position,
    required this.style,
    this.baseColor,
    this.highlightColor,
    this.offset = Duration.zero,
    this.lineEnd,
    this.textAlign = TextAlign.start,
    this.textDirection = TextDirection.ltr,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  @override
  State<KaraokeLyricText> createState() => _KaraokeLyricTextState();
}

class _KaraokeLyricTextState extends State<KaraokeLyricText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  LyricLine? _renderedLine;
  bool _pendingReset = true;
  double _fullWidth = 0;
  int _lastUpdateAtMs = 0;
  Duration _lastProgress = Duration.zero;
  List<double>? _wordWidths;
  double _sumWordWidths = 0;
  TextStyle? _wordWidthsStyle;

  // 缓存的整行 TextPainter：文本/样式/约束不变时复用，动画每帧只重绘不重排。
  TextPainter? _textPainter;
  String? _painterText;
  TextStyle? _painterStyle;
  double _painterMaxWidth = -1;
  TextAlign? _painterAlign;
  TextDirection? _painterDirection;
  int? _painterMaxLines;
  String? _painterEllipsis;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _kHighlightTransitionDuration,
    );
    widget.position.addListener(_onProgressChanged);
  }

  @override
  void didUpdateWidget(covariant KaraokeLyricText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onProgressChanged);
      widget.position.addListener(_onProgressChanged);
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_onProgressChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onProgressChanged() {
    _updateTarget();
  }

  void _updateTarget() {
    if (!mounted) return;
    // 若 position 通知恰好落在 build/layout 帧内（播放中逐帧驱动时可能发生），
    // 同步改 _controller 会触发监听它的 ValueListenableBuilder 同步
    // markNeedsBuild → “setState called during build” 级联崩溃。
    // 非安全期先登记，帧后统一执行。
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.idle) {
      _scheduleTargetUpdate();
      return;
    }
    _applyTargetUpdate();
  }

  bool _targetUpdateScheduled = false;

  void _scheduleTargetUpdate() {
    if (_targetUpdateScheduled) return;
    _targetUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _targetUpdateScheduled = false;
      if (!mounted) return;
      _applyTargetUpdate();
    });
  }

  void _applyTargetUpdate() {
    if (!mounted) return;
    final line = widget.line;
    final text = line.text;
    if (text.isEmpty) return;
    final fullWidth = _fullWidth;
    if (fullWidth <= 0) return;
    final progress = widget.position.value + widget.offset;

    // 与详情页相同：优先用真实单词时间戳，否则按字符把整行时长等分模拟
    final words = _resolveLineWords() ?? const <LyricWord>[];
    _ensureWordWidths(words);
    final wordWidths = _wordWidths ?? const <double>[];
    final widthScale = _sumWordWidths > 0 && fullWidth > 0
        ? fullWidth / _sumWordWidths
        : 1.0;

    // 与详情页相同：仅当有明确行结束时间且已到行末时才立即铺满
    final lineEnd = widget.lineEnd;
    if (lineEnd != null && progress >= lineEnd) {
      _controller.stop();
      _controller.value = 1.0;
      _lastUpdateAtMs = 0;
      _lastProgress = progress;
      return;
    }

    if (words.isEmpty) {
      _animateTo(0.0);
      _lastProgress = progress;
      return;
    }

    // 与详情页相同：测不出字宽时按时间比例铺满
    if (fullWidth <= 0 || _sumWordWidths <= 0) {
      final lineStart = line.start;
      if (lineEnd != null && lineEnd > lineStart) {
        final totalMs = (lineEnd - lineStart).inMilliseconds;
        final elapsedMs = (progress - lineStart).inMilliseconds;
        if (totalMs > 0) {
          _animateTo((elapsedMs / totalMs).clamp(0.0, 1.0));
          _lastProgress = progress;
          return;
        }
      }
    }

    var newWidth = 0.0;
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      final wordWidth = wordWidths[i];
      final wordStart = word.start;
      if (progress < wordStart) break;
      newWidth += wordWidth;

      final rawEnd = word.end;
      final hasValidEnd = rawEnd != null && rawEnd > wordStart;
      Duration wordEnd = hasValidEnd
          ? rawEnd
          : wordStart + const Duration(milliseconds: 120);
      if (i + 1 < words.length) {
        final nextStart = words[i + 1].start;
        if (rawEnd == null && nextStart > wordStart) {
          wordEnd = nextStart;
        }
      } else if (!hasValidEnd && lineEnd != null && lineEnd > wordStart) {
        wordEnd = lineEnd;
      }

      if (progress < wordEnd) {
        final wordDuration = (wordEnd - wordStart).inMilliseconds;
        final elapsed = (progress - wordStart).inMilliseconds;
        if (wordDuration > 0) {
          newWidth -= wordWidth * (1 - elapsed / wordDuration);
        }
      }
    }

    var scaledWidth = (newWidth * widthScale).clamp(0.0, fullWidth);
    // 与详情页相同：同一行内正向播放时高亮只增不减，避免回缩抖动
    final currentWidth = _controller.value * fullWidth;
    if (!_pendingReset &&
        progress >= _lastProgress &&
        scaledWidth < currentWidth) {
      scaledWidth = currentWidth;
    }
    _lastProgress = progress;
    _animateTo((scaledWidth / fullWidth).clamp(0.0, 1.0));
  }

  void _animateTo(double target) {
    final current = _controller.value;
    if ((current - target).abs() < 0.0001) return;
    if (target < current) {
      _controller.stop();
      _controller.value = target;
      _lastUpdateAtMs = 0;
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dtMs = _lastUpdateAtMs > 0
        ? (nowMs - _lastUpdateAtMs).clamp(60, 280)
        : _kHighlightTransitionDuration.inMilliseconds;
    _lastUpdateAtMs = nowMs;
    _controller.duration = Duration(milliseconds: dtMs);
    _controller.animateTo(target, curve: Curves.linear);
  }

  void _onLineChanged() {
    _renderedLine = widget.line;
    _pendingReset = true;
    _wordWidths = null;
    _wordWidthsStyle = null;
    _scheduleLineReset();
  }

  void _scheduleLineReset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_renderedLine, widget.line)) return;
      _controller.stop();
      _controller.value = 0;
      _lastUpdateAtMs = 0;
      _lastProgress = Duration.zero;
      _pendingReset = false;
      _updateTarget();
    });
  }

  TextPainter _resolveTextPainter(double maxWidth, Color baseColor) {
    final text = widget.line.text;
    final style = widget.style.copyWith(color: baseColor);
    final ellipsis = widget.overflow == TextOverflow.ellipsis ? '…' : null;
    final painter = _textPainter;
    if (painter != null &&
        _painterText == text &&
        _painterStyle == style &&
        _painterMaxWidth == maxWidth &&
        _painterAlign == widget.textAlign &&
        _painterDirection == widget.textDirection &&
        _painterMaxLines == widget.maxLines &&
        _painterEllipsis == ellipsis) {
      return painter;
    }
    final next = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: widget.textAlign,
      textDirection: widget.textDirection,
      maxLines: widget.maxLines,
      ellipsis: ellipsis,
    )..layout(maxWidth: maxWidth);
    _textPainter = next;
    _painterText = text;
    _painterStyle = style;
    _painterMaxWidth = maxWidth;
    _painterAlign = widget.textAlign;
    _painterDirection = widget.textDirection;
    _painterMaxLines = widget.maxLines;
    _painterEllipsis = ellipsis;
    return next;
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = LyricsService.instance;
    final explicitBase = widget.baseColor;
    final explicitHighlight = widget.highlightColor;
    if (explicitBase != null && explicitHighlight != null) {
      return _buildContent(context, explicitBase, explicitHighlight);
    }
    // 颜色变化只触发重建，不在 build 期同步读 notifier（避免信号同步镜像
    // 触发循环 markNeedsBuild → “setState called during build” 级联崩溃）。
    // builder 里延迟到帧后回调再读颜色，首帧用兜底值，帧后立即校正。
    return ListenableBuilder(
      listenable: Listenable.merge([
        lyrics.viewInactiveColor,
        lyrics.viewHighlightColor,
      ]),
      builder: (context, _) {
        final inactiveValue = lyrics.viewInactiveColor.value;
        final base =
            explicitBase ??
            LyricsViewColors.karaokeBaseColor(
              context,
              inactiveColor: inactiveValue == null
                  ? null
                  : Color(inactiveValue),
            );
        final highlight =
            explicitHighlight ??
            LyricsViewColors.customColorOrDefault(
              lyrics.viewHighlightColor.value,
              LyricsViewColors.defaultHighlightColor(context),
            );
        return _buildContent(context, base, highlight);
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    Color baseColor,
    Color highlightColor,
  ) {
    if (!identical(_renderedLine, widget.line)) {
      _onLineChanged();
    }
    final text = widget.line.text;
    final hasKaraoke = text.isNotEmpty && _resolveLineWords() != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        final painter = _resolveTextPainter(maxWidth, baseColor);
        _fullWidth = painter.width;
        // 与歌词详情页一致：动画每帧只重建 CustomPaint（painter 持有缓存好的
        // TextPainter，读取最新动画值），不重新布局、不重排 TextPainter。
        return ValueListenableBuilder<double>(
          valueListenable: _controller,
          builder: (context, value, child) {
            final f = (_pendingReset ? 0.0 : value).clamp(0.0, 1.0);
            return CustomPaint(
              size: painter.size,
              painter: KaraokeHighlightPainter(
                painter: painter,
                highlightColor: highlightColor,
                fraction: hasKaraoke ? f : 0.0,
              ),
            );
          },
        );
      },
    );
  }

  double _measureWidth(String text) {
    return (TextPainter(
      text: TextSpan(text: text, style: widget.style),
      textDirection: TextDirection.ltr,
    )..layout()).width;
  }

  void _ensureWordWidths(List<LyricWord> words) {
    final style = widget.style;
    if (_wordWidths != null &&
        _wordWidthsStyle == style &&
        _wordWidths!.length == words.length) {
      return;
    }
    _wordWidths = <double>[];
    _sumWordWidths = 0;
    for (final w in words) {
      final width = _measureWidth(w.text);
      _wordWidths!.add(width);
      _sumWordWidths += width;
    }
    _wordWidthsStyle = style;
  }

  Duration _effectiveEnd() {
    final end = widget.lineEnd;
    if (end != null && end > widget.line.start) return end;
    return widget.line.start + const Duration(seconds: 3);
  }

  List<LyricWord>? _resolveLineWords() {
    final words = widget.line.words;
    if (words != null && words.isNotEmpty) return words;
    final text = widget.line.text;
    final start = widget.line.start;
    final end = _effectiveEnd();
    if (text.isEmpty || end <= start) return null;
    final runes = text.runes.toList();
    if (runes.isEmpty || runes.length > 5000) return null;
    final totalMs = (end - start).inMilliseconds;
    if (totalMs <= 0) return null;
    final result = <LyricWord>[];
    for (var i = 0; i < runes.length; i++) {
      final ch = String.fromCharCode(runes[i]);
      final wordStartMs =
          start.inMilliseconds + ((totalMs * i) ~/ runes.length);
      final wordEndMs = i == runes.length - 1
          ? end.inMilliseconds
          : start.inMilliseconds + ((totalMs * (i + 1)) ~/ runes.length);
      final ws = Duration(milliseconds: wordStartMs);
      final we = Duration(
        milliseconds: wordEndMs <= wordStartMs ? wordStartMs + 1 : wordEndMs,
      );
      result.add(LyricWord(text: ch, start: ws, end: we));
    }
    return result;
  }
}

/// 逐字高亮画板：先以基础色绘制整行，再按 [fraction] 用 srcIn 覆盖高亮色，
/// 边界为硬边（无渐变淡出），与歌词详情页的渲染方式一致。
class KaraokeHighlightPainter extends CustomPainter {
  final TextPainter painter;
  final Color highlightColor;
  final double fraction;

  const KaraokeHighlightPainter({
    required this.painter,
    required this.highlightColor,
    required this.fraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    painter.paint(canvas, Offset.zero);
    final f = fraction.clamp(0.0, 1.0);
    if (f <= 0.0) return;
    final rect = Offset.zero & size;
    canvas.saveLayer(rect, Paint());
    painter.paint(canvas, Offset.zero);
    final highlightRect = Rect.fromLTWH(
      0,
      0,
      f >= 1.0 ? size.width : size.width * f,
      size.height,
    );
    final paint = Paint()
      ..blendMode = BlendMode.srcIn
      ..shader = LinearGradient(
        colors: [highlightColor, highlightColor],
      ).createShader(highlightRect);
    canvas.drawRect(highlightRect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant KaraokeHighlightPainter oldDelegate) {
    return oldDelegate.painter != painter ||
        oldDelegate.highlightColor != highlightColor ||
        oldDelegate.fraction != fraction;
  }
}
