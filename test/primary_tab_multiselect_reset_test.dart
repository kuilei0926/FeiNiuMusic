import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import 'package:feiniu_music/app/state/song_state.dart' show SongEntity;
import 'package:feiniu_music/app/utils/primary_shell_scope.dart';
import 'package:feiniu_music/app/utils/primary_tab_refresh_mixin.dart';
import 'package:feiniu_music/components/layout/modern_navigation_bar.dart'
    show PrimaryNavigationScope;
import 'package:feiniu_music/components/list/song_multi_select_mixin.dart';

/// 底部导航栏模式下，返回键切到首页 tab 时 IndexedStack 不会销毁原页面，
/// 多选状态会残留、globalMultiSelectActive 计数不清零，导致共享底栏一直
/// 隐藏（右上角取消多选却正常恢复）。页面在 [PrimaryTabRefreshMixin] 的
/// onPrimaryTabDeactivated 中退出多选，本测试复刻 shell 的
/// PrimaryNavigationScope + IndexedStack + 共享底栏结构验证该行为，
/// 并确保失活时的退出不会在 build 阶段触发 setState 异常。
void main() {
  tearDown(() {
    globalMultiSelectActive.value = 0;
    requestCancelMultiSelect.value = 0;
  });

  Widget buildHarness() => const MaterialApp(home: ShellHarness());

  testWidgets('多选后切到其它 tab：退出多选并恢复底栏（返回键场景）', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.pump();

    // 切到 tab1 并开启多选 → 共享底栏隐藏
    final harness = tester.state<ShellHarnessState>(
      find.byType(ShellHarness),
    );
    harness.select(1);
    await tester.pump();
    final tab1 = tester.state<TestTabPageState>(
      find.byWidgetPredicate(
        (w) => w is TestTabPage && w.index == 1,
        skipOffstage: false,
      ),
    );
    tab1.toggleMultiSelect();
    await tester.pump();
    expect(find.text('NAV'), findsNothing, reason: '多选时底栏应隐藏');
    expect(globalMultiSelectActive.value, 1);

    // 返回键 → 切回 tab0：tab1 失活应退出多选（帧后），底栏恢复
    harness.select(0);
    await tester.pump(); // 本帧：切换 tab + 帧后触发退出多选
    await tester.pump(); // 下一帧：底栏按清零后的计数重建
    expect(tab1.isMultiSelecting, isFalse, reason: '切走后应退出多选');
    expect(globalMultiSelectActive.value, 0, reason: '全局计数应清零');
    expect(find.text('NAV'), findsOneWidget, reason: '底栏应恢复显示');
  });

  testWidgets('失活时退出多选不触发 build 阶段 setState 异常', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.pump();

    final harness = tester.state<ShellHarnessState>(
      find.byType(ShellHarness),
    );
    // 先切到 tab1 并开启多选，再切回 tab0（触发真实失活路径）
    harness.select(1);
    await tester.pump();
    final tab1 = tester.state<TestTabPageState>(
      find.byWidgetPredicate(
        (w) => w is TestTabPage && w.index == 1,
        skipOffstage: false,
      ),
    );
    tab1.toggleMultiSelect();
    await tester.pump();
    expect(globalMultiSelectActive.value, 1);

    // 失活路径：设置 notifier 不应抛 "setState() called during build"
    harness.select(0);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(globalMultiSelectActive.value, 0);
    expect(find.text('NAV'), findsOneWidget);
  });

  testWidgets('多选时返回键：取消多选并留在当前页（不切 tab）', (tester) async {
    await tester.pumpWidget(buildHarness());
    await tester.pump();

    final harness = tester.state<ShellHarnessState>(
      find.byType(ShellHarness),
    );
    harness.select(1);
    await tester.pump();
    final tab1 = tester.state<TestTabPageState>(
      find.byWidgetPredicate(
        (w) => w is TestTabPage && w.index == 1,
        skipOffstage: false,
      ),
    );
    tab1.toggleMultiSelect();
    await tester.pump();
    expect(globalMultiSelectActive.value, 1);
    expect(find.text('NAV'), findsNothing, reason: '多选时底栏应隐藏');

    // shell 收到返回键：多选中不发切 tab 信号，改为请求取消多选
    requestCancelMultiSelect.value += 1;
    await tester.pump();
    expect(tab1.isMultiSelecting, isFalse, reason: '返回键应取消多选');
    expect(globalMultiSelectActive.value, 0, reason: '全局计数应清零');
    expect(find.text('NAV'), findsOneWidget, reason: '底栏应恢复显示');
    // 仍停留在 tab1（未被切回首页）
    expect(find.text('tab1'), findsOneWidget);
  });
}

class TestTabPage extends StatefulWidget {
  final int index;
  const TestTabPage({super.key, required this.index});

  @override
  State<TestTabPage> createState() => TestTabPageState();
}

class TestTabPageState extends State<TestTabPage>
    with SignalsMixin, SongMultiSelectMixin, PrimaryTabRefreshMixin {
  @override
  int get primaryTabIndex => widget.index;

  @override
  List<SongEntity> get multiSelectSongs => [];

  @override
  Future<void> onPrimaryTabActivated() async {}

  @override
  void onPrimaryTabDeactivated() {
    if (isMultiSelecting) exitMultiSelect();
  }

  @override
  Widget build(BuildContext context) {
    return Text('tab${widget.index}');
  }
}

/// 复刻 _PrimaryNavigationShell 的结构：PrimaryShellMarker +
/// PrimaryNavigationScope + IndexedStack + 监听 globalMultiSelectActive 的
/// 共享底栏。
class ShellHarness extends StatefulWidget {
  final int tabCount;
  const ShellHarness({super.key, this.tabCount = 3});

  @override
  State<ShellHarness> createState() => ShellHarnessState();
}

class ShellHarnessState extends State<ShellHarness> {
  int _current = 0;

  void select(int index) => setState(() => _current = index);

  @override
  Widget build(BuildContext context) {
    return PrimaryShellMarker(
      child: PrimaryNavigationScope(
        currentIndex: _current,
        onSelected: select,
        child: Stack(
          children: [
            IndexedStack(
              index: _current,
              children: [
                for (var i = 0; i < widget.tabCount; i++)
                  TestTabPage(index: i),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ValueListenableBuilder<int>(
                valueListenable: globalMultiSelectActive,
                builder: (context, count, _) => count > 0
                    ? const SizedBox.shrink()
                    : const Text('NAV'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
