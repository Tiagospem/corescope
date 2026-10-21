import AppKit
import SwiftUI

/// One row a watch saw change (`watch_status`).
struct DBChange: Decodable, Identifiable, Equatable {
  let seq: Int
  let batch: Int
  let at: Double
  let table: String
  let op: String
  let key: String
  let columns: [String]
  let before: [JSONValue]?
  let after: [JSONValue]?
  let changed: [String]
  let note: String?
  var id: Int { seq }
}
struct DBWatchStatus: Decodable, Equatable {
  let id: String
  let database: String
  let server: String
  let state: String
  let error: String?
  let started: Double
  let tables: Int
  let table_names: [String]
  let large_tables: [String]
  let ignored: [String]
  let default_ignored: [String]
  let last_seq: Int
  let changes: [DBChange]
}
/// A JSON value from the database, shown as text.
enum JSONValue: Decodable, Equatable {
  case null
  case text(String)
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let s = try? c.decode(String.self) {
      self = .text(s)
    } else if let b = try? c.decode(Bool.self) {
      self = .text(b ? "true" : "false")
    } else if let i = try? c.decode(Int64.self) {
      self = .text(String(i))
    } else if let d = try? c.decode(Double.self) {
      self = .text(String(d))
    } else {
      // Nested JSON (a json column): its text.
      let any = try c.decode(AnyJSON.self)
      self = .text(any.text)
    }
  }
  var display: String {
    switch self {
    case .null: return "NULL"
    case .text(let s): return s
    }
  }
}
private struct AnyJSON: Decodable {
  let text: String
  init(from decoder: Decoder) throws {
    if var a = try? decoder.unkeyedContainer() {
      var parts: [String] = []
      while !a.isAtEnd { parts.append((try? a.decode(AnyJSON.self).text) ?? "?") }
      text = "[" + parts.joined(separator: ", ") + "]"
    } else if let o = try? decoder.container(keyedBy: AnyKey.self) {
      text = "{" + o.allKeys.map { "\($0.stringValue): \((try? o.decode(AnyJSON.self, forKey: $0).text) ?? "?")" }.joined(separator: ", ") + "}"
    } else {
      text = (try? JSONValue(from: decoder).display) ?? "?"
    }
  }
}
private struct AnyKey: CodingKey {
  var stringValue: String
  var intValue: Int?
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) {
    self.intValue = intValue
    stringValue = "\(intValue)"
  }
}

/// The change monitor of one database in a window of its own; closing it stops the watch.
enum DBWatchWindow {
  private static var windows: [String: NSWindow] = [:]
  private static let delegate = CloseDelegate()
  static func open(_ db: DatabaseItem, database: String) {
    let key = "\(db.id)#\(database)"
    if let w = windows[key] {
      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = L("Alterações em %@", database)
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 720, height: 420)
    window.setFrameAutosaveName("db-watch")
    window.contentView = NSHostingView(rootView: DBWatchView(db: db, database: database))
    window.delegate = delegate
    windows[key] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  fileprivate static func closed(_ window: NSWindow) {
    guard let key = windows.first(where: { $0.value === window })?.key else { return }
    // Dropping the view stops its watch (onDisappear).
    window.contentView = nil
    windows[key] = nil
  }
  private final class CloseDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
      if let w = notification.object as? NSWindow { DBWatchWindow.closed(w) }
    }
  }
}

/// Runs one watch in the core and gathers its changes while the window is open.
final class DBWatchModel: ObservableObject {
  @Published private(set) var status: DBWatchStatus?
  @Published private(set) var changes: [DBChange] = []
  @Published var error: String?
  @Published var comparing: (name: String, changes: [DBChange])?
  @Published var message: String?
  private(set) var watch: String?
  private var since = 0
  private var timer: Timer?
  let db: DatabaseItem
  let database: String
  init(db: DatabaseItem, database: String) {
    self.db = db
    self.database = database
  }
  private var base: [String: Any] {
    var r: [String: Any] = [:]
    if let c = db.container { r["container"] = c } else { r["port"] = db.port }
    if db.container == nil, let cred = DBCredentials.all()[db.credentialKey] {
      r["user"] = cred["user"]
      r["password"] = cred["password"]
    }
    return r
  }
  func start(ignore: [String]? = nil) {
    var request = base.merging(["op": "watch_start", "database": database]) { $1 }
    if let ignore { request["ignore"] = ignore }
    error = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.call(request)
      DispatchQueue.main.async {
        switch r {
        case .failure(let e): self.error = e.message
        case .success(let v):
          self.watch = (v as? [String: Any])?["watch"] as? String
          self.since = 0
          self.poll()
        }
      }
    }
  }
  func stop() {
    timer?.invalidate()
    timer = nil
    if let w = watch { DispatchQueue.global().async { _ = DBTool.call(["op": "watch_stop", "watch": w]) } }
    watch = nil
  }
  private func poll() {
    guard let w = watch else { return }
    let since = self.since
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let r = DBTool.decode(["op": "watch_status", "watch": w, "since": since], as: DBWatchStatus.self)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.watch == w else { return }
        if case .success(let s) = r {
          if !s.changes.isEmpty {
            self.changes.append(contentsOf: s.changes)
            if self.changes.count > 5000 { self.changes.removeFirst(self.changes.count - 5000) }
            self.since = s.changes.last?.seq ?? self.since
          }
          self.status = s
          self.error = s.error
        }
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.poll() }
      }
    }
  }
  func clear() {
    changes = []
    comparing = nil
    if let w = watch { DispatchQueue.global().async { _ = DBTool.call(["op": "watch_clear", "watch": w]) } }
  }
  func setIgnored(_ tables: [String]) {
    guard let w = watch else { return }
    DispatchQueue.global(qos: .userInitiated).async { _ = DBTool.call(["op": "watch_ignore", "watch": w, "tables": tables]) }
  }
  func save() {
    guard let w = watch else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.call(["op": "watch_save", "watch": w])
      DispatchQueue.main.async {
        switch r {
        case .failure(let e): self.message = e.message
        case .success: self.message = L("Snapshot salvo: compare depois em Comparar com…")
        }
      }
    }
  }
  func snapshots() -> [(name: String, file: String)] {
    guard case .success(let v) = DBTool.call(["op": "watch_snapshots", "database": database]), let list = v as? [[String: Any]] else { return [] }
    return list.compactMap { s in (s["name"] as? String).flatMap { n in (s["file"] as? String).map { (n, $0) } } }
  }
  func compare(_ name: String, _ file: String) {
    guard let w = watch else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.decode(["op": "watch_compare", "watch": w, "file": file], as: [String: [DBChange]].self)
      DispatchQueue.main.async {
        switch r {
        case .failure(let e): self.message = e.message
        case .success(let v): self.comparing = (name, v["changes"] ?? [])
        }
      }
    }
  }
}

struct DBWatchView: View {
  let db: DatabaseItem
  let database: String
  @StateObject private var model: DBWatchModel
  @ViewState private var selected: Int?
  @ViewState private var filter = ""
  @ViewState private var choosingIgnored = false
  init(db: DatabaseItem, database: String) {
    self.db = db
    self.database = database
    _model = StateObject(wrappedValue: DBWatchModel(db: db, database: database))
  }
  private var shown: [DBChange] {
    let list = model.comparing?.changes ?? model.changes
    guard !filter.isEmpty else { return list }
    return list.filter { $0.table.localizedCaseInsensitiveContains(filter) || $0.key.localizedCaseInsensitiveContains(filter) }
  }
  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
      }
      if let c = model.comparing {
        HStack {
          Label(L("Comparação com %@: %@ diferenças", c.name, "\(c.changes.count)"), systemImage: "arrow.left.arrow.right")
            .font(.caption)
          Spacer()
          Button(L("Voltar ao vivo")) { model.comparing = nil }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(Color.accentColor.opacity(0.08))
      }
      HSplitView {
        list.frame(minWidth: 320, idealWidth: 420)
        detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Circle().fill(model.status?.state == "watching" ? Color.green : model.status?.state == "failed" ? .red : .orange)
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text(L("%@ em %@", database, db.label)).font(.callout.weight(.semibold))
        Text(statusLine).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      TextField(L("Filtrar tabela ou chave"), text: $filter).textFieldStyle(.roundedBorder).frame(width: 200).controlSize(.small)
      Button(L("Ignoradas (%@)", "\(model.status?.ignored.count ?? 0)")) { choosingIgnored = true }.controlSize(.small)
        .popover(isPresented: $choosingIgnored, arrowEdge: .bottom) {
          IgnoredTablesView(status: model.status) {
            model.setIgnored($0)
            choosingIgnored = false
          }
        }
      Button(L("Limpar lista")) { model.clear() }.controlSize(.small).help(L("Esquece as alterações mostradas; o monitor continua."))
      Menu(L("Snapshot")) {
        Button(L("Salvar o estado atual")) { model.save() }
        Divider()
        let list = model.snapshots()
        if list.isEmpty { Text(L("Nenhum snapshot salvo")) }
        ForEach(list.prefix(12), id: \.file) { s in
          Button(L("Comparar com %@", s.name)) { model.compare(s.name, s.file) }
        }
      }.fixedSize().controlSize(.small)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }
  private var statusLine: String {
    guard let s = model.status else { return L("Lendo as tabelas…") }
    if s.state == "starting" { return L("Lendo as tabelas…") }
    var parts = [L("%@ tabelas", "\(s.tables - s.ignored.count)")]
    if !s.ignored.isEmpty { parts.append(L("%@ ignoradas", "\(s.ignored.count)")) }
    if !s.large_tables.isEmpty { parts.append(L("%@ grandes (só linhas novas)", "\(s.large_tables.count)")) }
    parts.append(L("desde %@", Date(timeIntervalSince1970: s.started).formatted(date: .omitted, time: .shortened)))
    if let m = model.message { parts.append(m) }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder private var list: some View {
    let items = shown
    if items.isEmpty {
      VStack(spacing: 8) {
        Image(systemName: "eye").font(.title).foregroundStyle(.tertiary)
        Text(model.comparing == nil ? L("Use o app (um cadastro, um pedido…): as linhas criadas, alteradas e apagadas aparecem aqui.") : L("Nada mudou desde o snapshot."))
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        List(selection: $selected) {
          let batches = Dictionary(grouping: items, by: \.batch).sorted { $0.key > $1.key }
          ForEach(batches, id: \.key) { batch, rows in
            Section {
              ForEach(rows) { c in
                row(c).tag(c.seq)
                  .contextMenu {
                    Button(L("Ignorar a tabela %@", c.table)) {
                      model.setIgnored(Array(Set((model.status?.ignored ?? []) + [c.table])).sorted())
                    }
                    Button(L("Copiar como JSON")) { copy(json(c)) }
                  }
              }
            } header: {
              let summary = Dictionary(grouping: rows, by: \.table).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: " · ")
              HStack {
                Text(Date(timeIntervalSince1970: rows.first?.at ?? 0).formatted(date: .omitted, time: .standard))
                Text(summary).foregroundStyle(.secondary).lineLimit(1)
              }.font(.caption)
            }
          }
        }
        .listStyle(.inset)
        .onChange(of: items.last?.seq) { _, seq in if selected == nil, let seq { proxy.scrollTo(seq) } }
      }
    }
  }
  private func row(_ c: DBChange) -> some View {
    HStack(spacing: 8) {
      Text(opLabel(c.op)).font(.caption2.weight(.bold)).foregroundStyle(opColor(c.op))
        .frame(width: 58, alignment: .leading)
      Text(c.table).font(.callout).lineLimit(1)
      Text(c.key).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 4)
      if c.op == "updated" {
        Text(c.changed.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      } else if let n = c.note {
        Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
  @ViewBuilder private var detail: some View {
    if let c = shown.first(where: { $0.seq == selected }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Text(opLabel(c.op)).font(.caption.weight(.bold)).foregroundStyle(opColor(c.op))
            Text(c.table).font(.title3.weight(.semibold))
            Text(c.key).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button(L("Copiar como JSON")) { copy(json(c)) }.controlSize(.small)
          }
          if let n = c.note { Text(n).font(.callout).foregroundStyle(.secondary) }
          let changed = Set(c.changed)
          let indexes = Array(c.columns.indices)
          let order = c.op == "updated" ? indexes.filter { changed.contains(c.columns[$0]) } + indexes.filter { !changed.contains(c.columns[$0]) } : indexes
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
              Text(L("Coluna")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              if c.op == "updated" {
                Text(L("Antes")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(L("Depois")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              } else {
                Text(L("Valor")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
              }
            }
            ForEach(order, id: \.self) { i in
              let name = c.columns[i]
              let isChanged = changed.contains(name)
              GridRow(alignment: .top) {
                Text(name).font(.system(size: 12, weight: isChanged ? .semibold : .regular, design: .monospaced))
                  .foregroundStyle(isChanged ? Color.orange : .primary)
                if c.op == "updated" {
                  value(c.before?[safe: i], dim: !isChanged, struck: isChanged)
                  value(c.after?[safe: i], dim: !isChanged)
                } else {
                  value((c.after ?? c.before)?[safe: i], dim: false)
                }
              }
              .padding(.vertical, 1)
              .background(isChanged ? Color.orange.opacity(0.08) : .clear)
            }
          }
        }
        .padding(14)
      }
    } else {
      Text(L("Escolha uma alteração para ver os valores.")).font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private func value(_ v: JSONValue?, dim: Bool, struck: Bool = false) -> some View {
    let text = v?.display ?? ""
    return Text(text)
      .font(.system(size: 12, design: .monospaced))
      .italic(v == .null)
      .strikethrough(struck, color: .red.opacity(0.6))
      .foregroundStyle(v == .null ? Color.secondary : dim ? Color.secondary : .primary)
      .textSelection(.enabled)
      .lineLimit(6)
      .frame(maxWidth: 380, alignment: .leading)
  }
  private func opLabel(_ op: String) -> String {
    switch op {
    case "created": return L("CRIADO")
    case "updated": return L("ALTERADO")
    case "deleted": return L("APAGADO")
    default: return L("MUDOU")
    }
  }
  private func opColor(_ op: String) -> Color {
    switch op {
    case "created": return .green
    case "updated": return .orange
    case "deleted": return .red
    default: return .secondary
    }
  }
  private func json(_ c: DBChange) -> String {
    func obj(_ values: [JSONValue]?) -> [String: Any]? {
      guard let values else { return nil }
      var o: [String: Any] = [:]
      for (i, n) in c.columns.enumerated() {
        if case .text(let s) = values[safe: i] ?? .null { o[n] = s } else { o[n] = NSNull() }
      }
      return o
    }
    var out: [String: Any] = ["table": c.table, "op": c.op, "key": c.key]
    if let b = obj(c.before) { out["before"] = b }
    if let a = obj(c.after) { out["after"] = a }
    if !c.changed.isEmpty { out["changed"] = c.changed }
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
}

/// Which tables the monitor skips: the project's defaults (.corescope.yml) come ticked and can be
/// unticked here without editing the file.
private struct IgnoredTablesView: View {
  let status: DBWatchStatus?
  let apply: ([String]) -> Void
  @ViewState private var chosen: Set<String> = []
  @ViewState private var search = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L("Tabelas ignoradas")).font(.headline)
      Text(L("Não são lidas nem mostradas. As marcadas como padrão vêm do .corescope.yml (databases.<banco>.ignore_changes)."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextField(L("Filtrar"), text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
      let names = (status?.table_names ?? []).filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(names, id: \.self) { t in
            Toggle(isOn: Binding(get: { chosen.contains(t) }, set: { on in if on { chosen.insert(t) } else { chosen.remove(t) } })) {
              HStack(spacing: 6) {
                Text(t).font(.callout)
                if status?.default_ignored.contains(t) == true { Text(L("padrão")).font(.caption2).foregroundStyle(.secondary) }
              }
            }.toggleStyle(.checkbox)
          }
        }
      }.frame(height: 260)
      HStack {
        Button(L("Padrão do projeto")) { chosen = Set(status?.default_ignored ?? []) }.controlSize(.small)
        Spacer()
        Button(L("Aplicar")) { apply(chosen.sorted()) }.buttonStyle(.borderedProminent).controlSize(.small)
      }
    }
    .padding(14)
    .frame(width: 340)
    .onAppear { chosen = Set(status?.ignored ?? []) }
  }
}

extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
