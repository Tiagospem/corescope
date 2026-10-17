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
  /// Claude Desktop's own id for the Code session (`local_…`), used by its deep links.
  let hostSessionId: String?
  /// `claude://code/continue?session=local_…` opens this session in Claude Desktop.
  var desktopURL: URL? {
    guard entrypoint == "claude-desktop", let id = hostSessionId,
      id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
    else { return nil }
    return URL(string: "claude://code/continue?session=\(id)")
  }
}

/// How to jump to where a session lives: its Claude Desktop page, or the app hosting it
/// (terminal, editor or Codex) brought to the front.
enum SessionJump {
  case desktop(URL)
  case app(NSRunningApplication, String)
  static func target(for root: ProcessItem, meta: ClaudeSessionMeta?, in snapshot: Snapshot?)
    -> SessionJump?
  {
    if let url = meta?.desktopURL { return .desktop(url) }
    // Walk up from the session to the nearest process that is a regular app.
    var pid = root.ppid
    for _ in 0..<48 {
      guard pid > 1 else { break }
      if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
        return .app(app, app.localizedName ?? root.origin?.label ?? "")
      }
      guard let parent = snapshot?.process(pid: pid)?.ppid else { break }
      pid = parent
    }
    return nil
  }
  var label: String {
    switch self {
    case .desktop: L("Abrir no Claude")
    case .app(_, let name): L("Mostrar no %@", name)
    }
  }
  var help: String {
    switch self {
    case .desktop: L("Abre esta sessão no Claude Desktop")
    case .app(_, let name): L("Traz %@, onde a sessão está rodando, para a frente", name)
    }
  }
  func open() {
    switch self {
    case .desktop(let url): NSWorkspace.shared.open(url)
    case .app(let app, _): app.activate()
    }
  }
}
struct SessionJumpButton: View {
  let root: ProcessItem
  let meta: ClaudeSessionMeta?
  /// Icon-only for dense rows; a native bordered button with label in session cards.
  var compact = false
  var body: some View {
    if let jump = SessionJump.target(for: root, meta: meta, in: Monitor.shared.snapshot) {
      if compact {
        Button {
          jump.open()
        } label: {
          Image(systemName: "arrow.up.forward.app")
        }.buttonStyle(HoverButtonStyle(tint: .accentColor, size: 24)).help(jump.help)
          .accessibilityLabel(jump.label)
      } else {
        Button {
          jump.open()
        } label: {
          Label(jump.label, systemImage: "arrow.up.forward.app")
        }.buttonStyle(.bordered).help(jump.help)
      }
    }
  }
}
struct CodexUsage: Equatable {
  var windows: [LimitWindow] = []
  var plan: String?
  var credits: String?
  var observedAt: Date?
  var weekly: LimitWindow? { windows.first { $0.windowMinutes == 10080 } ?? windows.last }
}

/// Tokens of one agent session: its transcript plus any subagent transcripts.
struct SessionTokens: Equatable {
  var counts = TokenCounts()
  var model: String?
  var subagents = 0
  var cwd: String?
  var updated = Date.distantPast
}
/// Tokens used today and over the last 7 days (today included) by one agent or project.
struct TokenRow: Equatable, Identifiable {
  let id: String
  var today = TokenCounts()
  var week = TokenCounts()
}
struct TokenReport: Equatable {
  /// False until the first pass over the transcripts finishes.
  var ready = false
  var total = TokenRow(id: "")
  var agents: [TokenRow] = []
  var projects: [TokenRow] = []
  /// "claude:<session uuid>" or "codex:<session id>".
  var sessions: [String: SessionTokens] = [:]
  func claude(_ meta: ClaudeSessionMeta?) -> SessionTokens? {
    meta?.sessionId.flatMap { sessions["claude:" + $0] }
  }
  /// Codex keeps no pid → session map on disk: pick the newest Codex conversation in the
  /// process's folder that was written since the process started.
  func codex(for root: ProcessItem) -> SessionTokens? {
    guard root.name.lowercased().hasPrefix("codex") else { return nil }
    let since = root.startDate.addingTimeInterval(-60)
    return sessions.filter { $0.key.hasPrefix("codex:") && $0.value.cwd == root.cwd && $0.value.updated >= since }
      .max { $0.value.updated < $1.value.updated }?.value
  }
}

/// Token usage from agent transcripts on disk, read incrementally: each file is read from where
/// the previous pass stopped, and only counts per file and per day stay in memory. Files:
/// ~/.claude/projects/*/<session>.jsonl (+ <session>/subagents/*.jsonl) and
/// ~/.codex/sessions/YYYY/MM/DD/*.jsonl, limited to those written in the last 7 days plus the
/// transcripts of running Claude sessions.
final class TokenUsageStore: ObservableObject {
  @Published private(set) var report = TokenReport()
  private let queue = DispatchQueue(label: "app.corescope.tokens", qos: .utility)
  private var files: [String: (tally: TranscriptTally, modified: Date)] = [:]
  private var started = false
  private var running = false

  /// The first pass reads whole transcripts, so it waits until the Agents page is first shown.
  func start() {
    guard !started else { return }
    started = true
    AgentStore.shared.refresh()
  }
  func refresh(live: Set<String>) {
    guard started, !running else { return }
    running = true
    queue.async {
      let report = self.scan(live: live)
      DispatchQueue.main.async {
        self.running = false
        if report != self.report { self.report = report }
      }
    }
  }

  private static let home = FileManager.default.homeDirectoryForCurrentUser
  private static let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
  private typealias Candidate = (url: URL, kind: AgentKind, size: UInt64, modified: Date)
  private static func list(_ dir: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
  }
  private static func stat(_ url: URL) -> (size: UInt64, modified: Date)? {
    guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory != true,
      let size = v.fileSize, let modified = v.contentModificationDate
    else { return nil }
    return (UInt64(size), modified)
  }
  private func candidates(live: Set<String>, since: Date) -> [Candidate] {
    var out: [Candidate] = []
    for project in Self.list(Self.home.appendingPathComponent(".claude/projects")) where project.hasDirectoryPath {
      for file in Self.list(project) where file.pathExtension == "jsonl" {
        guard let s = Self.stat(file) else { continue }
        let session = file.deletingPathExtension().lastPathComponent
        guard s.modified >= since || live.contains(session) else { continue }
        out.append((file, .claude, s.size, s.modified))
        let subagents = project.appendingPathComponent(session).appendingPathComponent("subagents")
        for sub in Self.list(subagents) where sub.pathExtension == "jsonl" {
          if let t = Self.stat(sub) { out.append((sub, .claude, t.size, t.modified)) }
        }
      }
    }
    // Codex files live under the day the conversation started; already known files are
    // re-checked wherever they are, so long conversations keep counting.
    let root = Self.home.appendingPathComponent(".codex/sessions")
    let calendar = Calendar(identifier: .gregorian)
    var seen = Set(out.map(\.url.path))
    for back in 0...7 {
      guard let day = calendar.date(byAdding: .day, value: -back, to: Date()) else { continue }
      let c = calendar.dateComponents([.year, .month, .day], from: day)
      let dir = root.appendingPathComponent(
        String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
      for file in Self.list(dir) where file.pathExtension == "jsonl" {
        guard let s = Self.stat(file), s.modified >= since, seen.insert(file.path).inserted else { continue }
        out.append((file, .codex, s.size, s.modified))
      }
    }
    for (path, entry) in files where entry.tally.kind == .codex && !seen.contains(path) {
      let url = URL(fileURLWithPath: path)
      if let s = Self.stat(url), s.modified >= since { out.append((url, .codex, s.size, s.modified)) }
    }
    return out
  }

  private func scan(live: Set<String>) -> TokenReport {
    let today = localDay(Date().timeIntervalSince1970)
    let weekStart = today - 6
    var next: [String: (tally: TranscriptTally, modified: Date)] = [:]
    for file in candidates(live: live, since: Date().addingTimeInterval(-7 * 86400)) {
      var entry = files[file.url.path] ?? (TranscriptTally(kind: file.kind, path: file.url.path), file.modified)
      if file.size != entry.tally.offset {
        autoreleasepool { entry.tally.read(file.url, size: file.size) }
      }
      entry.tally.prune(before: weekStart)
      entry.modified = file.modified
      next[file.url.path] = entry
    }
    files = next  // files that aged out or disappeared are forgotten

    var report = TokenReport(ready: true)
    var agents: [String: TokenRow] = [:]
    var projects: [String: TokenRow] = [:]
    for (tally, modified) in files.values {
      let cwd = Demo.enabled ? tally.cwd.map(Demo.path) : tally.cwd
      let project = usageProject(cwd) ?? L("Sem projeto")
      let agent = tally.kind.rawValue
      for (day, counts) in tally.days where day >= weekStart {
        func add(_ row: inout TokenRow) {
          row.week += counts
          if day == today { row.today += counts }
        }
        add(&report.total)
        add(&agents[agent, default: TokenRow(id: agent)])
        add(&projects[project, default: TokenRow(id: project)])
      }
      guard let session = tally.session else { continue }
      let key = (tally.kind == .claude ? "claude:" : "codex:") + session
      var s = report.sessions[key] ?? SessionTokens()
      s.counts += tally.total
      if tally.isSubagent {
        s.subagents += 1
        if s.model == nil { s.model = tally.model }
      } else {
        s.model = tally.model ?? s.model
        s.cwd = cwd
      }
      s.updated = max(s.updated, modified)
      report.sessions[key] = s
    }
    let byWeek: (TokenRow, TokenRow) -> Bool = { ($0.week.total, $0.id) > ($1.week.total, $1.id) }
    report.agents = agents.values.sorted(by: byWeek)
    report.projects = projects.values.sorted(by: byWeek)
    return report
  }
}

/// Reads agent metadata from local files only (no network, no credentials). Codex limits come
/// from the `rate_limits` events its CLI writes to session logs; Claude Code does not store its
/// usage limits on disk, so only session metadata is available for it. Token counts come from
/// both agents' transcripts (see TokenUsageStore).
final class AgentStore: ObservableObject {
  static let shared = AgentStore()
  @Published private(set) var codex = CodexUsage()
  @Published private(set) var claudeSessions: [Int32: ClaudeSessionMeta] = [:]
  /// Separate object so token updates redraw only the views that show tokens.
  let tokens = TokenUsageStore()
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
        self.tokens.refresh(live: Set(sessions.values.compactMap(\.sessionId)))
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
      MeterBar(fraction: window.usedPercent / 100, color: window.color).accessibilityHidden(true)
      if !compact, let reset = window.resetText {
        Text(reset).font(.caption).foregroundStyle(.secondary)
      }
    }
    .help(window.resetText ?? "")
    .accessibilityElement(children: .combine)
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
  @ObservedObject var tokens = AgentStore.shared.tokens
  var body: some View {
    ScrollView {
      if let s = monitor.snapshot {
        VStack(alignment: .leading, spacing: 16) {
          LimitsCard()
          TokensCard()
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
            let meta = agents.claudeSessions[root.pid]
            SessionCard(
              root: root, tree: s.subtree(of: root), meta: meta,
              tokens: tokens.report.claude(meta) ?? tokens.report.codex(for: root))
          }
          ContainersSection()
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
    .onAppear { tokens.start() }
  }
}

private struct SessionCard: View {
  let root: ProcessItem
  let tree: [ProcessItem]
  let meta: ClaudeSessionMeta?
  let tokens: SessionTokens?
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
        Spacer(minLength: 12)
        stat(L("Processos"), "\(tree.count)")
        stat("CPU", String(format: "%.1f%%", cpu))
        stat(L("Memória"), formatBytes(memory))
        KillButton(process: root, targets: tree)
      }
      if let tokens { SessionTokensLine(tokens: tokens) }
      if !ports.isEmpty {
        HStack(spacing: 4) {
          Text(L("Portas")).font(.caption).foregroundStyle(.secondary)
          ForEach(ports.prefix(8), id: \.port) { port in
            PortBadge(port: port)
          }
        }
      }
      // Actions row: the process list toggle on the left, native buttons on the right.
      HStack(spacing: 8) {
        if !children.isEmpty {
          Button {
            expanded.toggle()
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0)).accessibilityHidden(true)
              Text(L("%@ processos iniciados pela sessão", String(children.count)))
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            .accessibilityValue(expanded ? L("Expandido") : L("Recolhido"))
        }
        Spacer(minLength: 8)
        SessionJumpButton(root: root, meta: meta)
        if !root.cwd.isEmpty {
          Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: root.cwd))
          } label: {
            Label("Finder", systemImage: "folder")
          }.help(L("Abrir no Finder"))
          Button {
            openTerminal(at: root.cwd)
          } label: {
            Label("Terminal", systemImage: "terminal")
          }.help(L("Abrir Terminal aqui"))
        }
      }
      .buttonStyle(.bordered).controlSize(.small)
      if expanded && !children.isEmpty {
        VStack(spacing: 6) {
            ForEach(children) { p in
              ProcessLine(process: p, subtitle: [p.project, p.portsLabel.isEmpty ? nil : p.portsLabel]
                .compactMap { $0 }.joined(separator: " · ")) {
                Text(p.cpu.percent).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                Text(p.memory.bytes).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                KillButton(process: p)
              }
            }
        }.padding(.top, 2)
      }
    }
  }
  private func stat(_ title: String, _ value: String) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.system(.callout, design: .rounded).weight(.medium)).monospacedDigit()
    }.frame(minWidth: 64, alignment: .trailing).accessibilityElement(children: .combine)
  }
}

// MARK: - Tokens UI

/// Tokens of one session, under its header: input, output and prompt cache, plus the model.
private struct SessionTokensLine: View {
  let tokens: SessionTokens
  var body: some View {
    let c = tokens.counts
    HStack(spacing: 12) {
      Text(L("Tokens")).foregroundStyle(.secondary)
      value(L("Entrada"), c.input)
      value(L("Saída"), c.output)
      value(L("Cache"), c.cache)
        .help(L("Cache de prompt: %@ gravados · %@ lidos", formatTokens(c.cacheWrite), formatTokens(c.cacheRead)))
      Spacer(minLength: 8)
      if tokens.subagents > 0 {
        Text(L("+ %@ subagentes", String(tokens.subagents))).foregroundStyle(.secondary)
      }
      if let model = tokens.model { Badge(text: model, color: Tint.memory, symbol: "cpu") }
    }
    .font(.caption)
    .help(L("Tokens desta sessão (subagentes incluídos), lidos do registro local do agente."))
  }
  private func value(_ title: String, _ count: Int) -> some View {
    HStack(spacing: 4) {
      Text(title).foregroundStyle(.secondary)
      Text(formatTokens(count)).fontWeight(.medium).monospacedDigit()
    }
  }
}

/// Tokens today and over the last 7 days, by agent and by project, from local transcripts.
struct TokensCard: View {
  @ObservedObject var store = AgentStore.shared.tokens
  var body: some View {
    let report = store.report
    Card {
      CardHeader(title: L("Uso de tokens"), symbol: "chart.bar.xaxis", tint: Tint.memory)
      if !report.ready {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(L("Lendo registros locais dos agentes…")).font(.caption).foregroundStyle(.secondary)
        }
      } else if report.total.week.total == 0 {
        EmptyNote(text: L("Nenhum token registrado nos últimos 7 dias."))
      } else {
        HStack(alignment: .top, spacing: 18) {
          TokenTotal(title: L("Hoje"), counts: report.total.today)
          TokenTotal(title: L("Últimos 7 dias"), counts: report.total.week)
        }
        HStack(alignment: .top, spacing: 18) {
          TokenTable(title: L("Agente"), rows: report.agents)
          TokenTable(title: L("Projeto"), rows: Array(report.projects.prefix(6)), more: report.projects.count - 6)
        }
        Text(
          L(
            "Contado dos registros locais do Claude Code e do Codex. Cache = tokens de prompt gravados e lidos do cache. Sem valores em dólar."
          )
        ).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { store.start() }
  }
}
private func tokenBreakdown(_ c: TokenCounts) -> String {
  L("entrada %@ · saída %@ · cache %@", formatTokens(c.input), formatTokens(c.output), formatTokens(c.cache))
}
private struct TokenTotal: View {
  let title: String
  let counts: TokenCounts
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(formatTokens(counts.total)).font(.system(size: 20, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(tokenBreakdown(counts)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
private struct TokenTable: View {
  let title: String
  let rows: [TokenRow]
  var more = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
        GridRow {
          Text(title)
          Text(L("Hoje")).gridColumnAlignment(.trailing)
          Text(L("7 dias")).gridColumnAlignment(.trailing)
        }.font(.caption2).foregroundStyle(.secondary)
        ForEach(rows) { row in
          GridRow {
            Text(row.id).lineLimit(1).truncationMode(.middle)
            Text(formatTokens(row.today.total))
            Text(formatTokens(row.week.total))
          }
          .font(.caption).monospacedDigit()
          .help(L("Hoje: %@ | 7 dias: %@", tokenBreakdown(row.today), tokenBreakdown(row.week)))
        }
      }
      if more > 0 {
        Text(L("+ %@ outros projetos", String(more))).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}
