import AppKit
import SwiftUI

/// Something the core found that can be cleaned: a folder (moved to the Trash) or unused Docker
/// data (removed by the engine).
struct DevSpaceItem: Codable, Identifiable, Equatable {
  let id: String
  let kind: String
  let group: String
  let name: String
  let path: String
  let bytes: Double
  let modified: Double
  var busy: String?
  let engine: String?
  /// A worktree's agent, branch and merged state.
  var detail: String? = nil
  /// A worktree's main repository.
  var repo: String? = nil
  var isDocker: Bool { engine != nil }
  var modifiedDate: Date? { modified > 0 ? Date(timeIntervalSince1970: modified) : nil }
  var title: String {
    switch kind {
    case "docker_dangling", "docker_unused", "docker_build_cache", "simulator_caches":
      return isDocker ? "\(name) · \(L(kindLabel))" : L(kindLabel)
    default: return name
    }
  }
  var kindLabel: String {
    switch kind {
    case "node_modules": "node_modules"
    case "rust_target": "target/ do Rust"
    case "worktree": "worktree"
    case "derived_data": "DerivedData"
    case "device_support": "Suporte a dispositivo"
    case "simulator_caches": "Caches do Simulador"
    case "docker_dangling": "Imagens órfãs (sem tag)"
    case "docker_unused": "Imagens sem contêiner"
    case "docker_build_cache": "Cache de build"
    default: "Cache"
    }
  }
  var symbol: String {
    switch kind {
    case "node_modules": "shippingbox"
    case "rust_target": "gearshape.2"
    case "worktree": "arrow.triangle.branch"
    case "derived_data", "device_support", "simulator_caches": "hammer"
    case "docker_dangling", "docker_unused", "docker_build_cache": "cube.transparent"
    default: "archivebox"
    }
  }
}
struct DevSpaceReport: Codable {
  var items: [DevSpaceItem]
  let roots: [String]
  let seconds: Double
  let docker_error: String?
}

/// Picks the singular key for one, the plural (count as its first `%@`) otherwise.
func plural(_ n: Int, _ one: String, _ many: String, _ more: String...) -> String {
  n == 1 ? L(one, more) : L(many, ["\(n)"] + more)
}

func diskBytes(_ value: Double) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file)
}

final class CleanupStore: ObservableObject {
  static let shared = CleanupStore()
  @Published private(set) var report: DevSpaceReport?
  @Published private(set) var scanning = false
  @Published private(set) var working = false
  @Published private(set) var scannedAt: Date?
  @Published private(set) var error: String?
  @Published var selection = Set<String>()
  private let queue = DispatchQueue(label: "app.corescope.cleanup", qos: .userInitiated)

  /// Folders the user had added when the cached result was produced.
  @Published private(set) var scannedRoots: [String] = []
  var selected: [DevSpaceItem] { (report?.items ?? []).filter { selection.contains($0.id) && $0.busy == nil } }

  /// The last result is kept on disk (paths, sizes and dates only) so opening the page never
  /// walks the disk by itself; scanning happens only when the user asks.
  private struct Cache: Codable {
    let report: DevSpaceReport
    let scannedAt: Date
    let roots: [String]
  }
  private static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CoreScope/cleanup-cache.json")
  private init() {
    guard let data = try? Data(contentsOf: Self.cacheURL),
      let cache = try? JSONDecoder().decode(Cache.self, from: data)
    else { return }
    report = cache.report
    scannedAt = cache.scannedAt
    scannedRoots = cache.roots
  }
  private func saveCache() {
    guard let report, let scannedAt else { return }
    let cache = Cache(report: report, scannedAt: scannedAt, roots: scannedRoots)
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("cleanup", cost) }
      try? FileManager.default.createDirectory(
        at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }
  }
  /// Why the cached result may no longer match the disk, if it may not.
  func staleness(roots: [String], now: Date = Date()) -> String? {
    guard let scannedAt else { return nil }
    if Set(roots) != Set(scannedRoots) { return L("As pastas mudaram desde a última análise.") }
    guard now.timeIntervalSince(scannedAt) > 6 * 3600 else { return nil }
    return L("Resultado de %@: pode estar desatualizado. Analise de novo para ver o estado atual.",
      scannedAt.formatted(.relative(presentation: .named)))
  }

  /// `done` gets an error message, or nil once the new result is in.
  func scan(done: ((String?) -> Void)? = nil) {
    guard !scanning, !working else {
      done?(L("Uma análise ou limpeza já está em andamento"))
      return
    }
    scanning = true
    let roots = Preferences.shared.cleanupRoots
    let request: [String: Any] = ["roots": roots, "auto": true, "docker": true]
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("cleanup", cost) }
      let result: Result<DevSpaceReport, Error> = Result {
        let data = try Self.call(request)
        return try JSONDecoder().decode(DevSpaceReport.self, from: data)
      }
      DispatchQueue.main.async {
        self.scanning = false
        switch result {
        case .success(let report):
          self.report = report
          self.error = nil
          self.scannedAt = Date()
          self.scannedRoots = roots
          self.saveCache()
          let ids = Set(report.items.filter { $0.busy == nil }.map(\.id))
          self.selection.formIntersection(ids)
          done?(nil)
        case .failure(let error):
          self.error = error.localizedDescription
          done?(error.localizedDescription)
        }
      }
    }
  }

  /// Runs after the user confirmed. Folders are re-checked by the core (still a real folder of a
  /// known kind, nothing using it) right before going to the Trash.
  /// `done` gets the summary shown to the user and the ids that were cleaned.
  func clean(_ items: [DevSpaceItem], done: ((String, Set<String>) -> Void)? = nil) {
    guard !working, !items.isEmpty else {
      done?(L("Uma análise ou limpeza já está em andamento"), [])
      return
    }
    working = true
    let monitor = Monitor.shared
    monitor.feedback = ActionFeedback(message: plural(items.count, "Limpando 1 item…", "Limpando %@ itens…"), pending: true)
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("cleanup", cost) }
      var finished = Set<String>()
      var freed = 0.0
      var failures: [String] = []
      var locked: [String: String] = [:]
      for item in items {
        if let engine = item.engine {
          let result = engine.withCString { socket in item.kind.withCString { cs_dev_space_docker(socket, $0) } }
          switch Self.decode(result) {
          case .success(let obj):
            finished.insert(item.id)
            // Some engines report 0 for images whose layers they count elsewhere: use the measured size.
            let reclaimed = (obj["reclaimed"] as? NSNumber)?.doubleValue ?? 0
            freed += reclaimed > 0 ? reclaimed : item.bytes
          case .failure(let error): failures.append("\(item.title): \(error)")
          }
          continue
        }
        if case .failure(let error) = Self.decode(item.path.withCString { cs_dev_space_verify($0) }) {
          failures.append("\(item.title): \(error)")
          if let user = error.user { locked[item.id] = user }
          continue
        }
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
          finished.insert(item.id)
          freed += item.bytes
          // The folder is in the Trash; drop git's record of it (the branch stays).
          if item.kind == "worktree", let repo = item.repo { Self.prune(repo) }
        } catch {
          failures.append("\(item.title): \(error.localizedDescription)")
        }
      }
      DispatchQueue.main.async {
        self.working = false
        self.report?.items.removeAll { finished.contains($0.id) }
        for (id, user) in locked {
          if let i = self.report?.items.firstIndex(where: { $0.id == id }) { self.report?.items[i].busy = user }
        }
        self.selection.subtract(finished)
        self.selection.subtract(locked.keys)
        self.saveCache()
        var parts: [String] = []
        if !finished.isEmpty {
          parts.append(
            finished.count == 1
              ? L("%@ liberados em 1 item.", diskBytes(freed)) : L("%@ liberados em %@ itens.", diskBytes(freed), "\(finished.count)"))
        }
        if let first = failures.first {
          parts.append(failures.count == 1 ? L("Não foi possível limpar %@", first) : L("%@ falharam: %@", "\(failures.count)", first))
        }
        let message = parts.joined(separator: " ")
        done?(message, finished)
        monitor.feedback = ActionFeedback(message: message, failed: !failures.isEmpty)
      }
    }
  }

  private static func prune(_ repo: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo, "worktree", "prune"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
  }
  private static func call(_ request: [String: Any]) throws -> Data {
    let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8) ?? "{}"
    guard let pointer = json.withCString({ cs_dev_space($0) }) else {
      throw NSError(domain: "CoreScope", code: 1, userInfo: [NSLocalizedDescriptionKey: L("O núcleo não retornou dados")])
    }
    defer { cs_free(pointer) }
    let data = Data(bytes: pointer, count: strlen(pointer))
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = obj["error"] as? String {
      throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: translate(error)])
    }
    return data
  }
  private static func decode(_ pointer: UnsafeMutablePointer<CChar>?) -> Result<[String: Any], CleanupError> {
    guard let pointer else { return .failure(CleanupError(L("falha interna"))) }
    defer { cs_free(pointer) }
    let data = Data(bytes: pointer, count: strlen(pointer))
    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    if let error = obj["error"] as? String {
      let prefix = "Em uso por "
      return .failure(
        CleanupError(translate(error), user: error.hasPrefix(prefix) ? String(error.dropFirst(prefix.count)) : nil))
    }
    return .success(obj)
  }
  /// Core messages are Portuguese keys; "Em uso por …" and engine refusals carry a dynamic tail.
  static func translate(_ error: String) -> String {
    for prefix in ["Em uso por", "O motor recusou a ação"] where error.hasPrefix(prefix) {
      return L(prefix) + error.dropFirst(prefix.count)
    }
    return L(error)
  }
}
struct CleanupError: Error, CustomStringConvertible {
  let description: String
  /// The process named by an "in use" refusal.
  var user: String?
  init(_ description: String, user: String? = nil) {
    self.description = description
    self.user = user
  }
}

struct CleanupView: View {
  @ObservedObject var store = CleanupStore.shared
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var confirm = false
  private static let groups: [(id: String, title: String, symbol: String)] = [
    ("projects", "Projetos", "folder"),
    ("xcode", "Xcode", "hammer"),
    ("worktrees", "Worktrees", "arrow.triangle.branch"),
    ("caches", "Caches de pacotes", "archivebox"),
    ("docker", "Docker", "cube.transparent"),
  ]
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        summary
        if let report = store.report {
          if report.items.isEmpty {
            Card { EmptyNote(text: L("Nada para limpar nas pastas analisadas.")) }
          }
          ForEach(Self.groups, id: \.id) { group in
            let items = report.items.filter { $0.group == group.id }
            if !items.isEmpty { section(group.title, group.symbol, items) }
          }
          if let error = report.docker_error {
            Text(L("Docker: %@", error)).font(.caption).foregroundStyle(.orange)
          }
        }
        Text(
          L("Pastas vão para a Lixeira: dá para recuperá-las até esvaziar a Lixeira, e o espaço só é liberado depois disso. Itens que um processo está usando (servidor de dev, cargo, Xcode, um agente trabalhando no projeto) ficam bloqueados e são verificados de novo na hora de limpar. Dados do Docker são removidos pelo próprio Docker e não voltam: as imagens são baixadas de novo quando precisar.")
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
    .safeAreaInset(edge: .bottom) { if !store.selected.isEmpty { actionBar } }
    .confirmationDialog(confirmTitle, isPresented: $confirm, titleVisibility: .visible) {
      Button(L("Limpar"), role: .destructive) { store.clean(store.selected) }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(confirmMessage)
    }
  }

  private var reclaimable: Double {
    (store.report?.items ?? []).filter { $0.busy == nil }.reduce(0) { $0 + $1.bytes }
  }
  private var summary: some View {
    Card {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(store.report == nil ? "—" : diskBytes(reclaimable))
            .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
          Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        if store.scanning {
          ProgressView().controlSize(.small)
          Text(L("Analisando…")).foregroundStyle(.secondary)
        } else {
          Button {
            store.scan()
          } label: {
            Label(store.report == nil ? L("Analisar") : L("Analisar de novo"), systemImage: "arrow.clockwise")
          }.disabled(store.working)
        }
      }
      if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
      if !store.scanning, let stale = store.staleness(roots: prefs.cleanupRoots) {
        Label(stale, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
      }
      if store.report == nil, !store.scanning {
        Text(L("A análise percorre as pastas de projeto e pode levar alguns segundos; nada é lido até você clicar em Analisar."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack(alignment: .top, spacing: 8) {
        Text(L("Pastas")).font(.callout.weight(.medium)).frame(width: 60, alignment: .leading)
        FlowRoots(
          roots: rootsShown, custom: Set(prefs.cleanupRoots),
          remove: { root in prefs.cleanupRoots.removeAll { $0 == root } })
        Spacer(minLength: 8)
        Button(L("Adicionar pasta…"), systemImage: "plus", action: addFolder).controlSize(.small)
      }
      Text(
        L("Além das pastas que você adicionar, o CoreScope procura em ~/Developer, ~/Projects, ~/Code… e na pasta que contém cada projeto em que um agente, editor ou terminal está trabalhando agora.")
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private var rootsShown: [String] {
    let found = store.report?.roots ?? []
    return found + prefs.cleanupRoots.filter { root in !found.contains { root.hasPrefix($0) } }
  }
  private var subtitle: String {
    guard let report = store.report else { return L("Encontre node_modules, target/ do Rust, DerivedData, caches e imagens Docker sem uso.") }
    var parts = [plural(report.items.filter { $0.busy == nil }.count, "recuperáveis em 1 item", "recuperáveis em %@ itens")]
    if let at = store.scannedAt {
      parts.append(L("análise %@ (%@ s)", at.formatted(.relative(presentation: .named)), String(format: "%.0f", report.seconds)))
    }
    return parts.joined(separator: " · ")
  }

  private func section(_ title: String, _ symbol: String, _ items: [DevSpaceItem]) -> some View {
    let free = items.filter { $0.busy == nil }
    let total = free.reduce(0) { $0 + $1.bytes }
    let allSelected = !free.isEmpty && free.allSatisfy { store.selection.contains($0.id) }
    return Card {
      CardHeader(title: L(title), symbol: symbol, count: items.count) {
        Text(diskBytes(total)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        if title == "Projetos" {
          let stale = free.filter { ($0.modifiedDate.map { -$0.timeIntervalSinceNow > 30 * 86400 }) ?? false }
          Button(L("Sem uso há 30+ dias")) { store.selection.formUnion(stale.map(\.id)) }
            .disabled(stale.isEmpty).controlSize(.small)
            .help(L("Seleciona as pastas que não mudam há mais de 30 dias"))
        }
        Button(allSelected ? L("Limpar seleção") : L("Selecionar tudo")) {
          if allSelected { store.selection.subtract(free.map(\.id)) } else { store.selection.formUnion(free.map(\.id)) }
        }.disabled(free.isEmpty).controlSize(.small)
      }
      ForEach(items) { item in
        CleanupRow(item: item, selected: selectionBinding(item))
        if item.id != items.last?.id { Divider() }
      }
    }
  }
  private func selectionBinding(_ item: DevSpaceItem) -> Binding<Bool> {
    Binding(
      get: { store.selection.contains(item.id) },
      set: { on in
        if on { store.selection.insert(item.id) } else { store.selection.remove(item.id) }
      })
  }
  private var actionBar: some View {
    let items = store.selected
    return HStack(spacing: 12) {
      Text(L("%@ selecionados · %@", "\(items.count)", diskBytes(items.reduce(0) { $0 + $1.bytes })))
        .font(.callout.weight(.medium)).monospacedDigit()
      Spacer()
      Button(L("Desmarcar")) { store.selection.removeAll() }
      Button(role: .destructive) {
        confirm = true
      } label: {
        Label(L("Limpar…"), systemImage: "trash")
      }
      .buttonStyle(.borderedProminent).tint(.red).disabled(store.working || store.scanning)
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
    .background(.bar)
  }
  private var confirmTitle: String {
    let items = store.selected
    return plural(items.count, "Limpar 1 item (%@)?", "Limpar %@ itens (%@)?", diskBytes(items.reduce(0) { $0 + $1.bytes }))
  }
  private var confirmMessage: String {
    let items = store.selected
    let folders = items.filter { !$0.isDocker }.count
    let docker = items.count - folders
    var lines: [String] = []
    if folders > 0 { lines.append(plural(folders, "1 pasta vai para a Lixeira (recuperável até esvaziá-la).", "%@ pastas vão para a Lixeira (recuperáveis até esvaziá-la).")) }
    if docker > 0 { lines.append(plural(docker, "1 item do Docker será removido pelo Docker, sem volta.", "%@ itens do Docker serão removidos pelo Docker, sem volta.")) }
    lines.append(items.prefix(4).map(\.title).joined(separator: ", ") + (items.count > 4 ? "…" : ""))
    return lines.joined(separator: "\n")
  }
  private func addFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = L("Adicionar")
    guard panel.runModal() == .OK else { return }
    for url in panel.urls where !prefs.cleanupRoots.contains(url.path) { prefs.cleanupRoots.append(url.path) }
  }
}

private struct FlowRoots: View {
  let roots: [String]
  let custom: Set<String>
  let remove: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if roots.isEmpty { Text("—").foregroundStyle(.secondary) }
      ForEach(roots, id: \.self) { root in
        HStack(spacing: 6) {
          Text(abbreviateHome(root)).font(.callout).lineLimit(1).truncationMode(.middle).help(root)
          if custom.contains(root) {
            Button {
              remove(root)
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain).help(L("Remover pasta"))
          } else {
            Badge(text: L("auto"))
          }
        }
      }
    }
  }
}

private struct CleanupRow: View {
  /// A process using the item ("node (PID 1)"), or why a worktree must stay.
  static func lockLabel(_ reason: String) -> String {
    if reason.contains("(PID") { return L("Em uso · %@", reason) }
    let suffix = " alterações não commitadas"
    if reason.hasSuffix(suffix) { return L("%@ alterações não commitadas", String(reason.dropLast(suffix.count))) }
    return L(reason)
  }
  let item: DevSpaceItem
  @Binding var selected: Bool
  var body: some View {
    HStack(spacing: 10) {
      Toggle("", isOn: $selected).toggleStyle(.checkbox).labelsHidden().disabled(item.busy != nil)
      Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
          if !item.isDocker, item.kind != "simulator_caches" {
            Text(L(item.kindLabel)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
          }
        }
        Text(item.isDocker ? L("Removido pelo Docker") : item.detail ?? abbreviateHome(item.path))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          .help(item.path)
      }
      Spacer(minLength: 8)
      if let busy = item.busy {
        Badge(text: Self.lockLabel(busy), color: .orange, symbol: "lock.fill")
          .help(L("Feche ou pare o processo para poder limpar"))
      } else if let date = item.modifiedDate {
        Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
          .help(L("Última modificação"))
      }
      Text(diskBytes(item.bytes)).font(.callout).monospacedDigit().frame(width: 76, alignment: .trailing)
      if !item.isDocker {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        } label: {
          Image(systemName: "magnifyingglass")
        }.buttonStyle(.borderless).help(L("Mostrar no Finder"))
      }
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
    .onTapGesture { if item.busy == nil { selected.toggle() } }
    .opacity(item.busy == nil ? 1 : 0.75)
  }
}
