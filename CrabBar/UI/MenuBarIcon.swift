import AppKit
import ClawdCore

/// The tray icon of the original: a circle in the level colour with the session percent in black.
enum MenuBarIcon {
  static func image(pct: Int?, level: Level, showText: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
      let color: NSColor = {
        switch level {
        case .ok: return NSColor(red: 74 / 255, green: 222 / 255, blue: 128 / 255, alpha: 1)
        case .warn: return NSColor(red: 251 / 255, green: 191 / 255, blue: 36 / 255, alpha: 1)
        case .crit: return NSColor(red: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1)
        case .dead: return NSColor(red: 107 / 255, green: 114 / 255, blue: 128 / 255, alpha: 1)
        }
      }()
      color.setFill()
      NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
      guard showText else { return true }
      let text = pct.map(String.init) ?? "--"
      let fontSize: CGFloat = text.count >= 3 ? 7.5 : (text.count == 2 ? 9.5 : 11)
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.black
      ]
      let s = NSAttributedString(string: text, attributes: attrs)
      let b = s.size()
      s.draw(at: NSPoint(x: (rect.width - b.width) / 2, y: (rect.height - b.height) / 2 + 0.5))
      return true
    }
    img.isTemplate = false
    return img
  }
}
