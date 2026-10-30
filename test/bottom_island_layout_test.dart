import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/settings_bottom_island_state.dart';
import 'package:feiniu_music/components/layout/bottom_island/bottom_island_layout.dart';

void main() {
  for (final style in BottomIslandStyle.values) {
    test('${style.name} preserves destination indices', () {
      final layout = BottomIslandLayout.resolve(style: style, width: 390);
      expect(
        layout.navigationIndices,
        style == BottomIslandStyle.c1 || style == BottomIslandStyle.c2
            ? [0, 1, 3, 4]
            : [0, 1, 2, 3, 4],
      );
      expect(() => layout.navigationIndices.add(5), throwsUnsupportedError);
    });
  }

  test('C1 and C3 have distinct occupied envelopes', () {
    final c1 = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c1,
      width: 390,
      bottomInset: 34,
    );
    final c3 = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c3,
      width: 390,
      bottomInset: 34,
    );
    expect(c1.contentHeight, 62);
    expect(c1.occupiedHeight, 62 + 12 + 34);
    expect(c3.contentHeight, 48 + 8 + 56);
    expect(c3.occupiedHeight, 48 + 8 + 56 + 34);
    expect(c3.scrollPadding(), c3.occupiedHeight + 24);
    expect(c1.transitionOccupiedHeight(c3), c3.occupiedHeight);
    expect(c3.transitionOccupiedHeight(c1), c3.occupiedHeight);
  });

  test('C2 reserves only the record protrusion without a title popup', () {
    final c2 = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c2,
      width: 390,
    );
    expect(c2.playerHeight, greaterThanOrEqualTo(48));
    expect(c2.topExtension, 24);
    expect(c2.contentHeight, 88);
    expect(c2.contentHeight, 64 + c2.topExtension);
    expect(c2.occupiedHeight, c2.contentHeight + 12);
  });

  test('safe area is consumed once', () {
    final layout = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c1,
      width: 390,
      bottomInset: 34,
      safeAreaConsumed: true,
    );
    expect(layout.bottomInset, 0);
    expect(layout.occupiedHeight, 62 + 12);
  });

  test(
    'drawer mode has only a player; player suppression keeps navigation',
    () {
      final player = BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
        hasNavigation: false,
      );
      expect(player.navigationIndices, isEmpty);
      expect(player.contentHeight, player.playerHeight);
      expect(player.topExtension, 0);
      final navigation = BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
        showPlayer: false,
      );
      expect(navigation.navigationIndices, [0, 1, 3, 4]);
      expect(navigation.contentHeight, navigation.navigationHeight);
      expect(navigation.playerVisible, isFalse);
      expect(navigation.controlsEnabled, isFalse);
      expect(navigation.topExtension, 0);
    },
  );

  test('no song disables controls without changing layout or navigation', () {
    final empty = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c1,
      width: 390,
      hasSong: false,
    );
    final playing = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c1,
      width: 390,
    );
    expect(empty.playerVisible, isTrue);
    expect(empty.controlsEnabled, isFalse);
    expect(empty.occupiedHeight, playing.occupiedHeight);
    expect(empty.navigationIndices, playing.navigationIndices);
  });

  test('hidden chrome reserves no safe area or overlay gap', () {
    for (final layout in [
      BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
        isVisible: false,
        bottomInset: 34,
      ),
      BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
        isLargeLayout: true,
      ),
      BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
        keyboardVisible: true,
      ),
      BottomIslandLayout.resolve(
        style: BottomIslandStyle.c2,
        width: 390,
        hasNavigation: false,
        showPlayer: false,
      ),
    ]) {
      expect(layout.occupiedHeight, 0);
      expect(layout.scrollPadding(), 24);
      expect(layout.playerVisible, isFalse);
      expect(layout.navigationIndices, isEmpty);
    }
  });

  test('explicit keyboard policy can keep chrome visible', () {
    final layout = BottomIslandLayout.resolve(
      style: BottomIslandStyle.c1,
      width: 390,
      keyboardVisible: true,
      keepVisibleWithKeyboard: true,
    );
    expect(layout.occupiedHeight, greaterThan(0));
  });

  for (final width in [320.0, 360.0, 390.0, 430.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      test('C1 fallback at width=$width scale=$scale is deterministic', () {
        final layout = BottomIslandLayout.resolve(
          style: BottomIslandStyle.c1,
          width: width,
          textScale: scale,
        );
        final expectedFallback = width < 344 || scale > 1.3;
        expect(
          layout.effectiveStyle,
          expectedFallback ? BottomIslandStyle.c3 : BottomIslandStyle.c1,
        );
        expect(layout.playerHeight, greaterThanOrEqualTo(48));
        expect(layout.navigationHeight, greaterThanOrEqualTo(48));
        expect(layout.contentHeight, greaterThanOrEqualTo(layout.playerHeight));
      });
    }
  }

  test('large text preserves sufficient C2 and C3 envelopes', () {
    for (final style in [BottomIslandStyle.c2, BottomIslandStyle.c3]) {
      final normal = BottomIslandLayout.resolve(style: style, width: 390);
      final large = BottomIslandLayout.resolve(
        style: style,
        width: 390,
        textScale: 2,
      );
      expect(large.contentHeight, greaterThanOrEqualTo(normal.contentHeight));
    }
  });

  test('legacy respects glass and solid navigation slots', () {
    for (final glass in [false, true]) {
      final layout = BottomIslandLayout.resolve(
        style: BottomIslandStyle.legacy,
        width: 390,
        useLiquidGlass: glass,
      );
      expect(layout.playerHeight, 70);
      expect(layout.navigationHeight, glass ? 84 : 64);
      expect(layout.occupiedHeight, 70 + (glass ? 84 : 64));
    }
  });

  test(
    'invalid metrics are rejected rather than propagating NaN or infinity',
    () {
      for (final width in [-1.0, double.nan, double.infinity]) {
        expect(
          () => BottomIslandLayout.resolve(
            style: BottomIslandStyle.c1,
            width: width,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => BottomIslandLayout.resolve(
          style: BottomIslandStyle.c1,
          width: 390,
          textScale: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => BottomIslandLayout.resolve(
          style: BottomIslandStyle.c1,
          width: 390,
          bottomInset: -1,
        ),
        throwsArgumentError,
      );
    },
  );
}
