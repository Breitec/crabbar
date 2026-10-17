import SwiftUI

public extension RGBA {
  var color: Color { Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a / 255) }
}

public enum Draw {
  public static func fill(_ ctx: inout GraphicsContext, _ rects: [CGRect], _ color: Color, offset: CGPoint = .zero) {
    guard !rects.isEmpty else { return }
    var p = Path()
    for r in rects { p.addRect(r.offsetBy(dx: offset.x, dy: offset.y)) }
    ctx.fill(p, with: .color(color))
  }

  /// Clawd's sprite with its top-left corner at `origin`, scaled by `scale`.
  public static func clawd(_ ctx: inout GraphicsContext, frame: ClawdFrame, origin: CGPoint, scale: CGFloat = 1) {
    let g = ClawdSprite.geometry(frame)
    func pts(_ rs: [ClawdSprite.Rect]) -> [CGRect] {
      rs.map { r in
        let s = r.scaled()
        return CGRect(x: origin.x + s.minX * scale, y: origin.y + s.minY * scale, width: s.width * scale, height: s.height * scale)
      }
    }
    fill(&ctx, pts(g.body), Palette.clawd)
    fill(&ctx, pts(g.eyes), Palette.eyes)
    fill(&ctx, pts(g.fx), Palette.dead)
    fill(&ctx, pts(g.sand), Palette.sand)
  }

  /// One mascot tick into an area of `size` (ground at the bottom edge).
  public static func mascot(_ ctx: inout GraphicsContext, _ r: MascotRender, size: CGSize) {
    let H = size.height
    let spriteTop = H - (r.bottom + ClawdSprite.height)
    clawd(&ctx, frame: r.frame, origin: CGPoint(x: r.x, y: spriteTop))
    if let s = r.sweat {
      var c = ctx
      c.opacity = s.opacity
      c.fill(Path(CGRect(x: r.x + s.left, y: spriteTop + s.top, width: 3, height: 4.5)), with: .color(Palette.sweat))
    }
    if let z = r.z {
      var c = ctx
      c.opacity = z.opacity
      c.draw(Text("z").font(.system(size: z.size, weight: .semibold)).foregroundColor(Palette.textHead),
             at: CGPoint(x: z.left, y: H - z.bottom), anchor: .bottomLeading)
    }
    if let b = r.bubble {
      ctx.draw(Text(b.text).font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: b.colorHex)),
               at: CGPoint(x: b.left + 6, y: H - b.bottom), anchor: .bottom)
    }
    for d in r.dust + r.confetti {
      var c = ctx
      c.opacity = d.opacity
      let h: CGFloat = d.colorHex == "#8B8B94" ? 2 : 2.5
      c.fill(Path(CGRect(x: d.left, y: H - d.bottom - h, width: d.width, height: h)), with: .color(Color(hex: d.colorHex)))
    }
    if let l = r.love {
      var c = ctx
      c.opacity = l.opacity
      fill(&c, ClawdSprite.heart(), Palette.crit, offset: CGPoint(x: l.left, y: H - l.bottom - 8.4))
    }
    if let s = r.soul {
      var c = ctx
      c.opacity = s.opacity
      fill(&c, s.rects, Palette.soul, offset: CGPoint(x: s.left, y: H - s.topFromBottom))
    }
    if !r.tag.isEmpty {
      ctx.draw(Text(r.tag).font(.system(size: 8)).foregroundColor(Palette.textDim), at: .zero, anchor: .topLeading)
    }
  }

  public static func sky(_ ctx: inout GraphicsContext, _ s: SkyRender, size: CGSize) {
    let full = CGRect(origin: .zero, size: size)
    ctx.fill(Path(full), with: .linearGradient(Gradient(colors: [s.top.color, s.bottom.color]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    var fx = ctx
    fx.opacity = 0.7
    for st in s.stars {
      var c = fx
      c.opacity *= max(0, st.opacity)
      c.fill(Path(st.rect), with: .color(st.color.color))
    }
    if let m = s.moon {
      var c = fx
      c.opacity *= m.opacity
      fill(&c, m.dark, Color(hex: "#2EE5E7EB"), offset: m.origin)
      fill(&c, m.lit, Color(hex: "#F1F5F9"), offset: m.origin)
    }
    if let g = s.sunGlow {
      var c = fx
      c.opacity *= g.opacity
      let r = CGRect(x: g.center.x - 10, y: g.center.y - 10, width: 20, height: 20)
      c.fill(Path(ellipseIn: r), with: .radialGradient(Gradient(colors: [Color(hex: "#40FDE68A"), Color(hex: "#00FDE68A")]),
                                                       center: g.center, startRadius: 0, endRadius: 10))
    }
    if let sun = s.sun {
      var c = fx
      c.opacity *= sun.opacity
      fill(&c, SkyEngine.pixels(SkyEngine.sunRows, px: 1.4), sun.color.color, offset: sun.origin)
    }
    for cl in s.clouds {
      var c = fx
      c.opacity *= cl.opacity
      fill(&c, cl.rects, s.cloudColor.color)
    }
    for (i, f) in s.fog.enumerated() {
      var c = fx
      c.opacity *= s.fogOpacity[i]
      c.fill(Path(f), with: .linearGradient(Gradient(colors: [Color(hex: "#00E5E7EB"), Color(hex: "#E5E7EB"), Color(hex: "#00E5E7EB")]),
                                             startPoint: CGPoint(x: f.minX, y: 0), endPoint: CGPoint(x: f.maxX, y: 0)))
    }
    fill(&fx, s.drops, Color(hex: "#8093C5FD"))
    fill(&fx, s.flakes, Color(hex: "#C0E4E4E7"))
    if let g = s.ground { fx.fill(Path(g), with: .color(s.groundColor.color)) }
    if s.flash > 0 {
      var c = fx
      c.opacity *= s.flash
      c.fill(Path(full), with: .color(Color(hex: "#F8FAFC")))
    }
  }
}

/// Horizontal fade at both ends, like the original OpacityMask.
public struct EdgeFade: View {
  public init() {}
  public var body: some View {
    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                           .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                   startPoint: .leading, endPoint: .trailing)
  }
}

/// Three pixel hearts with halves.
public struct HeartsView: View {
  public var halves: Int
  public var beat: CGFloat
  public var scale: CGFloat

  public init(halves: Int, beat: CGFloat = 1, scale: CGFloat = 1) {
    self.halves = halves
    self.beat = beat
    self.scale = scale
  }

  public var body: some View {
    HStack(spacing: 2.5 * scale) {
      ForEach(0..<3, id: \.self) { i in
        let h = halves - 2 * i
        Canvas { ctx, _ in
          var c = ctx
          c.scaleBy(x: scale, y: scale)
          Draw.fill(&c, ClawdSprite.heart(), Palette.heartOff)
          if h >= 2 { Draw.fill(&c, ClawdSprite.heart(), Palette.crit) }
          else if h == 1 { Draw.fill(&c, ClawdSprite.heart(maxCol: 3), Palette.crit) }
        }
        .frame(width: 9.8 * scale, height: 8.4 * scale)
        .scaleEffect(beat)
      }
    }
  }
}

public struct LimitBar: View {
  public var pct: Int?
  public var color: Color
  public var height: CGFloat

  public init(pct: Int?, color: Color, height: CGFloat) {
    self.pct = pct
    self.color = color
    self.height = height
  }

  public var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: height / 2).fill(Palette.track)
        RoundedRectangle(cornerRadius: height / 2).fill(color)
          .frame(width: max(0, CGFloat(min(100, pct ?? 0)) / 100 * g.size.width))
      }
    }
    .frame(height: height)
  }
}
