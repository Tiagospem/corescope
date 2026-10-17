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
