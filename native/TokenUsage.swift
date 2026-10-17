import Foundation

// Token usage read from agent transcripts on disk. Pure Foundation so the standalone tests can
// exercise it; only counts, model ids, session ids and working directories are ever kept.

/// Token counts as agents report them. `input` never includes cached prompt tokens, so the four
/// fields add up without double counting on every agent.
struct TokenCounts: Equatable {
  var input = 0
  var output = 0
  var cacheWrite = 0
  var cacheRead = 0
  var total: Int { input + output + cacheWrite + cacheRead }
  var cache: Int { cacheWrite + cacheRead }
  static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
    TokenCounts(
      input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
      cacheRead: a.cacheRead + b.cacheRead)
  }
  static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
  /// Growth from `old` to `self`, never negative.
  func since(_ old: TokenCounts) -> TokenCounts {
    TokenCounts(
      input: max(0, input - old.input), output: max(0, output - old.output),
      cacheWrite: max(0, cacheWrite - old.cacheWrite), cacheRead: max(0, cacheRead - old.cacheRead))
  }
}

enum AgentKind: String {
  case claude = "Claude Code"
  case codex = "Codex"
}

/// Incremental reader state for one transcript file: the byte offset where reading stopped and
/// what the complete lines before it added up to. Message text is never stored.
struct TranscriptTally {
  let kind: AgentKind
  /// Claude: the session uuid (subagent transcripts count toward their parent session).
  /// Codex: `session_id` from session_meta, shared by the forks of one conversation.
  var session: String?
  var isSubagent = false
  var cwd: String?
  var model: String?
  var offset: UInt64 = 0
  var total = TokenCounts()
  /// Local day index (see `localDay`) → tokens used that day.
  var days: [Int: TokenCounts] = [:]
  /// Claude writes one line per content block of a message, consecutively, each carrying the
  /// usage so far (output grows); only the growth since the previous block is added.
  private var lastMessage: String?
  private var lastUsage = TokenCounts()
  /// Codex repeats token_count events with an unchanged running total; those add nothing.
  private var lastTotal: TokenCounts?

  init(kind: AgentKind, path: String) {
    self.kind = kind
    guard kind == .claude else { return }
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    if parent.lastPathComponent == "subagents" {
      isSubagent = true
      session = parent.deletingLastPathComponent().lastPathComponent
    } else {
      session = url.deletingPathExtension().lastPathComponent
    }
  }

  /// Reads the bytes appended since the last call, up to the last complete line.
  /// One reusable buffer holds a chunk plus any unfinished line. Lines longer than the buffer
  /// are kept only when their start shows they can carry usage (up to `maxLine`); others, like
  /// Codex's multi-megabyte `compacted` entries, are skipped without being buffered.
  mutating func read(_ url: URL, size: UInt64, chunk: Int = 1 << 20, maxLine: Int = 32 << 20) {
    if size < offset { self = TranscriptTally(kind: kind, path: url.path) }  // truncated/replaced
    guard size > offset else { return }
    let fd = open(url.path, O_RDONLY)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: chunk)
    var filled = 0
    var position = offset  // file offset just past the buffered bytes
    var skipping = false
    while position < size {
      if filled == buffer.count {
        let keep = buffer.withUnsafeBytes { wants(UnsafeRawBufferPointer(rebasing: $0[0..<512])) }
        if keep && buffer.count < maxLine {
          buffer += [UInt8](repeating: 0, count: buffer.count)
        } else {
          skipping = true
          filled = 0
        }
      }
      let wanted = min(buffer.count - filled, Int(size - position))
      let got = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + filled, wanted, off_t(position)) }
      guard got > 0 else { break }
      let fresh = filled
      position += UInt64(got)
      filled += got
      var start = 0
      buffer.withUnsafeBytes { raw in
        let base = raw.baseAddress!
        if skipping {
          guard let hit = memchr(base + fresh, 0x0A, filled - fresh) else { return }
          start = base.distance(to: UnsafeRawPointer(hit)) + 1
          skipping = false
        }
        // Consume complete lines; the unterminated tail waits for the next chunk or call.
        while start < filled, let hit = memchr(base + start, 0x0A, filled - start) {
          let end = base.distance(to: UnsafeRawPointer(hit))
          if end > start { consume(UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
          start = end + 1
        }
      }
      if skipping {
        filled = 0  // still inside the skipped line; `offset` stays at its start
      } else if start > 0 {
        offset = position - UInt64(filled - start)
        buffer.withUnsafeMutableBytes { _ = memmove($0.baseAddress!, $0.baseAddress! + start, filled - start) }
        filled -= start
      }
    }
  }

  /// Whether a line starting with `head` can carry usage or session details.
  func wants(_ head: UnsafeRawBufferPointer) -> Bool {
    switch kind {
    case .claude:
      // Assistant entries name their role within the first bytes; user and tool-result lines,
      // the largest ones, are skipped without being searched.
      return !contains(head, "\"role\":\"user\"") && contains(head, "\"message\":{")
    case .codex:
      // The event type sits near the start; payload lines are not searched in full.
      let near = UnsafeRawBufferPointer(rebasing: head[0..<min(head.count, 256)])
      return contains(near, "\"token_count\"") || contains(near, "\"session_meta\"")
        || contains(near, "\"turn_context\"")
    }
  }

  /// Parses one JSONL line, cheaply skipping lines that cannot carry usage.
  mutating func consume(_ line: UnsafeRawBufferPointer) {
    let head = UnsafeRawBufferPointer(rebasing: line[0..<min(line.count, 512)])
    guard wants(head) else { return }
    autoreleasepool {
      switch kind {
      case .claude:
        if !Self.forceFullParse, cwd != nil, contains(head, "\"role\":\"assistant\""),
          let entry = ClaudeEntry(line, head: head)
        {
          record(entry)
        } else if contains(line, "\"usage\":{"), contains(line, "\"type\":\"assistant\"") {
          consumeClaude(line)
        }
      case .codex:
        consumeCodex(line)
      }
    }
  }

  private mutating func consumeClaude(_ line: UnsafeRawBufferPointer) {
    guard let object = json(line), object["type"] as? String == "assistant",
      let message = object["message"] as? [String: Any],
      let usage = message["usage"] as? [String: Any]
    else { return }
    if cwd == nil { cwd = object["cwd"] as? String }
    record(
      ClaudeEntry(
        id: message["id"] as? String, model: message["model"] as? String,
        counts: ClaudeEntry.counts(usage), timestamp: object["timestamp"] as? String))
  }
  private mutating func record(_ entry: ClaudeEntry) {
    if let m = entry.model, !m.hasPrefix("<") { model = m }  // "<synthetic>" carries no usage
    let added = entry.id != nil && entry.id == lastMessage ? entry.counts.since(lastUsage) : entry.counts
    lastMessage = entry.id
    lastUsage = entry.counts
    add(added, at: entry.timestamp)
  }
  /// Test hook: always use the full JSON parser, to check the fast path against it.
  static var forceFullParse = false

  private mutating func consumeCodex(_ line: UnsafeRawBufferPointer) {
    guard let object = json(line), let payload = object["payload"] as? [String: Any] else { return }
    switch object["type"] as? String {
    case "session_meta":
      // A fork also embeds its parent's session_meta; the first one describes this file.
      if session == nil {
        session = (payload["session_id"] as? String) ?? (payload["id"] as? String)
        cwd = payload["cwd"] as? String
      }
    case "turn_context":
      if let m = payload["model"] as? String, !m.isEmpty { model = m }
    case "event_msg":
      guard payload["type"] as? String == "token_count",
        let info = payload["info"] as? [String: Any],
        let totalUsage = info["total_token_usage"] as? [String: Any],
        let last = info["last_token_usage"] as? [String: Any]
      else { return }
      let running = Self.codexCounts(totalUsage)
      if running == lastTotal { return }
      lastTotal = running
      add(Self.codexCounts(last), at: object["timestamp"] as? String)
    default: break
    }
  }

  /// Codex (OpenAI) input_tokens includes the cached prompt; split it out like Claude does.
  /// cache_write_input_tokens has been 0 in every log observed, so it is kept as reported.
  static func codexCounts(_ u: [String: Any]) -> TokenCounts {
    let cached = int(u["cached_input_tokens"])
    return TokenCounts(
      input: max(0, int(u["input_tokens"]) - cached), output: int(u["output_tokens"]),
      cacheWrite: int(u["cache_write_input_tokens"]), cacheRead: cached)
  }

  private mutating func add(_ counts: TokenCounts, at timestamp: String?) {
    guard counts.total > 0 else { return }
    total += counts
    if let epoch = timestamp.flatMap(parseTimestamp) {
      days[localDay(epoch), default: TokenCounts()] += counts
    }
  }
  /// Drops per-day buckets older than `day`; totals are kept.
  mutating func prune(before day: Int) {
    days = days.filter { $0.key >= day }
  }
}

/// The fields of a Claude Code assistant entry that matter here.
struct ClaudeEntry {
  var id: String?
  var model: String?
  var counts: TokenCounts
  var timestamp: String?
  init(id: String?, model: String?, counts: TokenCounts, timestamp: String?) {
    (self.id, self.model, self.counts, self.timestamp) = (id, model, counts, timestamp)
  }
  static func counts(_ usage: [String: Any]) -> TokenCounts {
    TokenCounts(
      input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
      cacheWrite: int(usage["cache_creation_input_tokens"]),
      cacheRead: int(usage["cache_read_input_tokens"]))
  }
  /// Fast path that never parses message content: the message's id and model come first in
  /// its object, and its `usage` object follows the content, so only those small slices are
  /// read. Returns nil whenever the layout is not the expected one; callers then parse fully.
  init?(_ line: UnsafeRawBufferPointer, head: UnsafeRawBufferPointer) {
    guard let message = find(head, "\"message\":{"),
      let usageKey = findLast(line, "\"usage\":{"), usageKey > message,
      let usageEnd = objectEnd(line, from: usageKey + 8),
      let usage = json(UnsafeRawBufferPointer(rebasing: line[(usageKey + 8)...usageEnd])),
      usage["input_tokens"] is NSNumber, usage["output_tokens"] is NSNumber
    else { return nil }
    // The entry itself must be the assistant turn (not, say, a progress line embedding one):
    // its own type sits outside the message object, usually in the last few hundred bytes.
    guard let type = findLast(line, "\"type\":\"assistant\""), type > usageEnd || type < message
    else { return nil }
    let inMessage = UnsafeRawBufferPointer(rebasing: head[message...])
    id = stringValue(inMessage, "\"id\":\"")
    model = stringValue(inMessage, "\"model\":\"")
    counts = Self.counts(usage)
    timestamp = findLast(line, "\"timestamp\":\"").flatMap {
      stringValue(UnsafeRawBufferPointer(rebasing: line[$0...]), "\"timestamp\":\"")
    }
  }
}

private func find(_ haystack: UnsafeRawBufferPointer, _ needle: StaticString) -> Int? {
  guard let base = haystack.baseAddress, haystack.count >= needle.utf8CodeUnitCount,
    let hit = memmem(base, haystack.count, needle.utf8Start, needle.utf8CodeUnitCount)
  else { return nil }
  return haystack.startIndex + base.distance(to: UnsafeRawPointer(hit))
}
private func findLast(_ haystack: UnsafeRawBufferPointer, _ needle: StaticString) -> Int? {
  let n = needle.utf8CodeUnitCount
  guard let base = haystack.baseAddress, haystack.count >= n else { return nil }
  let first = needle.utf8Start.pointee
  var i = haystack.count - n
  while i >= 0 {
    if base.load(fromByteOffset: i, as: UInt8.self) == first, memcmp(base + i, needle.utf8Start, n) == 0 {
      return haystack.startIndex + i
    }
    i -= 1
  }
  return nil
}
/// Index of the `}` closing the object that opens at `start`, skipping braces inside strings.
private func objectEnd(_ line: UnsafeRawBufferPointer, from start: Int) -> Int? {
  guard start < line.endIndex, line[start] == UInt8(ascii: "{") else { return nil }
  var depth = 0
  var inString = false
  var escaped = false
  for i in start..<line.endIndex {
    let c = line[i]
    if inString {
      if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
    } else if c == 0x22 {
      inString = true
    } else if c == 0x7B {
      depth += 1
    } else if c == 0x7D {
      depth -= 1
      if depth == 0 { return i }
    }
  }
  return nil
}
/// The plain (escape-free) string after the first `key`, e.g. an id, model or timestamp.
private func stringValue(_ haystack: UnsafeRawBufferPointer, _ key: StaticString) -> String? {
  guard let at = find(haystack, key) else { return nil }
  let start = at + key.utf8CodeUnitCount
  var end = start
  while end < haystack.endIndex, end - start < 256 {
    let c = haystack[end]
    if c == 0x22 { return String(decoding: UnsafeRawBufferPointer(rebasing: haystack[start..<end]), as: UTF8.self) }
    if c == 0x5C { return nil }
    end += 1
  }
  return nil
}

private func json(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
  guard let base = line.baseAddress else { return nil }
  let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
private func contains(_ haystack: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
  guard let base = haystack.baseAddress, haystack.count >= needle.utf8CodeUnitCount else { return false }
  return memmem(base, haystack.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
}

/// Seconds since 1970 for "2026-10-17T01:06:15.425Z" (the UTC form both agents write).
func parseTimestamp(_ s: String) -> Double? {
  let u = Array(s.utf8)
  guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90
  else { return nil }
  func n(_ range: Range<Int>) -> Int? {
    var v = 0
    for i in range {
      guard u[i] >= 48 && u[i] <= 57 else { return nil }
      v = v * 10 + Int(u[i] - 48)
    }
    return v
  }
  guard let y = n(0..<4), let mo = n(5..<7), let d = n(8..<10), let h = n(11..<13), let mi = n(14..<16),
    let sec = n(17..<19), (1...12).contains(mo)
  else { return nil }
  // Days from civil (Howard Hinnant).
  let yy = mo <= 2 ? y - 1 : y
  let era = (yy >= 0 ? yy : yy - 399) / 400
  let yoe = yy - era * 400
  let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  let days = era * 146097 + doe - 719468
  var fraction = 0.0
  if u[19] == 46, let digits = String(bytes: u[20..<(u.count - 1)], encoding: .utf8), let f = Double("0." + digits) {
    fraction = f
  }
  return Double(days * 86400 + h * 3600 + mi * 60 + sec) + fraction
}

/// Calendar day in the given time zone as a day count, so "today" and "last 7 days" are integer
/// comparisons.
func localDay(_ epoch: Double, in zone: TimeZone = .current) -> Int {
  let local = epoch + Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: epoch)))
  return Int((local / 86400).rounded(.down))
}

/// Usage is grouped by repository: Claude Code worktrees count toward the repository they belong to.
func usageProject(_ cwd: String?) -> String? {
  guard var path = cwd, !path.isEmpty else { return nil }
  if let range = path.range(of: "/.claude/worktrees/") { path = String(path[..<range.lowerBound]) }
  return projectName(path)
}

/// 950 → "950", 12_300 → "12.3K", 4_560_000 → "4.6M", 2_100_000_000 → "2.1B".
func formatTokens(_ value: Int) -> String {
  let v = Double(value)
  switch value {
  case ..<1000: return "\(value)"
  case ..<1_000_000: return String(format: "%.1fK", v / 1e3)
  case ..<1_000_000_000: return String(format: "%.1fM", v / 1e6)
  default: return String(format: "%.2fB", v / 1e9)
  }
}
