import AppKit
import SwiftUI

/// What the core read from a dump (`dump_analyze`).
struct DumpAnalysis: Decodable, Equatable {
  struct Table: Decodable, Equatable, Identifiable {
    let name: String
    let rows: Double
    let data_bytes: Double
    var id: String { name }
  }
  struct LeftOut: Decodable, Equatable {
    let kind: String
    let count: Double
  }
  let file: String
  let bytes: Double
  let compressed: Bool
  let dialect: String
  let tool: String?
  let server_version: String?
  let source_database: String?
  let statements: Double
  let tables: [Table]
  let total_rows: Double
  let views: Double
  let triggers: Double
  let routines: Double
  let events: Double
  let definers: [String]
  let left_out: [LeftOut]
  let notes: [String]
}

/// An analysis or restore running in the core (`dump_job`).
struct DumpJob: Decodable, Equatable, Identifiable {
  let id: String
  let kind: String
  let state: String
  let phase: String
  let fraction: Double
  let table: String?
  let file: String
  let target: String?
  let started: Double
  let ended: Double?
  let error: String?
  let log: [String]
  let log_file: String?
  let database_touched: Bool
  /// A finished restore's outcome (an analysis job's result is the analysis: left nil here).
  let outcome: DumpOutcome?
  var running: Bool { state == "running" }
  enum CodingKeys: String, CodingKey {
    case id, kind, state, phase, fraction, table, file, target, started, ended, error, log, log_file, database_touched, result
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    kind = try c.decode(String.self, forKey: .kind)
    state = try c.decode(String.self, forKey: .state)
    phase = try c.decode(String.self, forKey: .phase)
    fraction = try c.decode(Double.self, forKey: .fraction)
    table = try c.decodeIfPresent(String.self, forKey: .table)
    file = try c.decode(String.self, forKey: .file)
    target = try c.decodeIfPresent(String.self, forKey: .target)
    started = try c.decode(Double.self, forKey: .started)
    ended = try c.decodeIfPresent(Double.self, forKey: .ended)
    error = try c.decodeIfPresent(String.self, forKey: .error)
    log = try c.decode([String].self, forKey: .log)
    log_file = try c.decodeIfPresent(String.self, forKey: .log_file)
    database_touched = try c.decode(Bool.self, forKey: .database_touched)
    outcome = kind == "restore" ? try? c.decode(DumpOutcome.self, forKey: .result) : nil
  }
}
struct DumpOutcome: Decodable, Equatable {
  let target: String
  let created: Bool
  let seconds: Double
  let statements: Double
  let rows_skipped: Double
  let tables_without_data: [String]
  let definers_replaced: Double
  let left_out: Double
  let snapshot: String?
  let tables_in_database: Double?
}

/// Dump restores of the Databases page: which card a job belongs to, the sheet on screen, and
/// the jobs started through MCP (shown on their card too).
final class DumpRestoreStore: ObservableObject {
  static let shared = DumpRestoreStore()
  /// The card whose restore sheet is open (database id) and the database it was opened on.
  @Published var presenting: (db: String, preselect: String?)?
  /// The latest restore per card (database id → job id).
  @Published private(set) var latest: [String: String] = [:]
  @Published private(set) var jobs: [String: DumpJob] = [:]
  private var timer: Timer?

  func present(_ db: DatabaseItem, preselect: String? = nil) { presenting = (db.id, preselect) }
  func adopt(_ job: String, for db: String) {
    latest[db] = job
    poll()
  }
  func job(_ id: String?) -> DumpJob? { id.flatMap { jobs[$0] } }
  /// Forget a card's finished restore (to start another).
  func clear(_ db: String) { latest[db] = nil }

  /// Reads the jobs once a second while one runs (half a second for the open sheet).
  func poll() {
    timer?.invalidate()
    let wanted = Set(latest.values)
    DispatchQueue.global(qos: .userInitiated).async {
      var next: [String: DumpJob] = [:]
      for id in wanted {
        if case .success(let j) = DBTool.decode(["op": "dump_job", "job": id], as: DumpJob.self) { next[id] = j }
      }
      DispatchQueue.main.async {
        if next != self.jobs {
          let finished = next.values.contains { job in job.kind == "restore" && !job.running && self.jobs[job.id]?.running == true }
          self.jobs = next
          if finished { DatabaseStore.shared.refresh() }
        }
        if next.values.contains(where: \.running) || self.presenting != nil {
          self.timer = Timer.scheduledTimer(withTimeInterval: self.presenting != nil ? 0.5 : 1, repeats: false) { [weak self] _ in self?.poll() }
        }
      }
    }
  }
  func track(_ job: String) {
    jobs[job] = nil
    poll()
  }
  func cancel(_ job: String) {
    DispatchQueue.global(qos: .userInitiated).async { _ = DBTool.call(["op": "dump_cancel", "job": job]) }
  }
}

/// A dump restore, step by step: choose the file, read it, choose where it goes and which
/// tables come without data, then follow the restore.
struct DumpRestoreSheet: View {
  let db: DatabaseItem
  let preselect: String?
  let close: () -> Void
  @ObservedObject var store = DumpRestoreStore.shared
  @ViewState private var file: URL?
  @ViewState private var analysisJob: String?
  @ViewState private var analysis: DumpAnalysis?
  @ViewState private var analysisError: String?
  @ViewState private var replace = true
  @ViewState private var existing = ""
  @ViewState private var newName = ""
  @ViewState private var snapshotFirst = true
  @ViewState private var dropTriggers = false
  @ViewState private var dropOwners = true
  @ViewState private var withData: Set<String> = []
  @ViewState private var threshold = "100000"
  @ViewState private var search = ""
  @ViewState private var confirming = false
  @ViewState private var startError: String?

  private var restoreJob: DumpJob? { store.job(store.latest[db.id]).flatMap { $0.kind == "restore" ? $0 : nil } }
  private var names: [String] {
    db.databases.map(\.name).filter {
      !["information_schema", "performance_schema", "mysql", "sys", "postgres", "template0", "template1"].contains($0)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "square.and.arrow.down.on.square").font(.title2).foregroundStyle(Tint.brand)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("Restaurar dump em %@", db.label)).font(.title3.weight(.semibold))
          Text([db.kindName, db.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      Divider()
      if let job = restoreJob, job.running || store.latest[db.id] != nil && analysis == nil {
        progress(job)
      } else if let analysis {
        configure(analysis)
      } else if let id = analysisJob {
        reading(store.job(id))
      } else {
        pick
      }
    }
    .padding(20)
    .frame(width: 760, height: 640, alignment: .topLeading)
    .onAppear { store.poll() }
    .onChange(of: store.job(analysisJob)) { _, job in
      guard let job, !job.running else { return }
      analysisJob = nil
      if job.state == "succeeded" { loadAnalysis(job) } else { analysisError = job.error ?? L("Falhou") }
    }
  }

  // MARK: steps

  private var pick: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Escolha um dump .sql ou .sql.gz do mysqldump, mariadb-dump ou pg_dump (formato texto). Ele é lido antes de qualquer mudança: tabelas, linhas, triggers e o que fica de fora."))
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Button {
        choose()
      } label: {
        Label(L("Escolher arquivo…"), systemImage: "doc.badge.plus").frame(maxWidth: .infinity).padding(.vertical, 18)
      }
      .buttonStyle(.bordered)
      if let analysisError {
        Label(analysisError, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout).textSelection(.enabled)
      }
      Spacer()
      HStack {
        Spacer()
        Button(L("Cancelar"), action: close).keyboardShortcut(.cancelAction)
      }
    }
  }

  private func reading(_ job: DumpJob?) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(file?.lastPathComponent ?? "").font(.headline)
      ProgressView(value: job?.fraction ?? 0) {
        Text(L("Lendo o dump…")).font(.callout)
      } currentValueLabel: {
        Text(job?.table.map { L("tabela %@", $0) } ?? " ").font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      HStack {
        Spacer()
        Button(L("Cancelar")) {
          if let id = analysisJob { store.cancel(id) }
          analysisJob = nil
        }
      }
    }
  }

  @ViewBuilder private func configure(_ a: DumpAnalysis) -> some View {
    let targetName = replace ? existing : newName
    let nameProblem = nameError(targetName)
    let visible = a.tables.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    let importing = a.tables.filter { withData.contains($0.name) }
    VStack(alignment: .leading, spacing: 12) {
      // What the dump holds.
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Image(systemName: "doc.zipper").foregroundStyle(.secondary)
          Text((a.file as NSString).lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
          Text(formatBytes(a.bytes)).font(.caption).foregroundStyle(.secondary)
          Button(L("Trocar")) {
            analysis = nil
            choose()
          }.buttonStyle(.link).font(.caption)
        }
        Text(
          [
            a.tool ?? (a.dialect == "postgres" ? "PostgreSQL" : "MySQL"),
            a.source_database.map { L("do banco %@", $0) },
            L("%@ tabelas", "\(a.tables.count)"),
            L("%@ linhas", compactNumber(a.total_rows)),
            a.views > 0 ? L("%@ views", "\(Int(a.views))") : nil,
            a.triggers > 0 ? L("%@ triggers", "\(Int(a.triggers))") : nil,
            a.routines + a.events > 0 ? L("%@ rotinas", "\(Int(a.routines + a.events))") : nil,
          ].compactMap { $0 }.joined(separator: " · ")
        ).font(.caption).foregroundStyle(.secondary)
        if !a.left_out.isEmpty || !a.definers.isEmpty {
          Text(
            [
              a.left_out.isEmpty ? nil : L("Fica de fora: %@", a.left_out.map { "\($0.kind) (\(Int($0.count)))" }.joined(separator: ", ")),
              a.definers.isEmpty ? nil : L("DEFINER de contas que não existem aqui vira CURRENT_USER: %@", a.definers.joined(separator: ", ")),
            ].compactMap { $0 }.joined(separator: ". ")
          ).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
        }
        ForEach(a.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
      }
      // Where it goes.
      VStack(alignment: .leading, spacing: 8) {
        Picker("", selection: $replace) {
          Text(L("Substituir um banco existente")).tag(true)
          Text(L("Criar um banco novo")).tag(false)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
        HStack(spacing: 10) {
          if replace {
            Picker(L("Banco"), selection: $existing) {
              ForEach(names, id: \.self) { Text($0).tag($0) }
            }.frame(maxWidth: 320)
            Toggle(L("Snapshot antes"), isOn: $snapshotFirst).help(L("Dump do banco atual antes de apagá-lo: dá para voltar em Snapshots."))
          } else {
            TextField(L("Nome do banco novo"), text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
          }
          if a.triggers > 0 {
            Toggle(L("Sem triggers"), isOn: $dropTriggers).help(L("Não cria as %@ triggers do dump (auditoria de produção, por exemplo).", "\(Int(a.triggers))"))
          }
          if a.dialect == "postgres" {
            Toggle(L("Ignorar donos"), isOn: $dropOwners).help(L("Deixa de fora ALTER … OWNER TO: os papéis de produção raramente existem aqui."))
          }
        }
        if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.orange) }
      }
      // Which tables bring their data.
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text(L("Dados por tabela")).font(.callout.weight(.semibold))
          Text(L("sem marca = criada vazia")).font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button(L("Todas")) { withData = Set(a.tables.map(\.name)) }.controlSize(.small)
          Button(L("Nenhuma")) { withData = [] }.controlSize(.small)
          Text(L("Sem dados acima de")).font(.caption)
          TextField("", text: $threshold).textFieldStyle(.roundedBorder).frame(width: 80).controlSize(.small)
          Text(L("linhas")).font(.caption)
          Button(L("Aplicar")) {
            let limit = Double(threshold.filter(\.isNumber)) ?? 0
            withData = Set(a.tables.filter { $0.rows <= limit }.map(\.name))
          }.controlSize(.small)
        }
        TextField(L("Filtrar tabelas"), text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
        let largest = max(a.tables.map(\.rows).max() ?? 1, 1)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(visible) { t in
              HStack(spacing: 8) {
                Toggle(
                  "",
                  isOn: Binding(
                    get: { withData.contains(t.name) },
                    set: { on in if on { withData.insert(t.name) } else { withData.remove(t.name) } })
                ).toggleStyle(.checkbox).labelsHidden()
                Text(t.name).font(.callout).lineLimit(1).frame(width: 260, alignment: .leading)
                  .foregroundStyle(withData.contains(t.name) ? Color.primary : .secondary)
                MeterBar(fraction: t.rows / largest, color: rowColor(t.rows).opacity(0.7)).frame(height: 4)
                Text(L("%@ linhas", compactNumber(t.rows))).font(.caption).monospacedDigit().foregroundStyle(rowColor(t.rows))
                  .frame(width: 90, alignment: .trailing)
                Text(formatBytes(t.data_bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
              }
              .padding(.vertical, 1)
            }
          }
        }
        .frame(maxHeight: .infinity)
        .padding(6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        Text(
          L(
            "%@ de %@ tabelas com dados · %@ linhas · %@ a importar", "\(importing.count)", "\(a.tables.count)",
            compactNumber(importing.reduce(0) { $0 + $1.rows }), formatBytes(importing.reduce(0) { $0 + $1.data_bytes }))
        ).font(.caption).foregroundStyle(.secondary)
      }
      if let startError { Label(startError, systemImage: "xmark.octagon").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button(L("Cancelar"), action: close).keyboardShortcut(.cancelAction)
        Button(replace ? L("Substituir %@…", targetName) : L("Criar %@", targetName)) {
          if replace { confirming = true } else { start(a, target: targetName) }
        }
        .buttonStyle(.borderedProminent)
        .tint(replace ? .red : Tint.brand)
        .disabled(nameProblem != nil || targetName.isEmpty)
      }
    }
    .confirmationDialog(L("Substituir %@?", targetName), isPresented: $confirming, titleVisibility: .visible) {
      Button(L("Substituir"), role: .destructive) { start(a, target: targetName) }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(
        snapshotFirst
          ? L("O banco %@ é apagado e recriado a partir do dump. Antes, um snapshot dele vai para Snapshots.", targetName)
          : L("O banco %@ é apagado e recriado a partir do dump, sem snapshot: o conteúdo atual se perde.", targetName))
    }
  }

  @ViewBuilder private func progress(_ job: DumpJob) -> some View {
    let outcome = job.outcome
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        if job.running {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: job.state == "succeeded" ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(job.state == "succeeded" ? .green : .red).font(.title2)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title(job)).font(.headline)
          Text((job.file as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
        }
      }
      if job.running {
        if job.phase == "finishing" {
          ProgressView { Text(phaseLabel(job.phase)).font(.callout) }.progressViewStyle(.linear)
        } else {
          ProgressView(value: job.fraction) {
            Text(phaseLabel(job.phase)).font(.callout)
          } currentValueLabel: {
            Text(job.table.map { L("tabela %@", $0) } ?? " ").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if let outcome {
        Text(
          [
            L("%@ instruções em %@", compactNumber(outcome.statements), formatDuration(outcome.seconds)),
            outcome.tables_in_database.map { L("%@ tabelas no banco", "\(Int($0))") },
            outcome.tables_without_data.isEmpty ? nil : L("%@ tabelas sem dados (%@ linhas)", "\(outcome.tables_without_data.count)", compactNumber(outcome.rows_skipped)),
            outcome.definers_replaced > 0 ? L("%@ DEFINER → CURRENT_USER", "\(Int(outcome.definers_replaced))") : nil,
            outcome.snapshot.map { L("snapshot antes: %@", $0) },
          ].compactMap { $0 }.joined(separator: " · ")
        ).font(.callout).fixedSize(horizontal: false, vertical: true)
      }
      if let error = job.error, !job.running {
        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        if job.database_touched {
          Text(L("O banco %@ pode ter ficado incompleto: restaure de novo, ou volte o snapshot em Snapshots.", job.target ?? ""))
            .font(.caption).foregroundStyle(.orange)
        }
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(job.log.suffix(200).enumerated()), id: \.offset) { i, line in
              Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).id(i)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: job.log.count) { _, _ in proxy.scrollTo(min(job.log.count, 200) - 1, anchor: .bottom) }
      }
      HStack {
        if let log = job.log_file {
          Button(L("Ver log")) { LogViewer.open(URL(fileURLWithPath: log), title: title(job)) }
        }
        Spacer()
        if job.running {
          Button(L("Cancelar restauração"), role: .destructive) { store.cancel(job.id) }
          Button(L("Fechar")) { close() }.help(L("A restauração continua; o card do banco mostra o progresso."))
        } else {
          Button(L("Nova restauração")) {
            store.clear(db.id)
            analysis = nil
            file = nil
          }
          Button(L("Fechar"), action: close).keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  // MARK: helpers

  private func choose() {
    let panel = NSOpenPanel()
    panel.title = L("Escolha o dump")
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    file = url
    analysisError = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.call(["op": "dump_analyze", "file": url.path, "kind": db.kind])
      DispatchQueue.main.async {
        switch r {
        case .failure(let e): analysisError = e.message
        case .success(let v):
          guard let id = (v as? [String: Any])?["job"] as? String else { return }
          analysisJob = id
          store.track(id)
          store.adopt(id, for: "analysis:\(db.id)")
        }
      }
    }
  }
  private func loadAnalysis(_ job: DumpJob) {
    // The job's result is the analysis; read it again in full (cached in the core).
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.decode(["op": "dump_analyze", "file": job.file, "kind": db.kind, "wait": true], as: DumpAnalysis.self)
      DispatchQueue.main.async {
        switch r {
        case .failure(let e): analysisError = e.message
        case .success(let a):
          analysis = a
          withData = Set(a.tables.map(\.name))
          let source = a.source_database ?? ""
          existing = preselect.flatMap { names.contains($0) ? $0 : nil } ?? (names.contains(source) ? source : names.first ?? "")
          replace = preselect != nil || names.contains(source)
          newName = names.contains(source) || source.isEmpty ? "\(source.isEmpty ? "restored" : source)_copy" : source
          dropTriggers = false
        }
      }
    }
  }
  private func start(_ a: DumpAnalysis, target: String) {
    startError = nil
    var request: [String: Any] = [
      "op": "dump_restore", "file": a.file, "target": target, "mode": replace ? "replace" : "create",
      "skip_data": a.tables.map(\.name).filter { !withData.contains($0) }, "drop_triggers": dropTriggers,
      "drop_owners": dropOwners, "snapshot_first": replace && snapshotFirst,
    ]
    if let c = db.container { request["container"] = c } else { request["port"] = db.port }
    if db.container == nil, let cred = DBCredentials.all()[db.credentialKey] {
      request["user"] = cred["user"]
      request["password"] = cred["password"]
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let r = DBTool.call(request)
      DispatchQueue.main.async {
        switch r {
        case .failure(let e): startError = e.message
        case .success(let v):
          guard let id = (v as? [String: Any])?["job"] as? String else { return }
          store.adopt(id, for: db.id)
          analysis = nil
        }
      }
    }
  }
  private func nameError(_ name: String) -> String? {
    if name.isEmpty { return replace ? L("Escolha o banco a substituir.") : L("Dê um nome ao banco novo.") }
    if name.count > 64 || !name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
      return L("Use letras, números e _ (até 64).")
    }
    if !replace && names.contains(name) { return L("%@ já existe: escolha substituir, ou outro nome.", name) }
    return nil
  }
  private func title(_ job: DumpJob) -> String {
    switch job.state {
    case "running": return L("Restaurando em %@", job.target ?? "")
    case "succeeded": return L("%@ restaurado", job.target ?? "")
    case "cancelled": return L("Restauração cancelada")
    default: return L("A restauração falhou")
    }
  }
  private func phaseLabel(_ phase: String) -> String {
    switch phase {
    case "analyzing": return L("Lendo o dump…")
    case "snapshot": return L("Snapshot antes de substituir…")
    case "preparing": return L("Preparando o banco…")
    case "importing": return L("Importando…")
    case "finishing": return L("Tudo enviado; o servidor está terminando…")
    case "checking": return L("Conferindo…")
    default: return phase
    }
  }
  private func rowColor(_ rows: Double) -> Color {
    rows >= 1_000_000 ? .red : rows >= 100_000 ? .orange : rows >= 1_000 ? Tint.brand : .secondary
  }
}

/// 1234 → "1.2k", 3_400_000 → "3.4M".
func compactNumber(_ n: Double) -> String {
  switch n {
  case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
  case 10_000...: return String(format: "%.0fk", n / 1_000)
  case 1_000...: return String(format: "%.1fk", n / 1_000)
  default: return "\(Int(n))"
  }
}

/// A restore of this card running or just finished (also one started through MCP).
struct DumpRestoreBanner: View {
  let db: DatabaseItem
  @ObservedObject var store = DumpRestoreStore.shared
  var body: some View {
    if let job = store.job(store.latest[db.id]), job.kind == "restore" {
      HStack(spacing: 8) {
        if job.running {
          ProgressView(value: job.fraction).frame(width: 120)
          Text(L("Restaurando em %@", job.target ?? "")).font(.caption)
          if let t = job.table { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        } else {
          Image(systemName: job.state == "succeeded" ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(job.state == "succeeded" ? .green : .red)
          Text(job.state == "succeeded" ? L("%@ restaurado", job.target ?? "") : (job.error ?? L("A restauração falhou")))
            .font(.caption).lineLimit(1)
        }
        Spacer()
        Button(L("Ver")) { store.present(db) }.controlSize(.small)
      }
    }
  }
}
