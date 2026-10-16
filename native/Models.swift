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
  var unavailable: String {
    state == "unsupported"
      ? "Não suportado" : state == "permission" ? "Sem permissão" : "Temporariamente indisponível"
  }
  var bytes: String {
    value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—"
  }
  var temperature: String { value.map { String(format: "%.1f °C", $0) } ?? unavailable }
  var percent: String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
  var rate: String {
    value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" }
      ?? "—"
  }
  var explanation: String {
    "\(source) · \(unit)\n\(value == nil ? unavailable : "Última leitura: " + Date(timeIntervalSince1970: at).formatted(date: .omitted, time: .standard))"
  }
}
struct Point: Decodable {
  let at: Double
  let cpu: Double?
  let memory: Double?
}
struct ProcessItem: Decodable, Identifiable {
  let id: String
  let pid: Int32
  let ppid: Int32
  let uid: UInt32
  let user: String
  let start: UInt64
  let name: String
  let path: String
  let cpu: Metric
  let memory: Metric
  let resident: Metric
  let threads: Metric
  let read: Metric
  let write: Metric
  let eligible: Bool
  let blocked: String
  let candidate: String?
  let attribution: String?
  let high_cpu_seconds: Double
  let history: [Point]
  var cpuValue: Double { cpu.value ?? -1 }
  var memoryValue: Double { memory.value ?? -1 }
  var threadValue: Double { threads.value ?? -1 }
  var startDate: Date { Date(timeIntervalSince1970: Double(start) / 1_000_000) }
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
  var label: String { level == 2 ? "Crítico" : level == 1 ? "Atenção" : "Sem alerta" }
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
  let pressure: Metric
  let thermal: Metric
  let processes: [ProcessItem]
  let volumes: [Volume]
  let disks: [Disk]
  let diagnostics: [Diagnostic]
  let history: [Point]
  let collector_ms: Double
  let own_wakeups: Metric
  let process_state: String
  let volume_state: String
  let disk_state: String
  let current_uid: UInt32
  var thermalLabel: String {
    guard let v = thermal.value else { return "Indisponível" }
    return ["Nominal", "Moderado", "Sério", "Crítico"][min(3, max(0, Int(v)))]
  }
  var memorySummary: String {
    guard let a = active.value, let w = wired.value, let c = compressed.value else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(a + w + c), countStyle: .memory)
  }
  var diskRate: String {
    let values = disks.compactMap { d -> Double? in
      guard let r = d.read.value, let w = d.write.value else { return nil }
      return r + w
    }
    guard !values.isEmpty else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(values.reduce(0, +)), countStyle: .file)
      + "/s"
  }
}

final class Preferences: ObservableObject {
  static let shared = Preferences()
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
  @Published var panelVisible = UserDefaults.standard.bool(forKey: "panelVisible") {
    didSet { save("panelVisible", panelVisible) }
  }
  @Published var panelOpacity =
    UserDefaults.standard.object(forKey: "panelOpacity") as? Double ?? 0.94
  { didSet { save("panelOpacity", panelOpacity) } }
  @Published var panelScale = UserDefaults.standard.object(forKey: "panelScale") as? Double ?? 1.0 {
    didSet { save("panelScale", panelScale) }
  }
  @Published var panelTop = UserDefaults.standard.object(forKey: "panelTop") as? Bool ?? true {
    didSet { save("panelTop", panelTop) }
  }
  @Published var panelLocked = UserDefaults.standard.bool(forKey: "panelLocked") {
    didSet { save("panelLocked", panelLocked) }
  }
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
  @Published var watched = UserDefaults.standard.stringArray(forKey: "watched") ?? [] {
    didSet { save("watched", Array(watched.prefix(12))) }
  }
  @Published var ignored = UserDefaults.standard.stringArray(forKey: "ignored") ?? [] {
    didSet { save("ignored", Array(ignored.suffix(256))) }
  }
  @Published var selectedSensor = UserDefaults.standard.string(forKey: "selectedSensor") ?? "" {
    didSet { save("selectedSensor", selectedSensor) }
  }
  @Published var thermalInPanel =
    UserDefaults.standard.object(forKey: "thermalInPanel") as? Bool ?? true
  { didSet { save("thermalInPanel", thermalInPanel) } }
  private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
  func toggleWatch(_ id: String) {
    if watched.contains(id) {
      watched.removeAll { $0 == id }
    } else if watched.count < 12 {
      watched.append(id)
    }
  }
}

final class Monitor: ObservableObject {
  static let shared = Monitor()
  @Published var snapshot: Snapshot?
  @Published var error: String?
  @Published var sleeping = false
  @Published var manuallyPaused = false
  @Published var actionResults: String?
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
      self.error = "Coleta demorando mais de 25 s; leituras anteriores estão antigas."
    }
    self.watchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: watchdog)
    let p = Preferences.shared
    let config: [String: Any] = [
      "thermal": ProcessInfo.processInfo.thermalState.rawValue, "pressure": pressure,
      "pressure_at": pressureAt, "cpu_warning": p.cpuWarning, "cpu_critical": p.cpuCritical,
      "sustain": p.sustain, "disk_warning": p.diskWarning, "disk_critical": p.diskCritical,
      "watched": p.watched, "ignored": p.ignored,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: config),
      let json = String(data: data, encoding: .utf8)
    else {
      busy = false
      error = "Configuração inválida"
      return
    }
    queue.async {
      let result: Result<Snapshot, Error> = Result {
        guard let pointer = json.withCString({ cs_snapshot($0) }) else {
          throw NSError(
            domain: "CoreScope", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "O núcleo não retornou dados"])
        }
        defer { cs_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = obj["error"] as? String
        {
          throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
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
            self.snapshot = s
            self.error = nil
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
  func signal(_ targets: [ProcessItem], force: Bool) {
    queue.async {
      var results: [String] = []
      var sent: [ProcessItem] = []
      for p in targets {
        guard let pointer = p.path.withCString({ cs_signal(p.pid, p.start, $0, force ? 1 : 0) })
        else {
          results.append("\(p.name): falha interna")
          continue
        }
        let text = String(cString: pointer)
        cs_free(pointer)
        if let data = text.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = obj["error"] as? String
        {
          results.append("\(p.name) (\(p.pid)): \(error)")
        } else {
          sent.append(p)
        }
      }
      // Observation is scheduled, not a blocking sleep; every identity is checked on the next fresh sample.
      DispatchQueue.main.async {
        self.actionResults =
          (results + sent.map { "\($0.name) (\($0.pid)): sinal enviado; aguardando observação." })
          .joined(separator: "\n")
        self.refresh()
      }
      self.queue.asyncAfter(deadline: .now() + 2) {
        let text =
          (results
          + sent.map { p in
            cs_is_same(p.pid, p.start) == 1
              ? "\(p.name) (\(p.pid)): continua presente após 2 s. Encerrar à força exige outra confirmação."
              : "\(p.name) (\(p.pid)): não está mais acessível com esta identidade (encerrou ou acesso mudou)."
          }).joined(separator: "\n")
        DispatchQueue.main.async {
          self.actionResults = text
          self.refresh()
        }
      }
    }
  }
}
