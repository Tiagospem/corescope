import AppKit
import SwiftUI

struct PublishedPort: Decodable, Hashable {
  let host: UInt16
  let container: UInt16
  let proto: String
  let exposed: Bool
}
struct ContainerItem: Decodable, Identifiable, Equatable {
  let id: String
  var name: String
  let image: String
  let engine: String
  let state: String
  let status: String
  let health: String?
  var project: String?
  let service: String?
  let created: Double
  let ports: [PublishedPort]
  /// Percent of one core, like process CPU.
  let cpu: Double?
  let memory: Double?
  let memory_limit: Double?
  var running: Bool { state == "running" }
  var tcpPorts: [PublishedPort] { ports.filter { $0.proto == "tcp" } }
  var cpuText: String { cpu.map { String(format: "%.1f%%", $0) } ?? "—" }
  var memoryText: String { memory.map(formatBytes) ?? "—" }
  var stateLabel: String {
    if let health, running { return L(health == "healthy" ? "Saudável" : health == "unhealthy" ? "Com falha" : "Iniciando") }
    switch state {
    case "running": return L("Rodando")
    case "paused": return L("Pausado")
    case "restarting": return L("Reiniciando")
    case "created": return L("Criado")
    case "exited", "dead": return L("Parado")
    default: return state
    }
  }
  var stateColor: Color {
    if health == "unhealthy" || state == "dead" || state == "restarting" { return .orange }
    return running ? Tint.brand : .secondary
  }
}
struct ContainerEngine: Decodable, Equatable {
  let name: String
  let socket: String
  let state: String
}
struct ContainerReport: Decodable, Equatable {
  let engines: [ContainerEngine]
  var containers: [ContainerItem]
}

/// Reads containers from local Docker Engine sockets on its own queue. Polls at most every 5 s
/// and only while a visible surface asks for it: `stats` watchers add one stats read per
/// running container; port-only watchers (listening servers) need just the list.
final class ContainerStore: ObservableObject {
  static let shared = ContainerStore()
  @Published private(set) var report: ContainerReport?
  @Published private(set) var error: String?
  /// Published host port → running container, for labeling ports held by the VM helper.
  private(set) var owners: [UInt16: ContainerItem] = [:]
  private let queue = DispatchQueue(label: "app.corescope.containers", qos: .utility)
  private let actions = DispatchQueue(label: "app.corescope.containers.actions", qos: .userInitiated)
  private var statsWatchers = Set<UUID>()
  private var portWatchers = Set<UUID>()
  private var timer: Timer?
  private var busy = false
  private var lastRead = Date.distantPast

  func watch(_ token: UUID, stats: Bool) {
    if stats { statsWatchers.insert(token) } else { portWatchers.insert(token) }
    // A surface that just opened gets data now, unless a read happened moments ago.
    if Date().timeIntervalSince(lastRead) > 2 { tick() } else if timer == nil { schedule() }
  }
  func unwatch(_ token: UUID) {
    statsWatchers.remove(token)
    portWatchers.remove(token)
    if statsWatchers.isEmpty && portWatchers.isEmpty {
      timer?.invalidate()
      timer = nil
    }
  }
  /// Some surface is on screen: a minimized or covered window keeps its views but needs no data.
  private var surfaceVisible: Bool {
    NSApp.windows.contains {
      $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        && $0.className != "NSStatusBarWindow"
    }
  }
  private func tick() {
    timer?.invalidate()
    timer = nil
    guard !busy, !statsWatchers.isEmpty || !portWatchers.isEmpty else { return }
    let monitor = Monitor.shared
    let stats = !statsWatchers.isEmpty
    // Port labels only matter when a VM helper (OrbStack, Docker Desktop…) is listening.
    let needed =
      stats
      || monitor.snapshot?.servers.contains { $0.tags.contains("container") } == true
    guard needed, !monitor.sleeping, !monitor.manuallyPaused, surfaceVisible else {
      schedule()
      return
    }
    busy = true
    queue.async {
      let result: Result<ContainerReport, Error> = Result {
        guard let pointer = cs_containers(stats ? 1 : 0) else {
          throw NSError(
            domain: "CoreScope", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L("O núcleo não retornou dados")])
        }
        defer { cs_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = obj["error"] as? String
        {
          throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: L(error)])
        }
        return try JSONDecoder().decode(ContainerReport.self, from: data)
      }
      DispatchQueue.main.async {
        self.busy = false
        self.lastRead = Date()
        switch result {
        case .success(var report):
          if Demo.enabled { report.containers = report.containers.map(Demo.container) }
          self.owners = Self.owners(report.containers)
          if report != self.report { self.report = report }
          if self.error != nil { self.error = nil }
        case .failure(let e): self.error = e.localizedDescription
        }
        self.schedule()
      }
    }
  }
  private func schedule() {
    guard timer == nil, !statsWatchers.isEmpty || !portWatchers.isEmpty else { return }
    let seconds = ProcessInfo.processInfo.isLowPowerModeEnabled ? 10.0 : 5.0
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.timer = nil
      self?.tick()
    }
    timer?.tolerance = 1
  }
  static func owners(_ containers: [ContainerItem]) -> [UInt16: ContainerItem] {
    var out: [UInt16: ContainerItem] = [:]
    var ambiguous = Set<UInt16>()
    for c in containers where c.running {
      for p in c.tcpPorts where !ambiguous.contains(p.host) {
        if out[p.host] != nil {
          out.removeValue(forKey: p.host)
          ambiguous.insert(p.host)
        } else {
          out[p.host] = c
        }
      }
    }
    return out
  }
  /// Runs after the user confirmed; the engine allows 10 s for a clean exit before SIGKILL.
  func perform(_ container: ContainerItem, action: String) {
    let monitor = Monitor.shared
    let stop = action == "stop"
    monitor.feedback = ActionFeedback(
      message: L(stop ? "Parando %@…" : "Reiniciando %@…", container.name), pending: true)
    actions.async {
      let error: String? = {
        guard
          let pointer = container.id.withCString({ id in
            action.withCString { cs_container_action(id, $0) }
          })
        else { return L("falha interna") }
        defer { cs_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // "O motor recusou a ação (HTTP …) <engine message>": only the prefix is ours to translate.
        return (obj?["error"] as? String).map { e in
          let refused = "O motor recusou a ação"
          return e.hasPrefix(refused) ? L(refused) + e.dropFirst(refused.count) : L(e)
        }
      }()
      DispatchQueue.main.async {
        monitor.feedback = ActionFeedback(
          message: error.map { "\(container.name): \($0)" }
            ?? L(stop ? "%@ parado." : "%@ reiniciado.", container.name),
          failed: error != nil)
        self.lastRead = .distantPast
        self.tick()
        monitor.refresh()
      }
    }
  }
}

private struct ContainerWatch: ViewModifier {
  let stats: Bool
  @ViewState private var token = UUID()
  func body(content: Content) -> some View {
    content
      .onAppear { ContainerStore.shared.watch(token, stats: stats) }
      .onDisappear { ContainerStore.shared.unwatch(token) }
  }
}
extension View {
  /// Keeps container data fresh while this view is on screen.
  func watchesContainers(stats: Bool = true) -> some View { modifier(ContainerWatch(stats: stats)) }
}

/// Stop or restart in place with the same arm-then-confirm pattern as process termination.
struct ContainerActionButton: View {
  let container: ContainerItem
  let action: String
  var body: some View {
    let stop = action == "stop"
    ArmedButton(
      symbol: stop ? "stop.circle" : "arrow.clockwise.circle",
      confirm: stop ? L("Parar") : L("Reiniciar"),
      help: L(stop ? "Parar o contêiner %@" : "Reiniciar o contêiner %@", container.name),
      tint: stop ? Tint.danger : .orange
    ) {
      ContainerStore.shared.perform(container, action: action)
    }
  }
}

struct ContainerIcon: View {
  let container: ContainerItem
  var size: CGFloat = 16
  var body: some View {
    let color: Color = container.running ? .blue : .secondary
    Image(systemName: "shippingbox")
      .font(.system(size: size * 0.62, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25))
  }
}

/// Explains why no containers are listed: no engine, engine stopped, no permission or empty.
struct ContainerEmptyState: View {
  let store: ContainerStore
  var body: some View {
    if let error = store.error {
      EmptyNote(text: L("Falha ao ler contêineres: %@", error))
    } else if let report = store.report {
      let reachable = report.engines.filter { $0.state == "ok" }
      let names = report.engines.map(\.name).joined(separator: ", ")
      if report.engines.isEmpty {
        EmptyNote(
          text: L("Nenhum motor de contêineres encontrado (OrbStack, Docker Desktop ou Colima)."))
      } else if reachable.isEmpty {
        EmptyNote(
          text: report.engines.contains { $0.state == "permission" }
            ? L("Sem permissão para o socket de %@.", names)
            : L("%@ não está em execução.", names))
      } else {
        EmptyNote(text: L("Nenhum contêiner em %@.", reachable.map(\.name).joined(separator: ", ")))
      }
    } else {
      EmptyNote(text: L("Lendo contêineres…"))
    }
  }
}

/// Container rows aligned as a grid: name, project, ports, CPU, memory and actions.
struct ContainerGrid: View {
  let containers: [ContainerItem]
  var showImage = true
  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
      GridRow {
        Text(L("Contêiner"))
        Text(L("Projeto"))
        if showImage { Text(L("Imagem")) }
        Text(L("Portas"))
        Text(L("CPU")).gridColumnAlignment(.trailing)
        Text(L("Memória")).gridColumnAlignment(.trailing)
        Text("")
      }.font(.caption).foregroundStyle(.secondary)
      ForEach(containers) { c in
        GridRow {
          HStack(spacing: 6) {
            ContainerIcon(container: c)
            VStack(alignment: .leading, spacing: 1) {
              Text(c.name).lineLimit(1)
              HStack(spacing: 4) {
                Circle().fill(c.stateColor).frame(width: 5, height: 5)
                Text(c.stateLabel)
                Text("· \(c.engine)").foregroundStyle(.tertiary)
              }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
          }.help("\(c.status)\n\(c.id.prefix(12))")
          Text(c.project ?? "—").lineLimit(1).foregroundStyle(c.project == nil ? .secondary : .primary)
            .help(c.service.map { L("Serviço %@", $0) } ?? "")
          if showImage {
            Text(c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              .frame(maxWidth: 180, alignment: .leading).help(c.image)
          }
          ContainerPorts(ports: c.tcpPorts)
          Text(c.running ? c.cpuText : "—").monospacedDigit()
          Text(c.running ? c.memoryText : "—").monospacedDigit()
            .help(c.memory_limit.map { L("Limite %@", formatBytes($0)) } ?? "")
          HStack(spacing: 2) {
            if c.running {
              ContainerActionButton(container: c, action: "restart")
              ContainerActionButton(container: c, action: "stop")
            }
          }
        }.font(.callout)
      }
    }
  }
}
struct ContainerPorts: View {
  let ports: [PublishedPort]
  var body: some View {
    HStack(spacing: 3) {
      if ports.isEmpty { Text("—").foregroundStyle(.secondary) }
      ForEach(ports.prefix(3), id: \.self) { p in
        Badge(text: ":\(p.host)", color: p.exposed ? .orange : Tint.netIn)
          .help(
            L("Porta %@ do contêiner", "\(p.container)") + " · "
              + (p.exposed ? L("Acessível na rede") : L("Somente local")))
      }
      if ports.count > 3 { Text("+\(ports.count - 3)").font(.caption2).foregroundStyle(.secondary) }
      if let port = ports.first?.host { OpenPortButton(port: port) }
    }
  }
}

/// Overview card: running containers first, a short list and a link to the full section.
struct ContainersCard: View {
  @ObservedObject var store = ContainerStore.shared
  var body: some View {
    let all = store.report?.containers ?? []
    let running = all.filter(\.running)
    Card {
      CardHeader(title: L("Contêineres"), symbol: "shippingbox", tint: .blue, count: running.count) {
        if !running.isEmpty {
          Text(
            L(
              "CPU %@ · %@", String(format: "%.1f%%", running.compactMap(\.cpu).reduce(0, +)),
              formatBytes(running.compactMap(\.memory).reduce(0, +)))
          ).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Button(L("Ver todos")) { navigate(.agents) }.buttonStyle(.link).font(.caption)
      }
      if running.isEmpty {
        ContainerEmptyState(store: store)
        if all.count > running.count {
          Text(L("%@ parados", "\(all.count - running.count)")).font(.caption).foregroundStyle(.secondary)
        }
      } else {
        ContainerGrid(containers: Array(running.prefix(8)), showImage: false)
        if running.count > 8 {
          Text(L("+ %@ contêineres", "\(running.count - 8)")).font(.caption).foregroundStyle(.secondary)
        }
      }
    }.watchesContainers()
  }
}

/// Agents page section: every container, stopped ones folded away.
struct ContainersSection: View {
  @ObservedObject var store = ContainerStore.shared
  @ViewState private var showStopped = false
  var body: some View {
    let all = store.report?.containers ?? []
    let running = all.filter(\.running)
    let stopped = all.filter { !$0.running }
    Card {
      CardHeader(title: L("Contêineres"), symbol: "shippingbox", tint: .blue, count: running.count) {
        Text(Set(all.map(\.engine)).sorted().joined(separator: " · ")).font(.caption)
          .foregroundStyle(.secondary)
      }
      if running.isEmpty { ContainerEmptyState(store: store) }
      if !running.isEmpty { ContainerGrid(containers: running) }
      if !stopped.isEmpty {
        Button {
          showStopped.toggle()
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
              .rotationEffect(.degrees(showStopped ? 90 : 0))
            Text(L("%@ parados", "\(stopped.count)"))
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
        if showStopped { ContainerGrid(containers: stopped) }
      }
      Text(
        L("Lido do socket local do Docker Engine (OrbStack, Docker Desktop ou Colima) a cada 5 s enquanto visível. CPU em % de um núcleo; memória sem cache de arquivos, como em docker stats.")
      ).font(.caption).foregroundStyle(.secondary)
    }.watchesContainers()
  }
}

/// A listening-servers row: a host process, or a container whose port the VM helper holds.
enum ServerEntry: Identifiable {
  case process(ProcessItem, instances: Int, ports: [PortInfo])
  case container(ContainerItem, via: ProcessItem, ports: [PortInfo])
  var id: String {
    switch self {
    case .process(let p, _, _): p.id
    case .container(let c, let via, _): "\(via.id)/\(c.id)"
    }
  }
  var ports: [PortInfo] {
    switch self {
    case .process(_, _, let ports), .container(_, _, let ports): ports
    }
  }
}
/// Splits each VM helper's ports among the containers that published them; the rest stays on
/// the helper row. Other servers are unchanged.
func serverEntries(_ groups: [(ProcessItem, Int)], owners: [UInt16: ContainerItem]) -> [ServerEntry] {
  var out: [ServerEntry] = []
  for (p, instances) in groups {
    guard p.tags.contains("container"), !owners.isEmpty else {
      out.append(.process(p, instances: instances, ports: p.ports))
      continue
    }
    let split = splitPorts(p.ports.map(\.port)) { owners[$0]?.id }
    let byPort = Dictionary(p.ports.map { ($0.port, $0) }, uniquingKeysWith: { a, _ in a })
    if !split.rest.isEmpty {
      out.append(.process(p, instances: instances, ports: split.rest.compactMap { byPort[$0] }))
    }
    for (_, ports) in split.owned {
      guard let first = ports.first, let c = owners[first] else { continue }
      out.append(.container(c, via: p, ports: ports.compactMap { byPort[$0] }))
    }
  }
  return out.sorted { ($0.ports.first?.port ?? 0) < ($1.ports.first?.port ?? 0) }
}
/// One listening-servers line for a container: its name, project and an in-place stop.
struct ContainerServerLine: View {
  let container: ContainerItem
  let via: ProcessItem
  let ports: [PortInfo]
  var maxPorts = 2
  var body: some View {
    HStack(spacing: 8) {
      ContainerIcon(container: container, size: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(L("contêiner %@", container.name)).lineLimit(1)
        Text([container.project, container.image, L("via %@", via.name)].compactMap { $0 }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 6)
      HStack(spacing: 3) {
        ForEach(ports.prefix(maxPorts), id: \.port) { port in
          Badge(text: ":\(port.port)", color: port.exposed ? .orange : Tint.netIn)
            .help(port.exposed ? L("Acessível na rede") : L("Somente local"))
        }
        if let port = ports.first?.port { OpenPortButton(port: port) }
        ContainerActionButton(container: container, action: "stop")
      }
    }
    .font(.callout)
    .contentShape(Rectangle())
    .help(L("Porta publicada pelo contêiner %@ (%@); o processo %@ apenas a encaminha.", container.name, container.engine, via.name))
  }
}
