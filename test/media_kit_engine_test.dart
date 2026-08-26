import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/player/media_kit_engine.dart';
import 'package:feiniu_music/app/services/player/player_engine.dart';

void main() {
  group('configureMediaKitDesktopAudioOnly', () {
    test('禁用 mpv 磁盘缓存、内嵌封面显示和视频轨', () async {
      final applied = <String, String>{};

      await configureMediaKitDesktopAudioOnly(
        setProperty: (property, value) async {
          applied[property] = value;
        },
      );

      expect(applied, {
        'cache-on-disk': 'no',
        'audio-display': 'no',
        'vid': 'no',
      });
    });

    test('单个 mpv 属性失败时继续应用其余保护项', () async {
      final attempted = <String>[];
      final errors = <String>[];

      await configureMediaKitDesktopAudioOnly(
        setProperty: (property, value) async {
          attempted.add(property);
          if (property == 'audio-display') {
            throw UnsupportedError(property);
          }
        },
        onError: (property, error) => errors.add(property),
      );

      expect(attempted, ['cache-on-disk', 'audio-display', 'vid']);
      expect(errors, ['audio-display']);
    });
  });

  group('mediaKitCompletedPlaylistIndex', () {
    test('completed 回调使用已交付索引而不是抢跑到下一首的原生索引', () {
      expect(
        mediaKitCompletedPlaylistIndex(observedIndex: 0, nativeIndex: 1),
        0,
      );
    });

    test('尚未收到 playlist 事件时回退原生索引', () {
      expect(
        mediaKitCompletedPlaylistIndex(observedIndex: null, nativeIndex: 2),
        2,
      );
    });
  });

  group('mediaKitProcessingState', () {
    test('中间歌曲 EOF 不上报整个播放列表完成', () {
      expect(
        mediaKitProcessingState(
          buffering: false,
          completed: true,
          playlistIndex: 1,
          playlistLength: 3,
        ),
        EngineProcessingState.ready,
      );
    });

    test('最后一首 EOF 上报播放列表完成', () {
      expect(
        mediaKitProcessingState(
          buffering: false,
          completed: true,
          playlistIndex: 2,
          playlistLength: 3,
        ),
        EngineProcessingState.completed,
      );
    });

    test('最后一首完成状态优先于 EOF 时的瞬时缓冲状态', () {
      expect(
        mediaKitProcessingState(
          buffering: true,
          completed: true,
          playlistIndex: 2,
          playlistLength: 3,
        ),
        EngineProcessingState.completed,
      );
    });

    test('中间歌曲 EOF 即使正在缓冲也不上报播放列表完成', () {
      expect(
        mediaKitProcessingState(
          buffering: true,
          completed: true,
          playlistIndex: 1,
          playlistLength: 3,
        ),
        EngineProcessingState.buffering,
      );
    });
  });

  group('mediaKitIsTrailingDecodeError', () {
    test('已到 EOF 的 FLAC 解码错误视为尾部噪音', () {
      expect(
        mediaKitIsTrailingDecodeError(
          message: 'Error decoding audio.',
          completed: true,
          position: const Duration(minutes: 4),
          duration: const Duration(minutes: 4),
        ),
        isTrue,
      );
    });

    test('距离结尾两秒内的解码错误视为尾部噪音', () {
      expect(
        mediaKitIsTrailingDecodeError(
          message: 'Error decoding audio.',
          completed: false,
          position: const Duration(minutes: 3, seconds: 59),
          duration: const Duration(minutes: 4),
        ),
        isTrue,
      );
    });

    test('歌曲中段的解码错误仍上报恢复', () {
      expect(
        mediaKitIsTrailingDecodeError(
          message: 'Error decoding audio.',
          completed: false,
          position: const Duration(minutes: 2),
          duration: const Duration(minutes: 4),
        ),
        isFalse,
      );
    });

    test('其它错误即使接近结尾也不忽略', () {
      expect(
        mediaKitIsTrailingDecodeError(
          message: 'Failed to open media.',
          completed: true,
          position: const Duration(minutes: 4),
          duration: const Duration(minutes: 4),
        ),
        isFalse,
      );
    });
  });

  group('normalizeCroppedPosition', () {
    test('非裁剪曲目（无 start / start 为零）原样透传', () {
      expect(
        normalizeCroppedPosition(const Duration(minutes: 53), null),
        const Duration(minutes: 53),
      );
      expect(
        normalizeCroppedPosition(
          const Duration(minutes: 53),
          Duration.zero,
        ),
        const Duration(minutes: 53),
      );
    });

    test('CUE 裁剪曲目把整轨绝对位置换算为裁剪段内相对时间', () {
      expect(
        normalizeCroppedPosition(
          const Duration(minutes: 53),
          const Duration(minutes: 50),
        ),
        const Duration(minutes: 3),
      );
    });

    test('位置不低于零（裁剪起始前的瞬时上报被夹到 0）', () {
      expect(
        normalizeCroppedPosition(
          const Duration(seconds: 30),
          const Duration(minutes: 50),
        ),
        Duration.zero,
      );
    });
  });

  group('absoluteCroppedSeekTarget', () {
    test('非裁剪曲目（无 start）原样透传', () {
      expect(
        absoluteCroppedSeekTarget(const Duration(minutes: 3), null),
        const Duration(minutes: 3),
      );
    });

    test('CUE 裁剪曲目相对 seek 目标换算回整轨绝对位置', () {
      expect(
        absoluteCroppedSeekTarget(
          const Duration(minutes: 3),
          const Duration(minutes: 50),
        ),
        const Duration(minutes: 53),
      );
    });
  });
}
