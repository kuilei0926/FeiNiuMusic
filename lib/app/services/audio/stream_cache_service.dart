import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../feiniu/api_client.dart';
import '../../state/settings_cache_state.dart';
import '../../state/song_state.dart';
import 'cache_source.dart';

/// 音频流缓存管理器 —— 注册表 + 上限淘汰
///
/// - 缓存目录：`getApplicationSupportDirectory()/stream_cache/`（app-support，
///   不会被系统临时清理器清掉）。
/// - 注册表 `Map<songId, StreamAudioCacheSource>`：播放器与预缓存器**共享同一实例**，
///   保证每个缓存文件只有一个下载循环。
/// - 淘汰：总量超限时按 mtime 删最旧**完整文件**，直到 ≤ 上限。保护当前播放歌曲与
///   所有活跃下载（注册表键）；绝不删除 `.part`（进行中）与 `.mime`（元数据）。
class StreamCacheService {
  static final StreamCacheService instance = StreamCacheService._internal();

  static const String dirName = 'stream_cache';

  final Map<String, StreamAudioCacheSource> _sources = {};
  Directory? _dir;
  Future<void>? _initFuture;

  /// 当前播放歌曲 id —— 由 PlayerService 每次切歌时设置（避免服务间循环依赖）。
  String? currentSongId;

  StreamCacheService._internal() {
    AppCacheSettings.cacheLimitMb.addListener(_onLimitChanged);
  }

  /// 缓存是否开启（本方案缓存始终开启，默认 1GB 上限；`> 0` 即为开启）
  bool get isEnabled => AppCacheSettings.cacheLimitMb.value > 0;

  Future<Directory> _ensureDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final inFlight = _initFuture;
    if (inFlight != null) {
      await inFlight;
      return _dir!;
    }
    final future = () async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, dirName));
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      await _cleanupStaleParts(dir);
      await evictIfNeeded();
    }();
    _initFuture = future;
    await future;
    return _dir!;
  }

  /// 测试用：注入缓存目录，跳过 getApplicationSupportDirectory 插件调用
  @visibleForTesting
  Future<void> setDirectoryForTest(Directory dir) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    _initFuture = Future<void>.value();
  }

  @visibleForTesting
  void resetForTest() {
    _sources.clear();
    _dir = null;
    _initFuture = null;
    currentSongId = null;
  }

  /// 净化 songId 为合法文件名片段
  @visibleForTesting
  static String safeCacheName(String songId) {
    final cleaned = songId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'song' : cleaned;
  }

  File _cacheFileFor(String songId) {
    // 生产环境用 _dir（_ensureDir 已解析）；测试环境 _dir 也被 setDirectoryForTest 注入
    final base = _dir?.path ?? '';
    return File(p.join(base, '${safeCacheName(songId)}.mp3'));
  }

  /// 完整缓存文件（存在则返回，供播放走 `AudioSource.file` 秒播）
  Future<File?> completeFileFor(String songId) async {
    if (!isEnabled) return null;
    await _ensureDir();
    final file = _cacheFileFor(songId);
    if (await file.exists()) return file;
    return null;
  }

  /// 获取（或创建）某首歌的缓存源。播放器与预缓存器共享同一实例。
  Future<StreamAudioCacheSource> sourceForSong(SongEntity song) async {
    final existing = _sources[song.id];
    if (existing != null) return existing;

    await _ensureDir();
    final source = StreamAudioCacheSource(
      songId: song.id,
      uri: Uri.parse(FeiNiuApiClient.instance.streamUrl(song.id)),
      headers: FeiNiuApiClient.imageAuthHeaders(),
      cacheFile: _cacheFileFor(song.id),
    );
    _sources[song.id] = source;
    // 下载完成（无论成败）后移出注册表并尝试淘汰
    unawaited(source.downloadDone.then(
      (_) => _onSourceFinished(song.id),
      onError: (_) => _onSourceFinished(song.id),
    ));
    return source;
  }

  void _onSourceFinished(String songId) {
    _sources.remove(songId);
    unawaited(evictIfNeeded());
  }

  /// 删除某首歌的缓存（完整文件 + .part + .mime），用于播放出错后的强制刷新
  Future<void> invalidate(String songId) async {
    await _ensureDir();
    _sources.remove(songId);
    final file = _cacheFileFor(songId);
    for (final f in [file, File('${file.path}.part'), File('${file.path}.mime')]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 预缓存一首歌（fire-and-forget 后台下载）。
  /// 不触播放器、不调 reportTrackPlay —— 播放上报只在歌曲成为 current 时触发。
  void precacheSong(SongEntity song) {
    if (!isEnabled || !AppCacheSettings.precacheNextSong.value) return;
    unawaited(_precacheSongAsync(song));
  }

  Future<void> _precacheSongAsync(SongEntity song) async {
    try {
      final source = await sourceForSong(song);
      if (source.isComplete) return;
      await source.precache();
    } catch (_) {
      // 预缓存失败静默忽略（不影响播放）
    }
  }

  /// 链式预缓存的等待节点：等待某首歌缓存下载完成。
  /// 已完整 → 立即返回；有在途下载 → join；无下载 → 返回（链不启动）。
  Future<void> waitForComplete(String songId) async {
    if (!isEnabled) return;
    if (await completeFileFor(songId) != null) return;
    final source = _sources[songId];
    if (source == null) return;
    try {
      await source.precache();
    } catch (_) {
      // 下载失败不阻断链
    }
  }

  /// 上限淘汰：总量超限时删最旧完整文件直到 ≤ 上限。
  Future<void> evictIfNeeded({Set<String>? protectedSongIds}) async {
    if (!isEnabled) return;
    final dir = _dir;
    if (dir == null) return;

    final limitBytes = AppCacheSettings.cacheLimitMb.value * 1024 * 1024;

    final protected = <String>{
      if (currentSongId != null) safeCacheName(currentSongId!),
      for (final id in _sources.keys) safeCacheName(id),
      for (final id in protectedSongIds ?? const <String>{}) safeCacheName(id),
    };

    final entries = <File>[];
    int total = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.endsWith('.part') || name.endsWith('.mime')) continue;
        try {
          total += await entity.length();
        } catch (_) {
          continue;
        }
        final stem = name.substring(0, name.length - 4); // 去 .mp3
        if (protected.contains(stem)) continue;
        entries.add(entity);
      }
    } catch (_) {}

    if (total <= limitBytes) return;

    entries.sort((a, b) {
      int compare(a, b) {
        try {
          return a.statSync().modified
              .compareTo(b.statSync().modified);
        } catch (_) {
          return 0;
        }
      }
      return compare(a, b);
    });

    for (final file in entries) {
      if (total <= limitBytes) break;
      final stem = p.basename(file.path).replaceFirst(RegExp(r'\.mp3$'), '');
      try {
        total -= await file.length();
        await file.delete();
        // 顺带删除 .mime 旁路文件
        final mime = File('${file.path}.mime');
        if (await mime.exists()) await mime.delete();
        _sources.removeWhere(
          (id, _) => safeCacheName(id) == stem,
        );
      } catch (_) {
        // Windows 打开中的文件删除会失败，静默跳过
      }
    }
  }

  void _onLimitChanged() {
    unawaited(evictIfNeeded());
  }

  /// 清理崩溃残留的 `.part` 临时文件
  Future<void> _cleanupStaleParts(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.part')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 缓存总大小（字节）
  Future<int> totalSize() async {
    try {
      await _ensureDir();
      int total = 0;
      await for (final f in _dir!.list(recursive: true, followLinks: false)) {
        if (f is File) total += await f.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空全部音频缓存（保留目录本身）
  Future<void> clearAll() async {
    try {
      await _ensureDir();
      _sources.clear();
      await for (final entity in _dir!.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
