import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals/signals.dart';

import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/widgets/player_background.dart';

double? _auroraSaturation(WidgetTester tester) =>
    _auroraField(tester, 'saturation');
double? _auroraHueShift(WidgetTester tester) =>
    _auroraField(tester, 'hueShift');

double? _auroraField(WidgetTester tester, String field) {
  for (final cp in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    final painter = cp.painter;
    if (painter == null) continue;
    if (painter.runtimeType.toString().contains('Aurora')) {
      final value = field == 'saturation'
          ? (painter as dynamic).saturation
          : (painter as dynamic).hueShift;
      return value as double;
    }
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dynamic aurora preview repaints when saturation changes', (
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

    expect(_auroraSaturation(tester), isNotNull, reason: '动态流光开启时应渲染极光画笔');
    expect(_auroraSaturation(tester), closeTo(1.0, 0.0001));

    PlayerBackgroundSettings.saturation.value = 2.0;
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      _auroraSaturation(tester),
      closeTo(2.0, 0.0001),
      reason: '改变 saturation 后画笔应收到新值（接线是否生效）',
    );

    PlayerBackgroundSettings.hueShift.value = 120.0;
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      _auroraHueShift(tester),
      closeTo(120.0, 0.0001),
      reason: '改变 hueShift 后画笔应收到新值',
    );
  });
}
