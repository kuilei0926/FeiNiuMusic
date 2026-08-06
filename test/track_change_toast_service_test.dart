import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/track_change_toast_service.dart';

void main() {
  group('TrackChangeToastService.shouldShow', () {
    test('通知开关关闭时不弹', () {
      expect(
        TrackChangeToastService.shouldShow(
          previousId: 'song-a',
          newId: 'song-b',
          notifyEnabled: false,
        ),
        false,
      );
    });

    test('首次选歌 / 启动恢复（previousId 为空）不弹', () {
      expect(
        TrackChangeToastService.shouldShow(
          previousId: null,
          newId: 'song-b',
          notifyEnabled: true,
        ),
        false,
      );
    });

    test('同一首歌重复通知（同 id）不弹', () {
      expect(
        TrackChangeToastService.shouldShow(
          previousId: 'song-a',
          newId: 'song-a',
          notifyEnabled: true,
        ),
        false,
      );
    });

    test('真实切歌（A → B）弹出', () {
      expect(
        TrackChangeToastService.shouldShow(
          previousId: 'song-a',
          newId: 'song-b',
          notifyEnabled: true,
        ),
        true,
      );
    });
  });
}
