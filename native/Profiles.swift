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
  /// Run on Stop, for commands that set something up and exit (`make env-down` for `make env-up`).
  var stopCommand: String? = nil
}
/// How a command CoreScope started has ended.
struct CommandExit: Codable, Equatable {
  let status: Int32
  let at: Date
}
/// Where a profile command stands, for the card and for MCP.
enum CommandState: Equatable {
  case idle
  case running(LaunchedCommand)
  /// Ran and exited 0 while the profile is started: setup commands count as up. No date when it
  /// ended while CoreScope was closed.
  case completed(Date?)
  case failed(Int32, Date)
}
/// A command CoreScope started, identified like everywhere else by PID + start time, in a session
/// of its own: everything it starts keeps that session id, even after detaching from the shell.
struct LaunchedCommand: Codable, Equatable {
  let pid: Int32
  let start: UInt64
  let log: String
  /// Session id (the shell leads it); nil for commands started by older versions.
  var sid: Int32? = nil
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
  /// Command id → how its last run ended (cleared when it starts again or the profile stops).
  @Published private(set) var exits: [UUID: CommandExit] {
    didSet { persist(exits, "envExits") }
  }
  /// Profiles started and not stopped yet: their containers stay up for them.
  @Published private(set) var active: Set<UUID> {
    didSet { persist(active, "envActive") }
  }
  /// Containers a profile started (they were stopped before); only these are stopped by profiles.
  @Published private(set) var startedContainers: Set<String> {
    didSet { persist(startedContainers, "envStartedContainers") }
  }
  private let queue = DispatchQueue(label: "app.corescope.profiles", qos: .userInitiated)
  static let logs = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CoreScope/logs")

  private init() {
    profiles = Self.load([EnvProfile].self, "envProfiles") ?? []
    // Kept even when the shell is gone: what it started may still run in its session.
    launched = Self.load([UUID: LaunchedCommand].self, "envLaunched") ?? [:]
    active = Self.load(Set<UUID>.self, "envActive") ?? []
    exits = Self.load([UUID: CommandExit].self, "envExits") ?? [:]
    startedContainers = Self.load(Set<String>.self, "envStartedContainers") ?? []
  }
  /// What Stop would do to this profile's containers right now.
  func stopPlan(_ profile: EnvProfile, containers: [ContainerItem]) -> ContainerStopPlan {
    let others = profiles.filter { $0.id != profile.id && active.contains($0.id) }.map {
      (name: $0.name, containers: $0.containers)
    }
    return planContainerStop(
      profile.containers, running: Set(containers.filter(\.running).map(\.name)),
      startedByProfiles: startedContainers, otherActive: others)
  }
  private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
  private func persist<T: Encodable>(_ value: T, _ key: String) {
    if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
  }

  /// Everything still running from a command: its session's processes (same user, started with
  /// or after it), so detached servers count and survive a CoreScope restart.
  func members(_ command: ProfileCommand) -> [ProcessItem] {
    guard let l = launched[command.id], let s = Monitor.shared.snapshot else { return [] }
    guard let sid = l.sid else {
      return s.processes.filter { $0.pid == l.pid && $0.start == l.start }
    }
    return s.processes.filter { $0.sid == sid && $0.uid == s.current_uid && $0.start >= l.start }
  }
  /// The launch record while anything from it still runs.
  func running(_ command: ProfileCommand) -> LaunchedCommand? {
    guard let l = launched[command.id] else { return nil }
    if !members(command).isEmpty || cs_is_same(l.pid, l.start) == 1 { return l }
    return nil
  }
  func state(_ command: ProfileCommand, in profile: EnvProfile) -> CommandState {
    if let l = running(command) { return .running(l) }
    if let exit = exits[command.id] {
      if exit.status != 0 { return .failed(exit.status, exit.at) }
      return active.contains(profile.id) ? .completed(exit.at) : .idle
    }
    // Ended while CoreScope was closed: no status, but it ran for this start of the profile.
    return launched[command.id] != nil && active.contains(profile.id) ? .completed(nil) : .idle
  }
  /// Commands running or completed, plus running containers.
  func runningCount(_ profile: EnvProfile, containers: [ContainerItem]) -> Int {
    profile.commands.filter {
      switch state($0, in: profile) {
      case .running, .completed: true
      default: false
      }
    }.count
      + profile.containers.filter { name in containers.contains { $0.name == name && $0.running } }.count
  }
  func logURL(_ profile: EnvProfile, _ command: ProfileCommand) -> URL {
    Self.logs.appendingPathComponent("\(profile.id.uuidString.prefix(8))-\(Self.slug(command.name)).log")
  }
  private static func slug(_ s: String) -> String {
    String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
  }

  /// `done` gets the errors (empty when everything started).
  func start(_ profile: EnvProfile, done: (([String]) -> Void)? = nil) {
    guard !busy.contains(profile.id) else {
      done?([L("O perfil já está iniciando ou parando")])
      return
    }
    busy.insert(profile.id)
    let monitor = Monitor.shared
    monitor.feedback = ActionFeedback(message: L("Iniciando %@…", profile.name), pending: true)
    // Running ones and setup commands that already completed for this start are left alone.
    let pending = profile.commands.filter {
      switch state($0, in: profile) {
      case .running, .completed: false
      default: true
      }
    }
    for command in pending { exits[command.id] = nil }
    queue.async {
      var errors: [String] = []
      var started: [UUID: LaunchedCommand] = [:]
      for command in pending {
        switch self.launch(profile, command) {
        case .success(let l?): started[command.id] = l
        case .success(nil): break
        case .failure(let e): errors.append("\(command.name): \(e.description)")
        }
      }
      let (containerErrors, startedNow, alreadyUp) = Self.containers(profile.containers, action: "start")
      errors += containerErrors
      DispatchQueue.main.async {
        self.launched.merge(started) { _, new in new }
        self.active.insert(profile.id)
        // Already running and no started profile accounts for it: someone else's, leave it be.
        let claimed = Set(self.profiles.filter { $0.id != profile.id && self.active.contains($0.id) }.flatMap(\.containers))
        self.startedContainers.subtract(alreadyUp.filter { !claimed.contains($0) })
        self.startedContainers.formUnion(startedNow)
        self.busy.remove(profile.id)
        ContainerStore.shared.refreshSoon()
        monitor.refresh()
        monitor.feedback = ActionFeedback(
          message: errors.first.map { L("%@: %@", profile.name, $0) } ?? L("%@ iniciado.", profile.name),
          failed: !errors.isEmpty)
        done?(errors)
      }
    }
  }

  /// Runs after the user confirmed: the trees of the commands it started, then the containers
  /// in `plan.stop` (or every running one of the profile with `everything`).
  /// `done` gets the plan that was applied and the errors.
  func stop(_ profile: EnvProfile, everything: Bool = false, done: ((ContainerStopPlan, [String]) -> Void)? = nil) {
    let current = ContainerStore.shared.report?.containers ?? []
    let plan = stopPlan(profile, containers: current)
    let names = everything ? profile.containers : plan.stop
    active.remove(profile.id)
    let monitor = Monitor.shared
    // Every process left in the commands' sessions, detached ones included; leaders last.
    let targets = profile.commands.flatMap { members($0) }.sorted { $0.start > $1.start }
    if !targets.isEmpty { monitor.signal(targets, force: false) }
    for command in profile.commands {
      launched[command.id] = nil
      exits[command.id] = nil
    }
    let teardown = profile.commands.filter { !($0.stopCommand ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    guard !names.isEmpty || !teardown.isEmpty else {
      done?(plan, [])
      return
    }
    busy.insert(profile.id)
    queue.async {
      var errors = teardown.compactMap { self.runStop(profile, $0) }
      let (containerErrors, stopped, _) = Self.containers(names, action: "stop")
      errors += containerErrors
      DispatchQueue.main.async {
        self.startedContainers.subtract(stopped)
        self.busy.remove(profile.id)
        ContainerStore.shared.refreshSoon()
        if let first = errors.first { monitor.feedback = ActionFeedback(message: first, failed: true) }
        done?(plan, errors)
      }
    }
  }

  /// A command's stop counterpart, appended to its log; waits up to 2 minutes. Returns an error.
  private func runStop(_ profile: EnvProfile, _ command: ProfileCommand) -> String? {
    guard let stop = command.stopCommand, FileManager.default.fileExists(atPath: profile.folder) else { return nil }
    let log = logURL(profile, command)
    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
    guard let output = try? FileHandle(forWritingTo: log) else { return L("Não foi possível criar o log") }
    output.seekToEndOfFile()
    output.write(Data("\n$ \(stop)   (\(L("ao parar")))\n".utf8))
    let process = Self.shell(stop, in: profile.folder, output: output)
    do { try process.run() } catch { return "\(command.name): \(error.localizedDescription)" }
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    if finished.wait(timeout: .now() + 120) == .timedOut {
      process.terminate()
      return L("%@: o comando ao parar passou de 2 min", command.name)
    }
    try? output.close()
    return process.terminationStatus == 0 ? nil : L("%@: o comando ao parar saiu com %@", command.name, "\(process.terminationStatus)")
  }
  /// A login, interactive shell sees the same PATH as the user's terminal (nvm, asdf, Homebrew).
  private static func shell(_ command: String, in folder: String, output: FileHandle) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    process.arguments = ["-l", "-i", "-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: folder)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    return process
  }

  /// Starts the command in a new session (POSIX_SPAWN_SETSID) so everything it starts can be
  /// found again by session id. nil on success means it already finished (its exit is recorded).
  private func launch(_ profile: EnvProfile, _ command: ProfileCommand) -> Result<LaunchedCommand?, CleanupError> {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: profile.folder, isDirectory: &isDir), isDir.boolValue else {
      return .failure(CleanupError(L("Pasta não encontrada")))
    }
    try? FileManager.default.createDirectory(at: Self.logs, withIntermediateDirectories: true)
    let log = logURL(profile, command)
    guard FileManager.default.createFile(atPath: log.path, contents: Data("$ \(command.command)\n".utf8)) else {
      return .failure(CleanupError(L("Não foi possível criar o log")))
    }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // New session; and no file descriptor of the app (sockets, files) leaks into the command.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    posix_spawn_file_actions_addchdir_np(&actions, profile.folder)
    // A login, interactive shell sees the same PATH as the user's terminal (nvm, asdf, Homebrew).
    let argv = [shell, "-l", "-i", "-c", command.command].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, shell, &actions, &attr, argv, environ)
    guard spawned == 0 else { return .failure(CleanupError(String(cString: strerror(spawned)))) }
    // Setup commands exit on their own: their status decides between "completed" and "failed".
    Thread.detachNewThread { [weak self] in
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
      let exit = CommandExit(status: code, at: Date())
      DispatchQueue.main.async { self?.exits[command.id] = exit }
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return .success(nil) }
    return .success(
      LaunchedCommand(pid: pid, start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, log: log.path, sid: pid))
  }

  /// Starts or stops containers by name through the engine: errors, the containers it changed,
  /// and those already in the wanted state.
  private static func containers(_ names: [String], action: String) -> ([String], [String], [String]) {
    guard !names.isEmpty else { return ([], [], []) }
    guard let pointer = cs_containers(0) else { return ([L("O núcleo não retornou dados")], [], []) }
    defer { cs_free(pointer) }
    let data = Data(bytes: pointer, count: strlen(pointer))
    let all = (try? JSONDecoder().decode(ContainerReport.self, from: data))?.containers ?? []
    var errors: [String] = []
    var changed: [String] = []
    var unchanged: [String] = []
    for name in names {
      guard let container = all.first(where: { $0.name == name }) else {
        errors.append(L("Contêiner %@ não encontrado", name))
        continue
      }
      if container.running == (action == "start") {
        unchanged.append(name)
        continue
      }
      let result = container.id.withCString { id in action.withCString { cs_container_action(id, $0) } }
      guard let result else { continue }
      let text = String(cString: result)
      cs_free(result)
      if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let error = obj["error"] as? String
      {
        errors.append("\(name): \(CleanupStore.translate(error))")
      } else {
        changed.append(name)
      }
    }
    return (errors, changed, unchanged)
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
        // Also offered when everything is already up: starting claims the shared containers.
        if up < total || !store.active.contains(profile.id) {
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
      let plan = store.stopPlan(profile, containers: containers)
      Button(L("Parar"), role: .destructive) { store.stop(profile) }
      if !plan.shared.isEmpty || !plan.external.isEmpty {
        Button(L("Parar tudo, inclusive compartilhados"), role: .destructive) { store.stop(profile, everything: true) }
      }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(stopMessage(store.stopPlan(profile, containers: containers)))
    }
    .confirmationDialog(L("Apagar o perfil %@?", profile.name), isPresented: $confirmDelete, titleVisibility: .visible) {
      Button(L("Apagar"), role: .destructive) { store.profiles.removeAll { $0.id == profile.id } }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("Só a configuração é apagada; nada que esteja rodando é encerrado."))
    }
  }
  private func stopMessage(_ plan: ContainerStopPlan) -> String {
    var lines = [L("Envia SIGTERM aos processos que o CoreScope iniciou para este perfil (e aos filhos deles).")]
    if !plan.stop.isEmpty { lines.append(L("Para: %@", plan.stop.joined(separator: ", "))) }
    for (name, other) in plan.shared.sorted(by: { $0.key < $1.key }) {
      lines.append(L("Mantém %@: em uso pelo perfil %@", name, other))
    }
    if !plan.external.isEmpty {
      lines.append(L("Mantém %@: já estava rodando quando o perfil foi iniciado", plan.external.joined(separator: ", ")))
    }
    return lines.joined(separator: "\n")
  }
  private func commandRow(_ command: ProfileCommand) -> some View {
    let state = store.state(command, in: profile)
    let launched: LaunchedCommand? = if case .running(let l) = state { l } else { nil }
    let members = store.members(command)
    let ports = members.flatMap(\.ports)
    return HStack(spacing: 8) {
      switch state {
      case .completed:
        Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(Tint.brand).frame(width: 7)
      case .failed:
        Image(systemName: "xmark.circle.fill").font(.system(size: 9)).foregroundStyle(.red).frame(width: 7)
      default:
        Circle().fill(launched != nil ? Tint.brand : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
      }
      Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16)
      Text(command.name).font(.callout.weight(.medium))
      VStack(alignment: .leading, spacing: 1) {
        Text(command.command).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.tail)
        if let stop = command.stopCommand, !stop.isEmpty {
          Text(L("ao parar: %@", stop)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 6)
      ForEach(ports.prefix(3), id: \.port) { port in PortBadge(port: port) }
      switch state {
      case .running(let l):
        Text(members.count > 1 ? L("%@ processos", "\(members.count)") : "PID \(members.first?.pid ?? l.pid)")
          .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
          .help(members.map { "\($0.name) (\($0.pid))" }.joined(separator: "\n"))
      case .completed(let at):
        Text(at.map { L("concluído %@", $0.formatted(.relative(presentation: .named))) } ?? L("concluído"))
          .font(.caption).foregroundStyle(.secondary)
          .help(L("Comando de preparação: terminou com sucesso (saída 0) e conta como ativo enquanto o perfil está iniciado."))
      case .failed(let status, _):
        Text(L("falhou · saída %@", "\(status)")).font(.caption).foregroundStyle(.red)
      case .idle: EmptyView()
      }
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
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                TextField(L("Nome"), text: field(command.id, \.name), prompt: Text(L("Nome"))).frame(width: 110)
                TextField(L("Comando"), text: field(command.id, \.command), prompt: Text(L("Comando, ex.: npm run dev")))
                  .font(.system(.body, design: .monospaced))
                Button {
                  profile.commands.removeAll { $0.id == command.id }
                } label: {
                  Image(systemName: "minus.circle")
                }.buttonStyle(.borderless)
              }
              HStack {
                Text(L("ao parar")).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                TextField(L("Ao parar"), text: stopField(command.id), prompt: Text(L("Opcional, ex.: make env-down")))
                  .font(.system(.caption, design: .monospaced))
              }
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
  private func stopField(_ id: UUID) -> Binding<String> {
    Binding(
      get: { profile.commands.first { $0.id == id }?.stopCommand ?? "" },
      set: { value in
        if let i = profile.commands.firstIndex(where: { $0.id == id }) {
          profile.commands[i].stopCommand = value.isEmpty ? nil : value
        }
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
