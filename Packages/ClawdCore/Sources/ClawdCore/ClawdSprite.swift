import Foundation
import CoreGraphics

/// Clawd from the Claude Code welcome screen, built from the same block glyphs:
/// 9 cells by 3 rows, each cell split into 2x4 pixels so quadrant glyphs map losslessly.
public enum ClawdSprite {
  public static let cols = 9
  public static let rows = 3
  public static let px: CGFloat = 2.0
  public static let py: CGFloat = 2.2
  public static let width: CGFloat = 2 * CGFloat(cols) * px          // 36
  public static let height: CGFloat = 4 * CGFloat(rows) * py         // 26.4
  /// The lower half of the legs row is empty: the sprite is lowered by it to the ground.
  public static let sink: CGFloat = 2 * py
  public static let frameMs = 60
  public static let burrowDig = 4

  static let W = 2 * cols
  static let H = 4 * rows

  /// Glyph quadrants as bits: 1 top-left, 2 top-right, 4 bottom-left, 8 bottom-right.
  static let quad: [Character: Int] = [
    " ": 0, "█": 15, "▀": 3, "▄": 12, "▌": 5, "▐": 10, "▘": 1, "▝": 2, "▖": 4, "▗": 8,
    "▛": 7, "▜": 11, "▙": 13, "▟": 14
  ]

  struct Arms { let r1L, r1R, r2L, r2R: String }
  static let arms: [String: Arms] = [
    "down": Arms(r1L: " ▐", r1R: "", r2L: "▝▜", r2R: "█▀"),
    "up": Arms(r1L: "▗▟", r1R: "▄", r2L: " ▜", r2R: "█▘"),
    "right": Arms(r1L: " ▐", r1R: "▄", r2L: "▝▜", r2R: "█▘"),
    "left": Arms(r1L: "▗▟", r1R: "", r2L: " ▜", r2R: "█▀")
  ]
  static let feet: [String: String] = [
    "both": " ▝▝   ▝▝ ",
    "left": " ▝▝      ",
    "right": "      ▝▝ "
  ]
  /// Turning in place: glyph rows and the columns from..to where the black face shows.
  static let facing: [String: [(String, Int, Int)]] = [
    "right-12": [(" ▐█▜██▛█ ", 2, 8), ("▝▜██████▀", 2, 7), (" ▝▝   ▝▝ ", 0, 0)],
    "right-30": [("  █▛██▛▌ ", 2, 7), (" ▝█████▛ ", 2, 7), ("  ▘▘  ▘▘ ", 0, 0)],
    "right-55": [("  ▐█▛█▜  ", 3, 7), ("  ▐████  ", 3, 7), ("  ▝▝ ▝▝  ", 0, 0)],
    "right-75": [("   ██▛▌  ", 3, 6), ("   ███▌  ", 3, 6), ("   ▘  ▘  ", 0, 0)],
    "edge": [("   ▐██   ", 4, 6), ("   ▐██   ", 4, 6), ("   ▝ ▝   ", 0, 0)],
    "back-105": [("   ███▌  ", 3, 6), ("   ███▌  ", 3, 6), ("   ▘  ▘  ", 0, 0)],
    "back-125": [("  ▐████  ", 3, 7), ("  ▐████  ", 3, 7), ("  ▝▝ ▝▝  ", 0, 0)],
    "back-150": [("  █████▌ ", 2, 7), (" ▝█████▛ ", 2, 7), ("  ▘▘  ▘▘ ", 0, 0)],
    "back": [(" ▐██████ ", 2, 8), ("▝▜██████▀", 2, 7), (" ▝▝   ▝▝ ", 0, 0)],
    "left-75": [("   ▛██▌  ", 3, 6), ("   ███▌  ", 3, 6), ("   ▘  ▘  ", 0, 0)],
    "left-55": [("  ▐▜▛██  ", 3, 7), ("  ▐████  ", 3, 7), ("  ▝▝ ▝▝  ", 0, 0)],
    "left-30": [("  ▛██▛█▌ ", 2, 7), (" ▝█████▛ ", 2, 7), ("  ▘▘  ▘▘ ", 0, 0)],
    "left-12": [(" ▐▛███▜█ ", 2, 8), ("▝▜██████▀", 2, 7), (" ▝▝   ▝▝ ", 0, 0)]
  ]
  /// Black pixels "dx,dy" from the top-left of the eye cell; ";" separates left and right eye.
  static let eyeShapes: [String: String] = [
    "open": "1,2 1,3",
    "left": "0,0 0,1",
    "right": "2,0 2,1",
    "closed": "0,3 1,3",
    "blink": "0,3 1,3",
    "wink": "1,2 1,3;0,3 1,3",
    "happy": "0,3 1,2 2,3",
    "focus": "1,3",
    "wide": "0,1 1,1 0,2 1,2 0,3 1,3",
    "x": "0,1 2,1 1,2 0,3 2,3",
    "yawn": "0,3 1,3",
    "gasp": "0,1 2,1 1,2 0,3 2,3"
  ]

  public struct Rect: Hashable, Sendable {
    public var x, y, w, h: CGFloat
    /// In sprite pixel units; scale x by px and y by py to get points.
    public func scaled() -> CGRect { CGRect(x: x * px, y: y * py, width: w * px, height: h * py) }
  }

  public struct Geometry: Sendable {
    public var body: [Rect] = []
    public var eyes: [Rect] = []
    public var fx: [Rect] = []
    public var sand: [Rect] = []
  }

  nonisolated(unsafe) static var cache: [ClawdFrame: Geometry] = [:]
  static let lock = NSLock()

  public static func geometry(_ f: ClawdFrame) -> Geometry {
    var key = f
    key.lift = 0
    key.soul = 0
    key.soulT = 0
    lock.lock()
    if let g = cache[key] { lock.unlock(); return g }
    lock.unlock()
    let g = build(key)
    lock.lock()
    if cache.count > 4000 { cache.removeAll() }
    cache[key] = g
    lock.unlock()
    return g
  }

  static func build(_ f: ClawdFrame) -> Geometry {
    // 0 empty, 1 body, 2 black (eyes and face).
    var g = Array(repeating: Array(repeating: 0, count: H), count: W)

    func paint(_ glyphs: String, _ col: Int, _ row: Int, _ mode: String) {
      for (i, c) in glyphs.enumerated() {
        let fg = mode == "lid" ? 2 : 1
        let bg = mode == "eyes" ? 2 : (mode == "lid" ? 1 : 0)
        for sy in 0..<4 {
          for sx in 0..<2 {
            let on: Bool
            if c == "▂" {
              on = sy == 3
            } else {
              let bit = (sy < 2 ? 1 : 4) * (sx == 1 ? 2 : 1)
              on = ((quad[c] ?? 0) & bit) != 0
            }
            let v = on ? fg : bg
            let gx = 2 * (col + i) + sx, gy = 4 * row + sy
            if v != 0, gx >= 0, gx < W, gy >= 0, gy < H { g[gx][gy] = v }
          }
        }
      }
    }

    if !f.facing.isEmpty, let rowsDef = facing[f.facing] {
      for (r, def) in rowsDef.enumerated() {
        let s = Array(def.0)
        paint(String(s[0..<def.1]), 0, r, "")
        paint(String(s[def.1..<def.2]), def.1, r, "eyes")
        paint(String(s[def.2...]), def.2, r, "")
      }
    } else {
      let a = arms[f.arms] ?? arms["down"]!
      paint(a.r1L, 0, 0, "")
      paint("██████", 2, 0, "eyes")
      paint(a.r1R, 8, 0, "")
      paint(a.r2L, 0, 1, "")
      paint("█████", 2, 1, "eyes")
      paint(a.r2R, 7, 1, "")
      paint(feet[f.feet] ?? feet["both"]!, 0, 2, "")

      // Looking sideways with normal eyes uses Claude Code's ready poses; other expressions shift the pupils.
      var eyes = f.eyes
      var shift = 0
      if eyes == "open" && f.look < 0 { eyes = "left" }
      else if eyes == "open" && f.look > 0 { eyes = "right" }
      else if !["open", "left", "right", "wink"].contains(eyes) { shift = f.look }
      let parts = (eyeShapes[eyes] ?? eyeShapes["open"]!).split(separator: ";").map(String.init)
      let ex = [4, 12]
      for k in 0..<2 {
        for pt in parts[min(k, parts.count - 1)].split(separator: " ") {
          let xy = pt.split(separator: ",").compactMap { Int($0) }
          guard xy.count == 2 else { continue }
          let gx = ex[k] + xy[0] + shift
          if gx >= 0, gx < W, xy[1] >= 0, xy[1] < H { g[gx][xy[1]] = 2 }
        }
      }
      if eyes == "yawn" || eyes == "gasp" {
        for x in 8...10 { g[x][4] = 2; g[x][5] = 2 }
      }
    }

    var geo = Geometry()
    let oy = 4 * f.off + f.dig
    let ox = 2 * f.x
    let lim = f.dig > 0 ? H - 2 : H
    for y in 0..<H {
      var sy = y
      if f.flip {
        if y >= H - 2 { continue }
        sy = H - 3 - y
      }
      let yy = sy + oy
      if yy < 0 || yy >= lim { continue }
      var x = 0
      while x < W {
        let c = g[x][y]
        if c == 0 { x += 1; continue }
        let x0 = x
        while x < W && g[x][y] == c { x += 1 }
        let l = max(0, x0 + ox), rr = min(W, x + ox)
        if rr <= l { continue }
        let rect = Rect(x: CGFloat(l), y: CGFloat(yy), w: CGFloat(rr - l), h: 1)
        if c == 2 { geo.eyes.append(rect) } else { geo.body.append(rect) }
      }
    }
    let Wf = CGFloat(W), Hf = CGFloat(H)
    if !f.poof.isEmpty && f.off > 0 {
      for cx in [0, Wf - 2] {
        let pts: [(CGFloat, CGFloat, CGFloat, CGFloat)] = f.poof == "dot"
          ? [(0.6, 9.4, 0.8, 0.9)]
          : [(0.0, 9.6, 0.7, 0.6), (0.7, 9.1, 0.6, 0.6), (1.3, 9.6, 0.7, 0.6)]
        for p in pts { geo.fx.append(Rect(x: cx + p.0, y: p.1, w: p.2, h: p.3)) }
      }
    }
    if !f.shadow.isEmpty {
      let (sc, sw): (CGFloat, CGFloat) = f.shadow == "wide" ? (6, 6) : (8, 2)
      geo.fx.append(Rect(x: sc, y: Hf - 0.5, w: sw, h: 0.5))
    }
    if f.dig >= 1 { geo.sand.append(Rect(x: -2, y: Hf - 3, w: Wf + 4, h: 1)) }
    if f.dig >= 2 { geo.sand.append(Rect(x: -1, y: Hf - 4, w: Wf + 2, h: 1)) }
    if f.dig >= 3 {
      geo.sand.append(Rect(x: -1, y: Hf - 5, w: 2, h: 1))
      geo.sand.append(Rect(x: Wf - 1, y: Hf - 5, w: 2, h: 1))
    }
    if f.spray > 0 {
      for k in 0..<2 {
        let d = CGFloat(f.spray + 2 * k)
        let sx = 1.5 + 0.9 * d
        let sy = (Hf - 4) - 0.9 * d * (5 - d) / 2
        geo.sand.append(Rect(x: -sx, y: sy, w: 0.8, h: 0.8))
        geo.sand.append(Rect(x: Wf - 0.8 + sx, y: sy, w: 0.8, h: 0.8))
      }
    }
    return geo
  }

  // MARK: - hearts and soul pixel art

  public static let heartPx: CGFloat = 1.4
  public static let heartRows = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]

  /// Heart pixels up to `maxCol` (6 full, 3 half), in points.
  public static func heart(maxCol: Int = 6, px: CGFloat = heartPx) -> [CGRect] {
    var out: [CGRect] = []
    for (y, row) in heartRows.enumerated() {
      for (x, c) in row.enumerated() where x <= maxCol && c == "#" {
        out.append(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px))
      }
    }
    return out
  }

  public static let soulUp = 26
  public static let soulBack = 48
  public static let soulTop: CGFloat = 20
  public static let soulPx: CGFloat = 1.4
  static let soulArt = [
    "..########..",
    "..#.####.#..",
    "############",
    "..########..",
    "...######...",
    "....####....",
    ".....##....."
  ]

  /// The soul with its thread, origin at the mouth (negative y is up).
  public static func soul(height h: CGFloat, t: Int) -> [CGRect] {
    let p = soulPx
    let sway = 2.5 * sin(Double(t) / 4.0)
    var out: [CGRect] = []
    let n = Int(floor(h / p))
    for i in 0..<max(0, n) {
      let k = Double(i) / Double(max(1, n))
      let dx = sway * k + 1.2 * sin(Double(t) / 2.0 + Double(i) * 0.7) * sin(k * .pi)
      out.append(CGRect(x: (dx / p).rounded() * p - p / 2, y: -CGFloat(i + 1) * p, width: p, height: p))
    }
    let top = -h - CGFloat(soulArt.count) * p
    let x0 = (sway / p).rounded() * p - 6 * p
    for (y, row) in soulArt.enumerated() {
      let chars = Array(row)
      var x = 0
      while x < chars.count {
        if chars[x] != "#" { x += 1; continue }
        let a = x
        while x < chars.count && chars[x] == "#" { x += 1 }
        out.append(CGRect(x: x0 + CGFloat(a) * p, y: top + CGFloat(y) * p, width: CGFloat(x - a) * p, height: p))
      }
    }
    return out
  }
}

/// One mascot frame: pose plus offsets. `off` lowers by rows (1 crouched, 3 hidden, negative above),
/// `x` shifts by cells, `dig` sinks pixel rows into the sand.
public struct ClawdFrame: Hashable, Sendable {
  public var eyes = "open"
  public var arms = "down"
  public var feet = "both"
  public var look = 0
  public var flip = false
  public var off = 0
  public var x = 0
  public var facing = ""
  public var poof = ""
  public var shadow = ""
  public var dig = 0
  public var spray = 0
  public var lift: CGFloat = 0
  public var soul: CGFloat = 0
  public var soulT = 0

  public init() {}

  public init(eyes: String, arms: String = "down", feet: String = "both") {
    self.eyes = eyes
    self.arms = arms
    self.feet = feet
  }
}
