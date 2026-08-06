import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_layout_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 重置静态懒加载缓存与值，避免跨 test 污染
    AppLayoutSettings.resetForTest();
  });

  test('切歌通知默认关闭，时长默认 3 秒', () async {
    await AppLayoutSettings.ensureLoaded();
    expect(AppLayoutSettings.trackChangeNotify.value, false);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 3000);
  });

  test('setTrackChangeNotify 更新 notifier 并持久化', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeNotify(true);
    expect(AppLayoutSettings.trackChangeNotify.value, true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('setting_track_change_notify'), true);
  });

  test('setTrackChangeToastDurationMs 更新 notifier 并持久化', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeToastDurationMs(5000);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 5000);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('setting_track_change_toast_duration_ms'), 5000);
  });

  test('提示时长钳制到 2s–10s 区间', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeToastDurationMs(500);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 2000);

    await AppLayoutSettings.setTrackChangeToastDurationMs(20000);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 10000);
  });

  test('已持久化的开关与时长可正确读回', () async {
    SharedPreferences.setMockInitialValues({
      'setting_track_change_notify': true,
      'setting_track_change_toast_duration_ms': 5000,
    });
    await AppLayoutSettings.ensureLoaded();
    expect(AppLayoutSettings.trackChangeNotify.value, true);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 5000);
  });

  test('resetForTest 复位切歌通知状态', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeNotify(true);
    await AppLayoutSettings.setTrackChangeToastDurationMs(7000);
    expect(AppLayoutSettings.trackChangeNotify.value, true);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 7000);

    AppLayoutSettings.resetForTest();
    expect(AppLayoutSettings.trackChangeNotify.value, false);
    expect(AppLayoutSettings.trackChangeToastDurationMs.value, 3000);
  });

  test('切歌卡片大小倍数默认 1.0（当前大小）', () async {
    await AppLayoutSettings.ensureLoaded();
    expect(AppLayoutSettings.trackChangeToastScale.value, 1.0);
  });

  test('setTrackChangeToastScale 更新 notifier 并持久化', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeToastScale(2.0);
    expect(AppLayoutSettings.trackChangeToastScale.value, 2.0);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('setting_track_change_toast_scale'), 2.0);
  });

  test('卡片大小倍数钳制到 1.0–3.0', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeToastScale(0.5);
    expect(AppLayoutSettings.trackChangeToastScale.value, 1.0);

    await AppLayoutSettings.setTrackChangeToastScale(5.0);
    expect(AppLayoutSettings.trackChangeToastScale.value, 3.0);
  });

  test('已持久化的倍数可正确读回', () async {
    SharedPreferences.setMockInitialValues({
      'setting_track_change_toast_scale': 2.0,
    });
    await AppLayoutSettings.ensureLoaded();
    expect(AppLayoutSettings.trackChangeToastScale.value, 2.0);
  });

  test('resetForTest 复位卡片大小倍数', () async {
    await AppLayoutSettings.ensureLoaded();
    await AppLayoutSettings.setTrackChangeToastScale(2.0);
    expect(AppLayoutSettings.trackChangeToastScale.value, 2.0);

    AppLayoutSettings.resetForTest();
    expect(AppLayoutSettings.trackChangeToastScale.value, 1.0);
  });
}
