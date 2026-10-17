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
    tokenTests()
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

    // Demo mode never shows a real folder name, but keeps system paths readable.
    let fakes = ["acme-api", "web-dashboard", "mobile-app"]
    func demo(_ path: String, executable: Bool = false) -> String {
      demoPath(path, home: "/Users/me", projects: fakes, executable: executable)
    }
    let work = demo("/Users/me/code/client-x")
    precondition(work.hasPrefix("/Users/dev/code/") && !work.contains("client-x"))
    precondition(fakes.contains(projectName(work, home: demoHome) ?? ""))
    precondition(demo("/Users/me/other/client-x") == work && demo("/Volumes/Work/client-x") == work)
    precondition(demo("/System/Volumes/Data/Users/me/code/client-x") == work)
    let binary = demo("/Users/me/code/client-x/target/debug/server", executable: true)
    precondition(binary.hasPrefix("/Users/dev/code/") && binary.hasSuffix("/server") && !binary.contains("client-x"))
    let derived = demo("/Users/me/Library/Developer/Xcode/DerivedData/ClientX-abc")
    precondition(!derived.contains("ClientX") && projectName(derived, home: demoHome) == nil)
    precondition(demo("/Users/me") == demoHome && projectName(demoHome, home: demoHome) == nil)
    for system in ["/", "/usr/bin/python3", "/Applications/Xcode.app/Contents/MacOS/Xcode", "/private/tmp/x"] {
      precondition(demo(system, executable: true) == system)
    }
    precondition(demo("") == "")

    // Notifications: one per identity per hour, sustained thresholds, no replay at launch.
    var debounce = NotificationDebounce()
    precondition(debounce.allow("42:1", at: 0) && !debounce.allow("42:1", at: 3599))
    precondition(debounce.allow("42:2", at: 10) && debounce.allow("42:1", at: 3600))
    var sustain = SustainTracker()
    precondition(sustain.update(above: ["a"], at: 0, duration: 60).isEmpty)
    precondition(sustain.update(above: ["a", "b"], at: 60, duration: 60) == ["a"])
    precondition(sustain.update(above: ["b"], at: 90, duration: 60).isEmpty)
    precondition(sustain.update(above: ["a", "b"], at: 120, duration: 60) == ["b"])
    var arrivals = NewArrivals()
    precondition(arrivals.update(["x"]).isEmpty && arrivals.update(["x", "y"]) == ["y"])
    precondition(arrivals.update(["y"]).isEmpty)
    precondition(parsePort("3000") == 3000 && parsePort(":8080") == 8080)
    precondition(parsePort("0") == nil && parsePort("70000") == nil && parsePort("abc") == nil)
    precondition(
      shortcutLabel(modifiers: HotkeyModifier.command | HotkeyModifier.option, key: "k") == "⌥⌘K")
    // Stalls: quiet transcript + what the turn's own commands are doing.
    let busy = 1000.0
    precondition(agentStall(busySince: nil, lastWrite: nil, children: [], now: 9999, threshold: 600) == nil)
    precondition(agentStall(busySince: busy, lastWrite: 1500, children: [], now: 2000, threshold: 600) == nil)
    precondition(agentStall(busySince: busy, lastWrite: 1100, children: [], now: 2000, threshold: 600) == .silent(since: 1100))
    let server = TurnChild(name: "vite", cpu: 0, start: 1050, listening: true)
    let mcp = TurnChild(name: "node", cpu: 90, start: 10, listening: false)
    precondition(
      agentStall(busySince: busy, lastWrite: nil, children: [server, mcp], now: 2000, threshold: 600) == .silent(since: busy))
    let tests = TurnChild(name: "cargo", cpu: 180, start: 1200, listening: false)
    let prompt = TurnChild(name: "npm", cpu: 0, start: 1300, listening: false)
    precondition(
      agentStall(busySince: busy, lastWrite: 1100, children: [tests, prompt], now: 2000, threshold: 600)
        == .longCommand("cargo", since: 1100))
    let stuck = agentStall(busySince: busy, lastWrite: 1100, children: [prompt], now: 2000, threshold: 600)
    precondition(stuck == .waiting("npm", since: 1100) && stuck?.suspicious == true)
    precondition(claudeProjectFolder("/Volumes/HD Externo/a_b/.claude") == "-Volumes-HD-Externo-a-b--claude")
    precondition(HealthTarget("3000") == .tcp(host: "localhost", port: 3000))
    precondition(HealthTarget(":5432") == .tcp(host: "localhost", port: 5432))
    precondition(HealthTarget("db.local:6379") == .tcp(host: "db.local", port: 6379))
    precondition(HealthTarget("localhost:3000/health") == .http(URL(string: "http://localhost:3000/health")!))
    precondition(HealthTarget("https://staging.app/up")?.isLocal == false)
    precondition(HealthTarget("http://api.localhost:8080")?.isLocal == true)
    precondition(HealthTarget("nonsense") == nil && HealthTarget("host:99999") == nil && HealthTarget("http://") == nil)
    precondition(HealthLevel(httpStatus: 204) == .up && HealthLevel(httpStatus: 404) == .warn && HealthLevel(httpStatus: 503) == .down)
    // Shared containers survive until the last active profile using them stops.
    let plan = planContainerStop(
      ["mysql", "redis", "mailpit", "stopped"], running: ["mysql", "redis", "mailpit"],
      startedByProfiles: ["mysql", "redis"], otherActive: [(name: "Shop", containers: ["mysql"])])
    precondition(plan == ContainerStopPlan(stop: ["redis"], shared: ["mysql": "Shop"], external: ["mailpit"]))
    precondition(
      planContainerStop(["mysql"], running: ["mysql"], startedByProfiles: ["mysql"], otherActive: []).stop == ["mysql"])
    print(
      "25 native assertions passed: descendants, cycle, ordering, off-screen recovery, negative-origin monitor, forest roots, flatten, collapse, totals, ancestors, filter, formatting, container ports, shared ports, demo paths, debounce, sustained thresholds, new arrivals, port parsing, shortcut label, agent stalls, health targets, shared containers; plus settings JSON, Unicode escapes, status line install/chain, Claude limits"
    )
    print(
      "token usage assertions passed: timestamps, formatting, Claude block dedupe, embedded entries, partial lines, long-line skip, fast/full parity, Codex repeats and forks"
    )
  }
}

func tokenTests() {
  precondition(parseTimestamp("2026-10-17T01:06:15.425Z") == 1_792_199_175.425)
  precondition(parseTimestamp("2026-10-17 01:06:15Z") == nil)
  let utc = TimeZone(identifier: "UTC")!
  precondition(localDay(1_792_199_175, in: utc) == 20743)
  precondition(localDay(1_792_199_175, in: TimeZone(identifier: "America/Sao_Paulo")!) == 20742)
  precondition(formatTokens(950) == "950" && formatTokens(12_300) == "12.3K")
  precondition(formatTokens(4_560_000) == "4.6M" && formatTokens(2_100_000_000) == "2.10B")
  precondition(usageProject("/tmp/app/.claude/worktrees/x-1") == "app")

  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("corescope-tokens-\(getpid())")
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  func write(_ name: String, _ text: String) -> (URL, UInt64) {
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
    return (url, UInt64(text.utf8.count))
  }
  func assistant(_ id: String, _ out: Int, ts: String = "2026-10-16T12:00:00.000Z", text: String = "hi") -> String {
    #"{"parentUuid":null,"isSidechain":false,"message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":\#(out),"iterations":[{"input_tokens":10,"output_tokens":\#(out)}]}},"type":"assistant","uuid":"u","timestamp":"\#(ts)","cwd":"/tmp/demo","sessionId":"s"}"#
  }
  // Same message twice (output grows), a user line, a progress line embedding a usage object,
  // and a long assistant line, then a partial line still being written.
  let user = #"{"parentUuid":"u","isSidechain":false,"message":{"role":"user","content":"x \"usage\":{"},"type":"user","timestamp":"2026-10-16T12:00:01.000Z"}"#
  let progress = #"{"parentUuid":"u","type":"progress","data":{"message":{"type":"assistant","message":{"role":"assistant","id":"m9","usage":{"input_tokens":5,"output_tokens":5}}}},"timestamp":"2026-10-16T12:00:02.000Z"}"#
  let long = assistant("m2", 7, ts: "2026-10-15T12:00:00.000Z", text: String(repeating: "y", count: 5000))
  let body = [assistant("m1", 5), assistant("m1", 50), user, progress, long].joined(separator: "\n") + "\n"
  let partial = assistant("m3", 1)
  var (url, size) = write("abc.jsonl", body + String(partial.prefix(40)))
  for full in [false, true] {
    TranscriptTally.forceFullParse = full
    var tally = TranscriptTally(kind: .claude, path: url.path)
    tally.read(url, size: size, chunk: 256)
    precondition(tally.session == "abc" && tally.cwd == "/tmp/demo" && tally.model == "claude-opus-5-5")
    precondition(tally.total == TokenCounts(input: 20, output: 57, cacheWrite: 200, cacheRead: 2000))
    precondition(tally.offset == UInt64(body.utf8.count))
    let day = localDay(parseTimestamp("2026-10-16T12:00:00.000Z")!)
    precondition(tally.days[day]?.output == 50 && tally.days[day - 1]?.output == 7)
    // The rest of the partial line arrives; it is counted once, from where reading stopped.
    let rest = write("abc.jsonl", body + partial + "\n")
    tally.read(rest.0, size: rest.1, chunk: 256)
    precondition(tally.total.output == 58 && tally.total.input == 30)
    tally.read(rest.0, size: rest.1)
    precondition(tally.total.output == 58)
    tally.prune(before: day)
    precondition(tally.days[day - 1] == nil && tally.total.output == 58)
    (url, size) = write("abc.jsonl", body + String(partial.prefix(40)))
  }
  TranscriptTally.forceFullParse = false
  let lateMessage =
    #"{"parentUuid":null,"cwd":"\#(String(repeating: "x", count: 600))","message":{"model":"claude-opus-5-5","id":"late","type":"message","role":"assistant","usage":{"input_tokens":11,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}},"type":"assistant","timestamp":"2026-10-16T12:00:00.000Z"}"#
  let (lateURL, lateSize) = write("late.jsonl", assistant("first", 1) + "\n" + lateMessage + "\n")
  for full in [false, true] {
    TranscriptTally.forceFullParse = full
    var lateTally = TranscriptTally(kind: .claude, path: lateURL.path)
    lateTally.read(lateURL, size: lateSize, chunk: 256)
    precondition(lateTally.total == TokenCounts(input: 21, output: 4, cacheWrite: 100, cacheRead: 1000))
  }
  TranscriptTally.forceFullParse = false
  let sub = dir.appendingPathComponent("abc/subagents")
  try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
  let subagent = TranscriptTally(kind: .claude, path: sub.appendingPathComponent("agent-1.jsonl").path)
  precondition(subagent.session == "abc" && subagent.isSubagent)

  // Codex: a fork embeds its parent's session_meta second; repeated totals add nothing; a huge
  // `compacted` line is skipped without being buffered.
  func count(_ total: Int, _ input: Int, _ cached: Int, _ output: Int) -> String {
    #"{"timestamp":"2026-10-16T13:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":0},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output)}}}}"#
  }
  let codex = [
    #"{"timestamp":"2026-10-16T13:00:00.000Z","type":"session_meta","payload":{"id":"fork","session_id":"root","cwd":"/tmp/demo"}}"#,
    #"{"timestamp":"2026-10-16T13:00:00.000Z","type":"session_meta","payload":{"id":"root","cwd":"/elsewhere"}}"#,
    #"{"timestamp":"2026-10-16T13:00:00.000Z","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#,
    #"{"timestamp":"2026-10-16T13:00:00.000Z","type":"compacted","payload":{"message":"\#(String(repeating: "z", count: 3000))"}}"#,
    count(100, 100, 60, 7), count(100, 100, 60, 7), count(250, 150, 100, 9),
  ].joined(separator: "\n") + "\n"
  let (codexURL, codexSize) = write("rollout.jsonl", codex)
  var c = TranscriptTally(kind: .codex, path: codexURL.path)
  c.read(codexURL, size: codexSize, chunk: 1024, maxLine: 2048)
  precondition(c.session == "root" && c.cwd == "/tmp/demo" && c.model == "gpt-6.1-sol")
  precondition(c.total == TokenCounts(input: 90, output: 16, cacheWrite: 0, cacheRead: 160))
  precondition(c.offset == codexSize)

  let shared = [count(100, 100, 60, 7), count(250, 150, 100, 9)]
  let parentLog = [
    #"{"type":"session_meta","payload":{"id":"root","cwd":"/tmp/demo"}}"#,
  ] + shared
  let forkLog = [
    #"{"type":"session_meta","payload":{"id":"fork","session_id":"root","cwd":"/tmp/demo"}}"#,
  ] + shared + [count(300, 50, 20, 4)]
  let (parentURL, parentSize) = write("parent.jsonl", parentLog.joined(separator: "\n") + "\n")
  let (forkURL, forkSize) = write("fork.jsonl", forkLog.joined(separator: "\n") + "\n")
  var parent = TranscriptTally(kind: .codex, path: parentURL.path)
  var fork = TranscriptTally(kind: .codex, path: forkURL.path)
  parent.read(parentURL, size: parentSize)
  fork.read(forkURL, size: forkSize)
  precondition(parent.session == fork.session)
  var deduper = CodexEventDeduper()
  var combined = TokenCounts()
  for (tally, session) in [(parent, parent.session), (fork, fork.session)] {
    for event in tally.codexEvents where deduper.insert(event, session: session) {
      combined += event.counts
    }
  }
  precondition(combined == TokenCounts(input: 120, output: 20, cacheWrite: 0, cacheRead: 180))
}
