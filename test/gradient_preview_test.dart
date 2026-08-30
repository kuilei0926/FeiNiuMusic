import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/widgets/player_background.dart';

ui.Image? _backgroundTexture(WidgetTester tester) =>
    tester.widget<RawImage>(find.byType(RawImage)).image;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dynamic aurora regenerates its bounded texture when tuned', (
    tester,
  ) async {
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

    expect(find.byType(RawImage), findsOneWidget);
    final initialTexture = _backgroundTexture(tester);
    expect(initialTexture, isNotNull, reason: '动态流光开启时应生成有界背景纹理');

    PlayerBackgroundSettings.saturation.value = 2.0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final saturatedTexture = _backgroundTexture(tester);
    expect(saturatedTexture, isNotNull);
    expect(saturatedTexture, isNot(same(initialTexture)));

    PlayerBackgroundSettings.hueShift.value = 120.0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final shiftedTexture = _backgroundTexture(tester);
    expect(shiftedTexture, isNotNull);
    expect(shiftedTexture, isNot(same(saturatedTexture)));
  });
}
