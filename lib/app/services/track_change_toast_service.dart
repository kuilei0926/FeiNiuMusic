import 'package:flutter/foundation.dart';

import '../../components/feedback/track_change_toast.dart';
import '../state/settings_state.dart';
import '../state/song_state.dart';
import 'player_service.dart';

/// 切歌通知服务：监听 currentSong，真实切歌时弹出「正在播放」提示卡片。
///
/// 「真实切歌」判定（纯函数 [shouldShow]）：
/// - 通知开关必须打开；
/// - 上一首非空（首次选歌 / 启动恢复的 `null → 歌曲` 迁移不弹）；
/// - 新歌 id 与上一首不同（同曲去重，如启动恢复里的重复设置）。
class TrackChangeToastService {
  TrackChangeToastService._();

  static bool _started = false;
  static ValueListenable<SongEntity?>? _currentSong;
  static String? _lastTrackId;

  /// 幂等启动。默认监听 [PlayerService.instance.currentSong]（main() 中
  /// MediaNotificationService.init() 之后调用）；测试可注入 [currentSong]
  /// 数据源，避免构造重量级 PlayerService。
  static void start({ValueListenable<SongEntity?>? currentSong}) {
    if (_started) return;
    _started = true;
    final listenable = currentSong ?? PlayerService.instance.currentSong;
    _currentSong = listenable;
    _lastTrackId = listenable.value?.id;
    listenable.addListener(_onCurrentSongChanged);
  }

  /// 测试用：停止监听并复位。
  @visibleForTesting
  static void resetForTest() {
    _currentSong?.removeListener(_onCurrentSongChanged);
    _currentSong = null;
    _started = false;
    _lastTrackId = null;
  }

  /// 纯决策函数：是否应弹出切歌通知。
  @visibleForTesting
  static bool shouldShow({
    required String? previousId,
    required String newId,
    required bool notifyEnabled,
  }) {
    if (!notifyEnabled) return false;
    if (previousId == null) return false; // 首次选歌 / 启动恢复
    if (previousId == newId) return false; // 同曲去重
    return true;
  }

  static void _onCurrentSongChanged() {
    final listenable = _currentSong;
    if (listenable == null) return;
    final song = listenable.value;
    final newId = song?.id;
    if (newId == null) {
      _lastTrackId = null;
      return;
    }
    final previousId = _lastTrackId;
    _lastTrackId = newId; // 即使被抑制也跟踪最新，避免旧歌被反复判定为新切歌

    if (!shouldShow(
      previousId: previousId,
      newId: newId,
      notifyEnabled: AppLayoutSettings.trackChangeNotify.value,
    )) {
      return;
    }

    TrackChangeToast.showGlobal(song!);
  }
}
