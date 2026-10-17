import Foundation
import SwiftUI

/// Installs CoreScope's `corescope gate` PreToolUse hook in ~/.claude/settings.json (opt-in): Claude
/// Code then waits for room before heavy commands in projects whose .corescope.yml asks for it.
/// Same care as the status line bridge: a backup first, key order kept, only our entry touched.
enum ClaudeGateBridge {
  static var binary: String? { CommandLineTool.bundled?.path }
  static func installed() -> Bool {
    guard let text = try? String(contentsOf: ClaudeLimitsBridge.settingsFile, encoding: .utf8),
      let settings = try? OrderedJSON.parse(text)
    else { return false }
    return ClaudeGateHook.installed(in: settings)
  }
  /// nil on success, else a message.
  static func set(_ on: Bool) -> String? {
    let file = ClaudeLimitsBridge.settingsFile
    let existed = FileManager.default.fileExists(atPath: file.path)
    guard let text = existed ? try? String(contentsOf: file, encoding: .utf8) : "{}\n" else {
      return L("Não foi possível ler ~/.claude/settings.json")
    }
    guard let settings = try? OrderedJSON.parse(text), case .object = settings else {
      return L("~/.claude/settings.json não é um JSON válido; corrija o arquivo antes.")
    }
    let next: OrderedJSON
    if on {
      guard let binary else { return L("Comando corescope não encontrado no app.") }
      next = ClaudeGateHook.installing(into: settings, binary: binary)
    } else {
      next = ClaudeGateHook.removing(from: settings)
    }
    guard next != settings else { return nil }
    do {
      if existed { try ClaudeLimitsBridge.backup(text) }
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
