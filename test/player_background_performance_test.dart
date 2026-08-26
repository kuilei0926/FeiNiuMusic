import 'package:feiniu_music/pages/player/widgets/player_background.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dynamicGradientFramesPerSecond', () {
    test('limits desktop platforms to 8 frames per second', () {
      expect(dynamicGradientFramesPerSecond(TargetPlatform.macOS), 8);
      expect(dynamicGradientFramesPerSecond(TargetPlatform.windows), 8);
      expect(dynamicGradientFramesPerSecond(TargetPlatform.linux), 8);
    });

    test('keeps mobile platforms smoother', () {
      expect(dynamicGradientFramesPerSecond(TargetPlatform.android), 15);
      expect(dynamicGradientFramesPerSecond(TargetPlatform.iOS), 15);
    });
  });
}
