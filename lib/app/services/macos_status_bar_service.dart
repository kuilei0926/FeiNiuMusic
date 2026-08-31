import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../services/player_service.dart';
import '../state/settings_state.dart';
import 'lyrics/lyrics_service.dart';

String resolveMacosStatusBarText({
  required String songTitle,
  required String? currentLyric,
  required bool isPlaying,
}) {
  final normalizedTitle = songTitle.trim();
  final normalizedLyric = currentLyric?.trim() ?? '';
  if (isPlaying && normalizedLyric.isNotEmpty) {
    return normalizedLyric;
  }
  return normalizedTitle;
}

/// macOS 菜单栏（状态栏）播放状态指示器。
///
/// 仅在 macOS 平台启用：启动时在原生侧创建一个 [NSStatusItem]，
/// 通过 MethodChannel 把当前播放歌曲/播放状态推送给原生 UI，
/// 并把菜单栏里的播放/暂停/上一首/下一首操作回传到 [PlayerService]。
class MacosStatusBarService {
  static const MethodChannel _channel = MethodChannel(
    'com.feiniu.music/statusbar',
  );

  static bool _started = false;
  static bool _nativeReady = false;
  static bool _connecting = false;
  static Timer? _connectRetryTimer;

  static Future<void> init() async {
    if (!Platform.isMacOS) return;
    await StatusBarSettings.ensureLoaded();
    await CloseToTraySettings.ensureLoaded();
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler(_handleCall);
    StatusBarSettings.enabled.addListener(_onEnabledChanged);
    CloseToTraySettings.enabled.addListener(_syncCloseToTray);

    final state = AppPlayerState.instance;
    state.isPlaying.addListener(_pushState);
    state.currentSong.addListener(_pushState);
    LyricsService.instance.currentLineText.addListener(_pushState);

    // Dart main() 与 AppDelegate 的 MethodChannel 注册没有固定先后顺序。
    // 主动握手并在失败后重试，避免首次 setState/hide 落在原生通道注册前，
    // 被 MissingPluginException 吞掉后状态栏永远停留在初始状态。
    unawaited(_connect());
  }

  static void _onEnabledChanged() {
    if (!_nativeReady) {
      unawaited(_connect());
      return;
    }
    _syncVisibilityAndState();
  }

  static void _syncVisibilityAndState() {
    if (StatusBarSettings.enabled.value) {
      _send('show');
      _pushState();
    } else {
      _send('hide');
    }
  }

  /// 把「关闭按钮隐藏到托盘」设置同步给原生：原生据此决定关闭窗口时
  /// 是隐藏（驻留菜单栏）还是真正关闭。
  static void _syncCloseToTray() {
    if (!_nativeReady) {
      unawaited(_connect());
      return;
    }
    _send('setCloseToTray', CloseToTraySettings.enabled.value);
  }

  static Future<void> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'ready':
        _markNativeReady();
      case 'play':
        await PlayerService.instance.play();
      case 'pause':
        await PlayerService.instance.pause();
      case 'playPause':
        await PlayerService.instance.togglePlayPause();
      case 'next':
        await PlayerService.instance.next();
      case 'previous':
        await PlayerService.instance.previous();
      default:
        break;
    }
  }

  static void _pushState() {
    if (!_nativeReady) {
      unawaited(_connect());
      return;
    }
    final state = AppPlayerState.instance;
    final song = state.currentSongSignal.value;
    final isPlaying = state.isPlayingSignal.value;
    final currentLyric = LyricsService.instance.currentLineText.value;
    _send('setState', <String, Object?>{
      'title': song?.title ?? '',
      'artist': song?.artistDisplayName ?? '',
      'displayText': resolveMacosStatusBarText(
        songTitle: song?.title ?? '',
        currentLyric: currentLyric,
        isPlaying: isPlaying,
      ),
      'isPlaying': isPlaying,
      'isIdle': song == null,
    });
  }

  static Future<void> _connect() async {
    if (_nativeReady || _connecting) return;
    _connecting = true;
    try {
      await _channel.invokeMethod<void>('ping');
      _markNativeReady();
    } catch (_) {
      _scheduleConnectRetry();
    } finally {
      _connecting = false;
    }
  }

  static void _markNativeReady() {
    if (_nativeReady) return;
    _nativeReady = true;
    _connectRetryTimer?.cancel();
    _connectRetryTimer = null;
    _syncVisibilityAndState();
    _syncCloseToTray();
  }

  static void _scheduleConnectRetry() {
    if (_nativeReady || _connectRetryTimer?.isActive == true) return;
    _connectRetryTimer = Timer(const Duration(milliseconds: 300), () {
      _connectRetryTimer = null;
      unawaited(_connect());
    });
  }

  static void _send(String method, [Object? arguments]) {
    unawaited(
      _channel.invokeMethod<void>(method, arguments).catchError((_) {
        _nativeReady = false;
        _scheduleConnectRetry();
      }),
    );
  }
}
