import 'package:flutter/foundation.dart';

import '../network_connection_service.dart';
import '../../state/settings_transcode_state.dart';
import '../../state/song_state.dart';
import 'api_client.dart';

/// 服务器转码服务（单例）。
///
/// 功能：
/// - **格式解析**（`resolvedFormatFor` / `resolvedCodecFor` / `resolvedSizeFor`）：
///   判断某首歌是否需 media_kit、文件大小是否超阈值（大文件转码判定）。
/// - **转码 HLS**（`transcodeHlsUrlFor`）：对需转码的歌请求服务器转码，返回
///   m3u8 绝对地址，按 `songId|codec` 缓存（TTL），并跟踪活动会话
///   （`activeTranscodeIds`）供切歌/停止时 quit 释放。
/// - **降级**（`markDowngradeToMp3`）：flac 转码 ExoPlayer 解析失败时降级 mp3
///   重新转码。
///
/// 说明：**转码 HLS 只喂 just_audio**（ExoPlayer）。media_kit 的 mpv FFmpeg
/// 音频库（`media_kit_libs_audio`）未编入 hls demuxer，播不了 fMP4 HLS。
///
/// 历史流程：DSF/DSD/WMA/APE/DTS/AIFF 等（ExoPlayer 无法解码）统一转成
/// FLAC HLS（`codec: 'flac'`）交给 media_kit 解码。现已改为 media_kit 直连
/// 原始流，`hlsUrlForFlac` 保留仅供测试。
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

  /// 交给 media_kit（FFmpeg）解码的格式：黑名单格式（DSF/APE/WMA…）。
  ///
  /// 普通 FLAC **不在此列**——它走 just_audio 直连流（原本就工作、有缓存）。
  /// 仅当 just_audio 解码 FLAC 触发 32KB 帧缓冲上限（`Buffer too small`）时，
  /// 由 PlayerService 运行时升级到 media_kit 解码（见 player_service 的
  /// `_mediaKitEscalateSongIds`）。
  static bool isMediaKitFormat(String format) {
    final f = format.trim().toLowerCase();
    return unsupportedFormats.contains(f);
  }

  /// 交给 media_kit（FFmpeg）解码的**编码**黑名单：M4A/MP4 容器内常见的
  /// 环绕声/无损编码。ExoPlayer 的设备解码器（MediaCodec）对这些 codec 的
  /// 支持因设备而异：解码器不可用/静默失败时，进度条照常走但无声音。
  /// FFmpeg 全部原生解码，交给 media_kit 必定出声。
  ///
  /// `eac3`/`ac3`：杜比数字（Plus）；`alac`：Apple 无损；`dts`/`truehd`/`mlp`：
  /// 家庭影院环绕编码。
  static const Set<String> mediaKitCodecs = {
    'eac3', 'ac3', 'alac', 'dts', 'truehd', 'mlp',
  };

  /// codec 是否为 media_kit 专属（ExoPlayer 设备解码不可靠）。
  static bool isMediaKitCodec(String? codec) {
    if (codec == null || codec.isEmpty) return false;
    return mediaKitCodecs.contains(codec.trim().toLowerCase());
  }

  /// 可能内嵌风险 codec（EAC3/ALAC…）的容器格式。codec 未知（null）时，
  /// 这些容器需要无声看门狗兜底。
  static const Set<String> riskySilenceContainers = {
    'm4a', 'm4b', 'm4p', 'mp4', 'aac', 'mov', '3gp', 'mka', 'mkv',
  };

  /// 容器是否可能内嵌风险 codec（codec 未知时据此判断是否需要看门狗）。
  static bool isRiskySilenceContainer(String? format) {
    if (format == null || format.isEmpty) return false;
    return riskySilenceContainers.contains(format.trim().toLowerCase());
  }

  /// 无损源格式（质量层 3）。
  ///
  /// 用于「禁止向上转码」：把有损源（mp3/aac/opus…）转成 flac 等无损格式
  /// 纯属浪费服务器带宽，直接直连原始流即可；无损→无损（wav→flac 等）也
  /// 无压缩收益，一律直连。
  static const Set<String> losslessFormats = {
    'flac', 'wav', 'alac', 'ape', 'aiff', 'aif',
    'dsf', 'dff', 'dsd', 'dts', 'truehd', 'mlp',
    'tta', 'wv', 'wavpack', 'shn', 'tak', 'ofr', 'wmal',
  };

  /// 有损「现代」源格式（质量层 2）：opus/ogg/aac/m4a 等，效率高于 mp3。
  static const Set<String> modernLossyFormats = {
    'opus', 'ogg', 'oga', 'aac', 'm4a', 'm4b', 'm4p', 'mp4',
    'webm', 'ac3', 'eac3',
  };

  /// 有损「传统」源格式（质量层 1）：mp3/wma 等。
  static const Set<String> legacyLossyFormats = {
    'mp3', 'mp2', 'mp1', 'wma', 'wmv', 'ra', 'au', 'dvf', 'dss', 'mmf', 'amr',
  };

  /// 无损 codec（质量层 3）：alac/truehd/mlp 等常内嵌在 m4a/mp4 有损容器里，
  /// 需按 codec 判定源质量，不能只看容器格式。
  static const Set<String> losslessCodecs = {
    'flac', 'alac', 'ape', 'wavpack', 'wv', 'dsd', 'dts', 'truehd', 'mlp',
    'tta', 'shn', 'tak', 'ofr', 'pcm', 'lpcm', 'wmal',
  };

  /// 有损 codec（质量层 2/1）。
  static const Set<String> lossyCodecs = {
    'mp3', 'mp2', 'mp1', 'aac', 'ac3', 'eac3', 'opus', 'vorbis', 'ogg',
    'wma', 'wmav1', 'wmav2', 'amr', 'adpcm', 'g711', 'speex', 'nellymoser',
  };

  /// 源格式质量层：3=无损，2=有损现代，1=有损传统，0=未知（不拦截）。
  ///
  /// codec 优先（alac 在 m4a 容器里也是无损）；codec 未知时回落到 format。
  static int sourceQualityTier(String? format, {String? codec}) {
    if (codec != null && codec.isNotEmpty) {
      final c = codec.trim().toLowerCase();
      if (losslessCodecs.contains(c)) return 3;
      if (lossyCodecs.contains(c)) return 2;
    }
    if (format == null || format.isEmpty) return 0;
    final f = format.trim().toLowerCase();
    if (losslessFormats.contains(f)) return 3;
    if (modernLossyFormats.contains(f)) return 2;
    if (legacyLossyFormats.contains(f)) return 1;
    return 0;
  }

  /// 转码输出格式质量层：flac=3，opus=2，mp3=1。
  static int targetQualityTier(String codec) {
    switch (codec.trim().toLowerCase()) {
      case 'flac':
        return 3;
      case 'opus':
        return 2;
      case 'mp3':
        return 1;
      default:
        return 0;
    }
  }

  /// 把 [sourceFormat]（含可选 [sourceCodec]）转成 [targetCodec] 是否属于
  /// **真降级**（输出质量层严格低于源 → 转码才有压缩收益）。
  ///
  /// - 目标 flac（无损）恒不满足：有损源转 flac 是向上转码（mp3→flac 浪费），
  ///   无损源转 flac 也无收益 → 一律直连；
  /// - 源/目标质量层任一未知 → 返回 true（不拦截，保持现状：未知格式仍按
  ///   大小阈值等既有逻辑转码）。
  static bool isDownscaleTranscode(
    String? sourceFormat,
    String? sourceCodec,
    String targetCodec,
  ) {
    final src = sourceQualityTier(sourceFormat, codec: sourceCodec);
    final dst = targetQualityTier(targetCodec);
    if (src == 0 || dst == 0) return true;
    return dst < src;
  }

  static const Duration _ttl = Duration(minutes: 30);

  FeiNiuApiClient _api = FeiNiuApiClient.instance;

  /// 转码 HLS 地址缓存，key = `songId|codec`（按格式分 key，改格式不串缓存）。
  final Map<String, _CachedHls> _cache = {};
  final Map<String, Future<Map<String, dynamic>?>> _formatInflight = {};
  final Map<String, String> _formats = {};
  final Map<String, String> _codecs = {};

  /// 会话内已解析的文件大小（字节）。
  final Map<String, int> _sizes = {};

  /// 当前活动转码会话（服务端正在转码的 guid）。
  final Set<String> _activeIds = {};

  /// 已降级到 mp3 的歌（flac 转码解析失败后，本会话不再尝试 flac）。
  final Set<String> _downgradedToMp3 = {};

  /// 歌曲信息面板手动指定的「强制转码」codec（会话级，key = songId）。
  ///
  /// 与全局「开启转码」开关无关：命中该歌即强制按此格式请求转码地址播放，
  /// 不参与「全部转码」/阈值/源格式==转码格式等判定。切歌后按 id 命中仍有效。
  final Map<String, String> _forcedCodecs = {};

  /// 活动转码会话 id（只读视图，供 PlayerService quit 释放）。
  Set<String> get activeTranscodeIds => Set.unmodifiable(_activeIds);

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

    // 与 resolvedCodecFor / resolvedSizeFor 共享同一次 metadata 请求：拉取时
    // 同时提取并缓存 format / codec / size，避免各发一次网络请求。
    final spec = await _resolveSpec(song);
    if (spec == null) return null;
    final format = _extractFormat(spec)?.trim();
    if (format != null && format.isNotEmpty) {
      _formats[song.id] = format;
    }
    _cacheCodecFromSpec(song.id, spec);
    _cacheSizeFromSpec(song.id, spec);
    return format;
  }

  /// 获取某首歌的**有效编码**（audioSpec.codec，如 eac3/alac/aac）。优先
  /// `song.codec`（列表接口已带则直接用，零网络开销）；为空时先查会话内
  /// codec 缓存，未命中再请求 `/track/metadata` 确认。
  ///
  /// 返回 null 表示无法确认编码（无需处理 / metadata 失败）。
  Future<String?> resolvedCodecFor(SongEntity song) async {
    final local = song.codec;
    if (local != null && local.trim().isNotEmpty) return local.trim();

    final cached = _codecs[song.id];
    if (cached != null) return cached;

    // 与 resolvedFormatFor 共享同一次 metadata 请求。
    final spec = await _resolveSpec(song);
    if (spec == null) return null;
    final codec = _extractCodec(spec)?.trim();
    if (codec != null && codec.isNotEmpty) {
      _codecs[song.id] = codec;
    }
    _cacheFormatFromSpec(song.id, spec);
    _cacheSizeFromSpec(song.id, spec);
    return codec;
  }

  /// 获取某首歌的**文件大小**（字节）。优先 `song.fileSize`（列表接口已带则
  /// 直接用，零网络开销）；为空时先查会话内 size 缓存，未命中再请求
  /// `/track/metadata` 确认。
  ///
  /// 返回 null 表示无法确认大小（「仅大文件」模式下不转码）。
  Future<int?> resolvedSizeFor(SongEntity song) async {
    if (song.fileSize != null && song.fileSize! > 0) return song.fileSize;
    final cached = _sizes[song.id];
    if (cached != null) return cached;
    final spec = await _resolveSpec(song);
    if (spec == null) return null;
    final size = _extractSize(spec);
    if (size != null && size > 0) _sizes[song.id] = size;
    return size;
  }

  /// 这首歌是否应走服务器转码。
  ///
  /// - `开启转码` 关 → 不转（直连）
  /// - **源格式 == 生效转码格式 → 不转（直连）**：flac 源 + 转码 flac 是纯浪费
  ///   （无损→无损大小不变，ExoPlayer 直连即播）；mp3/opus 源同理。
  /// - **不向上转码 → 不转（直连）**：转码输出质量层 ≥ 源质量层（如 mp3 源 +
  ///   flac 目标）无压缩收益，只有真降级（无损→有损等）才转码，见
  ///   [isDownscaleTranscode]。
  /// - `全部转码` 开 → 转（免 size，含 DSF/APE/WMA 等无损）
  /// - `全部转码` 关 → 仅超过阈值转；**未识别大小的文件不转**
  ///
  /// CUE 曲目也参与转码（服务器按 guid 返回**裁切好的单曲 HLS**，客户端无需
  /// 再裁剪）；CUE 整轨文件往往很大，转码后明显更小。
  Future<bool> shouldTranscode(
    SongEntity song, {
    bool respectWifiPolicy = true,
  }) async {
    // 桌面端（Windows/macOS/Linux）强制直连：转码产出 HLS（fMP4），
    // media_kit 的 mpv FFmpeg 音频库未编入 hls demuxer 播不了；
    // 全量走 media_kit 直连原始流即可。
    // 用 defaultTargetPlatform 而非 Platform.isWindows：单测默认 android。
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      return false;
    }
    // 歌曲信息面板手动指定「强制转码」：不依赖全局「开启转码」开关，
    // 直接请求该歌的转码地址播放。
    if (_forcedCodecs.containsKey(song.id)) return true;
    if (!AppTranscodeSettings.enabled.value) return false;
    if (respectWifiPolicy &&
        AppTranscodeSettings.directOnWifi.value &&
        NetworkConnectionService.instance.isWifiConnected) {
      return false;
    }
    // 源格式与生效转码格式一致（flac→flac / mp3→mp3 / opus→opus）→ 无转码收益，
    // 直接直连播放。已降级到 mp3 的歌若源本就是 mp3 也跳过。
    final source = (song.format ?? '').trim().toLowerCase();
    if (source.isNotEmpty && source == effectiveCodecFor(song.id)) return false;
    // 不向上转码：输出质量层 ≥ 源质量层 → 转码无压缩收益（如 mp3 源 + flac
    // 目标，纯浪费服务器带宽），直接直连。只有真降级（无损→有损等）才值得
    // 请求服务器转码。
    final target = effectiveCodecFor(song.id);
    if (!isDownscaleTranscode(source, song.codec, target)) return false;
    if (AppTranscodeSettings.transcodeAll.value) return true;
    final size = await resolvedSizeFor(song);
    if (size == null || size <= 0) return false;
    return size > AppTranscodeSettings.thresholdMb.value * 1024 * 1024;
  }

  /// 当前生效的转码 codec：降级到 mp3 的歌恒为 `mp3`，否则取设置格式。
  /// 歌曲信息面板手动「强制转码」的歌按强制格式（优先级最高，覆盖全局格式）。
  String effectiveCodecFor(String songId) {
    if (_downgradedToMp3.contains(songId)) return 'mp3';
    final forced = _forcedCodecs[songId];
    if (forced != null) return forced;
    return AppTranscodeSettings.format.value.name;
  }

  /// 设置/清除某歌的强制转码 codec（歌曲信息面板选择）。
  /// 传 null 清除强制，恢复按全局设置判定。
  void setForcedTranscodeCodec(String songId, String? codec) {
    if (codec == null || codec.isEmpty) {
      _forcedCodecs.remove(songId);
    } else {
      _forcedCodecs[songId] = codec;
    }
  }

  /// 该歌是否被强制转码（不依赖全局「开启转码」开关）。
  bool isForcedTranscode(String songId) => _forcedCodecs.containsKey(songId);

  /// 该歌被强制转码的 codec（未强制返回 null）。
  String? forcedTranscodeCodec(String songId) => _forcedCodecs[songId];

  /// 某首歌**配置上应走**的转码格式名（大写，如 FLAC/MP3/OPUS），供歌曲面板
  /// tag 显示。同步计算（不查网络/会话）：
  /// - 未开启转码 / 源格式==转码格式（flac→flac 直连）→ null（直连）；
  /// - 已降级到 mp3 → MP3；
  /// - `全部转码` 开 → 生效格式；
  /// - `全部转码` 关 → 歌曲自带 fileSize 且超阈值 → 生效格式；否则 null
  ///   （文件大小未知时需异步 resolvedSizeFor 才能判定 → 面板显示直连）。
  String? configuredTranscodeLabel(SongEntity song) {
    // 桌面端强制直连（media_kit 播不了 fMP4 HLS），一律显示直连。
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux)) {
      return null;
    }
    // 歌曲信息面板手动指定「强制转码」：不依赖全局开关，按强制格式显示。
    final forced = _forcedCodecs[song.id];
    if (forced != null) return forced.toUpperCase();
    if (!AppTranscodeSettings.enabled.value) return null;
    if (AppTranscodeSettings.directOnWifi.value &&
        NetworkConnectionService.instance.isWifiConnected) {
      return null;
    }
    final source = (song.format ?? '').trim().toLowerCase();
    if (source.isNotEmpty && source == effectiveCodecFor(song.id)) return null;
    // 不向上转码：输出质量层 ≥ 源质量层 → 直连（与 shouldTranscode 同源判定，
    // 避免 tag 显示转码、实际却直连的不一致）。
    if (!isDownscaleTranscode(source, song.codec, effectiveCodecFor(song.id))) {
      return null;
    }
    if (AppTranscodeSettings.transcodeAll.value) {
      return effectiveCodecFor(song.id).toUpperCase();
    }
    // 「全部转码」关：有 fileSize 且超阈值 → 转；否则按不转（直连）显示。
    final size = song.fileSize;
    if (size == null || size <= 0) return null;
    final threshold = AppTranscodeSettings.thresholdMb.value * 1024 * 1024;
    if (size <= threshold) return null;
    return effectiveCodecFor(song.id).toUpperCase();
  }

  bool isDowngradedToMp3(String songId) => _downgradedToMp3.contains(songId);

  /// 标记某歌降级到 mp3（flac 转码 ExoPlayer 解析失败后调用）：清除该歌
  /// 的 flac 转码缓存，下次请求强制转码成 mp3。
  void markDowngradeToMp3(String songId) {
    _downgradedToMp3.add(songId);
    _removeCacheFor(songId);
  }

  /// 清除某歌的降级标记（切换转码格式时调用，允许按新格式重新转码）。
  void clearDowngradeFor(String songId) {
    _downgradedToMp3.remove(songId);
  }

  /// 获取某首歌的**转码 HLS** 播放绝对地址（按当前生效 codec）。
  ///
  /// - 不应转码（`shouldTranscode` false）→ 返回 null；
  /// - 转码成功 → 缓存（TTL，按 `songId|codec`）并登记活动会话，返回绝对 URL；
  /// - 网络异常 / 服务器未返回地址 → **catch 全部异常返回 null**（调用方退直连）。
  Future<String?> transcodeHlsUrlFor(SongEntity song) async {
    try {
      if (!await shouldTranscode(song)) return null;
      final codec = effectiveCodecFor(song.id);
      final key = _cacheKey(song.id, codec);
      final hit = _cache[key];
      if (hit != null && hit.isValid()) {
        _activeIds.add(song.id);
        return hit.url;
      }
      // 只有 flac 带 bitrate（320）；mp3/opus 不带——带 bitrate 会劣化音质。
      final int? bitrate = codec == 'flac' ? 320 : null;
      final rel = await _api.trackTranscode(
        song.id,
        codec: codec,
        bitrate: bitrate,
        channel: 2,
      );
      if (rel == null) return null;
      final url = _api.resolveHlsUrl(rel);
      _cache[key] = _CachedHls(url, DateTime.now().add(_ttl));
      _activeIds.add(song.id);
      return url;
    } catch (_) {
      // 任何失败（转码请求异常等）→ 返回 null，由调用方退直连，不阻塞播放。
      return null;
    }
  }

  /// 释放服务器端转码会话（切歌/停止/退出时调用）。best-effort，失败忽略。
  Future<void> quitFor(String songId) => _quitIds([songId]);

  Future<void> quitForIds(Iterable<String> ids) => _quitIds(ids);

  /// 获取某首歌的 **MP3 转码 HLS** 绝对地址（供 DLNA 投屏使用）。
  ///
  /// 渲染器通常无法解码 FLAC/DSF/APE 等无损格式，投屏时优先转码成 MP3。
  /// - 转码成功 → 按 `songId|mp3` 缓存（TTL）并登记活动会话，返回绝对 URL；
  /// - 网络异常 / 服务器未返回地址 → 返回 null（调用方退直连）。
  Future<String?> transcodeMp3UrlFor(SongEntity song) async {
    try {
      final key = _cacheKey(song.id, 'mp3');
      final hit = _cache[key];
      if (hit != null && hit.isValid()) {
        _activeIds.add(song.id);
        return hit.url;
      }
      // mp3 不带 bitrate（带 bitrate 会显著劣化音质）。
      final rel = await _api.trackTranscode(song.id, codec: 'mp3', channel: 2);
      if (rel == null) return null;
      final url = _api.resolveHlsUrl(rel);
      _cache[key] = _CachedHls(url, DateTime.now().add(_ttl));
      _activeIds.add(song.id);
      return url;
    } catch (_) {
      // 任何失败 → 返回 null，由调用方退直连，不阻塞投屏。
      return null;
    }
  }

  Future<void> quitAll() => _quitIds(_activeIds.toList());

  /// 当前歌是否正在走服务器转码（有活动转码会话）。
  /// 供歌曲面板显示转码 tag；无活动会话 → 直连。
  bool isTranscoding(String songId) => _activeIds.contains(songId);

  /// 当前歌的**生效转码格式名**（大写，如 FLAC / MP3 / OPUS）。
  ///
  /// 仅当该歌正在转码（[isTranscoding]）时有意义；降级到 mp3 的歌返回 MP3。
  String? activeTranscodeLabel(String songId) {
    if (!_activeIds.contains(songId)) return null;
    final codec = effectiveCodecFor(songId);
    return codec.toUpperCase();
  }

  Future<void> _quitIds(Iterable<String> ids) async {
    final unique = ids.toSet();
    for (final id in unique) {
      _activeIds.remove(id);
      _removeCacheFor(id);
    }
    for (final id in unique) {
      try {
        await _api.trackTranscodeQuit(id);
      } catch (_) {
        // 释放失败忽略（服务端有超时兜底）。
      }
    }
  }

  /// 拉取一次 metadata。并发调用去重：复用同一个在途 Future。
  /// metadata 失败返回 null（按无需处理，不阻塞播放）。
  Future<Map<String, dynamic>?> _resolveSpec(SongEntity song) async {
    final inflight = _formatInflight[song.id];
    if (inflight != null) return inflight;

    final future = () async {
      try {
        return await _api.trackMetadata(song.id);
      } catch (_) {
        return null;
      }
    }();
    _formatInflight[song.id] = future;
    future.whenComplete(() => _formatInflight.remove(song.id));
    return future;
  }

  void _cacheFormatFromSpec(String songId, Map<String, dynamic> spec) {
    final format = _extractFormat(spec)?.trim();
    if (format != null && format.isNotEmpty) {
      _formats[songId] = format;
    }
  }

  void _cacheCodecFromSpec(String songId, Map<String, dynamic> spec) {
    final codec = _extractCodec(spec)?.trim();
    if (codec != null && codec.isNotEmpty) {
      _codecs[songId] = codec;
    }
  }

  void _cacheSizeFromSpec(String songId, Map<String, dynamic> spec) {
    final size = _extractSize(spec);
    if (size != null && size > 0) _sizes[songId] = size;
  }

  /// 获取某首歌的 **FLAC HLS** 播放绝对地址。
  ///
  /// ⚠️ 当前播放器已不再调用（media_kit 直连原始流，转码走 `transcodeHlsUrlFor`），
  /// 保留仅供测试。
  ///
  /// - 非 media_kit 格式（flac/mp3/aac/…，或 metadata 无法确认）→ 返回 null；
  /// - 转码成功 → 缓存（TTL）并返回绝对 URL；
  /// - 网络异常 / 服务器未返回地址 → 抛异常，由调用方回退直连。
  Future<String?> hlsUrlForFlac(SongEntity song, {bool force = false}) async {
    final format = await resolvedFormatFor(song);
    if (!force && !isMediaKitFormat(format ?? '')) return null;

    final key = _cacheKey(song.id, 'flac');
    final hit = _cache[key];
    if (hit != null && hit.isValid()) return hit.url;

    final rel = await _api.trackTranscode(song.id, codec: 'flac', bitrate: 320);
    if (rel == null) return null;

    final url = _api.resolveHlsUrl(rel);
    _cache[key] = _CachedHls(url, DateTime.now().add(_ttl));
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
    for (final entry in _cache.entries) {
      if (entry.key.startsWith('$songId|') && entry.value.isValid()) {
        return entry.value.url;
      }
    }
    return null;
  }

  /// 清除某首歌的转码/解析缓存（播放出错强制刷新时调用）。
  ///
  /// 注意：**不**清除降级标记（`_downgradedToMp3`）——降级是本会话的决策，
  /// 与升级到 media_kit（`_mediaKitEscalateSongIds`）同级、会话内保留。
  void invalidate(String songId) {
    _removeCacheFor(songId);
    _formatInflight.remove(songId);
    _formats.remove(songId);
    _codecs.remove(songId);
    _sizes.remove(songId);
    _activeIds.remove(songId);
  }

  String _cacheKey(String songId, String codec) => '$songId|$codec';

  void _removeCacheFor(String songId) {
    _cache.removeWhere((key, _) => key.startsWith('$songId|'));
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

  /// 从 metadata 响应中提取编码（`data.audioSpec.codec` 或
  /// `data.track.audioSpec.codec`，两者都存在）。镜像 [_extractFormat]。
  String? _extractCodec(Map<String, dynamic>? meta) {
    if (meta == null) return null;
    final audioSpec = meta['audioSpec'];
    if (audioSpec is Map<String, dynamic>) {
      final codec = audioSpec['codec'];
      if (codec is String && codec.isNotEmpty) return codec;
    }
    final track = meta['track'];
    if (track is Map<String, dynamic>) {
      final trackSpec = track['audioSpec'];
      if (trackSpec is Map<String, dynamic>) {
        final codec = trackSpec['codec'];
        if (codec is String && codec.isNotEmpty) return codec;
      }
    }
    return null;
  }

  /// 从 metadata 响应中提取文件大小（字节）：`audioSpec.size` 或
  /// `track.audioSpec.size`。镜像 [_extractFormat]。
  int? _extractSize(Map<String, dynamic>? meta) {
    int? pick(Map<String, dynamic> spec) {
      final size = spec['size'];
      if (size is num && size > 0) return size.toInt();
      return null;
    }

    if (meta == null) return null;
    final audioSpec = meta['audioSpec'];
    if (audioSpec is Map<String, dynamic>) {
      final size = pick(audioSpec);
      if (size != null) return size;
    }
    final track = meta['track'];
    if (track is Map<String, dynamic>) {
      final trackSpec = track['audioSpec'];
      if (trackSpec is Map<String, dynamic>) {
        final size = pick(trackSpec);
        if (size != null) return size;
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
    _codecs.clear();
    _sizes.clear();
    _activeIds.clear();
    _downgradedToMp3.clear();
    _forcedCodecs.clear();
  }

  @visibleForTesting
  void resetForTest() {
    _api = FeiNiuApiClient.instance;
    _cache.clear();
    _formatInflight.clear();
    _formats.clear();
    _codecs.clear();
    _sizes.clear();
    _activeIds.clear();
    _downgradedToMp3.clear();
    _forcedCodecs.clear();
  }
}

/// 转码缓存项：HLS 地址 + 过期时间。
class _CachedHls {
  final String url;
  final DateTime expiresAt;

  _CachedHls(this.url, this.expiresAt);

  bool isValid() => DateTime.now().isBefore(expiresAt);
}
