import SwiftUI
import AppKit
import ClawdCore

@main
struct CrabBarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

  var body: some Scene {
    Settings { EmptyView() }
  }
}

/// Menu bar icon (left click: the card in a popover, right click: the tray menu), the optional floating
/// window, Clawd's panel, settings and reminder cards.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
  /// With @NSApplicationDelegateAdaptor, NSApp.delegate is SwiftUI's proxy, not this object.
  nonisolated(unsafe) static weak var shared: AppDelegate?

  let model = AppModel()
  var statusItem: NSStatusItem?
  let popover = NSPopover()
  var floating: NSPanel?
  var panelWindow: NSWindow?
  var settingsWindow: NSWindow?
  var popups: ReminderPopups!
  var iconKey = ""
  private var launched = false
  private var pendingURLs: [URL] = []
  private var movingProgrammatically = false

  override init() {
    super.init()
    AppDelegate.shared = self
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    if let b = item.button {
      b.target = self
      b.action = #selector(statusClicked(_:))
      b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    popover.appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingController(rootView: popoverContent)
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host

    popups = ReminderPopups(model: model)
    model.reminders.show = { [weak self] r, file, text in self?.popups.show(r, doneFile: file, text: text) }
    model.openPanel = { [weak self] tab in self?.openPanel(tab: tab) }
    model.onChange = { [weak self] in self?.updateIcon() }
    Notifier.requestAuth()
    observeWidget()
    updateIcon()
    model.start()
    syncFloating()
    DebugRender.scheduleIfRequested(model: model, app: self)
    launched = true
    let urls = pendingURLs
    pendingURLs = []
    if !urls.isEmpty { handle(urls) }
  }

  func popoverDidShow(_ n: Notification) { model.setAnimating("popover", true) }
  func popoverDidClose(_ n: Notification) { model.setAnimating("popover", false) }

  var popoverContent: some View {
    UsageCard(model: model, onHide: { [weak self] in self?.popover.performClose(nil) },
              onExit: { NSApp.terminate(nil) })
      .padding(1)
  }

  func applicationWillTerminate(_ note: Notification) {
    model.clawdSession.stop()
  }

  func application(_ app: NSApplication, open urls: [URL]) {
    // A widget click can launch the app: the URL may arrive before launching has finished.
    guard launched else { pendingURLs += urls; return }
    handle(urls)
  }

  func handle(_ urls: [URL]) {
    for u in urls where u.scheme == "crabbar" {
      switch u.host {
      case "refresh": model.refreshNow()
      case "panel": openPanel(tab: nil)
      default: showPopover()
      }
    }
  }

  // MARK: - status item

  @objc func statusClicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      guard let item = statusItem else { return }
      item.menu = buildMenu()
      item.button?.performClick(nil)
      item.menu = nil
    } else if popover.isShown {
      popover.performClose(nil)
    } else {
      showPopover()
    }
  }

  func showPopover() {
    guard let b = statusItem?.button else { return }
    model.refreshSessions()
    popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    NSApp.activate()
  }

  func updateIcon() {
    let u = model.usage
    let key = "\(u?.session ?? -1)|\(model.sessionLevel)|\(model.config.menuBarPercent)|\(model.claudeError ?? "")"
    if key != iconKey {
      iconKey = key
      statusItem?.button?.image = MenuBarIcon.image(pct: u?.session, level: model.sessionLevel, showText: model.config.menuBarPercent)
    }
    statusItem?.button?.toolTip = model.claudeError ?? model.trayTip
  }

  func buildMenu() -> NSMenu {
    let m = NSMenu()
    func item(_ title: String, _ action: @escaping () -> Void, on: Bool = false, enabled: Bool = true) {
      let i = ClosureMenuItem(title: title, action: action)
      i.state = on ? .on : .off
      i.isEnabled = enabled
      m.addItem(i)
    }
    let head = NSMenuItem(title: "CrabBar · Claude Code v\(model.verLocal ?? "?")", action: nil, keyEquivalent: "")
    head.isEnabled = false
    m.addItem(head)
    if let r = model.appUpdate { item(T("app.menu", r.version), { [weak self] in self?.model.openReleasePage() }) }
    m.addItem(.separator())
    item(T("menu.toggle"), { [weak self] in self?.toggleFloating() }, on: model.config.floating)
    item(T("menu.panel"), { [weak self] in self?.openPanel(tab: nil) })
    item(T("menu.refresh"), { [weak self] in self?.model.refreshNow() })
    item(T("menu.bigger"), { [weak self] in self?.model.updateConfig { $0.scale = min(4, (($0.scale + 0.1) * 100).rounded() / 100) } })
    item(T("menu.smaller"), { [weak self] in self?.model.updateConfig { $0.scale = max(0.6, (($0.scale - 0.1) * 100).rounded() / 100) } })
    m.addItem(.separator())
    item(T("menu.advisor"), { [weak self] in self?.model.advisor.scan(); self?.openPanel(tab: "chat") })
    item(T("menu.clawdSession"), { [weak self] in self?.model.updateConfig { $0.clawdSession.toggle() } }, on: model.config.clawdSession)
    item(T("menu.clawdRestart"), { [weak self] in self?.model.clawdSession.restart() }, enabled: model.config.clawdSession)
    m.addItem(.separator())
    let lang = NSMenuItem(title: T("menu.language"), action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for (code, name) in [("system", T("menu.langSystem")), ("de", "Deutsch"), ("en", "English")] {
      let i = ClosureMenuItem(title: name) { [weak self] in self?.model.updateConfig { $0.language = code } }
      i.state = model.config.language == code ? .on : .off
      sub.addItem(i)
    }
    lang.submenu = sub
    m.addItem(lang)
    item(T("menu.settings"), { [weak self] in self?.openSettings() })
    item(T("menu.config"), { NSWorkspace.shared.open(AppPaths.config) })
    m.addItem(.separator())
    item(T("menu.exit"), { NSApp.terminate(nil) })
    return m
  }

  // MARK: - floating window

  func toggleFloating() {
    model.updateConfig { $0.floating.toggle() }
    syncFloating()
  }

  func syncFloating() {
    let c = model.config
    if !c.floating {
      floating?.orderOut(nil)
      model.setAnimating("floating", false)
      return
    }
    if floating == nil {
      let host = NSHostingView(rootView: UsageCard(model: model, floating: true,
                                                   onHide: { [weak self] in self?.toggleFloating() },
                                                   onExit: { NSApp.terminate(nil) }))
      let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                      styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = true
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false
      p.isMovableByWindowBackground = true
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.contentView = host
      p.delegate = self
      host.autoresizingMask = [.width, .height]
      if let l = c.left, let t = c.top {
        p.setFrameTopLeftPoint(NSPoint(x: l, y: t))
      } else if let s = NSScreen.main?.visibleFrame {
        p.setFrameTopLeftPoint(NSPoint(x: s.maxX - host.fittingSize.width - 20, y: s.maxY - 20))
      }
      floating = p
      sizeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.fitFloating() }
      }
    }
    floating?.level = c.topmost ? .floating : .normal
    floating?.alphaValue = c.opacity
    floating?.orderFrontRegardless()
    model.setAnimating("floating", true)
  }

  var sizeTimer: Timer?

  /// The card grows and shrinks (details, Fable row); keep the top-left corner where it is.
  func fitFloating() {
    guard let p = floating, p.isVisible, let v = p.contentView else { return }
    let s = v.fittingSize
    if abs(s.height - p.frame.height) > 0.5 || abs(s.width - p.frame.width) > 0.5 {
      let top = p.frame.maxY
      movingProgrammatically = true
      p.setFrame(NSRect(x: p.frame.minX, y: top - s.height, width: s.width, height: s.height), display: true)
      movingProgrammatically = false
    }
    p.level = model.config.topmost ? .floating : .normal
    p.alphaValue = model.config.opacity
  }

  func windowDidMove(_ n: Notification) {
    guard let p = n.object as? NSPanel, p === floating, !movingProgrammatically else { return }
    model.updateConfig { $0.left = p.frame.minX; $0.top = p.frame.maxY }
  }

  // MARK: - windows

  func openPanel(tab: String?) {
    if panelWindow == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
      w.title = "Clawd"
      w.appearance = NSAppearance(named: .darkAqua)
      w.isReleasedWhenClosed = false
      w.contentViewController = NSHostingController(rootView: PanelView(model: model))
      w.center()
      if let s = NSScreen.main?.visibleFrame { w.setFrameTopLeftPoint(NSPoint(x: s.maxX - 420, y: s.maxY - 40)) }
      panelWindow = w
    }
    popover.performClose(nil)
    panelWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if let tab { NotificationCenter.default.post(name: .clawdPanelTab, object: tab) }
  }

  func openSettings() {
    if settingsWindow == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
      w.title = T("menu.settings").replacingOccurrences(of: "…", with: "")
      w.isReleasedWhenClosed = false
      w.contentViewController = NSHostingController(rootView: SettingsView(model: model))
      w.center()
      settingsWindow = w
    }
    popover.performClose(nil)
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  // MARK: - widget

  /// The widget's refresh button posts a Darwin notification (the extension is sandboxed).
  func observeWidget() {
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let observer = Unmanaged.passUnretained(self).toOpaque()
    CFNotificationCenterAddObserver(center, observer, { _, obs, _, _, _ in
      guard let obs else { return }
      let me = Unmanaged<AppDelegate>.fromOpaque(obs).takeUnretainedValue()
      DispatchQueue.main.async { MainActor.assumeIsolated { me.model.refreshNow() } }
    }, SharedStore.refreshNotification as CFString, nil, .deliverImmediately)
  }
}

final class ClosureMenuItem: NSMenuItem {
  let handler: () -> Void

  init(title: String, action handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError() }

  @objc func fire() { handler() }
}
