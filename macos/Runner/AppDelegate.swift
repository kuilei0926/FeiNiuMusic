import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 应用是否正在退出（状态栏菜单「退出」/ Cmd+Q 触发）。
  /// 供 MainFlutterWindow.windowShouldClose 判断：真正退出时放行关闭，
  /// 仅关闭按钮点击时隐藏到托盘。NSApplication 没有公开 isTerminating，
  /// 所以用退出流程最早的回调（applicationShouldTerminate）置位。
  static var isTerminating = false

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppDelegate.isTerminating = true
    return .terminateNow
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // 关闭最后一个窗口时不退出应用：应用驻留菜单栏（状态栏），
    // 仅通过状态栏菜单「退出」退出。关闭行为由 MainFlutterWindow
    // windowShouldClose 拦截（关闭按钮隐藏到菜单栏）。
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    // 菜单栏状态关闭或原生通道尚未同步时仍保留 Dock 恢复入口，避免主窗口
    // 被 orderOut/close 后无法重新打开。
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
