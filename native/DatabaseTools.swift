import AppKit
import SwiftUI

struct DBError: Error { let message: String }

/// `cs_db_tool` (core `db_tool`): Redis keyspace and flush, databases, snapshots.
enum DBTool {
  static func call(_ request: [String: Any]) -> Result<Any, DBError> {
    guard let data = try? JSONSerialization.data(withJSONObject: request),
      let json = String(data: data, encoding: .utf8),
      let pointer = json.withCString({ cs_db_tool($0) })
    else { return .failure(DBError(message: L("O núcleo não retornou dados"))) }
    defer { cs_free(pointer) }
    let body = Data(bytes: pointer, count: strlen(pointer))
    guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
      return .failure(DBError(message: L("Resposta inválida")))
    }
    // The core fails with {"error": …} alone; a failed job's status carries its error next to its state.
    if let obj = value as? [String: Any], obj.count == 1, let error = obj["error"] as? String {
      return .failure(DBError(message: error))
    }
    return .success(value)
  }
  static func decode<T: Decodable>(_ request: [String: Any], as: T.Type) -> Result<T, DBError> {
    call(request).flatMap { value in
      guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
        let decoded = try? JSONDecoder().decode(T.self, from: data)
      else { return .failure(DBError(message: L("Resposta inválida"))) }
      return .success(decoded)
    }
  }
}

/// Connection string without a password: apps ask for one when the server needs it.
func databaseDSN(_ db: DatabaseItem, database: String? = nil) -> String {
  switch db.kind {
  case "mysql": return "mysql://root@127.0.0.1:\(db.port)/\(database ?? "")"
  case "postgres":
    let user = db.container != nil ? "postgres" : NSUserName()
    return "postgresql://\(user)@127.0.0.1:\(db.port)/\(database ?? "postgres")"
  default: return "redis://127.0.0.1:\(db.port)/\(database ?? "0")"
  }
}

/// Database apps installed on this Mac that open a connection URL.
struct DatabaseApp {
  let name: String
  let kinds: Set<String>
  let url: URL
  static var installed: [DatabaseApp] {
    let candidates: [(String, Set<String>, [String], String)] = [
      ("TablePlus", ["mysql", "postgres", "redis"], ["com.tinyapp.TablePlus", "com.tinyapp.TablePlus-setapp"], "TablePlus"),
      ("Redis Insight", ["redis"], ["org.RedisLabs.RedisInsight-V2", "com.redis.RedisInsight"], "Redis Insight"),
      ("Sequel Ace", ["mysql"], ["com.sequel-ace.sequel-ace"], "Sequel Ace"),
      ("Postico", ["postgres"], ["at.eggerapps.Postico2", "at.eggerapps.Postico"], "Postico 2"),
      ("DBeaver", ["mysql", "postgres"], ["org.jkiss.dbeaver.core.product"], "DBeaver"),
    ]
    return candidates.compactMap { name, kinds, ids, appName in
      let byID = ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
      let byName = ["/Applications/\(appName).app", "/Applications/Setapp/\(appName).app"]
        .map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
      return (byID ?? byName).map { DatabaseApp(name: name, kinds: kinds, url: $0) }
    }
  }
  func open(_ db: DatabaseItem, database: String? = nil) {
    var target = URL(string: databaseDSN(db, database: database))
    if name == "Redis Insight" {
      var c = URLComponents(string: "redisinsight://databases/connect")
      c?.queryItems = [
        URLQueryItem(name: "redisUrl", value: databaseDSN(db, database: database)),
        URLQueryItem(name: "databaseAlias", value: db.label),
      ]
      target = c?.url
    }
    guard let target else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    NSWorkspace.shared.open([target], withApplicationAt: url, configuration: config)
  }
}

/// "Open in" and "Copy DSN" for one database server.
struct DatabaseOpenMenu: View {
  let db: DatabaseItem
  var body: some View {
    let apps = DatabaseApp.installed.filter { $0.kinds.contains(db.kind) }
    Menu {
      ForEach(apps, id: \.name) { app in
        Button(L("Abrir no %@", app.name)) { app.open(db) }
      }
      if !apps.isEmpty { Divider() }
      Button(L("Copiar DSN")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(databaseDSN(db), forType: .string)
      }
    } label: {
      Image(systemName: "arrow.up.forward.app")
    }.menuStyle(.borderlessButton).fixedSize()
      .help(L("Abrir em um app de banco (TablePlus, Redis Insight…) ou copiar a URL de conexão, sem senha"))
  }
}

struct RedisPrefix: Decodable, Hashable {
  let prefix: String
  let sampled: Int
  let estimated_keys: Double
  let estimated_bytes: Double
  let without_ttl: Int
  let example: String
}
struct RedisKeyspace: Decodable {
  let db: Int
  let keys: Double
  let sampled: Int
  let prefixes: [RedisPrefix]
}

/// One Redis database by key prefix (sampled), with "flush" for development data.
struct RedisKeyspaceSheet: View {
  let db: DatabaseItem
  let number: Int
  @Environment(\.dismiss) private var dismiss
  @ViewState private var keyspace: RedisKeyspace?
  @ViewState private var error: String?
  @ViewState private var confirmFlush = false
  @ViewState private var flushed = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Redis :%@ · db%@", "\(db.port)", "\(number)")).font(.title3.weight(.semibold))
      if let k = keyspace {
        Text(L("%@ chaves; %@ amostradas (SCAN), memória por chave com MEMORY USAGE.", "\(Int(k.keys))", "\(k.sampled)"))
          .font(.caption).foregroundStyle(.secondary)
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(k.prefixes, id: \.self) { p in
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                  Text(p.prefix).font(.system(.callout, design: .monospaced)).lineLimit(1)
                  Text(p.example).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if p.without_ttl > 0 {
                  Badge(text: L("%@%% sem TTL", "\(p.without_ttl * 100 / max(p.sampled, 1))"), color: p.without_ttl == p.sampled ? .orange : .secondary)
                    .help(L("Chaves que nunca expiram crescem até alguém apagar."))
                }
                Text(L("~%@ chaves", "\(Int(p.estimated_keys))")).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("~" + formatBytes(p.estimated_bytes)).font(.callout).monospacedDigit().frame(width: 90, alignment: .trailing)
              }
            }
          }
        }.frame(maxHeight: 360)
      } else if let error {
        Text(error).foregroundStyle(.red)
      } else {
        ProgressView(L("Amostrando chaves…"))
      }
      if flushed { Label(L("db%@ esvaziado.", "\(number)"), systemImage: "checkmark.circle.fill").foregroundStyle(Tint.brand) }
      HStack {
        Button(L("Esvaziar db%@…", "\(number)"), role: .destructive) { confirmFlush = true }
          .disabled(keyspace == nil || flushed)
        Spacer()
        Button(L("Fechar")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(18).frame(width: 600)
    .onAppear(perform: load)
    .confirmationDialog(L("Esvaziar db%@ do Redis :%@?", "\(number)", "\(db.port)"), isPresented: $confirmFlush) {
      Button(L("Apagar todas as chaves"), role: .destructive) { flush() }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("FLUSHDB apaga as %@ chaves deste banco, sem volta. Use só em dados de desenvolvimento.", "\(Int(keyspace?.keys ?? 0))"))
    }
  }
  private func load() {
    let request: [String: Any] = ["op": "keyspace", "port": db.port, "db": number, "sample": 2000]
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.decode(request, as: RedisKeyspace.self)
      DispatchQueue.main.async {
        switch r {
        case .success(let k): keyspace = k
        case .failure(let e): error = e.message
        }
      }
    }
  }
  private func flush() {
    let request: [String: Any] = ["op": "flush", "port": db.port, "db": number]
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.call(request)
      DispatchQueue.main.async {
        if case .failure(let e) = r { error = e.message } else { flushed = true }
        DatabaseStore.shared.refresh()
      }
    }
  }
}

struct DBSnapshot: Decodable, Identifiable, Hashable {
  let id: String
  let kind: String
  let label: String
  let container: String?
  let port: Int
  let database: String
  let created: Double
  let bytes: Double
  let file: String
}

/// Snapshots of one MySQL/PostgreSQL server: take one, restore, delete.
final class SnapshotStore: ObservableObject {
  static let shared = SnapshotStore()
  @Published private(set) var all: [DBSnapshot] = []
  /// Endpoint id → what is running there ("Snapshot of shop…").
  @Published private(set) var busy: [String: String] = [:]
  @Published private(set) var messages: [String: String] = [:]
  private let queue = DispatchQueue(label: "app.corescope.dbsnapshots", qos: .userInitiated)

  func load() {
    queue.async {
      let list = (try? DBTool.decode(["op": "snapshots"], as: [DBSnapshot].self).get()) ?? []
      DispatchQueue.main.async { self.all = list }
    }
  }
  func snapshots(for db: DatabaseItem) -> [DBSnapshot] {
    all.filter { s in db.container.map { s.container == $0 } ?? (s.container == nil && s.port == db.port) }
  }
  private func run(_ db: DatabaseItem, _ label: String, _ request: [String: Any], done: String) {
    busy[db.id] = label
    messages[db.id] = nil
    queue.async {
      let r = DBTool.call(request)
      DispatchQueue.main.async {
        self.busy[db.id] = nil
        switch r {
        case .success: self.messages[db.id] = done
        case .failure(let e): self.messages[db.id] = L("Falhou: %@", e.message)
        }
        self.load()
      }
    }
  }
  func take(_ db: DatabaseItem, database: String) {
    run(db, L("Fazendo snapshot de %@…", database), ["op": "snapshot", "port": db.port, "database": database], done: L("Snapshot de %@ salvo.", database))
  }
  func restore(_ db: DatabaseItem, _ s: DBSnapshot) {
    run(db, L("Restaurando %@…", s.database), ["op": "restore", "id": s.id], done: L("%@ voltou ao snapshot de %@.", s.database, Date(timeIntervalSince1970: s.created).formatted(date: .abbreviated, time: .shortened)))
  }
  func delete(_ db: DatabaseItem, _ s: DBSnapshot) {
    run(db, L("Apagando…"), ["op": "delete", "id": s.id], done: L("Snapshot apagado."))
  }
}

struct DatabaseSnapshotsSection: View {
  let db: DatabaseItem
  @ObservedObject var store = SnapshotStore.shared
  @ViewState private var choosing = false
  @ViewState private var names: [String] = []
  @ViewState private var chosen = ""
  @ViewState private var restoring: DBSnapshot?
  @ViewState private var deleting: DBSnapshot?
  var body: some View {
    let list = store.snapshots(for: db)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Label(L("Snapshots"), systemImage: "camera.on.rectangle").font(.caption.weight(.semibold))
        if let busy = store.busy[db.id] {
          ProgressView().controlSize(.small)
          Text(busy).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if choosing {
          Picker("", selection: $chosen) {
            ForEach(names, id: \.self) { Text($0).tag($0) }
          }.labelsHidden().frame(maxWidth: 220).controlSize(.small)
          Button(L("Fazer snapshot")) {
            store.take(db, database: chosen)
            choosing = false
          }.controlSize(.small).buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
          Button(L("Cancelar")) { choosing = false }.controlSize(.small)
        } else {
          Button(L("Restaurar dump…")) { DumpRestoreStore.shared.present(db) }.controlSize(.small)
            .help(L("Um dump .sql / .sql.gz (de produção, por exemplo) num banco existente ou novo, escolhendo quais tabelas vêm sem dados."))
          Button(L("Novo snapshot…")) { choose() }.controlSize(.small).disabled(store.busy[db.id] != nil)
        }
      }
      if let message = store.messages[db.id] { Text(message).font(.caption).foregroundStyle(message.hasPrefix(L("Falhou: %@", "")) ? .red : Tint.brand) }
      ForEach(list.prefix(6)) { s in
        HStack(spacing: 8) {
          Text(s.database).font(.callout).frame(width: 180, alignment: .leading).lineLimit(1)
          Text(Date(timeIntervalSince1970: s.created).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
          Text(formatBytes(s.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
          Spacer()
          Button(L("Restaurar…")) { restoring = s }.controlSize(.small).disabled(store.busy[db.id] != nil)
          Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.file)]) } label: { Image(systemName: "folder") }
            .buttonStyle(HoverButtonStyle()).help(L("Mostrar no Finder"))
          Button { deleting = s } label: { Image(systemName: "trash") }.buttonStyle(HoverButtonStyle(tint: .red)).help(L("Apagar snapshot"))
        }
      }
      if list.isEmpty && store.busy[db.id] == nil {
        Text(
          db.container != nil
            ? L("Antes de um migrate:fresh ou db:wipe, tire um snapshot; restaurar volta o banco exatamente àquele ponto. O dump roda dentro do contêiner com as credenciais dele; agentes usam db_snapshot pelo MCP.")
            : L("Para um banco fora de contêiner, o snapshot só funciona com acesso local sem senha.")
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear { if store.all.isEmpty { store.load() } }
    .confirmationDialog(L("Restaurar %@?", restoring?.database ?? ""), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
      Button(L("Restaurar"), role: .destructive) {
        if let s = restoring { store.restore(db, s) }
        restoring = nil
      }
      Button(L("Cancelar"), role: .cancel) { restoring = nil }
    } message: {
      Text(L("O banco %@ é apagado e recriado como estava em %@. O que mudou depois se perde.", restoring?.database ?? "", restoring.map { Date(timeIntervalSince1970: $0.created).formatted(date: .abbreviated, time: .shortened) } ?? ""))
    }
    .confirmationDialog(L("Apagar este snapshot?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button(L("Apagar"), role: .destructive) {
        if let s = deleting { store.delete(db, s) }
        deleting = nil
      }
      Button(L("Cancelar"), role: .cancel) { deleting = nil }
    }
  }
  private func choose() {
    let fromProbe = db.databases.map(\.name).filter { !["information_schema", "performance_schema", "mysql", "sys"].contains($0) }
    if !fromProbe.isEmpty {
      names = fromProbe
      chosen = fromProbe[0]
      choosing = true
      return
    }
    let request: [String: Any] = ["op": "databases", "port": db.port]
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.decode(request, as: [String].self)
      DispatchQueue.main.async {
        switch r {
        case .success(let list) where !list.isEmpty:
          names = list
          chosen = list[0]
          choosing = true
        case .success: break
        case .failure(let e): SnapshotStore.shared.reportError(db, e.message)
        }
      }
    }
  }
}

extension SnapshotStore {
  func reportError(_ db: DatabaseItem, _ message: String) { messages[db.id] = L("Falhou: %@", message) }
}

struct RedisDB: Identifiable { let id: Int }
