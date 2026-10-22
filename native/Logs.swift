import AppKit
import SwiftUI

/// A log the core can read: a file (project log or profile command output) or a container.
struct LogSource: Codable, Hashable, Identifiable {
  let kind: String
  let name: String
  let project: String?
  let target: String
  var id: String { "\(kind):\(target)" }
}
struct LogEntry: Codable, Hashable {
  let source: String
  let project: String?
  let level: String
  let text: String
  let context: [String]
  let count: Int
}

/// Projects whose logs are gathered: profiles (app and file), project files and the projects
/// agents are working in. Reads happen in the core on demand; nothing is kept on disk.
final class LogsStore: ObservableObject {
  static let shared = LogsStore()
  @Published private(set) var sources: [LogSource] = []
  @Published private(set) var loading = false
  private let queue = DispatchQueue(label: "app.corescope.logs", qos: .userInitiated)

  struct Project: Hashable {
    let name: String
    let folder: String
    let globs: [String]
  }
  /// Every project CoreScope knows a folder for, deduplicated by folder.
  func projects() -> [Project] {
    var out: [Project] = []
    func add(_ name: String, _ folder: String, _ globs: [String] = []) {
      guard !folder.isEmpty, !out.contains(where: { $0.folder == folder }) else { return }
      out.append(Project(name: name, folder: folder, globs: globs))
    }
    for f in ProjectFileStore.shared.files { add(f.project, f.folder, f.config?.logs ?? []) }
    for p in ProfileStore.shared.allProfiles where p.source == nil {
      add(p.name, p.folder)
    }
    if let s = Monitor.shared.snapshot {
      for root in s.agentSessions where !root.cwd.isEmpty {
        let folder = repositoryRoot(root.cwd)
        add((folder as NSString).lastPathComponent, folder)
      }
    }
    return out
  }
  /// Nearest folder with a .git, else the folder itself (until the background lookup answers:
  /// agent folders are often on an external disk, and this runs on the main thread).
  private func repositoryRoot(_ cwd: String) -> String {
    WorkingTrees.shared.tree(cwd) ?? cwd
  }

  func refresh(done: (() -> Void)? = nil) {
    if loading {
      done?()
      return
    }
    loading = true
    let projects = projects()
    // Profile command output, named after the profile.
    var extra: [LogSource] = []
    for p in ProfileStore.shared.allProfiles {
      let project = projects.first { $0.folder == p.folder }?.name ?? p.name
      for c in p.commands {
        let url = ProfileStore.shared.logURL(p, c)
        if FileManager.default.fileExists(atPath: url.path) {
          extra.append(LogSource(kind: "file", name: "\(p.name) · \(c.name)", project: project, target: url.path))
        }
      }
      for name in p.containers {
        extra.append(LogSource(kind: "container", name: name, project: project, target: name))
      }
    }
    // Environment actions' output, under their project.
    for a in ActionStore.shared.actions {
      let url = ActionStore.logURL(a)
      if FileManager.default.fileExists(atPath: url.path) {
        let project = projects.first { $0.folder == a.folder }?.name ?? a.project
        extra.append(LogSource(kind: "file", name: "\(a.project) · \(a.group.isEmpty ? a.name : "\(a.group) · \(a.name)")", project: project, target: url.path))
      }
    }
    // Other containers, under their compose project.
    for c in ContainerStore.shared.report?.containers ?? [] where c.running && !extra.contains(where: { $0.target == c.name }) {
      extra.append(LogSource(kind: "container", name: c.name, project: c.project ?? L("Contêineres"), target: c.name))
    }
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("logs", cost) }
      let request: [String: Any] = [
        "op": "files", "folders": projects.map { ["folder": $0.folder, "project": $0.name, "globs": $0.globs] },
      ]
      let files: [LogSource] = (try? Self.call(request)).flatMap { try? JSONDecoder().decode([LogSource].self, from: $0) } ?? []
      DispatchQueue.main.async {
        self.loading = false
        let all = files + extra
        if all != self.sources { self.sources = all }
        done?()
      }
    }
  }

  func sources(project: String?) -> [LogSource] {
    guard let project else { return sources }
    let key = project.lowercased()
    return sources.filter { ($0.project ?? "").lowercased() == key || $0.name.lowercased().hasPrefix(key + " ·") }
  }

  /// Blocking: call from a background queue.
  static func call(_ request: [String: Any]) throws -> Data {
    let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8) ?? "{}"
    guard let pointer = json.withCString({ cs_logs($0) }) else {
      throw NSError(domain: "CoreScope", code: 1, userInfo: [NSLocalizedDescriptionKey: L("O núcleo não retornou dados")])
    }
    defer { cs_free(pointer) }
    let data = Data(bytes: pointer, count: strlen(pointer))
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = obj["error"] as? String {
      throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: L(error)])
    }
    return data
  }
  static func encode(_ sources: [LogSource]) -> [[String: Any]] {
    sources.map { s in
      var d: [String: Any] = ["kind": s.kind, "name": s.name, "target": s.target]
      if let p = s.project { d["project"] = p }
      return d
    }
  }
  func tail(_ source: LogSource, lines: Int, done: @escaping (Result<[String], Error>) -> Void) {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("logs", cost) }
      let result = Result {
        try JSONDecoder().decode(
          [String].self, from: Self.call(["op": "tail", "source": Self.encode([source])[0], "lines": lines]))
      }
      DispatchQueue.main.async { done(result) }
    }
  }
  func errors(_ sources: [LogSource], limit: Int = 30, warnings: Bool = false, done: @escaping ([LogEntry], [String]) -> Void) {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("logs", cost) }
      struct Out: Decodable {
        let entries: [LogEntry]
        let problems: [String]
      }
      let out = (try? Self.call(["op": "errors", "sources": Self.encode(sources), "limit": limit, "warnings": warnings]))
        .flatMap { try? JSONDecoder().decode(Out.self, from: $0) }
      DispatchQueue.main.async { done(out?.entries ?? [], out?.problems ?? []) }
    }
  }
  func search(_ sources: [LogSource], query: String, limit: Int = 200, done: @escaping ([LogEntry]) -> Void) {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("logs", cost) }
      let out = (try? Self.call(["op": "search", "sources": Self.encode(sources), "query": query, "limit": limit]))
        .flatMap { try? JSONDecoder().decode([LogEntry].self, from: $0) } ?? []
      DispatchQueue.main.async { done(out) }
    }
  }
}

struct LogsView: View {
  @ObservedObject var store = LogsStore.shared
  @ViewState private var project: String?
  @ViewState private var selected: LogSource?
  @ViewState private var mode = 0
  @ViewState private var lines: [String] = []
  @ViewState private var entries: [LogEntry] = []
  @ViewState private var query = ""
  @ViewState private var live = true
  @ViewState private var note: String?
  @ViewState private var reading = false
  private var projectNames: [String] {
    Array(Set(store.sources.compactMap(\.project))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }
  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 270)
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        toolbar
        if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        content
      }.padding(16)
    }
    .onAppear { store.refresh() }
    .task(id: "\(selected?.id ?? "")|\(mode)|\(live)") {
      // Live tail of the selected source every 2 s while the page is open.
      while !Task.isCancelled {
        load()
        guard live, mode == 0 else { break }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }

  private var sidebar: some View {
    List(selection: Binding(get: { selected?.id }, set: { id in selected = store.sources.first { $0.id == id } })) {
      if store.sources.isEmpty {
        Text(store.loading ? L("Procurando logs…") : L("Nenhum log encontrado nos projetos conhecidos."))
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(projectNames, id: \.self) { name in
        Section {
          ForEach(store.sources(project: name)) { s in
            Label {
              // The file name; its folder is in the tooltip.
              Text(s.kind == "file" && s.name.contains("/") ? (s.name as NSString).lastPathComponent : s.name)
                .lineLimit(1).truncationMode(.middle)
            } icon: {
              Image(systemName: s.kind == "container" ? "shippingbox" : "doc.plaintext")
            }.tag(s.id).help(s.target)
          }
        } header: {
          HStack {
            Text(name)
            Spacer()
            Button(L("Erros")) {
              project = name
              mode = 1
              selected = nil
            }.buttonStyle(.link).font(.caption)
          }
        }
      }
    }.listStyle(.sidebar)
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Picker("", selection: $mode) {
        Text(L("Ao vivo")).tag(0)
        Text(L("Erros")).tag(1)
        Text(L("Busca")).tag(2)
      }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
      if mode == 2 {
        TextField(L("Buscar nos logs do projeto"), text: $query).textFieldStyle(.roundedBorder).onSubmit(load)
      } else {
        Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      if reading { ProgressView().controlSize(.small) }
      if mode == 0 { Toggle(L("Ao vivo"), isOn: $live).toggleStyle(.switch).controlSize(.small) }
      Button {
        store.refresh()
        load()
      } label: {
        Image(systemName: "arrow.clockwise")
      }.help(L("Atualizar"))
    }
  }
  private var title: String {
    if mode == 1 { return L("Erros recentes · %@", project ?? selected?.project ?? L("todos os projetos")) }
    return selected?.name ?? L("Escolha um log")
  }
  private var scope: [LogSource] {
    if let selected, mode == 0 { return [selected] }
    return store.sources(project: project ?? selected?.project)
  }

  @ViewBuilder private var content: some View {
    switch mode {
    case 0:
      if selected == nil {
        EmptyNote(text: L("Escolha um log à esquerda, ou clique em Erros num projeto."))
        Spacer()
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
              ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(color(line))
                  .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(i)
              }
            }
          }
          .onChange(of: lines.count) { _, count in if live, count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) } }
        }
      }
    default:
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          if entries.isEmpty, !reading { EmptyNote(text: mode == 1 ? L("Nenhum erro recente.") : L("Nada encontrado.")) }
          ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Badge(text: e.source, color: .secondary)
                if e.count > 1 { Badge(text: "×\(e.count)", color: .orange) }
              }
              Text(e.text).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(e.level == "error" ? Color.red : e.level == "warning" ? .orange : .primary)
                .textSelection(.enabled).lineLimit(6)
              ForEach(e.context, id: \.self) { c in
                Text(c).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Divider()
          }
        }
      }
    }
  }
  private func color(_ line: String) -> Color {
    let l = line.lowercased()
    if l.contains("error") || l.contains("fatal") || l.contains("exception") || l.contains("panic") { return .red }
    if l.contains("warn") { return .orange }
    return .primary
  }
  private func load() {
    note = nil
    switch mode {
    case 0:
      guard let selected else { return }
      store.tail(selected, lines: 800) { result in
        switch result {
        case .success(let l): lines = l
        case .failure(let e): note = e.localizedDescription
        }
      }
    case 1:
      reading = true
      store.errors(scope) { e, problems in
        reading = false
        entries = e
        note = problems.first
      }
    default:
      guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
      reading = true
      store.search(scope, query: query) {
        reading = false
        entries = $0
      }
    }
  }
}
