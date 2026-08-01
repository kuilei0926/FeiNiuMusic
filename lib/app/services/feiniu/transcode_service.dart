import 'package:flutter/foundation.dart';

import '../../state/song_state.dart';
import 'api_client.dart';
import 'fmp4_flac_probe.dart';

/// 服务器转码服务（单例）
///
/// 本地播放器（ExoPlayer）无法解码部分服务器支持的格式
/// （如 DSF/DSD、WMA、APE、DTS、AIFF 等），直接播放 `/track/stream`
/// 会报解码错误。此时向服务器请求转码，把音频转成 HLS（m3u8）流播放。
///
/// 流程（对齐服务器接口）：
/// 1. `GET /track/metadata?guid=<id>` 取 `audioSpec.format` 判断格式；
/// 2. 若需转码，`POST /track/transcode` 取 `data.url`（m3u8 相对路径）；
/// 3. 拼出绝对地址交给播放器，m3u8 内 `init.mp4`/分片为相对路径，
///    ExoPlayer 会自动补全。
///
/// 转码结果是幂等的（服务器按 guid 转），用 TTL 缓存避免队列重建时
/// 对同一首歌反复请求转码。
///
/// FLAC 帧可能超出 Android 平台解码器输入缓冲上限（32KB，`c2.android
/// .flac.decoder`）。为保留"无损优先"，默认仍请求 FLAC，但在**播放前**
/// 探测其 fMP4 分片里的最大单帧大小：接近/超过上限（[flacProbeThreshold]，
/// 为后续分片波动留余量）即当场降级为 MP3 重新请求，避免首播先崩一次；
/// 探测失败则保持 FLAC，由 player_service 的解码错误兜底降级。
class FeiNiuTranscodeService {
  FeiNiuTranscodeService._();

  static final FeiNiuTranscodeService instance = FeiNiuTranscodeService._();

  /// Android 平台 FLAC 解码器输入缓冲上限（MediaCodec 32KB）。
  /// 单帧（一个 FLAC 块）超过该值即会触发 `Buffer too small` 崩溃，
  /// 需要在播放前降级。
  static const int maxFlacFrameBytes = 32 * 1024;

  /// 探测降级的余量系数：探测只抓了**第一个分片**，FLAC 帧大小随内容
  /// 波动（安静段压缩小、爆音/高频段压缩大），首分片的最大帧不代表后面
  /// 某个分片不会更大。因此用 [maxFlacFrameBytes] 的该比例作为阈值，
  /// **接近上限就提前降级**，避免后续分片出现超限帧导致播放中途崩溃。
  static const double flacProbeThresholdRatio = 0.80;

  /// 探测降级的帧大小阈值（接近上限的余量值）。首分片最大帧达到该值
  /// 即判定为有超限风险而降级 MP3。
  static int get flacProbeThreshold =>
      (maxFlacFrameBytes * flacProbeThresholdRatio).round();

  /// 本地解码不支持的格式（黑名单）。只转明确不支持的，
  /// 避免 FLAC/MP3/OGG/WAV/M4A/AAC 等常见格式被转码而丢失直连与缓存。
  static const Set<String> unsupportedFormats = {
    'dsf', 'dff', 'dsd',
    'wma', 'ape', 'dts',
    'aiff', 'ra', 'au',
    'dvf', 'tta', 'dss', 'mmf',
  };

  static const Duration _ttl = Duration(minutes: 30);

  FeiNiuApiClient _api = FeiNiuApiClient.instance;
  final Map<String, _CachedHls> _cache = {};
  final Map<String, Future<String?>> _formatInflight = {};
  final Map<String, String> _formats = {};

  /// 已降级到 MP3 转码的歌曲（FLAC 帧超出解码器能力，见 player_service
  /// 的 `_handlePlayerError`）。降级后 `hlsUrlFor` 直接请求 MP3，不再
  /// 尝试 FLAC；且不会随 `invalidate` 被清除，避免每次重播都先崩一次。
  final Set<String> _mp3Degraded = {};

  /// 该歌曲是否已降级为 MP3 转码（解码超限的安全处理）。
  bool isDegradedToMp3(String songId) => _mp3Degraded.contains(songId);

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

  /// 获取某首歌的 HLS 播放绝对地址。
  ///
  /// - 有效格式无需转码（或 metadata 无法确认）→ 返回 null；
  /// - 转码成功 → 缓存（TTL）并返回绝对 URL；
  /// - 网络异常 / 服务器未返回地址 → 抛异常，由调用方回退直连。
  ///
  /// FLAC（默认无损优先）：若服务器转出的流单帧**接近或超出**解码器
  /// 能力（首分片最大帧 ≥ [flacProbeThreshold]，为后续分片波动留余量），
  /// 播放前探测到后当场降级为 MP3 重新请求，避免首播先崩一次。
  /// 该歌曲已降级（见 [degradeToMp3]）时直接请求 MP3。
  Future<String?> hlsUrlFor(SongEntity song) async {
    final format = await resolvedFormatFor(song);
    if (!isTranscodeNeeded(format)) return null;

    final hit = _cache[song.id];
    if (hit != null && hit.isValid()) return hit.url;

    final alreadyDegraded = _mp3Degraded.contains(song.id);
    if (!alreadyDegraded) {
      // 无损优先：先请求 FLAC，若探测到单帧超限则当场降级 MP3
      final flacUrl = await _requestFlacAndProbe(song);
      if (flacUrl != null) return flacUrl;
    }

    // 已降级 / FLAC 探测超限降级 / FLAC 请求失败
    final rel = await _api.trackTranscode(song.id, codec: 'mp3');
    if (rel == null) return null;

    final url = _api.resolveHlsUrl(rel);
    _cache[song.id] = _CachedHls(url, DateTime.now().add(_ttl));
    if (kDebugMode) {
      debugPrint('[Transcode] ${song.title} → $url (mp3)');
    }
    return url;
  }

  /// 请求 FLAC 转码并探测其分片单帧大小。
  ///
  /// 返回 FLAC 的绝对 URL（首分片最大帧未接近上限）；若探测到**接近/
  /// 超出**解码器上限则内部降级为 MP3 并重新请求，返回 MP3 的 URL。
  /// 返回 null 表示 FLAC 未返回地址 / 探测接近或超限（上层改用 MP3）；
  /// 网络异常直接抛出，由调用方回退直连。
  Future<String?> _requestFlacAndProbe(SongEntity song) async {
    final rel = await _api.trackTranscode(song.id, codec: 'flac');
    if (rel == null) return null;

    final flacUrl = _api.resolveHlsUrl(rel);
    final needsMp3 = await _probeFlacTooLarge(flacUrl);
    if (needsMp3) {
      _mp3Degraded.add(song.id);
      _cache.remove(song.id); // 不缓存超限的 FLAC 地址
      if (kDebugMode) {
        debugPrint(
          '[Transcode] ${song.title} FLAC frame exceeds $maxFlacFrameBytes B, '
          'degrade to mp3',
        );
      }
      return null;
    }

    _cache[song.id] = _CachedHls(flacUrl, DateTime.now().add(_ttl));
    if (kDebugMode) {
      debugPrint('[Transcode] ${song.title} → $flacUrl (flac)');
    }
    return flacUrl;
  }

  /// 探测 FLAC HLS 流的第一个媒体分片，返回最大单帧是否**接近/超过**
  /// 解码器上限。
  ///
  /// 用 [flacProbeThreshold]（上限的 80%）而非硬上限 [maxFlacFrameBytes]：
  /// 首分片接近上限即提前降级，为后续分片留出余量（帧大小随内容波动，
  /// 后续可能出现更大的帧）。返回 false 表示未接近上限 / 探测失败
  /// （无法确认则不降级，保持无损，由解码错误兜底）。探测失败只在
  /// debug 打日志，不抛异常。
  Future<bool> _probeFlacTooLarge(String m3u8Url) async {
    try {
      final m3u8 = await _api.fetchM3u8Text(m3u8Url);
      if (m3u8 == null) return false;
      final mediaUri = firstMediaSegment(m3u8, m3u8Url);
      if (mediaUri == null) return false;
      final bytes = await _api.fetchBytes(mediaUri);
      if (bytes == null || bytes.isEmpty) return false;
      final sizes = fmp4SampleSizes(bytes);
      if (sizes == null || sizes.isEmpty) return false;
      final maxFrame = sizes.reduce((a, b) => a > b ? a : b);
      if (kDebugMode) {
        debugPrint(
          '[Transcode] probe max FLAC frame $maxFrame B '
          '(threshold $flacProbeThreshold B, hard limit $maxFlacFrameBytes B)',
        );
      }
      return maxFrame >= flacProbeThreshold;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Transcode] probe failed for $m3u8Url: $e');
      }
      return false;
    }
  }

  /// 从 m3u8 文本提取第一个媒体分片地址。
  ///
  /// 跳过 `#EXT-X-MAP`（init.mp4，无音频 sample 大小信息）与
  /// `#EXTINF` 时长为 0 的占位段。相对地址按 m3u8 所在地址解析。
  @visibleForTesting
  String? firstMediaSegment(String m3u8, String m3u8Url) {
    final lines = m3u8.split('\n').map((l) => l.trim()).toList();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty || line.startsWith('#EXTINF') || line.startsWith('#EXT-X-MAP')) {
        continue;
      }
      if (line.startsWith('#')) continue;
      if (line == '.mp4' || line == 'init.mp4') continue;
      return Uri.parse(m3u8Url).resolve(line).toString();
    }
    return null;
  }

  /// 将该歌曲降级为 MP3 转码（解码超限时的安全处理）。
  ///
  /// 仅当该歌曲当前未被降级时才标记，避免重复触发重建；
  /// 同时清掉已缓存的 FLAC 转码地址，保证下次请求走 MP3。
  /// 降级标记在会话内持续生效，不会随 [invalidate] 清除。
  void degradeToMp3(String songId) {
    if (_mp3Degraded.add(songId)) {
      _cache.remove(songId);
    }
  }

  /// 清除某首歌的转码缓存（播放出错强制刷新时调用）。
  ///
  /// 仅清缓存与格式解析，**不**清除 MP3 降级标记——解码超限的歌曲
  /// 降级后应持续走 MP3，避免每次重播都先崩一次。
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
    _mp3Degraded.clear();
  }

  @visibleForTesting
  void resetForTest() {
    _api = FeiNiuApiClient.instance;
    _cache.clear();
    _formatInflight.clear();
    _formats.clear();
    _mp3Degraded.clear();
  }
}

/// 转码缓存项：HLS 地址 + 过期时间。
class _CachedHls {
  final String url;
  final DateTime expiresAt;

  _CachedHls(this.url, this.expiresAt);

  bool isValid() => DateTime.now().isBefore(expiresAt);
}
