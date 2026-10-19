import SwiftUI

struct DatabaseSchema: Decodable, Hashable {
  let name: String
  let bytes: Double?
  let keys: Double?
}
struct LongQueryItem: Decodable, Hashable {
  let id: String
  let user: String
  let database: String
  let seconds: Double
  let query: String
}
/// One local database server as the core saw it (read-only).
struct DatabaseItem: Decodable, Identifiable {
  let kind: String
  let port: Int
  let label: String
  let container: String?
  /// Reachable from the Mac on 127.0.0.1:port (false: only inside its compose network).
  let published: Bool?
  let project: String?
  let service: String?
  /// "container" (read inside it with its own credentials), "password" (saved credentials).
  let via: String?
  var hostReachable: Bool { published ?? true }
  /// Keychain key for saved credentials.
  var credentialKey: String { "\(kind):\(port)" }
  let status: String
  let error: String?
  let version: String?
  let uptime: Double?
  let connections: Double?
  let slow_queries: Double?
  let size: Double?
  let databases: [DatabaseSchema]
  let long_queries: [LongQueryItem]
  var id: String { container.map { "\(kind):\($0)" } ?? "\(kind):\(port)" }
  var kindName: String {
    switch kind {
    case "mysql": "MySQL"
    case "postgres": "PostgreSQL"
    default: "Redis"
    }
  }
}

final class DatabaseStore: ObservableObject {
  static let shared = DatabaseStore()
  @Published private(set) var items: [DatabaseItem]?
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  @Published private(set) var readAt: Date?
  private let queue = DispatchQueue(label: "app.corescope.databases", qos: .userInitiated)

  func refresh() {
    guard !loading else { return }
    loading = true
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("databases", cost) }
      let result: Result<[DatabaseItem], Error> = Result {
        // Credentials the user saved for servers on this Mac, for this read only.
        let request = (try? JSONSerialization.data(withJSONObject: ["credentials": DBCredentials.all()])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let pointer = request.withCString({ cs_databases_with($0) }) else {
          throw NSError(domain: "CoreScope", code: 1, userInfo: [NSLocalizedDescriptionKey: L("O núcleo não retornou dados")])
        }
        defer { cs_free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = obj["error"] as? String {
          throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: L(error)])
        }
        return try JSONDecoder().decode([DatabaseItem].self, from: data)
      }
      DispatchQueue.main.async {
        self.loading = false
        self.readAt = Date()
        switch result {
        case .success(let items):
          self.items = items
          self.error = nil
        case .failure(let error): self.error = error.localizedDescription
        }
      }
    }
  }
}

struct DatabasesView: View {
  @ObservedObject var store = DatabaseStore.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text(L("MySQL/MariaDB, PostgreSQL e Redis encontrados em processos e contêineres locais."))
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          if store.loading { ProgressView().controlSize(.small) }
          Button {
            store.refresh()
          } label: {
            Label(L("Atualizar"), systemImage: "arrow.clockwise")
          }.disabled(store.loading)
        }
        if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
        if let items = store.items {
          if items.isEmpty {
            Card { EmptyNote(text: L("Nenhum MySQL, PostgreSQL ou Redis local em execução.")) }
          }
          // Grouped by compose project (a container group), servers on the Mac last.
          let groups = Dictionary(grouping: items) { $0.project ?? "" }
          ForEach(groups.keys.sorted { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a < b }, id: \.self) { project in
            if !project.isEmpty || groups.count > 1 {
              Label(project.isEmpty ? L("Neste Mac") : (Demo.enabled ? demoPick(["acme", "shop", "billing"], project) : project),
                    systemImage: project.isEmpty ? "desktopcomputer" : "shippingbox")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            }
            ForEach(groups[project] ?? []) { DatabaseCard(db: $0) }
          }
        } else if !store.loading {
          Card { EmptyNote(text: L("Procurando bancos locais…")) }
        }
        Text(
          L("Consultas só de leitura. Sem senha, pelo protocolo de cada banco em 127.0.0.1. Bancos em contêiner (com ou sem porta publicada) que pedem senha são lidos dentro do próprio contêiner, com as credenciais dele (MYSQL_ROOT_PASSWORD, POSTGRES_USER, REDIS_PASSWORD ou --requirepass): a senha não sai do contêiner. Para um servidor rodando direto no Mac, informe usuário e senha: ficam só no Keychain e vão para o cliente instalado (mysql, psql, redis-cli) pelo ambiente, nunca na linha de comando.")
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
    // Refreshes every 15 s while the page is on screen; nothing runs when it is not.
    .task {
      while !Task.isCancelled {
        store.refresh()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
      }
    }
  }
}

private struct DatabaseCard: View {
  let db: DatabaseItem
  @ViewState private var analyzing: Int?
  @ViewState private var askPassword = false
  @ViewBuilder private var viaNote: some View {
    switch db.via {
    case "container":
      Label(L("Lido dentro do contêiner, com as credenciais dele (a senha não sai do contêiner)."), systemImage: "shippingbox")
        .font(.caption).foregroundStyle(.secondary)
    case "password":
      HStack {
        Label(L("Lido com o usuário e a senha salvos no Keychain."), systemImage: "key").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(L("Esquecer senha")) {
          DBCredentials.delete(db.credentialKey)
          DatabaseStore.shared.refresh()
        }.controlSize(.small)
      }
    default: EmptyView()
    }
  }
  var body: some View {
    Card {
      HStack(spacing: 10) {
        Image(systemName: db.kind == "redis" ? "memorychip" : "cylinder.split.1x2")
          .font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
          .frame(width: 28, height: 28)
          .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(db.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Badge(text: db.kindName, color: tint)
            if db.hostReachable {
              Badge(text: ":\(db.port)", color: Tint.netIn)
            } else {
              Badge(text: L("sem porta no Mac"), color: .secondary).help(L("A porta %@ só existe na rede do compose; o CoreScope lê este banco de dentro do contêiner.", "\(db.port)"))
            }
            if db.container != nil { Badge(text: db.service ?? L("contêiner"), color: .secondary, symbol: "shippingbox") }
          }
          Text(
            [db.version.map { "v\($0)" }, db.uptime.map { L("no ar há %@", formatDuration($0)) }].compactMap { $0 }
              .joined(separator: " · ")
          ).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if db.status == "ok" {
          stat(db.kind == "redis" ? L("Memória") : L("Tamanho"), db.size.map(diskBytes) ?? "—")
          stat(L("Conexões"), db.connections.map { "\(Int($0))" } ?? "—")
          stat(db.kind == "redis" ? L("Slowlog") : L("Lentas"), db.slow_queries.map { "\(Int($0))" } ?? "—")
            .help(
              db.kind == "redis"
                ? L("Entradas no SLOWLOG do Redis") : L("Consultas acima do long_query_time desde que o servidor subiu"))
        }
        if db.hostReachable { DatabaseOpenMenu(db: db) }
      }
      switch db.status {
      case "ok":
        viaNote
        details
      case "auth":
        HStack {
          Label(
            db.error == nil || db.error == "Pede senha" ? L("Este servidor pede senha.") : L("Pede senha: %@", L(db.error ?? "")),
            systemImage: "lock"
          ).font(.callout).foregroundStyle(.orange)
          Spacer()
          if db.container == nil {
            Button(DBCredentials.has(db.credentialKey) ? L("Trocar senha…") : L("Informar senha…")) { askPassword = true }
              .controlSize(.small)
          }
        }
      default:
        Label(L(db.error ?? "Erro"), systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
      }
      // Snapshots run inside a container with its own credentials, so they also work where the
      // page itself cannot log in.
      if db.kind != "redis" && (db.status == "ok" || db.container != nil) {
        Divider()
        DatabaseSnapshotsSection(db: db)
      }
    }
    .sheet(item: Binding(get: { analyzing.map(RedisDB.init) }, set: { analyzing = $0?.id })) {
      RedisKeyspaceSheet(db: db, number: $0.id)
    }
    .sheet(isPresented: $askPassword) { DBCredentialSheet(db: db) }
  }
  private var tint: Color { db.status == "ok" ? Tint.brand : db.status == "auth" ? .orange : .red }
  @ViewBuilder private var details: some View {
    if !db.long_queries.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Label(L("Consultas rodando há mais de 5 s"), systemImage: "hourglass").font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        ForEach(db.long_queries, id: \.self) { q in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(Int(q.seconds)) s").font(.callout.weight(.semibold)).monospacedDigit().frame(width: 56, alignment: .trailing)
            Text(q.database.isEmpty ? "—" : q.database).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
              .lineLimit(1)
            Text(q.query).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
            Text(verbatim: "#\(q.id)").font(.caption2).foregroundStyle(.tertiary)
          }
        }
      }
    }
    if !db.databases.isEmpty {
      let top = Array(db.databases.prefix(10))
      let largest = max(top.compactMap { $0.bytes ?? $0.keys }.max() ?? 1, 1)
      VStack(alignment: .leading, spacing: 5) {
        ForEach(top, id: \.self) { s in
          HStack(spacing: 8) {
            Text(s.name).font(.callout).lineLimit(1).frame(width: 220, alignment: .leading)
            MeterBar(fraction: (s.bytes ?? s.keys ?? 0) / largest, color: Tint.brand.opacity(0.7)).frame(height: 5)
            Text(s.keys.map { L("%@ chaves", "\(Int($0))") } ?? s.bytes.map(diskBytes) ?? "—")
              .font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 90, alignment: .trailing)
            if db.kind == "redis", db.hostReachable, db.via == nil, let n = Int(s.name.dropFirst(2)) {
              Button(L("Analisar")) { analyzing = n }.controlSize(.small)
                .help(L("Chaves por prefixo, memória e chaves sem TTL (amostra)"))
            }
          }
        }
        if db.databases.count > top.count {
          Text(L("+ %@ bancos", "\(db.databases.count - top.count)")).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
  private func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }.frame(minWidth: 70, alignment: .trailing)
  }
}

/// User and password for a database server on this Mac, in the login Keychain (service
/// "local.corescope.db", one item per "kind:port"). Read only to hand them to the core for a
/// database read; never written to preferences, files or logs.
enum DBCredentials {
  private static let service = "local.corescope.db"
  static func has(_ key: String) -> Bool {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
  }
  @discardableResult static func save(_ key: String, user: String, password: String) -> Bool {
    delete(key)
    guard let data = try? JSONSerialization.data(withJSONObject: ["user": user, "password": password]) else { return false }
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
      kSecAttrLabel as String: "CoreScope · \(key)", kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }
  static func delete(_ key: String) {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    SecItemDelete(q as CFDictionary)
  }
  /// Every saved credential, "kind:port" → {user, password}.
  static func all() -> [String: [String: String]] {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [:] }
    var out: [String: [String: String]] = [:]
    for item in items {
      guard let key = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data,
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: String]
      else { continue }
      out[key] = value
    }
    return out
  }
}

/// Asks for the user and password of a database server on this Mac.
private struct DBCredentialSheet: View {
  let db: DatabaseItem
  @Environment(\.dismiss) private var dismiss
  @ViewState private var user = ""
  @ViewState private var password = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Senha de %@", "\(db.kindName) :\(db.port)")).font(.title3.weight(.semibold))
      Text(L("Fica só no Keychain do macOS. A cada leitura vai para o cliente instalado (mysql, psql ou redis-cli) pelo ambiente, nunca pela linha de comando, e as consultas são só de leitura."))
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      LabeledContent(L("Usuário")) {
        TextField("", text: $user, prompt: Text(db.kind == "mysql" ? "root" : db.kind == "postgres" ? "postgres" : L("(opcional)")))
          .labelsHidden().textFieldStyle(.roundedBorder)
      }
      LabeledContent(L("Senha")) {
        SecureField("", text: $password).labelsHidden().textFieldStyle(.roundedBorder)
      }
      HStack {
        if DBCredentials.has(db.credentialKey) {
          Button(L("Esquecer senha"), role: .destructive) {
            DBCredentials.delete(db.credentialKey)
            DatabaseStore.shared.refresh()
            dismiss()
          }
        }
        Spacer()
        Button(L("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L("Salvar e ler")) {
          DBCredentials.save(db.credentialKey, user: user.trimmingCharacters(in: .whitespaces), password: password)
          password = ""
          DatabaseStore.shared.refresh()
          dismiss()
        }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(password.isEmpty)
      }
    }
    .padding(18).frame(width: 440)
  }
}
