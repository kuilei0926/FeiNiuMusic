import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/login_pair_server.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/pages/login/login_page.dart';
import 'package:feiniu_music/pages/login/widgets/login_qr_card.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });
  tearDown(() {
    AppLayoutSettings.resetForTest();
    LoginPairServer.stop();
  });

  testWidgets('非 TV：无二维码卡片（原样渲染）', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    expect(find.byType(LoginQrCard), findsNothing);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('TV 模式：显示二维码卡片', (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LoginQrCard), findsOneWidget);
    expect(find.text('扫码配对'), findsOneWidget);
  });
}
