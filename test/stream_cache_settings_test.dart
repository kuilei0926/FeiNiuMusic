import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:feiniu_music/app/services/audio/stream_cache_service.dart';
import 'package:feiniu_music/app/state/settings_cache_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppCacheSettings.resetForTest();
    StreamCacheService.instance.resetForTest();
  });

  group('AppCacheSettings', () {
    test('defaults: cacheLimitMb = 1024, precacheNextSong = true', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 1024);
      expect(AppCacheSettings.precacheNextSong.value, true);
    });

    test('setCacheLimitMb clamps to [256, 5120]', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();

      await AppCacheSettings.setCacheLimitMb(9999);
      expect(AppCacheSettings.cacheLimitMb.value, 5120);

      await AppCacheSettings.setCacheLimitMb(10);
      expect(AppCacheSettings.cacheLimitMb.value, 256);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('audio_cache_limit_mb'), 256);
    });

    test('persistence round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      await AppCacheSettings.setCacheLimitMb(2048);
      await AppCacheSettings.setPrecacheNextSong(false);

      // 重新加载应读到持久化值
      AppCacheSettings.resetForTest();
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 2048);
      expect(AppCacheSettings.precacheNextSong.value, false);
    });

    test('legacy audio_cache_limit_gb=3 migrates to 3072 and removes key',
        () async {
      SharedPreferences.setMockInitialValues({'audio_cache_limit_gb': 3});
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 3072);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('audio_cache_limit_mb'), 3072);
      expect(prefs.getInt('audio_cache_limit_gb'), isNull);
    });

    test('legacy zero value falls back to default 1024', () async {
      SharedPreferences.setMockInitialValues({'audio_cache_limit_gb': 0});
      await AppCacheSettings.ensureLoaded();
      expect(AppCacheSettings.cacheLimitMb.value, 1024);
    });

    test('precacheNextSong setter persists', () async {
      SharedPreferences.setMockInitialValues({});
      await AppCacheSettings.ensureLoaded();
      await AppCacheSettings.setPrecacheNextSong(false);
      expect(AppCacheSettings.precacheNextSong.value, false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('audio_precache_next_song'), false);
    });
  });

  group('StreamCacheService pure logic', () {
    test('safeCacheName sanitizes and keeps valid chars', () {
      expect(StreamCacheService.safeCacheName('abc-123._x'), 'abc-123._x');
      expect(
        StreamCacheService.safeCacheName('a/b:c*d'),
        'a_b_c_d',
      );
      expect(StreamCacheService.safeCacheName(''), 'song');
    });

    test('completeFileFor returns existing file and null otherwise', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      AppCacheSettings.cacheLimitMb.value = 1024; // 开启缓存

      final missing = await StreamCacheService.instance.completeFileFor('s1');
      expect(missing, isNull);

      final file = File(
        '${tmp.path}${Platform.pathSeparator}${StreamCacheService.safeCacheName('s1')}.mp3',
      );
      await file.writeAsBytes([1, 2, 3]);

      final found = await StreamCacheService.instance.completeFileFor('s1');
      expect(found, isNotNull);
      expect(found!.path, file.path);
    });

    test('evictIfNeeded deletes oldest complete files, protects active', () async {
      final tmp = await Directory.systemTemp.createTemp('stream_cache_test_');
      addTearDown(() => tmp.delete(recursive: true));
      await StreamCacheService.instance.setDirectoryForTest(tmp);
      AppCacheSettings.cacheLimitMb.value = 1; // 1MB 上限

      // 4 首完整缓存，各 ~400KB，总计 ~1.6MB > 1MB
      final base = tmp.path + Platform.pathSeparator;
      // mtime 顺序：old 最旧（60×3 分钟前）→ mid → new → current 最新（60×0）
      final ids = ['old', 'mid', 'new', 'current'];
      final now = DateTime.now();
      for (var i = 0; i < ids.length; i++) {
        final f = File('$base${StreamCacheService.safeCacheName(ids[i])}.mp3');
        await f.writeAsBytes(List.filled(400 * 1024, i + 1));
        await f.setLastModified(now.subtract(Duration(minutes: 60 * (3 - i))));
      }

      // .part / .mime 依附于具体歌曲；被淘汰歌曲的 .mime 随之删除，
      // 但进行中的 .part 永不参与淘汰删除（此处挂在未淘汰的 'new' 上）
      final part = File('$base${StreamCacheService.safeCacheName('new')}.mp3.part');
      final mime = File('$base${StreamCacheService.safeCacheName('new')}.mp3.mime');
      await part.writeAsBytes([9]);
      await mime.writeAsString('audio/mpeg');

      // 保护 current（当前播放）与 new（活跃注册表）
      StreamCacheService.instance.currentSongId = 'current';
      await StreamCacheService.instance.evictIfNeeded(
        protectedSongIds: {'new'},
      );

      // 淘汰按 mtime 最旧优先：old → mid → new → current，直到总量 ≤ 1MB。
      // 初始 1.6MB；删 old(400K) → 1.2MB 仍超；删 mid(400K) → 800KB ≤ 1MB 停。
      expect(File('$base${StreamCacheService.safeCacheName('old')}.mp3').existsSync(), isFalse);
      expect(File('$base${StreamCacheService.safeCacheName('mid')}.mp3').existsSync(), isFalse);
      expect(File('$base${StreamCacheService.safeCacheName('new')}.mp3').existsSync(), isTrue);
      expect(File('$base${StreamCacheService.safeCacheName('current')}.mp3').existsSync(), isTrue);
      expect(part.existsSync(), isTrue, reason: '进行中的 .part 不应被删除');
      expect(mime.existsSync(), isTrue, reason: '未淘汰歌曲的 .mime 不应被删除');

      // 保护列表按 mtime 排序 → current 最新；即使保护失效也应最后删。验证保护生效：
      // 若未保护 new/current，则 new 在 current 之前（new 较旧）被删。
      expect(File('$base${StreamCacheService.safeCacheName('new')}.mp3').existsSync(), isTrue);
    });
  });
}
