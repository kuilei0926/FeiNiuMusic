import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';

/// TV 方向键「跨块」导航 widget 测试。
///
/// 复现 TabletLayoutHost 的结构：最外层根 ReadingOrder 域里，左侧是一个
/// 侧边栏可聚焦项，右侧是一个嵌套 Navigator（模拟主内容，route scope 的
/// `directionalTraversalEdgeBehavior = parentScope`）。验证：
/// - 焦点在主内容时按 左 → 跳到侧栏（否则会因 route scope 默认 stop 卡住）；
/// - 焦点在侧栏时按 右 → 回到主内容。
///
/// 这是问题「侧边栏模式下按左键切换不到侧栏」的回归测试。
void main() {
  setUp(() {
    AppLayoutSettings.resetForTest();
  });

  tearDown(() {
    AppLayoutSettings.resetForTest();
  });

  late FocusNode sideNode;
  late FocusNode contentNode;

  Future<void> pumpHost(WidgetTester tester) async {
    sideNode = FocusNode(debugLabel: 'side');
    contentNode = FocusNode(debugLabel: 'content');
    addTearDown(() {
      sideNode.dispose();
      contentNode.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              // 左侧侧边栏：一个可聚焦项
              SizedBox(
                width: 160,
                child: Center(
                  child: Focus(
                    focusNode: sideNode,
                    child: Container(width: 120, height: 60, color: Colors.grey),
                  ),
                ),
              ),
              // 右侧主内容：嵌套 Navigator（route scope 放开方向键边缘）
              Expanded(
                child: Navigator(
                  routeDirectionalTraversalEdgeBehavior:
                      TraversalEdgeBehavior.parentScope,
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    builder: (_) => Center(
                      child: Focus(
                        focusNode: contentNode,
                        autofocus: true,
                        child: Container(
                          width: 200,
                          height: 60,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('主内容按左 → 跳到侧栏（parentScope 跨 scope）', (tester) async {
    await pumpHost(tester);

    // 初始焦点在主内容项（autofocus）。
    expect(FocusManager.instance.primaryFocus, contentNode);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    // 焦点应跨到侧栏项。
    expect(
      FocusManager.instance.primaryFocus,
      sideNode,
      reason: 'route scope parentScope 应让左键从主内容跳到左侧侧栏',
    );
  });

  testWidgets('侧栏按右 → 回到主内容（同域 ReadingOrder 几何定位）', (tester) async {
    await pumpHost(tester);

    // 先聚焦侧栏项。
    sideNode.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, sideNode);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    // 焦点应回到主内容。
    expect(
      FocusManager.instance.primaryFocus,
      contentNode,
      reason: '侧栏在主内容左侧，右键应按几何回到主内容',
    );
  });
}
