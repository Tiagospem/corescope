import AppKit
import SwiftTerm
import SwiftUI

/// Integrated terminal in a project's changes view (Settings › Editor and terminal, off by
/// default): one login shell per project, started in its folder. The shell outlives the view —
/// hiding the pane or leaving the project keeps it running with nothing drawn — and ends when its
/// pane or project window is closed, or when CoreScope quits. Each ask first while a command runs.
enum IntegratedTerminal {
  static let key = "projectsIntegratedTerminal"
  static var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: key) }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}

/// One shell in a project's folder, with the terminal view that shows it.
final class ProjectShell: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
  let folder: String
  let shell: String
  let started = Date()
  let view: CoreScopeTerminalView
  private(set) var pid: pid_t = 0
  @Published private(set) var title = ""
  /// Last folder reported by the shell (OSC 7), when it reports one.
  private(set) var directory: String?
  private(set) var exited = false
  fileprivate var onExit: (() -> Void)?

  init(folder: String) {
    self.folder = folder
    shell = ProjectShell.loginShell()
    view = CoreScopeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
    super.init()
    view.processDelegate = self
    let name = (shell as NSString).lastPathComponent
    // argv[0] "-zsh" plus -l: a login shell, as Terminal starts it, so the user's profile sets PATH.
    view.startProcess(executable: shell, args: ["-l"], environment: ProjectShell.environment(), execName: "-\(name)", currentDirectory: folder)
    pid = view.process.shellPid
  }

  static func loginShell() -> String {
    if let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell, let path = String(validatingCString: s), !path.isEmpty,
      FileManager.default.isExecutableFile(atPath: path)
    {
      return path
    }
    return "/bin/zsh"
  }

  /// CoreScope's own environment (PATH, TMPDIR, SSH_AUTH_SOCK, LANG…) minus what belongs to the
  /// app process, plus the terminal identity.
  static func environment() -> [String] {
    var env = ProcessInfo.processInfo.environment
    for k in env.keys where k.hasPrefix("__CF") || k.hasPrefix("XPC_") || k.hasPrefix("OS_ACTIVITY") || k.hasPrefix("Malloc") {
      env[k] = nil
    }
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "CoreScope"
    env["TERM_PROGRAM_VERSION"] = AppVersion.short
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    return env.map { "\($0.key)=\($0.value)" }.sorted()
  }

  /// Processes the shell started that are still running (foreground commands and jobs), by name.
  var children: [String] {
    guard pid > 0, !exited else { return [] }
    var pids = [pid_t](repeating: 0, count: 64)
    let n = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    guard n > 0 else { return [] }
    return pids.prefix(min(n, pids.count)).filter { $0 > 0 }.map { child in
      var name = [CChar](repeating: 0, count: 256)
      proc_name(child, &name, UInt32(name.count))
      return String(cString: name)
    }
  }

  /// Hangs up like Terminal closing a window: the shell gets SIGHUP and passes it to its jobs.
  /// The exit is reaped by SwiftTerm's process monitor; a shell that ignores it is killed.
  func hangUp() {
    guard pid > 0, !exited else { return }
    kill(pid, SIGHUP)
    let pid = pid
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      if self?.exited == false { kill(pid, SIGKILL) }
    }
  }

  // MARK: LocalProcessTerminalViewDelegate
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    self.title = title
  }
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    self.directory = directory.flatMap { URL(string: $0)?.path ?? $0 }
  }
  func processTerminated(source: TerminalView, exitCode: Int32?) {
    // SwiftTerm reaped the shell just now: what it and its jobs spent is the user's, not CoreScope's.
    CostMeter.shared.excludeReapedShell()
    MemoryRelief.now()
    exited = true
    onExit?()
  }
}

/// The shells started by the integrated terminal, one per project folder.
final class ProjectShells: ObservableObject {
  static let shared = ProjectShells()
  @Published private(set) var shells: [String: ProjectShell] = [:]
  /// Folders whose pane is open; the shell keeps running while the pane is hidden.
  @Published var shown: Set<String> = []
  /// Shells hung up but not yet exited: kept until SwiftTerm reaps them, so none is left a zombie.
  private var closing: [ProjectShell] = []

  /// Shows the folder's pane, starting its shell when there is none.
  func open(_ folder: String) {
    if shells[folder]?.exited != false { start(folder) }
    shown.insert(folder)
  }

  private func start(_ folder: String) {
    let s = ProjectShell(folder: folder)
    s.onExit = { [weak self, weak s] in
      guard let self, let s else { return }
      self.closing.removeAll { $0 === s }
      guard self.shells[folder] === s else { return }
      self.shells[folder] = nil
      self.shown.remove(folder)
    }
    shells[folder] = s
  }

  /// Ends the folder's shell, asking first when it is running something. False when the user kept it.
  @discardableResult func close(_ folder: String) -> Bool {
    guard let s = shells[folder] else {
      shown.remove(folder)
      return true
    }
    let busy = s.children
    if !busy.isEmpty && !confirm(L("Encerrar o terminal?"), busy: busy, button: L("Encerrar")) { return false }
    closing.append(s)
    s.hangUp()
    shells[folder] = nil
    shown.remove(folder)
    return true
  }

  /// Asked on quit, like Terminal: only when a shell is running a command.
  func confirmQuit() -> Bool {
    let busy = shells.values.flatMap(\.children)
    return busy.isEmpty || confirm(L("Sair do CoreScope?"), busy: busy, button: L("Sair"))
  }

  func hangUpAll() {
    for s in shells.values { kill(s.pid, SIGHUP) }
    shells = [:]
  }

  private func confirm(_ title: String, busy: [String], button: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = L("Encerrar o terminal integrado também encerra o que roda nele: %@.", Array(Set(busy)).sorted().joined(separator: ", "))
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: L("Cancelar"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// MCP list_terminals: what each integrated shell is and runs (read-only).
  func describe(projects: [ProjectEntry]) -> [[String: Any]] {
    shells.values.sorted { $0.started < $1.started }.map { s in
      [
        "folder": s.folder, "project": projects.first { $0.folder == s.folder }?.name ?? NSNull(),
        "pid": Int(s.pid), "shell": s.shell, "started": s.started.timeIntervalSince1970,
        "title": s.title, "directory": s.directory ?? s.folder, "shown": shown.contains(s.folder),
        "running": s.children,
      ]
    }
  }
}

/// SwiftTerm's view with ⌘C/⌘V/⌘A/⌘F handled here (the app menu may not route them) and colors
/// that follow light and dark.
final class CoreScopeTerminalView: LocalProcessTerminalView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    optionAsMetaKey = false
    applyColors()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// Parsing the shell's output runs on the main thread: billed to "terminal" in CoreScope's cost.
  /// Output arrives a few bytes per read (1.5 M reads for `yes | head -n 2000000`), so the CPU
  /// is summed here and recorded at most once a second.
  override func dataReceived(slice: ArraySlice<UInt8>) {
    let start = CostMeter.threadNow()
    super.dataReceived(slice: slice)
    unbilled += CostMeter.threadNow() - start
    guard !billing else { return }
    billing = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self else { return }
      CostMeter.add("terminal", seconds: self.unbilled)
      let burst = self.unbilled > 0.1
      (self.unbilled, self.billing) = (0, false)
      // A burst of output leaves hundreds of MB of freed small buffers with the allocator (a
      // million reads for 2 M lines): hand them back once the output has stopped.
      guard burst else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        if self?.billing == false { MemoryRelief.now() }
      }
    }
  }
  private var unbilled = 0.0
  private var billing = false

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let key = event.charactersIgnoringModifiers
    else { return super.performKeyEquivalent(with: event) }
    switch key {
    case "c": copy(self)
    case "v": paste(self)
    case "a": selectAll(self)
    case "f":
      let item = NSMenuItem()
      item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
      performTextFinderAction(item)
    default: return super.performKeyEquivalent(with: event)
    }
    return true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    effectiveAppearance.performAsCurrentDrawingAppearance {
      nativeForegroundColor = NSColor.textColor.usingColorSpace(.sRGB) ?? .textColor
      nativeBackgroundColor = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
      caretColor = NSColor.controlAccentColor
    }
    installColors(dark ? Self.darkPalette : Self.lightPalette)
  }

  private static func palette(_ hex: [UInt32]) -> [SwiftTerm.Color] {
    hex.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xff), green8: UInt16($0 >> 8 & 0xff), blue8: UInt16($0 & 0xff)) }
  }
  /// The 16 ANSI colors, darker on a light background so yellow and cyan stay readable.
  private static let lightPalette = palette([
    0x000000, 0xc23621, 0x1f8a3b, 0x8a6d00, 0x1f4fd1, 0xa12fa6, 0x0f7f91, 0xbfbfbf,
    0x686868, 0xe0442e, 0x25a244, 0xa58400, 0x3d6ae0, 0xc13fc6, 0x1597a8, 0xffffff,
  ])
  private static let darkPalette = palette([
    0x000000, 0xff5f57, 0x5fd75f, 0xe5c07b, 0x61afef, 0xd787d7, 0x56c8d8, 0xd0d0d0,
    0x7f7f7f, 0xff8075, 0x87ff87, 0xffd787, 0x87bfff, 0xffafff, 0x87e5f0, 0xffffff,
  ])
}

/// The bottom pane of a project's changes view: a bar with the shell and its controls, and the
/// terminal itself.
struct ProjectTerminalPane: View {
  let folder: String
  @ObservedObject private var shells = ProjectShells.shared

  var body: some View {
    if let shell = shells.shells[folder] { Pane(shell: shell, folder: folder) }
  }
}

private struct Pane: View {
  @ObservedObject var shell: ProjectShell
  let folder: String
  private var shells: ProjectShells { .shared }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "terminal").foregroundStyle(.secondary)
        Text(shell.title.isEmpty ? (shell.shell as NSString).lastPathComponent : shell.title)
          .font(.caption.weight(.medium)).lineLimit(1)
        Text("PID \(shell.pid)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        Button {
          shells.shown.remove(folder)
        } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
          .help(L("Ocultar o terminal (ele continua rodando)")).accessibilityLabel(L("Ocultar o terminal"))
        Button {
          shells.close(folder)
        } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
          .help(L("Encerrar o terminal")).accessibilityLabel(L("Encerrar o terminal"))
      }
      .padding(.horizontal, 12).padding(.vertical, 5)
      Divider()
      TerminalHost(view: shell.view).padding(.leading, 6)
    }
    .background(SwiftUI.Color(nsColor: .textBackgroundColor))
  }
}

/// Hosts the shell's terminal view (which outlives this SwiftUI view) and hides it while the
/// window is not visible, so nothing is drawn for a minimized or covered window.
private struct TerminalHost: NSViewRepresentable {
  let view: CoreScopeTerminalView

  func makeNSView(context: Context) -> Container { Container() }
  func updateNSView(_ container: Container, context: Context) { container.show(view) }
  static func dismantleNSView(_ container: Container, coordinator: ()) { container.show(nil) }

  final class Container: NSView {
    private weak var terminal: NSView?
    private var observer: NSObjectProtocol?

    func show(_ view: NSView?) {
      guard terminal !== view || view?.superview !== self else { return }
      // The same shell can be shown in the main window and in the project's own window: only
      // take it out of this container, never out of the other one that holds it now.
      if terminal?.superview === self { terminal?.removeFromSuperview() }
      terminal = view
      guard let view else { return }
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
      updateVisibility()
      DispatchQueue.main.async { [weak self, weak view] in
        if let view, self?.window?.firstResponder == nil || self?.window?.firstResponder === self?.window {
          self?.window?.makeFirstResponder(view)
        }
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = window.map {
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main) {
          [weak self] _ in self?.updateVisibility()
        }
      }
      updateVisibility()
    }

    private func updateVisibility() {
      terminal?.isHidden = !(window?.occlusionState.contains(.visible) ?? false)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
}

/// The header button that shows or hides a project's terminal pane.
struct IntegratedTerminalButton: View {
  let folder: String
  @ObservedObject private var shells = ProjectShells.shared
  var body: some View {
    let shown = shells.shown.contains(folder)
    Button {
      if shown { shells.shown.remove(folder) } else { shells.open(folder) }
    } label: {
      Image(systemName: shown ? "rectangle.bottomhalf.filled" : "rectangle.bottomhalf.inset.filled")
        .overlay(alignment: .topTrailing) {
          if !shown && shells.shells[folder] != nil { Circle().fill(.green).frame(width: 5, height: 5).offset(x: 3, y: -2) }
        }
    }
    .buttonStyle(HoverButtonStyle())
    .help(shown ? L("Ocultar o terminal integrado") : L("Mostrar o terminal integrado"))
    .accessibilityLabel(L("Terminal integrado"))
  }
}
