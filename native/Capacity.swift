import Foundation
import SwiftUI

/// Agents whose hooks file CoreScope can add its hooks to.
enum HookHost: String, CaseIterable, Identifiable {
  case claude = "Claude Code"
  case codex = "Codex"
  var id: String { rawValue }
  /// Follows a dotfiles symlink so the real file is edited and the link survives.
  var file: URL {
    switch self {
    case .claude: ClaudeLimitsBridge.settingsFile
    case .codex:
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json").resolvingSymlinksInPath()
    }
  }
  var shortPath: String { self == .claude ? "~/.claude/settings.json" : "~/.codex/hooks.json" }
  fileprivate var backupPrefix: String { self == .claude ? "settings" : "codex-hooks" }
  /// Codex shows this while the hook runs; Claude Code has no such field.
  func statusMessage(_ hook: AgentHook) -> String? {
    guard self == .codex else { return nil }
    return hook == .gate ? "CoreScope: checking room for heavy commands" : "CoreScope: project context"
  }
  /// Codex is set up on this Mac (its folder exists).
  var available: Bool {
    self == .claude
      || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
  }
}

/// Installs CoreScope's hooks (opt-in): `corescope gate` before shell commands (heavy ones wait
/// for room in projects whose .corescope.yml asks for it) and `corescope context --hook` at
/// session start (the project's .corescope.yml summed up for the agent). Same care as the status
/// line bridge: a backup first, key order kept, only CoreScope's entries touched.
enum AgentHooksBridge {
  static var binary: String? { CommandLineTool.bundled?.path }
  private static func read(_ host: HookHost) -> OrderedJSON? {
    guard let text = try? String(contentsOf: host.file, encoding: .utf8) else { return nil }
    return try? OrderedJSON.parse(text)
  }
  static func installed(_ hook: AgentHook, in host: HookHost) -> Bool { hook.installed(in: read(host)) }
  /// nil on success, else a message.
  static func set(_ hook: AgentHook, in host: HookHost, _ on: Bool) -> String? {
    let file = host.file
    let existed = FileManager.default.fileExists(atPath: file.path)
    guard let text = existed ? try? String(contentsOf: file, encoding: .utf8) : "{}\n" else {
      return L("Não foi possível ler %@", host.shortPath)
    }
    guard let settings = try? OrderedJSON.parse(text), case .object = settings else {
      return L("%@ não é um JSON válido; corrija o arquivo antes.", host.shortPath)
    }
    let next: OrderedJSON
    if on {
      guard let binary else { return L("Comando corescope não encontrado no app.") }
      next = hook.installing(into: settings, binary: binary, statusMessage: host.statusMessage(hook))
    } else {
      next = hook.removing(from: settings)
    }
    guard next != settings else { return nil }
    do {
      if existed { try ClaudeLimitsBridge.backup(text, prefix: host.backupPrefix) }
      // Codex's hooks.json holds only hooks: one left empty by CoreScope goes away.
      if host == .codex, next == .object([]) {
        try FileManager.default.removeItem(at: file)
        return nil
      }
      try ClaudeLimitsBridge.write(next.serialized() + ClaudeLimitsBridge.trailing(text.isEmpty ? "\n" : text), to: file)
      return nil
    } catch {
      return error.localizedDescription
    }
  }
}

/// A heavy command in CoreScope's admission queue (shared by every agent session; written by
/// `corescope gate`, the MCP capacity tools and `corescope wait`).
struct AdmissionEntry: Decodable, Identifiable, Equatable {
  let agent_pid: Int32
  let folder: String
  let command: String
  let weight: Double
  let containers: [String]?
  /// waiting, granted (its next run goes) or running.
  let state: String
  let since: Double
  let seen: Double
  let reason: String?
  var id: String { "\(agent_pid)-\(command)-\(state)" }
}
/// One gate decision.
struct AdmissionEvent: Decodable, Identifiable, Equatable {
  let at: Double
  let agent_pid: Int32
  let folder: String
  let command: String
  let outcome: String
  let reason: String?
  let via: String
  var id: String { "\(at)-\(agent_pid)-\(command)" }
}
struct AdmissionState: Decodable, Equatable {
  var entries: [AdmissionEntry] = []
  var events: [AdmissionEvent] = []
  /// Off the main thread: reads and prunes the queue file.
  static func read() -> AdmissionState {
    guard let pointer = #"{"op":"list"}"#.withCString({ cs_capacity_queue($0) }) else { return AdmissionState() }
    defer { cs_free(pointer) }
    return (try? JSONDecoder().decode(AdmissionState.self, from: Data(bytes: pointer, count: strlen(pointer)))) ?? AdmissionState()
  }
  /// Run now: the agent's next run of the command is admitted whatever the readings say.
  static func grant(_ e: AdmissionEntry, done: @escaping () -> Void) {
    let request = (try? JSONSerialization.data(withJSONObject: ["op": "grant", "agent_pid": Int(e.agent_pid), "command": e.command]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    DispatchQueue.global(qos: .userInitiated).async {
      if let pointer = request.withCString({ cs_capacity_queue($0) }) { cs_free(pointer) }
      DispatchQueue.main.async(execute: done)
    }
  }
}

/// Agents page: heavy commands running, waiting (why, since when, Run now) and the latest
/// decisions of the admission queue.
struct AdmissionCard: View {
  let state: AdmissionState
  var refresh: () -> Void = {}
  private func since(_ t: Double) -> String {
    Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named))
  }
  var body: some View {
    let running = state.entries.filter { $0.state != "waiting" }
    let waiting = state.entries.filter { $0.state == "waiting" }
    let recent = state.events.filter { $0.outcome == "deferred" || $0.outcome == "failed_open" }.suffix(4)
    if !state.entries.isEmpty || !recent.isEmpty {
      Card {
        CardHeader(title: L("Fila de comandos pesados"), symbol: "hourglass", tint: .orange, count: waiting.count)
        ForEach(running) { e in
          row(e, symbol: "play.circle.fill", tint: .green,
              detail: e.state == "granted" ? L("vez reservada · começa na próxima execução") : L("rodando · peso %@", String(format: "%g", e.weight)),
              time: e.seen)
        }
        ForEach(waiting) { e in
          HStack(alignment: .top, spacing: 8) {
            row(e, symbol: "pause.circle", tint: .orange, detail: e.reason ?? "", time: e.since)
            Button(L("Rodar agora")) { AdmissionState.grant(e, done: refresh) }
              .controlSize(.small)
              .help(L("A próxima execução deste comando por esse agente passa direto, mesmo sem folga."))
          }
        }
        if !recent.isEmpty {
          Divider()
          Text(L("Decisões recentes")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(Array(recent.reversed())) { ev in
            HStack(alignment: .top, spacing: 6) {
              Image(systemName: ev.outcome == "failed_open" ? "exclamationmark.triangle" : "arrow.uturn.backward.circle")
                .foregroundStyle(ev.outcome == "failed_open" ? .orange : .secondary)
              Text("\(ev.command) · \(ev.reason ?? "")").font(.caption).foregroundStyle(.secondary).lineLimit(2)
              Spacer()
              Text(since(ev.at)).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Text(
          L("Projetos com agents.wait_for_capacity no .corescope.yml passam comandos pesados por esta fila: a decisão sai na hora, com o motivo para o agente; um de cada vez por contêiner e no máximo max_parallel ao mesmo tempo.")
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func row(_ e: AdmissionEntry, symbol: String, tint: Color, detail: String, time: Double) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbol).foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(e.command).font(.system(.callout, design: .monospaced))
        let where_ = [projectName(e.folder) ?? e.folder, (e.containers ?? []).isEmpty ? nil : (e.containers ?? []).joined(separator: ", ")]
          .compactMap { $0 }.joined(separator: " · ")
        Text("\(where_) · \(detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      Text(since(time)).font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Economy mode: on battery, busy processes that agent sessions started run at Darwin background
/// priority (CPU and I/O yield to what you are doing); restored on AC power or when turned off.
/// Servers with listening ports are left alone — you are probably using them.
final class EconomyWatch {
  static let shared = EconomyWatch()
  /// pid → start time of the processes CoreScope moved to the background.
  private(set) var throttled: [Int32: UInt64] = [:]
  private let queue = DispatchQueue(label: "app.corescope.economy", qos: .utility)

  func evaluate(_ s: Snapshot) {
    let on = Preferences.shared.economyMode && s.battery.map { !$0.on_ac } == true
    guard on else {
      restoreAll()
      return
    }
    let alive = Set(s.processes.map { "\($0.pid):\($0.start)" })
    throttled = throttled.filter { alive.contains("\($0.key):\($0.value)") }
    var targets: [(Int32, UInt64)] = []
    for root in s.agentSessions {
      for p in s.subtree(of: root) where p.pid != root.pid && p.ports.isEmpty && (p.cpu.value ?? 0) >= 5
        && throttled[p.pid] == nil && p.uid == s.current_uid
      {
        targets.append((p.pid, p.start))
      }
    }
    guard !targets.isEmpty else { return }
    for (pid, start) in targets { throttled[pid] = start }
    queue.async {
      for (pid, start) in targets {
        if let pointer = cs_background(pid, start, 1) { cs_free(pointer) }
      }
    }
  }
  private func restoreAll() {
    guard !throttled.isEmpty else { return }
    let list = throttled
    throttled = [:]
    queue.async {
      for (pid, start) in list {
        if let pointer = cs_background(pid, start, 0) { cs_free(pointer) }
      }
    }
  }
}

/// Agent sessions (and running Codex threads) sharing one git working tree: they can overwrite
/// each other's files and fight over ports and dev servers.
/// The git working tree around each folder, found off the main thread and remembered: the
/// folders are often on an external disk, and a stat there stalls for seconds under heavy I/O.
final class WorkingTrees: ObservableObject {
  static let shared = WorkingTrees()
  /// folder → its working tree ("" when it has none).
  @Published private(set) var known: [String: String] = [:]
  private var pending = Set<String>()
  private let queue = DispatchQueue(label: "app.corescope.worktrees", qos: .utility)
  /// The tree if already known; otherwise nil, and it is looked up in the background.
  func tree(_ folder: String) -> String? {
    if let tree = known[folder] { return tree.isEmpty ? nil : tree }
    if pending.insert(folder).inserted {
      queue.async {
        let tree = Self.find(folder) ?? ""
        DispatchQueue.main.async {
          self.pending.remove(folder)
          if self.known.count > 500 { self.known = [:] }
          self.known[folder] = tree
        }
      }
    }
    return nil
  }
  private static func find(_ path: String) -> String? {
    var url = URL(fileURLWithPath: path)
    for _ in 0..<12 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { return nil }
      url = parent
    }
    return nil
  }
}

struct AgentConflictsCard: View {
  let snapshot: Snapshot
  let threads: [CodexThread]
  @ObservedObject private var trees = WorkingTrees.shared
  private var groups: [(tree: String, members: [String])] {
    var trees: [String: [String]] = [:]
    for root in snapshot.agentSessions where !root.cwd.isEmpty {
      if let tree = self.trees.tree(root.cwd) {
        trees[tree, default: []].append("\(root.host ?? root.name) \(root.pid)")
      }
    }
    for t in threads where t.running {
      if let cwd = t.cwd, let tree = self.trees.tree(cwd) { trees[tree, default: []].append("Codex · \(t.title)") }
    }
    return trees.filter { $0.value.count > 1 }.map { ($0.key, $0.value) }.sorted { $0.tree < $1.tree }
  }
  var body: some View {
    let groups = groups
    if !groups.isEmpty {
      Card {
        CardHeader(title: L("Sessões no mesmo diretório"), symbol: "person.2.wave.2", tint: .orange, count: groups.count)
        ForEach(groups, id: \.tree) { g in
          VStack(alignment: .leading, spacing: 3) {
            Text(abbreviateHome(g.tree)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
            Text(g.members.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        Text(
          L("Várias sessões de agente no mesmo diretório de trabalho podem sobrescrever os arquivos umas das outras e disputar portas e o servidor de dev. Dê a cada uma um git worktree próprio.")
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
