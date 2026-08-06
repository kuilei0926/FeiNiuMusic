import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../router/app_router.dart';
import '../services/player_service.dart';
import '../utils/app_navigator.dart';

/// TV 遥控器非传输键的 Intent 定义。
///
/// 传输键（播放/暂停/切歌/停止）**不在此处理**：它们已由 audio_service 的
/// MediaSession + `MediaButtonReceiver` 处理，若再在 Flutter 侧设 shortcut
/// 会双触发。这里只处理系统不会路由的键：搜索键、快进/快退。
class TvSearchIntent extends Intent {
  const TvSearchIntent();
}

class TvSeekForwardIntent extends Intent {
  const TvSeekForwardIntent();
}

class TvSeekBackwardIntent extends Intent {
  const TvSeekBackwardIntent();
}

/// 遥控器快捷键 → Action 的映射表，由 [TvFocusScope] 安装。
Map<ShortcutActivator, Intent> buildTvShortcuts() {
  return <ShortcutActivator, Intent>{
    // TV 遥控器搜索键：全局打开搜索页。
    const SingleActivator(LogicalKeyboardKey.browserSearch):
        const TvSearchIntent(),
    // 快进/快退 15 秒（部分遥控器把这两个键映射为切歌，跳过亦可）。
    const SingleActivator(LogicalKeyboardKey.mediaRewind):
        const TvSeekBackwardIntent(),
    const SingleActivator(LogicalKeyboardKey.mediaFastForward):
        const TvSeekForwardIntent(),
  };
}

/// 遥控器快捷键对应的动作实现。
class TvRemoteActions extends StatelessWidget {
  final Widget child;

  const TvRemoteActions({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        TvSearchIntent: CallbackAction<TvSearchIntent>(
          onInvoke: (_) {
            AppNavigator.pushNamed(AppRoutes.search);
            return null;
          },
        ),
        TvSeekForwardIntent: CallbackAction<TvSeekForwardIntent>(
          onInvoke: (_) {
            final player = PlayerService.instance;
            final next = player.position.value + const Duration(seconds: 15);
            player.seek(next);
            return null;
          },
        ),
        TvSeekBackwardIntent: CallbackAction<TvSeekBackwardIntent>(
          onInvoke: (_) {
            final player = PlayerService.instance;
            final pos = player.position.value - const Duration(seconds: 15);
            player.seek(pos.isNegative ? Duration.zero : pos);
            return null;
          },
        ),
      },
      child: child,
    );
  }
}
