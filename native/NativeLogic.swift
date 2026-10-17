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
