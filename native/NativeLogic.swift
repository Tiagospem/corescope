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

func formatBytes(_ value: Double) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .memory)
}
func formatRate(_ value: Double) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .file) + "/s"
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
enum ClaudeGateHook {
  static func command(binary: String) -> String { ClaudeStatusLine.shellQuote(binary) + " gate" }
  private static func isOurs(_ hook: OrderedJSON) -> Bool {
    hook["command"]?.stringValue?.hasSuffix(" gate") == true && hook["command"]?.stringValue?.contains("corescope") == true
  }
  static func installed(in settings: OrderedJSON?) -> Bool {
    guard case .array(let groups)? = settings?["hooks"]?["PreToolUse"] else { return false }
    return groups.contains { group in
      guard case .array(let hooks)? = group["hooks"] else { return false }
      return hooks.contains(where: isOurs)
    }
  }
  /// Settings with the hook (replacing an older CoreScope entry, e.g. after the app moved).
  static func installing(into settings: OrderedJSON, binary: String, timeout: Int = 3600) -> OrderedJSON {
    let cleaned = removing(from: settings)
    let group = OrderedJSON.object([
      .init(key: "matcher", value: .string("Bash")),
      .init(key: "hooks", value: .array([
        .object([
          .init(key: "type", value: .string("command")),
          .init(key: "command", value: .string(command(binary: binary))),
          .init(key: "timeout", value: .number(String(timeout))),
        ])
      ])),
    ])
    let hooks = cleaned["hooks"] ?? .object([])
    var groups: [OrderedJSON] = []
    if case .array(let existing)? = hooks["PreToolUse"] { groups = existing }
    groups.append(group)
    return cleaned.setting("hooks", hooks.setting("PreToolUse", .array(groups)))
  }
  /// Settings without CoreScope's hook; groups and sections left empty by it are dropped.
  static func removing(from settings: OrderedJSON) -> OrderedJSON {
    guard let hooks = settings["hooks"], case .array(let groups)? = hooks["PreToolUse"] else { return settings }
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
    let nextHooks = hooks.setting("PreToolUse", kept.isEmpty ? nil : .array(kept))
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
