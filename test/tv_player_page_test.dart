import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/player/player_page.dart';
import 'package:feiniu_music/pages/player/tv_player_focus_scope.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() => AppLayoutSettings.resetForTest());

  testWidgets('非 TV：无 TvPlayerFocusScope，playerRouteActive 不动', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    expect(find.byType(TvPlayerFocusScope), findsNothing);
  });

  testWidgets('TV 模式：PlayerPage 挂载 → playerRouteActive=true，卸载 → false',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    expect(AppLayoutSettings.playerRouteActive.value, isFalse);

    await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
    await tester.pump();
    expect(AppLayoutSettings.playerRouteActive.value, isTrue);
    expect(find.byType(TvPlayerFocusScope), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(AppLayoutSettings.playerRouteActive.value, isFalse);
  });
}
