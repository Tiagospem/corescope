import AppKit
import SwiftUI

// Select the stable property wrapper: CLT SDK 27 ships a State macro without its plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

struct Metric: Decodable {
  let value: Double?
  let unit: String
  let source: String
  let at: Double
  let state: String
  private enum Keys: String, CodingKey { case value, unit, source, at, state }
  /// Per-process metrics arrive lean (`value`, optional `state`); the rest is optional.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    value = try c.decodeIfPresent(Double.self, forKey: .value)
    unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
    source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    at = try c.decodeIfPresent(Double.self, forKey: .at) ?? Date().timeIntervalSince1970
    state = try c.decodeIfPresent(String.self, forKey: .state) ?? (value == nil ? "unavailable" : "available")
  }
  var unavailable: String {
    L(
      state == "unsupported"
        ? "Não suportado" : state == "permission" ? "Sem permissão" : "Temporariamente indisponível")
  }
  var bytes: String { value.map(formatBytes) ?? "—" }
  var temperature: String { value.map { String(format: "%.1f °C", $0) } ?? unavailable }
  var percent: String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
  var rate: String { value.map(formatRate) ?? "—" }
  var explanation: String {
    (source.isEmpty ? "" : "\(source) · \(unit)\n") + "\(value == nil ? unavailable : L("Última leitura: %@", Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .standard)))"
  }
}
struct Point: Decodable {
  let at: Double
  let cpu: Double?
  let memory: Double?
  let disk_read: Double?
  let disk_write: Double?
  let net_in: Double?
  let net_out: Double?
}
struct PortInfo: Decodable, Hashable {
  let port: UInt16
  let exposed: Bool
}
struct Origin: Decodable, Hashable {
  let label: String
  let kind: String
  let pid: Int32
}
struct ProcessItem: Decodable, Identifiable {
  let id: String
  let pid: Int32
  let ppid: Int32
  let uid: UInt32
  var user: String
  let start: UInt64
  let name: String
  var path: String
  var signalPath: String?
  let cpu: Metric
  let memory: Metric
  let resident: Metric
  let threads: Metric
  let read: Metric
  let write: Metric
  /// Average watts since the previous sample (rusage v6); nil on older macOS.
  let energy: Metric?
  let eligible: Bool
  let blocked: String
  let orphan: String?
  var orphan_parent: String?
  /// Session id; nil from older cores.
  let sid: Int32?
  var cwd: String
  let ports: [PortInfo]
  let tags: [String]
  let host: String?
  let origin: Origin?
  let high_cpu_seconds: Double
  let history: [Point]
  var cpuValue: Double { cpu.value ?? -1 }
  var memoryValue: Double { memory.value ?? -1 }
  var threadValue: Double { threads.value ?? -1 }
  var startDate: Date { Date(timeIntervalSince1970: Double(start) / 1_000_000) }
  var uptime: TimeInterval { max(0, Date().timeIntervalSince(startDate)) }
  var isServer: Bool { !ports.isEmpty }
  var isDev: Bool {
    origin != nil || host != nil
      || tags.contains { ["runtime", "server", "shell", "mcp", "database", "container"].contains($0) }
  }
  /// Agent session root: a CLI agent started from a terminal, editor or a desktop app
  /// (Claude/Codex Desktop run each session as a bundled CLI). Nested sub-agents are excluded.
  var isAgentSession: Bool {
    tags.contains("agent") && !(host ?? "").hasSuffix("Desktop") && origin?.label != host
  }
  /// The session root itself or anything an agent session started.
  var inAgentSession: Bool {
    isAgentSession || (origin.map { $0.kind == "agent" && !$0.label.hasSuffix("Desktop") } ?? false)
  }
  /// Where an agent session runs: the desktop app or the terminal/editor that started it.
  var sessionSource: String {
    guard let o = origin else { return "CLI" }
    return o.label.hasSuffix("Desktop") ? "Desktop" : o.label
  }
  /// Outermost .app bundle, used for the real application icon.
  var bundlePath: String? {
    path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
  }
  var project: String? { projectName(cwd, home: Demo.enabled ? demoHome : NSHomeDirectory()) }
  var shortCwd: String { abbreviateHome(cwd) }
  var portsLabel: String { ports.map { ":\($0.port)" }.joined(separator: " ") }
}
struct CoreLoad: Decodable {
  /// "P", "E" or "" when the core type is unknown.
  let kind: String
  let value: Double?
}
struct Volume: Decodable, Identifiable {
  let id: String
  let mount: String
  let kind: String
  let total: Metric
  let available: Metric
  let temperature: Metric
}
struct Disk: Decodable, Identifiable {
  let id: String
  let name: String
  let read: Metric
  let write: Metric
  let temperature: Metric
}
struct Diagnostic: Decodable, Identifiable {
  let id: String
  let level: Int
  let title: String
  let detail: String
  var color: Color { level == 2 ? .red : level == 1 ? .orange : .secondary }
  var symbol: String {
    level == 2
      ? "exclamationmark.octagon.fill"
      : level == 1 ? "exclamationmark.triangle.fill" : "checkmark.circle"
  }
  var label: String { L(level == 2 ? "Crítico" : level == 1 ? "Atenção" : "Sem alerta") }
  var localizedTitle: String { L(title) }
  var localizedDetail: String { L(detail) }
}
struct BatteryInfo: Decodable, Equatable {
  let percent: Int
  let charging: Bool
  let on_ac: Bool
  let minutes: Int?
}
struct Snapshot: Decodable {
  let at: Double
  let cores: Int
  let cpu: Metric
  let physical: Metric
  let active: Metric
  let wired: Metric
  let compressed: Metric
  let swap: Metric
  let app_memory: Metric
  let cached_files: Metric
  let pressure_percent: Metric
  let pressure: Metric
  let thermal: Metric
  let core_load: [CoreLoad]
  let core_source: String
  let history_state: String
  var processes: [ProcessItem]
  let volumes: [Volume]
  let disks: [Disk]
  let diagnostics: [Diagnostic]
  let history: [Point]
  let disk_read: Metric
  let disk_write: Metric
  let net_in: Metric
  let net_out: Metric
  let collector_ms: Double
  let own_wakeups: Metric
  let process_state: String
  let volume_state: String
  let disk_state: String
  let current_uid: UInt32
  let battery: BatteryInfo?
  let power: Metric?
  var thermalLabel: String {
    guard let v = thermal.value else { return L("Indisponível") }
    return L(["Nominal", "Moderado", "Sério", "Crítico"][min(3, max(0, Int(v)))])
  }
  var thermalColor: Color {
    switch Int(thermal.value ?? 0) {
    case 3: .red
    case 2: .orange
    case 1: .yellow
    default: .green
    }
  }
  var pressureLabel: String {
    L(pressure.value.map { ["Normal", "Atenção", "Crítica"][min(2, max(0, Int($0)))] } ?? "Aguardando")
  }
  var memoryUsed: Double? {
    guard let a = active.value, let w = wired.value, let c = compressed.value else { return nil }
    return a + w + c
  }
  var memorySummary: String { memoryUsed.map(formatBytes) ?? "—" }
  var memoryFraction: Double? {
    guard let used = memoryUsed, let total = physical.value, total > 0 else { return nil }
    return used / total
  }
  var diskTotal: Double? {
    guard disk_read.value != nil || disk_write.value != nil else { return nil }
    return (disk_read.value ?? 0) + (disk_write.value ?? 0)
  }
  var diskRate: String { diskTotal.map(formatRate) ?? "—" }
  /// Derived lists are memoized per snapshot: views ask for them many times per render.
  private func memo<T>(_ key: String, _ make: () -> T) -> T {
    if SnapshotMemo.at != at {
      SnapshotMemo.at = at
      SnapshotMemo.values.removeAll(keepingCapacity: true)
    }
    if let value = SnapshotMemo.values[key] as? T { return value }
    let value = make()
    SnapshotMemo.values[key] = value
    return value
  }
  /// Listening processes, one per name + port set (pre-fork workers such as nginx share sockets).
  var servers: [ProcessItem] { memo("servers") { serverGroups.map(\.0) } }
  var serverGroups: [(ProcessItem, Int)] { memo("serverGroups") { makeServerGroups() } }
  private func makeServerGroups() -> [(ProcessItem, Int)] {
    var groups: [String: (ProcessItem, Int)] = [:]
    for p in processes where p.isServer {
      let key = p.name + p.portsLabel
      if let g = groups[key] {
        groups[key] = (g.0.pid < p.pid ? g.0 : p, g.1 + 1)
      } else {
        groups[key] = (p, 1)
      }
    }
    return groups.values.sorted { ($0.0.ports.first?.port ?? 0) < ($1.0.ports.first?.port ?? 0) }
  }
  /// Newest session first, by start time: a stable order, so rows don't jump as CPU changes.
  var agentSessions: [ProcessItem] {
    memo("agentSessions") {
      processes.filter(\.isAgentSession).sorted { ($0.start, $0.pid) > ($1.start, $1.pid) }
    }
  }
  var orphans: [ProcessItem] {
    memo("orphans") {
      // Oldest first: stable while memory values fluctuate between samples.
      processes.filter { $0.orphan != nil }.sorted { ($0.start, $0.pid) < ($1.start, $1.pid) }
    }
  }
  private var byPID: [Int32: ProcessItem] {
    memo("byPID") { Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a }) }
  }
  private var children: [Int32: [Int32]] {
    memo("children") { Dictionary(grouping: processes.map { ($0.pid, $0.ppid) }, by: \.1).mapValues { $0.map(\.0) } }
  }
  func process(pid: Int32) -> ProcessItem? { byPID[pid] }
  /// Root followed by every descendant (children before parents for signaling).
  func subtree(of root: ProcessItem) -> [ProcessItem] {
    memo("subtree.\(root.id)") {
      var ids = [root.pid]
      var seen: Set<Int32> = [root.pid]
      var index = 0
      while index < ids.count {
        for child in (children[ids[index]] ?? []).sorted() where seen.insert(child).inserted {
          ids.append(child)
        }
        index += 1
      }
      return ids.reversed().compactMap { byPID[$0] }
    }
  }
}

/// Main-thread cache for values derived from the current snapshot.
enum SnapshotMemo {
  static var at = -1.0
  static var values: [String: Any] = [:]
}

final class Preferences: ObservableObject {
  static let shared = Preferences()
  /// system · pt · en · es
  @Published var language = UserDefaults.standard.string(forKey: "language") ?? "system" {
    didSet {
      save("language", language)
      Localization.refresh()
    }
  }
  @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "Sistema" {
    didSet {
      save("appearance", appearance)
      applyAppearance()
    }
  }
  func applyAppearance() {
    NSApp.appearance =
      appearance == "Claro"
      ? NSAppearance(named: .aqua) : appearance == "Escuro" ? NSAppearance(named: .darkAqua) : nil
  }
  @Published var interval =
    UserDefaults.standard.double(forKey: "interval") == 0
    ? 3.0 : UserDefaults.standard.double(forKey: "interval")
  { didSet { save("interval", interval) } }
  @Published var menuItems =
    UserDefaults.standard.stringArray(forKey: "menuItems") ?? ["CPU", "Memória"]
  { didSet { save("menuItems", menuItems) } }
  @Published var compact = UserDefaults.standard.object(forKey: "compact") as? Bool ?? true {
    didSet { save("compact", compact) }
  }
  @Published var menuIcon = UserDefaults.standard.object(forKey: "menuIcon") as? Bool ?? true {
    didSet { save("menuIcon", menuIcon) }
  }
  /// always · window (only while the main window is open) · never
  @Published var dockMode =
    UserDefaults.standard.string(forKey: "dockMode")
    ?? ((UserDefaults.standard.object(forKey: "showInDock") as? Bool) == false ? "never" : "window")
  {
    didSet {
      save("dockMode", dockMode)
      applyActivationPolicy()
    }
  }
  /// Menu bar app when the window is closed; regular app (Dock, ⌘-Tab) while it is open.
  func applyActivationPolicy() {
    let windowOpen = NSApp.windows.contains {
      $0.isVisible && $0.identifier?.rawValue.contains("main") == true
    }
    let regular = dockMode == "always" || (dockMode == "window" && windowOpen)
    let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
    guard NSApp.activationPolicy() != policy else { return }
    NSApp.setActivationPolicy(policy)
    if regular, let icon = AppIcon.image { NSApp.applicationIconImage = icon }
  }
  @Published var confirmTerminate =
    UserDefaults.standard.object(forKey: "confirmTerminate") as? Bool ?? true
  { didSet { save("confirmTerminate", confirmTerminate) } }
  @Published var processTree = UserDefaults.standard.object(forKey: "processTree") as? Bool ?? true
  { didSet { save("processTree", processTree) } }
  @Published var panelVisible = UserDefaults.standard.bool(forKey: "panelVisible") {
    didSet {
      save("panelVisible", panelVisible)
      FloatingController.shared.apply()
    }
  }
  /// compact · standard · detailed
  @Published var panelMode = UserDefaults.standard.string(forKey: "panelMode") ?? "standard" {
    didSet { save("panelMode", panelMode) }
  }
  @Published var panelOpacity =
    UserDefaults.standard.object(forKey: "panelOpacity") as? Double ?? 0.92
  { didSet { save("panelOpacity", panelOpacity) } }
  @Published var panelScale = UserDefaults.standard.object(forKey: "panelScale") as? Double ?? 1.0 {
    didSet { save("panelScale", panelScale) }
  }
  @Published var panelTop = UserDefaults.standard.object(forKey: "panelTop") as? Bool ?? true {
    didSet {
      save("panelTop", panelTop)
      FloatingController.shared.apply()
    }
  }
  @Published var panelLocked = UserDefaults.standard.bool(forKey: "panelLocked") {
    didSet {
      save("panelLocked", panelLocked)
      FloatingController.shared.apply()
    }
  }
  @Published var limitsInMenuBar = UserDefaults.standard.bool(forKey: "limitsInMenuBar") {
    didSet { save("limitsInMenuBar", limitsInMenuBar) }
  }
  @Published var limitsInPanel = UserDefaults.standard.bool(forKey: "limitsInPanel") {
    didSet { save("limitsInPanel", limitsInPanel) }
  }
  /// Opt-in: installs CoreScope's status line command in ~/.claude/settings.json (turning it off
  /// restores the previous statusLine). Off by default; nothing of Claude's is touched while off.
  @Published var claudeLimits = UserDefaults.standard.bool(forKey: "claudeLimits") {
    didSet {
      guard claudeLimits != oldValue else { return }
      save("claudeLimits", claudeLimits)
      AgentStore.shared.setClaudeLimits(claudeLimits)
    }
  }
  /// Ask Codex's app-server for the current limit (Codex contacts OpenAI with its login).
  @Published var codexLiveLimits = UserDefaults.standard.bool(forKey: "codexLiveLimits") {
    didSet { save("codexLiveLimits", codexLiveLimits) }
  }
  @Published var limitsInOverview =
    UserDefaults.standard.object(forKey: "limitsInOverview") as? Bool ?? true
  { didSet { save("limitsInOverview", limitsInOverview) } }
  @Published var panelNetwork = UserDefaults.standard.object(forKey: "panelNetwork") as? Bool ?? false
  { didSet { save("panelNetwork", panelNetwork) } }
  @Published var cpuWarning = UserDefaults.standard.object(forKey: "cpuWarning") as? Double ?? 80 {
    didSet { save("cpuWarning", cpuWarning) }
  }
  @Published var cpuCritical = UserDefaults.standard.object(forKey: "cpuCritical") as? Double ?? 95
  { didSet { save("cpuCritical", cpuCritical) } }
  @Published var sustain = UserDefaults.standard.object(forKey: "sustain") as? Double ?? 20 {
    didSet { save("sustain", sustain) }
  }
  @Published var diskWarning = UserDefaults.standard.object(forKey: "diskWarning") as? Double ?? 10
  { didSet { save("diskWarning", diskWarning) } }
  @Published var diskCritical = UserDefaults.standard.object(forKey: "diskCritical") as? Double ?? 5
  { didSet { save("diskCritical", diskCritical) } }
  /// Extra folders the cleaner scans for node_modules and target/.
  @Published var cleanupRoots = UserDefaults.standard.stringArray(forKey: "cleanupRoots") ?? [] {
    didSet { save("cleanupRoots", cleanupRoots) }
  }
  @Published var watched = UserDefaults.standard.stringArray(forKey: "watched") ?? [] {
    didSet { save("watched", Array(watched.prefix(12))) }
  }
  @Published var ignored = UserDefaults.standard.stringArray(forKey: "ignored") ?? [] {
    didSet { save("ignored", Array(ignored.suffix(256))) }
  }
  @Published var selectedSensor = UserDefaults.standard.string(forKey: "selectedSensor") ?? "" {
    didSet { save("selectedSensor", selectedSensor) }
  }
  /// Persistent history is opt-in: off until the user enables it in Settings.
  @Published var historyEnabled = UserDefaults.standard.bool(forKey: "historyEnabled") {
    didSet { save("historyEnabled", historyEnabled) }
  }
  /// Retention in days: 1, 7 or 30.
  @Published var historyRetention =
    UserDefaults.standard.object(forKey: "historyRetention") as? Int ?? 7
  { didSet { save("historyRetention", historyRetention) } }
  var historyDays: Int { historyEnabled ? historyRetention : 0 }
  @Published var thermalInPanel =
    UserDefaults.standard.object(forKey: "thermalInPanel") as? Bool ?? true
  { didSet { save("thermalInPanel", thermalInPanel) } }
  // Notifications: every kind is off until the user opts in.
  @Published var notifyOrphans = UserDefaults.standard.bool(forKey: "notifyOrphans") {
    didSet { save("notifyOrphans", notifyOrphans) }
  }
  @Published var notifyHeavy = UserDefaults.standard.bool(forKey: "notifyHeavy") {
    didSet { save("notifyHeavy", notifyHeavy) }
  }
  @Published var notifyPressure = UserDefaults.standard.bool(forKey: "notifyPressure") {
    didSet { save("notifyPressure", notifyPressure) }
  }
  /// Memory threshold in GB (phys_footprint).
  @Published var notifyMemoryGB =
    UserDefaults.standard.object(forKey: "notifyMemoryGB") as? Double ?? 2
  { didSet { save("notifyMemoryGB", notifyMemoryGB) } }
  /// CPU threshold in percent of one core.
  @Published var notifyCPU = UserDefaults.standard.object(forKey: "notifyCPU") as? Double ?? 150 {
    didSet { save("notifyCPU", notifyCPU) }
  }
  /// Seconds a process must stay above either threshold.
  @Published var notifySustain =
    UserDefaults.standard.object(forKey: "notifySustain") as? Double ?? 60
  { didSet { save("notifySustain", notifySustain) } }
  /// Notify when a busy agent session stops making progress.
  @Published var notifyStalls = UserDefaults.standard.bool(forKey: "notifyStalls") {
    didSet { save("notifyStalls", notifyStalls) }
  }
  /// Minutes without transcript writes before a busy session counts as stalled.
  @Published var stallMinutes = UserDefaults.standard.object(forKey: "stallMinutes") as? Double ?? 10 {
    didSet { save("stallMinutes", stallMinutes) }
  }
  @Published var notifyServiceDown = UserDefaults.standard.bool(forKey: "notifyServiceDown") {
    didSet { save("notifyServiceDown", notifyServiceDown) }
  }
  /// Lets `corescope mcp` reach the app (profiles, Services, machines, cleanup, settings).
  @Published var mcpAppAccess = UserDefaults.standard.object(forKey: "mcpAppAccess") as? Bool ?? true {
    didSet {
      save("mcpAppAccess", mcpAppAccess)
      ControlServer.shared.apply()
    }
  }
  /// Notify when a remote machine needs attention (disk, load, failed units, containers).
  @Published var notifyMachines = UserDefaults.standard.bool(forKey: "notifyMachines") {
    didSet { save("notifyMachines", notifyMachines) }
  }
  /// On battery, run busy agent-started processes at background priority.
  @Published var economyMode = UserDefaults.standard.bool(forKey: "economyMode") {
    didSet { save("economyMode", economyMode) }
  }
  /// Notify when an agent session draws more than `drainWatts` on battery for 5 minutes.
  @Published var notifyAgentDrain = UserDefaults.standard.bool(forKey: "notifyAgentDrain") {
    didSet { save("notifyAgentDrain", notifyAgentDrain) }
  }
  @Published var drainWatts = UserDefaults.standard.object(forKey: "drainWatts") as? Double ?? 3 {
    didSet { save("drainWatts", drainWatts) }
  }
  /// Opt-in update checks (Settings › Updates): off until the user turns them on.
  @Published var checkForUpdates = UserDefaults.standard.bool(forKey: "checkForUpdates") {
    didSet {
      save("checkForUpdates", checkForUpdates)
      UpdateStore.shared.apply()
    }
  }
  var notificationsEnabled: Bool {
    notifyOrphans || notifyHeavy || notifyPressure || notifyStalls || notifyServiceDown || notifyAgentDrain
  }
  // Global port lookup shortcut (Carbon key code + modifier mask); default ⌥⌘K.
  @Published var hotkeyEnabled = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
  {
    didSet {
      save("hotkeyEnabled", hotkeyEnabled)
      Hotkey.shared.apply()
    }
  }
  @Published var hotkeyCode = UserDefaults.standard.object(forKey: "hotkeyCode") as? Int ?? 40 {
    didSet { save("hotkeyCode", hotkeyCode) }
  }
  @Published var hotkeyModifiers =
    UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int
    ?? (HotkeyModifier.command | HotkeyModifier.option)
  { didSet { save("hotkeyModifiers", hotkeyModifiers) } }
  @Published var hotkeyKey = UserDefaults.standard.string(forKey: "hotkeyKey") ?? "K" {
    didSet { save("hotkeyKey", hotkeyKey) }
  }
  var hotkeyLabel: String { shortcutLabel(modifiers: hotkeyModifiers, key: hotkeyKey) }
  private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
  func toggleWatch(_ id: String) {
    if watched.contains(id) {
      watched.removeAll { $0 == id }
    } else if watched.count < 12 {
      watched.append(id)
    }
  }
}

/// Outcome of a signal request, shown as a toast with an optional follow-up force action.
struct ActionFeedback: Identifiable {
  let id = UUID()
  var message: String
  var survivors: [ProcessItem] = []
  var failed = false
  var pending = false
}
/// A termination awaiting the user's confirmation in the main window.
struct KillRequest: Identifiable {
  let id = UUID()
  let targets: [ProcessItem]
  let roots: [ProcessItem]
  let force: Bool
  var title: String {
    if roots.count == 1, let p = roots.first {
      if targets.count > 1 {
        return L(
          force ? "Forçar encerramento de %@ e %@ descendentes?" : "Encerrar %@ e %@ descendentes?",
          p.name, String(targets.count - 1))
      }
      return L(
        force ? "Forçar encerramento de %@ (PID %@)?" : "Encerrar %@ (PID %@)?", p.name,
        String(p.pid))
    }
    return L(
      force ? "Forçar encerramento de %@ processos?" : "Encerrar %@ processos?",
      String(targets.count))
  }
  var detail: String {
    var lines: [String] = []
    if roots.count == 1, let p = roots.first {
      if !p.ports.isEmpty { lines.append(L("Escutando em %@", p.portsLabel)) }
      if !p.cwd.isEmpty { lines.append(L("Diretório: %@", p.shortCwd)) }
      if let o = p.origin { lines.append(L("Iniciado via %@", o.label)) }
    } else {
      lines.append(roots.prefix(6).map { "\($0.name) (\($0.pid))" }.joined(separator: ", "))
    }
    lines.append(
      L(
        force
          ? "SIGKILL encerra imediatamente: trabalho não salvo é perdido."
          : "SIGTERM pede encerramento; builds, agentes e servidores serão interrompidos."))
    if targets.contains(where: { !$0.eligible }) {
      lines.append(L("Processos protegidos ou de outro usuário serão ignorados."))
    }
    return lines.joined(separator: "\n")
  }
}

final class Monitor: ObservableObject {
  static let shared = Monitor()
  @Published var snapshot: Snapshot?
  @Published var error: String?
  @Published var sleeping = false
  @Published var manuallyPaused = false
  @Published var feedback: ActionFeedback?
  @Published var pendingKill: KillRequest?
  private let queue = DispatchQueue(label: "app.corescope.collector", qos: .utility)
  private var timer: Timer?
  private var busy = false
  private var watchdog: DispatchWorkItem?
  private var pressure = -1
  private var pressureAt = 0.0
  private var pressureSource: DispatchSourceMemoryPressure?
  private var observers: [NSObjectProtocol] = []
  var stale: Bool {
    sleeping || manuallyPaused || error != nil
      || snapshot.map { Date().timeIntervalSince1970 - $0.at > 25 } ?? true
  }
  init() {
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      guard let self, let source = self.pressureSource else { return }
      self.pressure = source.data.contains(.critical) ? 2 : source.data.contains(.warning) ? 1 : 0
      self.pressureAt = Date().timeIntervalSince1970
      Notifier.shared.pressureChanged(self.pressure, snapshot: self.snapshot)
    }
    source.resume()
    pressureSource = source
    let nc = NSWorkspace.shared.notificationCenter
    observers.append(
      nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        self?.sleeping = true
        self?.timer?.invalidate()
      })
    observers.append(
      nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        guard let self else { return }
        self.sleeping = false
        self.pressure = -1
        self.pressureAt = 0
        self.queue.async {
          cs_reset()
          DispatchQueue.main.async { self.refresh() }
        }
      })
    DispatchQueue.main.async { self.refresh() }
  }
  func setPaused(_ paused: Bool) {
    manuallyPaused = paused
    timer?.invalidate()
    if !paused {
      queue.async {
        cs_reset()
        DispatchQueue.main.async { self.refresh() }
      }
    }
  }
  func refresh() {
    guard !busy && !sleeping && !manuallyPaused else { return }
    timer?.invalidate()
    busy = true
    watchdog?.cancel()
    let watchdog = DispatchWorkItem { [weak self] in
      guard let self, self.busy else { return }
      self.error = L("Coleta demorando mais de 25 s; leituras anteriores estão antigas.")
    }
    self.watchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: watchdog)
    let p = Preferences.shared
    let config: [String: Any] = [
      "thermal": ProcessInfo.processInfo.thermalState.rawValue, "pressure": pressure,
      "pressure_at": pressureAt, "cpu_warning": p.cpuWarning, "cpu_critical": p.cpuCritical,
      "sustain": p.sustain, "disk_warning": p.diskWarning, "disk_critical": p.diskCritical,
      "watched": p.watched, "ignored": p.ignored, "history_days": p.historyDays,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8)
    else {
      busy = false
      error = L("Configuração inválida")
      return
    }
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("collector", cost) }
      let result: Result<Snapshot, Error> = Result {
        guard let pointer = json.withCString({ cs_snapshot($0) }) else {
          throw NSError(
            domain: "CoreScope", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L("O núcleo não retornou dados")])
        }
        defer { cs_free(pointer) }
        // One copy straight from the Rust buffer (no intermediate String).
        let data = Data(bytes: pointer, count: strlen(pointer))
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = obj["error"] as? String
        {
          throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: L(error)])
        }
        return try JSONDecoder().decode(Snapshot.self, from: data)
      }
      DispatchQueue.main.async {
        self.watchdog?.cancel()
        self.busy = false
        // A sample finishing during sleep is deliberately not presented as current.
        if !self.sleeping && !self.manuallyPaused {
          switch result {
          case .success(let s):
            let shown = Demo.enabled ? Demo.scrub(s) : s
            self.snapshot = shown
            self.error = nil
            Notifier.shared.evaluate(shown)
            Notifier.shared.evaluateDrain(shown)
            EconomyWatch.shared.evaluate(shown)
          case .failure(let e): self.error = e.localizedDescription
          }
        }
        self.schedule()
      }
    }
  }
  private func schedule() {
    guard !sleeping && !manuallyPaused else { return }
    let detailsVisible =
      NSApp.windows.contains {
        $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.resizable) && !($0 is NSPanel)
      } || Preferences.shared.panelVisible
    let seconds = max(
      Preferences.shared.interval,
      ProcessInfo.processInfo.isLowPowerModeEnabled || !detailsVisible ? 10 : 1)
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.refresh()
    }
    timer?.tolerance = seconds * 0.15
  }
  /// Entry point for every termination in the main window: confirms unless the user opted out
  /// for plain SIGTERM of the selected processes. Trees and SIGKILL always confirm.
  func requestKill(_ roots: [ProcessItem], tree: Bool = false, force: Bool = false) {
    guard let s = snapshot, !roots.isEmpty else { return }
    var seen = Set<String>()
    let targets = (tree ? roots.flatMap { s.subtree(of: $0) } : roots).filter {
      seen.insert($0.id).inserted
    }
    let request = KillRequest(targets: targets, roots: roots, force: force)
    if !force && !tree && !Preferences.shared.confirmTerminate {
      signal(targets, force: false)
    } else {
      pendingKill = request
    }
  }
  func signal(_ targets: [ProcessItem], force: Bool) {
    let targets = targets.filter(\.eligible)
    guard !targets.isEmpty else {
      feedback = ActionFeedback(message: L("Nenhum processo elegível para encerrar."), failed: true)
      return
    }
    feedback = ActionFeedback(
      message: targets.count == 1
        ? L("Encerrando %@…", targets[0].name) : L("Encerrando %@ processos…", String(targets.count)),
      pending: true)
    queue.async {
      var errors: [String] = []
      var sent: [ProcessItem] = []
      for p in targets {
        guard let pointer = (p.signalPath ?? p.path).withCString({
          cs_signal(p.pid, p.start, $0, force ? 1 : 0)
        })
        else {
          errors.append("\(p.name): " + L("falha interna"))
          continue
        }
        let text = String(cString: pointer)
        cs_free(pointer)
        if let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = obj["error"] as? String
        {
          errors.append("\(p.name) (\(p.pid)): \(L(error))")
        } else {
          sent.append(p)
        }
      }
      DispatchQueue.main.async { self.refresh() }
      // Observation is scheduled, not a blocking sleep; each identity is rechecked after 2 s.
      self.queue.asyncAfter(deadline: .now() + 2) {
        let survivors = sent.filter { cs_is_same($0.pid, $0.start) == 1 }
        let ended = sent.count - survivors.count
        var parts: [String] = []
        if ended > 0 {
          parts.append(
            ended == 1 && sent.count == 1
              ? L("%@ encerrado.", sent[0].name) : L("%@ processos encerrados.", String(ended)))
        }
        if !survivors.isEmpty {
          parts.append(
            survivors.count == 1
              ? L("%@ (%@) ignorou o pedido.", survivors[0].name, String(survivors[0].pid))
              : L("%@ continuam ativos.", String(survivors.count)))
        }
        parts.append(contentsOf: errors.prefix(3))
        DispatchQueue.main.async {
          self.feedback = ActionFeedback(
            message: parts.joined(separator: " "), survivors: force ? [] : survivors,
            failed: !errors.isEmpty || (force && !survivors.isEmpty))
          self.refresh()
        }
      }
    }
  }
}
