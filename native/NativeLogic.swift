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

/// Plan limits from the text Claude Code's own `/usage` command prints (`claude -p /usage`):
/// "Current session: 10% used · resets Oct 18 at 10:59pm (America/Sao_Paulo)" is the 5-hour
/// window and "Current week (all models): 85% used · resets Oct 20 at 4am (…)" the weekly one;
/// per-model weekly lines are left out. The reset carries no year: the one that puts it closest
/// to `now` wins, and a bare time ("resets 11pm") is the next such time.
func parseClaudeUsageText(_ text: String, now: Date = Date()) -> [ClaudeLimitSample] {
  let pattern = #"^\s*Current (session|week \(all models\)):\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets\s+(.+?))?(?:\s*\(([^)]+)\))?\s*$"#
  guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
  var out: [ClaudeLimitSample] = []
  let ns = text as NSString
  for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
    func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
    let (id, minutes) = group(1) == "session" ? ("five_hour", 300) : ("seven_day", 10080)
    guard !out.contains(where: { $0.id == id }), let used = group(2).flatMap(Double.init) else { continue }
    let zone = group(4).flatMap(TimeZone.init(identifier:)) ?? .current
    let reset = group(3).flatMap { claudeUsageReset($0, zone: zone, now: now) }
    out.append(ClaudeLimitSample(id: id, usedPercent: min(max(used, 0), 100), windowMinutes: minutes, resetsAt: reset))
  }
  return out
}
/// "Oct 20 at 3:59am", "Oct 20 at 4am" or "11pm" in `zone`.
private func claudeUsageReset(_ text: String, zone: TimeZone, now: Date) -> Date? {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = zone
  let parts = text.components(separatedBy: " at ")
  let timeText = parts.last!.lowercased().replacingOccurrences(of: " ", with: "")
  guard let t = timeText.range(of: #"^(\d{1,2})(?::(\d{2}))?(am|pm)?$"#, options: .regularExpression) else { return nil }
  let clock = String(timeText[t])
  let pm = clock.hasSuffix("pm")
  let am = clock.hasSuffix("am")
  let digits = clock.trimmingCharacters(in: CharacterSet(charactersIn: "apm")).split(separator: ":")
  guard var hour = Int(digits[0]), let minute = digits.count > 1 ? Int(digits[1]) : 0, hour < 24, minute < 60 else { return nil }
  if pm && hour < 12 { hour += 12 }
  if am && hour == 12 { hour = 0 }
  if parts.count == 1 {
    guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else { return nil }
    return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
  }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = zone
  formatter.dateFormat = "MMM d"
  guard let day = formatter.date(from: parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
  let md = calendar.dateComponents([.month, .day], from: day)
  let year = calendar.component(.year, from: now)
  return (year - 1...year + 1).compactMap {
    calendar.date(from: DateComponents(year: $0, month: md.month, day: md.day, hour: hour, minute: minute))
  }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
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
  /// The port a listener on this Mac would hold: loopback, `.localhost` and `.test` hosts (Valet,
  /// Herd, dnsmasq point those here). nil for other hosts, where a local listener says nothing.
  var localPort: UInt16? {
    switch self {
    case .tcp(let host, let port):
      return HealthTarget.tcp(host: host, port: port).isLocal || host.lowercased().hasSuffix(".test") ? port : nil
    case .http(let url):
      guard isLocal || (url.host ?? "").lowercased().hasSuffix(".test") else { return nil }
      return url.port.map(UInt16.init) ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
  }
}

/// What a Services row means, beyond the probe's answer: a check from a project whose
/// environment is off and whose port nobody listens on is "not running", not a failure.
enum ServiceState: String, CaseIterable {
  /// Worst first (summaries follow this order). `starting`, `external` and `unknown` only come from
  /// checks bound to profiles or a status component (`boundServiceState`).
  case down, unknown, warn, starting, notRunning = "not_running", external, paused, pending, up
  /// Counts as a failure (uptime, notifications, red).
  var isFailure: Bool { self == .down }
  /// Probe results are kept in the history and uptime only for checks that should be up.
  var recordsHistory: Bool { self == .up || self == .warn || self == .down }
  /// What MCP reports.
  var mcpStatus: String {
    switch self {
    case .warn: "answered_with_error"
    case .pending: "not_checked_yet"
    default: rawValue
    }
  }
}
/// - fromProject: declared in a `.corescope.yml` (hand-added checks always should be up).
/// - hasProfile: that project defines a profile (its app is started through CoreScope).
/// - profileRunning: one of that project's profiles is started or has a command running.
/// - listening: something on this Mac listens on the target's port; nil when that can't be known
///   (remote host).
/// A project check is an app's health check: while the app is off it is "not running". With a
/// profile it is not even probed (`shouldProbe`), whatever an older result said.
func serviceState(
  level: HealthLevel?, paused: Bool, fromProject: Bool, hasProfile: Bool, profileRunning: Bool, listening: Bool?
) -> ServiceState {
  if paused { return .paused }
  let off = fromProject && !profileRunning && listening == false
  if off && hasProfile { return .notRunning }
  switch level {
  case nil: return off ? .notRunning : .pending
  case .up: return .up
  case .warn: return .warn
  case .down: return off ? .notRunning : .down
  }
}
/// Paused checks and apps whose profile is stopped (and port free) are left alone.
func shouldProbe(paused: Bool, fromProject: Bool, hasProfile: Bool, profileRunning: Bool, listening: Bool?) -> Bool {
  !paused && !(fromProject && hasProfile && !profileRunning && listening == false)
}

/// Whether a check bound to profiles (`profiles:`) or a status component (`component:`) should be
/// up right now.
enum ServiceExpectation: Equatable {
  case expected
  case notExpected
  /// The selection could not be read (status failed, timed out or is stale): never up, never off.
  case unknown(String)
}
/// - profilesOn: per bound profile, on (true), off (false) or unknown (nil: a controller profile
///   whose status could not be read and that CoreScope did not start).
/// - component: the bound component's `expected` from a fresh status; nil when there is no
///   binding; `.some(nil)` when bound but the status is missing, stale or does not list it.
/// A component the controller reports wins: it knows about dependencies kept for other apps.
func serviceExpectation(profilesOn: [Bool?], component: Bool??, unknownReason: String) -> ServiceExpectation {
  if case .some(.some(let expected)) = component { return expected ? .expected : .notExpected }
  if profilesOn.contains(true) { return .expected }
  if component == nil, !profilesOn.isEmpty, profilesOn.allSatisfy({ $0 == false }) { return .notExpected }
  return .unknown(unknownReason)
}
/// A bound check: the binding, not a port that happens to listen (a proxy on 443 proves nothing
/// about the apps behind it), says whether it should be up.
/// - starting: its profile's operation is running, the controller says the component is starting,
///   or the profile started moments ago and the check has not answered yet.
func boundServiceState(level: HealthLevel?, paused: Bool, expectation: ServiceExpectation, starting: Bool) -> ServiceState {
  if paused { return .paused }
  switch expectation {
  case .unknown: return .unknown
  case .notExpected: return level == .up || level == .warn ? .external : .notRunning
  case .expected:
    if level == .up { return .up }
    if starting { return .starting }
    switch level {
    case nil: return .pending
    case .warn: return .warn
    default: return .down
    }
  }
}
/// Bound checks that nothing selected are probed only while something listens on their port (to
/// tell "running outside CoreScope" from "off"); remote targets (listening nil) are probed.
func shouldProbeBound(paused: Bool, expectation: ServiceExpectation, listening: Bool?) -> Bool {
  !paused && (expectation != .notExpected || listening != false)
}

/// What a project's `status` command reports (format 1, docs/ENVIRONMENT-CONTROLLER.md). Data,
/// never instructions: strings are clipped and only these fields are read.
struct EnvironmentStatus: Equatable {
  struct App: Equatable {
    var name: String
    var selected: Bool
  }
  struct Component: Equatable {
    var name: String
    var app: String?
    var mode: String?
    var expected: Bool
    /// running, starting, stopped, failed or unknown.
    var state: String
    var ready: Bool?
    /// controller or external.
    var controlledBy: String?
    /// Why it is kept up (a dependency of another app).
    var reason: String?
    var detail: String?
  }
  var environment: String
  var collectedAt: Date
  /// An operation the controller is running (its lock is held).
  var busy: String?
  var apps: [App]
  var components: [Component]
  var errors: [String]
  static let maxBytes = 256 * 1024
  static let states: Set<String> = ["running", "starting", "stopped", "failed", "unknown"]

  /// Throws a short reason (shown as the diagnostic) for anything that is not format 1.
  init(parsing data: Data) throws {
    guard data.count <= Self.maxBytes else { throw StatusError("output over 256 KB") }
    guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else {
      throw StatusError("output is not a JSON object")
    }
    guard (root["format"] as? NSNumber)?.intValue == 1 else { throw StatusError("format must be 1") }
    func text(_ value: Any?, _ limit: Int = 200) -> String? {
      guard let s = value as? String else { return nil }
      let clean = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
      return clean.isEmpty ? nil : String(clean.prefix(limit))
    }
    guard let environment = text(root["environment"], 100) else { throw StatusError("environment is missing") }
    let iso = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let stamp = root["collected_at"] as? String, let at = iso.date(from: stamp) ?? fractional.date(from: stamp) else {
      throw StatusError("collected_at must be an ISO 8601 date")
    }
    self.environment = environment
    collectedAt = at
    busy = text(root["busy"])
    apps = ((root["apps"] as? [[String: Any]]) ?? []).prefix(100).compactMap { a in
      guard let name = text(a["name"], 100), let selected = a["selected"] as? Bool else { return nil }
      return App(name: name, selected: selected)
    }
    components = ((root["components"] as? [[String: Any]]) ?? []).prefix(500).compactMap { c in
      guard let name = text(c["name"], 100), let expected = c["expected"] as? Bool else { return nil }
      let state = text(c["state"], 20).map { Self.states.contains($0) ? $0 : "unknown" } ?? "unknown"
      return Component(
        name: name, app: text(c["app"], 100), mode: text(c["mode"], 40), expected: expected, state: state,
        ready: c["ready"] as? Bool, controlledBy: text(c["controlled_by"], 20), reason: text(c["reason"]),
        detail: text(c["detail"]))
    }
    errors = ((root["errors"] as? [Any]) ?? []).prefix(20).compactMap { text($0, 300) }
  }
  init(environment: String, collectedAt: Date, busy: String? = nil, apps: [App], components: [Component], errors: [String] = []) {
    self.environment = environment
    self.collectedAt = collectedAt
    self.busy = busy
    self.apps = apps
    self.components = components
    self.errors = errors
  }
  /// The app is selected: as listed, else when one of its components is expected.
  func selected(_ app: String) -> Bool? {
    if let a = apps.first(where: { $0.name == app }) { return a.selected }
    let mine = components.filter { $0.app == app }
    return mine.isEmpty ? nil : mine.contains(where: \.expected)
  }
  /// Not running as expected: failed, stopped or not ready (starting ones are only late).
  var failing: [Component] {
    components.filter { $0.expected && ($0.state == "failed" || $0.state == "stopped" || ($0.state == "running" && $0.ready == false)) }
  }
}
extension EnvironmentStatus {
  /// The controller could not read any component (every expected one is `unknown`): with no
  /// container engine answering either, that is the engine switched off, not a failure.
  var nothingRead: Bool {
    let expected = components.filter(\.expected)
    return !expected.isEmpty && expected.allSatisfy { $0.state == "unknown" }
  }
  /// The same reading with the container engine off: nothing selected, nothing expected,
  /// everything stopped. Apps show off and checks stay neutral; the engine being off is the
  /// user's choice, not an error.
  var engineOff: EnvironmentStatus {
    var s = self
    s.apps = apps.map { App(name: $0.name, selected: false) }
    s.components = components.map {
      var c = $0
      c.expected = false
      c.state = "stopped"
      c.ready = nil
      return c
    }
    s.errors = []
    s.busy = nil
    return s
  }
}
struct StatusError: Error, Equatable {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}
/// A status reading too old to trust: asked for more than three polls ago (at least 2 min; the
/// app polls every 2 min with no window open), answered from a cache over 2 min old, or claiming
/// to come from the future.
func statusIsStale(collectedAt: Date, fetchedAt: Date, now: Date, interval: Double = 30) -> Bool {
  now.timeIntervalSince(fetchedAt) > max(120, interval * 3) || fetchedAt.timeIntervalSince(collectedAt) > 120
    || collectedAt.timeIntervalSince(fetchedAt) > 300
}

/// A profile run by an environment controller (`lifecycle: controller`), as one state.
enum EnvHealth: String {
  case off, starting, up, degraded, failed, unknown
}
/// The environment's status as a controller profile sees it.
enum StatusInput {
  /// The project has no `status` command.
  case none
  /// Failed, timed out, invalid or stale: the reason.
  case unavailable(String)
  case fresh(EnvironmentStatus)
}
/// - active: started through CoreScope and not stopped.
/// - inFlight: one of its commands (the controller's operation) is still running.
/// - failedExit: a command exited non-zero since the profile started.
/// - missingContainers: observed containers that are not running.
/// Returns the state, why (English, for MCP; empty when obvious) and whether the selection was
/// changed outside CoreScope (terminal, another tool).
func controllerHealth(
  active: Bool, inFlight: Bool, failedExit: Int32?, status: StatusInput, app: String, missingContainers: [String]
) -> (health: EnvHealth, reason: String, outside: Bool) {
  if inFlight { return (.starting, "the controller's operation is running", false) }
  if let failedExit, active { return (.failed, "a command exited with \(failedExit)", false) }
  switch status {
  case .unavailable(let why):
    return (.unknown, "status unavailable: \(why)", false)
  case .none:
    guard active else { return (.off, "", false) }
    if !missingContainers.isEmpty { return (.degraded, "not running: \(missingContainers.joined(separator: ", "))", false) }
    return (.up, "no status command: the commands succeeded", false)
  case .fresh(let s):
    guard s.selected(app) == true else {
      return (.off, active ? "switched off outside CoreScope" : "", active)
    }
    let mine = s.components.filter { $0.app == app && $0.expected }
    let failing = s.failing.filter { $0.app == app }.map(\.name) + (active ? missingContainers : [])
    if !failing.isEmpty { return (.degraded, "not running as expected: \(failing.joined(separator: ", "))", !active) }
    if let busy = s.busy { return (.starting, "controller busy: \(busy)", !active) }
    // The controller could not tell (its engine is down, say): unknown, not "starting".
    let unread = mine.filter { $0.state == "unknown" }.map(\.name)
    if !unread.isEmpty { return (.unknown, "state unknown: \(unread.joined(separator: ", "))", !active) }
    let late = mine.filter { $0.state == "starting" }.map(\.name)
    if !late.isEmpty { return (.starting, "starting: \(late.joined(separator: ", "))", !active) }
    return (.up, active ? "" : "selected outside CoreScope", !active)
  }
}
/// The compact menu bar form of a formatted value: "11,65 GB" → "11,6G", "1,9 MB/s" → "1,9M/s",
/// "512 B/s" → "512B/s". One decimal at most (cut, not rounded: it is a glance).
func compactValue(_ text: String) -> String {
  let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
  guard parts.count == 2 else { return text }
  var number = parts[0]
  if let sep = number.firstIndex(where: { $0 == "," || $0 == "." }) {
    let decimals = number[number.index(after: sep)...]
    number = decimals.count > 1 ? String(number[...number.index(after: sep)]) : number
  }
  let units = ["TB": "T", "GB": "G", "MB": "M", "KB": "K", "kB": "K", "B": "B"]
  let unit = parts[1].hasSuffix("/s") ? String(parts[1].dropLast(2)) : parts[1]
  guard let short = units[unit] else { return text }
  return number + short + (parts[1].hasSuffix("/s") ? "/s" : "")
}

/// What a project action is for, to list them in a useful order.
enum ActionKind: String, CaseIterable {
  case setup, run, diagnostics, data, stop, other
  /// From `kind:` in the file, else from the words of its name: `eco-arena-migrate` is setup,
  /// `docker-hindsight-stop` stop, `eco-memory-backup` data.
  static func of(name: String, explicit: String?) -> ActionKind {
    if let explicit, let kind = ActionKind(rawValue: explicit) { return kind }
    let words = Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let table: [(ActionKind, Set<String>)] = [
      (.data, ["backup", "restore", "export", "import", "recover", "restored", "dump", "snapshot"]),
      (.diagnostics, ["doctor", "status", "logs", "log", "agents", "check", "diagnostic", "diagnostics", "health", "test"]),
      (.stop, ["stop", "down", "halt"]),
      (.setup, ["init", "setup", "migrate", "config", "install", "seed", "herd", "storage", "banks", "bootstrap"]),
      (.run, ["up", "start", "build", "dev", "only", "restart", "activate", "mode", "use", "rebuild", "run"]),
    ]
    return table.first { !$0.1.isDisjoint(with: words) }?.0 ?? .other
  }
}
/// The last `CORESCOPE_ARTIFACT=<path>` line an action printed (relative paths resolve against
/// the project folder). The caller shows it only after exit 0 and if the file exists.
func actionArtifact(_ output: String, folder: String) -> String? {
  guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("CORESCOPE_ARTIFACT=") }) else {
    return nil
  }
  let path = line.dropFirst("CORESCOPE_ARTIFACT=".count).trimmingCharacters(in: .whitespaces)
  guard !path.isEmpty else { return nil }
  return path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
}

/// Ports an error message names ("Porta 19091 ocupada", "port 3000 in use", "127.0.0.1:8080"),
/// in order, without repeats.
func portsMentioned(_ text: String) -> [UInt16] {
  // "port 80" / "porta 19091", or ":8080" (three digits or more, so times like 12:30 are not ports).
  guard let re = try? NSRegularExpression(pattern: "(?i)(?:\\bporta?\\s*(\\d{2,5})|:(\\d{3,5}))\\b") else { return [] }
  let ns = text as NSString
  var out: [UInt16] = []
  for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
    let range = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
    if let port = UInt16(ns.substring(with: range)), port > 0, !out.contains(port) { out.append(port) }
  }
  return out
}
/// Moves `key` one place up or down in `order` (the context menu alternative to dragging).
func movedOne(_ order: [String], _ key: String, up: Bool) -> [String] {
  guard let i = order.firstIndex(of: key) else { return order }
  let j = up ? i - 1 : i + 1
  guard order.indices.contains(j) else { return order }
  var next = order
  next.swapAt(i, j)
  return next
}
/// Sorts by a saved order (keys missing from it go last, in the given fallback order).
func orderedBySaved<T>(_ items: [T], key: (T) -> String, saved: [String]) -> [T] {
  let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
  return items.enumerated().sorted { a, b in
    let ra = rank[key(a.element)] ?? Int.max
    let rb = rank[key(b.element)] ?? Int.max
    return ra != rb ? ra < rb : a.offset < b.offset
  }.map(\.element)
}
/// Log text as people read it: no ANSI colors, progress lines rewritten in place (`\r`) kept at
/// their last state.
func cleanLogText(_ raw: String) -> String {
  let noAnsi = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
  return noAnsi.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
    .map { line in line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
    .joined(separator: "\n")
}
/// The exit code CoreScope appended to a run's log (`[CoreScope] exit N`), from its last lines.
func logExitCode(_ tail: String) -> Int32? {
  guard let line = tail.components(separatedBy: "\n").last(where: { $0.hasPrefix("[CoreScope] exit ") }) else { return nil }
  return Int32(line.dropFirst("[CoreScope] exit ".count).trimmingCharacters(in: .whitespaces))
}

/// Per-group summary, worst first, without empty states: [(.down, 2), (.up, 4)].
func serviceSummary(_ states: [ServiceState]) -> [(state: ServiceState, count: Int)] {
  ServiceState.allCases.compactMap { s in
    let n = states.filter { $0 == s }.count
    return n > 0 ? (s, n) : nil
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
  /// The gate decides within ~5 s (it never holds the command); a hook that times out lets it run.
  var timeout: Int { self == .gate ? 10 : 15 }
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

// MARK: Docker volumes

/// Why a volume cannot be removed. Only volumes no container references (running or stopped)
/// are removable; when the engine did not say, nothing is removed.
enum VolumeBlock: Equatable {
  case inUse([String])
  case inUseCount(Int)
  case usageUnknown
}
/// `refCount` is the engine's RefCount (-1 when it did not report one); `usedBy` the containers
/// whose mounts name the volume.
func volumeBlock(refCount: Int, usedBy: [String]) -> VolumeBlock? {
  if !usedBy.isEmpty { return .inUse(usedBy) }
  if refCount > 0 { return .inUseCount(refCount) }
  if refCount < 0 { return .usageUnknown }
  return nil
}
/// `docker run -v /path` and Dockerfile `VOLUME` make volumes named by 64 hex digits.
func isAnonymousVolume(_ name: String) -> Bool {
  name.count == 64 && name.allSatisfy { $0.isHexDigit }
}
/// What the labels say made a volume: a compose project (and its volume key) or a swarm stack.
struct VolumeOrigin: Equatable {
  var project: String?
  var detail: String?
}
func volumeOrigin(labels: [String: String]) -> VolumeOrigin? {
  let value = { (key: String) in labels[key].flatMap { $0.isEmpty ? nil : $0 } }
  let project = value("com.docker.compose.project") ?? value("com.docker.stack.namespace")
  let detail = value("com.docker.compose.volume") ?? value("com.docker.compose.service")
  return project == nil && detail == nil ? nil : VolumeOrigin(project: project, detail: detail)
}
/// "MySQL", "PostgreSQL" or "Redis" when the name, the compose volume key or the images of the
/// containers using it say so. Removing such a volume deletes a database.
func volumeDatabaseKind(name: String, labels: [String: String], images: [String] = []) -> String? {
  let text = ([name, labels["com.docker.compose.volume"] ?? ""] + images).joined(separator: " ").lowercased()
  if text.contains("mysql") || text.contains("mariadb") { return "MySQL" }
  if text.contains("postgres") || text.contains("pgdata") { return "PostgreSQL" }
  if text.contains("redis") || text.contains("valkey") { return "Redis" }
  return nil
}
/// The volumes a bulk removal acts on (only removable ones) and the bytes it frees.
func volumeRemovalPlan(_ volumes: [(name: String, size: Int64?, refCount: Int, usedBy: [String])])
  -> (names: [String], bytes: Int64, blocked: Int)
{
  let ok = volumes.filter { volumeBlock(refCount: $0.refCount, usedBy: $0.usedBy) == nil }
  return (ok.map(\.name), ok.compactMap(\.size).reduce(0, +), volumes.count - ok.count)
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

// MARK: - Projects: worktrees and branches no longer used

/// What decides whether a linked worktree can go (the core's `WorktreeView`).
struct WorktreeFacts: Equatable {
  var path: String
  var branch: String? = nil
  var main = false
  var current = false
  var locked = false
  var prunable = false
  var merged: Bool? = nil
  var gone = false
  var changes: Int? = 0
  var inUse: String? = nil
}
/// What decides whether a local branch can go (the core's `LocalBranch`).
struct BranchFacts: Equatable {
  var name: String
  var current = false
  /// Checked out in this other working tree.
  var worktree: String? = nil
  var merged: Bool? = nil
  var gone = false
}
enum PruneReason: String {
  case merged, upstreamGone = "upstream_gone", folderGone = "folder_gone", worktreeRemoved = "worktree_removed"
}
/// Why an item stays. The core reports the same codes when it refuses one.
enum PruneBlock: String {
  case main, current, inUse = "in_use", locked, notMerged = "not_merged", defaultBranch = "default_branch"
  case checkedOut = "checked_out", unknownChanges = "unknown_changes", dirty
  case notAWorktree = "not_a_worktree", noSuchBranch = "no_such_branch"
}
struct PruneVerdict: Equatable {
  var reasons: [PruneReason]
  var block: PruneBlock?
  var removable: Bool { block == nil && !reasons.isEmpty }
}

/// The app's copy of the core's rules (`gitbranches::worktree_verdict`), which decide again before
/// removing: a linked worktree can go when its branch is merged into the default branch, its
/// upstream is gone or its folder is already gone; never the main or the project's own working
/// tree, one a process works in, one git locked, or one with uncommitted changes unless
/// `allowDirty`.
func worktreeVerdict(_ w: WorktreeFacts, allowDirty: Bool = false) -> PruneVerdict {
  var reasons: [PruneReason] = []
  if w.prunable { reasons.append(.folderGone) }
  if w.merged == true { reasons.append(.merged) }
  if w.gone { reasons.append(.upstreamGone) }
  let block: PruneBlock?
  if w.main {
    block = .main
  } else if w.current {
    block = .current
  } else if w.inUse != nil {
    block = .inUse
  } else if w.locked {
    block = .locked
  } else if reasons.isEmpty {
    block = .notMerged
  } else if w.prunable {
    block = nil
  } else if let n = w.changes {
    block = n > 0 && !allowDirty ? .dirty : nil
  } else {
    block = .unknownChanges
  }
  return PruneVerdict(reasons: reasons, block: block)
}

/// `name` is the default branch itself (`main` for `origin/main`).
func isDefaultBranch(_ name: String, default branch: String?) -> Bool {
  guard let branch else { return false }
  return branch == name || branch.hasSuffix("/" + name)
}

/// A local branch can go when it is merged into the default branch and checked out nowhere, or
/// only in a worktree removed first (`freed`). Mirrors `gitbranches::branch_verdict`.
func branchVerdict(_ b: BranchFacts, defaultBranch: String?, freed: Set<String> = []) -> PruneVerdict {
  var reasons: [PruneReason] = []
  if b.merged == true { reasons.append(.merged) }
  if b.gone { reasons.append(.upstreamGone) }
  let held = b.worktree.flatMap { freed.contains($0) ? nil : $0 }
  if b.worktree != nil && held == nil { reasons.append(.worktreeRemoved) }
  let block: PruneBlock?
  if b.current {
    block = .current
  } else if isDefaultBranch(b.name, default: defaultBranch) {
    block = .defaultBranch
  } else if held != nil {
    block = .checkedOut
  } else if b.merged != true {
    block = .notMerged
  } else {
    block = nil
  }
  return PruneVerdict(reasons: reasons, block: block)
}

/// How the project card groups worktrees and branches: what is in use (the checkout, the main
/// working tree, a process inside, a branch checked out), what can go, and the rest.
enum RefGroup: Int, CaseIterable {
  case inUse, removable, other
}
func worktreeGroup(_ w: WorktreeFacts) -> RefGroup {
  if w.main || w.current || w.inUse != nil { return .inUse }
  return worktreeVerdict(w).removable ? .removable : .other
}
func branchGroup(_ b: BranchFacts, defaultBranch: String?) -> RefGroup {
  if b.current || b.worktree != nil { return .inUse }
  return branchVerdict(b, defaultBranch: defaultBranch).removable ? .removable : .other
}

/// One line of the removal sheet.
struct PruneCandidate: Equatable {
  enum Kind { case worktree, branch }
  let kind: Kind
  /// The worktree path or the branch name.
  let target: String
  let verdict: PruneVerdict
  var key: String { (kind == .worktree ? "w:" : "b:") + target }
}
/// What the removal sheet lists: worktrees and branches that qualify, removable or held back with
/// the reason. A branch freed by removing its worktree counts only while that worktree is chosen.
func pruneCandidates(
  worktrees: [WorktreeFacts], branches: [BranchFacts], defaultBranch: String?, allowDirty: Bool,
  chosenWorktrees: Set<String>
) -> [PruneCandidate] {
  var out: [PruneCandidate] = []
  var removable: Set<String> = []
  for w in worktrees where !w.main && !w.current {
    let v = worktreeVerdict(w, allowDirty: allowDirty)
    guard !v.reasons.isEmpty else { continue }
    if v.removable { removable.insert(w.path) }
    out.append(PruneCandidate(kind: .worktree, target: w.path, verdict: v))
  }
  let freed = removable.intersection(chosenWorktrees)
  for b in branches where b.merged == true {
    let v = branchVerdict(b, defaultBranch: defaultBranch, freed: freed)
    // A branch checked out in a worktree that cannot go is simply in use: not listed.
    if v.block == .checkedOut, let wt = b.worktree, !removable.contains(wt) { continue }
    out.append(PruneCandidate(kind: .branch, target: b.name, verdict: v))
  }
  return out
}
/// The ones ticked by default: removable, except those with uncommitted changes (the "dirty"
/// option makes them choosable, never chosen for you).
func defaultPruneSelection(_ candidates: [PruneCandidate], worktrees: [WorktreeFacts]) -> Set<String> {
  let dirty = Set(worktrees.filter { ($0.changes ?? 0) > 0 }.map(\.path))
  return Set(
    candidates.filter { $0.verdict.removable && !($0.kind == .worktree && dirty.contains($0.target)) }.map(\.key))
}
