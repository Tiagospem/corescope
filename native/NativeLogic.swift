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
func projectName(_ cwd: String) -> String? {
  let home = NSHomeDirectory()
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
