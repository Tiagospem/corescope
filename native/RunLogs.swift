import AppKit
import SwiftUI

/// The output of an environment's operations — mode starts and stops, actions — kept per run.
/// Each new run moves the previous log aside (`name.1.log` … `name.4.log`), so the last five runs
/// of every mode and action stay readable from the environment card, the Logs page and MCP. When
/// a command ends CoreScope appends `[CoreScope] exit N`, so an older run keeps its outcome.
enum RunLogs {
  static let keep = 5

  /// Before a new run writes `url`: shifts the older runs and frees `url`.
  static func rotate(_ url: URL) {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    try? fm.removeItem(at: older(url, keep - 1))
    for i in stride(from: keep - 2, through: 1, by: -1) where fm.fileExists(atPath: older(url, i).path) {
      try? fm.moveItem(at: older(url, i), to: older(url, i + 1))
    }
    try? fm.moveItem(at: url, to: older(url, 1))
  }
  /// `name.log` → `name.N.log`.
  static func older(_ url: URL, _ n: Int) -> URL {
    url.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension("log")
  }
  /// The trailer that keeps a run's outcome in its log.
  static func noteExit(_ url: URL, _ code: Int32) {
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    handle.seekToEndOfFile()
    handle.write(Data("\n[CoreScope] exit \(code)\n".utf8))
    try? handle.close()
  }
  static func exitCode(_ url: URL) -> Int32? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 512 ? size - 512 : 0)
    return logExitCode(String(decoding: handle.readDataToEndOfFile(), as: UTF8.self))
  }

  /// One run of a mode or an action, newest first in `history`.
  struct Entry: Identifiable, Equatable {
    let url: URL
    /// "revamp · build" for a mode, "revamp · herd" for an action.
    let title: String
    let action: Bool
    let started: Date
    let ended: Date
    let exit: Int32?
    let running: Bool
    let bytes: Int
    var id: String { url.path }
    var outcome: String { running ? "running" : exit.map { $0 == 0 ? "succeeded" : "failed" } ?? "unknown" }
  }

  /// The runs of one environment (its project file), newest first. One directory listing, then
  /// only the logs that exist.
  static func history(source: String) -> [Entry] {
    let fm = FileManager.default
    let names = Set((try? fm.contentsOfDirectory(atPath: ProfileStore.logs.path)) ?? [])
    guard !names.isEmpty else { return [] }
    let profiles = ProfileStore.shared
    let actions = ActionStore.shared
    var out: [Entry] = []
    func add(_ base: URL, title: String, action: Bool, running: Bool, currentExit: Int32?) {
      for n in 0..<keep {
        let url = n == 0 ? base : older(base, n)
        guard names.contains(url.lastPathComponent), let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
        let modified = attrs[.modificationDate] as? Date ?? Date()
        let isCurrent = n == 0
        out.append(
          Entry(
            url: url, title: title, action: action, started: attrs[.creationDate] as? Date ?? modified, ended: modified,
            exit: exitCode(url) ?? (isCurrent ? currentExit : nil), running: isCurrent && running,
            bytes: (attrs[.size] as? NSNumber)?.intValue ?? 0))
      }
    }
    for p in profiles.fileProfiles where p.source == source {
      let base = [p.app, p.mode ?? (p.app == nil ? p.name : nil)].compactMap { $0 }.joined(separator: " · ")
      for c in p.commands {
        let title = p.commands.count > 1 ? "\(base) · \(c.name)" : base
        let running = if case .running = profiles.state(c, in: p) { true } else { false }
        add(profiles.logURL(p, c), title: title, action: false, running: running, currentExit: profiles.exits[c.id]?.status)
      }
    }
    for a in actions.actions where a.source == source {
      let run = actions.runs[a.id]
      add(
        ActionStore.logURL(a), title: a.group.isEmpty ? a.name : "\(a.group) · \(a.name)", action: true,
        running: run?.outcome == .running, currentExit: run?.exit)
    }
    return out.sorted { $0.started > $1.started }
  }

  /// The last `maxBytes` of a log, cleaned; whether earlier output was left out.
  static func read(_ url: URL, maxBytes: Int = 1 << 20) -> (text: String, truncated: Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    let truncated = size > UInt64(maxBytes)
    handle.seek(toFileOffset: truncated ? size - UInt64(maxBytes) : 0)
    var text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    if truncated, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
    return (cleanLogText(text), truncated)
  }
}

/// A log in a window of its own: read-only, find (⌘F), errors in red, and it follows the file
/// while the run writes to it. One window per log.
enum LogViewer {
  private static var windows: [String: NSWindow] = [:]
  private static let delegate = CloseDelegate()

  static func open(_ url: URL, title: String) {
    if let window = windows[url.path] {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 480, height: 280)
    window.setFrameAutosaveName("run-log")
    window.contentView = NSHostingView(rootView: LogViewerView(url: url, title: title))
    window.delegate = delegate
    windows[url.path] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  fileprivate static func closed(_ window: NSWindow) {
    guard let key = windows.first(where: { $0.value === window })?.key else { return }
    // Dropping the hosting view stops the follower's timer.
    window.contentView = nil
    windows[key] = nil
  }
  private final class CloseDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
      if let window = notification.object as? NSWindow { LogViewer.closed(window) }
    }
  }
}

/// Re-reads the log once a second while it grows (only while its window is open).
final class LogFollower: ObservableObject {
  @Published private(set) var text = ""
  @Published private(set) var truncated = false
  @Published private(set) var growing = false
  let url: URL
  private var size: UInt64 = .max
  private var quietTicks = 0
  private var timer: Timer?
  init(url: URL) {
    self.url = url
    reload()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
  }
  deinit { timer?.invalidate() }
  func reload() {
    let now = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    guard now != size else {
      quietTicks += 1
      if quietTicks == 3, growing { growing = false }
      return
    }
    growing = size != .max
    quietTicks = 0
    size = now
    DispatchQueue.global(qos: .userInitiated).async { [url] in
      let read = RunLogs.read(url)
      DispatchQueue.main.async {
        self.text = read.text
        self.truncated = read.truncated
      }
    }
  }
}

struct LogViewerView: View {
  let url: URL
  let title: String
  @StateObject private var follower: LogFollower
  init(url: URL, title: String) {
    self.url = url
    self.title = title
    _follower = StateObject(wrappedValue: LogFollower(url: url))
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.callout.weight(.semibold)).lineLimit(1)
          Text(Demo.enabled ? url.lastPathComponent : abbreviateHome(url.path)).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.head)
        }
        Spacer()
        if follower.growing {
          Label(L("ao vivo"), systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.green)
        }
        Button(L("Copiar")) { copy(follower.text) }.controlSize(.small)
        Button(L("Mostrar no Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
        if let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
          Button(L("Abrir no Console")) {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
          }.controlSize(.small)
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 8)
      if follower.truncated {
        Text(L("Mostrando o último 1 MB; o arquivo completo está no Finder."))
          .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12).padding(.bottom, 6)
      }
      Divider()
      LogTextView(text: follower.text)
    }
  }
}

/// Read-only, selectable text with the find bar; stays at the end when it was there.
private struct LogTextView: NSViewRepresentable {
  let text: String
  static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    guard let view = scroll.documentView as? NSTextView else { return scroll }
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = false
    view.usesFindBar = true
    view.isIncrementalSearchingEnabled = true
    view.textContainerInset = NSSize(width: 6, height: 6)
    view.backgroundColor = .textBackgroundColor
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage, storage.string != text else { return }
    let clip = scroll.contentView
    let atEnd = storage.length == 0 || clip.bounds.maxY >= (scroll.documentView?.frame.height ?? 0) - 24
    storage.setAttributedString(Self.colored(text))
    if atEnd { view.scrollToEndOfDocument(nil) }
  }
  /// Lines that read as errors in red, warnings in orange.
  static func colored(_ text: String) -> NSAttributedString {
    let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
    let ns = text as NSString
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { line, range, _, _ in
      guard let line = line?.lowercased() else { return }
      if line.contains("error") || line.contains("falhou") || line.contains("failed") || line.contains("fatal")
        || line.contains("exception") || line.hasPrefix("[corescope] exit ") && !line.hasSuffix(" 0")
      {
        out.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
      } else if line.contains("warn") {
        out.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
      }
    }
    return out
  }
}
