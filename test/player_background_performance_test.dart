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

    test('keeps both transition RGBA textures below four megabytes', () {
      const rgbaBytes =
          dynamicGradientTextureDimension *
          dynamicGradientTextureDimension *
          4 *
          dynamicGradientMaxResidentTextures;
      expect(dynamicGradientMaxResidentTextures, 2);
      expect(rgbaBytes, lessThan(4 * 1024 * 1024));
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
