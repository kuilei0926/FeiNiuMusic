import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';
import 'package:feiniu_music/components/focus/tv_text_field_focus_node.dart';

/// TV 文本输入框焦点：
/// - 上下键始终移出输入框（单行框无上下光标可移）；
/// - 左右键仅空输入框时移出（有内容时保留给光标微调）；
/// - 非 TV 模式完全不拦截（手机行为不变）。
void main() {
  setUp(() {
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  Future<void> pumpFields(
    WidgetTester tester, {
    String firstText = '',
    Axis axis = Axis.vertical,
  }) async {
    final controller1 = TextEditingController(text: firstText);
    final controller2 = TextEditingController();
    final focus1 = TvTextFieldFocusNode()..bindTo(controller1);
    final focus2 = TvTextFieldFocusNode()..bindTo(controller2);

    addTearDown(() {
      focus1.dispose();
      focus2.dispose();
      controller1.dispose();
      controller2.dispose();
    });

    final fields = [
      TextField(controller: controller1, focusNode: focus1, autofocus: true),
      const SizedBox(width: 20, height: 20),
      TextField(controller: controller2, focusNode: focus2),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: axis == Axis.vertical
              ? Column(children: fields)
              : Row(
                  children: [
                    Expanded(child: fields[0]),
                    fields[1],
                    Expanded(child: fields[2]),
                  ],
                ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('TV + 空输入框：arrowDown 移出到下一个输入框', (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await pumpFields(tester);

    final firstFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, isNot(same(firstFocus)));
  });

  testWidgets('TV + 输入框有内容：arrowDown 仍移出（上下键对单行无编辑价值）',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await pumpFields(tester, firstText: 'hello');

    final firstFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, isNot(same(firstFocus)));
  });

  testWidgets('TV + 输入框有内容：arrowLeft 保留给光标移动（不移出）',
      (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await pumpFields(tester, firstText: 'hello');

    final firstFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, same(firstFocus));
  });

  testWidgets('TV + 空输入框：arrowRight 移出到下一个输入框', (tester) async {
    AppLayoutSettings.tvMode.value = true;
    await pumpFields(tester, axis: Axis.horizontal);

    final firstFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, isNot(same(firstFocus)));
  });

  testWidgets('非 TV：方向键不拦截（保持默认行为）', (tester) async {
    await pumpFields(tester);

    final firstFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, same(firstFocus));
  });
}
