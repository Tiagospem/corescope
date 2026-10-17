import CoreGraphics
import Foundation

@main struct NativeTests {
  static func main() {
    let tree = descendantIDs(root: 10, nodes: [(10, 1), (11, 10), (12, 11), (13, 1), (14, 10)])
    precondition(Set(tree) == Set([10, 11, 12, 14]))
    precondition(tree.last == 10)
    precondition(descendantIDs(root: 10, nodes: [(10, 11), (11, 10)]).count == 2)
    let monitor = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let rescued = clampPanel(CGRect(x: 3000, y: -500, width: 300, height: 200), to: monitor)
    precondition(monitor.contains(rescued))
    let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    precondition(
      left.contains(clampPanel(CGRect(x: -2500, y: 1200, width: 400, height: 260), to: left)))

    // launchd children become roots; orphaned parents and cycles never hide nodes.
    let nodes: [(pid: Int32, ppid: Int32)] = [
      (1, 0), (10, 1), (11, 10), (12, 11), (13, 1), (14, 10), (20, 999), (30, 31), (31, 30),
    ]
    let forest = ProcessForest(nodes)
    precondition(Set(forest.roots).isSuperset(of: [1, 10, 13, 20]))
    let all = forest.flatten(expanded: { _ in true }, order: <)
    precondition(Set(all.map(\.pid)) == Set(nodes.map(\.pid)))
    precondition(all.first { $0.pid == 12 }?.depth == 2)
    let collapsed = forest.flatten(expanded: { $0 != 10 }, order: <)
    precondition(!collapsed.contains { $0.pid == 11 })
    precondition(collapsed.first { $0.pid == 10 }?.children == 2)
    let totals = forest.totals { Double($0) }
    precondition(totals[10] == 10 + 11 + 12 + 14)
    let parent = Dictionary(uniqueKeysWithValues: nodes.map { ($0.pid, $0.ppid) })
    precondition(forest.ancestors(of: [12], parent: parent) == [11, 10])
    let filtered = forest.flatten(visible: [12, 11, 10], expanded: { _ in true }, order: <)
    precondition(filtered.map(\.pid) == [10, 11, 12])
    precondition(formatDuration(3725) == "1 h 2 min")
    precondition(projectName("/") == nil && projectName("/tmp/app") == "app")

    // Demo mode never shows a real folder name, but keeps system paths readable.
    let fakes = ["acme-api", "web-dashboard", "mobile-app"]
    func demo(_ path: String, executable: Bool = false) -> String {
      demoPath(path, home: "/Users/me", projects: fakes, executable: executable)
    }
    let work = demo("/Users/me/code/client-x")
    precondition(work.hasPrefix("/Users/dev/code/") && !work.contains("client-x"))
    precondition(fakes.contains(projectName(work, home: demoHome) ?? ""))
    precondition(demo("/Users/me/other/client-x") == work && demo("/Volumes/Work/client-x") == work)
    let binary = demo("/Users/me/code/client-x/target/debug/server", executable: true)
    precondition(binary.hasPrefix("/Users/dev/code/") && binary.hasSuffix("/server") && !binary.contains("client-x"))
    let derived = demo("/Users/me/Library/Developer/Xcode/DerivedData/ClientX-abc")
    precondition(!derived.contains("ClientX") && projectName(derived, home: demoHome) == nil)
    precondition(demo("/Users/me") == demoHome && projectName(demoHome, home: demoHome) == nil)
    for system in ["/", "/usr/bin/python3", "/Applications/Xcode.app/Contents/MacOS/Xcode", "/private/tmp/x"] {
      precondition(demo(system, executable: true) == system)
    }
    precondition(demo("") == "")
    print(
      "16 native assertions passed: descendants, cycle, ordering, off-screen recovery, negative-origin monitor, forest roots, flatten, collapse, totals, ancestors, filter, formatting, demo paths"
    )
  }
}
