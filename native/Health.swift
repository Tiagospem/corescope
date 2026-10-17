import AppKit
import Network
import SwiftUI

/// A URL or port the user wants watched.
struct HealthCheck: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var target: String
  /// The `.corescope.yml` defining it; nil for checks added in the app.
  var source: String? = nil
}
struct HealthResult: Equatable {
  let level: HealthLevel
  /// "200", "connection refused", "timed out"…
  let detail: String
  /// Milliseconds; nil when there was no answer.
  let latency: Double?
  let at: Date
}

/// Probes the user's checks every 30 s while the app runs: an HTTP GET (no cookies, no cache)
/// or a TCP connect. Only the targets the user added are contacted.
final class HealthStore: ObservableObject {
  static let shared = HealthStore()
  @Published var checks: [HealthCheck] {
    didSet {
      if let data = try? JSONEncoder().encode(checks) { UserDefaults.standard.set(data, forKey: "healthChecks") }
      pruneAndSchedule()
    }
  }
  /// Checks from project files (`services:`), rebuilt when the files change.
  @Published private(set) var fileChecks: [HealthCheck] = []
  var allChecks: [HealthCheck] { checks + fileChecks }
  func reloadFileChecks() {
    var out: [HealthCheck] = []
    for file in ProjectFileStore.shared.files {
      for s in file.config?.services ?? [] {
        let label = s.name ?? HealthTarget(s.target)?.label ?? s.target
        out.append(
          HealthCheck(
            id: stableID("\(file.file)#service#\(s.target)"), name: "\(file.project) · \(label)", target: s.target,
            source: file.file))
      }
    }
    guard out != fileChecks else { return }
    fileChecks = out
    pruneAndSchedule()
  }
  private func pruneAndSchedule() {
    let ids = Set(allChecks.map(\.id))
    results = results.filter { ids.contains($0.key) }
    schedule()
  }
  @Published private(set) var results: [UUID: HealthResult] = [:]
  /// A week of 5-minute buckets per check, kept on disk (counts and latency only).
  @Published private(set) var buckets: [UUID: [Int: HealthBucket]] = [:]
  private var lastSave = Date.distantPast
  private static let historyFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CoreScope/services-history.json")
  /// Recent latencies per check (nil = failed), oldest first.
  @Published private(set) var history: [UUID: [Double?]] = [:]
  private var failures: [UUID: Int] = [:]
  private var alerted = Set<UUID>()
  private var timer: Timer?
  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.urlCache = nil
    return URLSession(configuration: config)
  }()

  private init() {
    let data = UserDefaults.standard.data(forKey: "healthChecks")
    checks = data.flatMap { try? JSONDecoder().decode([HealthCheck].self, from: $0) } ?? []
    if let saved = try? Data(contentsOf: Self.historyFile),
      let decoded = try? JSONDecoder().decode([UUID: [Int: HealthBucket]].self, from: saved)
    {
      buckets = decoded
    }
    schedule()
  }
  var worst: HealthLevel? { allChecks.compactMap { results[$0.id]?.level }.max() }

  private func schedule() {
    timer?.invalidate()
    timer = nil
    guard !allChecks.isEmpty else { return }
    runAll()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.runAll() }
    timer?.tolerance = 5
  }
  func runAll() {
    for check in allChecks { run(check) }
  }
  func run(_ check: HealthCheck) {
    guard let target = HealthTarget(check.target) else {
      record(check, HealthResult(level: .down, detail: L("Destino inválido"), latency: nil, at: Date()))
      return
    }
    let started = Date()
    let finish: (HealthLevel, String, Bool) -> Void = { [weak self] level, detail, answered in
      let latency = answered ? Date().timeIntervalSince(started) * 1000 : nil
      DispatchQueue.main.async {
        self?.record(check, HealthResult(level: level, detail: detail, latency: latency, at: Date()))
      }
    }
    switch target {
    case .http(let url):
      var request = URLRequest(url: url)
      request.setValue("CoreScope health check", forHTTPHeaderField: "User-Agent")
      session.dataTask(with: request) { _, response, error in
        if let http = response as? HTTPURLResponse {
          finish(HealthLevel(httpStatus: http.statusCode), "HTTP \(http.statusCode)", true)
        } else {
          finish(.down, Self.describe(error), false)
        }
      }.resume()
    case .tcp(let host, let port):
      Self.connect(host: host, port: port) { error in
        error == nil ? finish(.up, L("porta aberta"), true) : finish(.down, error ?? "", false)
      }
    }
  }

  private func record(_ check: HealthCheck, _ result: HealthResult) {
    guard allChecks.contains(where: { $0.id == check.id }) else { return }
    results[check.id] = result
    var recent = history[check.id] ?? []
    recent.append(result.level == .down ? nil : result.latency)
    history[check.id] = Array(recent.suffix(40))
    HealthHistory.record(&buckets[check.id, default: [:]], at: result.at, up: result.level != .down, latency: result.latency)
    if Date().timeIntervalSince(lastSave) > 120 { saveHistory() }
    // Two failures in a row before alerting, so one slow answer does not page anyone.
    failures[check.id] = result.level == .down ? (failures[check.id] ?? 0) + 1 : 0
    guard Preferences.shared.notifyServiceDown else { return }
    if failures[check.id] == 2, !alerted.contains(check.id) {
      alerted.insert(check.id)
      Notifier.shared.serviceChanged(
        key: check.id.uuidString, title: L("%@ fora do ar", check.name), body: "\(check.target) · \(result.detail)")
    } else if result.level != .down, alerted.remove(check.id) != nil {
      Notifier.shared.serviceChanged(
        key: check.id.uuidString, title: L("%@ voltou", check.name), body: "\(check.target) · \(result.detail)")
    }
  }

  /// Written at most every 2 minutes; checks that no longer exist are dropped.
  func saveHistory() {
    lastSave = Date()
    let ids = Set(allChecks.map(\.id))
    let snapshot = buckets.filter { ids.contains($0.key) }
    DispatchQueue.global(qos: .utility).async {
      try? FileManager.default.createDirectory(
        at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: Self.historyFile, options: .atomic) }
    }
  }
  func uptime(_ id: UUID, hours: Double) -> Double? {
    HealthHistory.uptime(buckets[id] ?? [:], now: Date(), seconds: hours * 3600)
  }
  func incidents(_ id: UUID) -> [(start: Date, end: Date)] { HealthHistory.incidents(buckets[id] ?? [:]) }

  private static func describe(_ error: Error?) -> String {
    guard let error = error as? URLError else { return L("sem resposta") }
    switch error.code {
    case .timedOut: return L("sem resposta em 5 s")
    case .cannotConnectToHost: return L("conexão recusada")
    case .cannotFindHost, .dnsLookupFailed: return L("host não encontrado")
    case .notConnectedToInternet: return L("sem rede")
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
      return L("certificado TLS inválido")
    default: return error.localizedDescription
    }
  }
  /// Connects and closes; nil on success, else a short reason. Gives up after 3 s.
  private static func connect(host: String, port: UInt16, done: @escaping (String?) -> Void) {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return done(L("porta inválida")) }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
    let queue = DispatchQueue(label: "app.corescope.health.tcp")
    var finished = false
    let complete: (String?) -> Void = { reason in
      queue.async {
        guard !finished else { return }
        finished = true
        connection.cancel()
        done(reason)
      }
    }
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: complete(nil)
      case .failed(let error), .waiting(let error):
        if case .posix(let code) = error, code == .ECONNREFUSED {
          complete(L("conexão recusada"))
        } else {
          complete(error.localizedDescription)
        }
      default: break
      }
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 3) { complete(L("sem resposta em 3 s")) }
  }
}

extension HealthLevel {
  var color: Color {
    switch self {
    case .up: Tint.brand
    case .warn: .orange
    case .down: .red
    }
  }
  var label: String {
    switch self {
    case .up: L("No ar")
    case .warn: L("Respondeu com erro")
    case .down: L("Fora do ar")
    }
  }
}

struct HealthView: View {
  @ObservedObject var store = HealthStore.shared
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var name = ""
  @ViewState private var target = ""
  @ViewState private var editing: UUID?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Card {
          CardHeader(title: L("Adicionar serviço"), symbol: "plus.circle")
          HStack(spacing: 8) {
            TextField(L("Nome"), text: $name).textFieldStyle(.roundedBorder).frame(width: 160)
            TextField(L("URL ou porta: 3000, localhost:5432, https://…/health"), text: $target)
              .textFieldStyle(.roundedBorder).onSubmit(add)
            Button(editing == nil ? L("Adicionar") : L("Salvar"), action: add)
              .disabled(HealthTarget(target) == nil)
            if editing != nil {
              Button(L("Cancelar")) { reset() }
            }
          }
          if let parsed = HealthTarget(target), !parsed.isLocal {
            Label(L("Destino fora deste Mac: o CoreScope vai acessar %@ a cada 30 s.", parsed.label), systemImage: "network")
              .font(.caption).foregroundStyle(.orange)
          }
          if !suggestions.isEmpty {
            HStack(spacing: 6) {
              Text(L("Portas abertas agora:")).font(.caption).foregroundStyle(.secondary)
              ForEach(suggestions.prefix(6), id: \.port) { s in
                Button(":\(s.port) \(s.name)") {
                  store.checks.append(HealthCheck(name: s.name, target: "localhost:\(s.port)"))
                }.controlSize(.small)
              }
            }
          }
        }
        if store.allChecks.isEmpty {
          Card {
            EmptyNote(text: L("Nenhum serviço monitorado. Adicione uma URL de health check ou uma porta (API local, banco, staging)."))
          }
        } else {
          Card {
            CardHeader(title: L("Serviços"), symbol: "heart.text.square", tint: store.worst?.color ?? .secondary, count: store.allChecks.count) {
              Button {
                store.runAll()
              } label: {
                Label(L("Verificar agora"), systemImage: "arrow.clockwise")
              }.controlSize(.small)
            }
            ForEach(store.allChecks) { check in
              HealthRow(check: check, result: store.results[check.id], history: store.history[check.id] ?? []) {
                editing = check.id
                name = check.name
                target = check.target
              } remove: {
                store.checks.removeAll { $0.id == check.id }
              }
              if check.id != store.allChecks.last?.id { Divider() }
            }
          }
        }
        Toggle(L("Notificar quando um serviço cair ou voltar"), isOn: $prefs.notifyServiceDown)
          .onChange(of: prefs.notifyServiceDown) { _, on in if on { Notifier.shared.activate() } }
        Text(
          L("Verifica a cada 30 s enquanto o CoreScope está aberto: HTTP GET (2xx/3xx no ar, 4xx respondeu com erro, 5xx ou sem resposta fora do ar) ou conexão TCP na porta. Sem cookies nem cache; só os destinos que você adicionou são acessados. Alerta depois de duas falhas seguidas.")
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
  }
  /// The user's own listening ports that are not watched yet.
  private var suggestions: [(port: UInt16, name: String)] {
    guard let s = monitor.snapshot else { return [] }
    let watched = Set(store.allChecks.compactMap { check -> UInt16? in
      if case .tcp(_, let port) = HealthTarget(check.target) { return port }
      if case .http(let url) = HealthTarget(check.target) { return url.port.map(UInt16.init) }
      return nil
    })
    var seen = Set<UInt16>()
    return s.processes.filter { $0.uid == s.current_uid }.flatMap { p in p.ports.map { (port: $0.port, name: p.project ?? p.name) } }
      .filter { !watched.contains($0.port) && seen.insert($0.port).inserted }
      .sorted { $0.port < $1.port }
  }
  private func add() {
    guard HealthTarget(target) != nil else { return }
    let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? HealthTarget(target)?.label ?? target : name
    if let id = editing, let i = store.checks.firstIndex(where: { $0.id == id }) {
      store.checks[i].name = label
      store.checks[i].target = target
    } else {
      store.checks.append(HealthCheck(name: label, target: target))
    }
    reset()
  }
  private func reset() {
    editing = nil
    name = ""
    target = ""
  }
}

private struct HealthRow: View {
  let check: HealthCheck
  let result: HealthResult?
  let history: [Double?]
  let edit: () -> Void
  let remove: () -> Void
  @ViewState private var showHistory = false
  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(result?.level.color ?? .secondary).frame(width: 9, height: 9)
        .help(result?.level.label ?? L("Verificando…"))
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(check.name).font(.callout.weight(.medium)).lineLimit(1)
          if check.source != nil { Badge(text: ".corescope.yml", color: Tint.netIn, symbol: "doc.text") }
        }
        Text(check.target).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      LatencyStrip(values: history).frame(width: 120, height: 18)
      Button {
        showHistory = true
      } label: {
        VStack(alignment: .trailing, spacing: 1) {
          Text(HealthStore.shared.uptime(check.id, hours: 24).map { String(format: "%.1f%%", $0 * 100) } ?? "—")
            .font(.callout).monospacedDigit()
          Text(L("24 h")).font(.caption2).foregroundStyle(.secondary)
        }
      }.buttonStyle(.plain).help(L("Disponibilidade e incidentes"))
      VStack(alignment: .trailing, spacing: 2) {
        Text(result?.latency.map { String(format: "%.0f ms", $0) } ?? "—").font(.callout).monospacedDigit()
        Text(result.map { "\($0.detail) · \($0.at.formatted(date: .omitted, time: .standard))" } ?? L("Verificando…"))
          .font(.caption).foregroundStyle(result?.level == .up ? Color.secondary : result?.level.color ?? .secondary)
          .lineLimit(1)
      }.frame(width: 190, alignment: .trailing)
      if case .http(let url) = HealthTarget(check.target) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Image(systemName: "safari")
        }.buttonStyle(.borderless).help(L("Abrir no navegador"))
      }
      Menu {
        if let source = check.source {
          Button(L("Abrir .corescope.yml")) { NSWorkspace.shared.open(URL(fileURLWithPath: source)) }
        } else {
          Button(L("Editar"), action: edit)
          Button(L("Remover"), role: .destructive, action: remove)
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }.padding(.vertical, 3)
    .sheet(isPresented: $showHistory) { ServiceHistorySheet(check: check) }
  }
}

/// One bar per recent check: height = latency, red stub = failure.
private struct LatencyStrip: View {
  let values: [Double?]
  var body: some View {
    GeometryReader { g in
      let ceiling = max(values.compactMap { $0 }.max() ?? 1, 1)
      let width = g.size.width / 40
      HStack(alignment: .bottom, spacing: 1) {
        Spacer(minLength: 0)
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
          RoundedRectangle(cornerRadius: 1)
            .fill(value == nil ? Color.red : Tint.brand.opacity(0.7))
            .frame(width: max(1, width - 1), height: value.map { max(2, g.size.height * $0 / ceiling) } ?? g.size.height)
        }
      }
    }.accessibilityHidden(true)
  }
}

/// Overview summary, shown only once a check exists.
struct HealthCard: View {
  @ObservedObject var store = HealthStore.shared
  var body: some View {
    if !store.allChecks.isEmpty {
      Card {
        CardHeader(title: L("Serviços"), symbol: "heart.text.square", tint: store.worst?.color ?? .secondary, count: store.allChecks.count) {
          Button(L("Ver todos")) { navigate(.health) }.buttonStyle(.link).font(.caption)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
          ForEach(store.allChecks) { check in
            let result = store.results[check.id]
            HStack(spacing: 7) {
              Circle().fill(result?.level.color ?? .secondary).frame(width: 8, height: 8)
              Text(check.name).font(.callout).lineLimit(1)
              Spacer(minLength: 4)
              Text(result?.level == .down ? result?.detail ?? "" : result?.latency.map { String(format: "%.0f ms", $0) } ?? "—")
                .font(.caption).foregroundStyle(result?.level == .down ? Color.red : .secondary).monospacedDigit().lineLimit(1)
            }.help("\(check.target) · \(result?.level.label ?? L("Verificando…"))")
          }
        }
      }
    }
  }
}

/// A week of one check: uptime, incidents and today's latency.
private struct ServiceHistorySheet: View {
  let check: HealthCheck
  @ObservedObject var store = HealthStore.shared
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    let buckets = store.buckets[check.id] ?? [:]
    let today = (0..<288).map { i -> Double? in
      buckets[HealthHistory.bucket(Date()) - 287 + i].flatMap { $0.down > $0.up ? nil : $0.latency }
    }
    let incidents = store.incidents(check.id)
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(check.name).font(.title3.weight(.semibold))
        Spacer()
        Button(L("Fechar")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack(spacing: 24) {
        figure(L("24 h"), store.uptime(check.id, hours: 24))
        figure(L("7 dias"), store.uptime(check.id, hours: 168))
        VStack(alignment: .leading, spacing: 2) {
          Text("\(incidents.count)").font(.system(size: 22, weight: .semibold, design: .rounded))
          Text(L("incidentes na semana")).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(L("Latência nas últimas 24 h")).font(.caption.weight(.semibold))
      LatencyStrip(values: today.map { $0 ?? 0 }).frame(height: 60)
      Text(L("Incidentes")).font(.caption.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          if incidents.isEmpty { EmptyNote(text: L("Nenhum incidente registrado.")) }
          ForEach(Array(incidents.prefix(50).enumerated()), id: \.offset) { _, i in
            HStack {
              Circle().fill(Color.red).frame(width: 6, height: 6)
              Text(i.start.formatted(date: .abbreviated, time: .shortened))
              Text("→ \(i.end.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
              Spacer()
              Text(formatDuration(i.end.timeIntervalSince(i.start))).foregroundStyle(.secondary)
            }.font(.callout)
          }
        }
      }
      Text(L("Guardado em blocos de 5 minutos por 7 dias (contagens e latência, nada mais).")).font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(width: 560, height: 520)
  }
  private func figure(_ label: String, _ value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.map { String(format: "%.2f%%", $0 * 100) } ?? "—").font(.system(size: 22, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}
