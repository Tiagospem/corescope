import AppKit
import CryptoKit
import SwiftUI

/// Commands from project files run through the user's login shell in the project folder, in a
/// session of their own (so a timeout or a cancel reaches everything they started).
enum ShellRun {
  struct Captured {
    var status: Int32?
    var output: Data
    var timedOut = false
    var truncated = false
  }
  /// Runs and reads stdout (stderr too with `mergeStderr`) up to `maxBytes`. Blocking: call it off
  /// the main thread. A timeout or an oversized output ends the whole session. The command writes
  /// to fd 3, so whatever the user's shell startup files print never mixes with its output.
  /// - light: through `/bin/sh` with the login shell's environment captured once
  ///   (`loginEnvironment`) instead of starting an interactive login shell each time: the same
  ///   PATH for a fraction of the cost (a zsh with plugins takes ~0.4 s of CPU to start). For
  ///   commands that run often, like `status`.
  static func capture(
    _ command: String, in folder: String, timeout: Double, maxBytes: Int, mergeStderr: Bool, env: [String: String] = [:],
    light: Bool = false
  ) -> Captured {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return Captured(status: nil, output: Data("pipe failed".utf8)) }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 3)
    let wrapped = "{ \(command)\n} >&3 \(mergeStderr ? "2>&3 " : "")3>&-"
    let base = light ? loginEnvironment() : nil
    guard let pid = spawn(wrapped, in: folder, actions: &actions, env: env, base: base) else {
      close(fds[0])
      close(fds[1])
      return Captured(status: nil, output: Data(L("Não foi possível iniciar o comando").utf8))
    }
    close(fds[1])
    let reaped = Reaped()
    var result = Captured(status: nil, output: Data())
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
      if reaped.endSession(pid) { reaped.timedOut = true }
    }
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let n = read(fds[0], &buffer, buffer.count)
      if n <= 0 { break }
      result.output.append(contentsOf: buffer[0..<n])
      if result.output.count > maxBytes {
        result.truncated = true
        _ = reaped.endSession(pid)
        break
      }
    }
    close(fds[0])
    result.status = reaped.wait(pid)
    result.timedOut = reaped.timedOut
    return result
  }

  /// The environment of the user's interactive login shell (PATH from nvm, asdf, Homebrew…),
  /// read once and again every 30 min; nil while it cannot be read. Blocking: off the main thread.
  static func loginEnvironment() -> [String: String]? {
    envLock.lock()
    defer { envLock.unlock() }
    if let cached = cachedEnvironment, -cached.at.timeIntervalSinceNow < 1800 { return cached.vars }
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return cachedEnvironment?.vars }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, fds[1], 3)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard let pid = spawn("/usr/bin/env -0 >&3 3>&-", in: home, actions: &actions, env: [:], base: nil) else {
      close(fds[0])
      close(fds[1])
      return cachedEnvironment?.vars
    }
    close(fds[1])
    let reaped = Reaped()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { _ = reaped.endSession(pid) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count < 1 << 20 {
      let n = read(fds[0], &buffer, buffer.count)
      if n <= 0 { break }
      data.append(contentsOf: buffer[0..<n])
    }
    close(fds[0])
    guard reaped.wait(pid) == 0 else { return cachedEnvironment?.vars }
    var vars: [String: String] = [:]
    for entry in data.split(separator: 0) {
      let text = String(decoding: entry, as: UTF8.self)
      guard let eq = text.firstIndex(of: "="), eq != text.startIndex else { continue }
      vars[String(text[..<eq])] = String(text[text.index(after: eq)...])
    }
    // Shell-internal values that make no sense outside that shell.
    for key in ["SHLVL", "_", "OLDPWD", "PWD"] { vars[key] = nil }
    guard vars["PATH"] != nil else { return cachedEnvironment?.vars }
    cachedEnvironment = (vars, Date())
    return vars
  }
  private static let envLock = NSLock()
  private static var cachedEnvironment: (vars: [String: String], at: Date)?

  /// Starts `$SHELL -l -i -c command` in a new session (or `/bin/sh -c command` with `base` as the
  /// whole environment); nil when it could not start.
  static func spawn(
    _ command: String, in folder: String, actions: inout posix_spawn_file_actions_t?, env: [String: String],
    base: [String: String]? = nil
  ) -> pid_t? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else { return nil }
    posix_spawn_file_actions_addchdir_np(&actions, folder)
    let shell = base == nil ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : "/bin/sh"
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let words: [String] = base == nil ? [shell, "-l", "-i", "-c", command] : [shell, "-c", command]
    var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
    argv.append(nil)
    defer { argv.forEach { free($0) } }
    var vars = base ?? ProcessInfo.processInfo.environment
    for (k, v) in env { vars[k] = v }
    var envp: [UnsafeMutablePointer<CChar>?] = vars.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    defer { envp.forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, shell, &actions, &attr, argv, envp) == 0 else { return nil }
    return pid
  }

  /// Guards signals to a session against PID reuse: the leader is waited for without being
  /// reaped (WNOWAIT), so its process group id cannot be reused before `wait` marks it done.
  final class Reaped {
    private let lock = NSLock()
    private var done = false
    private var timedOutValue = false
    var timedOut: Bool {
      get { lock.withLock { timedOutValue } }
      set { lock.withLock { timedOutValue = newValue } }
    }
    /// SIGTERM to the session, SIGKILL 5 s later; false once it already ended.
    func endSession(_ pid: pid_t) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !done else { return false }
      killpg(pid, SIGTERM)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [self] in
        lock.lock()
        defer { lock.unlock() }
        if !done { killpg(pid, SIGKILL) }
      }
      return true
    }
    /// The exit status (128 + signal when killed).
    func wait(_ pid: pid_t) -> Int32 {
      var info = siginfo_t()
      while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
      lock.lock()
      done = true
      lock.unlock()
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
  }
}

/// The real state of environments whose `.corescope.yml` has a `status` command (an environment
/// controller): read every 30 s and after each operation, one run at a time per project, with a
/// short timeout. Its output is data shown to the user, never acted upon beyond the documented
/// fields.
final class EnvironmentStore: ObservableObject {
  static let shared = EnvironmentStore()
  struct Reading {
    /// The last valid status and when CoreScope asked for it.
    var last: EnvironmentStatus?
    var lastFetchedAt: Date?
    /// Why the latest attempt failed (nil when it worked).
    var error: String?
    var attemptedAt: Date?
  }
  @Published private(set) var readings: [String: Reading] = [:]
  /// Project file → its status spec, folder and project name.
  private(set) var specs: [String: (spec: ProjectConfig.Status, folder: String, project: String)] = [:]
  private var running = Set<String>()
  /// Asked while a reading ran: that reading may predate what the caller just did, so another
  /// one follows and the callers wait for it.
  private var rerun = Set<String>()
  private var waiting: [String: [() -> Void]] = [:]
  private var timer: Timer?
  private let queue = DispatchQueue(label: "app.corescope.environment", qos: .utility, attributes: .concurrent)

  private init() {}
  func reload() {
    var next: [String: (spec: ProjectConfig.Status, folder: String, project: String)] = [:]
    for file in ProjectFileStore.shared.files {
      if let status = file.config?.status { next[file.file] = (status, file.folder, file.project) }
    }
    let changed = Set(next.keys) != Set(specs.keys) || next.contains { specs[$0.key]?.spec != $0.value.spec }
    specs = next
    readings = readings.filter { next[$0.key] != nil }
    guard changed else { return }
    timer?.invalidate()
    timer = nil
    guard !next.isEmpty else { return }
    refreshAll()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshAll(timer: true) }
    timer?.tolerance = 5
  }
  /// Every 30 s while a window or the floating panel is up or an operation of the project runs;
  /// every 2 min otherwise (the menu bar and alerts still follow, just less often).
  func refreshAll(timer: Bool = false) {
    let attentive =
      Preferences.shared.panelVisible
      || NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.resizable) && !($0 is NSPanel) }
    for source in specs.keys {
      if timer, !attentive, environmentOperation(source, except: nil) == nil,
        let last = readings[source]?.attemptedAt, -last.timeIntervalSinceNow < 115
      {
        continue
      }
      refresh(source)
    }
  }
  /// Reads one project's status now. Never two at once per project: a request during a reading
  /// is served by one more reading right after it (coalesced).
  func refresh(_ source: String, done: (() -> Void)? = nil) {
    guard let entry = specs[source] else {
      done?()
      return
    }
    if let done { waiting[source, default: []].append(done) }
    guard !running.contains(source) else {
      rerun.insert(source)
      return
    }
    running.insert(source)
    let asked = Date()
    let timeout = min(max(entry.spec.timeout_seconds ?? 5, 1), 30)
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("environment", cost) }
      let out = ShellRun.capture(
        entry.spec.run, in: entry.folder, timeout: timeout, maxBytes: EnvironmentStatus.maxBytes, mergeStderr: false,
        light: true)
      var status: EnvironmentStatus?
      var problem: String?
      if out.timedOut {
        problem = L("sem resposta em %@ s", "\(Int(timeout))")
      } else if out.truncated {
        problem = L("saída maior que 256 KB")
      } else if out.status != 0 {
        problem = L("saiu com %@", "\(out.status ?? -1)")
      } else {
        do { status = try EnvironmentStatus(parsing: out.output) } catch let e as StatusError {
          problem = L("saída inválida: %@", e.reason)
        } catch { problem = L("saída inválida") }
      }
      let error = problem
      DispatchQueue.main.async {
        self.running.remove(source)
        var r = self.readings[source] ?? Reading()
        r.attemptedAt = asked
        r.error = error
        if let status {
          r.last = status
          r.lastFetchedAt = asked
        }
        self.readings[source] = r
        if status != nil { ProfileStore.shared.reconcile(source: source, askedAt: asked) }
        HealthStore.shared.objectWillChange.send()
        if self.rerun.remove(source) != nil { return self.refresh(source) }
        let callers = self.waiting.removeValue(forKey: source) ?? []
        callers.forEach { $0() }
      }
    }
  }
  /// What profiles and checks of this project file see.
  func input(_ source: String?) -> StatusInput {
    guard let source, specs[source] != nil else { return .none }
    guard let r = readings[source] else { return .unavailable("waiting for the first reading") }
    if let error = r.error { return .unavailable(error) }
    guard let last = r.last, let fetched = r.lastFetchedAt else { return .unavailable("no reading") }
    if statusIsStale(collectedAt: last.collectedAt, fetchedAt: fetched, now: Date(), interval: 120) {
      return .unavailable("stale reading from \(last.collectedAt.formatted(date: .omitted, time: .standard))")
    }
    return .fresh(last)
  }
  func isReading(_ source: String) -> Bool { running.contains(source) }
}

/// A one-off action from a project file (setup, rebuild, diagnostics, backup, restore).
struct ProjectAction: Identifiable, Equatable {
  let id: UUID
  let name: String
  let project: String
  let source: String
  let folder: String
  let spec: ProjectConfig.Action
  var fullName: String { "\(project)/\(name)" }
  var timeout: Double { min(max(spec.timeout_minutes ?? 10, 1), 1440) * 60 }
  var confirm: Bool { spec.confirm == true }
}
/// How an action's latest run went (kept across restarts).
struct ActionRun: Codable, Equatable {
  enum Outcome: String, Codable {
    case running, succeeded, failed, cancelled
    case timedOut = "timed_out"
    /// CoreScope closed while it ran and it is gone: how it ended is unknown.
    case interrupted
  }
  var outcome: Outcome
  var pid: Int32
  var start: UInt64
  var startedAt: Date
  var endedAt: Date?
  var exit: Int32?
  var log: String
  /// Reported with `CORESCOPE_ARTIFACT=`, kept only after exit 0 when the file exists.
  var artifact: String?
}

/// Runs project actions: off the main thread, one operation per environment at a time, each with
/// its own timeout (default 10 min, never the 2 min of a profile's stop), log and result.
final class ActionStore: ObservableObject {
  static let shared = ActionStore()
  @Published private(set) var actions: [ProjectAction] = []
  @Published private(set) var runs: [UUID: ActionRun] {
    didSet { if let data = try? JSONEncoder().encode(runs) { UserDefaults.standard.set(data, forKey: "projectActionRuns") } }
  }
  /// Sessions this run of CoreScope started (cancel goes through them).
  private var reapers: [UUID: ShellRun.Reaped] = [:]
  private var cancelling = Set<UUID>()
  private var watchTimer: Timer?

  private init() {
    runs = UserDefaults.standard.data(forKey: "projectActionRuns")
      .flatMap { try? JSONDecoder().decode([UUID: ActionRun].self, from: $0) } ?? [:]
    // Started before a restart: still running if the same process lives, else unknown.
    for (id, run) in runs where run.outcome == .running {
      if cs_is_same(run.pid, run.start) != 1 {
        runs[id]?.outcome = .interrupted
        runs[id]?.endedAt = Date()
      }
    }
    watchTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.watchOrphans() }
  }
  func reload() {
    var out: [ProjectAction] = []
    for file in ProjectFileStore.shared.files {
      for (name, spec) in (file.config?.actions ?? [:]).sorted(by: { $0.key < $1.key }) {
        out.append(
          ProjectAction(
            id: stableID("\(file.file)#action#\(name)"), name: name, project: file.project, source: file.file,
            folder: file.folder, spec: spec))
      }
    }
    if out != actions { actions = out }
  }
  func find(_ name: String) -> ProjectAction? {
    let key = name.lowercased().replacingOccurrences(of: " / ", with: "/")
    return actions.first { $0.fullName.lowercased() == key || $0.id.uuidString.lowercased() == key }
  }
  func isRunning(_ action: ProjectAction) -> Bool { runs[action.id]?.outcome == .running }
  static func logURL(_ action: ProjectAction) -> URL {
    ProfileStore.logs.appendingPathComponent("action-\(action.id.uuidString.prefix(8))-\(action.name.prefix(40)).log")
  }

  /// The confirmation text: the preview command's output (read-only, 20 s, 8 KB) and its hash,
  /// which the run receives in CORESCOPE_PREVIEW_SHA256 so the controller can refuse when what
  /// it would do changed since the user saw it.
  func preview(_ action: ProjectAction, done: @escaping (Result<(text: String, hash: String), CleanupError>) -> Void) {
    guard let command = action.spec.preview else { return done(.success((L("Sem prévia configurada."), ""))) }
    DispatchQueue.global(qos: .userInitiated).async {
      let out = ShellRun.capture(command, in: action.folder, timeout: 20, maxBytes: 8 * 1024, mergeStderr: true)
      let text = String(decoding: out.output, as: UTF8.self)
      let hash = SHA256.hash(data: out.output).map { String(format: "%02x", $0) }.joined()
      let result: Result<(text: String, hash: String), CleanupError> =
        out.timedOut ? .failure(CleanupError(L("A prévia não respondeu em 20 s.")))
        : out.truncated ? .failure(CleanupError(L("A prévia passou de 8 KB.")))
        : out.status != 0 ? .failure(CleanupError(L("A prévia saiu com %@: %@", "\(out.status ?? -1)", String(text.suffix(600)))))
        : .success((text, hash))
      DispatchQueue.main.async { done(result) }
    }
  }

  /// Starts the action; nil when started, else why not. `confirmed` is required for actions with
  /// `confirm` (the caller showed the preview and the user agreed).
  @discardableResult
  func run(_ action: ProjectAction, confirmed: Bool, previewHash: String? = nil) -> String? {
    if action.confirm && !confirmed { return L("Esta ação pede confirmação antes de rodar.") }
    if isRunning(action) { return L("%@ já está rodando.", action.fullName) }
    if let other = environmentOperation(action.source, except: action.id) {
      return L("Outra operação deste ambiente está em andamento: %@", other)
    }
    try? FileManager.default.createDirectory(at: ProfileStore.logs, withIntermediateDirectories: true)
    let log = Self.logURL(action)
    guard FileManager.default.createFile(atPath: log.path, contents: Data("$ \(action.spec.run)\n".utf8)) else {
      return L("Não foi possível criar o log")
    }
    var command = action.spec.run
    // Heavy actions wait for room first with the project's own rule (`corescope wait`).
    if action.spec.heavy == true, let cli = CommandLineTool.bundled?.path {
      command = "'\(cli.replacingOccurrences(of: "'", with: "'\\''"))' wait . && { \(command)\n}"
    }
    var env = ["CORESCOPE_ACTION": action.name]
    if confirmed { env["CORESCOPE_CONFIRMED"] = "1" }
    if let previewHash, !previewHash.isEmpty { env["CORESCOPE_PREVIEW_SHA256"] = previewHash }
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, 1, log.path, O_WRONLY | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
    guard let pid = ShellRun.spawn(command, in: action.folder, actions: &fileActions, env: env) else {
      return L("Não foi possível iniciar o comando")
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let start = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
      ? info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec : 0
    let reaper = ShellRun.Reaped()
    reapers[action.id] = reaper
    runs[action.id] = ActionRun(outcome: .running, pid: pid, start: start, startedAt: Date(), log: log.path)
    let timeout = action.timeout
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
      guard reaper.endSession(pid) else { return }
      DispatchQueue.main.async {
        self?.cancelling.insert(action.id)
        self?.signalSession(pid: pid, start: start)
      }
      self?.note(log, L("passou de %@ min: encerrado pelo CoreScope", "\(Int(timeout / 60))"))
    }
    Thread.detachNewThread { [weak self] in
      let code = reaper.wait(pid)
      let tail = Self.tail(log)
      DispatchQueue.main.async { self?.finished(action, pid: pid, code: code, tail: tail, timeout: timeout) }
    }
    Monitor.shared.feedback = ActionFeedback(message: L("%@ iniciada.", action.fullName))
    return nil
  }
  private func finished(_ action: ProjectAction, pid: pid_t, code: Int32, tail: String, timeout: Double) {
    reapers[action.id] = nil
    guard var run = runs[action.id], run.pid == pid else { return }
    let wasCancelled = cancelling.remove(action.id) != nil
    run.endedAt = Date()
    run.exit = code
    if code == 0 {
      run.outcome = .succeeded
      if let path = actionArtifact(tail, folder: action.folder), FileManager.default.fileExists(atPath: path) {
        run.artifact = path
      }
    } else if wasCancelled {
      run.outcome = run.endedAt!.timeIntervalSince(run.startedAt) >= timeout - 1 ? .timedOut : .cancelled
    } else {
      run.outcome = .failed
    }
    runs[action.id] = run
    let failed = run.outcome != .succeeded
    Monitor.shared.feedback = ActionFeedback(
      message: failed ? L("%@: %@", action.fullName, outcomeLabel(run.outcome)) : L("%@ concluída.", action.fullName),
      failed: failed)
    // What the controller did is only known from its status.
    EnvironmentStore.shared.refresh(action.source)
  }
  /// SIGTERM to the action's session. The controller may still finish an operation it began.
  func cancel(_ action: ProjectAction) -> String? {
    guard let run = runs[action.id], run.outcome == .running else { return L("%@ não está rodando.", action.fullName) }
    if let reaper = reapers[action.id] {
      cancelling.insert(action.id)
      if reaper.endSession(run.pid) { note(URL(fileURLWithPath: run.log), L("cancelado pelo usuário")) }
      signalSession(pid: run.pid, start: run.start)
      return nil
    }
    // Started before a restart: only if it is still the same process.
    guard cs_is_same(run.pid, run.start) == 1 else { return L("O processo já terminou.") }
    killpg(run.pid, SIGTERM)
    signalSession(pid: run.pid, start: run.start)
    runs[action.id]?.outcome = .cancelled
    runs[action.id]?.endedAt = Date()
    return nil
  }
  /// SIGTERM to processes of the action's session that left its process group (shell job
  /// control): same user, started with or after it, identity-checked.
  private func signalSession(pid: Int32, start: UInt64) {
    guard let s = Monitor.shared.snapshot else { return }
    for p in s.processes where p.sid == pid && p.pid != pid && p.uid == s.current_uid && p.start >= start {
      if cs_is_same(p.pid, p.start) == 1 { kill(p.pid, SIGTERM) }
    }
  }
  private func note(_ log: URL, _ text: String) {
    guard let handle = try? FileHandle(forWritingTo: log) else { return }
    handle.seekToEndOfFile()
    handle.write(Data("\n[CoreScope] \(text)\n".utf8))
    try? handle.close()
  }
  /// Runs left from before a restart end when their process does.
  private func watchOrphans() {
    for (id, run) in runs where run.outcome == .running && reapers[id] == nil && cs_is_same(run.pid, run.start) != 1 {
      runs[id]?.outcome = .interrupted
      runs[id]?.endedAt = Date()
    }
  }
  static func tail(_ log: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
    defer { try? handle.close() }
    let size = handle.seekToEndOfFile()
    handle.seek(toFileOffset: size > 65536 ? size - 65536 : 0)
    return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
  }
}

/// What else of this environment (project file) is running: a controller profile's operation or
/// an action. One at a time, so CoreScope never sends two operations to the same controller.
func environmentOperation(_ source: String?, except: UUID?) -> String? {
  guard let source else { return nil }
  let profiles = ProfileStore.shared
  for p in profiles.fileProfiles where p.source == source && p.isController && p.id != except {
    if profiles.busy.contains(p.id) || profiles.inFlight(p) { return p.name }
  }
  for a in ActionStore.shared.actions where a.source == source && a.id != except && ActionStore.shared.isRunning(a) {
    return a.fullName
  }
  return nil
}

func outcomeLabel(_ outcome: ActionRun.Outcome) -> String {
  switch outcome {
  case .running: L("rodando")
  case .succeeded: L("concluída")
  case .failed: L("falhou")
  case .cancelled: L("cancelada")
  case .timedOut: L("passou do tempo limite")
  case .interrupted: L("interrompida")
  }
}
extension EnvHealth {
  var label: String {
    switch self {
    case .off: L("Desligado")
    case .starting: L("Iniciando")
    case .up: L("No ar")
    case .degraded: L("Degradado")
    case .failed: L("Falhou")
    case .unknown: L("Desconhecido")
    }
  }
  var color: Color {
    switch self {
    case .off: .secondary
    case .starting: .blue
    case .up: Tint.brand
    case .degraded, .unknown: .orange
    case .failed: .red
    }
  }
}

/// Which folded sections of the Profiles page are open (remembered); nil = the section's default.
final class FoldState: ObservableObject {
  static let shared = FoldState()
  @Published private var open: [String: Bool] {
    didSet { UserDefaults.standard.set(open, forKey: "profilesFolds") }
  }
  private init() { open = UserDefaults.standard.dictionary(forKey: "profilesFolds") as? [String: Bool] ?? [:] }
  func isOpen(_ key: String, default value: Bool = false) -> Bool { open[key] ?? value }
  func toggle(_ key: String, default value: Bool = false) { open[key] = !isOpen(key, default: value) }
}
/// A chevron row that opens or closes a section.
struct FoldHeader<Trailing: View>: View {
  let title: String
  var detail: String = ""
  let key: String
  var defaultOpen = false
  @ViewBuilder var trailing: Trailing
  @ObservedObject var folds = FoldState.shared
  var body: some View {
    let open = folds.isOpen(key, default: defaultOpen)
    HStack(spacing: 6) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { folds.toggle(key, default: defaultOpen) }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
            .foregroundStyle(.secondary).frame(width: 10)
          Text(title).font(.callout.weight(.semibold))
          if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityValue(open ? L("aberto") : L("fechado"))
      Spacer(minLength: 6)
      trailing
    }
  }
}
extension FoldHeader where Trailing == EmptyView {
  init(title: String, detail: String = "", key: String, defaultOpen: Bool = false) {
    self.init(title: title, detail: detail, key: key, defaultOpen: defaultOpen) { EmptyView() }
  }
}
extension ActionKind {
  var label: String {
    switch self {
    case .setup: L("Preparar")
    case .run: L("Subir e modos")
    case .diagnostics: L("Diagnóstico")
    case .data: L("Dados")
    case .stop: L("Parar")
    case .other: L("Outras")
    }
  }
}

/// A project's environment on the Profiles page: a summary first (apps, problems, what runs
/// now); components by app and actions by group and kind stay folded until opened.
struct EnvironmentCard: View {
  let file: ProjectFile
  @ObservedObject var environment = EnvironmentStore.shared
  @ObservedObject var actions = ActionStore.shared
  @ObservedObject var folds = FoldState.shared
  @ViewState private var confirming: ProjectAction?
  @ViewState private var preview: Result<(text: String, hash: String), CleanupError>?
  var body: some View {
    let reading = environment.readings[file.file]
    let input = environment.input(file.file)
    let fresh: Bool = if case .fresh = input { true } else { false }
    let mine = actions.actions.filter { $0.source == file.file }
    Card {
      CardHeader(title: L("Ambiente de %@", file.project), symbol: "square.stack.3d.up", tint: tint(input)) {
        if file.config?.status != nil {
          statusBadge(input, reading)
          if environment.isReading(file.file) {
            ProgressView().controlSize(.small)
          } else {
            Button {
              environment.refresh(file.file)
            } label: {
              Image(systemName: "arrow.clockwise")
            }.buttonStyle(.borderless).help(L("Ler o status agora"))
          }
        }
      }
      if let last = reading?.last {
        if !fresh {
          Text(L("Último status válido de %@ (desatualizado): nada abaixo conta como no ar.", last.collectedAt.formatted(date: .omitted, time: .standard)))
            .font(.caption).foregroundStyle(.orange)
        }
        apps(last, fresh: fresh)
        if let busy = last.busy { Label(L("Controlador ocupado: %@", busy), systemImage: "hourglass").font(.caption) }
        // Problems are never folded away; components whose state the controller could not read
        // (its engine is down) are one line, with the controller's error below.
        let problems = last.components.filter {
          $0.expected && $0.state != "unknown" && !(($0.state == "running" && $0.ready != false) || $0.state == "starting")
        }
        ForEach(problems, id: \.name) { c in componentRow(c, stale: !fresh) }
        let unread = last.components.filter { $0.expected && $0.state == "unknown" }
        if !unread.isEmpty {
          Label(
            L("%@ componentes esperados sem estado: %@", "\(unread.count)", unread.map(\.name).joined(separator: ", ")),
            systemImage: "questionmark.circle"
          ).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
        if let first = last.errors.first {
          Label(first, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
            .help(last.errors.joined(separator: "\n\n"))
        }
        components(last, fresh: fresh)
      } else if file.config?.status != nil {
        Text(reading?.error.map { L("Status indisponível: %@", $0) } ?? L("Lendo o status…")).font(.caption)
          .foregroundStyle(.secondary)
      }
      if !mine.isEmpty {
        if file.config?.status != nil { Divider() }
        actionsSection(mine, apps: reading?.last?.apps ?? [])
      }
    }
    .sheet(item: $confirming) { action in
      ActionConfirmSheet(action: action, preview: preview) { hash in
        if let error = actions.run(action, confirmed: true, previewHash: hash) {
          Monitor.shared.feedback = ActionFeedback(message: error, failed: true)
        }
        confirming = nil
      } cancel: {
        confirming = nil
      }
    }
  }

  // MARK: summary and components

  /// "revamp ● · arena ○ …": which apps are selected, each with its components' state.
  private func apps(_ s: EnvironmentStatus, fresh: Bool) -> some View {
    let expected = s.components.filter(\.expected)
    let ready = expected.filter { $0.state == "running" && $0.ready != false }
    let selected = s.apps.filter(\.selected)
    return VStack(alignment: .leading, spacing: 6) {
      Text(
        [
          L("%@ de %@ apps selecionados", "\(selected.count)", "\(s.apps.count)"),
          L("%@ de %@ componentes esperados prontos", "\(ready.count)", "\(expected.count)"),
        ].joined(separator: " · ")
      ).font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach(s.apps, id: \.name) { app in
          let parts = s.components.filter { $0.app == app.name }
          let bad = parts.contains { $0.expected && !($0.state == "running" && $0.ready != false) }
          Badge(
            text: app.name, color: !fresh || !app.selected ? .secondary : bad ? .orange : Tint.brand,
            symbol: app.selected ? "circle.fill" : "circle"
          ).help(
            app.selected
              ? L("%@ selecionado: %@ componentes", app.name, "\(parts.count)")
              : L("%@ não selecionado: não consome recursos nem gera alertas", app.name))
        }
        let shared = s.components.filter { $0.app == nil }
        if !shared.isEmpty {
          Badge(text: L("compartilhados %@", "\(shared.count)"), color: fresh ? Tint.netIn : .secondary, symbol: "square.stack")
            .help(L("Infraestrutura sem app (bancos, cache, memória dos agentes): fica no ar enquanto um app a usa."))
        }
      }
    }
  }
  /// Components by app: selected apps and shared ones open on demand; apps not selected stay a
  /// single line.
  @ViewBuilder private func components(_ s: EnvironmentStatus, fresh: Bool) -> some View {
    let key = "\(file.file)#components"
    FoldHeader(title: L("Componentes"), detail: "\(s.components.count)", key: key)
    if folds.isOpen(key) {
      let selected = s.apps.filter(\.selected).map(\.name)
      let groups = selected.map { name in (name, s.components.filter { $0.app == name }) }
        + [(L("Compartilhados"), s.components.filter { $0.app == nil })]
      ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { name, parts in
        VStack(alignment: .leading, spacing: 4) {
          Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(parts, id: \.name) { c in componentRow(c, stale: !fresh) }
        }.padding(.leading, 16)
      }
      let off = s.apps.filter { !$0.selected }.map { app in (app.name, s.components.filter { $0.app == app.name }) }
        .filter { !$0.1.isEmpty }
      if !off.isEmpty {
        let offKey = "\(file.file)#components#off"
        FoldHeader(
          title: L("Não selecionados"), detail: off.map { "\($0.0) (\($0.1.count))" }.joined(separator: " · "), key: offKey
        ).padding(.leading, 16)
        if folds.isOpen(offKey) {
          ForEach(off.flatMap(\.1), id: \.name) { c in componentRow(c, stale: !fresh) }.padding(.leading, 32)
        }
      }
    }
  }
  private func tint(_ input: StatusInput) -> Color {
    switch input {
    case .none: .secondary
    case .unavailable: .orange
    case .fresh(let s): s.failing.isEmpty ? Tint.brand : .orange
    }
  }
  @ViewBuilder private func statusBadge(_ input: StatusInput, _ reading: EnvironmentStore.Reading?) -> some View {
    switch input {
    case .fresh(let s):
      Badge(text: s.environment, color: Tint.netIn, symbol: "checkmark.seal")
        .help(L("Status coletado %@", s.collectedAt.formatted(date: .omitted, time: .standard)))
    case .unavailable(let why):
      Badge(text: L("Status desconhecido"), color: .orange, symbol: "questionmark.circle").help(reading?.error ?? why)
    case .none: EmptyView()
    }
  }
  private func componentRow(_ c: EnvironmentStatus.Component, stale: Bool) -> some View {
    let color: Color =
      stale ? .secondary
      : !c.expected ? (c.state == "running" ? Tint.netIn : .secondary)
      : c.state == "running" && c.ready != false ? Tint.brand
      : c.state == "starting" ? .blue : c.state == "unknown" ? .orange : .red
    return HStack(spacing: 8) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(c.name).font(.callout.weight(.medium)).lineLimit(1)
      if let mode = c.mode { Badge(text: mode, color: mode == "dev" ? .purple : Tint.netIn) }
      if c.controlledBy == "external" { Badge(text: L("externo"), color: .secondary).help(L("Fora do controlador: o CoreScope não para nem adota.")) }
      Spacer(minLength: 6)
      Text(componentText(c)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .help([c.reason.map { L("Mantido: %@", $0) }, c.detail].compactMap { $0 }.joined(separator: "\n"))
  }
  private func componentText(_ c: EnvironmentStatus.Component) -> String {
    if !c.expected { return c.state == "running" ? L("não selecionado, rodando") : L("não selecionado") }
    let ready = c.ready == false ? L("não pronto") : c.ready == true ? L("pronto") : ""
    let base = [c.state, ready].filter { !$0.isEmpty }.joined(separator: " · ")
    return c.reason.map { "\(base) · \(L("mantido: %@", $0))" } ?? base
  }

  // MARK: actions

  /// Running and recently failed actions on top; the rest folded by group (an app, `memory`…)
  /// and listed by kind inside it.
  @ViewBuilder private func actionsSection(_ mine: [ProjectAction], apps: [EnvironmentStatus.App]) -> some View {
    let profileApps = ProfileStore.shared.fileProfiles.filter { $0.source == file.file }.compactMap { $0.app ?? $0.key }
    let groups = actionGroups(mine.map { (name: $0.name, group: $0.spec.group) }, apps: apps.map(\.name) + profileApps)
    let prefix = actionCommonPrefix(mine.map(\.name))
    let recent = mine.filter { a in
      guard let run = actions.runs[a.id] else { return false }
      return run.outcome == .running
        || (run.outcome != .succeeded && -(run.endedAt ?? run.startedAt).timeIntervalSinceNow < 3600)
    }
    let key = "\(file.file)#actions"
    FoldHeader(title: L("Ações"), detail: "\(mine.count)", key: key) {
      if recent.contains(where: { actions.runs[$0.id]?.outcome == .running }) {
        Badge(text: L("rodando"), color: .blue, symbol: "hourglass")
      }
    }
    ForEach(recent) { a in actionRow(a, title: a.name).padding(.leading, 16) }
    if folds.isOpen(key) {
      let selected = Set(apps.filter(\.selected).map(\.name))
      let names = Array(Set(groups.values)).sorted { a, b in
        // Selected apps first, then other groups by name, general last.
        func rank(_ g: String) -> Int { g.isEmpty ? 2 : selected.contains(g) ? 0 : 1 }
        return rank(a) != rank(b) ? rank(a) < rank(b) : a < b
      }
      ForEach(names, id: \.self) { group in
        let members = mine.filter { groups[$0.name] == group }
          .sorted { (ActionKind.allCases.firstIndex(of: kind($0)) ?? 0, $0.name) < (ActionKind.allCases.firstIndex(of: kind($1)) ?? 0, $1.name) }
        let groupKey = "\(key)#\(group)"
        VStack(alignment: .leading, spacing: 4) {
          FoldHeader(
            title: group.isEmpty ? L("Geral") : group,
            detail: L("%@ ações", "\(members.count)") + (selected.contains(group) ? " · " + L("selecionado") : ""), key: groupKey)
          if folds.isOpen(groupKey) {
            ForEach(Array(members.enumerated()), id: \.element.id) { i, a in
              if i == 0 || kind(members[i - 1]) != kind(a) {
                Text(kind(a).label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).padding(.leading, 16).padding(.top, 2)
              }
              actionRow(a, title: actionShortName(a.name, group: group, prefix: prefix)).padding(.leading, 16)
            }
          }
        }.padding(.leading, 16)
      }
    }
  }
  private func kind(_ a: ProjectAction) -> ActionKind { ActionKind.of(name: a.name, explicit: a.spec.kind) }
  private func actionRow(_ a: ProjectAction, title: String) -> some View {
    let run = actions.runs[a.id]
    return HStack(spacing: 8) {
      Image(systemName: a.confirm ? "exclamationmark.shield" : "bolt").font(.caption)
        .foregroundStyle(a.confirm ? .orange : .secondary).frame(width: 14)
      Text(title).font(.callout).lineLimit(1)
      Text(a.spec.description ?? a.spec.run).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 6)
      if let run {
        Text(runText(run)).font(.caption).foregroundStyle(run.outcome == .succeeded || run.outcome == .running ? Color.secondary : .red)
          .lineLimit(1)
        if let artifact = run.artifact, run.outcome == .succeeded {
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact)])
          } label: {
            Image(systemName: "archivebox")
          }.buttonStyle(.borderless).help(L("Mostrar %@ no Finder", (artifact as NSString).lastPathComponent))
        }
        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: run.log))
        } label: {
          Image(systemName: "doc.text.magnifyingglass")
        }.buttonStyle(.borderless).help(L("Abrir log"))
      }
      if run?.outcome == .running {
        Button {
          if let error = actions.cancel(a) { Monitor.shared.feedback = ActionFeedback(message: error, failed: true) }
        } label: {
          Image(systemName: "stop.circle")
        }.buttonStyle(.borderless).help(L("Cancelar %@", a.name)).accessibilityLabel(L("Cancelar %@", a.name))
      } else {
        Button {
          start(a)
        } label: {
          Image(systemName: "play.circle")
        }.buttonStyle(.borderless).help(L("Executar %@: %@", a.name, a.spec.run)).accessibilityLabel(L("Executar %@", a.name))
      }
    }
    .padding(.vertical, 1)
    .help(a.spec.description.map { "\($0)\n\(a.spec.run)" } ?? a.spec.run)
  }
  private func runText(_ run: ActionRun) -> String {
    switch run.outcome {
    case .running: return L("rodando há %@", formatDuration(Date().timeIntervalSince(run.startedAt)))
    case .failed: return L("falhou · saída %@", "\(run.exit ?? -1)")
    default:
      let when = (run.endedAt ?? run.startedAt).formatted(.relative(presentation: .named))
      return "\(outcomeLabel(run.outcome)) · \(when)"
    }
  }
  private func start(_ a: ProjectAction) {
    guard a.confirm else {
      if let error = actions.run(a, confirmed: false) { Monitor.shared.feedback = ActionFeedback(message: error, failed: true) }
      return
    }
    preview = nil
    confirming = a
    actions.preview(a) { preview = $0 }
  }
}

/// Before an action that asks for confirmation: its preview (what file, from where, from when,
/// onto what) and an explicit Run.
private struct ActionConfirmSheet: View {
  let action: ProjectAction
  let preview: Result<(text: String, hash: String), CleanupError>?
  let run: (String) -> Void
  let cancel: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Executar %@?", action.fullName)).font(.title3.weight(.semibold))
      Text(action.spec.description ?? action.spec.run).foregroundStyle(.secondary)
      Text(action.spec.run).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      Group {
        switch preview {
        case nil: HStack { ProgressView().controlSize(.small); Text(L("Lendo a prévia…")) }
        case .failure(let e): Label(e.description, systemImage: "xmark.octagon").foregroundStyle(.red)
        case .success(let p):
          ScrollView {
            Text(p.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 220).padding(8).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      Text(L("A prévia vem do comando do projeto e é mostrada como está. Confira o arquivo, a origem, a data e o destino antes de continuar."))
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button(L("Cancelar"), action: cancel).keyboardShortcut(.cancelAction)
        Button(L("Executar"), role: .destructive) {
          if case .success(let p) = preview { run(p.hash) }
        }.disabled({ if case .success = preview { false } else { true } }())
      }
    }
    .padding(20)
    .frame(width: 560)
  }
}
