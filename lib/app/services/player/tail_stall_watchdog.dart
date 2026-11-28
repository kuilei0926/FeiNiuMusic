import 'dart:async';

/// 转码 HLS 末尾卡住看门狗。
///
/// 服务器转码的 HLS 若末尾缺少 `#EXT-X-ENDLIST`（或最后几个分片迟迟不出），
/// ExoPlayer 会把它当作直播流，在末尾一直 buffering 等新分片：既不报错也不
/// 发 `completed`，播放页一直转圈、不切下一首。
///
/// 规则：处于「播放中 + buffering」时开始计时；超时后若播放位置已接近歌曲
/// 已知时长，视为播完，回调 [onStall]。期间状态恢复（ready/暂停/切歌）即取消。
class TailStallWatchdog {
  TailStallWatchdog({
    required this.isNearEnd,
    required this.onStall,
    this.timeout = const Duration(seconds: 6),
  });

  /// 触发时判断当前位置是否已接近末尾。
  final bool Function() isNearEnd;

  /// 判定为末尾卡住时回调，参数为开始计时时的曲目标识。
  final void Function(String trackId) onStall;

  final Duration timeout;

  /// 距离已知时长多少以内算「接近末尾」。
  static const Duration nearEndWindow = Duration(seconds: 10);

  Timer? _timer;
  String? _armedTrackId;

  bool get isArmed => _timer != null;

  static bool isPositionNearEnd(Duration position, Duration? duration) {
    if (duration == null || duration <= Duration.zero) return false;
    return position >= duration - nearEndWindow;
  }

  /// 每次引擎状态变化时调用。[trackId] 为 null 表示当前不需要监控。
  void update({required bool stalled, required String? trackId}) {
    if (!stalled || trackId == null) {
      cancel();
      return;
    }
    if (_timer != null && _armedTrackId == trackId) return;
    cancel();
    _armedTrackId = trackId;
    _timer = Timer(timeout, () {
      _timer = null;
      final id = _armedTrackId;
      _armedTrackId = null;
      if (id != null && isNearEnd()) onStall(id);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _armedTrackId = null;
  }
}
