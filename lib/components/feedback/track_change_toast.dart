import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/navigator_key.dart';
import '../../app/state/settings_layout_state.dart';
import '../../app/state/song_state.dart';
import '../common/artwork_widget.dart';
import '../common/playing_bars.dart';
import '../focus/tv_focusable.dart';

/// 切歌通知：应用内弹出「正在播放」卡片（歌名 + 歌手 + 封面 + 手动关闭）。
///
/// - 右上角有手动关闭按钮；TV 模式下整卡成为单一遥控器焦点目标，
///   Enter/确认键即可关闭。
/// - TV / 平板（大屏）自动放大卡片，更醒目。
/// - 到点（配置时长）仍自动淡出；新通知**替换**旧通知，不叠加。
/// - 除关闭按钮外卡片不拦截触摸：空白区域点击穿透到下层页面。
class TrackChangeToast {
  TrackChangeToast._();

  static OverlayEntry? _currentEntry;
  static Timer? _timer;

  /// 展示切歌通知浮层（供有 BuildContext 的场景 / widget 测试）。
  static void show(
    BuildContext context,
    SongEntity song, {
    Duration? duration,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _insert(overlay, song, duration);
  }

  /// 无 BuildContext 时用的全局切歌通知：经根 Navigator 的 Overlay 弹出。
  ///
  /// 用 `appNavigatorKey.currentState?.overlay` 而非 `Overlay.of(context)`
  /// （context 是 Navigator 自身，其 Overlay 是它的后代，向上查找找不到）。
  /// 根 Navigator 尚未就绪时静默丢弃（不崩溃）。
  static void showGlobal(SongEntity song, {Duration? duration}) {
    final navigator = appNavigatorKey.currentState;
    final overlay = navigator?.overlay;
    if (overlay == null) return;
    _insert(overlay, song, duration);
  }

  /// 立即隐藏当前切歌通知。
  static void hide() => _removeCurrent();

  static void _insert(
    OverlayState overlay,
    SongEntity song,
    Duration? duration,
  ) {
    _removeCurrent();

    final effectiveDuration =
        duration ?? Duration(milliseconds: _defaultDurationMs);

    final entry = OverlayEntry(
      builder: (_) => _TrackChangeToastEntry(
        song: song,
        duration: effectiveDuration,
        onDismiss: _removeCurrent,
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);

    // 兜底计时器：组件内退场动画失败时也能移除。
    _timer = Timer(effectiveDuration + const Duration(milliseconds: 400), () {
      _removeCurrent();
    });
  }

  static int get _defaultDurationMs {
    final ms = AppLayoutSettings.trackChangeToastDurationMs.value;
    return ms.clamp(2000, 10000);
  }

  static void _removeCurrent() {
    _timer?.cancel();
    _timer = null;
    _currentEntry?.remove();
    _currentEntry = null;
  }
}

/// 弹窗卡片本体：可直接 pump 的公开组件（widget 测试用）。
///
/// [onClose] 为空时关闭按钮禁用（仅展示）；TV 模式下整卡聚焦、确认键关闭。
class TrackChangeToastView extends StatelessWidget {
  final SongEntity song;
  final VoidCallback? onClose;
  final bool autofocus;

  const TrackChangeToastView({
    super.key,
    required this.song,
    this.onClose,
    this.autofocus = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isLarge = AppLayoutSettings.tvMode.value ||
        AppLayoutSettings.tabletMode.value;
    final isTv = AppLayoutSettings.tvMode.value;

    // 平板/TV 卡片大小倍数（1.0–2.0，默认 1.5）。仅作用于大屏模式，
    // 手机端尺寸固定不变。
    final scale = isLarge
        ? AppLayoutSettings.trackChangeToastScale.value
        : 1.0;

    final artworkSize = isLarge ? 144.0 * scale : 44.0;
    final maxWidth = isLarge ? 960.0 * scale : 340.0;
    final titleSize = isLarge ? 36.0 * scale : 15.0;
    final artistSize = isLarge ? 24.0 * scale : 12.0;
    final captionSize = isLarge ? 21.0 * scale : 11.0;
    final borderRadius = isLarge ? 36.0 * scale : 16.0;
    final closeIconSize = isLarge ? 40.0 * scale : 20.0;

    final closeButton = IconButton(
      icon: Icon(Icons.close_rounded, size: closeIconSize),
      tooltip: '关闭',
      color: scheme.onSurfaceVariant,
      onPressed: onClose,
      padding: EdgeInsets.all(isLarge ? 14 : 6),
      constraints: const BoxConstraints(),
    );

    // 封面柔光晕：中性深阴影，突出封面但不带彩色。
    final artworkGlow = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(artworkSize * 0.26),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.16),
            blurRadius: isLarge ? 30 : 14,
            offset: Offset(0, isLarge ? 8 : 4),
          ),
        ],
      ),
      child: ArtworkWidget(
        song: song,
        size: artworkSize,
        borderRadius: artworkSize * 0.22,
      ),
    );

    final card = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF262A30) : Colors.white,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: isDark
              ? Colors.white12
              : scheme.outlineVariant.withValues(alpha: 0.4),
          width: isLarge ? 1.6 : 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: isLarge ? 56 : 28,
            offset: Offset(0, isLarge ? 22 : 12),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isLarge ? 26 : 14,
          vertical: isLarge ? 20 : 10,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            artworkGlow,
            SizedBox(width: isLarge ? 24 : 12),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                    // 显式关掉下划线/装饰，防止继承到 Shadcn/主题的 decoration。
                    decoration: TextDecoration.none,
                  ),
                  children: [
                    TextSpan(
                      text: '正在播放',
                      style: TextStyle(
                        fontSize: captionSize,
                        color: scheme.primary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    TextSpan(
                      text: '\n',
                      style: const TextStyle(decoration: TextDecoration.none),
                    ),
                    TextSpan(
                      text: song.title,
                      style: const TextStyle(decoration: TextDecoration.none),
                    ),
                    if (song.artistDisplayName.isNotEmpty) ...[
                      const TextSpan(
                        text: '\n',
                        style: TextStyle(decoration: TextDecoration.none),
                      ),
                      TextSpan(
                        text: song.artistDisplayName,
                        style: TextStyle(
                          fontSize: artistSize,
                          fontWeight: FontWeight.w400,
                          color: scheme.onSurfaceVariant,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SizedBox(width: isLarge ? 20 : 10),
            PlayingBars(color: scheme.primary, animating: true),
            SizedBox(width: isLarge ? 18 : 8),
            closeButton,
          ],
        ),
      ),
    );

    // TV：整卡成为单一遥控器焦点目标，聚焦后按 Enter/确认键关闭；
    // autofocus 让弹窗弹出时焦点直接落在卡片上（不抢走其它常规操作，
    // 关闭后焦点回落），焦点环同时让卡片在 3 米外更醒目。
    if (isTv) {
      return TvFocusable(
        borderRadius: BorderRadius.circular(borderRadius + 6),
        ringWidth: 3,
        autofocus: autofocus,
        onActivate: onClose,
        child: card,
      );
    }
    return card;
  }
}

/// Overlay 条目：顶部定位 + 入场/退场动画 + 到时自动消失 / 手动关闭。
class _TrackChangeToastEntry extends StatefulWidget {
  final SongEntity song;
  final Duration duration;
  final VoidCallback onDismiss;

  const _TrackChangeToastEntry({
    required this.song,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_TrackChangeToastEntry> createState() =>
      _TrackChangeToastEntryState();
}

class _TrackChangeToastEntryState extends State<_TrackChangeToastEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _offset;
  late final Animation<double> _opacity;
  late final Animation<double> _scale;
  Timer? _hideTimer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _offset = Tween<Offset>(
      begin: const Offset(0, -1.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 1.08, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();

    _hideTimer = Timer(widget.duration, () {
      if (!mounted) return;
      _controller.reverse().then((_) => widget.onDismiss());
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _hideTimer?.cancel();
    _controller.reverse().then((_) => widget.onDismiss());
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topInset + 12,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: SlideTransition(
          position: _offset,
          child: FadeTransition(
            opacity: _opacity,
            child: ScaleTransition(
              scale: _scale,
              child: TrackChangeToastView(
                song: widget.song,
                onClose: _close,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
