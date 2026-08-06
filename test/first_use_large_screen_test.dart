import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';

/// 首次使用检测为 TV 或平板（大屏）时自动打开「切歌弹窗」开关。
///
/// - 平板判定：屏幕最短边 ≥ 600dp（Android sw600dp 惯例）；
/// - TV 判定：复用 [AppLayoutSettings.tvMode]（自动检测或手动强制）；
/// - 仅首次使用（首次引导会话）生效；老用户重启不改动任何开关；
/// - 同会话只应用一次：用户随后手动关闭切歌弹窗，不会再被自动打开。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLayoutSettings.resetForTest();
  });

  group('AppLayoutSettings.isLargeScreen（TV/平板判定）', () {
    test('TV 无论尺寸都判定为大屏', () {
      expect(
        AppLayoutSettings.isLargeScreen(isTv: true, shortestSide: 400),
        isTrue,
      );
    });

    test('最短边 ≥600 判定为平板（大屏）', () {
      expect(
        AppLayoutSettings.isLargeScreen(isTv: false, shortestSide: 600),
        isTrue,
      );
      expect(
        AppLayoutSettings.isLargeScreen(isTv: false, shortestSide: 800),
        isTrue,
      );
    });

    test('最短边 <600 的手机不判定为大屏', () {
      expect(
        AppLayoutSettings.isLargeScreen(isTv: false, shortestSide: 390),
        isFalse,
      );
    });
  });

  group('AppLayoutSettings.applyFirstUseLargeScreenDefaults（首次大屏自动开启切歌弹窗）', () {
    test('首次使用 + 平板：自动开启切歌弹窗并持久化', () async {
      await AppLayoutSettings.ensureLoaded();
      expect(AppLayoutSettings.trackChangeNotify.value, isFalse);

      await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
        isFirstLaunch: true,
        isTv: false,
        shortestSide: 800,
      );

      expect(AppLayoutSettings.trackChangeNotify.value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('setting_track_change_notify'), isTrue);
    });

    test('首次使用 + TV：自动开启切歌弹窗', () async {
      await AppLayoutSettings.ensureLoaded();

      await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
        isFirstLaunch: true,
        isTv: true,
        shortestSide: 400,
      );

      expect(AppLayoutSettings.trackChangeNotify.value, isTrue);
    });

    test('首次使用 + 手机：不开启切歌弹窗', () async {
      await AppLayoutSettings.ensureLoaded();

      await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
        isFirstLaunch: true,
        isTv: false,
        shortestSide: 390,
      );

      expect(AppLayoutSettings.trackChangeNotify.value, isFalse);
    });

    test('非首次启动（老用户）：即使大屏也不改动开关', () async {
      await AppLayoutSettings.ensureLoaded();

      await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
        isFirstLaunch: false,
        isTv: true,
        shortestSide: 800,
      );

      expect(AppLayoutSettings.trackChangeNotify.value, isFalse);
    });

    test('已应用后用户手动关闭：同会话不再重新开启', () async {
      await AppLayoutSettings.ensureLoaded();

      await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
        isFirstLaunch: true,
        isTv: false,
        shortestSide: 800,
      );
      expect(AppLayoutSettings.trackChangeNotify.value, isTrue);

      // 用户手动关闭
      await AppLayoutSettings.setTrackChangeNotify(false);

      // 再次触发（如引导页重建）不应重新开启
      await AppLayoutSettings.applyFirstUseLargeScreenDefaults(
        isFirstLaunch: true,
        isTv: false,
        shortestSide: 800,
      );
      expect(AppLayoutSettings.trackChangeNotify.value, isFalse);
    });
  });
}
