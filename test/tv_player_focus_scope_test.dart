import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/pages/player/tv_player_focus_scope.dart';

void main() {
  testWidgets('OK 键在中性区 → 播放/暂停', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          onTogglePlayPause: () => toggled++,
          child: Scaffold(
            body: Center(child: Focus(autofocus: true, child: Text('中性'))),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(toggled, 1);
  });

  testWidgets('OK 键在按钮上 → 激活按钮，不播放/暂停', (tester) async {
    var toggled = 0;
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          onTogglePlayPause: () => toggled++,
          child: Scaffold(
            body: Center(
              child: IconButton(
                autofocus: true,
                icon: const Icon(Icons.alarm),
                onPressed: () => pressed++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, 1);
    expect(toggled, 0);
  });

  testWidgets('长按左/右 → 上一曲/下一曲（KeyRepeat）', (tester) async {
    var prev = 0;
    var next = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          onPrevious: () => prev++,
          onNext: () => next++,
          child: Scaffold(
            body: Center(child: Focus(autofocus: true, child: SizedBox())),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(prev, 1);
    expect(next, 1);
  });

  testWidgets('下键：焦点在中性区 → 移到底部操作栏内第一个可聚焦项', (tester) async {
    final bottomFocus = FocusNode(debugLabel: 'bottomContainer');
    addTearDown(bottomFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: TvPlayerFocusScope(
          bottomActionsFocusNode: bottomFocus,
          child: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Focus(autofocus: true, debugLabel: 'neutral', child: Text('封面区')),
                ),
                Focus(
                  focusNode: bottomFocus,
                  // 容器只是「找第一个按钮」的句柄：自身不可聚焦/不可遍历，
                  // 让方向键跳过它直接落到里面的按钮。
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.shuffle),
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      isNot(equals(bottomFocus)),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // 焦点应落在底部操作栏内第一个可聚焦按钮（shuffle 的 IconButton）。
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull);
    expect(
      bottomFocus.descendants.contains(primary),
      isTrue,
      reason: '下键应聚焦到底部操作栏内按钮：实际 $primary',
    );
  });
}
