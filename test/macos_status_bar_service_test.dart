import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/macos_status_bar_service.dart';

void main() {
  group('resolveMacosStatusBarText', () {
    test('shows the current lyric while playing', () {
      expect(
        resolveMacosStatusBarText(
          songTitle: 'Song title',
          currentLyric: '  Current lyric  ',
          isPlaying: true,
        ),
        'Current lyric',
      );
    });

    test('falls back to the song title when lyric is unavailable', () {
      expect(
        resolveMacosStatusBarText(
          songTitle: ' Song title ',
          currentLyric: '   ',
          isPlaying: true,
        ),
        'Song title',
      );
    });

    test('shows the song title while paused', () {
      expect(
        resolveMacosStatusBarText(
          songTitle: 'Song title',
          currentLyric: 'Current lyric',
          isPlaying: false,
        ),
        'Song title',
      );
    });
  });

  group('shouldEnableMacosCloseToTray', () {
    test('requires both close-to-tray and a visible status item', () {
      expect(
        shouldEnableMacosCloseToTray(
          closeToTrayEnabled: true,
          statusBarEnabled: true,
        ),
        isTrue,
      );
      expect(
        shouldEnableMacosCloseToTray(
          closeToTrayEnabled: true,
          statusBarEnabled: false,
        ),
        isFalse,
      );
      expect(
        shouldEnableMacosCloseToTray(
          closeToTrayEnabled: false,
          statusBarEnabled: true,
        ),
        isFalse,
      );
    });
  });
}
