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
    return hook == .gate ? "CoreScope: waiting for the Mac to have room if this is heavy" : "CoreScope: project context"
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

/// A heavy command an agent is holding until the Mac has room (written by `corescope gate`).
struct GateWait: Decodable, Identifiable, Equatable {
  let agent_pid: Int32
  let folder: String
  let command: String
  let reason: String
  let since: Double
  var id: String { "\(agent_pid)-\(since)" }
  static let folder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CoreScope/gates")
  /// Current waits; files whose gate process is gone are stale and removed.
  static func read() -> [GateWait] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    var out: [GateWait] = []
    for file in files where file.pathExtension == "json" {
      let pid = Int32(file.deletingPathExtension().lastPathComponent) ?? 0
      guard pid > 0, kill(pid, 0) == 0 else {
        try? FileManager.default.removeItem(at: file)
        continue
      }
      if let data = try? Data(contentsOf: file), let wait = try? JSONDecoder().decode(GateWait.self, from: data) {
        out.append(wait)
      }
    }
    return out.sorted { $0.since < $1.since }
  }
}

/// Agents page: who is waiting for the Mac, for which command and why.
struct GateWaitsCard: View {
  let waits: [GateWait]
  var body: some View {
    if !waits.isEmpty {
      Card {
        CardHeader(title: L("Aguardando capacidade"), symbol: "hourglass", tint: .orange, count: waits.count)
        ForEach(waits) { w in
          HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
              Text(w.command).font(.system(.callout, design: .monospaced))
              Text("\(projectName(w.folder) ?? w.folder) · \(w.reason)").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(Date(timeIntervalSince1970: w.since).formatted(.relative(presentation: .named))).font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(
          L("O projeto pede que agentes esperem a máquina ter folga antes de comandos pesados (.corescope.yml › agents.wait_for_capacity). O comando começa sozinho quando a CPU e a memória normalizarem.")
        ).font(.caption).foregroundStyle(.secondary)
      }
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
struct AgentConflictsCard: View {
  let snapshot: Snapshot
  let threads: [CodexThread]
  private static func workingTree(_ path: String) -> String? {
    var url = URL(fileURLWithPath: path)
    for _ in 0..<12 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
      let parent = url.deletingLastPathComponent()
      if parent.path == url.path { return nil }
      url = parent
    }
    return nil
  }
  private var groups: [(tree: String, members: [String])] {
    var trees: [String: [String]] = [:]
    for root in snapshot.agentSessions where !root.cwd.isEmpty {
      if let tree = Self.workingTree(root.cwd) {
        trees[tree, default: []].append("\(root.host ?? root.name) \(root.pid)")
      }
    }
    for t in threads where t.running {
      if let cwd = t.cwd, let tree = Self.workingTree(cwd) { trees[tree, default: []].append("Codex · \(t.title)") }
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
