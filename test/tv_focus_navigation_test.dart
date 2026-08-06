import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/components/focus/tv_focusable.dart';

/// TV 遥控器方向键导航 widget 测试。
///
/// 模式：MaterialApp + FocusTraversalGroup 包裹一组 [TvFocusable]，用
/// `tester.sendKeyEvent` 发送方向键，断言焦点在元素间移动、Enter 触发
/// [onActivate]。使用 `tester.pump()` 而非 `pumpAndSettle`（焦点环动画
/// 是常驻的，pumpAndSettle 会超时）。
void main() {
  setUp(() {
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  testWidgets('TvFocusable：方向键移动焦点 + Enter 触发 onActivate',
      (tester) async {
    var activated = -1;
    final keys = List.generate(3, (i) => Key('item-$i'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: Column(
              children: [
                for (var i = 0; i < 3; i++)
                  TvFocusable(
                    key: keys[i],
                    autofocus: i == 0,
                    onActivate: () => activated = i,
                    child: Container(
                      width: 200,
                      height: 60,
                      color: Colors.grey,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 初始焦点落在第一个（autofocus），Enter 触发第一个 onActivate。
    expect(activated, -1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 0);

    // 方向键下 → 焦点移动到第二个，Enter 触发第二个。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 1);

    // 再下 → 第三个。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 2);

    // 方向键上 → 回到第二个。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 1);
  });

  testWidgets('TvFocusable：select 键同样触发 onActivate', (tester) async {
    var activated = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TvFocusable(
              autofocus: true,
              onActivate: () => activated = 1,
              child: Container(width: 100, height: 50, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(activated, 1);
  });
}
