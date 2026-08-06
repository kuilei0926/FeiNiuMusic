import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_onboarding_state.dart';
import 'package:feiniu_music/app/state/settings_playback_state.dart';

/// 首次启动引导完成后「启动设置」的生效时机。
///
/// 引导页页4 文案明确「这些设置从下次启动生效」：在引导页勾选的
/// 「启动软件自动打开播放界面」与「进入应用自动播放」必须等下次启动才生效，
/// 不能在引导完成的当次 session 立即触发（否则用户刚进首页就被强行打开
/// 播放页并自动播放）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppOnboardingSettings.resetForTest();
    AppLaunchNavigationSettings.resetForTest();
    AppLaunchPlaybackSettings.resetForTest();
  });

  test('首次引导完成当次不触发「自动打开播放界面」（需下次启动）', () async {
    await AppOnboardingSettings.ensureLoaded();
    await AppLaunchNavigationSettings.ensureLoaded();
    // 引导页勾选该开关
    await AppLaunchNavigationSettings.setAutoOpenPlayerOnLaunch(true);

    // 引导完成（首页首帧前的门控入口，如 app.dart _scheduleAutoOpenPlayer）
    final shouldOpenNow =
        AppLaunchNavigationSettings.shouldAutoOpenPlayerOnLaunch();
    expect(
      shouldOpenNow,
      false,
      reason: '引导刚完成当次 session 不应自动打开播放页，应从下次启动生效',
    );
  });

  test('老用户重启（引导已完成）仍正常自动打开播放界面', () async {
    // 上次启动已完成引导（持久化已标记），本次是正常重启
    SharedPreferences.setMockInitialValues({'app_onboarding_completed': true});
    await AppOnboardingSettings.ensureLoaded();
    await AppLaunchNavigationSettings.ensureLoaded();
    await AppLaunchNavigationSettings.setAutoOpenPlayerOnLaunch(true);

    final shouldOpenNow =
        AppLaunchNavigationSettings.shouldAutoOpenPlayerOnLaunch();
    expect(
      shouldOpenNow,
      true,
      reason: '老用户重启且开关开着，应正常自动打开播放界面',
    );
  });

  test('首次引导完成当次不触发「进入应用自动播放」（需下次启动）', () async {
    await AppOnboardingSettings.ensureLoaded();
    await AppLaunchPlaybackSettings.ensureLoaded();
    // 引导页勾选该开关
    await AppLaunchPlaybackSettings.setAutoPlayOnAppLaunch(true);

    // 播放服务启动恢复（如 player_service _restorePlaybackState）
    final shouldAutoPlayNow =
        AppLaunchPlaybackSettings.shouldAutoPlayOnAppLaunch();
    expect(
      shouldAutoPlayNow,
      false,
      reason: '引导刚完成当次 session 不应自动播放，应从下次启动生效',
    );
  });

  test('老用户重启（引导已完成）仍正常自动播放', () async {
    SharedPreferences.setMockInitialValues({'app_onboarding_completed': true});
    await AppOnboardingSettings.ensureLoaded();
    await AppLaunchPlaybackSettings.ensureLoaded();
    await AppLaunchPlaybackSettings.setAutoPlayOnAppLaunch(true);

    final shouldAutoPlayNow =
        AppLaunchPlaybackSettings.shouldAutoPlayOnAppLaunch();
    expect(
      shouldAutoPlayNow,
      true,
      reason: '老用户重启且开关开着，应正常自动播放',
    );
  });
}
