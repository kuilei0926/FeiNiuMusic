import 'package:flutter/foundation.dart';

import '../../state/song_state.dart';
import 'api_client.dart';

/// 服务器转码服务（单例）
///
/// 需要服务器转码的格式（DSF/DSD、WMA、APE、DTS、AIFF 等，ExoPlayer 无法
/// 解码）统一转成 **FLAC HLS**（`codec: 'flac'`），交给 media_kit（FFmpeg）
/// 解码。FFmpeg 无 ExoPlayer 的 32KB FLAC 帧缓冲上限，因此**不再**做 fMP4
/// 帧大小探测、**不再**降级 MP3——音质无损。
///
/// 流程（对齐服务器接口）：
/// 1. `GET /track/metadata?guid=<id>` 取 `audioSpec.format` 判断格式；
/// 2. 若需转码，`POST /track/transcode` 取 `data.url`（m3u8 相对路径）；
/// 3. 拼出绝对地址交给 media_kit，m3u8 内 `init.mp4`/分片为相对路径，
///    libmpv 会自动补全，且经 `Media.httpHeaders` 继承 Cookie 认证。
///
/// 转码结果是幂等的（服务器按 guid 转），用 TTL 缓存避免队列重建时
/// 对同一首歌反复请求转码。
class FeiNiuTranscodeService {
  FeiNiuTranscodeService._();

  static final FeiNiuTranscodeService instance = FeiNiuTranscodeService._();

  /// 需服务器转码（本地 ExoPlayer 不支持）的格式黑名单。
  static const Set<String> unsupportedFormats = {
    'dsf', 'dff', 'dsd',
    'wma', 'ape', 'dts',
    'aiff', 'ra', 'au',
    'dvf', 'tta', 'dss', 'mmf',
  };

  /// 交给 media_kit（FFmpeg）解码的格式：需转码的黑名单格式。
  ///
  /// 普通 FLAC **不在此列**——它走 just_audio 直连流（原本就工作、有缓存）。
  /// 仅当 just_audio 解码 FLAC 触发 32KB 帧缓冲上限（`Buffer too small`）时，
  /// 由 PlayerService 运行时升级到 media_kit 解码（见 player_service 的
  /// `_mediaKitEscalateSongIds`）。黑名单格式经服务器转码成 FLAC HLS 后由
  /// media_kit 解码（FFmpeg 无 32KB 限制，且不降级 MP3 保音质）。
  static bool isMediaKitFormat(String format) {
    final f = format.trim().toLowerCase();
    return unsupportedFormats.contains(f);
  }

  static const Duration _ttl = Duration(minutes: 30);

  FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final Map<String, _CachedHls> _cache = {};
  final Map<String, Future<String?>> _formatInflight = {};
  final Map<String, String> _formats = {};

  /// 该格式是否需要在服务器侧转码。
  bool isTranscodeNeeded(String? format) {
    if (format == null || format.isEmpty) return false;
    return unsupportedFormats.contains(format.trim().toLowerCase());
  }

  /// 获取某首歌的**有效格式**：优先 `song.format`（列表接口已带则直接用，
  /// 零网络开销）；为空时先查会话内格式缓存，未命中再请求
  /// `/track/metadata` 确认（DSF/DSD 等曲目在列表接口里常不返回 audioSpec）。
  ///
  /// 返回 null 表示无法确认格式（无需转码 / metadata 失败）。
  Future<String?> resolvedFormatFor(SongEntity song) async {
    final local = song.format;
    if (local != null && local.trim().isNotEmpty) return local.trim();

    final cached = _formats[song.id];
    if (cached != null) return cached;

    // 本歌曲的 metadata 解析去重：并发调用复用同一个在途 Future
    final inflight = _formatInflight[song.id];
    if (inflight != null) return inflight;

    final future = () async {
      try {
        final meta = await _api.trackMetadata(song.id);
        final format = _extractFormat(meta)?.trim();
        if (format != null && format.isNotEmpty) {
          _formats[song.id] = format;
        }
        return format;
      } catch (_) {
        // metadata 失败：无法确认格式 → 按无需转码处理，不阻塞播放
        return null;
      }
    }();
    _formatInflight[song.id] = future;
    future.whenComplete(() => _formatInflight.remove(song.id));
    return future;
  }

  /// 获取某首歌的 **FLAC HLS** 播放绝对地址（交给 media_kit 解码）。
  ///
  /// - 非 media_kit 格式（flac/mp3/aac/…，或 metadata 无法确认）→ 返回 null；
  /// - 转码成功 → 缓存（TTL）并返回绝对 URL；
  /// - 网络异常 / 服务器未返回地址 → 抛异常，由调用方回退直连。
  ///
  /// 仅对黑名单格式（DSF/APE/WMA…）请求 FLAC 转码——无损优先、不降级 MP3。
  /// 普通 FLAC 不转码（just_audio 直连播放）。当 [force] 为 true 时（该歌
  /// 已由 PlayerService 升级到 media_kit，如 just_audio 解码 FLAC 帧超限），
  /// 无视格式强制请求 FLAC 转码。
  Future<String?> hlsUrlForFlac(SongEntity song, {bool force = false}) async {
    final format = await resolvedFormatFor(song);
    if (!force && !isMediaKitFormat(format ?? '')) return null;

    final hit = _cache[song.id];
    if (hit != null && hit.isValid()) return hit.url;

    final rel = await _api.trackTranscode(song.id, codec: 'flac');
    if (rel == null) return null;

    final url = _api.resolveHlsUrl(rel);
    _cache[song.id] = _CachedHls(url, DateTime.now().add(_ttl));
    return url;
  }

  /// 同步读取会话内已缓存的格式（不发起网络请求）。
  /// 用于 [PlayerService] 构建 media_kit 条目时的快速判断。
  String? resolvedFormatForSync(SongEntity song) {
    final local = song.format;
    if (local != null && local.trim().isNotEmpty) return local.trim();
    return _formats[song.id];
  }

  /// 读取已缓存的转码 HLS 地址（不发起网络请求）。未缓存/已过期返回 null。
  String? cachedHlsUrlFor(String songId) {
    final hit = _cache[songId];
    if (hit != null && hit.isValid()) return hit.url;
    return null;
  }

  /// 清除某首歌的转码缓存（播放出错强制刷新时调用）。
  void invalidate(String songId) {
    _cache.remove(songId);
    _formatInflight.remove(songId);
    _formats.remove(songId);
  }

  /// 从 metadata 响应中提取格式（`data.audioSpec.format` 或
  /// `data.track.audioSpec.format`，两者都存在）。
  String? _extractFormat(Map<String, dynamic>? meta) {
    if (meta == null) return null;
    final audioSpec = meta['audioSpec'];
    if (audioSpec is Map<String, dynamic>) {
      final format = audioSpec['format'];
      if (format is String && format.isNotEmpty) return format;
    }
    final track = meta['track'];
    if (track is Map<String, dynamic>) {
      final trackSpec = track['audioSpec'];
      if (trackSpec is Map<String, dynamic>) {
        final format = trackSpec['format'];
        if (format is String && format.isNotEmpty) return format;
      }
    }
    return null;
  }

  @visibleForTesting
  void setApiForTest(FeiNiuApiClient api) => _api = api;

  @visibleForTesting
  void clearCacheForTest() {
    _cache.clear();
    _formatInflight.clear();
    _formats.clear();
  }

  @visibleForTesting
  void resetForTest() {
    _api = FeiNiuApiClient.instance;
    _cache.clear();
    _formatInflight.clear();
    _formats.clear();
  }
}

/// 转码缓存项：HLS 地址 + 过期时间。
class _CachedHls {
  final String url;
  final DateTime expiresAt;

  _CachedHls(this.url, this.expiresAt);

  bool isValid() => DateTime.now().isBefore(expiresAt);
}
