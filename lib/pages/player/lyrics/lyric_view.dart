import 'package:flutter/material.dart';
import 'package:flutter_lyric/core/lyric_controller.dart';
import 'package:flutter_lyric/core/lyric_style.dart';
import 'package:flutter_lyric/widgets/lyric_view.dart' as fl;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import '../../../app/services/lyrics/lyrics_service.dart';
import '../../../app/services/lyrics/lyrics_view_colors.dart';
import '../../../app/services/player_service.dart';
import '../../../app/state/settings_state.dart';
import '../../../components/index.dart';
import '../widgets/player_bottom_panel.dart';
import 'widgets/lyrics_actions_bar.dart';
import 'widgets/lyrics_drag_to_seek.dart';

class PlayerLyricsView extends StatefulWidget {
  /// 是否在歌词页底部显示播放控件与操作栏（播放页内歌词页开启，
  /// 平板横屏右栏、独立歌词页保持关闭）。
  final bool showControls;

  /// 上下边缘渐隐遮罩。
  ///
  /// 歌词在区域内上下滚动出界时会被硬截断，开启后上下边缘叠加线性渐隐，
  /// 让歌词淡出而非被直接裁掉。
  final bool fadeEdges;

  const PlayerLyricsView({
    super.key,
    this.showControls = false,
    this.fadeEdges = false,
  });

  @override
  State<PlayerLyricsView> createState() => _PlayerLyricsViewState();
}

class _PlayerLyricsViewState extends State<PlayerLyricsView> with SignalsMixin {
  static const String _prefsFontSize = 'lyrics_view_font_size';
  static const String _prefsActiveFontSize = 'lyrics_view_active_font_size';
  static const String _prefsLineGap = 'lyrics_view_line_gap';
  static const String _prefsAlignment = 'lyrics_view_alignment';
  static const String _prefsShowTranslation = 'lyrics_view_show_translation';
  static const String _prefsDragToSeek = 'lyrics_view_drag_to_seek';
  static const String _prefsDragLyrics = 'lyrics_view_drag_lyrics';
  static const String _prefsDragSeek = 'lyrics_view_drag_seek';
  static const String _prefsForceKaraoke = 'lyrics_view_force_karaoke';
  static const String _prefsInactiveColor = 'lyrics_view_inactive_color';
  static const String _prefsActiveColor = 'lyrics_view_active_color';
  static const String _prefsHighlightColor = 'lyrics_view_highlight_color';
  static const String _prefsMiniEnabled = 'mini_lyrics_enabled';
  static const String _prefsMiniAlignment = 'mini_lyrics_alignment';

  late final _showTranslation = createSignal(true);
  late final _dragLyrics = createSignal(true);
  late final _dragSeek = createSignal(true);
  late final _forceKaraoke = createSignal(false);
  late final _miniEnabled = createSignal(true);
  late final _miniAlignment = createSignal('center');
  late final _fontSize = createSignal(16.0);
  late final _activeFontSize = createSignal(20.0);
  late final _lineGap = createSignal(14.0);
  late final _alignment = createSignal('center');
  late final _inactiveColorValue = createSignal<int?>(null);
  late final _activeColorValue = createSignal<int?>(null);
  late final _highlightColorValue = createSignal<int?>(null);
  late final _selectionCentered = createSignal(false);
  VoidCallback? _unregisterResumeSelectedLine;
  VoidCallback? _unregisterStopSelection;
  bool _tapSeekEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    final controller = LyricsService.instance.controller;
    controller.selectedIndexNotifier.addListener(_onSelectionIndexChange);
    controller.isSelectingNotifier.addListener(_onSelectingChange);
    _unregisterResumeSelectedLine = controller.registerEvent(
      LyricEvent.resumeSelectedLine,
      (_) {
        if (!mounted) return;
        _selectionCentered.value = true;
      },
    );
    _unregisterStopSelection = controller.registerEvent(
      LyricEvent.stopSelection,
      (_) {
        if (!mounted) return;
        _selectionCentered.value = false;
      },
    );
  }

  @override
  void dispose() {
    final controller = LyricsService.instance.controller;
    controller.selectedIndexNotifier.removeListener(_onSelectionIndexChange);
    controller.isSelectingNotifier.removeListener(_onSelectingChange);
    _unregisterResumeSelectedLine?.call();
    _unregisterStopSelection?.call();
    // 释放全局拖动选中状态：LyricController 是全局单例，若歌词页销毁时
    // 仍处于拖动选中（isSelecting=true / selectedIndex 指向拖到的行），
    // 残留状态会传染给其它共享 controller 的歌词预览（如封面页底栏迷你
    // 歌词、海报预览），表现为「左滑回封面页时左边也被选中」。
    controller.stopSelection();
    super.dispose();
  }

  void _onSelectionIndexChange() {
    _selectionCentered.value = false;
  }

  void _onSelectingChange() {
    if (!LyricsService.instance.controller.isSelectingNotifier.value) {
      _selectionCentered.value = false;
    }
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    _showTranslation.value = prefs.getBool(_prefsShowTranslation) ?? true;
    final legacyDrag = prefs.getBool(_prefsDragToSeek);
    _dragLyrics.value = prefs.getBool(_prefsDragLyrics) ?? legacyDrag ?? true;
    _dragSeek.value = prefs.getBool(_prefsDragSeek) ?? legacyDrag ?? true;
    _forceKaraoke.value = prefs.getBool(_prefsForceKaraoke) ?? false;
    _miniEnabled.value = prefs.getBool(_prefsMiniEnabled) ?? true;
    _miniAlignment.value = prefs.getString(_prefsMiniAlignment) ?? 'center';
    _fontSize.value = prefs.getDouble(_prefsFontSize) ?? 16;
    _activeFontSize.value = prefs.getDouble(_prefsActiveFontSize) ?? 20;
    _lineGap.value = prefs.getDouble(_prefsLineGap) ?? 14;
    _alignment.value = prefs.getString(_prefsAlignment) ?? 'center';
    _inactiveColorValue.value = prefs.getInt(_prefsInactiveColor);
    _activeColorValue.value = prefs.getInt(_prefsActiveColor);
    _highlightColorValue.value = prefs.getInt(_prefsHighlightColor);
  }

  Future<void> _setPrefBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
    LyricsService.instance.notifyViewSettingsChanged();
  }

  Future<void> _setPrefDouble(String key, double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(key, value);
    LyricsService.instance.notifyViewSettingsChanged();
  }

  Future<void> _setPrefString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
    LyricsService.instance.notifyViewSettingsChanged();
  }

  Future<void> _setPrefColor(String key, Color? color) async {
    final prefs = await SharedPreferences.getInstance();
    if (color == null) {
      await prefs.remove(key);
    } else {
      await prefs.setInt(key, color.toARGB32());
    }
    LyricsService.instance.notifyViewSettingsChanged();
  }

  Future<void> _openColorPicker({
    required String title,
    required Color initialColor,
    required ValueChanged<Color?> onSelected,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return _LyricsColorPickerDialog(
          title: title,
          initialColor: initialColor,
          onSelected: onSelected,
        );
      },
    );
  }

  TextAlign _lineTextAlign() {
    switch (_alignment.value) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      default:
        return TextAlign.center;
    }
  }

  CrossAxisAlignment _contentAlignment() {
    switch (_alignment.value) {
      case 'left':
        return CrossAxisAlignment.start;
      case 'right':
        return CrossAxisAlignment.end;
      default:
        return CrossAxisAlignment.center;
    }
  }

  void _openLyricsSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          snap: true,
          builder: (context, scrollController) {
            return Watch.builder(
              builder: (context) {
                final fontSize = _fontSize.value;
                final activeFontSize = _activeFontSize.value;
                final lineGap = _lineGap.value;
                final alignment = _alignment.value;
                final dragLyrics = _dragLyrics.value;
                final dragSeek = _dragSeek.value;
                final forceKaraoke = _forceKaraoke.value;
                final miniEnabled = _miniEnabled.value;
                final miniAlignment = _miniAlignment.value;
                final inactiveColorValue = _inactiveColorValue.value;
                final activeColorValue = _activeColorValue.value;
                final highlightColorValue = _highlightColorValue.value;
                return AppSheetPanel(
                  title: '歌词设置',
                  expand: true,
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppSettingSection(
                          title: '样式',
                          showDividers: false,
                          children: [
                            LabeledSlider(
                              title: '字号',
                              value: fontSize,
                              min: 14.0,
                              max: 32.0,
                              divisions: 9,
                              valueText: fontSize.toStringAsFixed(0),
                              onChanged: (v) => _fontSize.value = v,
                              onChangeEnd: (v) =>
                                  _setPrefDouble(_prefsFontSize, v),
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                12,
                              ),
                            ),
                            LabeledSlider(
                              title: '播放字号',
                              value: activeFontSize,
                              min: 16.0,
                              max: 48.0,
                              divisions: 16,
                              valueText: activeFontSize.toStringAsFixed(0),
                              onChanged: (v) => _activeFontSize.value = v,
                              onChangeEnd: (v) =>
                                  _setPrefDouble(_prefsActiveFontSize, v),
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                12,
                              ),
                            ),
                            LabeledSlider(
                              title: '行距',
                              value: lineGap,
                              min: 8.0,
                              max: 32.0,
                              divisions: 12,
                              valueText: lineGap.toStringAsFixed(0),
                              onChanged: (v) => _lineGap.value = v,
                              onChangeEnd: (v) =>
                                  _setPrefDouble(_prefsLineGap, v),
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                12,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                              child: SizedBox(
                                width: double.infinity,
                                child: SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(
                                      value: 'left',
                                      label: Text('居左'),
                                      icon: Icon(Icons.format_align_left),
                                    ),
                                    ButtonSegment(
                                      value: 'center',
                                      label: Text('居中'),
                                      icon: Icon(Icons.format_align_center),
                                    ),
                                    ButtonSegment(
                                      value: 'right',
                                      label: Text('居右'),
                                      icon: Icon(Icons.format_align_right),
                                    ),
                                  ],
                                  selected: {alignment},
                                  onSelectionChanged: (selection) {
                                    final v = selection.first;
                                    _alignment.value = v;
                                    _setPrefString(_prefsAlignment, v);
                                  },
                                  showSelectedIcon: false,
                                ),
                              ),
                            ),
                            _LyricsColorSettingTile(
                              title: '普通歌词颜色',
                              color: inactiveColorValue == null
                                  ? null
                                  : Color(inactiveColorValue),
                              onTap: () {
                                final fallback =
                                    LyricsViewColors.defaultInactiveColor(
                                      context,
                                    );
                                _openColorPicker(
                                  title: '普通歌词颜色',
                                  initialColor: inactiveColorValue == null
                                      ? fallback
                                      : Color(inactiveColorValue),
                                  onSelected: (color) {
                                    _inactiveColorValue.value = color
                                        ?.toARGB32();
                                    _setPrefColor(_prefsInactiveColor, color);
                                  },
                                );
                              },
                              onReset: inactiveColorValue == null
                                  ? null
                                  : () {
                                      _inactiveColorValue.value = null;
                                      _setPrefColor(_prefsInactiveColor, null);
                                    },
                            ),
                            _LyricsColorSettingTile(
                              title: '当前歌词颜色',
                              color: activeColorValue == null
                                  ? null
                                  : Color(activeColorValue),
                              onTap: () {
                                final fallback =
                                    LyricsViewColors.defaultActiveColor(
                                      context,
                                    );
                                _openColorPicker(
                                  title: '当前歌词颜色',
                                  initialColor: activeColorValue == null
                                      ? fallback
                                      : Color(activeColorValue),
                                  onSelected: (color) {
                                    _activeColorValue.value = color?.toARGB32();
                                    _setPrefColor(_prefsActiveColor, color);
                                  },
                                );
                              },
                              onReset: activeColorValue == null
                                  ? null
                                  : () {
                                      _activeColorValue.value = null;
                                      _setPrefColor(_prefsActiveColor, null);
                                    },
                            ),
                            _LyricsColorSettingTile(
                              title: '逐字高亮颜色',
                              color: highlightColorValue == null
                                  ? null
                                  : Color(highlightColorValue),
                              onTap: () {
                                final fallback =
                                    LyricsViewColors.defaultHighlightColor(
                                      context,
                                    );
                                _openColorPicker(
                                  title: '逐字高亮颜色',
                                  initialColor: highlightColorValue == null
                                      ? fallback
                                      : Color(highlightColorValue),
                                  onSelected: (color) {
                                    _highlightColorValue.value = color
                                        ?.toARGB32();
                                    _setPrefColor(_prefsHighlightColor, color);
                                  },
                                );
                              },
                              onReset: highlightColorValue == null
                                  ? null
                                  : () {
                                      _highlightColorValue.value = null;
                                      _setPrefColor(_prefsHighlightColor, null);
                                    },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        AppSettingSection(
                          title: '交互',
                          showDividers: false,
                          children: [
                            AppSettingSwitchTile(
                              title: '拖动歌词',
                              value: dragLyrics,
                              onChanged: (v) {
                                _dragLyrics.value = v;
                                _setPrefBool(_prefsDragLyrics, v);
                              },
                            ),
                            if (dragLyrics)
                              AppSettingSwitchTile(
                                title: '拖动调节进度',
                                value: dragSeek,
                                onChanged: (v) {
                                  _dragSeek.value = v;
                                  _setPrefBool(_prefsDragSeek, v);
                                },
                              ),
                            AppSettingSwitchTile(
                              title: '强制逐字',
                              subtitle: '对非逐字歌词进行逐字处理',
                              value: forceKaraoke,
                              onChanged: (v) async {
                                _forceKaraoke.value = v;
                                await _setPrefBool(_prefsForceKaraoke, v);
                                await LyricsService.instance.refreshSettings();
                                LyricsService.instance.reloadCurrentSong();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        AppSettingSection(
                          title: '三行歌词',
                          showDividers: false,
                          children: [
                            AppSettingSwitchTile(
                              title: '显示三行歌词',
                              value: miniEnabled,
                              onChanged: (v) {
                                _miniEnabled.value = v;
                                _setPrefBool(_prefsMiniEnabled, v);
                              },
                            ),
                            if (miniEnabled)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  12,
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: SegmentedButton<String>(
                                    segments: const [
                                      ButtonSegment(
                                        value: 'left',
                                        label: Text('居左'),
                                        icon: Icon(Icons.format_align_left),
                                      ),
                                      ButtonSegment(
                                        value: 'center',
                                        label: Text('居中'),
                                        icon: Icon(Icons.format_align_center),
                                      ),
                                      ButtonSegment(
                                        value: 'right',
                                        label: Text('居右'),
                                        icon: Icon(Icons.format_align_right),
                                      ),
                                    ],
                                    selected: {miniAlignment},
                                    onSelectionChanged: (selection) {
                                      final v = selection.first;
                                      _miniAlignment.value = v;
                                      _setPrefString(_prefsMiniAlignment, v);
                                    },
                                    showSelectedIcon: false,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onSurface = scheme.onSurface;
    final player = PlayerService.instance;
    final lyrics = LyricsService.instance;

    return Watch.builder(
      builder: (context) {
        final dragLyrics = _dragLyrics.value;
        final dragSeek = _dragSeek.value;
        final showTranslation = _showTranslation.value;
        final forceKaraoke = _forceKaraoke.value;
        // TV 端（3 米外观看）按比例放大歌词字号：默认 16/20 → 22/28，
        // 行距同步放大。滑块仍显示原始数值（用户设置不变，仅渲染缩放）。
        final isTv = AppLayoutSettings.tvMode.value;
        final fontSizeScale = isTv ? 1.4 : 1.0;
        final rawFontSize = _fontSize.value;
        final rawActiveFontSize = _activeFontSize.value;
        final rawLineGap = _lineGap.value;
        final fontSize = rawFontSize * fontSizeScale;
        final activeFontSize = rawActiveFontSize * fontSizeScale;
        final lineGap = rawLineGap * fontSizeScale;
        final snap = lyrics.snapshotSignal.value;
        final isPlaying = player.isPlayingSignal.value;
        final model = lyrics.lyricModelSignal.value;
        final selecting = lyrics.isSelectingSignal.value;
        final centered = _selectionCentered.value;
        final index = lyrics.selectedIndexSignal.value;
        if (dragSeek != _tapSeekEnabled) {
          _tapSeekEnabled = dragSeek;
          if (dragSeek) {
            lyrics.controller.setOnTapLineCallback((pos) {
              lyrics.controller.stopSelection();
              player.seek(pos);
            });
          } else {
            lyrics.controller.cancelOnTapLineCallback();
          }
        }
        final hasTranslation =
            model?.lines.any(
              (line) => (line.translation ?? '').trim().isNotEmpty,
            ) ??
            false;

        return Column(
          children: [
            Expanded(
              // 上下边缘渐隐遮罩：fadeEdges 关闭时全白（dstIn 无效果），
              // 开启时上下各约 22% 高度淡出，歌词滑出边界不被硬截断。
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.22, 0.78, 1.0],
                  colors: widget.fadeEdges
                      ? const [
                          Colors.transparent,
                          Colors.white,
                          Colors.white,
                          Colors.transparent,
                        ]
                      : const [
                          Colors.white,
                          Colors.white,
                          Colors.white,
                          Colors.white,
                        ],
                ).createShader(rect),
                child: LyricsDragToSeek(
                    enabled: dragLyrics,
                    player: player,
                    lyrics: lyrics,
                    child: () {
                      final hasLines = model?.lines.isNotEmpty ?? false;
                      if (snap.status == LyricsLoadStatus.loading &&
                          !hasLines) {
                        return const SizedBox.shrink();
                      }
                      if (!hasLines) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '暂无歌词',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: onSurface.withValues(alpha: 0.8),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '纯音乐或未匹配到歌词',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: onSurface.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      final hasKaraokeWords = model!.lines.any(
                        (line) => line.words?.isNotEmpty ?? false,
                      );
                      final karaokeMode = forceKaraoke || hasKaraokeWords;
                      final inactiveColor =
                          LyricsViewColors.customColorOrDefault(
                            _inactiveColorValue.value,
                            LyricsViewColors.defaultInactiveColor(context),
                          );
                      final activeColor = LyricsViewColors.customColorOrDefault(
                        _activeColorValue.value,
                        LyricsViewColors.defaultActiveColor(context),
                      );
                      final highlightColor =
                          LyricsViewColors.customColorOrDefault(
                            _highlightColorValue.value,
                            LyricsViewColors.defaultHighlightColor(context),
                          );
                      final isLight = theme.brightness == Brightness.light;
                      final karaokeBaseColor =
                          LyricsViewColors.karaokeBaseColor(
                            context,
                            inactiveColor: inactiveColor,
                          );

                      final translationStyle = showTranslation
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
                            );

                      final style = LyricStyle(
                        textStyle: TextStyle(
                          color: inactiveColor,
                          fontSize: fontSize,
                          height: 1.3,
                        ),
                        activeStyle: TextStyle(
                          color: karaokeMode ? karaokeBaseColor : activeColor,
                          fontSize: activeFontSize,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                        translationStyle: translationStyle,
                        translationActiveColor: showTranslation
                            ? onSurface.withValues(alpha: 0.9)
                            : Colors.transparent,
                        lineTextAlign: _lineTextAlign(),
                        contentAlignment: _contentAlignment(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        lineGap: lineGap,
                        translationLineGap: showTranslation ? 8 : 0,
                        selectionAnchorPosition: 0.5,
                        activeAnchorPosition: 0.5,
                        selectionAlignment: MainAxisAlignment.center,
                        activeAlignment: MainAxisAlignment.center,
                        scrollDuration: const Duration(milliseconds: 380),
                        scrollCurve: Curves.easeOutCubic,
                        selectedColor: activeColor,
                        selectedTranslationColor: onSurface.withValues(
                          alpha: 0.9,
                        ),
                        selectionAutoResumeDuration: const Duration(
                          milliseconds: 200,
                        ),
                        activeAutoResumeDuration: isPlaying
                            ? const Duration(seconds: 3)
                            : const Duration(days: 365),
                        disableTouchEvent: !dragLyrics,
                        enableSwitchAnimation: false,
                        activeHighlightGradient: karaokeMode
                            ? LinearGradient(
                                colors: [
                                  highlightColor.withValues(alpha: 1.0),
                                  highlightColor.withValues(alpha: 1.0),
                                ],
                              )
                            : null,
                        activeHighlightExtraFadeWidth: 0,
                      );
                      return Stack(
                        children: [
                          fl.LyricView(
                            controller: lyrics.controller,
                            style: style,
                          ),
                          if (!dragLyrics || !selecting)
                            const SizedBox.shrink()
                          else
                            Align(
                              alignment: Alignment.center,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: SizedBox(
                                  height: 44,
                                  child: () {
                                    final m = model;
                                    final showDetails =
                                        index >= 0 && index < m.lines.length;
                                    final timeText = showDetails
                                        ? "${m.lines[index].start.inMinutes.toString().padLeft(2, '0')}:${(m.lines[index].start.inSeconds % 60).toString().padLeft(2, '0')}"
                                        : '';
                                    return Row(
                                      children: [
                                        if (showDetails)
                                          Text(
                                            timeText,
                                            style: TextStyle(
                                              color: activeColor,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        if (showDetails)
                                          const SizedBox(width: 8),
                                        Expanded(
                                          child: Container(
                                            height: 1,
                                            color: centered
                                                ? Colors.transparent
                                                : onSurface.withValues(
                                                    alpha: 0.25,
                                                  ),
                                          ),
                                        ),
                                        if (showDetails)
                                          const SizedBox(width: 8),
                                        if (showDetails && dragSeek)
                                          GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () {
                                              if (index < 0 ||
                                                  index >= m.lines.length) {
                                                return;
                                              }
                                              final start =
                                                  m.lines[index].start;
                                              lyrics.controller.stopSelection();
                                              player.seek(start);
                                            },
                                            child: Icon(
                                              Icons.play_arrow_rounded,
                                              size: 32,
                                              color: activeColor,
                                            ),
                                          ),
                                      ],
                                    );
                                  }(),
                                ),
                              ),
                            ),
                        ],
                      );
                    }(),
                  ),
                ),
              ),
            // 词/译 切换栏
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
              child: LyricsActionsBar(
                hasTranslation: hasTranslation,
                showTranslation: showTranslation,
                onOpenSettings: _openLyricsSettingsSheet,
                onToggleTranslation: () {
                  _showTranslation.value = !showTranslation;
                  _setPrefBool(_prefsShowTranslation, _showTranslation.value);
                },
                color: onSurface,
              ),
            ),
            // 播放控件 + 底部操作栏（可选，播放页内歌词页开启）
            if (widget.showControls) ..._buildControlsArea(context),
          ],
        );
      },
    );
  }

  List<Widget> _buildControlsArea(BuildContext context) {
    final player = PlayerService.instance;
    final stylePreset = PlayerStyleSettings.stylePreset.value;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final bottomSpacing = bottomInset > 20 ? bottomInset + 16.0 : 24.0;
    final Widget controls;
    if (stylePreset == PlayerStylePreset.poster) {
      // 海报模式：与封面页海报布局一致（模式 + 上一首/播放/下一首 + 更多）
      controls = PosterControls(player: player);
    } else {
      // 经典模式：播放控件 + 底部操作栏
      controls = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlayerControls(player: player, stylePreset: stylePreset),
          const SizedBox(height: 20),
          BottomActions(player: player, stylePreset: stylePreset),
        ],
      );
    }
    return [
      controls,
      SizedBox(height: bottomSpacing),
    ];
  }
}

class _LyricsColorSettingTile extends StatelessWidget {
  final String title;
  final Color? color;
  final VoidCallback onTap;
  final VoidCallback? onReset;

  const _LyricsColorSettingTile({
    required this.title,
    required this.color,
    required this.onTap,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text(title),
      subtitle: Text(color == null ? '跟随默认样式' : '自定义颜色'),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color ?? scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: color == null
                ? Icon(
                    Icons.auto_awesome,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  )
                : null,
          ),
          if (onReset != null) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: '恢复默认',
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ],
        ],
      ),
    );
  }
}

class _LyricsColorPickerDialog extends StatefulWidget {
  final String title;
  final Color initialColor;
  final ValueChanged<Color?> onSelected;

  const _LyricsColorPickerDialog({
    required this.title,
    required this.initialColor,
    required this.onSelected,
  });

  @override
  State<_LyricsColorPickerDialog> createState() =>
      _LyricsColorPickerDialogState();
}

class _LyricsColorPickerDialogState extends State<_LyricsColorPickerDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
  }

  void _updateSaturationValue(Offset localPosition, double size) {
    final dx = localPosition.dx.clamp(0.0, size);
    final dy = localPosition.dy.clamp(0.0, size);
    setState(() {
      _hsv = _hsv
          .withSaturation((dx / size).clamp(0.0, 1.0))
          .withValue((1 - dy / size).clamp(0.0, 1.0));
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _hsv.toColor();
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: preview,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final size = constraints.maxWidth;
                  return GestureDetector(
                    onPanDown: (details) =>
                        _updateSaturationValue(details.localPosition, size),
                    onPanUpdate: (details) =>
                        _updateSaturationValue(details.localPosition, size),
                    child: Stack(
                      children: [
                        SizedBox(
                          width: size,
                          height: size,
                          child: CustomPaint(
                            painter: _LyricsSaturationValuePainter(
                              hue: _hsv.hue,
                            ),
                          ),
                        ),
                        Positioned(
                          left: _hsv.saturation * size - 10,
                          top: (1 - _hsv.value) * size - 10,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.onSurface,
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.2),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _LyricsHueSlider(
                value: _hsv.hue,
                onChanged: (value) {
                  setState(() {
                    _hsv = _hsv.withHue(value);
                  });
                },
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () {
                      widget.onSelected(null);
                      Navigator.pop(context);
                    },
                    child: const Text('默认'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () {
                      widget.onSelected(preview);
                      Navigator.pop(context);
                    },
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsSaturationValuePainter extends CustomPainter {
  final double hue;

  _LyricsSaturationValuePainter({required this.hue});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final baseColor = HSVColor.fromAHSV(1, hue, 1, 1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [Colors.white, baseColor],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _LyricsSaturationValuePainter oldDelegate) {
    return oldDelegate.hue != hue;
  }
}

class _LyricsHueSlider extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _LyricsHueSlider({required this.value, required this.onChanged});

  @override
  State<_LyricsHueSlider> createState() => _LyricsHueSliderState();
}

class _LyricsHueSliderState extends State<_LyricsHueSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayValue = _dragValue ?? widget.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanDown: (details) => _updateValue(details.localPosition.dx, width),
          onPanUpdate: (details) =>
              _updateValue(details.localPosition.dx, width),
          onPanEnd: (_) => setState(() => _dragValue = null),
          child: SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      colors: [
                        Color(0xFFFF0000),
                        Color(0xFFFFFF00),
                        Color(0xFF00FF00),
                        Color(0xFF00FFFF),
                        Color(0xFF0000FF),
                        Color(0xFFFF00FF),
                        Color(0xFFFF0000),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: (displayValue / 360 * width) - 10,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: HSVColor.fromAHSV(1, displayValue, 1, 1).toColor(),
                      border: Border.all(color: scheme.onSurface, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _updateValue(double dx, double width) {
    final clamped = dx.clamp(0.0, width);
    final next = (clamped / width * 360).clamp(0.0, 360.0);
    setState(() {
      _dragValue = next;
    });
    widget.onChanged(next);
  }
}
