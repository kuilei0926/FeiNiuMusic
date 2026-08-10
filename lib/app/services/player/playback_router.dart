import 'package:flutter/foundation.dart';

import '../feiniu/transcode_service.dart';
import '../../state/song_state.dart';
import 'player_engine.dart';

/// 播放引擎路由：决定每首歌由哪个引擎解码。
///
/// 原则：**能系统解码的就用系统解码（just_audio），只有系统解码不了的才用
/// media_kit（FFmpeg 软解）**。
///
/// - **just_audio**（默认）：普通 FLAC、mp3/aac/m4a/ogg/wav/opus、未知/空格式
///   ——直连流 + 缓存，ExoPlayer 系统解码器处理。
/// - **media_kit**：
///   - 黑名单格式（dsf/dff/dsd/wma/ape/dts/aiff…）：ExoPlayer 原生无法解码，
///     media_kit 直连原始流，FFmpeg 软解。
///   - 黑名单 codec（eac3/ac3/alac/dts/truehd/mlp…）：M4A/MP4 容器内常见的
///     环绕声/无损编码，ExoPlayer 设备解码器支持因设备而异（解码器不可用或
///     静默失败时进度条走但无声音），media_kit（FFmpeg）必定出声。
///   - **运行时升级**的歌曲（见 PlayerService `_mediaKitEscalateSongIds`）：
///     普通 FLAC 若 ExoPlayer 解码触发 32KB 帧缓冲超限（`Buffer too small`），
///     当场升级到 media_kit 无损解码。**只有这类 FLAC 才走 media_kit**。
///
/// 未知/空格式走 just_audio 直连（与现状一致）：格式探测延后，播放出错由
/// 引擎错误处理兜底。
EngineKind routeForFormat(String? format, {String? codec}) {
  // Windows 桌面端：just_audio（ExoPlayer）无原生实现，全量走 media_kit
  // （libmpv + FFmpeg，任意格式都能软解）。用 defaultTargetPlatform 而非
  // Platform.isWindows：单测默认 TargetPlatform.android，保持路由测试有效。
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return EngineKind.mediaKit;
  }
  // codec 判断优先：eac3/ac3/alac 等 ExoPlayer 设备解码不可靠的编码直接
  // 走 media_kit（FFmpeg），即使容器是 m4a（format 不在黑名单）。
  if (FeiNiuTranscodeService.isMediaKitCodec(codec)) {
    return EngineKind.mediaKit;
  }
  if (format == null || format.isEmpty) return EngineKind.justAudio;
  final f = format.trim().toLowerCase();
  // 普通 FLAC 走系统解码（just_audio），不强制 media_kit。
  return FeiNiuTranscodeService.isMediaKitFormat(f)
      ? EngineKind.mediaKit
      : EngineKind.justAudio;
}

/// 解析歌曲格式与编码后返回引擎类型。格式/编码解析走 `resolvedFormatFor` /
/// `resolvedCodecFor`（会话内缓存），对列表接口已带 `audioSpec.format` /
/// `audioSpec.codec` 的曲目零网络开销。
Future<EngineKind> routeForSong(SongEntity song) async {
  final format = await FeiNiuTranscodeService.instance.resolvedFormatFor(song);
  final codec = await FeiNiuTranscodeService.instance.resolvedCodecFor(song);
  return routeForFormat(format, codec: codec);
}
