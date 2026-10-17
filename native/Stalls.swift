import AppKit
import SwiftUI

/// When agents last wrote to their transcripts: modification times only, never contents.
enum Transcripts {
  private static let home = FileManager.default.homeDirectoryForCurrentUser
  /// Codex rollout file per thread id; touched only from the agents queue.
  private static var rollouts: [String: URL] = [:]

  /// Busy Claude sessions ("claude:<sessionId>") and running Codex threads ("codex:<threadId>").
  static func lastWrites(claude: [ClaudeSessionMeta], codex: [CodexThread]) -> [String: Double] {
    var out: [String: Double] = [:]
    for meta in claude where meta.isBusy {
      guard let id = meta.sessionId, let cwd = meta.cwd else { continue }
      if let date = claudeWrite(session: id, cwd: cwd) { out["claude:\(id)"] = date }
    }
    for thread in codex where thread.running {
      if let url = rollout(thread.id), let date = modified(url) { out["codex:\(thread.id)"] = date }
    }
    return out
  }
  private static func modified(_ url: URL) -> Double? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?
      .timeIntervalSince1970
  }
  /// The session transcript, or any of its subagents' (a Task writes there, not to the main file).
  private static func claudeWrite(session: String, cwd: String) -> Double? {
    let projects = home.appendingPathComponent(".claude/projects")
    var folder = projects.appendingPathComponent(claudeProjectFolder(cwd))
    if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(session).jsonl").path) {
      let all = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
      guard
        let found = all.prefix(400).first(where: {
          FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(session).jsonl").path)
        })
      else { return nil }
      folder = found
    }
    var newest = modified(folder.appendingPathComponent("\(session).jsonl"))
    let subagents = folder.appendingPathComponent("\(session)/subagents")
    for file in (try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? [] {
      if let date = modified(file), date > (newest ?? 0) { newest = date }
    }
    return newest
  }
  /// `~/.codex/sessions/YYYY/MM/DD/rollout-…-<threadId>.jsonl`, looked up over the last week.
  private static func rollout(_ thread: String) -> URL? {
    if let url = rollouts[thread], FileManager.default.fileExists(atPath: url.path) { return url }
    let root = home.appendingPathComponent(".codex/sessions")
    let calendar = Calendar(identifier: .gregorian)
    for back in 0..<7 {
      guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
      let c = calendar.dateComponents([.year, .month, .day], from: day)
      let dir = root.appendingPathComponent(
        String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
      let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
      if let name = files.first(where: { $0.hasSuffix("-\(thread).jsonl") }) {
        let url = dir.appendingPathComponent(name)
        rollouts[thread] = url
        return url
      }
    }
    return nil
  }
}

extension ClaudeSessionMeta {
  var isBusy: Bool { status.map { $0 != "idle" } ?? false }
}

/// Decides, for the session cards and for notifications, whether a busy agent looks stuck.
final class StallWatch {
  static let shared = StallWatch()
  /// Helpers agents keep around during a turn that say nothing about progress.
  private static let helpers: Set<String> = ["caffeinate", "disclaimer"]
  /// Session key → `since` of the stall already notified, so each episode alerts once.
  private var notified: [String: Double] = [:]

  var threshold: Double { Preferences.shared.stallMinutes * 60 }

  func stall(root: ProcessItem, tree: [ProcessItem], meta: ClaudeSessionMeta?) -> AgentStall? {
    guard let meta, meta.isBusy, let id = meta.sessionId else { return nil }
    let busySince = (meta.statusUpdatedAt ?? meta.updatedAt).map { $0 / 1000 } ?? root.startDate.timeIntervalSince1970
    let children = tree.filter { $0.pid != root.pid && !Self.helpers.contains($0.name) }.map {
      TurnChild(
        name: $0.name, cpu: $0.cpu.value ?? 0, start: $0.startDate.timeIntervalSince1970,
        listening: !$0.ports.isEmpty)
    }
    return agentStall(
      busySince: busySince, lastWrite: AgentStore.shared.lastWrites["claude:\(id)"], children: children,
      now: Date().timeIntervalSince1970, threshold: threshold)
  }
  func stall(thread: CodexThread) -> AgentStall? {
    guard thread.running else { return nil }
    return agentStall(
      busySince: thread.turnStarted ?? thread.updated.timeIntervalSince1970,
      lastWrite: AgentStore.shared.lastWrites["codex:\(thread.id)"], children: [],
      now: Date().timeIntervalSince1970, threshold: threshold)
  }

  /// After each agent refresh (every 20 s): one notification per stall episode, when enabled.
  func evaluate() {
    let prefs = Preferences.shared
    guard prefs.notifyStalls, let snapshot = Monitor.shared.snapshot else {
      notified.removeAll()
      return
    }
    let nodes = snapshot.processes.map { (pid: $0.pid, ppid: $0.ppid) }
    let byPID = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var active = Set<String>()
    for meta in AgentStore.shared.claudeSessions.values {
      guard let root = byPID[meta.pid], let id = meta.sessionId else { continue }
      let tree = descendantIDs(root: root.pid, nodes: nodes).compactMap { byPID[$0] }
      guard let stall = stall(root: root, tree: tree, meta: meta), stall.suspicious else { continue }
      let key = "claude:\(id)"
      active.insert(key)
      let title = meta.name ?? root.project ?? "Claude Code"
      alert(key: key, stall: stall, agent: "Claude Code", title: title, url: meta.desktopURL)
    }
    for thread in AgentStore.shared.codexThreads {
      guard let stall = stall(thread: thread), stall.suspicious else { continue }
      let key = "codex:\(thread.id)"
      active.insert(key)
      alert(key: key, stall: stall, agent: "Codex", title: thread.title, url: thread.url)
    }
    notified = notified.filter { active.contains($0.key) }
  }
  private func alert(key: String, stall: AgentStall, agent: String, title: String, url: URL?) {
    guard notified[key] != stall.since else { return }
    notified[key] = stall.since
    Notifier.shared.agentStalled(key: key, title: L("%@ parece travado", agent), body: "\(title)\n\(stall.summary)", url: url)
  }
}

extension AgentStall {
  var minutes: Int { max(1, Int((Date().timeIntervalSince1970 - since) / 60)) }
  /// One line for badges, tooltips and notifications.
  var summary: String {
    switch self {
    case .longCommand(let name, _): L("Rodando %@ há %@ min, sem novas mensagens", name, "\(minutes)")
    case .waiting(let name, _): L("Esperando %@ há %@ min: pode estar pedindo uma entrada", name, "\(minutes)")
    case .silent: L("Sem atividade há %@ min", "\(minutes)")
    }
  }
}

/// Replaces the "Working" badge while a stall lasts.
struct StallBadge: View {
  let stall: AgentStall
  var body: some View {
    Badge(
      text: stall.suspicious ? L("Parece travada · %@ min", "\(stall.minutes)") : L("Comando longo · %@ min", "\(stall.minutes)"),
      color: stall.suspicious ? .orange : .yellow,
      symbol: stall.suspicious ? "exclamationmark.triangle.fill" : "hourglass"
    ).help(stall.summary)
  }
}
