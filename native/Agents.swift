import AppKit
import SwiftUI

/// One usage window reported by an agent (e.g. Codex weekly limit).
struct LimitWindow: Identifiable, Equatable {
  let id: String
  let usedPercent: Double
  let windowMinutes: Int
  let resetsAt: Date?
  var label: String {
    switch windowMinutes {
    case 10080: L("Semanal")
    case 300: L("5 horas")
    case let m where m % 1440 == 0: L("%@ dias", String(m / 1440))
    default: L("%@ h", String(windowMinutes / 60))
    }
  }
  var resetText: String? {
    resetsAt.map { L("reinicia em %@", formatDuration(max(0, $0.timeIntervalSinceNow))) }
  }
  var color: Color { usedPercent >= 90 ? .red : usedPercent >= 70 ? .orange : Tint.brand }
}
/// Metadata Claude Code keeps per running session in ~/.claude/sessions/<pid>.json.
struct ClaudeSessionMeta: Decodable, Equatable {
  let pid: Int32
  let sessionId: String?
  var cwd: String?
  let version: String?
  let entrypoint: String?
  var name: String?
  let status: String?
  let updatedAt: Double?
}
struct CodexUsage: Equatable {
  var windows: [LimitWindow] = []
  var plan: String?
  var credits: String?
  var observedAt: Date?
  var weekly: LimitWindow? { windows.first { $0.windowMinutes == 10080 } ?? windows.last }
}

/// Reads agent metadata from local files only (no network, no credentials). Codex limits come
/// from the `rate_limits` events its CLI writes to session logs; Claude Code does not store its
/// usage limits on disk, so only session metadata is available for it.
final class AgentStore: ObservableObject {
  static let shared = AgentStore()
  @Published private(set) var codex = CodexUsage()
  @Published private(set) var claudeSessions: [Int32: ClaudeSessionMeta] = [:]
  private let queue = DispatchQueue(label: "app.corescope.agents", qos: .utility)
  private var timer: Timer?
  private var lastCodexFile: (URL, Date)?
  init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      self?.refresh()
    }
    timer?.tolerance = 5
  }
  func refresh() {
    queue.async {
      let codex = self.readCodex()
      let sessions = Self.readClaudeSessions()
      DispatchQueue.main.async {
        // Publish only real changes so idle refreshes do not redraw the interface.
        if let codex, codex != self.codex { self.codex = codex }
        if sessions != self.claudeSessions { self.claudeSessions = sessions }
      }
    }
  }

  private static let home = FileManager.default.homeDirectoryForCurrentUser
  private static func newest(in dir: URL, files: Bool) -> [URL] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    return items.filter { files ? $0.pathExtension == "jsonl" : $0.hasDirectoryPath }
      .sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (a ?? .distantPast) > (b ?? .distantPast)
      }
  }
  /// Most recent session logs: sessions/YYYY/MM/DD/*.jsonl, newest day first.
  private static func recentCodexLogs(limit: Int) -> [URL] {
    let root = home.appendingPathComponent(".codex/sessions")
    var out: [URL] = []
    for year in newest(in: root, files: false).prefix(2) {
      for month in newest(in: year, files: false).prefix(2) {
        for day in newest(in: month, files: false).prefix(3) {
          out += newest(in: day, files: true).prefix(limit)
          if out.count >= limit { return Array(out.prefix(limit)) }
        }
      }
    }
    return out
  }
  private func readCodex() -> CodexUsage? {
    for file in Self.recentCodexLogs(limit: 4) {
      let modified =
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
      if let last = lastCodexFile, last.0 == file, last.1 == modified { return nil }
      if let usage = Self.parseCodexTail(file, modified: modified) {
        lastCodexFile = (file, modified)
        return usage
      }
    }
    return nil
  }
  /// Reads only the last 384 KB and keeps nothing but the newest rate_limits object.
  private static func parseCodexTail(_ file: URL, modified: Date) -> CodexUsage? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let chunk: UInt64 = 384 * 1024
    try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
    else { return nil }
    for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let limits = findKey("rate_limits", in: object) as? [String: Any]
      else { continue }
      var usage = CodexUsage(observedAt: modified)
      for key in ["primary", "secondary"] {
        guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double else {
          continue
        }
        let minutes = (w["window_minutes"] as? Int) ?? 0
        var reset: Date?
        if let at = w["resets_at"] as? Double {
          reset = Date(timeIntervalSince1970: at)
        } else if let seconds = w["resets_in_seconds"] as? Double {
          reset = modified.addingTimeInterval(seconds)
        }
        usage.windows.append(
          LimitWindow(id: key, usedPercent: used, windowMinutes: minutes, resetsAt: reset))
      }
      usage.plan = limits["plan_type"] as? String
      if let credits = limits["credits"] as? [String: Any], let balance = credits["balance"] as? String,
        let value = Double(balance)
      {
        usage.credits = Demo.enabled ? nil : String(format: "%.0f", value)
      }
      return usage.windows.isEmpty ? nil : usage
    }
    return nil
  }
  private static func findKey(_ key: String, in object: Any) -> Any? {
    if let dict = object as? [String: Any] {
      if let value = dict[key], !(value is NSNull) { return value }
      for value in dict.values { if let found = findKey(key, in: value) { return found } }
    } else if let array = object as? [Any] {
      for value in array { if let found = findKey(key, in: value) { return found } }
    }
    return nil
  }
  private static func readClaudeSessions() -> [Int32: ClaudeSessionMeta] {
    let dir = home.appendingPathComponent(".claude/sessions")
    let files =
      (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
      .filter { $0.pathExtension == "json" } ?? []
    var out: [Int32: ClaudeSessionMeta] = [:]
    for file in files.prefix(64) {
      guard let data = try? Data(contentsOf: file), data.count < 64 * 1024,
        var meta = try? JSONDecoder().decode(ClaudeSessionMeta.self, from: data)
      else { continue }
      if Demo.enabled {
        meta.name = Demo.sessionTitle(meta.pid)
        meta.cwd = meta.cwd.map(Demo.path)
      }
      out[meta.pid] = meta
    }
    return out
  }
}

// MARK: - Limits UI

struct LimitBar: View {
  let title: String
  let window: LimitWindow
  var compact = false
  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 3 : 5) {
      HStack(spacing: 6) {
        Text(title).font(.system(size: compact ? 10.5 : 12, weight: .semibold))
        Text(window.label).font(.system(size: compact ? 9.5 : 11)).foregroundStyle(.secondary)
        Spacer(minLength: 4)
        Text(String(format: "%.0f%%", window.usedPercent))
          .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded)).monospacedDigit()
          .foregroundStyle(window.color)
      }
      MeterBar(fraction: window.usedPercent / 100, color: window.color)
      if !compact, let reset = window.resetText {
        Text(reset).font(.caption).foregroundStyle(.secondary)
      }
    }
    .help(window.resetText ?? "")
  }
}

/// Usage limits card: Codex from its local logs; Claude explains why it is not available.
struct LimitsCard: View {
  @ObservedObject var agents = AgentStore.shared
  var body: some View {
    Card {
      CardHeader(title: L("Limites de uso"), symbol: "gauge.with.dots.needle.33percent", tint: .orange)
      HStack(alignment: .top, spacing: 18) {
        VStack(alignment: .leading, spacing: 10) {
          if agents.codex.windows.isEmpty {
            LimitPlaceholder(
              title: "Codex", text: L("Sem eventos de limite nos logs recentes do Codex."))
          } else {
            ForEach(agents.codex.windows) { w in LimitBar(title: "Codex", window: w) }
            Text(
              [agents.codex.plan.map { L("Plano %@", $0) }, agents.codex.credits.map { L("créditos %@", $0) },
               agents.codex.observedAt.map { L("lido %@", $0.formatted(date: .omitted, time: .shortened)) }]
                .compactMap { $0 }.joined(separator: " · ")
            ).font(.caption2).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        LimitPlaceholder(
          title: "Claude Code",
          text: L(
            "O Claude Code não grava o limite semanal em disco. Use /usage no Claude Code; o CoreScope não lê credenciais nem acessa a rede."
          )
        ).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
private struct LimitPlaceholder: View {
  let title: String
  let text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 12, weight: .semibold))
      Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Agents page

struct AgentsView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var agents = AgentStore.shared
  var body: some View {
    ScrollView {
      if let s = monitor.snapshot {
        VStack(alignment: .leading, spacing: 16) {
          LimitsCard()
          let sessions = s.agentSessions
          HStack {
            Text(L("Sessões ativas")).font(.system(size: 15, weight: .semibold))
            Badge(text: "\(sessions.count)", color: .orange)
            Spacer()
            let tree = sessions.flatMap { s.subtree(of: $0) }
            Text(
              L(
                "%@ processos · CPU %@ · %@", String(tree.count),
                String(format: "%.1f%%", tree.compactMap(\.cpu.value).reduce(0, +)),
                formatBytes(tree.compactMap(\.memory.value).reduce(0, +)))
            ).font(.caption).foregroundStyle(.secondary).monospacedDigit()
          }
          if sessions.isEmpty {
            Card {
              EmptyNote(
                text: L(
                  "Nenhuma sessão de Claude Code, Codex ou outro agente em execução (desktop ou terminal)."))
            }
          }
          ForEach(sessions) { root in
            SessionCard(root: root, tree: s.subtree(of: root), meta: agents.claudeSessions[root.pid])
          }
          let orphans = s.orphans
          if !orphans.isEmpty {
            Card {
              CardHeader(
                title: L("Possíveis órfãos"), symbol: "exclamationmark.triangle", tint: .orange,
                count: orphans.count)
              ForEach(orphans) { p in
                ProcessLine(process: p, subtitle: devSubtitle(p)) { KillButton(process: p) }
                  .help(L(p.orphan ?? ""))
              }
            }
          }
        }.padding(20)
      } else {
        ProgressView(L("Lendo processos…")).frame(maxWidth: .infinity, minHeight: 320)
      }
    }
  }
}

private struct SessionCard: View {
  let root: ProcessItem
  let tree: [ProcessItem]
  let meta: ClaudeSessionMeta?
  @ViewState private var expanded = false
  private var busy: Bool? { meta?.status.map { $0 != "idle" } }
  var body: some View {
    // Spawn order (start time) keeps the list steady between samples.
    let children = tree.filter { $0.pid != root.pid && $0.name != "disclaimer" }
      .sorted { ($0.start, $0.pid) < ($1.start, $1.pid) }
    let cpu = tree.compactMap(\.cpu.value).reduce(0, +)
    let memory = tree.compactMap(\.memory.value).reduce(0, +)
    let ports = tree.flatMap(\.ports)
    Card {
      HStack(spacing: 10) {
        ProcessIcon(process: root, size: 28)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(meta?.name ?? root.project ?? root.host ?? root.name)
              .font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let busy {
              Badge(
                text: busy ? L("Trabalhando") : L("Ociosa"), color: busy ? Tint.brand : .secondary,
                symbol: busy ? "bolt.fill" : "moon.fill")
            }
            Badge(text: root.sessionSource, color: .orange)
          }
          Text(
            [root.host, root.project, L("ativo há %@", formatDuration(root.uptime)), meta?.version.map { "v\($0)" }]
              .compactMap { $0 }.joined(separator: " · ")
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        stat(L("Processos"), "\(tree.count)")
        stat("CPU", String(format: "%.1f%%", cpu))
        stat(L("Memória"), formatBytes(memory))
        if !root.cwd.isEmpty {
          Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: root.cwd))
          } label: {
            Image(systemName: "folder")
          }.buttonStyle(HoverButtonStyle(size: 26)).help(L("Abrir no Finder"))
          Button {
            openTerminal(at: root.cwd)
          } label: {
            Image(systemName: "terminal")
          }.buttonStyle(HoverButtonStyle(size: 26)).help(L("Abrir Terminal aqui"))
        }
        Button(L("Encerrar sessão…")) { Monitor.shared.requestKill([root], tree: true) }
          .buttonStyle(PillButtonStyle(tint: Tint.danger)).disabled(!root.eligible)
          .help(L("Encerra o agente e todos os processos que ele iniciou"))
      }
      if !ports.isEmpty {
        HStack(spacing: 4) {
          Text(L("Portas")).font(.caption).foregroundStyle(.secondary)
          ForEach(ports.prefix(8), id: \.port) { port in
            Badge(text: ":\(port.port)", color: port.exposed ? .orange : Tint.netIn)
          }
        }
      }
      if !children.isEmpty {
        DisclosureGroup(isExpanded: $expanded) {
          VStack(spacing: 6) {
            ForEach(children) { p in
              ProcessLine(process: p, subtitle: [p.project, p.portsLabel.isEmpty ? nil : p.portsLabel]
                .compactMap { $0 }.joined(separator: " · ")) {
                Text(p.cpu.percent).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                Text(p.memory.bytes).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                KillButton(process: p)
              }
            }
          }.padding(.top, 6)
        } label: {
          Text(L("%@ processos iniciados pela sessão", String(children.count))).font(.callout)
        }
      }
    }
  }
  private func stat(_ title: String, _ value: String) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.system(.callout, design: .rounded).weight(.medium)).monospacedDigit()
    }.frame(minWidth: 64, alignment: .trailing)
  }
}
