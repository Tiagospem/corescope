import Foundation

/// `CORESCOPE_DEMO=1` keeps live metrics but anonymizes users, paths, project names and agent
/// session titles, so screenshots can be shared without exposing private work.
enum Demo {
  static let enabled = ProcessInfo.processInfo.environment["CORESCOPE_DEMO"] != nil
  private static let home = NSHomeDirectory()
  private static let user = NSUserName()
  private static let projects = [
    "acme-api", "web-dashboard", "mobile-app", "billing-service", "docs-site", "data-pipeline",
    "auth-gateway", "design-system",
  ]
  private static let titles = [
    "Refactor auth middleware", "Fix flaky e2e tests", "Add dark mode to the dashboard",
    "Migrate API to Postgres 17", "Investigate memory leak in worker", "Ship onboarding flow",
  ]
  private static func pick(_ list: [String], _ key: String) -> String {
    list[Int(key.utf8.reduce(UInt32(7)) { $0 &* 31 &+ UInt32($1) } % UInt32(list.count))]
  }
  static func sessionTitle(_ pid: Int32) -> String { pick(titles, String(pid)) }
  /// Home becomes /Users/dev; work folders elsewhere become ~/code/<fake project>.
  static func path(_ value: String) -> String {
    guard !value.isEmpty else { return value }
    var out = value.replacingOccurrences(of: home, with: "/Users/dev")
    if out.hasPrefix("/Volumes/") {
      let name = (out as NSString).lastPathComponent
      out = "/Users/dev/code/" + pick(projects, name)
    }
    return out.replacingOccurrences(of: user, with: "dev")
  }
  static func scrub(_ snapshot: Snapshot) -> Snapshot {
    var s = snapshot
    for i in s.processes.indices {
      s.processes[i].user = s.processes[i].user == user ? "dev" : s.processes[i].user
      s.processes[i].path = path(s.processes[i].path)
      s.processes[i].cwd = path(s.processes[i].cwd)
      s.processes[i].orphan_parent = nil
    }
    return s
  }
}
