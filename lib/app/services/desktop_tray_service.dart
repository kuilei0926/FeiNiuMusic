import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../state/settings_state.dart';
import 'player_service.dart';

/// Windows 系统托盘服务。
///
/// 仅在 Windows 平台启用：
/// - 拦截关闭按钮（window_manager setPreventClose）：设置开启时隐藏到托盘
///   而不是退出应用（默认开启）；
/// - 创建托盘图标与右键菜单（当前歌曲信息 + 播放/暂停/上一首/下一首/退出），
///   随播放状态实时刷新；
/// - 托盘图标单击恢复主窗口。
///
/// macOS 由原生 NSStatusItem 承担（MacosStatusBarService + 原生改动），
/// 本服务不处理（window_manager 在 macOS 会劫持窗口 delegate，与原生
/// windowShouldClose 冲突，故 macOS 走原生实现）。
class DesktopTrayService with WindowListener, TrayListener {
  DesktopTrayService._();

  static final DesktopTrayService instance = DesktopTrayService._();

  /// Windows 托盘图标：LoadImage(IMAGE_ICON, LR_LOADFROMFILE) 只认 .ico，
  /// 必须是 asset 路径（插件解析到 data/flutter_assets 下）。
  static const String _iconAsset = 'assets/icon/app_icon.ico';

  static const String _kInfo = 'info';
  static const String _kPlayPause = 'playPause';
  static const String _kPrevious = 'previous';
  static const String _kNext = 'next';
  static const String _kQuit = 'quit';

  bool _started = false;
  bool _trayReady = false;

  static Future<void> init() async {
    if (!Platform.isWindows) return;
    if (instance._started) return;
    instance._started = true;

    await CloseToTraySettings.ensureLoaded();

    await WindowManager.instance.ensureInitialized();
    WindowManager.instance.addListener(instance);
    TrayManager.instance.addListener(instance);

    CloseToTraySettings.enabled.addListener(instance._onSettingChanged);
    AppPlayerState.instance.isPlaying.addListener(instance._refreshMenu);
    AppPlayerState.instance.currentSong.addListener(instance._refreshMenu);

    await instance._applySetting(CloseToTraySettings.enabled.value);
  }

  Future<void> _onSettingChanged() async {
    await _applySetting(CloseToTraySettings.enabled.value);
  }

  Future<void> _applySetting(bool enabled) async {
    if (enabled) {
      await WindowManager.instance.setPreventClose(true);
      await _ensureTray();
    } else {
      await _destroyTray();
      await WindowManager.instance.setPreventClose(false);
      // 关闭该设置时若窗口正隐藏（在托盘里），恢复显示，
      // 避免「看不到窗口也退不出应用」。
      if (!await WindowManager.instance.isVisible()) {
        await WindowManager.instance.show();
        await WindowManager.instance.focus();
      }
    }
  }

  Future<void> _ensureTray() async {
    if (_trayReady) return;
    await TrayManager.instance.setIcon(_iconAsset);
    await TrayManager.instance.setToolTip('飞牛音乐');
    // 先置位再刷新：_refreshMenu 内部有 _trayReady 守卫，否则首次菜单发不出。
    _trayReady = true;
    await _refreshMenu();
  }

  Future<void> _destroyTray() async {
    if (!_trayReady) return;
    await TrayManager.instance.destroy();
    _trayReady = false;
  }

  Future<void> _refreshMenu() async {
    if (!_trayReady) return;
    final state = AppPlayerState.instance;
    final song = state.currentSong.value;
    final isPlaying = state.isPlaying.value;
    final title = song?.title.trim() ?? '';
    final artist = song?.artistDisplayName.trim() ?? '';
    final info = song == null
        ? '飞牛音乐'
        : '${isPlaying ? '正在播放' : '已暂停'}：$title'
            '${artist.isEmpty ? '' : ' — $artist'}';

    // tray_manager 无增量更新：每次全量重建菜单。
    await TrayManager.instance.setContextMenu(Menu(items: [
      MenuItem(key: _kInfo, label: info, disabled: true),
      MenuItem.separator(),
      MenuItem(key: _kPlayPause, label: isPlaying ? '暂停' : '播放'),
      MenuItem(key: _kPrevious, label: '上一首'),
      MenuItem(key: _kNext, label: '下一首'),
      MenuItem.separator(),
      MenuItem(key: _kQuit, label: '退出'),
    ]));
  }

  // ---- WindowListener ----

  @override
  void onWindowClose() async {
    // 设置开启时拦截关闭 → 隐藏到托盘；设置关闭时 setPreventClose(false)，
    // 由原生默认销毁（WM_DESTROY → PostQuitMessage）退出，这里不做任何事。
    if (CloseToTraySettings.enabled.value) {
      await WindowManager.instance.hide();
    }
  }

  // ---- TrayListener ----

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _kPlayPause:
        unawaited(PlayerService.instance.togglePlayPause());
      case _kPrevious:
        unawaited(PlayerService.instance.previous());
      case _kNext:
        unawaited(PlayerService.instance.next());
      case _kQuit:
        unawaited(_quit());
    }
  }

  @override
  void onTrayIconMouseDown() {
    // 单击/双击托盘图标：恢复并聚焦主窗口。
    unawaited(_showMainWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // Windows 原生不自动弹出菜单，需手动调用。
    unawaited(TrayManager.instance.popUpContextMenu());
  }

  Future<void> _showMainWindow() async {
    if (await WindowManager.instance.isMinimized()) {
      await WindowManager.instance.restore();
    }
    await WindowManager.instance.show();
    await WindowManager.instance.focus();
  }

  Future<void> _quit() async {
    await _destroyTray();
    await WindowManager.instance.destroy();
  }
}
