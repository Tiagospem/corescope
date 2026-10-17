import AppKit

/// `CORESCOPE_TOUR=<folder>` (used with `CORESCOPE_DEMO=1` by scripts/readme-media.sh): once
/// data has settled, visits each page and writes the main window to PNG files for the README
/// and its demo GIF, then quits. The app captures its own window, so no Screen Recording
/// permission is needed.
enum Tour {
  static let folder = ProcessInfo.processInfo.environment["CORESCOPE_TOUR"]
  /// (file name, page, seconds to wait before capturing); `CORESCOPE_TOUR_PAGES=ports,logs`
  /// (page slugs, as in corescope://open/<slug>) captures those pages instead.
  private static let steps: [(String, Page, Double)] = {
    let custom = (ProcessInfo.processInfo.environment["CORESCOPE_TOUR_PAGES"] ?? "").split(separator: ",")
      .compactMap { slug in Page.allCases.first { $0.slug == slug.trimmingCharacters(in: .whitespaces) } }
    if !custom.isEmpty { return custom.map { ($0.slug, $0, 6) } }
    return [
      ("overview", .overview, 3), ("processes", .processes, 3), ("agents", .agents, 4),
      ("containers", .containers, 9), ("history", .history, 3), ("overview-2", .overview, 3),
    ]
  }()
  static func start() {
    guard let folder else { return }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    // Token usage normally starts when its card first appears; start it now so it is ready.
    AgentStore.shared.tokens.start()
    // Let charts, token counts and container stats fill in before the first capture.
    let warmup = Double(ProcessInfo.processInfo.environment["CORESCOPE_TOUR_WARMUP"] ?? "") ?? 45
    DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { run(0, folder) }
  }
  private static func run(_ index: Int, _ folder: String) {
    guard index < steps.count else {
      NSApp.terminate(nil)
      return
    }
    let (name, page, wait) = steps[index]
    WindowOpener.shared.showMain(page: page)
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
      capture(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
      run(index + 1, folder)
    }
  }
  private static func capture(to url: URL) {
    guard
      let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }),
      let view = window.contentView?.superview ?? window.contentView
    else { return }
    // Render the window's layer tree at 2x (Retina-sharp); cacheDisplay misses parts of it.
    if let layer = view.layer {
      let scale: CGFloat = 2
      let size = view.bounds.size
      if let ctx = CGContext(
        data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      {
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        if let image = ctx.makeImage() {
          let rep = NSBitmapImageRep(cgImage: image)
          try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
      }
    }
  }
  /// Fixed window size so captures are consistent between runs.
  static func prepareWindow() {
    guard folder != nil,
      let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })
    else { return }
    window.setContentSize(NSSize(width: 1280, height: 860))
    window.center()
  }
}

