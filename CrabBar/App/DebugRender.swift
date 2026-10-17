import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClawdCore

/// Developer aid: `--render <dir>` writes PNGs of the card (collapsed and expanded), the panel tabs and the settings
/// once data has arrived, so the UI can be checked without screen-recording permission.
/// With `--demo` the data is made up (see DemoMode.swift) and the widgets are rendered too; `--gif` adds an
/// animated Clawd. `--anonymize` replaces the account, `--lang de|en` picks the language.
@MainActor
enum DebugRender {
  static func scheduleIfRequested(model: AppModel, app: AppDelegate) {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Task { @MainActor in
      if let j = args.firstIndex(of: "--lang"), j + 1 < args.count { L10n.setting = args[j + 1] }
      try? await Task.sleep(for: .seconds(model.demo ? 3 : 20))
      if model.demo { model.startDemo() }
      model.setAnimating("debug", true)
      // For screenshots meant for others: no real account in the footer.
      if args.contains("--anonymize") { model.account = Account(loggedIn: true, plan: "Max", email: "you@example.com") }
      try? await Task.sleep(for: .seconds(2))
      let expanded = model.config.expanded
      model.config.expanded = false
      write(UsageCard(model: model), to: dir.appendingPathComponent("card.png"))
      model.config.expanded = true
      if model.projects == nil { model.scanProjects() }
      try? await Task.sleep(for: .seconds(model.demo ? 1 : 8))
      write(UsageCard(model: model), to: dir.appendingPathComponent("card-expanded.png"))
      model.config.expanded = expanded
      for tab in ["chat", "remind", "lists"] {
        app.openPanel(tab: tab)
        try? await Task.sleep(for: .seconds(2))
        if let w = app.panelWindow { capture(w, to: dir.appendingPathComponent("panel-\(tab).png")) }
      }
      app.panelWindow?.close()
      app.openSettings()
      try? await Task.sleep(for: .seconds(2))
      if let w = app.settingsWindow { capture(w, to: dir.appendingPathComponent("settings.png")) }
      app.settingsWindow?.close()
      if model.demo { write(widgets(Demo.snapshot()), to: dir.appendingPathComponent("widgets.png")) }
      if args.contains("--gif") { gif(to: dir.appendingPathComponent("clawd.gif")) }
      model.setAnimating("debug", false)
      try? "done".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }
  }

  static func write<V: View>(_ v: V, to url: URL) {
    let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
  }

  /// The app may always draw its own windows. Converted to sRGB so the PNG carries no display profile.
  static func capture(_ w: NSWindow, to url: URL) {
    guard let v = w.contentView?.superview ?? w.contentView,
          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let out = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
    try? out.representation(using: .png, properties: [:])?.write(to: url)
  }

  // MARK: - widgets

  /// The three widget sizes side by side, drawn like on the desktop.
  static func widgets(_ s: WidgetSnapshot) -> some View {
    let now = Date()
    func tile<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat) -> some View {
      v.padding(16)
        .frame(width: w, height: h)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.border, lineWidth: 1))
    }
    return HStack(alignment: .top, spacing: 18) {
      VStack(spacing: 18) {
        tile(SmallView(s: s, now: now), 170, 170)
        tile(MediumView(s: s, now: now), 364, 170)
      }
      tile(LargeView(s: s, now: now), 364, 358)
    }
    .padding(20)
    .background(Color(hex: "#2B2F48"))
  }

  // MARK: - animated Clawd

  struct GIFFrame: View {
    var render: MascotRender
    var sky: SkyRender
    var pct: Int

    var body: some View {
      HStack(alignment: .bottom, spacing: 0) {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
          Text("\(pct)").font(.system(size: 30, weight: .light)).foregroundStyle(Level.of(pct).color).monospacedDigit()
          Text("%").font(.system(size: 14)).foregroundStyle(Palette.textHead)
        }
        .frame(width: GIF.pctWidth, alignment: .leading)
        Canvas { ctx, size in Draw.mascot(&ctx, render, size: size) }
          .frame(width: GIF.areaWidth, height: GIF.areaHeight)
          .padding(.leading, 10)
      }
      .frame(width: GIF.width, height: GIF.height, alignment: .bottomLeading)
      .background(alignment: .bottom) {
        Canvas { ctx, size in Draw.sky(&ctx, sky, size: size) }
          .mask(EdgeFade())
          .frame(height: GIF.height)
      }
      .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
      .background(Palette.card)
    }
  }

  enum GIF {
    static let width: CGFloat = 238
    static let height: CGFloat = 50
    static let pctWidth: CGFloat = 68
    static let areaWidth: CGFloat = width - pctWidth - 10
    static let areaHeight: CGFloat = 44
  }

  /// A fixed little story: asleep in the sand, wakes up when a session starts, jumps, works, celebrates a reset.
  static func gif(to url: URL) {
    let engine = MascotEngine(entrance: false)
    let sky = SkyEngine()
    sky.force = .day
    var frames: [(CGImage, Double)] = []
    let idle = ClaudeSession(pid: 1, name: "my-app", cwd: "~", busy: false, waiting: false)
    let busy = ClaudeSession(pid: 1, name: "my-app", cwd: "~", busy: true, waiting: false)
    func play(_ ticks: Int, sessions: [ClaudeSession], pct: Int, act: String? = nil) {
      engine.update(sessions: sessions, usage: Usage(session: pct), warn: 60, critPct: 85)
      if let act { engine.start(act) }
      for _ in 0..<ticks {
        let r = engine.step(areaWidth: GIF.areaWidth, areaHeight: GIF.areaHeight, hovering: false, mouseX: nil)
        let s = sky.step(width: GIF.width, height: GIF.height, now: Date(), sun: (432, 1111),
                         weather: Weather(code: 0, temp: 18, wind: 6), place: nil)
        let rr = ImageRenderer(content: GIFFrame(render: r, sky: s, pct: pct).environment(\.colorScheme, .dark))
        rr.scale = 2
        if let img = rr.cgImage { frames.append((img, Double(r.intervalMs) / 1000)) }
      }
    }
    play(45, sessions: [], pct: 37)
    play(45, sessions: [idle], pct: 37)
    play(16, sessions: [idle], pct: 37, act: "jump")
    play(50, sessions: [busy], pct: 37)
    play(45, sessions: [idle], pct: 0, act: "celebrate")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (img, delay) in frames {
      CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
  }
}
