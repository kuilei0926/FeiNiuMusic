import 'package:feiniu_music/pages/player/widgets/player_background.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dynamic gradient resource limits', () {
    test('uses the same low animation rate on every platform', () {
      expect(dynamicGradientFramesPerSecond, 8);
    });

    test('keeps the reusable RGBA texture below two megabytes', () {
      const rgbaBytes =
          dynamicGradientTextureDimension * dynamicGradientTextureDimension * 4;
      expect(rgbaBytes, lessThan(2 * 1024 * 1024));
    });
  });
}
