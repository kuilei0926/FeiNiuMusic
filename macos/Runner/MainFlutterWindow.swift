import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var statusBarController: MacosStatusBarController?

  /// 关闭按钮是否隐藏到菜单栏（由 Dart 通过 statusbar 通道推送，默认开启）。
  var closeToTray = true

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 引擎默认 FlutterView 的 layer 背景是黑色（FlutterView.mm 里
    // `[self setBackgroundColor:[NSColor blackColor]]`）。滚动/切页时若有
    // 一帧合成不及时，Metal layer 露出的就是黑底 → 整窗黑屏闪烁。
    // 这里先按系统外观设一个与 App 主题一致的底色；Flutter 侧
    // （MacosWindowBackgroundService）再通过 channel 精确同步实际主题色。
    flutterViewController.backgroundColor = resolveInitialBackground()

    RegisterGeneratedPlugins(registry: flutterViewController)
    // 窗口背景色同步通道：Flutter 侧把主题背景色（ARGB int）推到这里，
    // 覆盖上面的初始底色，并跟随主题/系统亮暗实时更新。
    let windowChannel = FlutterMethodChannel(
      name: "com.feiniu.music/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak flutterViewController] call, result in
      guard call.method == "setBackgroundColor",
            let argb = call.arguments as? Int else {
        result(FlutterMethodNotImplemented)
        return
      }
      let a = Double((argb >> 24) & 0xFF) / 255.0
      let r = Double((argb >> 16) & 0xFF) / 255.0
      let g = Double((argb >> 8) & 0xFF) / 255.0
      let b = Double(argb & 0xFF) / 255.0
      flutterViewController?.backgroundColor = NSColor(
        srgbRed: r, green: g, blue: b, alpha: a)
      result(nil)
    }

    // 拦截窗口关闭：设置开启时隐藏到菜单栏而非关闭（见 windowShouldClose）。
    self.delegate = self

    statusBarController = MacosStatusBarController(
      binaryMessenger: flutterViewController.engine.binaryMessenger,
      mainWindow: self)

    super.awakeFromNib()
  }

  // NSWindowDelegate
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // 应用正在退出（状态栏菜单「退出」/ NSApp.terminate）时放行；
    // 否则按「关闭按钮隐藏到托盘」设置隐藏或关闭。
    if closeToTray && !AppDelegate.isTerminating {
      self.orderOut(nil) // 隐藏窗口，应用继续在菜单栏运行
      return false
    }
    return true
  }

  /// 与 App 主题背景色一致（暗色 #080808 / 亮色 #F7F7F7，见
  /// app_visual_theme.dart），启动首帧前先用系统外观定一个接近的底色。
  private func resolveInitialBackground() -> NSColor {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    if isDark {
      return NSColor(srgbRed: 0x08 / 255.0, green: 0x08 / 255.0, blue: 0x08 / 255.0, alpha: 1)
    }
    return NSColor(srgbRed: 0xF7 / 255.0, green: 0xF7 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
  }
}

private final class MacosStatusBarController: NSObject {
  private static let marqueeStatusItemLength: CGFloat = 210
  private static let marqueeTitleWidth: CGFloat = 170
  private static let marqueeInterval: TimeInterval = 0.25
  private static let marqueeGap = "     "
  private static let marqueeHoldTicks = 4

  private let statusItem: NSStatusItem
  private let methodChannel: FlutterMethodChannel
  private weak var mainWindow: MainFlutterWindow?
  private var lastTitle = "飞牛音乐"
  private var lastArtist = ""
  private var displayText = "飞牛音乐"
  private var isPlaying = false
  private var isIdle = true
  private var isStatusItemVisible = true
  private var marqueeTimer: Timer?
  private var marqueeCharacters: [Character] = []
  private var marqueeOffset = 0
  private var marqueeHoldTicks = 0

  init(binaryMessenger: FlutterBinaryMessenger, mainWindow: MainFlutterWindow?) {
    self.mainWindow = mainWindow
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    methodChannel = FlutterMethodChannel(
      name: "com.feiniu.music/statusbar",
      binaryMessenger: binaryMessenger)
    super.init()

    configureStatusItemButton()
    updateStatusItemTitle()
    statusItem.button?.toolTip = "飞牛音乐"
    statusItem.menu = buildMenu()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    DispatchQueue.main.async { [weak self] in
      self?.methodChannel.invokeMethod("ready", arguments: nil)
    }
  }

  private func configureStatusItemButton() {
    guard let button = statusItem.button,
          let image = NSImage(named: "StatusBarIcon") else {
      return
    }
    image.isTemplate = true
    image.size = NSSize(width: 18, height: 18)
    button.image = image
    button.imagePosition = .imageLeading
    button.imageScaling = .scaleProportionallyDown
    button.cell?.lineBreakMode = .byClipping
    button.setAccessibilityLabel("飞牛音乐")
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false

    let titleItem = NSMenuItem(title: lastTitle, action: nil, keyEquivalent: "")
    titleItem.isEnabled = false
    menu.addItem(titleItem)
    if !lastArtist.isEmpty {
      let artistItem = NSMenuItem(title: lastArtist, action: nil, keyEquivalent: "")
      artistItem.isEnabled = false
      menu.addItem(artistItem)
    }
    menu.addItem(NSMenuItem.separator())

    let showItem = NSMenuItem(
      title: "显示主窗口", action: #selector(showMainWindowTapped(_:)), keyEquivalent: "")
    showItem.target = self
    menu.addItem(showItem)
    menu.addItem(NSMenuItem.separator())

    let playItem = NSMenuItem(
      title: isPlaying ? "暂停" : "播放",
      action: #selector(playPauseTapped(_:)),
      keyEquivalent: "")
    playItem.target = self
    menu.addItem(playItem)

    let nextItem = NSMenuItem(title: "下一首", action: #selector(nextTapped(_:)), keyEquivalent: "")
    nextItem.target = self
    menu.addItem(nextItem)

    let previousItem = NSMenuItem(title: "上一首", action: #selector(previousTapped(_:)), keyEquivalent: "")
    previousItem.target = self
    menu.addItem(previousItem)
    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(title: "退出 飞牛音乐", action: #selector(quitTapped(_:)), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
    return menu
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "ping":
      result(nil)
    case "setState":
      if let args = call.arguments as? [String: Any] {
        lastTitle = (args["title"] as? String) ?? "飞牛音乐"
        lastArtist = (args["artist"] as? String) ?? ""
        displayText = (args["displayText"] as? String) ?? lastTitle
        isPlaying = (args["isPlaying"] as? Bool) ?? false
        isIdle = (args["isIdle"] as? Bool) ?? false
        updateStatusItemTitle()
        if isIdle || lastTitle.isEmpty {
          statusItem.button?.toolTip = "飞牛音乐"
        } else {
          let playbackState = isPlaying ? "正在播放" : "已暂停"
          let songDescription = lastArtist.isEmpty ? lastTitle : "\(lastTitle) — \(lastArtist)"
          statusItem.button?.toolTip = "\(playbackState)：\(songDescription)"
        }
        statusItem.menu = buildMenu()
      }
      result(nil)
    case "show":
      isStatusItemVisible = true
      statusItem.isVisible = true
      updateStatusItemTitle()
      result(nil)
    case "hide":
      isStatusItemVisible = false
      stopMarquee()
      statusItem.isVisible = false
      result(nil)
    case "setCloseToTray":
      if let enabled = call.arguments as? Bool {
        mainWindow?.closeToTray = enabled
        if !enabled, let window = mainWindow, !window.isVisible {
          // 关闭该设置且窗口正隐藏 → 恢复显示，避免「看不到窗口也退不出应用」。
          window.makeKeyAndOrderFront(nil)
        }
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func updateStatusItemTitle() {
    stopMarquee()

    let title = isIdle || displayText.isEmpty ? "飞牛音乐" : displayText
    guard let button = statusItem.button else { return }
    button.setAccessibilityLabel(title)

    guard isStatusItemVisible, titleWidth(title, font: button.font) > Self.marqueeTitleWidth else {
      statusItem.length = NSStatusItem.variableLength
      button.title = title
      return
    }

    statusItem.length = Self.marqueeStatusItemLength
    button.title = title
    marqueeCharacters = Array(title + Self.marqueeGap)
    marqueeHoldTicks = Self.marqueeHoldTicks

    let timer = Timer(timeInterval: Self.marqueeInterval, repeats: true) { [weak self] _ in
      self?.advanceMarquee()
    }
    marqueeTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func advanceMarquee() {
    guard let button = statusItem.button, !marqueeCharacters.isEmpty else { return }
    if marqueeHoldTicks > 0 {
      marqueeHoldTicks -= 1
      return
    }

    marqueeOffset = (marqueeOffset + 1) % marqueeCharacters.count
    if marqueeOffset == 0 {
      marqueeHoldTicks = Self.marqueeHoldTicks
    }
    let rotated = Array(marqueeCharacters[marqueeOffset...])
      + Array(marqueeCharacters[..<marqueeOffset])
    button.title = String(rotated)
  }

  private func stopMarquee() {
    marqueeTimer?.invalidate()
    marqueeTimer = nil
    marqueeCharacters = []
    marqueeOffset = 0
    marqueeHoldTicks = 0
  }

  private func titleWidth(_ title: String, font: NSFont?) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.menuBarFont(ofSize: 0),
    ]
    return (title as NSString).size(withAttributes: attributes).width
  }

  @objc private func playPauseTapped(_ sender: Any) {
    methodChannel.invokeMethod("playPause", arguments: nil)
  }

  @objc private func nextTapped(_ sender: Any) {
    methodChannel.invokeMethod("next", arguments: nil)
  }

  @objc private func previousTapped(_ sender: Any) {
    methodChannel.invokeMethod("previous", arguments: nil)
  }

  @objc private func showMainWindowTapped(_ sender: Any) {
    guard let window = mainWindow else { return }
    window.makeKeyAndOrderFront(nil)
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @objc private func quitTapped(_ sender: Any) {
    NSApp.terminate(nil)
  }
}
