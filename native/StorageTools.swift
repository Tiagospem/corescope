import AppKit
import SwiftUI

struct DiskHealth: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let status: String
  let verdict: String?
  let percentage_used: Int?
  let available_spare: Int?
  let spare_threshold: Int?
  let written_bytes: Double?
  let read_bytes: Double?
  let power_cycles: Int?
  let power_on_hours: Int?
  let unsafe_shutdowns: Int?
  let media_errors: Int?
  let notes: [String]
}

/// SSD health (NVMe SMART), read when the Storage page opens and every 10 minutes while it is
/// open: these counters change slowly.
final class DiskHealthStore: ObservableObject {
  static let shared = DiskHealthStore()
  @Published private(set) var disks: [String: DiskHealth] = [:]
  private var readAt = Date.distantPast
  private let queue = DispatchQueue(label: "app.corescope.diskhealth", qos: .utility)

  func refreshIfOld() {
    guard -readAt.timeIntervalSinceNow > 600 else { return }
    readAt = Date()
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("storage", cost) }
      var list: [DiskHealth] = []
      if let pointer = cs_disk_health() {
        list = (try? JSONDecoder().decode([DiskHealth].self, from: Data(bytes: pointer, count: strlen(pointer)))) ?? []
        cs_free(pointer)
      }
      let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      DispatchQueue.main.async { if byID != self.disks { self.disks = byID } }
    }
  }
}

/// Wear, writes and warnings under one disk in the Devices card.
struct DiskHealthLine: View {
  let health: DiskHealth
  var body: some View {
    if health.status != "ok" {
      Text(L("Sem dados de saúde (SMART NVMe %@).", L(health.status == "unsupported" ? "não exposto por este disco ou adaptador" : "indisponível")))
        .font(.caption).foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Badge(text: verdictText, color: verdictColor, symbol: verdictSymbol)
          if let used = health.percentage_used {
            Text(L("%@ da vida útil usada", "\(used)%")).font(.caption).monospacedDigit()
            MeterBar(fraction: min(1, Double(used) / 100), color: verdictColor).frame(width: 120)
          }
          Spacer()
        }
        Text(facts).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
        ForEach(health.notes, id: \.self) { note in
          Label(note, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(verdictColor)
        }
      }
      .help(L("Página SMART/Health do NVMe: percentual da resistência nominal usado, blocos de reserva, dados escritos e lidos (unidades de 512 000 bytes), ciclos, horas ligado, desligamentos inesperados e erros de mídia."))
    }
  }
  private var facts: String {
    var parts: [String] = []
    if let w = health.written_bytes { parts.append(L("%@ escritos", tb(w))) }
    if let r = health.read_bytes { parts.append(L("%@ lidos", tb(r))) }
    if let h = health.power_on_hours {
      parts.append(L("%@ h ligado", "\(h)"))
      if let w = health.written_bytes, h > 0 { parts.append(L("%@/h em média", formatBytes(w / Double(h)))) }
    }
    if let c = health.power_cycles { parts.append(L("%@ ciclos", "\(c)")) }
    if let u = health.unsafe_shutdowns { parts.append(L("%@ desligamentos inesperados", "\(u)")) }
    if let m = health.media_errors { parts.append(L("%@ erros de mídia", "\(m)")) }
    if let s = health.available_spare, let t = health.spare_threshold { parts.append(L("reserva %@ (mín. %@)", "\(s)%", "\(t)%")) }
    return parts.joined(separator: " · ")
  }
  private func tb(_ bytes: Double) -> String {
    bytes >= 1e12 ? String(format: "%.1f TB", bytes / 1e12) : String(format: "%.0f GB", bytes / 1e9)
  }
  private var verdictText: String {
    switch health.verdict {
    case "replace": L("trocar")
    case "watch": L("atenção")
    default: L("saudável")
    }
  }
  private var verdictColor: Color {
    switch health.verdict {
    case "replace": .red
    case "watch": .orange
    default: Tint.brand
    }
  }
  private var verdictSymbol: String {
    health.verdict == "good" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
  }
}

/// Processes reading and writing the most right now, from the collector's per-process counters.
struct DiskWritersCard: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    let top = (monitor.snapshot?.processes ?? [])
      .map { p in (p, (p.write.value ?? 0) + (p.read.value ?? 0)) }
      .filter { $0.1 >= 64 * 1024 }
      .sorted { $0.1 > $1.1 }
      .prefix(6)
    Card {
      CardHeader(title: L("Usando o disco agora"), symbol: "arrow.up.arrow.down.circle", tint: Tint.diskWrite, count: top.count) {
        Button(L("Ver no Histórico")) { AppLinks.show(.history) }.controlSize(.small)
      }
      if top.isEmpty {
        EmptyNote(text: L("Nenhum processo lendo ou escrevendo mais de 64 KB/s."))
      }
      ForEach(Array(top), id: \.0.id) { p, _ in
        ProcessLine(process: p, subtitle: devSubtitle(p)) {
          HStack(spacing: 10) {
            Label(p.write.rate, systemImage: "arrow.up").foregroundStyle(Tint.diskWrite)
            Label(p.read.rate, systemImage: "arrow.down").foregroundStyle(Tint.diskRead)
          }.font(.caption).monospacedDigit()
          KillButton(process: p)
        }
      }
      Text(L("Bytes lidos e escritos por processo desde a última amostra (rusage). Também: corescope top --disk e MCP top_processes by: disk."))
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct CleanupAction: Decodable, Identifiable, Equatable {
  let id: String
  let title: String
  let kind: String
  let command: String
  let argv: [String]
  let paths: [String]
  let docker_kind: String?
  let estimate: Double
  let up_to: Bool
  let busy: String?
  let note: String
}

/// The safe cleanup plan (core `cleanplan`) and running the actions the user picked: folders to
/// the Trash, commands in the login shell with their arguments quoted, Docker data through the
/// engine. Each action is re-checked for a busy tool right before it runs.
final class CleanupPlanStore: ObservableObject {
  static let shared = CleanupPlanStore()
  @Published private(set) var actions: [CleanupAction] = []
  @Published private(set) var loading = false
  @Published private(set) var running: Set<String> = []
  /// Outcome per action id ("freed 2.1 GB", "npm is running", the command's error).
  @Published private(set) var results: [String: String] = [:]
  @Published var selected: Set<String> = []
  private let queue = DispatchQueue(label: "app.corescope.cleanplan", qos: .utility)

  func load(then: (([CleanupAction]) -> Void)? = nil) {
    guard !loading else { return }
    loading = true
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("storage", cost) }
      let list = Self.plan()
      DispatchQueue.main.async {
        self.loading = false
        self.actions = list
        self.selected = self.selected.intersection(Set(list.map(\.id)))
        then?(list)
      }
    }
  }
  private static func plan() -> [CleanupAction] {
    guard let pointer = cs_cleanup_plan(1) else { return [] }
    defer { cs_free(pointer) }
    return (try? JSONDecoder().decode([CleanupAction].self, from: Data(bytes: pointer, count: strlen(pointer)))) ?? []
  }
  /// Runs the chosen actions one after the other; `done` gets id → outcome.
  func run(_ ids: Set<String>, done: (([String: String]) -> Void)? = nil) {
    let chosen = ids.subtracting(running)
    guard !chosen.isEmpty else {
      done?(Dictionary(uniqueKeysWithValues: ids.map { ($0, L("Já em execução.")) }))
      return
    }
    running.formUnion(chosen)
    queue.async {
      // Fresh estimates and busy checks right before running.
      let fresh = Self.plan()
      var outcomes: [String: String] = [:]
      for id in chosen {
        guard let action = fresh.first(where: { $0.id == id }) else {
          outcomes[id] = L("Nada a liberar agora.")
          continue
        }
        if let busy = action.busy {
          outcomes[id] = L("Não executado: %@ está em uso.", busy)
          continue
        }
        outcomes[id] = Self.perform(action)
      }
      DispatchQueue.main.async {
        self.running.subtract(chosen)
        self.results.merge(outcomes) { _, new in new }
        self.selected.subtract(chosen)
        self.load()
        DiskGrowthStore.shared.measure()
        done?(outcomes)
      }
    }
  }
  private static func perform(_ a: CleanupAction) -> String {
    switch a.kind {
    case "trash":
      var moved = 0
      var errors: [String] = []
      for path in a.paths {
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
          moved += 1
        } catch { errors.append("\(abbreviateHome(path)): \(error.localizedDescription)") }
      }
      return errors.isEmpty
        ? L("%@ na Lixeira.", formatBytes(a.estimate)) : errors.joined(separator: "; ")
    case "docker":
      guard let socket = a.paths.first, let kind = a.docker_kind,
        let pointer = socket.withCString({ s in kind.withCString { cs_dev_space_docker(s, $0) } })
      else { return L("Motor de contêineres não encontrado") }
      defer { cs_free(pointer) }
      let obj = (try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: strlen(pointer)))) as? [String: Any]
      if let error = obj?["error"] as? String { return L(error) }
      return L("%@ liberados.", formatBytes((obj?["reclaimed"] as? NSNumber)?.doubleValue ?? 0))
    default:
      let quoted = a.argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-lc", quoted]
      var env = ProcessInfo.processInfo.environment
      env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      process.environment = env
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch { return error.localizedDescription }
      let deadline = Date().addingTimeInterval(600)
      while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
      if process.isRunning {
        process.terminate()
        return L("Tempo esgotado (10 min).")
      }
      let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let tail = output.split(separator: "\n").suffix(2).joined(separator: " · ")
      return process.terminationStatus == 0
        ? L("Concluído. %@", tail) : L("Falhou (código %@): %@", "\(process.terminationStatus)", tail)
    }
  }
}

/// Free space safely: what tools re-create on demand, with what each action runs.
struct CleanupPlanCard: View {
  @ObservedObject var store = CleanupPlanStore.shared
  @ViewState private var confirming = false
  var body: some View {
    let chosen = store.actions.filter { store.selected.contains($0.id) && $0.busy == nil }
    Card {
      CardHeader(title: L("Liberar espaço com segurança"), symbol: "sparkles", tint: Tint.brand, count: store.actions.count) {
        if store.loading { ProgressView().controlSize(.small) }
        Button(L("Atualizar")) { store.load() }.controlSize(.small).disabled(store.loading)
        Button(L("Executar %@ (%@)", "\(chosen.count)", formatBytes(chosen.reduce(0) { $0 + $1.estimate }))) { confirming = true }
          .controlSize(.small).buttonStyle(.borderedProminent).disabled(chosen.isEmpty || !store.running.isEmpty)
      }
      if store.actions.isEmpty && !store.loading {
        EmptyNote(text: L("Nada a liberar nos caches conhecidos."))
      }
      ForEach(store.actions) { a in
        HStack(alignment: .top, spacing: 10) {
          Toggle("", isOn: Binding(
            get: { store.selected.contains(a.id) },
            set: { on in if on { store.selected.insert(a.id) } else { store.selected.remove(a.id) } }
          )).labelsHidden().disabled(a.busy != nil || store.running.contains(a.id))
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(a.title).font(.callout.weight(.medium))
              if a.kind == "docker" { Badge(text: L("permanente"), color: .orange) }
              if let busy = a.busy { Badge(text: L("em uso: %@", busy), color: .orange) }
            }
            Text(a.note).font(.caption).foregroundStyle(.secondary)
            Text(a.command).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
              .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            if let result = store.results[a.id] { Text(result).font(.caption).foregroundStyle(Tint.brand) }
          }
          Spacer(minLength: 6)
          if store.running.contains(a.id) {
            ProgressView().controlSize(.small)
          } else {
            Text((a.up_to ? "≤ " : "") + formatBytes(a.estimate)).monospacedDigit().font(.callout)
          }
        }
      }
      Text(
        L("Pastas vão para a Lixeira (recuperáveis); comandos rodam no seu shell com o caminho completo da ferramenta; dados do Docker são removidos pelo motor (sem volta). Uma ação cuja ferramenta está rodando não é executada. Também: corescope space --plan e MCP cleanup_plan / run_cleanup_plan.")
      ).font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { if store.actions.isEmpty { store.load() } }
    .confirmationDialog(L("Executar %@ ações?", "\(chosen.count)"), isPresented: $confirming) {
      Button(L("Executar"), role: .destructive) { store.run(Set(chosen.map(\.id))) }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(chosen.map { "• \($0.title): \($0.command)" }.joined(separator: "\n"))
    }
  }
}

struct BigFile: Decodable, Identifiable, Equatable {
  let path: String
  let bytes: Double
  let modified: Double
  let kind: String
  let managed_by: String?
  var id: String { path }
}
struct BigFileScan: Decodable, Equatable {
  let files: [BigFile]
  let scanned_files: Int
  let partial: Bool
  let seconds: Double
}

/// The largest files in the home folder: searched only when asked (the walk takes up to 90 s),
/// the result kept until the next search.
final class LargeFilesStore: ObservableObject {
  static let shared = LargeFilesStore()
  @Published private(set) var scan: BigFileScan?
  @Published private(set) var scannedAt: Date?
  @Published private(set) var scanning = false
  @Published var minMB: Double = 1024
  private let queue = DispatchQueue(label: "app.corescope.largefiles", qos: .utility)

  func search() {
    guard !scanning else { return }
    scanning = true
    let min = UInt64(minMB)
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("storage", cost) }
      var result: BigFileScan?
      if let pointer = cs_large_files(min, 100) {
        result = try? JSONDecoder().decode(BigFileScan.self, from: Data(bytes: pointer, count: strlen(pointer)))
        cs_free(pointer)
      }
      DispatchQueue.main.async {
        self.scanning = false
        self.scan = result
        self.scannedAt = Date()
      }
    }
  }
  /// Moves a file to the Trash (recoverable) and drops it from the list.
  func trash(_ file: BigFile) -> String? {
    guard file.managed_by == nil else { return L("Gerenciado por %@: remova pelo próprio app.", file.managed_by ?? "") }
    do {
      try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
      if let s = scan {
        scan = BigFileScan(files: s.files.filter { $0.path != file.path }, scanned_files: s.scanned_files, partial: s.partial, seconds: s.seconds)
      }
      return nil
    } catch { return error.localizedDescription }
  }
}

struct LargeFilesCard: View {
  @ObservedObject var store = LargeFilesStore.shared
  @ViewState private var pending: BigFile?
  @ViewState private var error: String?
  var body: some View {
    Card {
      CardHeader(title: L("Arquivos grandes"), symbol: "doc.zipper", tint: .orange, count: store.scan?.files.count) {
        Picker("", selection: $store.minMB) {
          Text("≥ 250 MB").tag(250.0)
          Text("≥ 500 MB").tag(500.0)
          Text("≥ 1 GB").tag(1024.0)
          Text("≥ 5 GB").tag(5120.0)
        }.labelsHidden().frame(width: 110).controlSize(.small)
        if store.scanning {
          ProgressView().controlSize(.small)
        } else {
          Button(store.scan == nil ? L("Procurar") : L("Procurar de novo")) { store.search() }.controlSize(.small)
        }
      }
      if let s = store.scan, let at = store.scannedAt {
        Text(
          L("%@ arquivos verificados em %@ s, %@.", "\(s.scanned_files)", String(format: "%.0f", s.seconds), at.formatted(date: .omitted, time: .shortened))
            + (s.partial ? " " + L("Parou no limite de tempo: pode faltar algum.") : "")
        ).font(.caption).foregroundStyle(.secondary)
        if s.files.isEmpty { EmptyNote(text: L("Nenhum arquivo acima do tamanho escolhido.")) }
        ForEach(s.files.prefix(40)) { f in
          HStack(spacing: 10) {
            Image(systemName: symbol(f.kind)).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
              Text((f.path as NSString).lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
              HStack(spacing: 6) {
                Text(abbreviateHome((f.path as NSString).deletingLastPathComponent)).lineLimit(1).truncationMode(.middle)
                Text("·")
                Text(Date(timeIntervalSince1970: f.modified), format: .relative(presentation: .named))
              }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let owner = f.managed_by { Badge(text: owner, color: .secondary).help(L("Gerenciado por %@: remova pelo próprio app.", owner)) }
            Text(formatBytes(f.bytes)).monospacedDigit().font(.callout)
            Button {
              let p = Process()
              p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
              p.arguments = ["-p", f.path]
              p.standardOutput = FileHandle.nullDevice
              p.standardError = FileHandle.nullDevice
              try? p.run()
            } label: { Image(systemName: "eye") }.buttonStyle(HoverButtonStyle()).help(L("Pré-visualizar (Quick Look)"))
            Button {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
            } label: { Image(systemName: "folder") }.buttonStyle(HoverButtonStyle()).help(L("Mostrar no Finder"))
            Button { pending = f } label: { Image(systemName: "trash") }
              .buttonStyle(HoverButtonStyle(tint: .red)).disabled(f.managed_by != nil).help(L("Mover para a Lixeira"))
          }
        }
      } else if !store.scanning {
        EmptyNote(text: L("Procura na sua pasta pessoal (e nas pastas que ela aponta para outros discos) os maiores arquivos: imagens de disco, vídeos, VMs, dumps e modelos. Fica fora: nuvem (OneDrive, iCloud), node_modules, .git e outros volumes montados."))
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      Text(L("Também: corescope large-files e MCP large_files. Arquivos de apps (Docker, OrbStack, Claude, Photos, Hugging Face…) só aparecem: remova pelo próprio app."))
        .font(.caption).foregroundStyle(.secondary)
    }
    .confirmationDialog(L("Mover para a Lixeira?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
      Button(L("Mover %@ para a Lixeira", formatBytes(pending?.bytes ?? 0)), role: .destructive) {
        if let f = pending { error = store.trash(f) }
        pending = nil
      }
      Button(L("Cancelar"), role: .cancel) { pending = nil }
    } message: {
      Text(pending.map { abbreviateHome($0.path) } ?? "")
    }
  }
  private func symbol(_ kind: String) -> String {
    switch kind {
    case "disk image": "opticaldiscdrive"
    case "video": "film"
    case "archive": "archivebox"
    case "virtual machine": "desktopcomputer"
    case "database dump": "cylinder.split.1x2"
    case "model": "brain"
    case "log": "doc.text"
    default: "doc"
    }
  }
}

struct VolumeHolder: Decodable, Identifiable, Equatable {
  let pid: Int32
  let name: String
  let reason: String
  let files: Int
  let example: String
  let eligible: Bool
  let origin: String?
  var id: Int32 { pid }
}

enum VolumeEject {
  /// Mounts ejected moments ago, hidden from lists until the inventory stops showing them
  /// (or 2 minutes pass, if the volume came back).
  static var ejected: [String: Date] = [:]
  static func visible(_ volumes: [Volume]) -> [Volume] {
    ejected = ejected.filter { mount, at in -at.timeIntervalSinceNow < 120 && volumes.contains { $0.mount == mount } }
    return volumes.filter { ejected[$0.mount] == nil }
  }
  static func holders(_ mount: String) -> [VolumeHolder] {
    guard let pointer = mount.withCString({ cs_volume_holders($0) }) else { return [] }
    defer { cs_free(pointer) }
    return (try? JSONDecoder().decode([VolumeHolder].self, from: Data(bytes: pointer, count: strlen(pointer)))) ?? []
  }
  /// `diskutil eject`; nil on success, else what diskutil said (it names system services that
  /// hold the volume, which CoreScope cannot see).
  static func eject(_ mount: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["eject", mount]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return error.localizedDescription }
    p.waitUntilExit()
    let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return p.terminationStatus == 0 ? nil : (text.isEmpty ? L("Falhou ao ejetar.") : text)
  }
}

/// Who holds a volume, with a stop button per process, and the eject itself.
struct EjectSheet: View {
  let mount: String
  @ObservedObject var monitor = Monitor.shared
  @Environment(\.dismiss) private var dismiss
  @ViewState private var holders: [VolumeHolder] = []
  @ViewState private var loading = false
  @ViewState private var message: String?
  @ViewState private var ejected = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Ejetar %@", (mount as NSString).lastPathComponent)).font(.title3.weight(.semibold))
      if ejected {
        Label(L("Ejetado. Já pode desconectar."), systemImage: "checkmark.circle.fill").foregroundStyle(Tint.brand)
      } else if loading {
        ProgressView(L("Procurando o que usa o volume…"))
      } else if holders.isEmpty {
        Text(L("Nenhum processo seu usa este volume.")).foregroundStyle(.secondary)
      } else {
        Text(L("%@ processos usam este volume:", "\(holders.count)")).font(.callout)
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(holders) { h in
              HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                  Text("\(h.name) · PID \(h.pid)").font(.callout.weight(.medium))
                  Text(reasonText(h) + " — " + abbreviateHome(h.example)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let p = monitor.snapshot?.process(pid: h.pid) { KillButton(process: p) }
              }
            }
          }
        }.frame(maxHeight: 280)
      }
      if let message { Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      Text(L("Serviços do sistema (como o Spotlight) também podem segurar um volume; o macOS diz quais se a ejeção falhar."))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(L("Atualizar")) { load() }.disabled(loading || ejected)
        Spacer()
        Button(ejected ? L("Fechar") : L("Cancelar")) { dismiss() }
        if !ejected {
          Button(holders.isEmpty ? L("Ejetar") : L("Tentar ejetar mesmo assim")) { eject() }
            .buttonStyle(.borderedProminent).disabled(loading)
        }
      }
    }
    .padding(18).frame(width: 520)
    .onAppear { load() }
  }
  private func reasonText(_ h: VolumeHolder) -> String {
    switch h.reason {
    case "program": L("roda a partir do volume")
    case "working folder": L("pasta de trabalho no volume")
    default: h.files > 1 ? L("%@ arquivos abertos", "\(h.files)") : L("arquivo aberto")
    }
  }
  private func load() {
    loading = true
    message = nil
    let mount = mount
    DispatchQueue.global(qos: .userInitiated).async {
      let list = VolumeEject.holders(mount)
      DispatchQueue.main.async {
        holders = list
        loading = false
      }
    }
  }
  private func eject() {
    loading = true
    let mount = mount
    DispatchQueue.global(qos: .userInitiated).async {
      let error = VolumeEject.eject(mount)
      DispatchQueue.main.async {
        loading = false
        if let error {
          message = error
          load()
        } else {
          ejected = true
          // Off the list now, and the inventory re-read on the next sample (not 30 s later).
          VolumeEject.ejected[mount] = Date()
          Monitor.shared.refreshVolumes()
        }
      }
    }
  }
}

struct MountID: Identifiable { let id: String }
