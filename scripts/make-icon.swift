// Draws the CoreScope app icon (scope reticle + pulse line) into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.removeItem(at: output)
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
    blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(_ ctx: CGContext, _ size: CGFloat) {
  let s = size / 1024
  ctx.scaleBy(x: s, y: s)
  // macOS icon grid: 824 pt body centered on a 1024 canvas.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
  ctx.addPath(shape)
  ctx.setFillColor(color(0x0E1512))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(shape)
  ctx.clip()
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let background = CGGradient(
    colorsSpace: space, colors: [color(0x1F2E27), color(0x0F1714), color(0x080C0B)] as CFArray,
    locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(
    background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
  // Soft green glow behind the reticle.
  let glow = CGGradient(
    colorsSpace: space, colors: [color(0x3DDC84, 0.32), color(0x3DDC84, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
    endCenter: CGPoint(x: 512, y: 500), endRadius: 380, options: [])

  let center = CGPoint(x: 512, y: 512)
  // Reticle rings.
  for (radius, alpha, width) in [(300.0, 0.20, 6.0), (215.0, 0.32, 6.0), (130.0, 0.20, 5.0)] {
    ctx.setStrokeColor(color(0x7CF3A8, alpha))
    ctx.setLineWidth(width)
    ctx.strokeEllipse(
      in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }
  // Tick marks on the outer ring.
  ctx.setStrokeColor(color(0x7CF3A8, 0.45))
  ctx.setLineWidth(8)
  ctx.setLineCap(.round)
  for i in 0..<4 {
    let a = Double(i) * .pi / 2
    let inner = 318.0
    let outer = 352.0
    ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
  }
  ctx.strokePath()

  // Pulse line crossing the scope.
  let points: [(Double, Double)] = [
    (170, 512), (330, 512), (380, 470), (430, 512), (470, 512), (515, 720), (575, 300),
    (625, 560), (655, 512), (854, 512),
  ]
  let pulse = CGMutablePath()
  pulse.move(to: CGPoint(x: points[0].0, y: points[0].1))
  for p in points.dropFirst() { pulse.addLine(to: CGPoint(x: p.0, y: p.1)) }
  ctx.setLineJoin(.round)
  ctx.setLineCap(.round)
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: 40, color: color(0x3DDC84, 0.9))
  ctx.addPath(pulse)
  ctx.setStrokeColor(color(0x3DDC84))
  ctx.setLineWidth(34)
  ctx.strokePath()
  ctx.restoreGState()
  ctx.addPath(pulse)
  ctx.setStrokeColor(color(0xC8FFDD))
  ctx.setLineWidth(12)
  ctx.strokePath()

  // Top highlight and edge.
  let shine = CGGradient(
    colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(
    shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
  ctx.restoreGState()
  ctx.addPath(shape)
  ctx.setStrokeColor(color(0xFFFFFF, 0.12))
  ctx.setLineWidth(3)
  ctx.strokePath()
}

for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let px = base * scale
    let ctx = CGContext(
      data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
  }
}
