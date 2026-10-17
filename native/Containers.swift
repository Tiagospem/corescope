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
  var image: String
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
  /// Registered views: whether each wants stats, and the window hosting it (weak).
  private var watchers: [UUID: Bool] = [:]
  private var windows: [UUID: WeakWindow] = [:]
  private var timer: Timer?
  private var busy = false
  private var lastRead = Date.distantPast

  func watch(_ token: UUID, stats: Bool) {
    watchers[token] = stats
    kick()
  }
  /// The hosting window is known only once the view is installed, possibly after onAppear.
  func attach(_ token: UUID, window: NSWindow?) {
    windows[token] = WeakWindow(window: window)
    if watchers[token] != nil { kick() }
  }
  func unwatch(_ token: UUID) {
    watchers[token] = nil
    windows[token] = nil
    if watchers.isEmpty {
      timer?.invalidate()
      timer = nil
    }
  }
  /// A surface that just opened gets data now, unless a read happened moments ago.
  /// Re-reads soon after an action elsewhere (profiles) changed container state.
  func refreshSoon() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      self.lastRead = .distantPast
      self.tick()
    }
  }
  private func kick() {
    if Date().timeIntervalSince(lastRead) > 2 { tick() } else if timer == nil { schedule() }
  }
  /// Watchers whose own window is on screen: a minimized or covered window keeps its views
  /// (and their registration) but needs no data, whatever other windows are showing.
  private var visibleWatchers: [Bool] {
    watchers.compactMap { token, stats in
      // Tour captures run unattended, often with the display asleep (window "occluded").
      guard let w = windows[token]?.window, w.isVisible, !w.isMiniaturized,
        w.occlusionState.contains(.visible) || Tour.folder != nil
      else { return nil }
      return stats
    }
  }
  private func tick() {
    timer?.invalidate()
    timer = nil
    guard !busy, !watchers.isEmpty else { return }
    let monitor = Monitor.shared
    let visible = visibleWatchers
    let stats = visible.contains(true)
    // Port labels only matter when a VM helper (OrbStack, Docker Desktop…) is listening.
    let needed =
      stats
      || (!visible.isEmpty
        && monitor.snapshot?.servers.contains { $0.tags.contains("container") } == true)
    guard needed, !monitor.sleeping, !monitor.manuallyPaused else {
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
    guard timer == nil, !watchers.isEmpty else { return }
    let seconds = ProcessInfo.processInfo.isLowPowerModeEnabled ? 10.0 : 5.0
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.timer = nil
      self?.tick()
    }
    timer?.tolerance = 1
  }
  /// A port published by more than one container (other host address or engine) stays on the
  /// helper row: picking one would put the wrong container's Stop button there.
  static func owners(_ containers: [ContainerItem]) -> [UInt16: ContainerItem] {
    let running = containers.filter(\.running)
    let byID = Dictionary(running.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let pairs = running.flatMap { c in c.tcpPorts.map { (port: $0.host, owner: c.id) } }
    return uniqueOwners(pairs).compactMapValues { byID[$0] }
  }
  /// Runs after the user confirmed; the engine allows 10 s for a clean exit before SIGKILL.
  /// `done` gets the error message, or nil when the engine did it.
  func perform(_ container: ContainerItem, action: String, done: ((String?) -> Void)? = nil) {
    let monitor = Monitor.shared
    let stop = action == "stop"
    let start = action == "start"
    monitor.feedback = ActionFeedback(
      message: L(start ? "Iniciando %@…" : stop ? "Parando %@…" : "Reiniciando %@…", container.name), pending: true)
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
            ?? L(start ? "%@ iniciado." : stop ? "%@ parado." : "%@ reiniciado.", container.name),
          failed: error != nil)
        done?(error)
        self.lastRead = .distantPast
        self.tick()
        monitor.refresh()
      }
    }
  }
}

private struct WeakWindow {
  weak var window: NSWindow?
}
/// Reports the window that hosts a view, so polling follows that window's visibility.
private struct WindowReader: NSViewRepresentable {
  let onChange: (NSWindow?) -> Void
  final class Probe: NSView {
    var onChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onChange?(window)
    }
  }
  func makeNSView(context: Context) -> Probe {
    let probe = Probe()
    probe.onChange = onChange
    return probe
  }
  func updateNSView(_ probe: Probe, context: Context) { probe.onChange = onChange }
}
private struct ContainerWatch: ViewModifier {
  let stats: Bool
  @ViewState private var token = UUID()
  func body(content: Content) -> some View {
    content
      .background(WindowReader { [token] window in ContainerStore.shared.attach(token, window: window) })
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
                if let policy = DockerDetailsStore.shared.details.restart[c.id], policy != "no" {
                  Text("· \(policy)").foregroundStyle(.tertiary)
                    .help(L("Política de reinício: o Docker sobe o contêiner de novo sozinho"))
                }
              }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          // Name and image columns absorb the extra width so the table spans the card.
          .frame(maxWidth: .infinity, alignment: .leading)
          .help("\(c.status)\n\(c.id.prefix(12))")
          Text(c.project ?? "—").lineLimit(1).foregroundStyle(c.project == nil ? .secondary : .primary)
            .help(c.service.map { L("Serviço %@", $0) } ?? "")
          if showImage {
            VStack(alignment: .leading, spacing: 1) {
              Text(c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              if let created = DockerDetailsStore.shared.details.images[c.image] {
                Text(L("imagem de %@", Date(timeIntervalSince1970: created).formatted(.relative(presentation: .named))))
                  .font(.caption2).foregroundStyle(.tertiary)
              }
            }.frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).help(c.image)
          }
          ContainerPorts(ports: c.tcpPorts)
          Text(c.running ? c.cpuText : "—").monospacedDigit()
          Text(c.running ? c.memoryText : "—").monospacedDigit()
            .help(c.memory_limit.map { L("Limite %@", formatBytes($0)) } ?? "")
          HStack(spacing: 2) {
            if c.running {
              ContainerActionButton(container: c, action: "restart")
              ContainerActionButton(container: c, action: "stop")
            } else {
              Button {
                ContainerStore.shared.perform(c, action: "start")
              } label: {
                Image(systemName: "play.circle").font(.system(size: 15))
              }.buttonStyle(.borderless).help(L("Iniciar o contêiner %@", c.name))
            }
          }.gridColumnAlignment(.trailing)
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
          .accessibilityLabel(L("Porta %@", "\(p.host)"))
          .accessibilityValue(p.exposed ? L("Acessível na rede") : L("Somente local"))
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
/// Sidebar page dedicated to containers, kept apart from agent sessions.
struct ContainersView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) { ContainersSection() }.padding(20)
    }
  }
}
struct ContainersSection: View {
  @ObservedObject var store = ContainerStore.shared
  @ObservedObject var details = DockerDetailsStore.shared
  @ViewState private var showStopped = false
  var body: some View {
    let all = store.report?.containers ?? []
    let running = all.filter(\.running)
    let groups = Dictionary(grouping: all) { $0.project ?? "" }
    let projects = groups.keys.sorted { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a < b }
    VStack(alignment: .leading, spacing: 16) {
      Card {
        CardHeader(title: L("Contêineres"), symbol: "shippingbox", tint: .blue, count: running.count) {
          Text(Set(all.map(\.engine)).sorted().joined(separator: " · ")).font(.caption)
            .foregroundStyle(.secondary)
          Toggle(L("Mostrar parados"), isOn: $showStopped).toggleStyle(.switch).controlSize(.mini)
        }
        if all.isEmpty { ContainerEmptyState(store: store) }
        // One block per compose project; loose containers last.
        ForEach(projects, id: \.self) { project in
          let list = (groups[project] ?? []).filter { showStopped || $0.running }
          if !list.isEmpty {
            ComposeHeader(project: project, containers: groups[project] ?? [])
            ContainerGrid(containers: list)
          }
        }
        if !showStopped, all.count > running.count {
          Text(L("%@ parados", "\(all.count - running.count)")).font(.caption).foregroundStyle(.secondary)
        }
        Text(
          L("Lido do socket local do Docker Engine (OrbStack, Docker Desktop ou Colima) a cada 5 s enquanto visível. CPU em % de um núcleo; memória sem cache de arquivos, como em docker stats.")
        ).font(.caption).foregroundStyle(.secondary)
      }.watchesContainers()
      VolumesCard(volumes: details.details.volumes)
    }
    .task {
      while !Task.isCancelled {
        details.refresh()
        try? await Task.sleep(nanoseconds: 30_000_000_000)
      }
    }
  }
}

/// A compose project's title row with start-all / stop-all.
private struct ComposeHeader: View {
  let project: String
  let containers: [ContainerItem]
  var body: some View {
    let up = containers.filter(\.running).count
    HStack(spacing: 8) {
      Image(systemName: project.isEmpty ? "square.dashed" : "square.stack.3d.up").foregroundStyle(.secondary)
      Text(project.isEmpty ? L("Sem projeto compose") : project).font(.callout.weight(.semibold))
      Badge(text: L("%@ de %@ rodando", "\(up)", "\(containers.count)"), color: up == containers.count ? Tint.brand : .secondary)
      Spacer()
      if !project.isEmpty {
        if up < containers.count {
          Button(L("Iniciar todos")) {
            for c in containers where !c.running { ContainerStore.shared.perform(c, action: "start") }
          }.controlSize(.small)
        }
        if up > 0 {
          ArmedButton(symbol: "stop.circle", confirm: L("Parar todos"), help: L("Parar os contêineres de %@", project), tint: Tint.danger) {
            for c in containers where c.running { ContainerStore.shared.perform(c, action: "stop") }
          }
        }
      }
    }.padding(.top, 6)
  }
}

/// Named volumes with size and use; unused ones flagged (removing them deletes data, so CoreScope
/// only shows them).
private struct VolumesCard: View {
  let volumes: [VolumeInfo]
  @ViewState private var showAll = false
  var body: some View {
    if !volumes.isEmpty {
      let unused = volumes.filter { $0.containers == 0 }
      Card {
        CardHeader(title: L("Volumes"), symbol: "externaldrive.connected.to.line.below", count: volumes.count) {
          Text(diskBytes(Double(volumes.compactMap(\.size).reduce(0, +)))).font(.caption).foregroundStyle(.secondary)
        }
        if !unused.isEmpty {
          Text(
            L("%@ sem nenhum contêiner (%@). Remover um volume apaga os dados dele; faça pelo Docker se tiver certeza.",
              "\(unused.count)", diskBytes(Double(unused.compactMap(\.size).reduce(0, +))))
          ).font(.caption).foregroundStyle(.orange)
        }
        ForEach(Array((showAll ? volumes : Array(volumes.prefix(8))).enumerated()), id: \.offset) { _, v in
          HStack(spacing: 8) {
            Image(systemName: "cylinder").foregroundStyle(.secondary).frame(width: 16)
            Text(v.name).font(.callout).lineLimit(1).truncationMode(.middle).help(v.name)
            if let project = v.project { Badge(text: project, color: .secondary) }
            Spacer()
            Text(v.containers == 0 ? L("sem uso") : v.containers > 0 ? L("%@ contêiner(es)", "\(v.containers)") : "")
              .font(.caption).foregroundStyle(v.containers == 0 ? .orange : .secondary)
            Text(v.size.map { diskBytes(Double($0)) } ?? "—").font(.callout).monospacedDigit().frame(width: 80, alignment: .trailing)
          }
        }
        if volumes.count > 8 {
          Button(showAll ? L("Mostrar menos") : L("Mostrar todos (%@)", "\(volumes.count)")) { showAll.toggle() }
            .buttonStyle(.link).font(.caption)
        }
      }
    }
  }
}

struct VolumeInfo: Decodable, Hashable {
  let name: String
  let engine: String
  let size: Int64?
  let containers: Int
  let project: String?
}
struct DockerDetails: Decodable {
  var volumes: [VolumeInfo] = []
  var restart: [String: String] = [:]
  var images: [String: Double] = [:]
}
/// Volumes, restart policies and image dates: slower reads, every 30 s while Containers is open.
final class DockerDetailsStore: ObservableObject {
  static let shared = DockerDetailsStore()
  @Published private(set) var details = DockerDetails()
  private let queue = DispatchQueue(label: "app.corescope.dockerdetails", qos: .utility)
  private var busy = false
  func refresh() {
    guard !busy else { return }
    busy = true
    queue.async {
      var next: DockerDetails?
      if let pointer = cs_docker_details() {
        let data = Data(bytes: pointer, count: strlen(pointer))
        cs_free(pointer)
        next = try? JSONDecoder().decode(DockerDetails.self, from: data)
      }
      DispatchQueue.main.async {
        self.busy = false
        if let next { self.details = next }
      }
    }
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
        ForEach(ports.prefix(maxPorts), id: \.port) { port in PortBadge(port: port) }
        if let port = ports.first?.port { OpenPortButton(port: port) }
        ContainerActionButton(container: container, action: "stop")
      }
    }
    .font(.callout)
    .contentShape(Rectangle())
    .help(L("Porta publicada pelo contêiner %@ (%@); o processo %@ apenas a encaminha.", container.name, container.engine, via.name))
  }
}
