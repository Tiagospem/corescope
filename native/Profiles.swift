import AppKit
import SwiftUI

/// A project's dev environment: the commands to run in its folder and the containers it needs.
struct EnvProfile: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var folder: String
  var commands: [ProfileCommand] = []
  /// Container names, started and stopped with the profile.
  var containers: [String] = []
}
struct ProfileCommand: Codable, Identifiable, Equatable {
  var id = UUID()
  var name: String
  var command: String
}
/// A command CoreScope started, identified like everywhere else by PID + start time.
struct LaunchedCommand: Codable, Equatable {
  let pid: Int32
  let start: UInt64
  let log: String
}

/// Starts profile commands through the user's login shell in the project folder (output to a
/// log file) and their containers through the local engine. Stopping signals only the trees
/// CoreScope itself started, with the same identity checks as every other termination.
final class ProfileStore: ObservableObject {
  static let shared = ProfileStore()
  @Published var profiles: [EnvProfile] {
    didSet { persist(profiles, "envProfiles") }
  }
  /// Command id → the process started for it.
  @Published private(set) var launched: [UUID: LaunchedCommand] {
    didSet { persist(launched, "envLaunched") }
  }
  @Published private(set) var busy = Set<UUID>()
  private let queue = DispatchQueue(label: "app.corescope.profiles", qos: .userInitiated)
  static let logs = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CoreScope/logs")

  private init() {
    profiles = Self.load([EnvProfile].self, "envProfiles") ?? []
    launched = (Self.load([UUID: LaunchedCommand].self, "envLaunched") ?? [:]).filter {
      cs_is_same($0.value.pid, $0.value.start) == 1
    }
  }
  private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
  private func persist<T: Encodable>(_ value: T, _ key: String) {
    if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
  }

  /// The running process for a command, if CoreScope started it and it is still the same one.
  func running(_ command: ProfileCommand) -> LaunchedCommand? {
    guard let l = launched[command.id], cs_is_same(l.pid, l.start) == 1 else { return nil }
    return l
  }
  func runningCount(_ profile: EnvProfile, containers: [ContainerItem]) -> Int {
    profile.commands.filter { running($0) != nil }.count
      + profile.containers.filter { name in containers.contains { $0.name == name && $0.running } }.count
  }
  func logURL(_ profile: EnvProfile, _ command: ProfileCommand) -> URL {
    Self.logs.appendingPathComponent("\(profile.id.uuidString.prefix(8))-\(Self.slug(command.name)).log")
  }
  private static func slug(_ s: String) -> String {
    String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
  }

  func start(_ profile: EnvProfile) {
    guard !busy.contains(profile.id) else { return }
    busy.insert(profile.id)
    let monitor = Monitor.shared
    monitor.feedback = ActionFeedback(message: L("Iniciando %@…", profile.name), pending: true)
    let pending = profile.commands.filter { running($0) == nil }
    queue.async {
      var errors: [String] = []
      var started: [UUID: LaunchedCommand] = [:]
      for command in pending {
        switch self.launch(profile, command) {
        case .success(let l): started[command.id] = l
        case .failure(let e): errors.append("\(command.name): \(e.description)")
        }
      }
      errors += Self.containers(profile.containers, action: "start")
      DispatchQueue.main.async {
        self.launched.merge(started) { _, new in new }
        self.busy.remove(profile.id)
        ContainerStore.shared.refreshSoon()
        monitor.refresh()
        monitor.feedback = ActionFeedback(
          message: errors.first.map { L("%@: %@", profile.name, $0) } ?? L("%@ iniciado.", profile.name),
          failed: !errors.isEmpty)
      }
    }
  }

  /// Runs after the user confirmed: the trees of the commands it started, then its containers.
  func stop(_ profile: EnvProfile) {
    let monitor = Monitor.shared
    if let snapshot = monitor.snapshot {
      let nodes = snapshot.processes.map { (pid: $0.pid, ppid: $0.ppid) }
      let byPID = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
      let targets = profile.commands.compactMap(running).flatMap { l -> [ProcessItem] in
        guard let root = byPID[l.pid], root.start == l.start else { return [] }
        return descendantIDs(root: root.pid, nodes: nodes).compactMap { byPID[$0] }
      }
      if !targets.isEmpty { monitor.signal(targets, force: false) }
    }
    for command in profile.commands { launched[command.id] = nil }
    guard !profile.containers.isEmpty else { return }
    busy.insert(profile.id)
    queue.async {
      let errors = Self.containers(profile.containers, action: "stop")
      DispatchQueue.main.async {
        self.busy.remove(profile.id)
        ContainerStore.shared.refreshSoon()
        if let first = errors.first { monitor.feedback = ActionFeedback(message: first, failed: true) }
      }
    }
  }

  private func launch(_ profile: EnvProfile, _ command: ProfileCommand) -> Result<LaunchedCommand, CleanupError> {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: profile.folder, isDirectory: &isDir), isDir.boolValue else {
      return .failure(CleanupError(L("Pasta não encontrada")))
    }
    try? FileManager.default.createDirectory(at: Self.logs, withIntermediateDirectories: true)
    let log = logURL(profile, command)
    FileManager.default.createFile(atPath: log.path, contents: Data("$ \(command.command)\n".utf8))
    guard let output = try? FileHandle(forWritingTo: log) else {
      return .failure(CleanupError(L("Não foi possível criar o log")))
    }
    output.seekToEndOfFile()
    let process = Process()
    // A login, interactive shell sees the same PATH as the user's terminal (nvm, asdf, Homebrew).
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    process.arguments = ["-l", "-i", "-c", command.command]
    process.currentDirectoryURL = URL(fileURLWithPath: profile.folder)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch { return .failure(CleanupError(error.localizedDescription)) }
    try? output.close()
    let pid = process.processIdentifier
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
      return .failure(CleanupError(L("O comando terminou logo ao iniciar; veja o log")))
    }
    return .success(LaunchedCommand(pid: pid, start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, log: log.path))
  }

  /// Starts or stops containers by name through the engine; returns errors.
  private static func containers(_ names: [String], action: String) -> [String] {
    guard !names.isEmpty else { return [] }
    guard let pointer = cs_containers(0) else { return [L("O núcleo não retornou dados")] }
    defer { cs_free(pointer) }
    let data = Data(bytes: pointer, count: strlen(pointer))
    let all = (try? JSONDecoder().decode(ContainerReport.self, from: data))?.containers ?? []
    var errors: [String] = []
    for name in names {
      guard let container = all.first(where: { $0.name == name }) else {
        errors.append(L("Contêiner %@ não encontrado", name))
        continue
      }
      if container.running == (action == "start") { continue }
      let result = container.id.withCString { id in action.withCString { cs_container_action(id, $0) } }
      guard let result else { continue }
      let text = String(cString: result)
      cs_free(result)
      if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let error = obj["error"] as? String
      {
        errors.append("\(name): \(CleanupStore.translate(error))")
      }
    }
    return errors
  }
}

struct ProfilesView: View {
  @ObservedObject var store = ProfileStore.shared
  @ObservedObject var containers = ContainerStore.shared
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var editing: EnvProfile?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text(L("Um clique para subir (ou derrubar) o ambiente de um projeto: comandos na pasta dele e os contêineres de que ele precisa."))
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          Button {
            editing = EnvProfile(name: "", folder: "", commands: [ProfileCommand(name: "dev", command: "")])
          } label: {
            Label(L("Novo perfil"), systemImage: "plus")
          }
        }
        if store.profiles.isEmpty {
          Card { EmptyNote(text: L("Nenhum perfil ainda. Crie um com os comandos que você roda todo dia (npm run dev, php artisan serve…) e os contêineres do projeto.")) }
        }
        ForEach(store.profiles) { profile in
          ProfileCard(profile: profile, containers: (containers.report?.containers ?? [])) { editing = profile }
        }
        Text(
          L("Os comandos rodam no seu shell de login, na pasta do perfil, com a saída em ~/Library/Application Support/CoreScope/logs. Parar encerra só os processos que o CoreScope iniciou (com a mesma verificação de identidade do resto do app) e para os contêineres do perfil.")
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
    .watchesContainers(stats: false)
    .sheet(item: $editing) { profile in
      ProfileEditor(profile: profile) { saved in
        if let i = store.profiles.firstIndex(where: { $0.id == saved.id }) {
          store.profiles[i] = saved
        } else {
          store.profiles.append(saved)
        }
        editing = nil
      } cancel: {
        editing = nil
      }
    }
  }
}

private struct ProfileCard: View {
  let profile: EnvProfile
  let containers: [ContainerItem]
  let edit: () -> Void
  @ObservedObject var store = ProfileStore.shared
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var confirmStop = false
  @ViewState private var confirmDelete = false
  var body: some View {
    let total = profile.commands.count + profile.containers.count
    let up = store.runningCount(profile, containers: containers)
    Card {
      HStack(spacing: 10) {
        Image(systemName: "play.square.stack").font(.system(size: 15, weight: .semibold))
          .foregroundStyle(up > 0 ? Tint.brand : .secondary)
          .frame(width: 28, height: 28)
          .background((up > 0 ? Tint.brand : Color.secondary).opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Badge(
              text: up == 0 ? L("Parado") : up == total ? L("Rodando") : L("%@ de %@ rodando", "\(up)", "\(total)"),
              color: up == 0 ? .secondary : up == total ? Tint.brand : .orange)
          }
          Text(abbreviateHome(profile.folder)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer(minLength: 8)
        if store.busy.contains(profile.id) { ProgressView().controlSize(.small) }
        if up < total {
          Button {
            store.start(profile)
          } label: {
            Label(L("Iniciar"), systemImage: "play.fill")
          }.disabled(store.busy.contains(profile.id))
        }
        if up > 0 {
          Button {
            confirmStop = true
          } label: {
            Label(L("Parar"), systemImage: "stop.fill")
          }.disabled(store.busy.contains(profile.id))
        }
        Menu {
          Button(L("Editar"), action: edit)
          Button(L("Mostrar logs no Finder")) { NSWorkspace.shared.open(ProfileStore.logs) }
          Divider()
          Button(L("Apagar perfil"), role: .destructive) { confirmDelete = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      }
      .buttonStyle(.bordered).controlSize(.small)
      ForEach(profile.commands) { command in commandRow(command) }
      ForEach(profile.containers, id: \.self) { name in containerRow(name) }
    }
    .confirmationDialog(L("Parar %@?", profile.name), isPresented: $confirmStop, titleVisibility: .visible) {
      Button(L("Parar"), role: .destructive) { store.stop(profile) }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("Envia SIGTERM aos processos que o CoreScope iniciou para este perfil (e aos filhos deles) e para os contêineres do perfil."))
    }
    .confirmationDialog(L("Apagar o perfil %@?", profile.name), isPresented: $confirmDelete, titleVisibility: .visible) {
      Button(L("Apagar"), role: .destructive) { store.profiles.removeAll { $0.id == profile.id } }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("Só a configuração é apagada; nada que esteja rodando é encerrado."))
    }
  }
  private func commandRow(_ command: ProfileCommand) -> some View {
    let launched = store.running(command)
    let ports = launched.map { l in tree(l.pid).flatMap(\.ports) } ?? []
    return HStack(spacing: 8) {
      Circle().fill(launched != nil ? Tint.brand : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
      Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16)
      Text(command.name).font(.callout.weight(.medium))
      Text(command.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 6)
      ForEach(ports.prefix(3), id: \.port) { port in PortBadge(port: port) }
      if let launched { Text("PID \(launched.pid)").font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
      Button {
        NSWorkspace.shared.open(store.logURL(profile, command))
      } label: {
        Image(systemName: "doc.text.magnifyingglass")
      }.buttonStyle(.borderless).help(L("Abrir log"))
        .disabled(!FileManager.default.fileExists(atPath: store.logURL(profile, command).path))
    }
  }
  private func containerRow(_ name: String) -> some View {
    let container = containers.first { $0.name == name }
    return HStack(spacing: 8) {
      Circle().fill(container?.running == true ? Tint.brand : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
      Image(systemName: "shippingbox").foregroundStyle(.secondary).frame(width: 16)
      Text(name).font(.callout.weight(.medium)).lineLimit(1)
      Text(container?.stateLabel ?? L("não encontrado")).font(.caption).foregroundStyle(.secondary)
      Spacer(minLength: 6)
      ForEach((container?.tcpPorts ?? []).prefix(3), id: \.host) { port in
        Badge(text: ":\(port.host)", color: port.exposed ? .orange : Tint.netIn)
      }
    }
  }
  private func tree(_ pid: Int32) -> [ProcessItem] {
    guard let s = monitor.snapshot else { return [] }
    let byPID = Dictionary(s.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    return descendantIDs(root: pid, nodes: s.processes.map { (pid: $0.pid, ppid: $0.ppid) }).compactMap { byPID[$0] }
  }
}

private struct ProfileEditor: View {
  @ViewState var profile: EnvProfile
  let save: (EnvProfile) -> Void
  let cancel: () -> Void
  @ObservedObject var containers = ContainerStore.shared
  init(profile: EnvProfile, save: @escaping (EnvProfile) -> Void, cancel: @escaping () -> Void) {
    _profile = ViewState(initialValue: profile)
    self.save = save
    self.cancel = cancel
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(profile.name.isEmpty ? L("Novo perfil") : profile.name).font(.title3.weight(.semibold))
      Form {
        TextField(L("Nome"), text: $profile.name)
        LabeledContent(L("Pasta")) {
          HStack {
            Text(profile.folder.isEmpty ? "—" : abbreviateHome(profile.folder)).lineLimit(1).truncationMode(.middle)
            Button(L("Escolher…"), action: chooseFolder)
          }
        }
        Section(L("Comandos")) {
          // Bindings by id, not by index: a field that updates after its row was removed would
          // otherwise read past the end of the array and crash.
          ForEach(profile.commands) { command in
            HStack {
              TextField(L("Nome"), text: field(command.id, \.name), prompt: Text(L("Nome"))).frame(width: 110)
              TextField(L("Comando"), text: field(command.id, \.command), prompt: Text(L("Comando, ex.: npm run dev")))
                .font(.system(.body, design: .monospaced))
              Button {
                profile.commands.removeAll { $0.id == command.id }
              } label: {
                Image(systemName: "minus.circle")
              }.buttonStyle(.borderless)
            }.labelsHidden()
          }
          Button(L("Adicionar comando"), systemImage: "plus") {
            profile.commands.append(ProfileCommand(name: "cmd\(profile.commands.count + 1)", command: ""))
          }
        }
        Section(L("Contêineres")) {
          let names = Array(Set((containers.report?.containers ?? []).map(\.name) + profile.containers)).sorted()
          if names.isEmpty { Text(L("Nenhum contêiner encontrado.")).foregroundStyle(.secondary) }
          ForEach(names, id: \.self) { name in
            Toggle(name, isOn: Binding(
              get: { profile.containers.contains(name) },
              set: { on in
                if on { profile.containers.append(name) } else { profile.containers.removeAll { $0 == name } }
              }))
          }
        }
      }.formStyle(.grouped)
      HStack {
        Spacer()
        Button(L("Cancelar"), action: cancel).keyboardShortcut(.cancelAction)
        Button(L("Salvar")) {
          var saved = profile
          saved.commands.removeAll { $0.command.trimmingCharacters(in: .whitespaces).isEmpty }
          save(saved)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty || profile.folder.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 620, height: 560)
    .watchesContainers(stats: false)
  }
  private func field(_ id: UUID, _ key: WritableKeyPath<ProfileCommand, String>) -> Binding<String> {
    Binding(
      get: { profile.commands.first { $0.id == id }?[keyPath: key] ?? "" },
      set: { value in
        if let i = profile.commands.firstIndex(where: { $0.id == id }) { profile.commands[i][keyPath: key] = value }
      })
  }
  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    profile.folder = url.path
    if profile.name.isEmpty { profile.name = url.lastPathComponent }
  }
}
