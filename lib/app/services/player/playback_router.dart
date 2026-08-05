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
///     服务器转码成 FLAC HLS 后由 media_kit 解码。
///   - **运行时升级**的歌曲（见 PlayerService `_mediaKitEscalateSongIds`）：
///     普通 FLAC 若 ExoPlayer 解码触发 32KB 帧缓冲超限（`Buffer too small`），
///     当场升级到 media_kit 无损解码。**只有这类 FLAC 才走 media_kit**。
///
/// 未知/空格式走 just_audio 直连（与现状一致）：格式探测延后，播放出错由
/// 引擎错误处理兜底。
EngineKind routeForFormat(String? format) {
  if (format == null || format.isEmpty) return EngineKind.justAudio;
  final f = format.trim().toLowerCase();
  // 普通 FLAC 走系统解码（just_audio），不强制 media_kit。
  return FeiNiuTranscodeService.isMediaKitFormat(f)
      ? EngineKind.mediaKit
      : EngineKind.justAudio;
}

/// 解析歌曲格式后返回引擎类型。格式解析走 `resolvedFormatFor`（会话内缓存），
/// 对列表接口已带 `audioSpec.format` 的曲目零网络开销。
Future<EngineKind> routeForSong(SongEntity song) async {
  final format = await FeiNiuTranscodeService.instance.resolvedFormatFor(song);
  return routeForFormat(format);
}
