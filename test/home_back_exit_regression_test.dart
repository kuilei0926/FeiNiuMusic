import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/navigator_key.dart';
import 'package:feiniu_music/components/feedback/app_toast.dart';
import 'package:feiniu_music/components/layout/tablet_layout_host.dart';

/// 回归测试：真机日志曾显示首页返回时
/// `AppToast.showGlobal` 因 `Overlay.of(根 Navigator context)` 返回 null
/// 抛空检查异常，导致 `_RootBackHandler` 在 `_armedToExit=true` 之前崩溃——
/// 「返回没反应、不会回到桌面」。这里验证：
/// 1. showGlobal 用根 Navigator 自己的 overlay 弹 toast 不再崩溃；
/// 2. 首页第一次返回弹出提示、第二次返回触发 SystemNavigator.pop()。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('showGlobal 通过根 Navigator overlay 弹 toast 不崩溃', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appNavigatorKey,
        home: const SizedBox(),
      ),
    );
    await tester.pump();

    // 旧实现：Overlay.of(appNavigatorKey.currentContext) 在此必然抛异常。
    // 新实现：直接取 NavigatorState.overlay，应正常插入、不抛。
    expect(() => AppToast.showGlobal('测试全局提示'), returnsNormally);
    await tester.pump();
    expect(find.text('测试全局提示'), findsOneWidget);
    // 等到 toast 自动消失，避免收尾时仍有 pending timer。
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('测试全局提示'), findsNothing);
  });

  testWidgets('首页：第一次返回弹提示并武装，第二次返回 SystemNavigator.pop',
      (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final systemPopCalls = <bool?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') {
          systemPopCalls.add(call.arguments as bool?);
          return null;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: TabletLayoutHost(
          navigatorKey: navKey,
          child: Navigator(
            key: navKey,
            onGenerateRoute: (settings) => MaterialPageRoute(
              settings: settings,
              builder: (_) => const Text('home'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 第一次返回：不再崩溃（这是 1.5.5 起的回归点），弹提示 + 武装
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(systemPopCalls, isEmpty, reason: '第一次返回只提示，不退出');

    // 第二次返回：真正 SystemNavigator.pop() → 回到桌面
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(systemPopCalls, isNotEmpty, reason: '第二次返回应退出到桌面');
  });
}
