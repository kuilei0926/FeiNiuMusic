import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/components/player/vinyl_player_gesture_area.dart';

void main() {
  var plays = 0;
  var previous = 0;
  var next = 0;
  var opened = 0;

  setUp(() {
    plays = 0;
    previous = 0;
    next = 0;
    opened = 0;
  });

  Widget scene({bool enabled = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: VinylPlayerGestureArea(
          key: const ValueKey('record'),
          enabled: enabled,
          label: '测试歌曲',
          value: '已暂停',
          onPlay: () => plays++,
          onPrevious: () => previous++,
          onNext: () => next++,
          onOpen: () => opened++,
          child: const SizedBox(width: 64, height: 64),
        ),
      ),
    ),
  );

  testWidgets('tap toggles playback without navigation', (tester) async {
    await tester.pumpWidget(scene());
    await tester.tap(find.byKey(const ValueKey('record')));
    expect(plays, 1);
    expect([previous, next, opened], [0, 0, 0]);
  });

  testWidgets('horizontal swipes skip once without toggling or opening', (
    tester,
  ) async {
    await tester.pumpWidget(scene());
    final record = find.byKey(const ValueKey('record'));
    await tester.drag(record, const Offset(-70, 0));
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 0, 1, 0]);
    await tester.drag(record, const Offset(70, 0));
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 1, 1, 0]);
  });

  testWidgets('upward swipe opens directly, downward swipe does nothing', (
    tester,
  ) async {
    await tester.pumpWidget(scene());
    final record = find.byKey(const ValueKey('record'));
    await tester.drag(record, const Offset(0, 70));
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 0, 0, 0]);
    await tester.drag(record, const Offset(0, -70));
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 0, 0, 1]);
  });

  testWidgets('diagonal drags commit only the dominant direction', (
    tester,
  ) async {
    await tester.pumpWidget(scene());
    final record = find.byKey(const ValueKey('record'));
    await tester.drag(record, const Offset(-80, -15));
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 0, 1, 0]);
    await tester.drag(record, const Offset(-15, -80));
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 0, 1, 1]);
  });

  testWidgets('cancelled drag never commits an action', (tester) async {
    await tester.pumpWidget(scene());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('record'))),
    );
    await gesture.moveBy(const Offset(-70, 0));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect([plays, previous, next, opened], [0, 0, 0, 0]);
  });

  testWidgets('empty record disables all gestures', (tester) async {
    await tester.pumpWidget(scene(enabled: false));
    final record = find.byKey(const ValueKey('record'));
    await tester.tap(record);
    await tester.drag(record, const Offset(-70, 0));
    await tester.drag(record, const Offset(70, 0));
    await tester.drag(record, const Offset(0, -70));
    expect([plays, previous, next, opened], [0, 0, 0, 0]);
  });

  testWidgets('screen reader exposes playback and three explicit actions', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(scene());
      final data = tester
          .getSemantics(find.byKey(const ValueKey('record')))
          .getSemanticsData();
      expect(data.label, '测试歌曲');
      expect(data.value, '已暂停');
      expect(data.customSemanticsActionIds, hasLength(3));
      final labels = data.customSemanticsActionIds!.map(
        (id) => CustomSemanticsAction.getAction(id)!.label,
      );
      expect(labels, containsAll(['上一曲', '下一曲', '打开播放页']));
    } finally {
      handle.dispose();
    }
  });
}
