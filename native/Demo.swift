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
  static func sessionTitle(_ pid: Int32) -> String { demoPick(titles, String(pid)) }
  /// System paths stay readable; home and other folders become /Users/dev/code/<fake project>.
  static func path(_ value: String, executable: Bool = false) -> String {
    demoPath(value, home: home, projects: projects, executable: executable)
      .replacingOccurrences(of: user, with: "dev")
  }
  /// Compose projects get a fake name; container and image names that embed it follow it.
  static func container(_ c: ContainerItem) -> ContainerItem {
    var c = c
    if let project = c.project {
      let fake = demoPick(projects, project)
      c.name = c.name.replacingOccurrences(of: project, with: fake)
      // Compose names built images <project>-<service>; registry names stay as they are.
      c.image = c.image.replacingOccurrences(of: project, with: fake)
      c.project = fake
    }
    return c
  }
  static func scrub(_ snapshot: Snapshot) -> Snapshot {
    var s = snapshot
    for i in s.processes.indices {
      s.processes[i].user = s.processes[i].user == user ? "dev" : s.processes[i].user
      s.processes[i].signalPath = s.processes[i].path
      s.processes[i].path = path(s.processes[i].path, executable: true)
      s.processes[i].cwd = path(s.processes[i].cwd)
      s.processes[i].orphan_parent = nil
    }
    return s
  }
}
