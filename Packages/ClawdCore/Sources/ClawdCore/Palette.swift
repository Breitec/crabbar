import SwiftUI

public extension Color {
  /// "#RRGGBB" or "#AARRGGBB" (WPF order, alpha first).
  init(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    let a, r, g, b: Double
    if s.count == 8 {
      a = Double((v >> 24) & 0xFF) / 255
      r = Double((v >> 16) & 0xFF) / 255
      g = Double((v >> 8) & 0xFF) / 255
      b = Double(v & 0xFF) / 255
    } else {
      a = 1
      r = Double((v >> 16) & 0xFF) / 255
      g = Double((v >> 8) & 0xFF) / 255
      b = Double(v & 0xFF) / 255
    }
    self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
  }
}

public enum Level: String, Codable, Sendable {
  case ok, warn, crit, dead

  public static func of(_ pct: Int?, warn: Int = 60, crit: Int = 85) -> Level {
    guard let pct else { return .dead }
    if pct >= crit { return .crit }
    if pct >= warn { return .warn }
    return .ok
  }

  public var color: Color {
    switch self {
    case .ok: return Palette.ok
    case .warn: return Palette.warn
    case .crit: return Palette.crit
    case .dead: return Palette.dead
    }
  }
}

public enum Palette {
  public static let ok = Color(hex: "#4ADE80")
  public static let warn = Color(hex: "#FBBF24")
  public static let crit = Color(hex: "#F87171")
  public static let dead = Color(hex: "#6B7280")
  public static let week = Color(hex: "#60A5FA")
  public static let fable = Color(hex: "#A78BFA")
  public static let clawd = Color(hex: "#D77757")
  public static let eyes = Color(hex: "#141416")
  public static let card = Color(hex: "#1A1A1E")
  public static let border = Color(hex: "#33FFFFFF")
  public static let track = Color(hex: "#26FFFFFF")
  public static let divider = Color(hex: "#1AFFFFFF")
  public static let textHead = Color(hex: "#8B8B94")
  public static let textDim = Color(hex: "#6B7280")
  public static let textMain = Color(hex: "#D4D4D8")
  public static let textFoot = Color(hex: "#52525B")
  public static let heartOff = Color(hex: "#3F3F46")
  public static let sand = Color(hex: "#B8955E")
  public static let sweat = Color(hex: "#7DD3FC")
  public static let soul = Color(hex: "#F4F4F5")
  public static let note = Color(hex: "#93C5FD")
  public static let histArea = Color(hex: "#264ADE80")
}
