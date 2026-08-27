import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signals_flutter/signals_flutter.dart' hide computed;

import 'package:feiniu_music/app/state/song_state.dart' show SongEntity;
import 'package:feiniu_music/app/utils/primary_shell_scope.dart';
import 'package:feiniu_music/components/layout/modern_navigation_bar.dart'
    show PrimaryNavigationScope;
import 'package:feiniu_music/components/list/song_multi_select_mixin.dart';

/// 底部导航栏模式下「返回键取消多选」回归测试。
///
/// shell 的 PopScope 收到返回键且发现多选时 bump [requestCancelMultiSelect]
/// 信号，多选页（[SongMultiSelectMixin]）监听后退出多选、留在当前页（不切
/// tab、不退出页面）。本测试复刻 shell 的 PrimaryNavigationScope +
/// IndexedStack 结构验证该信号机制。
void main() {
  tearDown(() {
    globalMultiSelectActive.value = 0;
    requestCancelMultiSelect.value = 0;
  });

  Widget buildHarness() => const MaterialApp(home: ShellHarness());

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

    // shell 收到返回键：多选中不发切 tab 信号，改为请求取消多选
    requestCancelMultiSelect.value += 1;
    await tester.pump();
    expect(tab1.isMultiSelecting, isFalse, reason: '返回键应取消多选');
    expect(globalMultiSelectActive.value, 0, reason: '全局计数应清零');
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
    with SignalsMixin, SongMultiSelectMixin {
  @override
  List<SongEntity> get multiSelectSongs => [];

  @override
  Widget build(BuildContext context) {
    return Text('tab${widget.index}');
  }
}

/// 复刻 _PrimaryNavigationShell 的结构：PrimaryShellMarker +
/// PrimaryNavigationScope + IndexedStack。
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
        child: IndexedStack(
          index: _current,
          children: [
            for (var i = 0; i < widget.tabCount; i++) TestTabPage(index: i),
          ],
        ),
      ),
    );
  }
}
