// Builds an animated GIF from PNG frames: swift scripts/make-gif.swift out.gif width delay f1.png f2.png …
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5, let width = Double(args[2]), let delay = Double(args[3]) else {
  print("usage: make-gif.swift out.gif width delaySeconds frame.png …")
  exit(1)
}
let frames = args.dropFirst(4).map { URL(fileURLWithPath: $0) }
let out = URL(fileURLWithPath: args[1])
guard
  let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
else { exit(1) }
CGImageDestinationSetProperties(
  dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for url in frames {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
  else { continue }
  let height = Double(image.height) * width / Double(image.width)
  let ctx = CGContext(
    data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  CGImageDestinationAddImage(
    dest, ctx.makeImage()!,
    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("GIF: \(out.path)")
