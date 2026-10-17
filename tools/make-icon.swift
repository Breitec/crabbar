import AppKit

let size: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
// --full-bleed: the iOS variant, a full square without transparency (iOS rounds the corners itself).
let fullBleed = CommandLine.arguments.contains("--full-bleed")
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: (fullBleed ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
// Top-left origin, like the sprite data.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824 x 824 squircle-ish rounded rect inside the 1024 canvas.
let tile = fullBleed ? CGRect(x: 0, y: 0, width: size, height: size) : CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = fullBleed ? CGPath(rect: tile, transform: nil) : CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
// Sky: dusk blue fading into the card colour, like the widget's backdrop.
let grad = CGGradient(colorsSpace: cs, colors: [col(0x3A4A7A), col(0x2B2F48), col(0x1A1A1E)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
// Stars.
for (x, y) in [(400, 180), (520, 250), (760, 190), (840, 320), (650, 150), (180, 400), (330, 330)] {
  ctx.setFillColor(col(0xF8FAFC, 0.8))
  ctx.fill(CGRect(x: x, y: y, width: 12, height: 12))
}
// Pixel moon (crescent).
let moon = ["..###..", ".##....", "##.....", "##.....", "##.....", ".##....", "..###.."]
for (yy, row) in moon.enumerated() {
  for (xx, c) in row.enumerated() where c == "#" {
    ctx.setFillColor(col(0xF1F5F9))
    ctx.fill(CGRect(x: 220 + CGFloat(xx) * 16, y: 200 + CGFloat(yy) * 16, width: 16, height: 16))
  }
}

// Clawd, arms up and happy, standing on the sand.
var f = ClawdFrame(eyes: "happy", arms: "up", feet: "both")
let g = ClawdSprite.geometry(f)
let scale: CGFloat = 15
let spriteW = ClawdSprite.width * scale
let origin = CGPoint(x: ((size - spriteW) / 2).rounded(), y: 452)
func paint(_ rs: [ClawdSprite.Rect], _ c: CGColor) {
  ctx.setFillColor(c)
  for r in rs {
    let s = r.scaled()
    ctx.fill(CGRect(x: (origin.x + s.minX * scale).rounded(), y: (origin.y + s.minY * scale).rounded(),
                    width: (s.width * scale).rounded(), height: (s.height * scale).rounded()))
  }
}
ctx.setShouldAntialias(false)
paint(g.body, col(0xD77757))
paint(g.eyes, col(0x141416))
ctx.setShouldAntialias(true)
// Sand under the feet.
let groundY = origin.y + (ClawdSprite.height - ClawdSprite.sink) * scale
ctx.setFillColor(col(0xB8955E))
ctx.fill(CGRect(x: tile.minX, y: groundY, width: tile.width, height: tile.maxY - groundY))
ctx.setFillColor(col(0x9C7B4A))
ctx.fill(CGRect(x: tile.minX, y: groundY, width: tile.width, height: 14))
// A heart floating above, as when he is petted.
let heart = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
for (yy, row) in heart.enumerated() {
  for (xx, c) in row.enumerated() where c == "#" {
    ctx.setFillColor(col(0xF87171))
    ctx.fill(CGRect(x: 640 + CGFloat(xx) * 15, y: 340 + CGFloat(yy) * 15, width: 15, height: 15))
  }
}
ctx.restoreGState()
// Hairline border (macOS only).
if !fullBleed {
  ctx.addPath(shape)
  ctx.setStrokeColor(col(0xFFFFFF, 0.12))
  ctx.setLineWidth(3)
  ctx.strokePath()
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("written")
