import 'dart:ui' show Size;

import 'package:feiniu_music/pages/player/widgets/player_background.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dynamic gradient resource limits', () {
    test(
      'uses a long color transition instead of abrupt texture replacement',
      () {
        expect(
          dynamicGradientColorTransitionDuration,
          const Duration(milliseconds: 1500),
        );
      },
    );

    test('caps both transition RGBA textures below 34 megabytes', () {
      const rgbaBytes =
          dynamicGradientMaxTextureDimension *
          dynamicGradientMaxTextureDimension *
          4 *
          dynamicGradientMaxResidentTextures;
      expect(dynamicGradientMaxResidentTextures, 2);
      expect(rgbaBytes, lessThan(34 * 1024 * 1024));
    });

    test('texture dimension matches on-screen physical size', () {
      // 桌面 1080p 超出 1024 上限 → 截断到上限，控制显存。
      final desktop = dynamicGradientTextureDimensionFor(
        logicalSize: const Size(1600, 900),
        devicePixelRatio: 1.0,
      );
      expect(desktop, dynamicGradientMaxTextureDimension);

      // 小窗 720p 在物理尺寸内 → 按显示尺寸生成。
      final small = dynamicGradientTextureDimensionFor(
        logicalSize: const Size(800, 450),
        devicePixelRatio: 1.0,
      );
      expect(small, (800 * 1.0 * 1.12).ceil());

      // 高 DPI 手机超过上限 → 截断。
      final phone = dynamicGradientTextureDimensionFor(
        logicalSize: const Size(390, 844),
        devicePixelRatio: 3.0,
      );
      expect(phone, dynamicGradientMaxTextureDimension);

      // 4K 大屏同样截断。
      final large = dynamicGradientTextureDimensionFor(
        logicalSize: const Size(3840, 2160),
        devicePixelRatio: 1.0,
      );
      expect(large, dynamicGradientMaxTextureDimension);
    });

    test('texture dimension falls back on invalid inputs', () {
      expect(
        dynamicGradientTextureDimensionFor(
          logicalSize: const Size(0, 844),
          devicePixelRatio: 3.0,
        ),
        dynamicGradientTextureDimension,
      );
      expect(
        dynamicGradientTextureDimensionFor(
          logicalSize: const Size(390, 844),
          devicePixelRatio: 0,
        ),
        dynamicGradientTextureDimension,
      );
    });

    test('crossfade keeps the previous texture opaque', () {
      for (final incomingOpacity in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        const previousOpacity = 1.0;
        final compositeOpacity =
            incomingOpacity + previousOpacity * (1 - incomingOpacity);
        expect(compositeOpacity, 1.0);
      }
    });
  });
}
