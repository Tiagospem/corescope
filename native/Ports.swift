import AppKit
import SwiftUI

struct ExposureItem: Decodable, Hashable {
  let port: Int
  let owner: String
  let pid: Int32?
  let container: String?
  let project: String?
  let kind: String
  let risk: String
  let advice: String
}
struct PortClaimItem: Decodable, Hashable {
  let project: String
  let folder: String
  let role: String
  let port: Int
  let state: String
  let held_by: String?
  let held_by_project: String?
  let suggestion: Int?
}

/// Exposure and preferred ports, read while the Ports page is open (every 15 s).
final class PortsStore: ObservableObject {
  static let shared = PortsStore()
  @Published private(set) var exposed: [ExposureItem] = []
  @Published private(set) var claims: [PortClaimItem] = []
  private let queue = DispatchQueue(label: "app.corescope.ports", qos: .utility)
  private var busy = false

  func refresh() {
    guard !busy else { return }
    busy = true
    let projects = ProjectFileStore.shared.files.compactMap { f -> [String: Any]? in
      guard let ports = f.config?.ports, !ports.isEmpty else { return nil }
      return ["name": f.project, "folder": f.folder, "ports": ports]
    }
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("ports", cost) }
      func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?) -> T? {
        guard let pointer else { return nil }
        defer { cs_free(pointer) }
        return try? JSONDecoder().decode(T.self, from: Data(bytes: pointer, count: strlen(pointer)))
      }
      let exposed: [ExposureItem] = decode(cs_exposure()) ?? []
      var claims: [PortClaimItem] = []
      if !projects.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["projects": projects]),
        let request = String(data: data, encoding: .utf8)
      {
        claims = request.withCString { decode(cs_port_claims($0)) } ?? []
      }
      DispatchQueue.main.async {
        self.busy = false
        if exposed != self.exposed { self.exposed = exposed }
        if claims != self.claims { self.claims = claims }
      }
    }
  }
}

struct PortsView: View {
  @ObservedObject var store = PortsStore.shared
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var from = "3000"
  @ViewState private var free: Int?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        exposureCard
        claimsCard
        listeningCard
      }.padding(20)
    }
    .watchesContainers(stats: false)
    .task {
      while !Task.isCancelled {
        store.refresh()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
      }
    }
  }

  private var exposureCard: some View {
    Card {
      CardHeader(
        title: L("Acessível pela rede"), symbol: "network.badge.shield.half.filled",
        tint: store.exposed.contains { $0.risk == "high" } ? .red : store.exposed.isEmpty ? Tint.brand : .orange,
        count: store.exposed.count)
      if store.exposed.isEmpty {
        EmptyNote(text: L("Nada seu escuta além do localhost."))
      }
      ForEach(store.exposed, id: \.self) { e in
        HStack(alignment: .top, spacing: 10) {
          Badge(text: L(e.risk == "high" ? "alto" : e.risk == "medium" ? "médio" : "baixo"),
                color: e.risk == "high" ? .red : e.risk == "medium" ? .orange : .secondary)
            .frame(width: 54, alignment: .leading)
          Text(":\(e.port)").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 64, alignment: .leading)
          VStack(alignment: .leading, spacing: 2) {
            Text([e.owner, e.project].compactMap { $0 }.joined(separator: " · ")).font(.callout).lineLimit(1)
            Text(e.advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 4)
          if let pid = e.pid, let p = monitor.snapshot?.process(pid: pid) { KillButton(process: p) }
        }
      }
      Text(
        L("Portas abertas em todas as interfaces (0.0.0.0) podem ser acessadas por outros na mesma rede: café, coworking, escritório. Bancos e caches costumam vir sem senha em desenvolvimento.")
      ).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var claimsCard: some View {
    Card {
      CardHeader(title: L("Portas preferidas dos projetos"), symbol: "number", count: store.claims.count) {
        HStack(spacing: 6) {
          TextField("3000", text: $from).textFieldStyle(.roundedBorder).frame(width: 64).onSubmit(findFree)
          Button(L("Achar porta livre"), action: findFree).controlSize(.small)
          if let free {
            Button(":\(free)") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString("\(free)", forType: .string)
            }.controlSize(.small).help(L("Copiar"))
          }
        }
      }
      if store.claims.isEmpty {
        EmptyNote(text: L("Nenhum .corescope.yml com `ports:`. Declare as portas do projeto (web: 8000, vite: 5173) para ver conflitos aqui."))
      }
      ForEach(store.claims, id: \.self) { c in
        HStack(spacing: 10) {
          Circle().fill(c.state == "taken" ? Color.orange : c.state == "ours" ? Tint.brand : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
          Text(c.project).font(.callout.weight(.medium)).frame(width: 150, alignment: .leading).lineLimit(1)
          Text(c.role).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
          Text(":\(c.port)").font(.callout).monospacedDigit().frame(width: 60, alignment: .leading)
          Text(
            c.state == "free" ? L("livre") : c.state == "ours" ? L("em uso pelo projeto") : L("ocupada por %@", c.held_by ?? "?")
          ).font(.caption).foregroundStyle(c.state == "taken" ? .orange : .secondary).lineLimit(1)
          Spacer()
          if let s = c.suggestion { Badge(text: L("livre: :%@", "\(s)"), color: Tint.brand) }
        }
      }
    }
  }
  private func findFree() {
    let start = UInt16(from) ?? 3000
    DispatchQueue.global(qos: .userInitiated).async {
      let port = (start...UInt16.max).first { p in
        !(Monitor.shared.snapshot?.processes.contains { $0.ports.contains { $0.port == p } } ?? false) && Self.bindable(p)
      }
      DispatchQueue.main.async { free = port.map(Int.init) }
    }
  }
  private static func bindable(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
  }

  private var listeningCard: some View {
    let servers = monitor.snapshot?.serverGroups ?? []
    let owners = ContainerStore.shared.owners
    let entries = serverEntries(servers, owners: owners)
    return Card {
      CardHeader(title: L("Servidores em escuta"), symbol: "network", tint: Tint.netIn, count: entries.count)
      ForEach(entries) { entry in
        switch entry {
        case .container(let c, let via, let ports):
          ContainerServerLine(container: c, via: via, ports: ports)
        case .process(let p, _, let ports):
          ProcessLine(process: p, subtitle: devSubtitle(p)) {
            HStack(spacing: 3) {
              ForEach(ports.prefix(4), id: \.port) { port in PortBadge(port: port) }
              if let port = ports.first?.port { OpenPortButton(port: port) }
              KillButton(process: p)
            }
          }
        }
      }
    }
  }
}
