import SwiftUI

/// Pieces of the widgets that the iPhone app shows as well.
public extension WidgetSnapshot {
  var level: Level { Level.of(usage?.session, warn: warnPercent, crit: critPercent) }

  func resetLine(_ now: Date) -> String {
    if let e = error, usage == nil { return e }
    guard let u = usage, u.session != nil else { return T("noData") }
    if let r = u.sessionReset {
      return Format.span(until: r, now: now).map { T("reset.in", $0) } ?? T("reset.closed")
    }
    return ""
  }

  func limitText(_ pct: Int?, _ reset: Date?, _ now: Date) -> String {
    guard let pct else { return T("noData") }
    var s = "\(pct)%"
    if let r = reset, let sp = Format.span(until: r, now: now) { s += " · \(sp)" }
    return s
  }

  var sessionsLine: String {
    if sessions == 0 { return T("sess.none") }
    var line = plural(sessions, "session")
    if busy > 0 || waiting == 0 { line += " · " + T("sess.busy", busy) }
    if waiting > 0 { line += " · " + T("sess.wait", waiting) }
    return line
  }
}

public struct ClawdStill: View {
  public var mood: Mood
  public var halves: Int?

  public init(mood: Mood, halves: Int?) {
    self.mood = mood
    self.halves = halves
  }

  public var body: some View {
    let (frame, bubble) = MascotEngine.stillFrame(for: mood, halves: halves)
    Canvas { ctx, size in
      let scale = min(size.width / ClawdSprite.width, size.height / (ClawdSprite.height - ClawdSprite.sink + 6))
      let w = ClawdSprite.width * scale
      let origin = CGPoint(x: (size.width - w) / 2, y: size.height - (ClawdSprite.height - ClawdSprite.sink) * scale)
      Draw.clawd(&ctx, frame: frame, origin: origin, scale: scale)
      if let b = bubble {
        ctx.draw(Text(b).font(.system(size: 9 * scale, weight: .bold)).foregroundColor(Palette.warn),
                 at: CGPoint(x: size.width / 2, y: origin.y - 2), anchor: .bottom)
      }
      if mood == .sleep || mood == .doze {
        ctx.draw(Text("z").font(.system(size: 6 * scale, weight: .semibold)).foregroundColor(Palette.textHead),
                 at: CGPoint(x: origin.x + w + 2, y: origin.y + 2), anchor: .bottomLeading)
      }
    }
  }
}

public struct SkyStill: View {
  public var s: WidgetSnapshot
  public var now: Date

  public init(s: WidgetSnapshot, now: Date) {
    self.s = s
    self.now = now
  }

  public var body: some View {
    Canvas { ctx, size in
      let e = SkyEngine()
      let wx = s.weatherCode.map { Weather(code: $0, temp: s.temp ?? 0, wind: 8) }
      let r = e.still(width: size.width, height: size.height, now: now, sun: (s.sunrise, s.sunset), weather: wx,
                      place: Place(lat: s.lat, lon: 0, city: s.city))
      Draw.sky(&ctx, r, size: size)
    }
    .mask(EdgeFade())
  }
}

/// The last 24 hours of session (green, filled) and week (blue).
public struct DayChart: View {
  public var s: WidgetSnapshot
  public var now: Date

  public init(s: WidgetSnapshot, now: Date) {
    self.s = s
    self.now = now
  }

  public var body: some View {
    Canvas { ctx, size in
      let h = UsageHistory(samples: s.history)
      let t1 = UsageHistory.minute(now), t0 = t1 - 1440
      func xp(_ t: Int) -> CGFloat { size.width * CGFloat(t - t0) / CGFloat(t1 - t0) }
      func yp(_ v: Int) -> CGFloat { 1 + (size.height - 2) * (1 - CGFloat(min(100, v)) / 100) }
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#0AFFFFFF")))
      for (col, color) in [(2, Palette.week), (1, Palette.ok)] {
        for run in h.runs(from: t0, column: col) {
          var pts = run.map { CGPoint(x: xp($0.0), y: yp($0.1)) }
          if pts.count == 1 { pts.append(CGPoint(x: pts[0].x + 1, y: pts[0].y)) }
          if col == 1 {
            var area = Path()
            area.move(to: CGPoint(x: pts[0].x, y: size.height))
            area.addLines(pts)
            area.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(Palette.histArea))
          }
          ctx.stroke(Path { $0.addLines(pts) }, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
      }
    }
  }
}
