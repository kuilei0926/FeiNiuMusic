import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/widgets/player_background.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('desktop texture resource limits', () {
    test('caps both transition RGBA textures below four megabytes', () {
      const rgbaBytes =
          dynamicGradientTextureDimension *
          dynamicGradientTextureDimension *
          4 *
          dynamicGradientMaxResidentTextures;
      expect(dynamicGradientMaxResidentTextures, 2);
      expect(rgbaBytes, lessThan(4 * 1024 * 1024));
    });

    testWidgets('desktop uses a bounded texture instead of full-screen painting', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      // Run the memoized loader once so PlayerBackground.initState's ensureLoaded
      // is a no-op and won't overwrite the values we set below.
      await PlayerBackgroundSettings.ensureLoaded();
      PlayerBackgroundSettings.dynamicGradientEnabled.value = true;
      PlayerBackgroundSettings.saturation.value = 1.0;
      PlayerBackgroundSettings.hueShift.value = 0.0;

      final songSignal = signal<SongEntity?>(null);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlayerBackground(songSignal: songSignal)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final rawImages = tester.widgetList<RawImage>(find.byType(RawImage));
      debugDefaultTargetPlatformOverride = null;
      expect(rawImages.length, 1, reason: '桌面端应使用有界纹理背景');
      expect(rawImages.first.image, isNotNull, reason: '动态流光开启时桌面端应生成背景纹理');
    });
  });
}
