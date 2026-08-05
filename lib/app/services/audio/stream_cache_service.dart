import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../feiniu/api_client.dart';
import '../feiniu/transcode_service.dart';
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

  /// 兜底扩展名（无法确认格式时的默认后缀）。
  static const String defaultExtension = 'mp3';

  /// 会话内已确认的格式 → 扩展名缓存（避免反复解析格式）。
  final Map<String, String> _formatExtensions = {};

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
    await _resolveDir();
    await _cleanupStaleParts(_dir!);
    await evictIfNeeded();
    return _dir!;
  }

  /// 仅解析缓存目录（含建目录），不做任何扫描/淘汰维护。
  ///
  /// `completeFileFor` 等「只想命中已有缓存文件」的路径用它：启动秒播
  /// 关键路径避免每次构建源都全量 `evictIfNeeded` 拖慢首音；扫描/淘汰
  /// 推迟到首次真实下载/写入（`sourceForSong` 走 [_ensureDir]）之前。
  Future<Directory> _resolveDir() async {
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
    _formatExtensions.clear();
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

  /// 缓存文件后缀：随歌曲实际格式（避免 ExoPlayer/mpv 按 `.mp3` 扩展名
  /// 误判 FLAC/DSF 内容为 MP3 而无法识别）。
  ///
  /// 优先读歌曲自带的 `format`；为空时查会话内已解析缓存；仍为空则按
  /// MIME 映射；最终兜底 [defaultExtension]。
  Future<String> extensionForSong(SongEntity song) async {
    final cached = _formatExtensions[song.id];
    if (cached != null) return cached;

    var ext = _extensionForFormat(song.format);
    if (ext == null) {
      final fmt = await FeiNiuTranscodeService.instance.resolvedFormatFor(song);
      if (fmt != null && fmt.trim().isNotEmpty) {
        ext = _extensionForFormat(fmt);
      }
    }

    // 仍无法确认格式：按下载时记录的 Content-Type 回退映射（轻量，不出网）。
    final extFinal = ext ?? await _extensionFromMime(song.id);
    _formatExtensions[song.id] = extFinal;
    return extFinal;
  }

  /// 同步读缓存文件后缀（不解析格式/不出网；未知返回 null）。
  String? extensionForSongSync(SongEntity song) {
    final cached = _formatExtensions[song.id];
    if (cached != null) return cached;
    final ext = _extensionForFormat(song.format) ?? _extensionForFormat(
      FeiNiuTranscodeService.instance.resolvedFormatForSync(song),
    );
    if (ext != null) _formatExtensions[song.id] = ext;
    return ext;
  }

  static String? _extensionForFormat(String? format) {
    final f = format?.trim().toLowerCase();
    if (f == null || f.isEmpty) return null;
    // 已知容器格式 → 对应扩展名；未知格式（如 "lossless"/"hires"）→ null
    const map = <String, String>{
      'mp3': 'mp3',
      'mpeg': 'mp3',
      'm4a': 'm4a',
      'aac': 'aac',
      'ogg': 'ogg',
      'oga': 'ogg',
      'opus': 'ogg',
      'flac': 'flac',
      'wav': 'wav',
      'dsf': 'dsf',
      'dff': 'dff',
      'dsd': 'dsf',
      'ape': 'ape',
      'wma': 'wma',
      'aiff': 'aiff',
      'aif': 'aiff',
      'dts': 'dts',
    };
    return map[f];
  }

  static String? _extensionForMime(String mime) {
    final m = mime.trim().toLowerCase();
    if (m.contains('flac')) return 'flac';
    if (m.contains('mp3') || m.contains('mpeg')) return 'mp3';
    if (m.contains('m4a') || m.contains('aac') || m.contains('mp4')) return 'm4a';
    if (m.contains('ogg')) return 'ogg';
    if (m.contains('wav') || m.contains('wave')) return 'wav';
    if (m.contains('dsd') || m.contains('dsf')) return 'dsf';
    if (m.contains('wma')) return 'wma';
    if (m.contains('ape')) return 'ape';
    return null;
  }

  Future<String> _extensionFromMime(String songId) async {
    try {
      await _resolveDir();
      final mimeFile = File('${_cacheFileBaseFor(songId)}.mime');
      if (await mimeFile.exists()) {
        final mime = await mimeFile.readAsString();
        final ext = _extensionForMime(mime);
        if (ext != null) return ext;
      }
    } catch (_) {}
    return defaultExtension;
  }

  /// 缓存文件主名（`${safeCacheName}.<ext>`）。
  File _cacheFileFor(String songId, String ext) {
    final base = _dir?.path ?? '';
    return File(p.join(base, '${safeCacheName(songId)}.$ext'));
  }

  /// 无后缀的基础路径（用于 .part/.mime 等旁路文件）。
  String _cacheFileBaseFor(String songId) {
    final base = _dir?.path ?? '';
    return p.join(base, '${safeCacheName(songId)}.mp3');
  }

  /// 完整缓存文件（存在则返回，供播放走 `AudioSource.file` 秒播）。
  ///
  /// 轻量路径：先解析目录（不扫描/不淘汰），直接查 `existsSync()`——
  /// 缓存命中是启动秒播的关键路径，避免每次构建源都全量 `evictIfNeeded`
  /// 拖慢首音。目录扫描/淘汰由 [_ensureDir] 在首次真实下载/写入前执行。
  ///
  /// [ext] 指定扩展名（默认按歌曲格式动态解析）；历史缓存为 `.mp3` 后缀
  /// 时自动兼容（新下载统一按实际格式后缀命名）。
  Future<File?> completeFileFor(
    String songId, {
    SongEntity? song,
    String? ext,
  }) async {
    if (!isEnabled) return null;
    await _resolveDir();
    final resolved = ext ??
        (song != null ? await extensionForSong(song) : defaultExtension);
    final file = _cacheFileFor(songId, resolved);
    if (await file.exists()) return file;
    // 兼容历史 `.mp3` 后缀缓存（改名前的旧文件）
    if (resolved != 'mp3') {
      final legacy = _cacheFileFor(songId, 'mp3');
      if (await legacy.exists()) return legacy;
    }
    return null;
  }

  /// 获取（或创建）某首歌的缓存源。播放器与预缓存器共享同一实例。
  Future<StreamAudioCacheSource> sourceForSong(SongEntity song) async {
    final existing = _sources[song.id];
    if (existing != null) return existing;

    await _ensureDir();
    final ext = await extensionForSong(song);
    final source = StreamAudioCacheSource(
      songId: song.id,
      uri: Uri.parse(FeiNiuApiClient.instance.streamUrl(song.id)),
      headers: FeiNiuApiClient.imageAuthHeaders(),
      cacheFile: _cacheFileFor(song.id, ext),
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
    final base = _cacheFileBaseFor(songId);
    final candidates = <File>[
      File(base),
      File('$base.part'),
      File('$base.mime'),
    ];
    // 历史/其它后缀的完整文件也一并清除
    for (final ext in ['mp3', 'flac', 'm4a', 'ogg', 'wav', 'dsf', 'dff', 'ape', 'wma', 'aiff', 'dts']) {
      final f = File(_cacheFileFor(songId, ext).path);
      if (!candidates.contains(f)) candidates.add(f);
    }
    for (final f in candidates) {
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
  Future<void> waitForComplete(
    String songId, {
    SongEntity? song,
  }) async {
    if (!isEnabled) return;
    if (await completeFileFor(songId, song: song) != null) return;
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
    // 目录未初始化（从未下载过）无需扫描/淘汰
    if (dir == null) return;

    final limitBytes = AppCacheSettings.cacheLimitMb.value * 1024 * 1024;

    final protected = <String>{
      if (currentSongId != null) safeCacheName(currentSongId!),
      for (final id in _sources.keys) safeCacheName(id),
      for (final id in protectedSongIds ?? const <String>{}) safeCacheName(id),
    };

    // 非完整缓存（.part/.mime 旁路文件）不参与上限统计
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
        final stem = _stemFromCacheName(name); // 去扩展名
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
      final stem = _stemFromCacheName(p.basename(file.path));
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

  /// 从缓存文件名剥离扩展名，得到 songId 净化名（`<name>.mp3`/`<name>.flac`…）。
  /// 兼容未知后缀（截掉最后一个 `.` 之后部分）。
  static String _stemFromCacheName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
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
