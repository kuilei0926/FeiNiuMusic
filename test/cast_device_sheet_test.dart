import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signals_flutter/signals_flutter.dart';

import 'package:feiniu_music/app/services/cast/dlna_cast_service.dart';
import 'package:feiniu_music/app/state/settings_cast_state.dart';
import 'package:feiniu_music/app/state/song_state.dart';
import 'package:feiniu_music/pages/player/widgets/cast_button.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'dlna_cast_enabled': true});
    DlnaCastSettings.resetForTest();
  });

  tearDown(() {
    DlnaCastService.instance.state.value = DlnaCastState.idle;
    DlnaCastSettings.resetForTest();
  });

  testWidgets('搜索结束后面板从加载状态切换为空列表提示并可重新搜索', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await DlnaCastSettings.ensureLoaded();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CastButton(songSignal: signal<SongEntity?>(null))),
      ),
    );
    await tester.tap(find.byIcon(Icons.cast));
    await tester.pumpAndSettle();

    final cast = DlnaCastService.instance;
    cast.state.value = DlnaCastState.discovering;
    await tester.pump();
    expect(find.text('正在搜索设备…'), findsOneWidget);
    expect(find.byTooltip('重新搜索'), findsNothing);

    cast.state.value = DlnaCastState.idle;
    await tester.pump();
    expect(find.text('正在搜索设备…'), findsNothing);
    expect(find.textContaining('未发现 DLNA 设备'), findsOneWidget);
    expect(find.byTooltip('重新搜索'), findsOneWidget);

    // 关闭面板，释放自动停止搜索的计时器。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
