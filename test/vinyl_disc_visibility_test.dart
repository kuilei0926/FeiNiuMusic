import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/utils/route_visibility.dart';
import 'package:feiniu_music/components/player/vinyl_disc.dart';

void main() {
  testWidgets(
    'rotation stops for covered route and background, resumes at its angle',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [appRouteObserver],
          home: const Scaffold(body: VinylDisc(playing: true)),
        ),
      );
      double angle() => tester
          .widget<RotationTransition>(
            find.descendant(
              of: find.byType(VinylDisc, skipOffstage: false),
              matching: find.byType(RotationTransition, skipOffstage: false),
            ),
          )
          .turns
          .value;
      await tester.pump(const Duration(milliseconds: 100));
      final first = angle();
      expect(first, greaterThan(0));
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('covered')),
        ),
      );
      await tester.pump();
      final covered = angle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(angle(), covered);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(angle(), greaterThan(covered));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final paused = angle();
      await tester.pump(const Duration(seconds: 1));
      expect(angle(), paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(angle(), greaterThan(paused));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
