import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/components/layout/base/app_page_scaffold.dart';
import 'package:feiniu_music/components/layout/modern_navigation_bar.dart';

/// 底部导航栏在页面内渲染时的多选隐藏回归测试。
///
/// 多选时页面底部出现操作栏，而底部导航栏以 Positioned 悬浮在内容上方，
/// 会盖住操作栏（歌曲/收藏等 tab 页的共享底栏由 shell 在
/// app_router.dart 用 globalMultiSelectActive 隐藏；本测试覆盖页面自渲染
/// 底栏的分支 —— 歌手/专辑/歌单详情页通过 hideBottomNav 隐藏）。
void main() {
  Widget buildScaffold({required bool hideBottomNav}) {
    return MaterialApp(
      home: AppPageScaffold(
        body: const SizedBox.expand(),
        showMiniPlayer: false,
        bottomNavIndex: 0,
        onBottomNavTap: (_) {},
        hideBottomNav: hideBottomNav,
      ),
    );
  }

  testWidgets('hideBottomNav=false：渲染底部导航栏', (tester) async {
    await tester.pumpWidget(buildScaffold(hideBottomNav: false));
    await tester.pump();
    expect(find.byType(ModernNavigationBar), findsOneWidget);
  });

  testWidgets('hideBottomNav=true：隐藏底部导航栏（不被覆盖）', (tester) async {
    await tester.pumpWidget(buildScaffold(hideBottomNav: true));
    await tester.pump();
    expect(find.byType(ModernNavigationBar), findsNothing);
  });

  testWidgets('hideBottomNav 从 false 切到 true 时导航栏随动消失', (tester) async {
    await tester.pumpWidget(buildScaffold(hideBottomNav: false));
    await tester.pump();
    expect(find.byType(ModernNavigationBar), findsOneWidget);

    await tester.pumpWidget(buildScaffold(hideBottomNav: true));
    await tester.pump();
    expect(find.byType(ModernNavigationBar), findsNothing);
  });
}
