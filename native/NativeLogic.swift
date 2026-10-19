import CoreGraphics
import Foundation

// Pure helpers shared by the native UI and its standalone integration tests.
func descendantIDs(root: Int32, nodes: [(pid: Int32, ppid: Int32)]) -> [Int32] {
  var result = [root]
  var seen: Set<Int32> = [root]
  var index = 0
  while index < result.count {
    let parent = result[index]
    for node in nodes where node.ppid == parent && seen.insert(node.pid).inserted {
      result.append(node.pid)
    }
    index += 1
  }
  return result.reversed()
}
func clampPanel(_ frame: CGRect, to visible: CGRect) -> CGRect {
  var frame = frame
  frame.size.width = min(frame.width, visible.width)
  frame.size.height = min(frame.height, visible.height)
  frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
  frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
  return frame
}

/// Process forest as people read it: children of launchd (PID 1) and processes whose parent is
/// gone become roots, so each app or tool heads its own tree.
struct ProcessForest {
  var roots: [Int32] = []
  var children: [Int32: [Int32]] = [:]
  init(_ nodes: [(pid: Int32, ppid: Int32)]) {
    let present = Set(nodes.map(\.pid))
    for node in nodes {
      if node.ppid <= 1 || node.ppid == node.pid || !present.contains(node.ppid) {
        roots.append(node.pid)
      } else {
        children[node.ppid, default: []].append(node.pid)
      }
    }
    // Parent cycles cannot occur in the kernel, but a racing snapshot must never hide nodes.
    var reachable = Set<Int32>()
    var stack = roots
    while let pid = stack.popLast() {
      guard reachable.insert(pid).inserted else { continue }
      stack.append(contentsOf: children[pid] ?? [])
    }
    for node in nodes where !reachable.contains(node.pid) {
      roots.append(node.pid)
      reachable.insert(node.pid)
    }
  }
  /// Sum of `value` over each node and all of its descendants.
  func totals(_ value: (Int32) -> Double) -> [Int32: Double] {
    var result: [Int32: Double] = [:]
    var visited = Set<Int32>()
    func visit(_ pid: Int32) -> Double {
      if let known = result[pid] { return known }
      guard visited.insert(pid).inserted else { return 0 }
      let sum = max(0, value(pid)) + (children[pid] ?? []).reduce(0) { $0 + visit($1) }
      result[pid] = sum
      return sum
    }
    for root in roots { _ = visit(root) }
    return result
  }
  /// Depth-first visible rows. `visible` limits nodes (filters keep matching ancestors);
  /// `expanded` decides whether children are shown; `order` sorts siblings.
  func flatten(
    visible: Set<Int32>? = nil, expanded: (Int32) -> Bool, order: (Int32, Int32) -> Bool
  ) -> [(pid: Int32, depth: Int, children: Int)] {
    var out: [(pid: Int32, depth: Int, children: Int)] = []
    var visited = Set<Int32>()
    func shown(_ pids: [Int32]) -> [Int32] {
      (visible.map { set in pids.filter { set.contains($0) } } ?? pids).sorted(by: order)
    }
    func visit(_ pid: Int32, _ depth: Int) {
      guard visited.insert(pid).inserted else { return }
      let kids = shown(children[pid] ?? [])
      out.append((pid, depth, kids.count))
      if expanded(pid) { for kid in kids { visit(kid, depth + 1) } }
    }
    for root in shown(roots) { visit(root, 0) }
    return out
  }
  /// Every ancestor of the given nodes, so filtered matches keep their context.
  func ancestors(of pids: Set<Int32>, parent: [Int32: Int32]) -> Set<Int32> {
    var out = Set<Int32>()
    for pid in pids {
      var current = parent[pid]
      var steps = 0
      while let p = current, p > 1, steps < 64, out.insert(p).inserted {
        current = parent[p]
        steps += 1
      }
    }
    return out
  }
}

/// Groups ports by owner in order of first appearance; ports without an owner stay in `rest`.
func splitPorts(_ ports: [UInt16], owner: (UInt16) -> String?) -> (
  owned: [(owner: String, ports: [UInt16])], rest: [UInt16]
) {
  var owned: [(owner: String, ports: [UInt16])] = []
  var rest: [UInt16] = []
  for port in ports {
    guard let id = owner(port) else {
      rest.append(port)
      continue
    }
    if let index = owned.firstIndex(where: { $0.owner == id }) {
      owned[index].ports.append(port)
    } else {
      owned.append((id, [port]))
    }
  }
  return (owned, rest)
}

/// Port → owner for ports claimed by exactly one owner; shared ports are left out.
func uniqueOwners(_ pairs: [(port: UInt16, owner: String)]) -> [UInt16: String] {
  var owners: [UInt16: Set<String>] = [:]
  for pair in pairs { owners[pair.port, default: []].insert(pair.owner) }
  return owners.compactMapValues { $0.count == 1 ? $0.first : nil }
}

/// "0 KB" rather than the system's "Zero KB".
private func byteFormatter(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
  let f = ByteCountFormatter()
  f.countStyle = style
  f.allowsNonnumericFormatting = false
  return f
}
private let memoryBytes = byteFormatter(.memory)
private let fileBytes = byteFormatter(.file)
func formatBytes(_ value: Double) -> String {
  memoryBytes.string(fromByteCount: Int64(max(0, value)))
}
func formatRate(_ value: Double) -> String {
  fileBytes.string(fromByteCount: Int64(max(0, value))) + "/s"
}
func formatDuration(_ seconds: TimeInterval) -> String {
  let s = Int(max(0, seconds))
  if s < 60 { return "\(s) s" }
  if s < 3600 { return "\(s / 60) min" }
  if s < 86400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
  return "\(s / 86400) d \(s % 86400 / 3600) h"
}
func abbreviateHome(_ path: String) -> String {
  let home = NSHomeDirectory()
  return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
/// Last component of a working directory when it looks like a project (not / or the home folder).
/// Demo mode passes `demoHome`, since its paths no longer start with the real home.
func projectName(_ cwd: String, home: String = NSHomeDirectory()) -> String? {
  // App sandboxes and support folders are not projects.
  guard !cwd.isEmpty, cwd != "/", cwd != home, !cwd.hasPrefix(home + "/Library/"),
    !cwd.hasPrefix("/private/"), !cwd.hasPrefix("/Library/"), !cwd.hasPrefix("/System/")
  else { return nil }
  return (cwd as NSString).lastPathComponent
}

// MARK: - Claude Code status line (opt-in limits)

/// JSON value that keeps object key order and number lexemes, so changing one key of
/// ~/.claude/settings.json leaves every other key exactly as Claude Code wrote it.
enum OrderedJSON: Equatable {
  struct Member: Equatable {
    var key: String
    var value: OrderedJSON
  }
  case object([Member]), array([OrderedJSON]), string(String), number(String), bool(Bool), null

  struct ParseError: Error {}
  static func parse(_ text: String) throws -> OrderedJSON {
    var scanner = JSONScanner(bytes: Array(text.utf8))
    let value = try scanner.value()
    scanner.skipSpace()
    guard scanner.index == scanner.bytes.count else { throw ParseError() }
    return value
  }
  subscript(key: String) -> OrderedJSON? {
    guard case .object(let members) = self else { return nil }
    return members.first { $0.key == key }?.value
  }
  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }
  /// Replaces `key` in place (appending when new); nil removes it. Non-objects are returned as is.
  func setting(_ key: String, _ value: OrderedJSON?) -> OrderedJSON {
    guard case .object(var members) = self else { return self }
    if let i = members.firstIndex(where: { $0.key == key }) {
      if let value { members[i].value = value } else { members.remove(at: i) }
    } else if let value {
      members.append(Member(key: key, value: value))
    }
    return .object(members)
  }
  /// Same layout as `JSON.stringify(value, null, 2)`, which is how Claude Code writes settings.
  func serialized(_ level: Int = 0) -> String {
    let pad = String(repeating: "  ", count: level + 1)
    let end = String(repeating: "  ", count: level)
    switch self {
    case .object(let members):
      if members.isEmpty { return "{}" }
      let body = members.map { pad + Self.quote($0.key) + ": " + $0.value.serialized(level + 1) }
      return "{\n" + body.joined(separator: ",\n") + "\n" + end + "}"
    case .array(let items):
      if items.isEmpty { return "[]" }
      return "[\n" + items.map { pad + $0.serialized(level + 1) }.joined(separator: ",\n") + "\n" + end + "]"
    case .string(let s): return Self.quote(s)
    case .number(let n): return n
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    }
  }
  static func quote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }
}

private struct JSONScanner {
  let bytes: [UInt8]
  var index = 0
  init(bytes: [UInt8]) { self.bytes = bytes }
  mutating func skipSpace() {
    while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
  }
  private mutating func expect(_ byte: UInt8) throws {
    skipSpace()
    guard index < bytes.count, bytes[index] == byte else { throw OrderedJSON.ParseError() }
    index += 1
  }
  private func peek() -> UInt8? {
    index < bytes.count ? bytes[index] : nil
  }
  mutating func value() throws -> OrderedJSON {
    skipSpace()
    guard let byte = peek() else { throw OrderedJSON.ParseError() }
    switch byte {
    case UInt8(ascii: "{"):
      index += 1
      var members: [OrderedJSON.Member] = []
      skipSpace()
      if peek() == UInt8(ascii: "}") {
        index += 1
        return .object(members)
      }
      repeat {
        skipSpace()
        let key = try string()
        try expect(UInt8(ascii: ":"))
        members.append(.init(key: key, value: try value()))
        skipSpace()
      } while try separator(closing: UInt8(ascii: "}"))
      return .object(members)
    case UInt8(ascii: "["):
      index += 1
      var items: [OrderedJSON] = []
      skipSpace()
      if peek() == UInt8(ascii: "]") {
        index += 1
        return .array(items)
      }
      repeat {
        items.append(try value())
        skipSpace()
      } while try separator(closing: UInt8(ascii: "]"))
      return .array(items)
    case UInt8(ascii: "\""): return .string(try string())
    case UInt8(ascii: "t"): return try literal("true", .bool(true))
    case UInt8(ascii: "f"): return try literal("false", .bool(false))
    case UInt8(ascii: "n"): return try literal("null", .null)
    default: return try number()
    }
  }
  /// True after a comma, false after the closing bracket.
  private mutating func separator(closing: UInt8) throws -> Bool {
    guard let byte = peek() else { throw OrderedJSON.ParseError() }
    index += 1
    if byte == UInt8(ascii: ",") { return true }
    if byte == closing { return false }
    throw OrderedJSON.ParseError()
  }
  private mutating func literal(_ word: String, _ value: OrderedJSON) throws -> OrderedJSON {
    let w = Array(word.utf8)
    guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else {
      throw OrderedJSON.ParseError()
    }
    index += w.count
    return value
  }
  private mutating func number() throws -> OrderedJSON {
    let start = index
    while let b = peek(), b == UInt8(ascii: "-") || b == UInt8(ascii: "+") || b == UInt8(ascii: ".")
      || b == UInt8(ascii: "e") || b == UInt8(ascii: "E") || (0x30...0x39).contains(b)
    {
      index += 1
    }
    let lexeme = String(decoding: bytes[start..<index], as: UTF8.self)
    guard lexeme.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression)
      != nil
    else { throw OrderedJSON.ParseError() }
    return .number(lexeme)
  }
  private mutating func hex4() throws -> UInt32 {
    guard index + 4 <= bytes.count,
      let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
    else { throw OrderedJSON.ParseError() }
    index += 4
    return v
  }
  mutating func string() throws -> String {
    guard peek() == UInt8(ascii: "\"") else { throw OrderedJSON.ParseError() }
    index += 1
    var out: [UInt8] = []
    while true {
      guard let b = peek() else { throw OrderedJSON.ParseError() }
      index += 1
      switch b {
      case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
      case UInt8(ascii: "\\"):
        guard let e = peek() else { throw OrderedJSON.ParseError() }
        index += 1
        switch e {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
          var code = try hex4()
          if (0xD800..<0xDC00).contains(code) {
            guard peek() == UInt8(ascii: "\\"), index + 1 < bytes.count,
              bytes[index + 1] == UInt8(ascii: "u")
            else { throw OrderedJSON.ParseError() }
            index += 2
            let low = try hex4()
            guard (0xDC00...0xDFFF).contains(low) else { throw OrderedJSON.ParseError() }
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
          } else if (0xDC00...0xDFFF).contains(code) {
            throw OrderedJSON.ParseError()
          }
          guard let scalar = Unicode.Scalar(code) else { throw OrderedJSON.ParseError() }
          out += Array(String(scalar).utf8)
        default: throw OrderedJSON.ParseError()
        }
      case 0..<0x20: throw OrderedJSON.ParseError()
      default: out.append(b)
      }
    }
  }
}

/// How CoreScope's status line command sits in Claude Code's settings. Claude Code passes
/// documented `rate_limits` (five_hour / seven_day) to the status line command on stdin.
enum ClaudeStatusLine {
  enum Link: Equatable {
    /// No statusLine configured.
    case absent
    /// CoreScope's command is the status line.
    case installed
    /// CoreScope's command runs in front of the user's own command (`--record |`).
    case chained
    /// Another status line; CoreScope leaves it untouched.
    case foreign(String)
  }
  static func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
  static func command(script: String) -> String { shellQuote(script) }
  /// Records the limits, passes stdin through unchanged, and lets the original command print.
  /// The subshell (closed on its own line) keeps `;`, `&&` and trailing comments intact.
  static func chained(script: String, original: String) -> String {
    shellQuote(script) + " --record | (\n" + original + "\n)"
  }
  static func link(of settings: OrderedJSON?, script: String) -> Link {
    guard let statusLine = settings?["statusLine"] else { return .absent }
    guard let command = statusLine["command"]?.stringValue else { return .foreign("") }
    if command == Self.command(script: script) { return .installed }
    if command.contains(script) { return .chained }
    return .foreign(command)
  }
  /// The new statusLine value, or nil when the existing one should be left alone. Chaining keeps
  /// every other key of the user's statusLine (padding, refreshInterval…).
  static func installing(over current: OrderedJSON?, script: String, chain: Bool) -> OrderedJSON? {
    guard let current else {
      return .object([
        .init(key: "type", value: .string("command")),
        .init(key: "command", value: .string(command(script: script))),
      ])
    }
    guard chain, let original = current["command"]?.stringValue, !original.contains(script) else {
      return nil
    }
    return current.setting("command", .string(chained(script: script, original: original)))
  }
}

struct ClaudeLimitSample: Equatable {
  let id: String
  let usedPercent: Double
  let windowMinutes: Int
  let resetsAt: Date?
}
/// Parses the `rate_limits` object the status line command saved. Windows whose reset time
/// has passed are dropped, as Claude Code itself does.
func parseClaudeLimits(_ data: Data, now: Date = Date()) -> [ClaudeLimitSample] {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
  return [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes in
    guard let w = object[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue
    else { return nil }
    // Some Claude Code versions put the reset epoch in used_percentage: not a percentage.
    guard used <= 100.5 else { return nil }
    let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    if let reset, reset <= now { return nil }
    return ClaudeLimitSample(
      id: key, usedPercent: min(max(used, 0), 100), windowMinutes: minutes, resetsAt: reset)
  }
}

/// Home folder shown in demo mode (`CORESCOPE_DEMO=1`).
let demoHome = "/Users/dev"
/// Stable stand-in from `list` for `key`, so a name always maps to the same fake one.
func demoPick(_ list: [String], _ key: String) -> String {
  list[Int(key.utf8.reduce(UInt32(7)) { $0 &* 31 &+ UInt32($1) } % UInt32(list.count))]
}
/// Demo-mode stand-in for a path. System locations stay readable; the home becomes `demoHome`,
/// ~/Library becomes a generic support folder, and every other folder (home subfolders, external
/// volumes, other users) becomes `demoHome/code/<fake project>`, so no real folder name is shown.
/// Executables keep their file name, which is already shown as the process name.
func demoPath(_ path: String, home: String, projects: [String], executable: Bool = false) -> String {
  func withoutDataVolumePrefix(_ value: String) -> String {
    let prefix = "/System/Volumes/Data"
    if value == prefix { return "/" }
    return value.hasPrefix(prefix + "/") ? String(value.dropFirst(prefix.count)) : value
  }
  let path = withoutDataVolumePrefix(path)
  let home = withoutDataVolumePrefix(home)
  guard path.hasPrefix("/") else { return path }
  let name = (path as NSString).lastPathComponent
  let file = executable ? "/" + name : ""
  if path == home { return demoHome }
  if path.hasPrefix(home + "/") {
    if path == home + "/Library" || path.hasPrefix(home + "/Library/") {
      return demoHome + "/Library/Application Support" + file
    }
  } else {
    let system = [
      "/System", "/usr", "/bin", "/sbin", "/Applications", "/Library", "/private", "/opt", "/tmp",
      "/var", "/etc", "/dev", "/cores",
    ]
    if path == "/" || system.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      return path
    }
  }
  let folder = executable ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent : name
  return demoHome + "/code/" + demoPick(projects, folder) + file
}

/// At most one notification per key (a process identity `pid:start`, or an event) per interval.
struct NotificationDebounce {
  var interval: TimeInterval = 3600
  private(set) var last: [String: TimeInterval] = [:]
  mutating func allow(_ key: String, at now: TimeInterval) -> Bool {
    if let at = last[key], now - at < interval { return false }
    last[key] = now
    // Bounded: forget keys whose window has passed once the table grows.
    if last.count > 256 { last = last.filter { now - $0.value < interval } }
    return true
  }
}
/// How long each identity has stayed above a threshold; dropping below resets its clock.
struct SustainTracker {
  private(set) var since: [String: TimeInterval] = [:]
  /// Identities above the threshold for at least `duration` seconds.
  mutating func update(above: [String], at now: TimeInterval, duration: TimeInterval) -> [String] {
    var next: [String: TimeInterval] = [:]
    var out: [String] = []
    for id in above {
      let start = since[id] ?? now
      next[id] = start
      if now - start >= duration { out.append(id) }
    }
    since = next
    return out
  }
}
/// Identities not present in the previous call; the first call only records a baseline, so
/// launching the app never replays everything that already exists.
struct NewArrivals {
  private(set) var seen: Set<String>?
  mutating func update(_ ids: [String]) -> [String] {
    defer { seen = Set(ids) }
    guard let seen else { return [] }
    return ids.filter { !seen.contains($0) }
  }
}
/// A TCP port typed by the user, or nil outside 1...65535.
func parsePort(_ text: String) -> UInt16? {
  let trimmed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: [":"])
  guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
  return UInt16(value)
}
/// Carbon modifier masks (HIToolbox Events.h), kept here so the label is testable without Carbon.
enum HotkeyModifier {
  static let command = 0x100
  static let shift = 0x200
  static let option = 0x800
  static let control = 0x1000
}
/// Shortcut label in the macOS menu order: ⌃⌥⇧⌘ then the key.
func shortcutLabel(modifiers: Int, key: String) -> String {
  var out = ""
  if modifiers & HotkeyModifier.control != 0 { out += "⌃" }
  if modifiers & HotkeyModifier.option != 0 { out += "⌥" }
  if modifiers & HotkeyModifier.shift != 0 { out += "⇧" }
  if modifiers & HotkeyModifier.command != 0 { out += "⌘" }
  return out + key.uppercased()
}

/// A process an agent session started, as far as stall detection cares.
struct TurnChild {
  let name: String
  let cpu: Double
  /// Start time, seconds since 1970.
  let start: Double
  let listening: Bool
}
/// What a busy agent session seems to be doing when nothing new has reached its transcript for
/// a while. `since` is when the transcript last changed (or the turn began).
enum AgentStall: Equatable {
  /// A command it started in this turn is still computing: probably just long.
  case longCommand(String, since: Double)
  /// A command it started in this turn sits idle: waiting for input, a lock or the network.
  case waiting(String, since: Double)
  /// No transcript writes and nothing running: the agent itself looks stuck.
  case silent(since: Double)
  var since: Double {
    switch self {
    case .longCommand(_, let since), .waiting(_, let since), .silent(let since): since
    }
  }
  /// Worth an alert: a long build or test run is not.
  var suspicious: Bool { if case .longCommand = self { false } else { true } }
}
/// One agent session in the floating panel, most urgent first.
enum AgentPanelState: Int, Comparable {
  case stuck, longCommand, busy, waiting, unknown
  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
/// `status` is Claude Code's own ("busy", "idle"; nil when the agent writes none, as Codex).
func agentPanelState(status: String?, stall: AgentStall?) -> AgentPanelState {
  if let stall { return stall.suspicious ? .stuck : .longCommand }
  guard let status else { return .unknown }
  return status == "idle" ? .waiting : .busy
}
/// Nil while the session is idle or wrote to its transcript within `threshold` seconds. Servers
/// it left listening and processes from earlier turns (MCP servers, dev servers) are ignored.
func agentStall(
  busySince: Double?, lastWrite: Double?, children: [TurnChild], now: Double, threshold: Double
) -> AgentStall? {
  guard let busySince else { return nil }
  let quietSince = max(busySince, lastWrite ?? busySince)
  guard now - quietSince >= threshold else { return nil }
  let turn = children.filter { $0.start >= busySince - 1 && !$0.listening }
  if let hot = turn.max(by: { $0.cpu < $1.cpu }), hot.cpu >= 20 {
    return .longCommand(hot.name, since: quietSince)
  }
  if let newest = turn.max(by: { $0.start < $1.start }) { return .waiting(newest.name, since: quietSince) }
  return .silent(since: quietSince)
}
/// Claude Code's folder under ~/.claude/projects for a working directory.
func claudeProjectFolder(_ cwd: String) -> String {
  String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
}

/// What a health check probes: an HTTP(S) endpoint, or a TCP port that must accept connections.
enum HealthTarget: Equatable {
  case http(URL)
  case tcp(host: String, port: UInt16)
  /// "3000", ":3000", "db.local:5432", "localhost:3000/health", "https://staging.app/up".
  init?(_ text: String) {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") {
      guard let url = URL(string: t), url.host?.isEmpty == false else { return nil }
      self = .http(url)
      return
    }
    if t.contains("/") {
      guard let url = URL(string: "http://" + t), url.host?.isEmpty == false else { return nil }
      self = .http(url)
      return
    }
    if let port = parsePort(t) {
      self = .tcp(host: "localhost", port: port)
      return
    }
    guard let colon = t.lastIndex(of: ":"), let port = parsePort(String(t[t.index(after: colon)...])) else {
      return nil
    }
    let host = String(t[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard !host.isEmpty, !host.contains(" ") else { return nil }
    self = .tcp(host: host, port: port)
  }
  var label: String {
    switch self {
    case .http(let url): url.absoluteString
    case .tcp(let host, let port): "\(host):\(port)"
    }
  }
  /// Only loopback targets keep CoreScope's "no network" promise; others are the user's choice.
  var isLocal: Bool {
    let host: String
    switch self {
    case .http(let url): host = url.host ?? ""
    case .tcp(let h, _): host = h
    }
    return ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) || host.hasSuffix(".localhost")
  }
}
/// 2xx/3xx is healthy; 4xx answers but is probably the wrong path; anything else is down.
enum HealthLevel: Int, Comparable {
  case up = 0, warn = 1, down = 2
  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
  init(httpStatus: Int) { self = httpStatus < 400 ? .up : httpStatus < 500 ? .warn : .down }
}

/// What stopping one profile does to its containers. A container keeps running while another
/// started profile still uses it, or when no profile started it (it was already up: the user's or
/// another tool's). The last profile using a container a profile started stops it.
struct ContainerStopPlan: Equatable {
  var stop: [String] = []
  /// Container → the active profile that still uses it.
  var shared: [String: String] = [:]
  /// Running before any profile started it.
  var external: [String] = []
}
func planContainerStop(
  _ containers: [String], running: Set<String>, startedByProfiles: Set<String>,
  otherActive: [(name: String, containers: [String])]
) -> ContainerStopPlan {
  var plan = ContainerStopPlan()
  for name in containers where running.contains(name) {
    if let other = otherActive.first(where: { $0.containers.contains(name) }) {
      plan.shared[name] = other.name
    } else if startedByProfiles.contains(name) {
      plan.stop.append(name)
    } else {
      plan.external.append(name)
    }
  }
  return plan
}

/// What `machineScript` prints on a remote host, one `key=value` per line.
struct RemoteStats: Equatable {
  var os = "", kernel = "", host = ""
  var load: [Double] = []
  var cpus = 0
  var uptime: Double?
  var memoryTotal: Double?, memoryAvailable: Double?
  var diskTotal: Double?, diskUsed: Double?
  var containers: Int?
  var processes: [(cpu: Double, memory: Double, name: String)] = []
  var memoryProcesses: [(cpu: Double, memory: Double, name: String)] = []
  var osName = ""
  var swapTotal: Double?, swapFree: Double?
  var disks: [(mount: String, total: Double, used: Double)] = []
  var failedUnits: [String] = []
  var containerList: [(name: String, state: String, status: String)] = []
  static func == (a: Self, b: Self) -> Bool {
    a.os == b.os && a.host == b.host && a.load == b.load && a.cpus == b.cpus && a.uptime == b.uptime
      && a.memoryTotal == b.memoryTotal && a.memoryAvailable == b.memoryAvailable && a.diskTotal == b.diskTotal
      && a.diskUsed == b.diskUsed && a.containers == b.containers && a.processes.map(\.name) == b.processes.map(\.name)
  }
  init() {}
  init(parsing text: String) {
    for line in text.split(whereSeparator: \.isNewline) {
      guard let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq], value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      switch key {
      case "os": os = value
      case "kernel": kernel = value
      case "host": host = value
      case "load": load = value.split(separator: " ").compactMap { Double($0) }
      case "cpus": cpus = Int(value) ?? 0
      case "uptime": uptime = Double(value)
      case "memtotal": memoryTotal = Double(value)
      case "memavail": memoryAvailable = Double(value)
      case "disktotal": diskTotal = Double(value)
      case "diskused": diskUsed = Double(value)
      case "containers": containers = Int(value)
      case "proc", "mproc":
        let parts = value.split(separator: "|", maxSplits: 2).map(String.init)
        if parts.count == 3, let cpu = Double(parts[0]), let mem = Double(parts[1]) {
          let entry = (cpu, mem, (parts[2] as NSString).lastPathComponent)
          if key == "proc" { processes.append(entry) } else { memoryProcesses.append(entry) }
        }
      case "osname": osName = value
      case "swaptotal": swapTotal = Double(value)
      case "swapfree": swapFree = Double(value)
      case "disk":
        let parts = value.split(separator: "|").map(String.init)
        if parts.count == 3, let total = Double(parts[1]), let used = Double(parts[2]), total > 0 {
          disks.append((parts[0], total, used))
        }
      case "failed": if !value.isEmpty { failedUnits.append(value) }
      case "container":
        let parts = value.split(separator: "|", maxSplits: 2).map(String.init)
        if parts.count == 3 { containerList.append((parts[0], parts[1], parts[2])) }
      default: break
      }
    }
  }
  var valid: Bool { !os.isEmpty }
}
/// An ssh destination CoreScope will pass on: alias, host or user@host[:port-less], never an option.
func validSSHDestination(_ s: String) -> Bool {
  !s.isEmpty && !s.hasPrefix("-") && s.count <= 255
    && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-@[]:".unicodeScalars.contains($0) }
}
/// `Host` aliases from an ssh config, without patterns.
func sshConfigHosts(_ config: String) -> [String] {
  var out: [String] = []
  for line in config.split(whereSeparator: \.isNewline) {
    let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = words.first, first.lowercased() == "host" else { continue }
    for w in words.dropFirst() where !w.contains("*") && !w.contains("?") && !w.hasPrefix("!") {
      if !out.contains(String(w)) { out.append(String(w)) }
    }
  }
  return out
}

/// CoreScope's Claude Code PreToolUse hook (`corescope gate`) inside ~/.claude/settings.json:
/// added as its own matcher group, recognized by its command, removed without touching other
/// hooks.
/// CoreScope's hooks in an agent's hooks file. Claude Code (`~/.claude/settings.json`) and Codex
/// (`~/.codex/hooks.json`) use the same shape: `hooks.<Event>[] = {matcher?, hooks: [{type,
/// command, timeout, statusMessage?}]}`. Only CoreScope's own entries are added or removed.
enum AgentHook: String, CaseIterable {
  /// PreToolUse on Bash: heavy commands wait for room (`corescope gate`).
  case gate
  /// SessionStart: the project's .corescope.yml summed up as context (`corescope context --hook`).
  case context
  var event: String { self == .gate ? "PreToolUse" : "SessionStart" }
  var matcher: String? { self == .gate ? "Bash" : nil }
  private var suffix: String { self == .gate ? " gate" : " context --hook" }
  var timeout: Int { self == .gate ? 3600 : 15 }
  func command(binary: String) -> String { ClaudeStatusLine.shellQuote(binary) + suffix }
  private func isOurs(_ hook: OrderedJSON) -> Bool {
    guard let command = hook["command"]?.stringValue else { return false }
    return command.hasSuffix(suffix) && command.contains("corescope")
  }
  func installed(in settings: OrderedJSON?) -> Bool {
    guard case .array(let groups)? = settings?["hooks"]?[event] else { return false }
    return groups.contains { group in
      guard case .array(let hooks)? = group["hooks"] else { return false }
      return hooks.contains(where: isOurs)
    }
  }
  /// Settings with the hook (replacing an older CoreScope entry, e.g. after the app moved).
  func installing(into settings: OrderedJSON, binary: String, statusMessage: String? = nil) -> OrderedJSON {
    let cleaned = removing(from: settings)
    var handler: [OrderedJSON.Member] = [
      .init(key: "type", value: .string("command")),
      .init(key: "command", value: .string(command(binary: binary))),
      .init(key: "timeout", value: .number(String(timeout))),
    ]
    if let statusMessage { handler.append(.init(key: "statusMessage", value: .string(statusMessage))) }
    var groupMembers: [OrderedJSON.Member] = []
    if let matcher { groupMembers.append(.init(key: "matcher", value: .string(matcher))) }
    groupMembers.append(.init(key: "hooks", value: .array([.object(handler)])))
    let hooks = cleaned["hooks"] ?? .object([])
    var groups: [OrderedJSON] = []
    if case .array(let existing)? = hooks[event] { groups = existing }
    groups.append(.object(groupMembers))
    return cleaned.setting("hooks", hooks.setting(event, .array(groups)))
  }
  /// Settings without CoreScope's hook; groups and sections left empty by it are dropped.
  func removing(from settings: OrderedJSON) -> OrderedJSON {
    guard let hooks = settings["hooks"], case .array(let groups)? = hooks[event] else { return settings }
    var kept: [OrderedJSON] = []
    for group in groups {
      guard case .array(let list)? = group["hooks"] else {
        kept.append(group)
        continue
      }
      let remaining = list.filter { !isOurs($0) }
      if remaining.count == list.count {
        kept.append(group)
      } else if !remaining.isEmpty {
        kept.append(group.setting("hooks", .array(remaining)))
      }
    }
    let nextHooks = hooks.setting(event, kept.isEmpty ? nil : .array(kept))
    return settings.setting("hooks", nextHooks == .object([]) ? nil : nextHooks)
  }
}

/// A problem worth an alert on a remote machine.
enum MachineAlert: Equatable {
  case disk(mount: String, percent: Int)
  case load(Double, cores: Int)
  case failedUnits([String])
  case containerStopped(String, status: String)
  case containerUnhealthy(String)
}
/// `before` is the previous reading, for sustained load and containers that stopped since.
func machineAlerts(_ now: RemoteStats, before: RemoteStats?) -> [MachineAlert] {
  var out: [MachineAlert] = []
  // Volumes under 1 GB are disk images and recovery partitions: always nearly full.
  for d in now.disks where d.total >= 1e9 && d.used / d.total >= 0.9 {
    out.append(.disk(mount: d.mount, percent: Int((d.used / d.total * 100).rounded())))
  }
  if now.disks.isEmpty, let total = now.diskTotal, let used = now.diskUsed, total > 0, used / total >= 0.9 {
    out.append(.disk(mount: "/", percent: Int((used / total * 100).rounded())))
  }
  let cores = Double(max(now.cpus, 1))
  if let load = now.load.first, load / cores >= 1.5, let previous = before?.load.first, previous / cores >= 1.5 {
    out.append(.load(load, cores: now.cpus))
  }
  if !now.failedUnits.isEmpty { out.append(.failedUnits(now.failedUnits)) }
  let running = Set(before?.containerList.filter { $0.state == "running" }.map(\.name) ?? [])
  for c in now.containerList where running.contains(c.name) && c.state != "running" {
    out.append(.containerStopped(c.name, status: c.status))
  }
  for c in now.containerList where c.status.contains("unhealthy") {
    out.append(.containerUnhealthy(c.name))
  }
  return out
}

extension RemoteStats {
  /// 1-minute load over cores: 1.0 means every core busy.
  var loadFraction: Double? { cpus > 0 ? load.first.map { $0 / Double(cpus) } : nil }
  var memoryFraction: Double? {
    guard let total = memoryTotal, let available = memoryAvailable, total > 0 else { return nil }
    return (total - available) / total
  }
  var diskFraction: Double? {
    guard let total = diskTotal, let used = diskUsed, total > 0 else { return nil }
    return used / total
  }
}
/// The Machines page and the floating panel both ask for readings; a host probed within the
/// last `every` seconds (less slack for timers) is not probed again.
func machineProbeDue(lastProbe: Double?, now: Double, every: Double = 60) -> Bool {
  guard let lastProbe else { return true }
  return now - lastProbe >= every - 10
}
/// The machines chosen for the panel, in the Machines page order; hosts removed there drop out.
func panelMachineHosts(selected: [String], hosts: [String]) -> [String] {
  let chosen = Set(selected)
  return hosts.filter(chosen.contains)
}

/// A systemd unit name CoreScope puts in a remote command: unit-name characters only (letters,
/// digits, `:-_.\@`), a known unit type, never an option. Quoted on top of that.
func validSystemdUnit(_ s: String) -> Bool {
  let types = ["service", "socket", "timer", "mount", "automount", "swap", "target", "path", "slice", "scope", "device"]
  guard !s.isEmpty, s.count <= 256, !s.hasPrefix("-"), !s.hasPrefix("."),
    let dot = s.lastIndex(of: "."), types.contains(String(s[s.index(after: dot)...]))
  else { return false }
  return s.unicodeScalars.allSatisfy {
    ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || ":-_.\\@".unicodeScalars.contains($0)
  }
}
enum FailedUnitCheck {
  static let journalMarker = "@@corescope-journal@@"
  static let idMarker = "@@corescope-id@@"
  /// The read-only check behind "why did this unit fail": status without log lines, the unit's
  /// recent journal (enough for a few runs; only the last run is summarized) and who we are, so
  /// an empty journal can be told apart from one we may not read. Nil for an invalid unit.
  static func command(unit: String) -> String? {
    guard validSystemdUnit(unit) else { return nil }
    let u = "'" + unit + "'"
    return "systemctl status \(u) --no-pager -n 0 2>&1; echo '\(journalMarker)'; "
      + "journalctl -u \(u) -n 200 --no-pager 2>&1; echo \"\(idMarker) $(id -u) $(id -Gn 2>/dev/null)\""
  }
}

/// Repeated error lines from a unit's journal, grouped by shape (paths, quoted names and
/// numbers vary): `message` is the first one, `samples` up to five distinct ones.
struct UnitErrorGroup: Equatable {
  var source: String
  var message: String
  var count: Int
  var samples: [String]
}
/// A well-known failure, explained in one line. CoreScope only explains; it never changes the server.
struct UnitHint: Equatable {
  enum Kind: String { case logrotateUnknownUser, logrotateDuplicate, postrotate, nginxConfig }
  var kind: Kind
  /// Config files (or the failing line, for nginx) the journal names, distinct, in order.
  var files: [String]
  /// The first six files, then how many more.
  var fileList: String { files.prefix(6).joined(separator: ", ") + (files.count > 6 ? " (+\(files.count - 6))" : "") }
  var english: String {
    let list = files.isEmpty ? "." : ": \(fileList)."
    switch kind {
    case .logrotateUnknownUser:
      return "A logrotate config names a user that no longer exists — usually left behind when a site user was deleted "
        + "(Laravel Forge leaves /etc/logrotate.d/forge-*). logrotate skips it and the run fails; remove or fix\(list)"
    case .logrotateDuplicate:
      return "Two logrotate configs rotate the same log file and logrotate refuses the second "
        + "(often an old Forge config next to a newer one). Keep one of\(list)"
    case .postrotate:
      return "A postrotate script (usually a service reload) failed after rotating — check that the service it reloads is running\(list)"
    case .nginxConfig:
      return "nginx's configuration test (nginx -t) failed; the line says which file and line. nginx keeps the old config until it passes\(list)"
    }
  }
}
struct UnitExplanation: Equatable {
  var unit: String
  var description = ""
  /// The `Active:` line, e.g. "failed (Result: exit-code) since …".
  var active = ""
  /// The failing `Process:`/`Main PID:` line, e.g. "ExecStart=/usr/sbin/logrotate … status=1/FAILURE".
  var process = ""
  var notFound = false
  var groups: [UnitErrorGroup] = []
  var hints: [UnitHint] = []
  /// Log lines of the last run (or of everything read, when no start line was found).
  var lines = 0
  /// journald hid the unit's lines from this user (not in `adm`/`systemd-journal`).
  var journalRestricted = false
  var status = ""
  var journal = ""
}

/// Reads what `FailedUnitCheck.command` printed.
func explainFailedUnit(unit: String, output: String) -> UnitExplanation {
  var e = UnitExplanation(unit: unit)
  let parts = output.components(separatedBy: FailedUnitCheck.journalMarker)
  e.status = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
  var journal = parts.count > 1 ? parts[1] : ""
  var uid = "", groups: [String] = []
  if let id = journal.range(of: FailedUnitCheck.idMarker) {
    let words = journal[id.upperBound...].split(whereSeparator: \.isWhitespace).map(String.init)
    uid = words.first ?? ""
    groups = Array(words.dropFirst())
    journal = String(journal[..<id.lowerBound])
  }
  e.journal = journal.trimmingCharacters(in: .whitespacesAndNewlines)

  for raw in e.status.split(whereSeparator: \.isNewline) {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if e.description.isEmpty, line.contains(unit), let dash = line.range(of: " - ") {
      e.description = String(line[dash.upperBound...])
    } else if line.hasPrefix("Active:") {
      e.active = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
    } else if line.hasPrefix("Process:") || line.hasPrefix("Main PID:"), e.process.isEmpty,
      line.contains("status="), !line.contains("status=0/SUCCESS")
    {
      let value = line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
      // Drop the PID: "12345 ExecStart=…" → "ExecStart=…".
      e.process = value.first?.isNumber == true ? String(value.drop(while: { !$0.isWhitespace })).trimmingCharacters(in: .whitespaces) : value
    } else if line.contains("could not be found") {
      e.notFound = true
    }
  }

  // Only the last run: lines after systemd's last "Starting …" for this unit.
  let logLines = e.journal.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("-- ") }
  var entries: [(source: String, message: String)] = []
  for line in logLines {
    guard let entry = journalEntry(line) else { continue }
    if entry.source == "systemd", entry.message.hasPrefix("Starting ") { entries.removeAll() }
    entries.append(entry)
  }
  e.lines = entries.count

  let lowerJournal = e.journal.lowercased()
  let hidden = lowerJournal.contains("not seeing messages from other users") || lowerJournal.contains("insufficient permissions")
  let privileged = uid == "0" || groups.contains { ["adm", "systemd-journal", "wheel", "root"].contains($0) }
  e.journalRestricted = entries.isEmpty && (hidden || !uid.isEmpty && !privileged)

  var order: [String] = []
  var byShape: [String: UnitErrorGroup] = [:]
  for entry in entries where isErrorLine(entry.message) {
    let key = entry.source + "\u{1}" + errorShape(entry.message)
    if var g = byShape[key] {
      g.count += 1
      if g.samples.count < 5, !g.samples.contains(entry.message) { g.samples.append(entry.message) }
      byShape[key] = g
    } else {
      order.append(key)
      byShape[key] = UnitErrorGroup(source: entry.source, message: entry.message, count: 1, samples: [entry.message])
    }
  }
  // The program's own errors first; systemd's "failed with result" lines only restate them.
  let all = order.compactMap { byShape[$0] }
  e.groups = all.filter { $0.source != "systemd" } + all.filter { $0.source == "systemd" }
  e.hints = unitHints(entries.map(\.message))
  return e
}

/// "Oct 17 00:00:01 web-1 logrotate[812]: error: …" (or short-iso) → ("logrotate", "error: …").
func journalEntry(_ line: String) -> (source: String, message: String)? {
  let words = line.split(separator: " ", omittingEmptySubsequences: true)
  // The identifier is the first word ending in ":" after the timestamp and host.
  guard let at = words.prefix(6).firstIndex(where: { $0.hasSuffix(":") && !$0.dropLast().allSatisfy { $0.isNumber || $0 == ":" } }),
    at >= 2
  else { return nil }
  var source = String(words[at].dropLast())
  if let bracket = source.firstIndex(of: "[") { source = String(source[..<bracket]) }
  let message = words[(at + 1)...].joined(separator: " ")
  return (source, message)
}
private func isErrorLine(_ message: String) -> Bool {
  let m = message.lowercased()
  return ["error", "failed", "failure", "fatal", "[emerg]", "[crit]", "denied"].contains { m.contains($0) }
}
/// The line with paths, quoted text and numbers blanked, so repeats of one problem group together.
private func errorShape(_ message: String) -> String {
  var out = ""
  var quote: Character?
  for word in message.split(separator: " ", omittingEmptySubsequences: true) {
    var w = String(word)
    if quote != nil {
      if w.last == quote || w.dropLast().last == quote { quote = nil }
      continue
    }
    if let first = w.first, first == "'" || first == "\"" || first == "‘" {
      let closer: Character = first == "‘" ? "’" : first
      if !(w.count > 1 && (w.last == closer || w.dropLast().last == closer)) { quote = closer }
      w = "'…'"
    } else if w.contains("/") || out.hasSuffix(" file") {
      w = "…"
    } else if w.contains(where: \.isNumber) {
      w = "#"
    }
    out += (out.isEmpty ? "" : " ") + w
  }
  return out
}
/// One hint per well-known failure, with the files it names.
func unitHints(_ messages: [String]) -> [UnitHint] {
  var hints: [UnitHint] = []
  func add(_ kind: UnitHint.Kind, _ file: String?) {
    if let i = hints.firstIndex(where: { $0.kind == kind }) {
      if let file, !hints[i].files.contains(file) { hints[i].files.append(file) }
    } else {
      hints.append(UnitHint(kind: kind, files: file.map { [$0] } ?? []))
    }
  }
  /// "error: /etc/logrotate.d/forge-x:5 unknown user 'x'" → "/etc/logrotate.d/forge-x".
  func configFile(_ m: String) -> String? {
    guard let path = m.split(separator: " ").first(where: { $0.hasPrefix("/") }) else { return nil }
    if let colon = path.lastIndex(of: ":"), path[path.index(after: colon)...].allSatisfy(\.isNumber) {
      return String(path[..<colon])
    }
    return String(path)
  }
  for m in messages {
    let lower = m.lowercased()
    if lower.contains("unknown user") || lower.contains("unknown group") {
      add(.logrotateUnknownUser, configFile(m))
    } else if lower.contains("duplicate log entry") {
      add(.logrotateDuplicate, configFile(m))
    } else if lower.contains("postrotate script") || lower.contains("prerotate script") {
      let target = m.split(separator: "'").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
      add(.postrotate, target)
    } else if lower.contains("nginx") && (lower.contains("[emerg]") || lower.contains("test failed")) {
      add(.nginxConfig, lower.contains("[emerg]") ? m : nil)
    }
  }
  return hints
}

/// Five minutes of a Services check: how many checks were up and down, and the summed latency.
struct HealthBucket: Codable, Equatable {
  var up = 0
  var down = 0
  var latencySum = 0.0
  var latencyCount = 0
  var latency: Double? { latencyCount > 0 ? latencySum / Double(latencyCount) : nil }
}
enum HealthHistory {
  static let bucketSeconds = 300.0
  static let keep = 7 * 24 * 12
  static func bucket(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / bucketSeconds) }
  /// Adds one result and drops buckets older than a week.
  static func record(_ buckets: inout [Int: HealthBucket], at: Date, up: Bool, latency: Double?) {
    let key = bucket(at)
    var b = buckets[key] ?? HealthBucket()
    if up { b.up += 1 } else { b.down += 1 }
    if let latency {
      b.latencySum += latency
      b.latencyCount += 1
    }
    buckets[key] = b
    let oldest = key - keep
    if buckets.keys.contains(where: { $0 < oldest }) { buckets = buckets.filter { $0.key >= oldest } }
  }
  /// Share of checks that were up in the window ending now; nil without data.
  static func uptime(_ buckets: [Int: HealthBucket], now: Date, seconds: Double) -> Double? {
    let from = bucket(now.addingTimeInterval(-seconds))
    let inWindow = buckets.filter { $0.key > from }.values
    let up = inWindow.reduce(0) { $0 + $1.up }, total = inWindow.reduce(0) { $0 + $1.up + $1.down }
    return total > 0 ? Double(up) / Double(total) : nil
  }
  /// Down periods (buckets where most checks failed), consecutive ones merged, newest first.
  static func incidents(_ buckets: [Int: HealthBucket]) -> [(start: Date, end: Date)] {
    let bad = buckets.filter { $0.value.down > $0.value.up }.keys.sorted()
    var out: [(Int, Int)] = []
    for k in bad {
      if let last = out.last, last.1 == k - 1 { out[out.count - 1].1 = k } else { out.append((k, k)) }
    }
    return out.reversed().map {
      (Date(timeIntervalSince1970: Double($0.0) * bucketSeconds), Date(timeIntervalSince1970: Double($0.1 + 1) * bucketSeconds))
    }
  }
}

/// CPU seconds (cumulative counter) read at points in time → average share of one core, in percent,
/// over the samples inside `window` seconds before the last one. Nil with fewer than two samples
/// or a counter that went backwards.
func averageCPUShare(_ samples: [(at: Double, seconds: Double)], window: Double) -> Double? {
  guard let last = samples.last else { return nil }
  guard let first = samples.first(where: { last.at - $0.at <= window }), last.at - first.at >= 5,
    last.seconds >= first.seconds
  else { return nil }
  return (last.seconds - first.seconds) / (last.at - first.at) * 100
}
/// How heavy an average share of one core is for a background monitor.
enum CostWeight: Int, Comparable {
  case low, medium, high
  init(percent: Double) { self = percent >= 1 ? .high : percent >= 0.2 ? .medium : .low }
  static func < (a: CostWeight, b: CostWeight) -> Bool { a.rawValue < b.rawValue }
}
/// CoreScope's own helpers: the bundled CLI (MCP servers, the gate hook, the status line).
func isCoreScopeHelper(path: String) -> Bool {
  path.hasSuffix("/Contents/Resources/bin/corescope") && path.contains("CoreScope")
}

/// A `corescope://` link, from Shortcuts, Raycast, scripts or a browser.
///   corescope://open/ports · corescope://profile/start?name=Shop · corescope://lookup?port=8000
///   corescope://services/check · corescope://happened?at=14:05 · corescope://palette
///   corescope://project/<id or name> (the project's changes)
enum AppLink: Equatable {
  case open(page: String?)
  case project(String)
  case profile(action: String, name: String)
  case lookup(port: UInt16?)
  case checkServices
  case happened(at: String)
  case palette
  init?(_ url: URL) {
    guard url.scheme?.lowercased() == "corescope",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] where query[item.name.lowercased()] == nil {
      if let value = item.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty { query[item.name.lowercased()] = value }
    }
    let path = components.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    switch (components.host ?? "").lowercased() {
    case "", "open": self = .open(page: (query["page"] ?? path.first)?.lowercased())
    case "profile":
      let action = (path.first ?? query["action"] ?? "").lowercased()
      guard ["start", "stop", "toggle"].contains(action), let name = query["name"] ?? path.dropFirst().first else {
        return nil
      }
      self = .profile(action: action, name: name)
    case "lookup", "port": self = .lookup(port: (query["port"] ?? path.first).flatMap(parsePort))
    case "services":
      guard path.isEmpty || path.first?.lowercased() == "check" else { return nil }
      self = .checkServices
    case "happened":
      guard let at = query["at"] ?? path.first else { return nil }
      self = .happened(at: at)
    case "palette": self = .palette
    case "project", "projects":
      guard let project = path.first ?? query["name"] else { return nil }
      self = .project(project)
    default: return nil
    }
  }
}

/// How well a palette query matches an action title: each query word must start a word of the
/// title (best) or appear inside it. Case and accents are ignored. Nil: no match; lower is better.
func quickScore(_ query: String, _ title: String) -> Int? {
  let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
  let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
  guard !words.isEmpty else { return nil }
  let target = fold(title)
  let titleWords = target.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" || $0 == "·" }).map(String.init)
  var score = 0
  for word in words {
    if titleWords.contains(where: { $0.hasPrefix(word) }) { continue }
    guard target.contains(word) else { return nil }
    score += 2
  }
  return target.hasPrefix(words[0]) ? score : score + 1
}
/// Whether palette text reads as a clock time ("14:05", "2:05 pm", "14h05", "ontem 9:30").
func looksLikeTime(_ text: String) -> Bool {
  let t = text.lowercased().trimmingCharacters(in: .whitespaces)
  let words = ["ontem", "yesterday", "ayer"]
  let rest = words.first(where: { t.hasPrefix($0) }).map { String(t.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? t
  return rest.range(of: #"^\d{1,2}([:h]\d{2})?\s*(am|pm)?$"#, options: .regularExpression) != nil
    && (rest.contains(":") || rest.contains("h") || rest.hasSuffix("m"))
}


/// Claude Desktop's own usage samples (`~/Library/Application Support/Claude/plan-usage-history.json`,
/// `{samples: [{t: ms, org, u: {fh, sd}}]}`): the latest 5-hour and weekly percentages. They carry
/// no reset times; a sample older than its window says nothing about it.
struct DesktopUsage: Equatable {
  var fiveHour: Double?
  var sevenDay: Double?
  let at: Date
}
func parseDesktopUsage(_ data: Data, now: Date = Date()) -> DesktopUsage? {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let samples = object["samples"] as? [[String: Any]],
    let last = samples.max(by: { (($0["t"] as? NSNumber)?.doubleValue ?? 0) < (($1["t"] as? NSNumber)?.doubleValue ?? 0) }),
    let t = (last["t"] as? NSNumber)?.doubleValue, let u = last["u"] as? [String: Any]
  else { return nil }
  let at = Date(timeIntervalSince1970: t / 1000)
  let age = now.timeIntervalSince(at)
  let pct = { (key: String) in (u[key] as? NSNumber)?.doubleValue.flatMap { $0 >= 0 && $0 <= 100 ? $0 : nil } }
  let usage = DesktopUsage(
    fiveHour: age < 5 * 3600 ? pct("fh") : nil, sevenDay: age < 7 * 86400 ? pct("sd") : nil, at: at)
  return usage.fiveHour == nil && usage.sevenDay == nil ? nil : usage
}
extension Double {
  fileprivate func flatMap(_ f: (Double) -> Double?) -> Double? { f(self) }
}

/// Where a limit window is heading at the average pace since it started: the percentage at the
/// reset, and when it reaches 100% if that is before the reset. Too early in the window (first
/// 10 minutes of 5 hours, first hour of a week) there is no pace yet.
struct LimitPace: Equatable {
  let projected: Double
  let fullAt: Date?
}
func limitPace(used: Double, windowMinutes: Int, resetsAt: Date, now: Date = Date()) -> LimitPace? {
  let window = Double(windowMinutes) * 60
  let remaining = resetsAt.timeIntervalSince(now)
  let elapsed = window - remaining
  let minimum: Double = windowMinutes <= 300 ? 600 : 3600
  guard remaining > 0, elapsed >= minimum, used > 0 else { return nil }
  let rate = used / elapsed
  let projected = used + rate * remaining
  let toFull = (100 - used) / rate
  return LimitPace(projected: projected, fullAt: toFull < remaining ? now.addingTimeInterval(toFull) : nil)
}

/// Settings backups: which UserDefaults keys are the user's settings. System and framework keys
/// (NS…, Apple…, Sparkle's SU…, window and panel positions) and the runtime state of running
/// profiles (they point at process IDs that will not exist after a restore) stay out.
enum SettingsBackupLogic {
  static let runtimeKeys: Set<String> = ["envLaunched", "envExits", "envActive", "envStartedContainers", "panel.lastScreen"]
  static func isSetting(_ key: String) -> Bool {
    !(key.hasPrefix("NS") || key.hasPrefix("Apple") || key.hasPrefix("SU") || key.hasPrefix("com.apple")
      || key.hasPrefix("panel.frame.") || runtimeKeys.contains(key))
  }
  static func settings(_ domain: [String: Any]) -> [String: Any] {
    domain.filter { isSetting($0.key) }
  }
  /// A domain that holds nothing the user set: a first launch, or one after an uninstaller
  /// removed the preferences.
  static func isFresh(_ domain: [String: Any]?) -> Bool {
    settings(domain ?? [:]).isEmpty
  }
  /// Dated backups to delete, keeping the newest `keep` (names sort by date).
  static func expired(_ names: [String], keep: Int) -> [String] {
    let dated = names.filter { $0.hasPrefix("settings-") && $0.hasSuffix(".plist") }.sorted()
    return Array(dated.dropLast(keep))
  }
}

/// "a/b/c.txt" → ["a", "a/b"]: the folders above a repository-relative path.
func pathAncestors(_ path: String) -> [String] {
  let parts = path.split(separator: "/").dropLast()
  return parts.indices.map { parts[parts.startIndex...$0].joined(separator: "/") }
}

// MARK: - Performance audit (MCP performance_audit, Overview card)

/// How sure CoreScope is that a finding can go without getting in the user's way.
enum AuditConfidence: Int, Comparable {
  case low, medium, high
  var factor: Double { [0.4, 0.7, 1][rawValue] }
  var name: String { ["low", "medium", "high"][rawValue] }
  static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}
/// What acting on a finding would give back: CPU in % of one core, memory and disk in bytes.
struct AuditImpact: Equatable {
  var cpu: Double = 0
  var memory: Double = 0
  var disk: Double = 0
  var watts: Double = 0
}
/// The Mac's state, which decides the resource that matters most right now.
struct AuditContext: Equatable {
  var memoryTight = false
  var diskTight = false
  var onBattery = false
  /// Memory pressure level (0 normal, 1 warning, 2 critical) or 2 GB of swap; startup disk under
  /// 10 % free; running on battery.
  init(pressure: Double?, swap: Double?, diskFree: Double?, diskTotal: Double?, onBattery: Bool) {
    memoryTight = (pressure ?? 0) >= 1 || (swap ?? 0) >= 2 * 1_073_741_824
    if let free = diskFree, let total = diskTotal, total > 0 { diskTight = free / total < 0.10 }
    self.onBattery = onBattery
  }
  init() {}
}
/// One comparable figure per finding: a core fully busy ≈ 10, 1 GB of memory ≈ 4 (8 under
/// pressure), 1 GB of disk ≈ 0.5 (2 when the disk is nearly full), 1 W ≈ 1 (2 on battery);
/// scaled by confidence so a sure small win can beat a doubtful big one.
func auditScore(_ impact: AuditImpact, confidence: AuditConfidence, context: AuditContext) -> Double {
  let gb = 1_073_741_824.0
  let cpu = max(0, impact.cpu) / 10
  let memory = max(0, impact.memory) / gb * (context.memoryTight ? 8 : 4)
  let disk = max(0, impact.disk) / gb * (context.diskTight ? 2 : 0.5)
  let watts = max(0, impact.watts) * (context.onBattery ? 2 : 1)
  return (cpu + memory + disk + watts) * confidence.factor
}
/// Highest score first; equal scores keep their order (stable for the same inputs).
func rankAudit<T>(_ items: [T], score: (T) -> Double) -> [T] {
  items.enumerated().sorted { a, b in
    let (x, y) = (score(a.element), score(b.element))
    return x != y ? x > y : a.offset < b.offset
  }.map(\.element)
}
/// Thresholds for what is worth listing.
enum AuditThreshold {
  static let heavyCPU = 50.0
  static let heavyMemory = 1.5 * 1_073_741_824
  static let sustainedSeconds = 60.0
  static let orphanMemory = 30.0 * 1_048_576
  static let idleContainerCPU = 1.0
  static let idleContainerMemory = 200.0 * 1_048_576
  static let diskItem = 500.0 * 1_048_576
  static let growth = 1_073_741_824.0
  static let scanStale = 6 * 3600.0
  static let deadService = 0.2
}
/// A process worth a look: CPU at least `heavyCPU` for a sustained minute (≥ 80 % of a core per
/// the collector's own counter), or memory over `heavyMemory`.
func auditHeavyProcess(cpu: Double, memory: Double, highCPUSeconds: Double) -> Bool {
  (cpu >= AuditThreshold.heavyCPU && highCPUSeconds >= AuditThreshold.sustainedSeconds)
    || memory >= AuditThreshold.heavyMemory
}
/// An orphan that holds something: memory, a busy core or a port.
func auditOrphanWorthStopping(cpu: Double, memory: Double, listening: Bool) -> Bool {
  memory >= AuditThreshold.orphanMemory || cpu >= 1 || listening
}
/// A running container nothing seems to use: nearly no CPU while holding memory, and no started
/// profile owns it. Without stats (nil) nothing is claimed.
func auditIdleContainer(cpu: Double?, memory: Double?, inActiveProfile: Bool) -> Bool {
  guard let cpu, let memory, !inActiveProfile else { return false }
  return cpu < AuditThreshold.idleContainerCPU && memory >= AuditThreshold.idleContainerMemory
}
/// Confidence that a reclaimable dev-space item can go: Docker data and caches are re-created on
/// demand; a worktree only when merged; build folders untouched for a month.
func auditDiskConfidence(kind: String, modified: Double, merged: Bool, now: Double) -> AuditConfidence {
  switch kind {
  case "docker_dangling", "docker_build_cache", "derived_data", "simulator_caches", "cache": return .high
  case "worktree": return merged ? .high : .low
  default:
    return modified > 0 && now - modified > 30 * 86400 ? .high : .medium
  }
}
/// A Services check that has been down most of a day still runs every 30 s for nothing.
func auditDeadService(uptime24h: Double?) -> Bool {
  guard let uptime24h else { return false }
  return uptime24h < AuditThreshold.deadService
}
/// Seconds since the scan, or nil when it is fresh enough to rank from.
func auditStaleAge(scannedAt: Double?, now: Double, limit: Double = AuditThreshold.scanStale) -> Double? {
  guard let scannedAt else { return .infinity }
  let age = now - scannedAt
  return age > limit ? age : nil
}
