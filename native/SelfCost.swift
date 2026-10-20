import AppKit
import SwiftUI

/// What CoreScope itself spends: CPU time measured in each feature's background work, the app's
/// own CPU (rusage) and that of the processes it started, sampled with every collector pass.
final class CostMeter {
  static let shared = CostMeter()
  static let window: Double = 300
  private let lock = NSLock()
  private var spent: [String: [(at: Double, seconds: Double)]] = [:]
  /// Cumulative CPU seconds of the app and of its finished children (ssh, git, docker, codex).
  private var own: [(at: Double, seconds: Double)] = []
  private var children: [(at: Double, seconds: Double)] = []
  /// CPU of reaped integrated-terminal shells (and what they ran), left out of `children`: the
  /// user's own commands are not CoreScope's cost.
  private var excludedChildren = 0.0
  private var lastChildren = CostMeter.usage(RUSAGE_CHILDREN)

  /// Runs `work` and bills the CPU time this thread spent on it to `feature`.
  @discardableResult
  static func measure<T>(_ feature: String, _ work: () throws -> T) rethrows -> T {
    let start = threadCPU()
    defer { shared.record(feature, threadCPU() - start) }
    return try work()
  }
  /// For work that is easier to bracket: `let t = CostMeter.begin(); defer { CostMeter.end("x", t) }`.
  static func begin() -> Double { threadCPU() }
  static func end(_ feature: String, _ start: Double) { shared.record(feature, threadCPU() - start) }
  /// For work too fine-grained to record each time (the integrated terminal reads output a few
  /// bytes at a time): the caller adds up thread CPU and hands it over in one record.
  static func add(_ feature: String, seconds: Double) { shared.record(feature, seconds) }
  static func threadNow() -> Double { threadCPU() }
  private func record(_ feature: String, _ seconds: Double) {
    let now = Date().timeIntervalSince1970
    // The first minute (first scans, token history, caches) is startup, not the steady cost.
    guard now - Self.launched > Self.warmup else { return }
    lock.lock()
    defer { lock.unlock() }
    var list = spent[feature, default: []]
    list.append((now, seconds))
    list.removeAll { now - $0.at > Self.window }
    spent[feature] = list
    guard feature == "collector" else { return }
    own.append((now, Self.usage(RUSAGE_SELF)))
    lastChildren = Self.usage(RUSAGE_CHILDREN)
    children.append((now, lastChildren - excludedChildren))
    own.removeAll { now - $0.at > Self.window + 30 }
    children.removeAll { now - $0.at > Self.window + 30 }
  }
  /// Called right after an integrated shell is reaped: its CPU, and its jobs', joined
  /// RUSAGE_CHILDREN in one step. Children reaped since the last sample go with it (seconds).
  func excludeReapedShell() {
    lock.lock()
    defer { lock.unlock() }
    let now = Self.usage(RUSAGE_CHILDREN)
    excludedChildren += max(0, now - lastChildren)
    lastChildren = now
  }
  /// Average share of one core per feature over the last five minutes (or since launch).
  func features() -> [String: Double] {
    let now = Date().timeIntervalSince1970
    let span = min(Self.window, now - Self.launched - Self.warmup)
    guard span >= 10 else { return [:] }
    lock.lock()
    defer { lock.unlock() }
    return spent.mapValues { $0.reduce(0) { $0 + $1.seconds } / span * 100 }
  }
  func appAverage() -> Double? {
    lock.lock()
    defer { lock.unlock() }
    return averageCPUShare(own, window: Self.window)
  }
  func childrenAverage() -> Double? {
    lock.lock()
    defer { lock.unlock() }
    return averageCPUShare(children, window: Self.window)
  }
  private static let launched = Date().timeIntervalSince1970
  static let warmup: Double = 60
  private static func threadCPU() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
  }
  fileprivate static func usage(_ who: Int32) -> Double {
    var u = rusage()
    getrusage(who, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
  }
}

/// One feature that runs in the background, whether it is on and what it costs.
struct FeatureCost: Identifiable {
  let id: String
  let title: String
  let on: Bool
  /// When and how often it works.
  let cadence: String
  /// Measured share of one core (last 5 minutes), when the work runs in CoreScope's threads.
  let cpu: Double?
  var weight: CostWeight { CostWeight(percent: cpu ?? 0) }
}

/// CoreScope's footprint right now, from the latest snapshot plus the cost meter.
struct SelfCost {
  struct Part {
    var count = 0
    var cpu = 0.0
    var memory = 0.0
    var energy: Double?
  }
  var app = Part()
  var appAverage: Double?
  /// The bundled CLI running for agents: MCP servers, the gate hook, the status line.
  var helpers = Part()
  /// Processes the app started that are still running (ssh, codex app-server…).
  var children = Part()
  var childrenAverage: Double?
  var features: [FeatureCost] = []

  var totalCPU: Double { app.cpu + helpers.cpu + children.cpu }
  var totalMemory: Double { app.memory + helpers.memory + children.memory }
  var totalEnergy: Double? {
    let parts = [app.energy, helpers.energy, children.energy].compactMap { $0 }
    return parts.isEmpty ? nil : parts.reduce(0, +)
  }
  /// The features worth a look: measured at medium or more.
  var heavy: [FeatureCost] { features.filter { $0.on && $0.weight >= .medium }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) } }
  /// Too much for a monitor: more than 2 % of a core on average or 500 MB.
  /// Whether the main window was open: drawing it costs a few % of a core on its own.
  var windowOpen = false
  /// CPU is judged on the 5-minute average only (one busy sample, a scan or a page opening, is not
  /// a pattern): over 2 % of a core in the background, 6 % with the window open, or 500 MB.
  /// The integrated terminal's output is the user's own command: listed, never judged.
  var tooMuch: Bool {
    let limit: Double = windowOpen ? 6 : 2
    let terminal = features.first { $0.id == "terminal" }?.cpu ?? 0
    return (appAverage.map { $0 - terminal + (childrenAverage ?? 0) + helpers.cpu > limit } ?? false)
      || totalMemory > 500 * 1_048_576
  }

  static func current() -> SelfCost {
    var cost = SelfCost()
    let own = getpid()
    let shells = Set(ProjectShells.shared.shells.values.map(\.pid))
    if let s = Monitor.shared.snapshot {
      func add(_ part: inout Part, _ p: ProcessItem) {
        part.count += 1
        part.cpu += max(0, p.cpu.value ?? 0)
        part.memory += max(0, p.memory.value ?? 0)
        if let e = p.energy?.value { part.energy = (part.energy ?? 0) + e }
      }
      for p in s.processes {
        if p.pid == own {
          add(&cost.app, p)
        } else if isCoreScopeHelper(path: p.path) {
          add(&cost.helpers, p)
        } else if p.ppid == own && !shells.contains(p.pid) {
          add(&cost.children, p)
        }
      }
    }
    cost.windowOpen = NSApp.windows.contains {
      $0.isVisible && !$0.isMiniaturized && $0.identifier?.rawValue.contains("main") == true
    }
    cost.appAverage = CostMeter.shared.appAverage()
    cost.childrenAverage = CostMeter.shared.childrenAverage()
    cost.features = features(CostMeter.shared.features())
    return cost
  }

  private static func features(_ measured: [String: Double]) -> [FeatureCost] {
    let p = Preferences.shared
    let checks = HealthStore.shared.allChecks.count
    let hosts = MachineStore.shared.hosts.count
    let panelHosts = p.panelVisible && p.panelMachines ? MachineStore.shared.panelHosts.count : 0
    let collectorMS = Monitor.shared.snapshot?.collector_ms ?? 0
    func f(_ id: String, _ title: String, on: Bool, _ cadence: String, measured key: String? = nil) -> FeatureCost {
      FeatureCost(
        id: id, title: title, on: on, cadence: cadence,
        cpu: key.flatMap { measured[$0] } ?? (key == nil || measured.isEmpty ? nil : 0))
    }
    return [
      f(
        "collector", L("Coletor (processos, portas, sensores)"), on: true,
        L("a cada %@ s com janela ou painel visível, 10 s sem · %@ ms por passagem", "\(Int(p.interval))", String(format: "%.0f", collectorMS)),
        measured: "collector"),
      f("panel", L("Painel flutuante"), on: p.panelVisible, L("mantém o coletor no intervalo rápido mesmo com a janela fechada")),
      f("history", L("Histórico persistente"), on: p.historyEnabled, L("uma gravação por minuto, dentro do coletor; consultas da página à parte"), measured: "history"),
      f("agents", L("Agentes, sessões e limites"), on: true, L("a cada 20 s"), measured: "agents"),
      f("tokens", L("Uso de tokens"), on: true, L("a cada 20 s, só arquivos novos ou alterados"), measured: "tokens"),
      f("codexLive", L("Limites ao vivo do Codex"), on: p.codexLiveLimits, L("inicia o codex app-server a cada 5 min")),
      f("claudeLive", L("Limites ao vivo do Claude"), on: p.claudeLiveLimits, L("roda claude -p /usage a cada 5 min com o Claude em uso, 30 min sem · alguns segundos de CPU por leitura")),
      f("claudeLimits", L("Status line do Claude"), on: p.claudeLimits, L("roda o corescope a cada atualização do status line do Claude")),
      f(
        "services", L("Serviços"), on: checks > 0,
        checks == 1 ? L("1 verificação a cada 30 s") : L("%@ verificações a cada 30 s", "\(checks)")),
      f("projects", L("Arquivos .corescope.yml"), on: true, L("relê a cada 60 s; procura pastas novas a cada 10 min"), measured: "projects"),
      f(
        "environment", L("Status de ambientes"), on: !EnvironmentStore.shared.specs.isEmpty,
        L("roda o comando status de cada ambiente a cada 30 s, um por vez, com limite de tempo"), measured: "environment"),
      f("projects-git", L("Projetos (git)"), on: true, L("só com as alterações de um projeto abertas: FSEvents, recarrega no máximo a cada 0,5 s e ignora o que o .gitignore cobre"), measured: "projects-git"),
      f("containers", L("Contêineres"), on: true, L("só enquanto uma tela com contêineres está aberta"), measured: "containers"),
      f(
        "machines", L("Máquinas (ssh)"), on: hosts > 0,
        panelHosts > 0
          ? L("%@ hosts a cada 60 s com a página aberta; %@ sempre, pelo painel flutuante", "\(hosts)", "\(panelHosts)")
          : L("%@ hosts a cada 60 s, só com a página aberta", "\(hosts)"), measured: "machines"),
      f("logs", L("Logs"), on: true, L("a cada 2 s, só com a página aberta"), measured: "logs"),
      f("ports", L("Portas e exposição"), on: true, L("a cada 15 s, só com a página aberta"), measured: "ports"),
      f("databases", L("Bancos locais"), on: true, L("a cada 15 s, só com a página aberta"), measured: "databases"),
      f("cleanup", L("Limpeza"), on: true, L("só quando você pede um escaneamento"), measured: "cleanup"),
      f("storage", L("Saúde do SSD (SMART)"), on: true, L("lê ao abrir Armazenamento, no máximo a cada 10 min"), measured: "storage"),
      f("settingsbackup", L("Backup das configurações"), on: SettingsBackup.shared.enabled, L("alguns segundos depois de uma mudança, só se mudou algo"), measured: "settingsbackup"),
      f("diskgrowth", L("Crescimento do disco"), on: true, L("mede no máximo a cada 6 h, alguns segundos de disco"), measured: "diskgrowth"),
      f("economy", L("Modo economia"), on: p.economyMode, L("só na bateria, a cada coleta")),
      f("updates", L("Procurar atualizações"), on: p.checkForUpdates, L("um pedido ao GitHub por dia, no máximo")),
      f("mcp", L("Acesso do MCP ao app"), on: p.mcpAppAccess, L("socket local parado até um agente pedir algo")),
      f(
        "terminal", L("Terminal integrado"), on: !ProjectShells.shared.shells.isEmpty,
        L("lê e desenha a saída dos shells abertos; nada com o painel oculto além de ler o que chega"), measured: "terminal"),
    ]
  }

  /// What `corescope_cost` returns to agents.
  func json() -> [String: Any] {
    func part(_ p: Part, average: Double? = nil) -> [String: Any] {
      [
        "processes": p.count, "cpu_percent": round(p.cpu * 10) / 10, "memory_bytes": Int(p.memory),
        "energy_watts": p.energy.map { round($0 * 100) / 100 } ?? NSNull(),
        "cpu_percent_5min": average.map { round($0 * 100) / 100 } ?? NSNull(),
      ]
    }
    return [
      "app": part(app, average: appAverage), "helpers": part(helpers), "children": part(children, average: childrenAverage),
      "total": [
        "cpu_percent": round(totalCPU * 10) / 10, "memory_bytes": Int(totalMemory),
        "energy_watts": totalEnergy.map { round($0 * 100) / 100 } ?? NSNull(),
      ],
      "too_much": tooMuch, "window_open": windowOpen,
      "features": features.map {
        [
          "id": $0.id, "title": $0.title, "on": $0.on, "cadence": $0.cadence,
          "cpu_percent_5min": $0.cpu.map { round($0 * 1000) / 1000 } ?? NSNull(),
          "weight": ["low", "medium", "high"][$0.weight.rawValue],
        ] as [String: Any]
      },
      "note": "cpu_percent is a share of one core. Feature CPU is measured in CoreScope's own threads; "
        + "helpers are the bundled CLI (MCP servers, gate hook, status line), children are processes the app started.",
    ]
  }
}

/// CoreScope's footprint and the features behind it, with the switches that change it.
struct SelfCostView: View {
  @ObservedObject var p = Preferences.shared
  @ObservedObject var monitor = Monitor.shared
  var compact = false
  var body: some View {
    let cost = SelfCost.current()
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 18) {
        figure(L("CPU agora"), String(format: "%.1f%%", cost.totalCPU))
        figure(L("Média 5 min"), cost.appAverage.map { String(format: "%.2f%%", $0 + (cost.childrenAverage ?? 0)) } ?? "—")
        figure(L("Memória"), formatBytes(cost.totalMemory))
        figure(L("Energia"), cost.totalEnergy.map { String(format: "%.2f W", $0) } ?? "—")
      }
      VStack(alignment: .leading, spacing: 3) {
        line(L("App"), cost.app)
        if cost.helpers.count > 0 { line(L("Ajudantes (MCP, gancho, status line)"), cost.helpers) }
        if cost.children.count > 0 { line(L("Processos iniciados pelo app"), cost.children) }
      }.font(.caption).monospacedDigit()
      if cost.tooMuch {
        Label(
          L("CoreScope está gastando mais do que um monitor deveria. Desligue o que não usa abaixo; os itens medidos como médio ou alto vêm primeiro."),
          systemImage: "exclamationmark.triangle.fill"
        ).font(.caption).foregroundStyle(.orange)
      }
      if !compact { Divider() }
      ForEach(compact ? Array(cost.features.filter(\.on).sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(5)) : sorted(cost.features)) {
        feature in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Circle().fill(color(feature)).frame(width: 7, height: 7)
          VStack(alignment: .leading, spacing: 1) {
            Text(feature.title).font(.callout).foregroundStyle(feature.on ? .primary : .secondary)
            if !compact { Text(feature.cadence).font(.caption).foregroundStyle(.secondary) }
          }
          Spacer(minLength: 6)
          if let cpu = feature.cpu, feature.on {
            Text(cpu < 0.01 ? "<0.01%" : String(format: "%.2f%%", cpu)).font(.caption).monospacedDigit()
              .foregroundStyle(feature.weight == .high ? .orange : .secondary)
          }
          if !compact { control(feature.id) }
        }
      }
      Text(
        L("CPU em % de um núcleo. Cada recurso é medido no tempo de CPU das próprias threads do CoreScope, sem o primeiro minuto (arranque); ajudantes e processos iniciados aparecem à parte. A interface (janela, painel, barra de menus) fica no total do app.")
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private func sorted(_ list: [FeatureCost]) -> [FeatureCost] {
    list.sorted { a, b in a.on != b.on ? a.on : (a.cpu ?? 0) > (b.cpu ?? 0) }
  }
  private func color(_ f: FeatureCost) -> Color {
    guard f.on else { return .secondary.opacity(0.4) }
    switch f.weight {
    case .high: return .orange
    case .medium: return .yellow
    case .low: return Tint.brand
    }
  }
  private func figure(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
    }
  }
  private func line(_ title: String, _ part: SelfCost.Part) -> some View {
    HStack {
      Text(part.count > 1 ? "\(title) ×\(part.count)" : title)
      Spacer()
      Text(String(format: "%.1f%%", part.cpu)).frame(width: 50, alignment: .trailing)
      Text(formatBytes(part.memory)).frame(width: 70, alignment: .trailing)
      Text(part.energy.map { String(format: "%.2f W", $0) } ?? "—").frame(width: 60, alignment: .trailing)
    }.foregroundStyle(.secondary)
  }
  @ViewBuilder private func control(_ id: String) -> some View {
    switch id {
    case "collector":
      Picker("", selection: $p.interval) {
        Text("2 s").tag(2.0)
        Text("3 s").tag(3.0)
        Text("5 s").tag(5.0)
        Text("10 s").tag(10.0)
      }.labelsHidden().frame(width: 70).controlSize(.small)
        .onChange(of: p.interval) { _, _ in monitor.refresh() }
    case "panel": toggle($p.panelVisible)
    case "history": toggle($p.historyEnabled)
    case "codexLive": toggle($p.codexLiveLimits)
    case "claudeLive": toggle($p.claudeLiveLimits)
    case "economy": toggle($p.economyMode)
    case "mcp": toggle($p.mcpAppAccess)
    default: EmptyView()
    }
  }
  private func toggle(_ binding: Binding<Bool>) -> some View {
    Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.mini)
  }
}

/// Footer readout of CoreScope's own CPU and memory; opens the breakdown.
struct SelfCostBadge: View {
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var open = false
  var body: some View {
    let cost = SelfCost.current()
    Button {
      open.toggle()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "gauge.with.dots.needle.33percent")
        Text(L("CoreScope %@ · %@", String(format: "%.1f%%", cost.totalCPU), formatBytes(cost.totalMemory)))
      }.foregroundStyle(cost.tooMuch ? .orange : .secondary)
    }
    .buttonStyle(.plain)
    .help(L("Quanto o próprio CoreScope está gastando"))
    .popover(isPresented: $open, arrowEdge: .top) {
      SelfCostView(compact: true).padding(14).frame(width: 380)
    }
  }
}
