import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'feiniu/api_client.dart';

/// 封面本地缓存共享工具：切歌悬浮窗、灵动岛等原生覆盖层共用。
///
/// 三步策略：
/// 1. 查 flutter_cache_manager（CachedNetworkImage 共用）已有磁盘缓存；
/// 2. 无缓存时经 getSingleFile 下载到缓存池（带认证头）；
/// 3. fallback 下载到独立目录（自签名证书兼容），供原生层和车机封面
///    Provider 读取。
class CoverLocalCache {
  CoverLocalCache._();

  static const String kDirName = 'covers_v2';

  static final DefaultCacheManager _coverCache = DefaultCacheManager();

  static String? _dirPath;
  static Future<String>? _applicationId;

  static Future<String> coverDirPath() async {
    if (_dirPath == null) {
      final dir = await getTemporaryDirectory();
      _dirPath = '${dir.path}/$kDirName';
      await io.Directory(_dirPath!).create(recursive: true);
    }
    return _dirPath!;
  }

  /// Returns a URI that Android Auto and other external media clients can
  /// safely read. The provider only exposes files produced by this cache.
  static Future<Uri?> contentUriForPath(String? localPath) async {
    if (localPath == null || localPath.isEmpty) return null;
    final fileName = path.basename(localPath);
    if (!RegExp(r'^[0-9a-f]{40}\.img$').hasMatch(fileName)) return null;
    final applicationId = await _resolveApplicationId();
    return Uri(
      scheme: 'content',
      host: '$applicationId.coverart',
      pathSegments: <String>[fileName],
    );
  }

  static Future<String?> downloadToLocal(
    String coverId, {
    int? updatedAt,
    int size = 120,
  }) async {
    final target = await _cacheFileFor(
      coverId,
      updatedAt: updatedAt,
      size: size,
    );
    if (await target.exists()) return target.path;

    final url = FeiNiuApiClient.instance.coverUrl(
      coverId,
      size: size,
      updatedAt: updatedAt,
    );
    // 目标尺寸未缓存时，先尝试复用同封面其它已缓存尺寸（App UI 的
    // CachedNetworkImage 与 _coverCache 是同一个 DefaultCacheManager 单例，
    // 播放页/列表页通常已把该封面以某个尺寸下载过）。直接磁盘拷贝，避免
    // 重新向 NAS 请求一个新的尺寸而慢到超时。
    if (await _reuseCachedVariant(coverId, updatedAt, size, target)) {
      return target.path;
    }
    try {
      final cacheObject = await _coverCache.getFileFromCache(url);
      if (cacheObject != null) {
        final f = io.File(cacheObject.file.path);
        if (await f.exists()) return _copyToCoverCache(f, target);
      }
    } catch (error) {
      _debugLog('read cached cover failed: $error');
    }
    try {
      final cacheFile = await _coverCache.getSingleFile(
        url,
        headers: FeiNiuApiClient.imageAuthHeaders(),
      );
      final f = io.File(cacheFile.path);
      if (await f.exists()) return _copyToCoverCache(f, target);
    } catch (error) {
      _debugLog('download cover with cache manager failed: $error');
    }
    try {
      final httpClient = io.HttpClient()
        ..badCertificateCallback = (_, _, _) => true;
      try {
        final request = await httpClient.getUrl(Uri.parse(url));
        if (FeiNiuApiClient.instance.token.isNotEmpty) {
          final headers = FeiNiuApiClient.instance.authHeaders();
          for (final entry in headers.entries) {
            request.headers.set(entry.key, entry.value);
          }
        }
        final response = await request.close();
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          await target.writeAsBytes(bytes, flush: true);
          return target.path;
        }
      } finally {
        httpClient.close(force: true);
      }
    } catch (error) {
      _debugLog('download cover fallback failed: $error');
    }
    return null;
  }

  static Future<io.File> _cacheFileFor(
    String coverId, {
    int? updatedAt,
    int size = 120,
  }) async {
    // size 纳入缓存键：同封面不同尺寸（通知 512px vs 悬浮岛 120px）落在
    // 不同文件，避免先写入的小尺寸文件被大尺寸请求复用。
    final cacheKey = '$coverId:${updatedAt ?? 0}:$size';
    final fileName = '${sha1.convert(utf8.encode(cacheKey))}.img';
    return io.File('${await coverDirPath()}/$fileName');
  }

  static Future<String?> _copyToCoverCache(
    io.File source,
    io.File target,
  ) async {
    try {
      if (!await target.exists()) {
        await source.copy(target.path);
      }
      return target.path;
    } catch (error) {
      _debugLog('copy cover into shared cache failed: $error');
      return null;
    }
  }

  /// 在 flutter_cache_manager 缓存里找同封面其它已缓存尺寸，拷贝进目标槽位。
  /// App UI 的 CachedNetworkImage 与 [_coverCache] 是同一个
  /// DefaultCacheManager 单例，播放页/列表页通常已下载过该封面，直接复用
  /// 磁盘文件可避免向 NAS 重新请求一个新的尺寸（首请求会触发服务端生成，
  /// 可能 >2s 导致媒体卡片封面解析超时）。
  ///
  /// 只接受 >= 256px 的候选：小米图像管线把低分辨率判为 "small resolution"
  /// （JpegXmCodec::isSupported returns false for small resolution），妙播
  /// 媒体卡片不渲染 120px 这种小图；复用 256+ 才保证能显示。
  static Future<bool> _reuseCachedVariant(
    String coverId,
    int? updatedAt,
    int targetSize,
    io.File target,
  ) async {
    // 常见 UI 尺寸（由大到小，优先更大的）。跳过目标尺寸本身（那正缺失）。
    const candidates = <int>[800, 512, 320, 300, 256, 120];
    for (final s in candidates) {
      if (s == targetSize || s < 256) continue;
      final url = FeiNiuApiClient.instance.coverUrl(
        coverId,
        size: s,
        updatedAt: updatedAt,
      );
      try {
        final cacheObject = await _coverCache.getFileFromCache(url);
        if (cacheObject == null) continue;
        final source = io.File(cacheObject.file.path);
        if (await source.exists()) {
          await source.copy(target.path);
          _debugLog('reused cached cover size=$s for target=$targetSize');
          return true;
        }
      } catch (_) {
        // 某个尺寸查缓存失败不影响其它尺寸。
      }
    }
    return false;
  }

  static void _debugLog(String message) {
    debugPrint('[CoverLocalCache] $message');
  }

  static Future<String> _resolveApplicationId() {
    return _applicationId ??= _loadApplicationId();
  }

  static Future<String> _loadApplicationId() async {
    try {
      return (await PackageInfo.fromPlatform()).packageName;
    } catch (_) {
      return 'com.feiniu.music';
    }
  }
}
