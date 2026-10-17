import Foundation
import CoreGraphics

public struct RGBA: Equatable, Sendable {
  public var a, r, g, b: Double

  public init(_ hex: String) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    if s.count == 8 {
      a = Double((v >> 24) & 0xFF); r = Double((v >> 16) & 0xFF); g = Double((v >> 8) & 0xFF); b = Double(v & 0xFF)
    } else {
      a = 255; r = Double((v >> 16) & 0xFF); g = Double((v >> 8) & 0xFF); b = Double(v & 0xFF)
    }
  }

  init(a: Double, r: Double, g: Double, b: Double) {
    self.a = a; self.r = r; self.g = g; self.b = b
  }

  public static func mix(_ x: RGBA, _ y: RGBA, _ k0: Double) -> RGBA {
    let k = max(0, min(1, k0))
    return RGBA(a: (x.a + (y.a - x.a) * k).rounded(), r: (x.r + (y.r - x.r) * k).rounded(),
                g: (x.g + (y.g - x.g) * k).rounded(), b: (x.b + (y.b - x.b) * k).rounded())
  }

  /// Cloudiness: the colour fades toward grey and darkens.
  public func dimmed(_ g0: Double) -> RGBA {
    let l = 0.3 * r + 0.59 * g + 0.11 * b
    let f = 1 - 0.3 * g0
    return RGBA(a: a, r: ((r + (l - r) * g0) * f).rounded(), g: ((g + (l - g) * g0) * f).rounded(),
                b: ((b + (l - b) * g0) * f).rounded())
  }
}

public enum SkyPhase: String, CaseIterable, Sendable { case dawn, day, dusk, night }

/// What to draw for the sky this tick, in sky-area coordinates (top-left origin).
public struct SkyRender: Sendable {
  public struct Shape: Sendable { public var rect: CGRect; public var color: RGBA; public var opacity: Double }
  public var top = RGBA("#00304A8C")
  public var bottom = RGBA("#1A304A8C")
  public var stars: [Shape] = []
  public var clouds: [(rects: [CGRect], opacity: Double)] = []
  public var cloudColor = RGBA("#B4B4BC")
  public var fog: [CGRect] = []
  public var fogOpacity: [Double] = []
  public var drops: [CGRect] = []
  public var flakes: [CGRect] = []
  public var ground: CGRect?
  public var groundColor = RGBA("#50A1A8B5")
  public var flash: Double = 0
  public var sun: (origin: CGPoint, opacity: Double, color: RGBA)?
  public var sunGlow: (center: CGPoint, opacity: Double)?
  public var moon: (origin: CGPoint, lit: [CGRect], dark: [CGRect], opacity: Double)?
  public var tooltip = ""

  public init() {}
}

/// The backdrop behind the percentage and Clawd: real sunrise/sunset colours, sun and moon on an arc,
/// stars, clouds, fog, rain, snow and lightning. Ported from sky.ps1.
public final class SkyEngine {
  public var force: SkyPhase?
  public var forceWx: Int?

  static let pal: [String: (RGBA, RGBA, Double)] = [
    "night": (RGBA("#00304A8C"), RGBA("#1A304A8C"), 0.0),
    "dawn": (RGBA("#00404E8A"), RGBA("#33E08A66"), 0.5),
    "day": (RGBA("#004A8CCB"), RGBA("#2E6FA8D8"), 1.0),
    "dusk": (RGBA("#00383070"), RGBA("#33D86A50"), 0.5)
  ]
  static let sunHigh = RGBA("#FDE68A"), sunLow = RGBA("#FB923C")
  static let snowDay = RGBA("#80DDE4EC"), snowNight = RGBA("#50A1A8B5")
  static let cloudDay = RGBA("#B4B4BC"), cloudNight = RGBA("#5E5E68"), cloudRain = RGBA("#52525B")

  public static let sunRows = ["..###..", ".#####.", "#######", "#######", "#######", ".#####.", "..###.."]
  static let cloudShapes = [
    ["....###.....", "..#######...", ".##########.", "############"],
    ["..###...", ".######.", "########"],
    ["...##.##..", ".########.", "##########"]
  ]

  struct Star { var fx, fy: Double }
  struct Cloud { var rows: [String]; var w: Double; var x = -1.0; var fy: Double; var v: Double; var fade = 0.0 }
  struct Fog { var x: Double; var fy: Double }
  struct Drop { var x = 0.0, y = -99.0, v = 0.0 }
  struct Flake { var x = 0.0, y = -99.0, v = 0.0, ph = 0.0 }

  var stars: [Star]
  var clouds: [Cloud]
  var fogs: [Fog]
  var drops = Array(repeating: Drop(), count: 40)
  var flakes = Array(repeating: Flake(), count: 34)
  var tick = 0
  var flash = 0
  var key = ""
  var w = 0.0, h = 0.0
  var light = 0.0
  var kind = WeatherKind.of(0)
  var starOp = 0.0
  var nClouds = 0, nRain = 0, nSnow = 0
  var cached = SkyRender()
  var moonKey = ""
  var moonLit: [CGRect] = []
  var moonDark: [CGRect] = []

  public init() {
    stars = (0..<20).map { _ in Star(fx: .random(in: 0..<1), fy: .random(in: 0..<1) * 0.6) }
    clouds = (0..<9).map { i in
      let rows = Self.cloudShapes[i % 3]
      return Cloud(rows: rows, w: Double(rows[0].count * 2), fy: 0.05 + 0.3 * .random(in: 0..<1), v: 0.7 + 0.6 * .random(in: 0..<1))
    }
    fogs = (0..<3).map { i in Fog(x: .random(in: 0..<1), fy: 0.42 + 0.2 * Double(i)) }
  }

  public static func pixels(_ rows: [String], px: CGFloat, at o: CGPoint = .zero) -> [CGRect] {
    var out: [CGRect] = []
    for (y, row) in rows.enumerated() {
      let c = Array(row)
      var x = 0
      while x < c.count {
        if c[x] != "#" { x += 1; continue }
        let x0 = x
        while x < c.count && c[x] == "#" { x += 1 }
        out.append(CGRect(x: o.x + CGFloat(x0) * px, y: o.y + CGFloat(y) * px, width: CGFloat(x - x0) * px, height: px))
      }
    }
    return out
  }

  /// Moon phase from the mean synodic month since the new moon of 6 January 2000.
  func setMoon(lat: Double, now: Date) {
    let P = 29.530588853
    let ref = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                             year: 2000, month: 1, day: 6, hour: 18, minute: 14).date!
    let days = now.timeIntervalSince(ref) / 86400
    let age = (days.truncatingRemainder(dividingBy: P) + P).truncatingRemainder(dividingBy: P)
    let k0 = "\(Int((age * 2).rounded()))|\(lat < 0)"
    if k0 == moonKey { return }
    moonKey = k0
    let th = 2 * Double.pi * age / P
    let k = cos(th)
    let n = 7
    let r = Double(n) / 2
    var lit: [String] = [], dark: [String] = []
    for y in 0..<n {
      var a = "", b = ""
      for x in 0..<n {
        var u = (Double(x) + 0.5 - r) / r
        let v = (Double(y) + 0.5 - r) / r
        if lat < 0 { u = -u }
        let inside = u * u + v * v <= 1.05
        let t = k * sqrt(max(0, 1 - v * v))
        let on = inside && (th < .pi ? u > t : u < -t)
        a += on ? "#" : "."
        b += (inside && !on) ? "#" : "."
      }
      lit.append(a); dark.append(b)
    }
    moonLit = Self.pixels(lit, px: 1.3)
    moonDark = Self.pixels(dark, px: 1.3)
  }

  func onArc(_ p: Double, half: Double) -> CGPoint? {
    if p < -0.06 || p > 1.06 { return nil }
    let alt = sin(Double.pi * p)
    return CGPoint(x: 7 + p * (w - 14) - half, y: h + 3 - alt * (h - 12) - half)
  }

  public static func phase(minutes t: Double, sunrise sr: Double, sunset ss: Double) -> SkyPhase {
    if t >= sr - 80 && t < sr + 30 { return .dawn }
    if t >= sr + 30 && t < ss - 30 { return .day }
    if t >= ss - 30 && t < ss + 80 { return .dusk }
    return .night
  }

  /// One tick. `sun` are local sunrise/sunset minutes; `weather` is nil when stale or missing.
  public func step(width: Double, height: Double, now: Date, sun: (sr: Double, ss: Double),
                   weather: Weather?, place: Place?) -> SkyRender {
    tick += 1
    guard width > 0, height > 0 else { return cached }
    if width != w || height != h {
      w = width; h = height; key = ""
      for i in clouds.indices where clouds[i].x < 0 { clouds[i].x = .random(in: 0..<1) * w }
    }
    let (sr, ss) = sun
    let cal = Calendar.current
    var t = Double(cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)) +
      Double(cal.component(.second, from: now)) / 60
    switch force {
    case .dawn: t = sr - 10
    case .day: t = (sr + ss) / 2
    case .dusk: t = ss + 10
    case .night: t = 0
    case nil: break
    }
    let code = forceWx ?? weather?.code ?? 0
    let wind = forceWx != nil ? 12.0 : (weather?.wind ?? 8.0)

    var r = cached
    let k0 = "\(Int(t))|\(code)|\(w)|\(h)"
    if k0 != key {
      key = k0
      kind = WeatherKind.of(code)
      let stops: [(Double, String)] = [(sr - 80, "night"), (sr - 10, "dawn"), (sr + 70, "day"),
                                       (ss - 70, "day"), (ss + 10, "dusk"), (ss + 80, "night")]
      var a = Self.pal["night"]!, b = Self.pal["night"]!
      var k = 0.0
      for i in 0..<(stops.count - 1) where t >= stops[i].0 && t < stops[i + 1].0 {
        a = Self.pal[stops[i].1]!; b = Self.pal[stops[i + 1].1]!
        k = (t - stops[i].0) / (stops[i + 1].0 - stops[i].0)
        break
      }
      light = a.2 + (b.2 - a.2) * k
      let g = kind.cover * 0.9
      r.top = RGBA.mix(a.0, b.0, k).dimmed(g)
      r.bottom = RGBA.mix(a.1, b.1, k).dimmed(g)
      r.ground = kind.snow > 0 ? CGRect(x: 0, y: h - 1.5, width: w, height: 1.5) : nil
      r.groundColor = RGBA.mix(Self.snowNight, Self.snowDay, light)
      var cc = RGBA.mix(Self.cloudNight, Self.cloudDay, light)
      if kind.rain > 0 || kind.storm { cc = RGBA.mix(cc, Self.cloudRain, 0.55) }
      r.cloudColor = cc

      let vis = max(0, 1 - kind.cover * 1.15)
      let p = (t - sr) / (ss - sr)
      if vis > 0, let o = onArc(p, half: 4.9) {
        let col = RGBA.mix(Self.sunLow, Self.sunHigh, sin(Double.pi * p) * 1.6)
        r.sun = (o, vis, col)
        if let gc = onArc(p, half: 10) { r.sunGlow = (CGPoint(x: gc.x + 10, y: gc.y + 10), vis) }
      } else {
        r.sun = nil
        r.sunGlow = nil
      }
      setMoon(lat: place?.lat ?? 50, now: now)
      let q = ((t - ss + 1440).truncatingRemainder(dividingBy: 1440)) / (sr + 1440 - ss)
      if vis > 0, let o = onArc(q, half: 4.55) { r.moon = (o, moonLit, moonDark, vis) } else { r.moon = nil }

      starOp = (1 - light * 2) * max(0, 1 - kind.cover * 1.4)
      let dens = max(1.0, w / 140.0)
      nClouds = min(clouds.count, Int((kind.cover * 5 * dens).rounded()))
      nRain = min(drops.count, Int((Double(kind.rain) * dens).rounded()))
      nSnow = min(flakes.count, Int((Double(kind.snow) * dens).rounded()))
      r.tooltip = tooltip(weather: weather, place: place, sr: sr, ss: ss)
    }

    r.stars = []
    if starOp > 0 {
      for (i, s) in stars.enumerated() {
        let op = starOp * (0.55 + 0.45 * sin(Double(tick) / 7.0 + Double(i) * 1.7))
        r.stars.append(.init(rect: CGRect(x: (s.fx * (w - 2)).rounded(), y: (2 + s.fy * h).rounded(), width: 1.2, height: 1.2),
                             color: RGBA("#F8FAFC"), opacity: op))
      }
    }

    r.clouds = []
    let drift = 0.04 + wind / 350.0
    for i in clouds.indices {
      let want = i < nClouds ? 1.0 : 0.0
      clouds[i].fade += max(-0.03, min(0.03, want - clouds[i].fade))
      if clouds[i].fade <= 0 { continue }
      clouds[i].x += drift * clouds[i].v
      if clouds[i].x > w { clouds[i].x = -clouds[i].w; clouds[i].fy = 0.05 + 0.3 * .random(in: 0..<1) }
      let o = CGPoint(x: clouds[i].x.rounded(), y: (clouds[i].fy * h).rounded())
      r.clouds.append((Self.pixels(clouds[i].rows, px: 2, at: o), 0.65 * clouds[i].fade))
    }

    r.fog = []
    r.fogOpacity = []
    if kind.fog {
      for i in fogs.indices {
        fogs[i].x = (fogs[i].x + 0.0015).truncatingRemainder(dividingBy: 1.6)
        r.fog.append(CGRect(x: (fogs[i].x - 0.6) * w, y: fogs[i].fy * h, width: w * 0.6, height: 3))
        r.fogOpacity.append(0.14 + 0.05 * sin(Double(tick) / 20.0 + fogs[i].fy * 10))
      }
    }

    let slant = min(1.2, wind / 25.0)
    r.drops = []
    for i in drops.indices {
      if i >= nRain { drops[i].y = -99; continue }
      if drops[i].y < -50 || drops[i].y > h {
        drops[i].x = .random(in: 0..<1) * (w + 10) - 10
        drops[i].y = drops[i].y < -50 ? .random(in: 0..<1) * h : -4
        drops[i].v = 3.5 + 1.5 * .random(in: 0..<1)
      }
      drops[i].y += drops[i].v
      drops[i].x += slant
      r.drops.append(CGRect(x: drops[i].x, y: drops[i].y, width: 1, height: 3.5))
    }
    r.flakes = []
    for i in flakes.indices {
      if i >= nSnow { flakes[i].y = -99; continue }
      if flakes[i].y < -50 || flakes[i].y > h {
        flakes[i].x = .random(in: 0..<1) * w
        flakes[i].y = flakes[i].y < -50 ? .random(in: 0..<1) * h : -2
        flakes[i].v = 0.3 + 0.35 * .random(in: 0..<1)
        flakes[i].ph = .random(in: 0..<1) * 6.28
      }
      flakes[i].y += flakes[i].v
      let fx = flakes[i].x + 1.5 * sin(Double(tick) / 9.0 + flakes[i].ph) + slant * flakes[i].y / 4
      r.flakes.append(CGRect(x: fx, y: flakes[i].y, width: 1.6, height: 1.6))
    }

    if kind.storm && flash <= 0 && Int.random(in: 0..<140) == 0 { flash = 7 }
    if flash > 0 {
      r.flash = [0, 0.18, 0.05, 0, 0.25, 0.1, 0.04][flash - 1]
      flash -= 1
    } else {
      r.flash = 0
    }
    cached = r
    return r
  }

  /// A settled still frame (for the widget): clouds fully faded in, no lightning flash.
  public func still(width: Double, height: Double, now: Date, sun: (sr: Double, ss: Double),
                    weather: Weather?, place: Place?) -> SkyRender {
    _ = step(width: width, height: height, now: now, sun: sun, weather: weather, place: place)
    for i in clouds.indices { clouds[i].fade = i < nClouds ? 1 : 0 }
    flash = 0
    var r = step(width: width, height: height, now: now, sun: sun, weather: weather, place: place)
    r.flash = 0
    flash = 0
    return r
  }

  func tooltip(weather: Weather?, place: Place?, sr: Double, ss: Double) -> String {
    var parts: [String] = []
    if force != nil || forceWx != nil {
      var what: [String] = []
      if let f = force { what.append(T("phase.\(f.rawValue)")) }
      if let c = forceWx { what.append(WeatherKind.of(c).name) }
      parts.append("dev · " + what.joined(separator: ", "))
    } else if let wx = weather {
      let temp = Int(wx.temp.rounded())
      var line = "\(temp > 0 ? "+" : "")\(temp)°, \(WeatherKind.of(wx.code).name)"
      if let c = place?.city, !c.isEmpty { line = "\(c) · \(line)" }
      parts.append(line)
      parts.append(T("sky.wind", Int((wx.wind / 3.6).rounded())))
    } else {
      parts.append(T("sky.noData"))
    }
    func hm(_ m: Double) -> String { String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60) }
    parts.append(T("sky.sun", hm(sr), hm(ss)))
    return parts.joined(separator: "\n")
  }
}
