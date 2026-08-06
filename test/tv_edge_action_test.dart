import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/router/app_router.dart';
import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/app/utils/app_navigator.dart';
import 'package:feiniu_music/components/focus/tv_focus_scope.dart';

/// TV 方向键「边缘动作」测试。
///
/// 验证 TvFocusScope 的右键处理：
/// - 焦点节点右侧已无任何可聚焦目标时，按右键 → 通过 AppNavigator 打开播放页；
/// - 右侧有目标时按右键 → 正常向右移动，不打开播放页。
void main() {
  setUp(() {
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
    AppNavigator.attach(null);
  });

  testWidgets('右键已到边缘 → 打开播放页', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    AppNavigator.attach(navKey);

    await tester.pumpWidget(
      MaterialApp(
        home: TvFocusScope(
          child: Navigator(
            key: navKey,
            onGenerateRoute: (settings) {
              if (settings.name == AppRoutes.player) {
                return MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => const Scaffold(body: Text('player')),
                );
              }
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => Scaffold(
                  body: Align(
                    alignment: Alignment.centerRight,
                    child: Focus(
                      debugLabel: 'right-edge',
                      autofocus: true,
                      child: Container(width: 100, height: 100, color: Colors.grey),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // 焦点在右边缘节点（autofocus），右侧无目标。
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('right-edge'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    // 应通过 AppNavigator 压栈播放页。
    expect(find.text('player'), findsOneWidget);
  });

  testWidgets('右侧有目标 → 正常移动，不打开播放页', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    AppNavigator.attach(navKey);

    await tester.pumpWidget(
      MaterialApp(
        home: TvFocusScope(
          child: Navigator(
            key: navKey,
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => Scaffold(
                body: Row(
                  children: [
                    Focus(
                      debugLabel: 'left',
                      autofocus: true,
                      child: Container(width: 100, height: 100, color: Colors.grey),
                    ),
                    const SizedBox(width: 40),
                    Focus(
                      debugLabel: 'right',
                      child: Container(width: 100, height: 100, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 焦点在左侧节点。
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('left'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    // 应移动到右侧节点，不打开播放页。
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('right'));
    expect(find.text('player'), findsNothing);
  });
}
