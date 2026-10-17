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
    // VM helper ports split among the containers that published them.
    let split = splitPorts([6379, 3306, 8025, 1025, 5555]) {
      [6379: "redis", 3306: "mysql", 8025: "mail", 1025: "mail"][$0]
    }
    precondition(split.owned.map(\.owner) == ["redis", "mysql", "mail"])
    precondition(split.owned.last?.ports == [8025, 1025] && split.rest == [5555])
    precondition(splitPorts([80]) { _ in nil }.owned.isEmpty)
    // A port two containers publish stays unattributed; repeats of one owner do not count.
    let owners = uniqueOwners([(8080, "a"), (8080, "b"), (5432, "db"), (5432, "db"), (6379, "r")])
    precondition(owners == [5432: "db", 6379: "r"])
    // Claude status line: settings.json edits keep key order, numbers and escapes untouched.
    let settingsText = """
      {
        "theme": "dark",
        "env": {
          "A": "x \\"q\\" \\u00e9 /",
          "n": 1.50
        },
        "hooks": [],
        "list": [
          true,
          null,
          -2e3
        ]
      }
      """
    let settings = try! OrderedJSON.parse(settingsText)
    precondition(settings.serialized() == settingsText.replacingOccurrences(of: "\\u00e9", with: "é"))
    precondition((try? OrderedJSON.parse("{\"a\":1,}")) == nil && (try? OrderedJSON.parse("[01]")) == nil)
    precondition(try! OrderedJSON.parse(#""\uD83D\uDE00""#).stringValue == "😀")
    for malformed in [#""\uD800\u0041""#, #""\uD800x""#, #""\uD800""#, #""\uDC00""#] {
      precondition((try? OrderedJSON.parse(malformed)) == nil)
    }
    let script = "/Users/me/Library/Application Support/CoreScope/claude-statusline.sh"
    precondition(ClaudeStatusLine.link(of: settings, script: script) == .absent)
    let fresh = ClaudeStatusLine.installing(over: nil, script: script, chain: false)!
    let installed = settings.setting("statusLine", fresh)
    precondition(ClaudeStatusLine.link(of: installed, script: script) == .installed)
    guard case .object(let members) = installed else { preconditionFailure() }
    precondition(members.map(\.key) == ["theme", "env", "hooks", "list", "statusLine"])
    precondition(installed.setting("statusLine", nil) == settings)
    let own = OrderedJSON.object([
      .init(key: "type", value: .string("command")), .init(key: "command", value: .string("echo hi # x")),
      .init(key: "padding", value: .number("0")),
    ])
    precondition(ClaudeStatusLine.installing(over: own, script: script, chain: false) == nil)
    let chained = ClaudeStatusLine.installing(over: own, script: script, chain: true)!
    precondition(chained["padding"] == .number("0"))
    precondition(
      chained["command"]?.stringValue == "'\(script)' --record | (\necho hi # x\n)")
    precondition(
      ClaudeStatusLine.link(of: settings.setting("statusLine", chained), script: script) == .chained)
    precondition(ClaudeStatusLine.shellQuote("it's") == "'it'\\''s'")
    let limits = Data(
      #"{"five_hour":{"used_percentage":23.5,"resets_at":2000000000},"seven_day":{"used_percentage":41.200000000000003,"resets_at":1000}}"#
        .utf8)
    let samples = parseClaudeLimits(limits, now: Date(timeIntervalSince1970: 1_500_000_000))
    precondition(samples.map(\.id) == ["five_hour"] && samples[0].usedPercent == 23.5)
    precondition(samples[0].windowMinutes == 300)
    precondition(parseClaudeLimits(limits, now: .distantPast).count == 2)
    precondition(parseClaudeLimits(Data("nope".utf8)).isEmpty)
    print(
      "Native assertions passed: descendants, cycle, ordering, off-screen recovery, negative-origin monitor, forest roots, flatten, collapse, totals, ancestors, filter, formatting, container ports, shared ports, settings JSON, Unicode escapes, status line install/chain, Claude limits"
    )
  }
}
