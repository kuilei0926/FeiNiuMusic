import 'package:flutter_test/flutter_test.dart';

import 'package:feiniu_music/app/services/media_notification_metadata.dart';
import 'package:feiniu_music/app/state/song_state.dart';

const _song = SongEntity(
  id: 'track',
  title: 'Time after time',
  artist: '[{"name":"仓木麻衣"}]',
  album: '{"name":"专辑"}',
  durationMs: 244000,
);

void main() {
  test('Android 第二行歌词写入系统卡片读取的 artist，并保留媒体信息', () {
    final art = Uri.file('/cache/cover.jpg');
    final metadata = buildMediaNotificationMetadata(
      _song,
      current: true,
      isAndroid: true,
      isPlaying: true,
      showLyrics: true,
      lyricOnTop: false,
      carLyricsEnabled: false,
      lyricLine: '当前歌词',
      carLyricLine: '当前歌词',
      artUri: art,
      artHeaders: const {'X-Cover': 'test'},
    );
    final item = metadata.item;
    expect(item.title, _song.title);
    expect(item.displayTitle, _song.title);
    expect(item.artist, '当前歌词');
    expect(item.displaySubtitle, '当前歌词');
    expect(item.displayDescription, '仓木麻衣');
    expect(item.album, '专辑');
    expect(item.duration, const Duration(seconds: 244));
    expect(item.artUri, art);
    expect(item.artHeaders, {'X-Cover': 'test'});
    expect(item.extras, isNull);
    expect(metadata.suppressQueueIndex, isTrue);
  });

  test('静态队列条目保持真实歌名和歌手，不携带当前歌词', () {
    for (final onTop in [false, true]) {
      final metadata = buildMediaNotificationMetadata(
        _song,
        current: false,
        isAndroid: true,
        isPlaying: true,
        showLyrics: true,
        lyricOnTop: onTop,
        carLyricsEnabled: true,
        lyricLine: '当前歌词',
        carLyricLine: '车载歌词',
      );
      expect(metadata.item.title, _song.title);
      expect(metadata.item.displayTitle, _song.title);
      expect(metadata.item.artist, '仓木麻衣');
      expect(metadata.item.displaySubtitle, '仓木麻衣');
      expect(metadata.item.extras, isNull);
      expect(metadata.suppressQueueIndex, isFalse);
    }
  });

  test('关闭通知歌词或歌词清空后恢复真实歌手和队列索引', () {
    for (final enabled in [false, true]) {
      final metadata = buildMediaNotificationMetadata(
        _song,
        current: true,
        isAndroid: true,
        isPlaying: true,
        showLyrics: enabled,
        lyricOnTop: false,
        carLyricsEnabled: false,
        lyricLine: enabled ? null : '当前歌词',
        carLyricLine: null,
      );
      expect(metadata.item.title, _song.title);
      expect(metadata.item.artist, '仓木麻衣');
      expect(metadata.item.displaySubtitle, isNull);
      expect(metadata.suppressQueueIndex, isFalse);
    }
  });

  test('歌词首行模式保留歌词标题和歌名歌手副标题', () {
    final metadata = buildMediaNotificationMetadata(
      _song,
      current: true,
      isAndroid: true,
      isPlaying: true,
      showLyrics: true,
      lyricOnTop: true,
      carLyricsEnabled: false,
      lyricLine: '当前歌词',
      carLyricLine: null,
    );
    expect(metadata.item.title, '当前歌词');
    expect(metadata.item.displayTitle, '当前歌词');
    expect(metadata.item.artist, 'Time after time · 仓木麻衣');
    expect(metadata.item.displaySubtitle, 'Time after time · 仓木麻衣');
    expect(metadata.suppressQueueIndex, isTrue);
  });

  test('暂停仍显示通知歌词时不发布与歌词冲突的活动队列索引', () {
    for (final onTop in [false, true]) {
      final metadata = buildMediaNotificationMetadata(
        _song,
        current: true,
        isAndroid: true,
        isPlaying: false,
        showLyrics: true,
        lyricOnTop: onTop,
        carLyricsEnabled: true,
        lyricLine: '当前歌词',
        carLyricLine: '车载歌词',
      );
      expect(metadata.item.title, _song.title);
      expect(metadata.item.displayTitle, onTop ? '当前歌词' : _song.title);
      expect(metadata.item.artist, onTop ? 'Time after time · 仓木麻衣' : '当前歌词');
      expect(metadata.item.extras, isNull);
      expect(metadata.suppressQueueIndex, isTrue);
    }
  });

  test('通知歌词和车载歌词同时开启时各自使用对应字段', () {
    for (final onTop in [false, true]) {
      final metadata = buildMediaNotificationMetadata(
        _song,
        current: true,
        isAndroid: true,
        isPlaying: true,
        showLyrics: true,
        lyricOnTop: onTop,
        carLyricsEnabled: true,
        lyricLine: '通知歌词',
        carLyricLine: '车载歌词',
      );
      expect(metadata.item.title, '车载歌词');
      expect(metadata.item.displayTitle, onTop ? '通知歌词' : _song.title);
      expect(metadata.item.artist, onTop ? 'Time after time · 仓木麻衣' : '通知歌词');
      expect(metadata.item.extras?['android.media.metadata.LYRICS'], '车载歌词');
      expect(metadata.suppressQueueIndex, isTrue);
    }
  });

  test('车载歌词独立开关及暂停回退保持原行为', () {
    for (final playing in [false, true]) {
      final metadata = buildMediaNotificationMetadata(
        _song,
        current: true,
        isAndroid: true,
        isPlaying: playing,
        showLyrics: false,
        lyricOnTop: false,
        carLyricsEnabled: true,
        lyricLine: '通知歌词',
        carLyricLine: '车载歌词',
      );
      expect(metadata.item.title, playing ? '车载歌词' : _song.title);
      expect(metadata.item.displayTitle, _song.title);
      expect(metadata.item.artist, playing ? 'Time after time · 仓木麻衣' : '仓木麻衣');
      expect(metadata.item.displaySubtitle, isNull);
      expect(metadata.suppressQueueIndex, playing);
    }
  });

  test('非 Android 平台保留歌手字段及原有副标题歌词', () {
    final metadata = buildMediaNotificationMetadata(
      _song,
      current: true,
      isAndroid: false,
      isPlaying: true,
      showLyrics: true,
      lyricOnTop: false,
      carLyricsEnabled: false,
      lyricLine: '当前歌词',
      carLyricLine: null,
    );
    expect(metadata.item.title, _song.title);
    expect(metadata.item.artist, '仓木麻衣');
    expect(metadata.item.displaySubtitle, '当前歌词');
    expect(metadata.suppressQueueIndex, isFalse);
  });
}
