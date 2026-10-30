import 'dart:math' as math;

import '../../../app/state/settings_bottom_island_state.dart';

/// Geometry shared by the future overlay host and page content padding.
/// Heights exclude system insets until [occupiedHeight] is calculated.
class BottomIslandLayout {
  static const List<int> _allDestinations = [0, 1, 2, 3, 4];
  static const List<int> _compactDestinations = [0, 1, 3, 4];

  final BottomIslandStyle effectiveStyle;
  final List<int> navigationIndices;
  final bool playerVisible;
  final bool controlsEnabled;
  final double navigationHeight;
  final double playerHeight;
  final double topExtension;
  final double contentHeight;
  final double bottomGap;
  final double bottomInset;

  const BottomIslandLayout._({
    required this.effectiveStyle,
    required this.navigationIndices,
    required this.playerVisible,
    required this.controlsEnabled,
    required this.navigationHeight,
    required this.playerHeight,
    required this.topExtension,
    required this.contentHeight,
    required this.bottomGap,
    required this.bottomInset,
  });

  double get occupiedHeight =>
      contentHeight == 0 ? 0 : contentHeight + bottomGap + bottomInset;

  double scrollPadding({double contentGap = 24}) =>
      occupiedHeight + _nonNegative(contentGap, 'contentGap');

  /// Reserve both shapes during a style transition, without double-counting
  /// either the consumed safe area or the page's content gap.
  double transitionOccupiedHeight(BottomIslandLayout previous) =>
      math.max(occupiedHeight, previous.occupiedHeight);

  factory BottomIslandLayout.resolve({
    required BottomIslandStyle style,
    required double width,
    double textScale = 1,
    double bottomInset = 0,
    bool safeAreaConsumed = false,
    bool hasNavigation = true,
    bool showPlayer = true,
    bool hasSong = true,
    bool isVisible = true,
    bool keyboardVisible = false,
    bool keepVisibleWithKeyboard = false,
    bool isLargeLayout = false,
    bool useLiquidGlass = false,
  }) {
    _nonNegative(width, 'width');
    _nonNegative(bottomInset, 'bottomInset');
    if (!textScale.isFinite || textScale <= 0) {
      throw ArgumentError.value(textScale, 'textScale', 'Must be positive');
    }

    final hidden =
        !isVisible ||
        isLargeLayout ||
        width == 0 ||
        (keyboardVisible && !keepVisibleWithKeyboard);
    var effectiveStyle = style;
    // Four 48dp navigation targets, a 48dp play target, a 48dp disc,
    // 24dp internal spacing, and 32dp outer margins leave no title at 344dp.
    if (style == BottomIslandStyle.c1 && (width < 344 || textScale > 1.3)) {
      effectiveStyle = BottomIslandStyle.c3;
    }

    final navigation = hasNavigation && !hidden;
    final player = showPlayer && !hidden;
    final indices = !navigation
        ? const <int>[]
        : switch (effectiveStyle) {
            BottomIslandStyle.c1 ||
            BottomIslandStyle.c2 => _compactDestinations,
            BottomIslandStyle.legacy ||
            BottomIslandStyle.c3 => _allDestinations,
          };
    final scale = math.max(1.0, textScale);
    final navHeight = !navigation
        ? 0.0
        : effectiveStyle == BottomIslandStyle.legacy
        ? (useLiquidGlass ? 84.0 : 64.0)
        : math.max(56.0, 32 + 16 * scale);
    final playerHeight = !player
        ? 0.0
        : effectiveStyle == BottomIslandStyle.legacy
        ? 70.0
        : math.max(48.0, 16 + 32 * scale);

    double contentHeight;
    var topExtension = 0.0;
    if (effectiveStyle == BottomIslandStyle.legacy) {
      contentHeight = navHeight + playerHeight;
    } else if (!navigation || !player) {
      contentHeight = math.max(navHeight, playerHeight);
    } else {
      switch (effectiveStyle) {
        case BottomIslandStyle.c1:
          contentHeight = 62;
        case BottomIslandStyle.c2:
          // The title/play row is above the protruding disc. The host must
          // reserve this full envelope, while its empty side regions pass hits.
          topExtension = playerHeight + 8 + 16;
          contentHeight = math.max(64, navHeight) + topExtension;
        case BottomIslandStyle.c3:
          contentHeight = playerHeight + 8 + navHeight;
        case BottomIslandStyle.legacy:
          throw StateError('Legacy layout was already resolved');
      }
    }

    return BottomIslandLayout._(
      effectiveStyle: effectiveStyle,
      navigationIndices: indices,
      playerVisible: player,
      controlsEnabled: player && hasSong,
      navigationHeight: navHeight,
      playerHeight: playerHeight,
      topExtension: topExtension,
      contentHeight: contentHeight,
      bottomGap:
          contentHeight == 0 || effectiveStyle == BottomIslandStyle.legacy
          ? 0
          : navigation && effectiveStyle == BottomIslandStyle.c3
          ? 0
          : 12,
      bottomInset: safeAreaConsumed ? 0 : bottomInset,
    );
  }

  static double _nonNegative(double value, String name) {
    if (!value.isFinite || value < 0) {
      throw ArgumentError.value(value, name, 'Must be finite and non-negative');
    }
    return value;
  }
}
