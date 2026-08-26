import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/state/settings_playback_state.dart';

void main() {
  test('app playback volume loads, saves, and clamps values', () async {
    SharedPreferences.setMockInitialValues({'player_app_volume': 0.35});

    await AppPlaybackVolumeSettings.ensureLoaded();
    expect(AppPlaybackVolumeSettings.volume.value, 0.35);

    await AppPlaybackVolumeSettings.setVolume(1.4);
    expect(AppPlaybackVolumeSettings.volume.value, 1);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('player_app_volume'), 1);
  });

  test('app playback speed loads, saves, and snaps to 0.1 step', () async {
    SharedPreferences.setMockInitialValues({'player_playback_speed': 1.5});

    await AppPlaybackSpeedSettings.ensureLoaded();
    expect(AppPlaybackSpeedSettings.speed.value, 1.5);

    // 0.1 步进归一化。
    await AppPlaybackSpeedSettings.setSpeed(1.34);
    expect(AppPlaybackSpeedSettings.speed.value, 1.3);

    await AppPlaybackSpeedSettings.setSpeed(5.4);
    expect(AppPlaybackSpeedSettings.speed.value, 5.0);

    await AppPlaybackSpeedSettings.setSpeed(0.05);
    expect(AppPlaybackSpeedSettings.speed.value, 0.1);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('player_playback_speed'), 0.1);
  });

  test(
    'exclusive audio focus defaults off on non-iOS, loads and saves',
    () async {
      SharedPreferences.setMockInitialValues({});

      await AppPlaybackAudioFocusSettings.ensureLoaded();
      // 非 iOS 平台默认关闭；iOS 默认开启（锁屏控制可用），见设置类注释。
      expect(AppPlaybackAudioFocusSettings.exclusiveFocus.value, false);

      await AppPlaybackAudioFocusSettings.setExclusiveFocus(true);
      expect(AppPlaybackAudioFocusSettings.exclusiveFocus.value, true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('player_exclusive_audio_focus'), true);
    },
  );
}
