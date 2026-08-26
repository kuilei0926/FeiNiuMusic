import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/components/common/cover_image_cache.dart';

void main() {
  group('coverMemoryCacheDimension', () {
    test('uses logical size multiplied by device pixel ratio', () {
      expect(
        coverMemoryCacheDimension(logicalSize: 48, devicePixelRatio: 2),
        96,
      );
    });

    test('rounds up fractional physical pixels', () {
      expect(
        coverMemoryCacheDimension(logicalSize: 47.5, devicePixelRatio: 2.5),
        119,
      );
    });

    test('caps decoded covers at the canonical source dimension', () {
      expect(
        coverMemoryCacheDimension(logicalSize: 600, devicePixelRatio: 2),
        800,
      );
    });

    test('returns a safe minimum for invalid dimensions', () {
      expect(coverMemoryCacheDimension(logicalSize: 0, devicePixelRatio: 2), 1);
    });
  });
}
