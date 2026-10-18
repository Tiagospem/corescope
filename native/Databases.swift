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
/// One local database server as the core saw it (read-only, no passwords).
struct DatabaseItem: Decodable, Identifiable {
  let kind: String
  let port: Int
  let label: String
  let container: String?
  let status: String
  let error: String?
  let version: String?
  let uptime: Double?
  let connections: Double?
  let slow_queries: Double?
  let size: Double?
  let databases: [DatabaseSchema]
  let long_queries: [LongQueryItem]
  var id: String { "\(kind):\(port)" }
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
        guard let pointer = cs_databases() else {
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
          ForEach(items) { DatabaseCard(db: $0) }
        } else if !store.loading {
          Card { EmptyNote(text: L("Procurando bancos locais…")) }
        }
        Text(
          L("Consultas só de leitura em 127.0.0.1, pelo protocolo de cada banco. O CoreScope nunca pede, guarda ou lê senhas: conecta apenas quando o servidor aceita acesso local sem senha (MySQL root sem senha, PostgreSQL com trust para o seu usuário, Redis sem AUTH) e, se não, mostra que pede senha. Cada consulta tem limite de tempo também no servidor.")
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
            Badge(text: ":\(db.port)", color: Tint.netIn)
            if db.container != nil { Badge(text: L("contêiner"), color: .secondary, symbol: "shippingbox") }
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
        DatabaseOpenMenu(db: db)
      }
      switch db.status {
      case "ok": details
      case "auth":
        Label(L("Pede senha: o CoreScope não usa senhas, então não lê este servidor."), systemImage: "lock")
          .font(.callout).foregroundStyle(.orange)
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
            if db.kind == "redis", let n = Int(s.name.dropFirst(2)) {
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
