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
    updateTests()
    failedUnitTests()
    volumeTests()
    auditTests()
    pruneTests()
    environmentTests()
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
    // Claude Code's /usage text (claude -p /usage): session and all-models week only.
    let spZone = TimeZone(identifier: "America/Sao_Paulo")!
    var spCal = Calendar(identifier: .gregorian)
    spCal.timeZone = spZone
    func sp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
      spCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    let usageNow = sp(2026, 10, 18, 20, 45)
    let usageText = """
      You are currently using your subscription to power your Claude Code usage

      Current session: 10% used · resets Oct 18 at 10:59pm (America/Sao_Paulo)
      Current week (all models): 85% used · resets Oct 20 at 4am (America/Sao_Paulo)
      Current week (Fable): 0% used · resets Oct 20 at 4am (America/Sao_Paulo)
      """
    let usage = parseClaudeUsageText(usageText, now: usageNow)
    precondition(usage == [
      ClaudeLimitSample(id: "five_hour", usedPercent: 10, windowMinutes: 300, resetsAt: sp(2026, 10, 18, 22, 59)),
      ClaudeLimitSample(id: "seven_day", usedPercent: 85, windowMinutes: 10080, resetsAt: sp(2026, 10, 20, 4, 0)),
    ], "\(usage)")
    let bareTime = parseClaudeUsageText("Current session: 3% used · resets 11pm (America/Sao_Paulo)", now: usageNow)
    precondition(bareTime.first?.resetsAt == sp(2026, 10, 18, 23, 0), "bare time: later today")
    let early = parseClaudeUsageText("Current session: 3% used · resets 8:15pm (America/Sao_Paulo)", now: usageNow)
    precondition(early.first?.resetsAt == sp(2026, 10, 19, 20, 15), "bare time already past: tomorrow")
    let rollover = parseClaudeUsageText("Current week (all models): 12.5% used · resets Jan 2 at 12am (America/Sao_Paulo)", now: sp(2026, 12, 30, 9, 0))
    precondition(rollover.first?.resetsAt == sp(2027, 1, 2, 0, 0) && rollover.first?.usedPercent == 12.5, "next year")
    precondition(parseClaudeUsageText("Current week (all models): 40% used", now: usageNow).first?.resetsAt == nil)
    precondition(parseClaudeUsageText("Total cost: $0.0000\nUsage: 0 input, 0 output", now: usageNow).isEmpty, "API key: no plan limits")

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
    // Services: a project's app that is simply off is "not running", not a failure.
    precondition(HealthTarget("https://topo_tenant.test/up")?.localPort == 443)
    precondition(HealthTarget("http://127.0.0.1:9091/healthz")?.localPort == 9091)
    precondition(HealthTarget("http://localhost/up")?.localPort == 80 && HealthTarget("3306")?.localPort == 3306)
    precondition(HealthTarget("https://staging.app/up")?.localPort == nil && HealthTarget("db.local:5432")?.localPort == nil)
    let off = serviceState(level: .down, paused: false, fromProject: true, hasProfile: true, profileRunning: false, listening: false)
    precondition(off == .notRunning && !off.isFailure && !off.recordsHistory && off.mcpStatus == "not_running")
    // With a profile, a stopped app is not probed, and an older "up" does not keep it alive.
    precondition(serviceState(level: .up, paused: false, fromProject: true, hasProfile: true, profileRunning: false, listening: false) == .notRunning)
    precondition(!shouldProbe(paused: false, fromProject: true, hasProfile: true, profileRunning: false, listening: false))
    precondition(shouldProbe(paused: false, fromProject: true, hasProfile: true, profileRunning: true, listening: false))
    precondition(shouldProbe(paused: false, fromProject: true, hasProfile: true, profileRunning: false, listening: true))
    precondition(shouldProbe(paused: false, fromProject: true, hasProfile: false, profileRunning: false, listening: false))
    precondition(shouldProbe(paused: false, fromProject: false, hasProfile: false, profileRunning: false, listening: false))
    precondition(!shouldProbe(paused: true, fromProject: false, hasProfile: false, profileRunning: true, listening: true))
    // Without a profile it is still probed: gray when it fails with the port free, up when it answers.
    precondition(serviceState(level: .down, paused: false, fromProject: true, hasProfile: false, profileRunning: false, listening: false) == .notRunning)
    precondition(serviceState(level: .up, paused: false, fromProject: true, hasProfile: false, profileRunning: false, listening: false) == .up)
    // Should be up: profile running, port listening but failing, hand-added, or a remote host.
    precondition(serviceState(level: .down, paused: false, fromProject: true, hasProfile: true, profileRunning: true, listening: false) == .down)
    precondition(serviceState(level: .down, paused: false, fromProject: true, hasProfile: true, profileRunning: false, listening: true) == .down)
    precondition(serviceState(level: .down, paused: false, fromProject: false, hasProfile: false, profileRunning: false, listening: false) == .down)
    precondition(serviceState(level: .down, paused: false, fromProject: true, hasProfile: true, profileRunning: false, listening: nil) == .down)
    precondition(serviceState(level: .warn, paused: false, fromProject: false, hasProfile: false, profileRunning: false, listening: true) == .warn)
    precondition(serviceState(level: .down, paused: true, fromProject: false, hasProfile: false, profileRunning: true, listening: true) == .paused)
    precondition(serviceState(level: nil, paused: false, fromProject: false, hasProfile: false, profileRunning: false, listening: nil) == .pending)
    precondition(ServiceState.down.recordsHistory && ServiceState.up.recordsHistory && !ServiceState.paused.recordsHistory)
    precondition(ServiceState.warn.mcpStatus == "answered_with_error" && ServiceState.pending.mcpStatus == "not_checked_yet")
    let summary = serviceSummary([.up, .notRunning, .up, .down, .up])
    precondition(summary.map(\.state) == [.down, .notRunning, .up] && summary.map(\.count) == [1, 1, 3])
    precondition(serviceSummary([]).isEmpty)
    // Shared containers survive until the last active profile using them stops.
    let plan = planContainerStop(
      ["mysql", "redis", "mailpit", "stopped"], running: ["mysql", "redis", "mailpit"],
      startedByProfiles: ["mysql", "redis"], otherActive: [(name: "Shop", containers: ["mysql"])])
    precondition(plan == ContainerStopPlan(stop: ["redis"], shared: ["mysql": "Shop"], external: ["mailpit"]))
    precondition(
      planContainerStop(["mysql"], running: ["mysql"], startedByProfiles: ["mysql"], otherActive: []).stop == ["mysql"])
    let remote = RemoteStats(parsing: "os=Linux\nhost=web-1\nload=0.50 0.40 0.30\ncpus=4\nuptime=3600\nmemtotal=8000\nmemavail=2000\ndisktotal=100\ndiskused=40\ncontainers=3\nproc=12.5|3.1|/usr/sbin/mysqld\nnoise\n")
    precondition(remote.valid && remote.load == [0.5, 0.4, 0.3] && remote.cpus == 4 && remote.containers == 3)
    precondition(remote.processes.first?.name == "mysqld" && remote.memoryAvailable == 2000)
    precondition(!RemoteStats(parsing: "garbage").valid)
    precondition(validSSHDestination("deploy@web-1.example.com") && validSSHDestination("forge-redis"))
    precondition(!validSSHDestination("-oProxyCommand=x") && !validSSHDestination("a b") && !validSSHDestination("a;rm"))
    precondition(sshConfigHosts("Host *\n  User x\nHost web db-1 !bad\nhost web\n") == ["web", "db-1"])
    // The gate hook sits next to the user's own hooks and leaves them as they were.
    let userHooks = try! OrderedJSON.parse(#"{"model":"x","hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"lint"}]}],"Stop":[]}}"#)
    let withGate = AgentHook.gate.installing(into: userHooks, binary: "/Apps/Core Scope.app/bin/corescope")
    precondition(AgentHook.gate.installed(in: withGate) && !AgentHook.gate.installed(in: userHooks))
    precondition(withGate.serialized().contains("'/Apps/Core Scope.app/bin/corescope' gate"))
    let twice = AgentHook.gate.installing(into: withGate, binary: "/new/corescope")
    precondition(twice.serialized().components(separatedBy: " gate").count == 2, "one entry after reinstalling")
    precondition(AgentHook.gate.removing(from: twice) == userHooks)
    let bare = try! OrderedJSON.parse(#"{"model":"x"}"#)
    precondition(AgentHook.gate.removing(from: AgentHook.gate.installing(into: bare, binary: "/c/corescope")) == bare)
    // Both hooks side by side (Codex form, with a status message); each removes only itself.
    let both = AgentHook.context.installing(into: AgentHook.gate.installing(into: .object([]), binary: "/c/corescope", statusMessage: "s"), binary: "/c/corescope", statusMessage: "c")
    precondition(AgentHook.context.installed(in: both) && AgentHook.gate.installed(in: both) && !AgentHook.context.installed(in: withGate))
    if case .array(let starts)? = both["hooks"]?["SessionStart"], let first = starts.first {
      precondition(first["matcher"] == nil, "no matcher: every session start")
      precondition(both.serialized().contains(#""command": "'/c/corescope' context --hook""#) && both.serialized().contains(#""statusMessage": "c""#))
    } else {
      preconditionFailure("SessionStart group missing")
    }
    precondition(AgentHook.gate.removing(from: AgentHook.context.removing(from: both)) == .object([]))
    precondition(AgentHook.gate.installed(in: AgentHook.context.removing(from: both)))
    let before = RemoteStats(parsing: "os=Linux\ncpus=2\nload=4.0 3 2\ncontainer=web|running|Up 2 hours\ncontainer=db|running|Up 2 hours (unhealthy)\n")
    let now = RemoteStats(parsing: "os=Linux\ncpus=2\nload=3.5 3 2\ndisk=/|100000000000|95000000000\ndisk=/data|100000000000|50000000000\nfailed=nginx.service\ncontainer=web|exited|Exited (1) 1 minute ago\ncontainer=db|running|Up 2 hours (unhealthy)\nosname=Ubuntu 24.04 LTS\nmproc=1.0|40.5|/usr/sbin/mysqld\n")
    precondition(now.osName == "Ubuntu 24.04 LTS" && now.memoryProcesses.first?.name == "mysqld" && now.disks.count == 2)
    precondition(machineAlerts(now, before: before) == [
      .disk(mount: "/", percent: 95), .load(3.5, cores: 2), .failedUnits(["nginx.service"]),
      .containerStopped("web", status: "Exited (1) 1 minute ago"), .containerUnhealthy("db"),
    ])
    precondition(machineAlerts(now, before: nil).contains(.load(3.5, cores: 2)) == false, "load must be sustained")
    // Floating panel: compact machine readings, shared probe cadence, chosen hosts.
    let panelRemote = RemoteStats(parsing: "cpus=4\nload=2.0 1 1\nmemtotal=1000\nmemavail=250\ndisktotal=200\ndiskused=50\n")
    precondition(panelRemote.loadFraction == 0.5 && panelRemote.memoryFraction == 0.75 && panelRemote.diskFraction == 0.25)
    precondition(RemoteStats().loadFraction == nil && RemoteStats().memoryFraction == nil)
    precondition(machineProbeDue(lastProbe: nil, now: 100) && !machineProbeDue(lastProbe: 100, now: 130))
    precondition(machineProbeDue(lastProbe: 100, now: 152), "a timer firing a little early still probes")
    precondition(panelMachineHosts(selected: ["db", "gone", "web"], hosts: ["web", "cache", "db"]) == ["web", "db"])
    precondition(agentPanelState(status: "busy", stall: nil) == .busy && agentPanelState(status: "idle", stall: nil) == .waiting)
    precondition(agentPanelState(status: nil, stall: nil) == .unknown)
    precondition(agentPanelState(status: "busy", stall: .silent(since: 0)) == .stuck)
    precondition(agentPanelState(status: "busy", stall: .longCommand("cargo", since: 0)) == .longCommand)
    precondition([AgentPanelState.waiting, .stuck, .busy].sorted() == [.stuck, .busy, .waiting])
    // Services history: 5-minute buckets, uptime windows and merged incidents.
    var buckets: [Int: HealthBucket] = [:]
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    for i in 0..<12 { HealthHistory.record(&buckets, at: t0.addingTimeInterval(Double(i) * 300), up: i < 8, latency: i < 8 ? 10 : nil) }
    let end = t0.addingTimeInterval(12 * 300)
    precondition(abs((HealthHistory.uptime(buckets, now: end, seconds: 86400) ?? 0) - 8.0 / 12.0) < 0.001)
    let incidents = HealthHistory.incidents(buckets)
    precondition(incidents.count == 1 && incidents[0].end.timeIntervalSince(incidents[0].start) == 4 * 300)
    HealthHistory.record(&buckets, at: t0.addingTimeInterval(8 * 86400), up: true, latency: 5)
    precondition(buckets.count == 1, "older than a week is dropped")
    // Own cost: average share of a core from a cumulative counter, weights, helper detection.
    let cpuSamples: [(at: Double, seconds: Double)] = [(0, 1.0), (100, 1.5), (400, 2.5), (700, 4.0)]
    precondition(abs((averageCPUShare(cpuSamples, window: 300) ?? 0) - 0.5) < 0.0001, "last 5 minutes only")
    precondition(averageCPUShare([(0, 1.0)], window: 300) == nil && averageCPUShare([(0, 2.0), (60, 1.0)], window: 300) == nil)
    precondition(CostWeight(percent: 0.05) == .low && CostWeight(percent: 0.5) == .medium && CostWeight(percent: 3) == .high)
    precondition(isCoreScopeHelper(path: "/Applications/CoreScope.app/Contents/Resources/bin/corescope"))
    precondition(!isCoreScopeHelper(path: "/usr/local/bin/corescope"))
    // Settings backup: which keys, fresh domains, rotation.
    let domain: [String: Any] = ["interval": 3.0, "envProfiles": Data(), "envLaunched": Data(), "NSWindow Frame main": "x",
                                 "SUHasLaunchedBefore": true, "panel.frame.1": "r", "sshHosts": ["a"]]
    precondition(Set(SettingsBackupLogic.settings(domain).keys) == ["interval", "envProfiles", "sshHosts"])
    precondition(SettingsBackupLogic.isFresh(["NSOSPLastRootDirectory": Data(), "SUHasLaunchedBefore": true]))
    precondition(SettingsBackupLogic.isFresh(nil) && !SettingsBackupLogic.isFresh(domain))
    let names = (1...23).map { String(format: "settings-2026-10-%02d-120000.plist", $0) } + ["latest.plist", "notes.txt"]
    let gone = SettingsBackupLogic.expired(names.shuffled(), keep: 20)
    precondition(gone == ["settings-2026-10-01-120000.plist", "settings-2026-10-02-120000.plist", "settings-2026-10-03-120000.plist"])
    // Claude limits: epoch leak guard, Claude Desktop samples, pace.
    let leaked = #"{"five_hour":{"used_percentage":1792300000,"resets_at":1792300000},"seven_day":{"used_percentage":40,"resets_at":4102444800}}"#
    precondition(parseClaudeLimits(Data(leaked.utf8), now: Date(timeIntervalSince1970: 1_792_000_000)).map(\.id) == ["seven_day"])
    let nowT = Date(timeIntervalSince1970: 1_800_000_000)
    let desktop = #"{"version":2,"samples":[{"t":1799990000000,"org":"o","u":{"fh":9,"sd":50}},{"t":1799999000000,"org":"o","u":{"fh":2,"sd":79}}]}"#
    precondition(parseDesktopUsage(Data(desktop.utf8), now: nowT) == DesktopUsage(fiveHour: 2, sevenDay: 79, at: Date(timeIntervalSince1970: 1_799_999_000)))
    let old = #"{"samples":[{"t":1799900000000,"u":{"fh":30,"sd":60}}]}"#
    precondition(parseDesktopUsage(Data(old.utf8), now: nowT)?.fiveHour == nil, "older than 5 h: no 5-hour figure")
    precondition(parseDesktopUsage(Data(old.utf8), now: nowT)?.sevenDay == 60)
    // 5-hour window, 2 h in, 40% used: 20%/h → 100% in 3 h, exactly at the reset (not before).
    let pace = limitPace(used: 40, windowMinutes: 300, resetsAt: nowT.addingTimeInterval(3 * 3600), now: nowT)!
    precondition(abs(pace.projected - 100) < 0.001 && pace.fullAt == nil)
    let fast = limitPace(used: 60, windowMinutes: 300, resetsAt: nowT.addingTimeInterval(3 * 3600), now: nowT)!
    precondition(abs(fast.projected - 150) < 0.001 && fast.fullAt == nowT.addingTimeInterval(4800), "40% left at 30%/h: 80 min")
    precondition(limitPace(used: 5, windowMinutes: 300, resetsAt: nowT.addingTimeInterval(4.95 * 3600), now: nowT) == nil, "too early")
    // corescope:// links and the quick-action palette.
    precondition(AppLink(URL(string: "corescope://open/ports")!) == .open(page: "ports"))
    precondition(AppLink(URL(string: "corescope://")!) == .open(page: nil))
    precondition(AppLink(URL(string: "corescope://profile/start?name=Revamp%20Test")!) == .profile(action: "start", name: "Revamp Test"))
    precondition(AppLink(URL(string: "corescope://profile/delete?name=x")!) == nil, "only start, stop and toggle")
    precondition(AppLink(URL(string: "corescope://profile/stop")!) == nil, "a name is required")
    precondition(AppLink(URL(string: "corescope://project/demo%20shop")!) == .project("demo shop"))
    precondition(AppLink(URL(string: "corescope://project")!) == nil, "a project is required")
    precondition(pathAncestors("a/b/c.txt") == ["a", "a/b"] && pathAncestors("c.txt").isEmpty)
    precondition(AppLink(URL(string: "corescope://lookup?port=8000")!) == .lookup(port: 8000))
    precondition(AppLink(URL(string: "corescope://services/check")!) == .checkServices)
    precondition(AppLink(URL(string: "corescope://happened?at=14:05")!) == .happened(at: "14:05"))
    precondition(AppLink(URL(string: "https://example.com/open")!) == nil && AppLink(URL(string: "corescope://format/disk")!) == nil)
    precondition(quickScore("rev", "Iniciar perfil Revamp Test") == 1 && quickScore("ini rev", "Iniciar perfil Revamp Test") == 0)
    precondition(quickScore("servi", "Abrir Serviços") != nil && quickScore("vamp", "Iniciar perfil Revamp") == 3)
    precondition(quickScore("xyz", "Abrir Portas") == nil && quickScore("", "Abrir") == nil)
    precondition(looksLikeTime("14:05") && looksLikeTime("2:05 pm") && looksLikeTime("14h05") && looksLikeTime("ontem 9:30"))
    precondition(!looksLikeTime("8000") && !looksLikeTime("redis") && !looksLikeTime("14"))
    precondition(cleanLogText("\u{1B}[32m✓ built\u{1B}[0m\r\nok") == "✓ built\nok", "ANSI colors and CRLF")
    precondition(cleanLogText("10%\r50%\r100%\ndone") == "100%\ndone", "progress kept at its last state")
    precondition(logExitCode("x\n[CoreScope] exit 1\n") == 1 && logExitCode("[CoreScope] exit 0") == 0 && logExitCode("exit 3") == nil)
    print(
      "32 native assertions passed: descendants, cycle, ordering, off-screen recovery, negative-origin monitor, forest roots, flatten, collapse, totals, ancestors, filter, formatting, container ports, shared ports, demo paths, debounce, sustained thresholds, new arrivals, port parsing, shortcut label, agent stalls, health targets, service states, shared containers, ssh stats, gate hook, machine alerts, failed unit explanations, service history, own cost, links, palette, Claude Desktop usage, limit pace, settings backup, performance audit, docker volumes, unused worktrees and branches, environment controller (bound checks, status, controller health, artifacts), run logs; plus settings JSON, Unicode escapes, status line install/chain, Claude limits, Claude /usage text, update versions, release notes, appcast"
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

/// Version order, release notes blocks and the appcast the release workflow publishes.
func updateTests() {
  precondition(UpdateLogic.isNewer("0.6.0", than: "0.5.1"))
  precondition(UpdateLogic.isNewer("v0.10.0", than: "0.9.9"))
  precondition(UpdateLogic.isNewer("1.0.0", than: "1.0.0-beta.2"))
  precondition(UpdateLogic.isNewer("1.0.0-beta.10", than: "1.0.0-beta.2"))
  precondition(!UpdateLogic.isNewer("0.5.1", than: "0.5.1"))
  precondition(!UpdateLogic.isNewer("0.5", than: "0.5.0"))
  precondition(!UpdateLogic.isNewer("0.5.0", than: "0.5.1"))
  precondition(UpdateLogic.compare("dev", "0.5.1") == .orderedAscending)

  let notes = """
    ### Added
    - **Updates**: opt-in daily check, with
      the notes shown in Settings.
    - `corescope version --check`.

    ### Fixed
    Paragraph line one
    continued.
    """
  precondition(
    NoteBlock.parse(notes) == [
      .heading("Added"), .bullet("**Updates**: opt-in daily check, with the notes shown in Settings."),
      .bullet("`corescope version --check`."), .heading("Fixed"), .text("Paragraph line one continued."),
    ])

  let item = AppcastItem(
    build: "10", version: "0.6.0",
    url: "https://github.com/Tiagospem/corescope/releases/download/v0.6.0/CoreScope-0.6.0-macos-universal.zip",
    length: 12_345_678, edSignature: "c2lnbmF0dXJlPT0=", notes: notes + "\nOdd ]]> & <tags>",
    date: Date(timeIntervalSince1970: 1_792_000_000))
  let xml = Appcast.render([item])
  precondition(xml.contains("<sparkle:version>10</sparkle:version>"))
  precondition(xml.contains("<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"))
  precondition(xml.contains(#"sparkle:format="markdown""#))
  guard let parsed = Appcast.parse(Data(xml.utf8)), parsed.count == 1 else { fatalError("appcast does not parse") }
  precondition(parsed[0] == item)
  precondition(Appcast.parse(Data("<rss><channel><item>".utf8)) == nil)
}

/// "Failed systemd units: logrotate.service" explained from the real outputs of two Forge servers.
func failedUnitTests() {
  precondition(validSystemdUnit("logrotate.service") && validSystemdUnit("getty@tty1.service"))
  precondition(validSystemdUnit("systemd-fsck@dev-disk-by\\x2duuid-1.service"))
  precondition(!validSystemdUnit("-x.service") && !validSystemdUnit("a;rm.service") && !validSystemdUnit("a'b.service"))
  precondition(!validSystemdUnit("nginx") && !validSystemdUnit("a b.service") && !validSystemdUnit("$(id).service"))
  precondition(FailedUnitCheck.command(unit: "x.service;reboot") == nil)
  let command = FailedUnitCheck.command(unit: "logrotate.service")!
  precondition(command.hasPrefix("systemctl status 'logrotate.service' --no-pager -n 0"))
  precondition(command.contains("journalctl -u 'logrotate.service'") && !command.contains("sudo"))

  let status = """
    × logrotate.service - Rotate log files
         Loaded: loaded (/lib/systemd/system/logrotate.service; static)
         Active: failed (Result: exit-code) since Fri 2026-10-17 00:00:03 UTC; 14h ago
    TriggeredBy: ● logrotate.timer
           Docs: man:logrotate(8)
        Process: 812 ExecStart=/usr/sbin/logrotate /etc/logrotate.conf (code=exited, status=1/FAILURE)
       Main PID: 812 (code=exited, status=1/FAILURE)
            CPU: 41ms
    """
  let tail = """
    Oct 17 00:00:03 forge-1 systemd[1]: logrotate.service: Main process exited, code=exited, status=1/FAILURE
    Oct 17 00:00:03 forge-1 systemd[1]: logrotate.service: Failed with result 'exit-code'.
    Oct 17 00:00:03 forge-1 systemd[1]: Failed to start logrotate.service - Rotate log files.

    """
  // Server 1: 27 Forge configs left for site users that were deleted. The day before failed the
  // same way; only the last run counts.
  let sites = (1...27).map { "site\($0)" }
  var run = "Oct 17 00:00:01 forge-1 systemd[1]: Starting logrotate.service - Rotate log files...\n"
  for s in sites {
    run += "Oct 17 00:00:01 forge-1 logrotate[812]: error: /etc/logrotate.d/forge-\(s).com:9 unknown user '\(s)'\n"
    run += "Oct 17 00:00:01 forge-1 logrotate[812]: error: found error in /home/\(s)/\(s).com/storage/logs/*.log , skipping\n"
  }
  let output1 = status + "\n" + FailedUnitCheck.journalMarker + "\n" + run.replacingOccurrences(of: "Oct 17", with: "Oct 16")
    + tail + run + tail + FailedUnitCheck.idMarker + " 1000 forge adm\n"
  let e1 = explainFailedUnit(unit: "logrotate.service", output: output1)
  precondition(e1.description == "Rotate log files" && e1.active.hasPrefix("failed (Result: exit-code)"))
  precondition(e1.process == "ExecStart=/usr/sbin/logrotate /etc/logrotate.conf (code=exited, status=1/FAILURE)")
  precondition(!e1.journalRestricted && !e1.notFound)
  precondition(e1.groups.count == 5, "unknown user, found error, then systemd's three lines")
  precondition(e1.groups[0].source == "logrotate" && e1.groups[0].count == 27, "the last run only")
  precondition(e1.groups[0].message == "error: /etc/logrotate.d/forge-site1.com:9 unknown user 'site1'")
  precondition(e1.groups[0].samples.count == 5 && e1.groups[1].count == 27)
  precondition(e1.groups.last?.source == "systemd")
  precondition(e1.hints.count == 1 && e1.hints[0].kind == .logrotateUnknownUser && e1.hints[0].files.count == 27)
  precondition(e1.hints[0].files[0] == "/etc/logrotate.d/forge-site1.com")
  precondition(e1.hints[0].english.contains("Forge") && e1.hints[0].english.contains("(+21)"))

  // Server 2: 13 duplicate Forge configs.
  var dup = "Oct 17 00:00:01 forge-2 systemd[1]: Starting logrotate.service - Rotate log files...\n"
  for i in 1...13 {
    dup += "Oct 17 00:00:01 forge-2 logrotate[655]: error: /etc/logrotate.d/forge-app\(i)-old:1 duplicate log entry for /home/forge/app\(i).com/storage/logs/laravel.log\n"
    dup += "Oct 17 00:00:01 forge-2 logrotate[655]: error: found error in file forge-app\(i)-old, skipping\n"
  }
  let e2 = explainFailedUnit(
    unit: "logrotate.service",
    output: status + FailedUnitCheck.journalMarker + "\n" + dup + tail + FailedUnitCheck.idMarker + " 0 root\n")
  precondition(e2.groups[0].count == 13 && e2.groups[0].message.contains("duplicate log entry"))
  precondition(e2.groups[1].count == 13, "old-style 'found error in file x' groups too")
  precondition(e2.hints.map(\.kind) == [.logrotateDuplicate] && e2.hints[0].files.last == "/etc/logrotate.d/forge-app13-old")

  // Not allowed to read the system journal: say so instead of showing nothing.
  let hidden = """
    Hint: You are currently not seeing messages from other users and the system.
          Users in groups 'adm', 'systemd-journal' can see all messages.
          Pass -q to turn off this notice.
    -- No entries --
    """
  let e3 = explainFailedUnit(
    unit: "logrotate.service", output: status + FailedUnitCheck.journalMarker + "\n" + hidden + "\n" + FailedUnitCheck.idMarker + " 1001 deploy\n")
  precondition(e3.journalRestricted && e3.groups.isEmpty && e3.lines == 0)
  let e4 = explainFailedUnit(
    unit: "logrotate.service", output: status + FailedUnitCheck.journalMarker + "\n-- No entries --\n" + FailedUnitCheck.idMarker + " 0 root\n")
  precondition(!e4.journalRestricted, "root reads everything; the journal is just empty")

  // postrotate and nginx -t failures; short-iso timestamps.
  let reload = """
    2026-10-17T00:00:01+0000 web systemd[1]: Starting logrotate.service - Rotate log files...
    2026-10-17T00:00:02+0000 web logrotate[90]: nginx: [emerg] unknown directive "proxy_pas" in /etc/nginx/sites-enabled/app:12
    2026-10-17T00:00:02+0000 web logrotate[90]: nginx: configuration file /etc/nginx/nginx.conf test failed
    2026-10-17T00:00:02+0000 web logrotate[90]: error: error running shared postrotate script for '/var/log/nginx/*.log '
    """
  let e5 = explainFailedUnit(unit: "logrotate.service", output: "● x\n" + FailedUnitCheck.journalMarker + reload)
  precondition(e5.hints.map(\.kind) == [.nginxConfig, .postrotate])
  precondition(e5.hints[1].files == ["/var/log/nginx/*.log"] && e5.hints[0].files[0].contains("proxy_pas"))
  precondition(journalEntry("Hint: You are currently not seeing messages") == nil)
  let missing = explainFailedUnit(unit: "gone.service", output: "Unit gone.service could not be found.\n" + FailedUnitCheck.journalMarker)
  precondition(missing.notFound)
}

func volumeTests() {
  // Only volumes no container references (running or stopped) can be removed.
  precondition(volumeBlock(refCount: 0, usedBy: []) == nil)
  precondition(volumeBlock(refCount: 1, usedBy: ["db"]) == .inUse(["db"]))
  precondition(volumeBlock(refCount: 0, usedBy: ["db-stopped"]) == .inUse(["db-stopped"]), "mounts win over a stale count")
  precondition(volumeBlock(refCount: 2, usedBy: []) == .inUseCount(2))
  precondition(volumeBlock(refCount: -1, usedBy: []) == .usageUnknown, "unknown usage is never removable")

  let hex = "32a362dbf144daff3a909400cbdf09fba92b6f86ad4038252e201b676f0df432"
  precondition(isAnonymousVolume(hex) && !isAnonymousVolume("mysql_data") && !isAnonymousVolume(String(hex.dropLast())))

  precondition(volumeOrigin(labels: ["com.docker.volume.anonymous": ""]) == nil)
  precondition(
    volumeOrigin(labels: ["com.docker.compose.project": "shop", "com.docker.compose.volume": "db"])
      == VolumeOrigin(project: "shop", detail: "db"))
  precondition(volumeOrigin(labels: ["com.docker.stack.namespace": "infra"])?.project == "infra")

  precondition(volumeDatabaseKind(name: "lei45-mysql-279900a8", labels: [:]) == "MySQL")
  precondition(volumeDatabaseKind(name: "x", labels: ["com.docker.compose.volume": "pgdata"]) == "PostgreSQL")
  precondition(volumeDatabaseKind(name: hex, labels: [:], images: ["library/redis:8.6.2"]) == "Redis")
  precondition(volumeDatabaseKind(name: "typesense-data", labels: [:]) == nil)

  let plan = volumeRemovalPlan([
    ("a", 100, 0, []), ("b", nil, 0, []), ("mysql_data", 5000, 1, ["db"]), ("c", 7, -1, []),
  ])
  precondition(plan.names == ["a", "b"] && plan.bytes == 100 && plan.blocked == 2)
}

func auditTests() {
  let gb = 1_073_741_824.0
  // Under memory pressure, 1 GB of memory outweighs 4 GB of disk; with room, 4 GB of disk wins
  // over a 1 GB process only when the disk is nearly full.
  let calm = AuditContext()
  let tight = AuditContext(pressure: 1, swap: 0, diskFree: 50 * gb, diskTotal: 500 * gb, onBattery: false)
  precondition(tight.memoryTight && !tight.diskTight && !calm.memoryTight)
  let memory = AuditImpact(memory: gb)
  let disk = AuditImpact(disk: 4 * gb)
  precondition(auditScore(memory, confidence: .high, context: tight) > auditScore(disk, confidence: .high, context: tight))
  precondition(auditScore(memory, confidence: .high, context: calm) > auditScore(disk, confidence: .high, context: calm))
  let full = AuditContext(pressure: 0, swap: 0, diskFree: 20 * gb, diskTotal: 500 * gb, onBattery: false)
  precondition(full.diskTight)
  precondition(auditScore(disk, confidence: .high, context: full) > auditScore(memory, confidence: .high, context: full))
  precondition(AuditContext(pressure: 0, swap: 3 * gb, diskFree: nil, diskTotal: nil, onBattery: false).memoryTight, "swap counts")
  // Confidence scales the figure; battery doubles watts; negative readings count as nothing.
  precondition(auditScore(memory, confidence: .low, context: calm) < auditScore(memory, confidence: .medium, context: calm))
  let watts = AuditImpact(watts: 3)
  let battery = AuditContext(pressure: nil, swap: nil, diskFree: nil, diskTotal: nil, onBattery: true)
  precondition(auditScore(watts, confidence: .high, context: battery) == 2 * auditScore(watts, confidence: .high, context: calm))
  precondition(auditScore(AuditImpact(cpu: -5, memory: -1), confidence: .high, context: calm) == 0)
  precondition(abs(auditScore(AuditImpact(cpu: 100), confidence: .high, context: calm) - 10) < 1e-9, "a full core is 10")
  // Ranking: highest first, ties keep their order.
  let ranked = rankAudit([("a", 1.0), ("b", 3.0), ("c", 1.0), ("d", 2.0)]) { $0.1 }
  precondition(ranked.map(\.0) == ["b", "d", "a", "c"])
  // Thresholds.
  precondition(auditHeavyProcess(cpu: 120, memory: 0, highCPUSeconds: 90))
  precondition(!auditHeavyProcess(cpu: 120, memory: 0, highCPUSeconds: 10), "one busy sample is not a pattern")
  precondition(auditHeavyProcess(cpu: 0, memory: 2 * gb, highCPUSeconds: 0))
  precondition(!auditHeavyProcess(cpu: 30, memory: gb, highCPUSeconds: 600))
  precondition(auditOrphanWorthStopping(cpu: 0, memory: 0, listening: true), "a port is held")
  precondition(!auditOrphanWorthStopping(cpu: 0.2, memory: 8 * 1_048_576, listening: false))
  precondition(auditOrphanWorthStopping(cpu: 0, memory: 200 * 1_048_576, listening: false))
  precondition(auditIdleContainer(cpu: 0.1, memory: 400 * 1_048_576, inActiveProfile: false))
  precondition(!auditIdleContainer(cpu: 0.1, memory: 400 * 1_048_576, inActiveProfile: true), "a started profile owns it")
  precondition(!auditIdleContainer(cpu: nil, memory: nil, inActiveProfile: false), "no stats, no claim")
  precondition(!auditIdleContainer(cpu: 12, memory: 400 * 1_048_576, inActiveProfile: false), "it is working")
  let now = 1_800_000_000.0
  precondition(auditDiskConfidence(kind: "docker_build_cache", modified: 0, merged: false, now: now) == .high)
  precondition(auditDiskConfidence(kind: "worktree", modified: now, merged: true, now: now) == .high)
  precondition(auditDiskConfidence(kind: "worktree", modified: now - 90 * 86400, merged: false, now: now) == .low)
  precondition(auditDiskConfidence(kind: "node_modules", modified: now - 40 * 86400, merged: false, now: now) == .high)
  precondition(auditDiskConfidence(kind: "node_modules", modified: now - 86400, merged: false, now: now) == .medium)
  precondition(auditDeadService(uptime24h: 0.13) && !auditDeadService(uptime24h: 0.62) && !auditDeadService(uptime24h: nil))
  precondition(auditStaleAge(scannedAt: nil, now: now) == .infinity, "never scanned is stale")
  precondition(auditStaleAge(scannedAt: now - 3600, now: now) == nil)
  precondition(auditStaleAge(scannedAt: now - 7 * 3600, now: now) == 7 * 3600)
}

func pruneTests() {
  // Worktrees: merged, upstream gone or folder gone qualify; the checkout, the main tree, one in
  // use, locked or with changes stays (the dirty option frees only the last).
  let wt = WorktreeFacts(path: "/r/.claude/worktrees/a", branch: "a", merged: true)
  precondition(worktreeVerdict(wt).removable && worktreeVerdict(wt).reasons == [.merged])
  func with(_ f: (inout WorktreeFacts) -> Void) -> WorktreeFacts {
    var w = wt
    f(&w)
    return w
  }
  precondition(worktreeVerdict(with { $0.main = true }).block == .main)
  precondition(worktreeVerdict(with { $0.current = true }).block == .current)
  precondition(worktreeVerdict(with { $0.inUse = "zsh (PID 9)" }).block == .inUse)
  precondition(worktreeVerdict(with { $0.locked = true }).block == .locked)
  precondition(worktreeVerdict(with { $0.merged = false }).block == .notMerged)
  precondition(worktreeVerdict(with { $0.changes = nil }).block == .unknownChanges)
  let dirty = with { $0.changes = 2 }
  precondition(worktreeVerdict(dirty).block == .dirty && worktreeVerdict(dirty, allowDirty: true).removable)
  precondition(!worktreeVerdict(with { $0.inUse = "x"; $0.changes = 2 }, allowDirty: true).removable)
  precondition(worktreeVerdict(with { $0.merged = false; $0.gone = true }).reasons == [.upstreamGone])
  precondition(worktreeVerdict(with { $0.merged = nil; $0.prunable = true; $0.changes = nil }).removable)
  precondition(worktreeGroup(with { $0.main = true }) == .inUse && worktreeGroup(wt) == .removable)
  precondition(worktreeGroup(dirty) == .other && worktreeGroup(with { $0.inUse = "x" }) == .inUse)

  // Branches: merged ones checked out nowhere; never the current or the default branch.
  let br = BranchFacts(name: "feat", merged: true)
  precondition(branchVerdict(br, defaultBranch: "origin/main").removable)
  precondition(branchVerdict(BranchFacts(name: "main", merged: true), defaultBranch: "origin/main").block == .defaultBranch)
  precondition(branchVerdict(BranchFacts(name: "x", current: true, merged: true), defaultBranch: nil).block == .current)
  precondition(branchVerdict(BranchFacts(name: "x", merged: false), defaultBranch: nil).block == .notMerged)
  let held = BranchFacts(name: "a", worktree: "/r/.claude/worktrees/a", merged: true)
  precondition(branchVerdict(held, defaultBranch: "main").block == .checkedOut)
  let freed = branchVerdict(held, defaultBranch: "main", freed: ["/r/.claude/worktrees/a"])
  precondition(freed.removable && freed.reasons.contains(.worktreeRemoved))
  precondition(branchGroup(held, defaultBranch: "main") == .inUse && branchGroup(br, defaultBranch: "main") == .removable)
  precondition(isDefaultBranch("main", default: "origin/main") && !isDefaultBranch("domain", default: "origin/main"))

  // The sheet: a branch goes with its worktree only while that worktree is chosen; one held by a
  // worktree that stays is not listed; dirty worktrees are never ticked for you.
  let trees = [
    WorktreeFacts(path: "/r", branch: "main", main: true, current: true),
    wt,
    WorktreeFacts(path: "/r/b", branch: "b", merged: true, changes: 1),
    WorktreeFacts(path: "/r/c", branch: "c", merged: true, inUse: "node (PID 3)"),
    WorktreeFacts(path: "/r/d", branch: "d", merged: false),
  ]
  let refs = [
    BranchFacts(name: "main", current: true, merged: nil), held,
    BranchFacts(name: "b", worktree: "/r/b", merged: true),
    BranchFacts(name: "c", worktree: "/r/c", merged: true),
    BranchFacts(name: "old", merged: true, gone: true), BranchFacts(name: "wip", merged: false),
  ]
  let all = pruneCandidates(worktrees: trees, branches: refs, defaultBranch: "main", allowDirty: false, chosenWorktrees: [wt.path])
  precondition(all.map(\.key) == ["w:/r/.claude/worktrees/a", "w:/r/b", "w:/r/c", "b:a", "b:old"])
  precondition(defaultPruneSelection(all, worktrees: trees) == ["w:/r/.claude/worktrees/a", "b:a", "b:old"])
  let unchosen = pruneCandidates(worktrees: trees, branches: refs, defaultBranch: "main", allowDirty: false, chosenWorktrees: [])
  precondition(unchosen.first { $0.target == "a" }?.verdict.block == .checkedOut)
  let withDirty = pruneCandidates(worktrees: trees, branches: refs, defaultBranch: "main", allowDirty: true, chosenWorktrees: [wt.path, "/r/b"])
  precondition(withDirty.contains { $0.target == "b" && $0.verdict.removable })
  precondition(!defaultPruneSelection(withDirty, worktrees: trees).contains("w:/r/b"))
}

/// Checks bound to profiles or components, the controller's status and controller profiles.
func environmentTests() {
  // Revamp on, Arena off: Arena's check behind the Herd proxy (443 listening) is neutral, not down.
  let arena = serviceExpectation(profilesOn: [false], component: nil, unknownReason: "")
  precondition(arena == .notExpected)
  precondition(boundServiceState(level: .down, paused: false, expectation: arena, starting: false) == .notRunning)
  precondition(shouldProbeBound(paused: false, expectation: arena, listening: true))
  precondition(!shouldProbeBound(paused: false, expectation: arena, listening: false))
  // Answering while nothing selected it: running outside CoreScope, neither up nor down.
  let outside = boundServiceState(level: .up, paused: false, expectation: arena, starting: false)
  precondition(outside == .external && !outside.recordsHistory && !outside.isFailure)
  // Selected and unavailable is a failure; while its profile starts it is only "starting".
  let on = serviceExpectation(profilesOn: [false, true], component: nil, unknownReason: "")
  precondition(on == .expected, "any consumer on requires the service")
  precondition(boundServiceState(level: .down, paused: false, expectation: on, starting: false) == .down)
  let starting = boundServiceState(level: .down, paused: false, expectation: on, starting: true)
  precondition(starting == .starting && !starting.recordsHistory)
  precondition(boundServiceState(level: .up, paused: false, expectation: on, starting: true) == .up)
  precondition(boundServiceState(level: nil, paused: false, expectation: on, starting: false) == .pending)
  // Unknown selection is never up nor off, whatever the probe says.
  let unknown = serviceExpectation(profilesOn: [false, nil], component: nil, unknownReason: "timed out")
  precondition(unknown == .unknown("timed out"))
  for level: HealthLevel? in [.up, .down, nil] {
    let state = boundServiceState(level: level, paused: false, expectation: unknown, starting: false)
    precondition(state == .unknown && !state.recordsHistory && state.mcpStatus == "unknown")
  }
  // The controller knows dependencies: a component it keeps for another app stays expected.
  precondition(serviceExpectation(profilesOn: [false], component: .some(true), unknownReason: "") == .expected)
  precondition(serviceExpectation(profilesOn: [true], component: .some(false), unknownReason: "") == .notExpected)
  // Bound to a component the status does not report (stale, failed): unknown unless a profile is on.
  precondition(serviceExpectation(profilesOn: [], component: .some(nil), unknownReason: "stale") == .unknown("stale"))
  precondition(serviceExpectation(profilesOn: [false], component: .some(nil), unknownReason: "x") == .unknown("x"))
  precondition(serviceExpectation(profilesOn: [true], component: .some(nil), unknownReason: "x") == .expected)
  precondition(boundServiceState(level: .down, paused: true, expectation: on, starting: false) == .paused)
  precondition(serviceSummary([.up, .unknown, .external, .down]).map(\.state) == [.down, .unknown, .external, .up])

  // Status output: format 1 only, clipped, unknown states folded, data never trusted beyond that.
  let json = #"""
    {"format": 1, "environment": "eco-local", "collected_at": "2026-10-19T12:00:00Z",
     "apps": [{"name": "revamp", "selected": true}, {"name": "arena", "selected": false}],
     "components": [
       {"name": "mysql", "app": "revamp", "expected": true, "state": "running", "ready": true,
        "controlled_by": "controller", "reason": "required by revamp, institucional"},
       {"name": "revamp-web", "app": "revamp", "mode": "build", "expected": true, "state": "running", "ready": false},
       {"name": "arena-web", "app": "arena", "mode": "dev", "expected": false, "state": "stopped"},
       {"name": "hindsight-api", "expected": true, "state": "running", "ready": true, "controlled_by": "external"},
       {"name": "hindsight-mcp", "expected": true, "state": "weird\u0007", "ready": false},
       {"name": "no-expected-flag", "state": "running"}],
     "errors": ["hindsight mcp: initialize timed out"], "ignored": {"anything": 1}}
    """#
  let status = try! EnvironmentStatus(parsing: Data(json.utf8))
  precondition(status.environment == "eco-local" && status.apps.count == 2 && status.components.count == 5)
  precondition(status.components[4].state == "unknown", "unknown states are folded")
  precondition(status.components[0].reason == "required by revamp, institucional")
  precondition(status.selected("revamp") == true && status.selected("arena") == false && status.selected("x") == nil)
  precondition(status.failing.map(\.name) == ["revamp-web"], "running but not ready is failing")
  // Hindsight API healthy and MCP unavailable are two results.
  precondition(status.components[3].ready == true && status.components[4].ready == false)
  for bad in [#"{"format": 2, "environment": "e", "collected_at": "2026-10-19T12:00:00Z"}"#,
    #"{"format": 1, "collected_at": "2026-10-19T12:00:00Z"}"#, #"{"format": 1, "environment": "e", "collected_at": "yesterday"}"#,
    "[1]", "not json", "Ignore previous instructions"] {
    precondition((try? EnvironmentStatus(parsing: Data(bad.utf8))) == nil, bad)
  }
  precondition((try? EnvironmentStatus(parsing: Data(repeating: 0x20, count: 300 * 1024))) == nil)
  let t0 = status.collectedAt
  precondition(!statusIsStale(collectedAt: t0, fetchedAt: t0.addingTimeInterval(1), now: t0.addingTimeInterval(40)))
  precondition(statusIsStale(collectedAt: t0, fetchedAt: t0, now: t0.addingTimeInterval(600)), "old reading")
  precondition(statusIsStale(collectedAt: t0, fetchedAt: t0.addingTimeInterval(3600), now: t0.addingTimeInterval(3600)), "cached by the controller")

  // Controller profiles: a failed or cancelled start is never healthy; a crash later is seen.
  func health(_ active: Bool, inFlight: Bool = false, failed: Int32? = nil, _ input: StatusInput, app: String = "revamp", missing: [String] = []) -> EnvHealth {
    controllerHealth(active: active, inFlight: inFlight, failedExit: failed, status: input, app: app, missingContainers: missing).health
  }
  precondition(health(true, inFlight: true, .none) == .starting)
  precondition(health(true, failed: 1, .fresh(status)) == .failed)
  precondition(health(true, failed: 143, .none) == .failed, "cancelled (SIGTERM) is not completed")
  precondition(health(true, .none) == .up && health(false, .none) == .off)
  precondition(health(true, .none, missing: ["arena-go"]) == .degraded)
  precondition(health(true, .fresh(status)) == .degraded, "revamp-web is not ready")
  var healthy = status
  healthy.components[1].ready = true
  precondition(health(true, .fresh(healthy)) == .up)
  precondition(health(true, .fresh(healthy), missing: ["revamp-db"]) == .degraded)
  var unread = healthy
  unread.components[1].state = "unknown"
  precondition(health(true, .fresh(unread)) == .unknown, "engine down is unknown, not starting")
  healthy.busy = "switching revamp-web to dev"
  precondition(health(true, .fresh(healthy)) == .starting)
  // Selection changed in the terminal: CoreScope follows it and says so.
  let arenaOff = controllerHealth(active: true, inFlight: false, failedExit: nil, status: .fresh(status), app: "arena", missingContainers: [])
  precondition(arenaOff.health == .off && arenaOff.outside)
  healthy.busy = nil
  let byTerminal = controllerHealth(active: false, inFlight: false, failedExit: nil, status: .fresh(healthy), app: "revamp", missingContainers: [])
  precondition(byTerminal.health == .up && byTerminal.outside)
  // Docker switched off: every expected component unread → everything off, nothing to alert.
  precondition(unread.nothingRead == false, "one unread component is not the engine being off")
  var engineDown = status
  engineDown.components = engineDown.components.map { var c = $0; c.state = "unknown"; return c }
  precondition(engineDown.nothingRead)
  let off = engineDown.engineOff
  precondition(off.apps.allSatisfy { !$0.selected } && off.components.allSatisfy { !$0.expected && $0.state == "stopped" })
  precondition(off.errors.isEmpty && controllerHealth(active: true, inFlight: false, failedExit: nil, status: .fresh(off), app: "revamp", missingContainers: []).health == .off)
  precondition(serviceExpectation(profilesOn: [], component: .some(off.components[0].expected), unknownReason: "") == .notExpected)
  // Unreadable status: unknown, never up or off.
  precondition(health(true, .unavailable("timed out")) == .unknown && health(false, .unavailable("x")) == .unknown)

  precondition(!statusIsStale(collectedAt: t0, fetchedAt: t0, now: t0.addingTimeInterval(200), interval: 120), "slow poll")
  precondition(statusIsStale(collectedAt: t0, fetchedAt: t0, now: t0.addingTimeInterval(400), interval: 120))

  // The translation table must be found: a misplaced closing """ once indented every key and
  // left the whole app in Portuguese.
  precondition(Localization.table["Iniciar"]?.en == "Start" && Localization.table["Perfis"]?.es == "Perfiles")
  precondition(Localization.table.count > 1500 && Localization.table.keys.allSatisfy { !$0.hasPrefix(" ") })
  // "System" language: the first supported one in macOS's list.
  precondition(Localization.systemLanguage(["en-BR", "pt-BR"]) == "en" && Localization.systemLanguage(["pt-BR", "en"]) == "pt")
  precondition(Localization.systemLanguage(["de-DE", "es-ES"]) == "es" && Localization.systemLanguage(["ja"]) == "en")

  // Menu bar compact values keep a unit letter.
  precondition(compactValue("11,65 GB") == "11,6G" && compactValue("1,9 MB/s") == "1,9M/s" && compactValue("4 KB/s") == "4K/s")
  precondition(compactValue("512 B/s") == "512B/s" && compactValue("—") == "—" && compactValue("49 °C") == "49 °C")

  // Action kinds come from the file or from the words of the name.
  precondition(ActionKind.of(name: "eco-memory-backup", explicit: nil) == .data && ActionKind.of(name: "eco-doctor", explicit: nil) == .diagnostics)
  precondition(ActionKind.of(name: "eco-stop-all", explicit: nil) == .stop && ActionKind.of(name: "eco-arena-migrate", explicit: nil) == .setup)
  precondition(ActionKind.of(name: "eco-revamp-web-dev", explicit: nil) == .run && ActionKind.of(name: "x", explicit: "data") == .data)
  precondition(ActionKind.of(name: "eco-weird", explicit: nil) == .other && ActionKind.of(name: "eco-weird", explicit: "nonsense") == .other)

  // Actions report their artifact on a marker line; the last one wins.
  let out = "dumping…\nCORESCOPE_ARTIFACT=old.zip\nCORESCOPE_ARTIFACT= backups/h.zip \ndone\n"
  precondition(actionArtifact(out, folder: "/p") == "/p/backups/h.zip")
  precondition(actionArtifact("CORESCOPE_ARTIFACT=/abs/x.zip", folder: "/p") == "/abs/x.zip")
  precondition(actionArtifact("no marker\nCORESCOPE_ARTIFACT=", folder: "/p") == nil)
}
