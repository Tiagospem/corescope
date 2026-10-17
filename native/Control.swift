import Darwin
import Foundation

/// Local control socket for `corescope mcp`: the app owns profiles, Services checks, machines,
/// the cleanup cache and settings, so agents reach them here instead of a second copy of that
/// state. A Unix socket in the user's Application Support folder (mode 0600), peers checked to be
/// the same user, one JSON request per connection. Off with Settings › MCP › app access.
final class ControlServer {
  static let shared = ControlServer()
  static let path = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CoreScope/control.sock").path
  private var listener: Int32 = -1
  private let workers = DispatchQueue(label: "app.corescope.control", qos: .userInitiated, attributes: .concurrent)

  func apply() {
    Preferences.shared.mcpAppAccess ? start() : stop()
  }
  private func start() {
    guard listener < 0 else { return }
    try? FileManager.default.createDirectory(
      atPath: (Self.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    unlink(Self.path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(Self.path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      close(fd)
      return
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
    }
    guard bound == 0, chmod(Self.path, 0o600) == 0, listen(fd, 8) == 0 else {
      close(fd)
      return
    }
    listener = fd
    let thread = Thread { [weak self] in self?.acceptLoop(fd) }
    thread.name = "CoreScope control"
    thread.start()
  }
  func stop() {
    guard listener >= 0 else { return }
    let fd = listener
    listener = -1
    shutdown(fd, SHUT_RDWR)
    close(fd)
    unlink(Self.path)
  }
  private func acceptLoop(_ fd: Int32) {
    while listener == fd {
      let client = accept(fd, nil, nil)
      guard client >= 0 else {
        if listener != fd { return }
        continue
      }
      workers.async { self.serve(client) }
    }
  }
  private func serve(_ client: Int32) {
    defer { close(client) }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while data.count < 1 << 20, !data.contains(0x0A) {
      let n = read(client, &buffer, buffer.count)
      guard n > 0 else { break }
      data.append(contentsOf: buffer[0..<n])
    }
    let line = data.split(separator: 0x0A).first ?? Data()
    let reply: [String: Any]
    if let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = request["op"] as? String {
      let args = request["args"] as? [String: Any] ?? [:]
      let done = DispatchSemaphore(value: 0)
      var result: [String: Any] = [:]
      DispatchQueue.main.async {
        ControlAPI.handle(op, args) { value in
          result = value
          done.signal()
        }
      }
      result = done.wait(timeout: .now() + 180) == .timedOut ? ["error": "timed out"] : result
      reply = result
    } else {
      reply = ["error": "invalid request"]
    }
    var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{}".utf8)
    out.append(0x0A)
    out.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let n = write(client, raw.baseAddress! + sent, raw.count - sent)
        if n <= 0 { break }
        sent += n
      }
    }
  }
}

/// The operations behind the MCP tools. Runs on the main thread; replies are JSON objects with
/// English messages (agents read them), `error` when the request cannot be done.
enum ControlAPI {
  typealias Reply = ([String: Any]) -> Void

  static func handle(_ op: String, _ args: [String: Any], reply: @escaping Reply) {
    switch op {
    case "ping": reply(["ok": true, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""])
    case "profiles.list": reply(["profiles": ProfileStore.shared.profiles.map(profileJSON)])
    case "profiles.create": createProfile(args, reply)
    case "profiles.delete": withProfile(args, reply) { p in
        ProfileStore.shared.profiles.removeAll { $0.id == p.id }
        reply(["deleted": p.name, "note": "Only the settings were deleted; nothing running was stopped."])
      }
    case "profiles.start": withProfile(args, reply) { p in
        ProfileStore.shared.start(p) { errors in
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var out = profileJSON(ProfileStore.shared.profiles.first { $0.id == p.id } ?? p)
            out["errors"] = errors
            reply(out)
          }
        }
      }
    case "profiles.stop": withProfile(args, reply) { p in
        let everything = args["everything"] as? Bool ?? false
        ProfileStore.shared.stop(p, everything: everything) { plan, errors in
          reply([
            "stopped_containers": everything ? p.containers : plan.stop,
            "kept_shared": everything ? [:] : plan.shared,
            "kept_not_started_by_profiles": everything ? [] : plan.external,
            "errors": errors,
            "note": "SIGTERM was sent to the processes CoreScope started for this profile and their children.",
          ])
        }
      }
    case "profiles.logs": withProfile(args, reply) { p in
        let lines = min(max(args["lines"] as? Int ?? 60, 1), 400)
        let wanted = args["command"] as? String
        var logs: [String: String] = [:]
        for c in p.commands where wanted == nil || c.name == wanted {
          let url = ProfileStore.shared.logURL(p, c)
          let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
          logs[c.name] = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
        reply(["profile": p.name, "logs": logs])
      }

    case "services.list": reply(["services": HealthStore.shared.checks.map(serviceJSON)])
    case "services.add":
      guard let target = args["target"] as? String, HealthTarget(target) != nil else {
        return reply(["error": "target must be a URL (http/https), host:port or a local port"])
      }
      let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? HealthTarget(target)!.label
      let check = HealthCheck(name: name, target: target)
      HealthStore.shared.checks.append(check)
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) { reply(serviceJSON(check)) }
    case "services.remove":
      guard let check = findService(args) else { return reply(["error": "no such service"]) }
      HealthStore.shared.checks.removeAll { $0.id == check.id }
      reply(["removed": check.name])
    case "services.check":
      HealthStore.shared.runAll()
      DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        reply(["services": HealthStore.shared.checks.map(serviceJSON)])
      }

    case "machines.list": reply(["machines": MachineStore.shared.hosts.map(machineJSON)])
    case "machines.add":
      guard let host = args["host"] as? String, validSSHDestination(host) else {
        return reply(["error": "host must be an ssh alias or user@host (no options or spaces)"])
      }
      if !MachineStore.shared.hosts.contains(host) { MachineStore.shared.hosts.append(host) }
      MachineStore.shared.refresh(host)
      waitForMachines(reply) { ["machine": machineJSON(host)] }
    case "machines.remove":
      guard let host = args["host"] as? String, MachineStore.shared.hosts.contains(host) else {
        return reply(["error": "no such machine"])
      }
      MachineStore.shared.hosts.removeAll { $0 == host }
      reply(["removed": host])
    case "machines.refresh":
      MachineStore.shared.refreshAll()
      waitForMachines(reply) { ["machines": MachineStore.shared.hosts.map(machineJSON)] }

    case "cleanup.list": reply(cleanupJSON())
    case "cleanup.scan":
      CleanupStore.shared.scan { error in reply(error.map { ["error": $0] } ?? cleanupJSON()) }
    case "cleanup.clean":
      let paths = Set(args["paths"] as? [String] ?? [])
      let items = (CleanupStore.shared.report?.items ?? []).filter { paths.contains($0.id) }
      let unknown = paths.subtracting(items.map(\.id))
      guard !items.isEmpty else {
        return reply(["error": "none of these ids are in the latest scan; run scan_dev_space and use its ids"])
      }
      let busy = items.filter { $0.busy != nil }
      CleanupStore.shared.clean(items.filter { $0.busy == nil }) { message, done in
        reply([
          "summary": message, "cleaned": Array(done), "skipped_in_use": busy.map(\.id),
          "unknown_ids": Array(unknown),
          "note": "Folders went to the Trash (recoverable until it is emptied); Docker data was removed by Docker.",
        ])
      }

    case "settings.get": reply(["settings": AgentSettings.read()])
    case "settings.set":
      guard let key = args["key"] as? String else { return reply(["error": "key is required"]) }
      if let error = AgentSettings.write(key, args["value"]) { return reply(["error": error]) }
      reply(["settings": AgentSettings.read()])

    case "agents.stuck":
      let watch = StallWatch.shared
      var out: [[String: Any]] = []
      if let s = Monitor.shared.snapshot {
        for meta in AgentStore.shared.claudeSessions.values {
          guard let root = s.process(pid: meta.pid) else { continue }
          var row: [String: Any] = [
            "agent": "Claude Code", "pid": root.pid, "title": meta.name ?? "", "project": root.project ?? "",
            "busy": meta.isBusy,
          ]
          if let stall = watch.stall(root: root, tree: s.subtree(of: root), meta: meta) {
            row["stall"] = stallJSON(stall)
          }
          out.append(row)
        }
      }
      for t in AgentStore.shared.codexThreads where t.running {
        var row: [String: Any] = ["agent": "Codex", "thread": t.id, "title": t.title, "project": t.project ?? "", "busy": true]
        if let stall = watch.stall(thread: t) { row["stall"] = stallJSON(stall) }
        out.append(row)
      }
      reply(["sessions": out, "threshold_minutes": Preferences.shared.stallMinutes])

    default: reply(["error": "unknown operation \(op)"])
    }
  }

  // MARK: profiles

  private static func findProfile(_ args: [String: Any]) -> EnvProfile? {
    let key = (args["name"] as? String ?? args["id"] as? String ?? "").lowercased()
    return ProfileStore.shared.profiles.first { $0.name.lowercased() == key || $0.id.uuidString.lowercased() == key }
  }
  private static func withProfile(_ args: [String: Any], _ reply: @escaping Reply, _ body: (EnvProfile) -> Void) {
    guard let p = findProfile(args) else {
      return reply(["error": "no such profile; list_profiles shows the names"])
    }
    body(p)
  }
  private static func createProfile(_ args: [String: Any], _ reply: Reply) {
    let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let folder = (args["folder"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    var isDir: ObjCBool = false
    guard !name.isEmpty else { return reply(["error": "name is required"]) }
    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
      return reply(["error": "folder must be an existing directory (absolute path)"])
    }
    let store = ProfileStore.shared
    let replace = args["replace"] as? Bool ?? false
    if let existing = store.profiles.first(where: { $0.name.lowercased() == name.lowercased() }), !replace {
      return reply(["error": "a profile named \(existing.name) exists; pass replace: true to overwrite it"])
    }
    let commands = (args["commands"] as? [[String: Any]] ?? []).compactMap { c -> ProfileCommand? in
      guard let command = (c["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty else { return nil }
      let stop = (c["stop_command"] as? String)?.trimmingCharacters(in: .whitespaces)
      return ProfileCommand(
        name: (c["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cmd", command: command,
        stopCommand: stop?.isEmpty == false ? stop : nil)
    }
    let containers = args["containers"] as? [String] ?? []
    guard !commands.isEmpty || !containers.isEmpty else {
      return reply(["error": "give at least one command or container"])
    }
    var profile = EnvProfile(name: name, folder: folder, commands: commands, containers: containers)
    if let i = store.profiles.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
      profile.id = store.profiles[i].id
      store.profiles[i] = profile
    } else {
      store.profiles.append(profile)
    }
    reply(profileJSON(profile))
  }
  private static func profileJSON(_ p: EnvProfile) -> [String: Any] {
    let store = ProfileStore.shared
    let containers = ContainerStore.shared.report?.containers ?? []
    return [
      "id": p.id.uuidString, "name": p.name, "folder": p.folder, "active": store.active.contains(p.id),
      "commands": p.commands.map { c -> [String: Any] in
        var row: [String: Any] = ["name": c.name, "command": c.command, "running": false]
        if let stop = c.stopCommand { row["stop_command"] = stop }
        switch store.state(c, in: p) {
        case .completed: row["state"] = "completed (exit 0)"
        case .failed(let status, _): row["state"] = "failed (exit \(status))"
        case .running: row["state"] = "running"
        case .idle: row["state"] = "not started"
        }
        let members = store.members(c)
        if store.running(c) != nil {
          row["running"] = true
          row["processes"] = members.map { ["pid": $0.pid, "name": $0.name] }
          row["ports"] = members.flatMap(\.ports).map(\.port)
        }
        return row
      },
      "containers": p.containers.map { name -> [String: Any] in
        let c = containers.first { $0.name == name }
        return ["name": name, "state": c?.state ?? "not found"]
      },
    ]
  }

  // MARK: services, machines, cleanup

  private static func findService(_ args: [String: Any]) -> HealthCheck? {
    let key = (args["name"] as? String ?? args["target"] as? String ?? "").lowercased()
    return HealthStore.shared.checks.first { $0.name.lowercased() == key || $0.target.lowercased() == key }
  }
  private static func serviceJSON(_ c: HealthCheck) -> [String: Any] {
    var row: [String: Any] = ["name": c.name, "target": c.target]
    if let r = HealthStore.shared.results[c.id] {
      row["status"] = ["up", "answered with an error", "down"][r.level.rawValue]
      row["detail"] = r.detail
      row["latency_ms"] = r.latency.map { ($0 * 10).rounded() / 10 } ?? NSNull()
      row["checked_at"] = ISO8601DateFormatter().string(from: r.at)
    } else {
      row["status"] = "not checked yet"
    }
    return row
  }
  private static func machineJSON(_ host: String) -> [String: Any] {
    var row: [String: Any] = ["host": host]
    guard let state = MachineStore.shared.states[host] else { return row }
    if let error = state.error { row["error"] = error }
    if let s = state.stats {
      row["os"] = "\(s.os) \(s.kernel)"
      row["hostname"] = s.host
      row["load"] = s.load
      row["cpus"] = s.cpus
      row["uptime_seconds"] = s.uptime ?? NSNull()
      row["memory_total"] = s.memoryTotal ?? NSNull()
      row["memory_available"] = s.memoryAvailable ?? NSNull()
      row["disk_total"] = s.diskTotal ?? NSNull()
      row["disk_used"] = s.diskUsed ?? NSNull()
      row["containers"] = s.containers ?? NSNull()
      row["top_processes"] = s.processes.map { ["name": $0.name, "cpu_percent": $0.cpu, "memory_percent": $0.memory] }
    }
    row["read_at"] = ISO8601DateFormatter().string(from: state.at)
    return row
  }
  private static func waitForMachines(_ reply: @escaping Reply, attempts: Int = 0, _ value: @escaping () -> [String: Any]) {
    if MachineStore.shared.probing.isEmpty || attempts > 34 { return reply(value()) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForMachines(reply, attempts: attempts + 1, value) }
  }
  private static func cleanupJSON() -> [String: Any] {
    let store = CleanupStore.shared
    guard let report = store.report, let at = store.scannedAt else {
      return ["scanned": false, "note": "No scan yet: call scan_dev_space."]
    }
    var out: [String: Any] = [
      "scanned_at": ISO8601DateFormatter().string(from: at),
      "reclaimable_bytes": report.items.filter { $0.busy == nil }.reduce(0) { $0 + $1.bytes },
      "items": report.items.map { i -> [String: Any] in
        [
          "id": i.id, "kind": i.kind, "group": i.group, "name": i.name, "path": i.path, "bytes": i.bytes,
          "modified": i.modified > 0 ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: i.modified)) : NSNull(),
          "in_use_by": i.busy ?? NSNull(), "removed_by": i.isDocker ? "docker (permanent)" : "trash (recoverable)",
        ]
      },
    ]
    if let stale = store.staleness(roots: Preferences.shared.cleanupRoots) { out["stale"] = stale }
    return out
  }
  private static func stallJSON(_ stall: AgentStall) -> [String: Any] {
    let kind: String
    switch stall {
    case .longCommand: kind = "long command"
    case .waiting: kind = "waiting on a command (maybe input)"
    case .silent: kind = "no activity"
    }
    return ["kind": kind, "minutes": stall.minutes, "summary": stall.summary, "suspicious": stall.suspicious]
  }
}

/// The preferences agents may read and change: notifications, thresholds and cleanup folders.
/// Anything that reaches outside the Mac or edits another app's files stays with the user.
enum AgentSettings {
  private static let bools: [String: ReferenceWritableKeyPath<Preferences, Bool>] = [
    "notify_orphans": \.notifyOrphans, "notify_heavy_processes": \.notifyHeavy,
    "notify_memory_pressure": \.notifyPressure, "notify_stuck_agents": \.notifyStalls,
    "notify_service_down": \.notifyServiceDown, "notify_agent_battery_drain": \.notifyAgentDrain,
  ]
  private static let numbers: [String: (ReferenceWritableKeyPath<Preferences, Double>, ClosedRange<Double>)] = [
    "stuck_agent_minutes": (\.stallMinutes, 1...240), "agent_drain_watts": (\.drainWatts, 0.5...50),
    "heavy_memory_gb": (\.notifyMemoryGB, 0.5...64), "heavy_cpu_percent": (\.notifyCPU, 50...1600),
    "heavy_sustain_seconds": (\.notifySustain, 15...3600),
  ]
  static func read() -> [String: Any] {
    let p = Preferences.shared
    var out: [String: Any] = [:]
    for (k, path) in bools { out[k] = p[keyPath: path] }
    for (k, (path, _)) in numbers { out[k] = p[keyPath: path] }
    out["cleanup_folders"] = p.cleanupRoots
    return out
  }
  static func write(_ key: String, _ value: Any?) -> String? {
    let p = Preferences.shared
    if let path = bools[key] {
      guard let v = value as? Bool else { return "\(key) takes true or false" }
      p[keyPath: path] = v
      if v { Notifier.shared.activate() }
      return nil
    }
    if let (path, range) = numbers[key] {
      guard let v = (value as? NSNumber)?.doubleValue, range.contains(v) else {
        return "\(key) takes a number between \(range.lowerBound) and \(range.upperBound)"
      }
      p[keyPath: path] = v
      return nil
    }
    if key == "cleanup_folders" {
      guard let folders = value as? [String] else { return "cleanup_folders takes a list of absolute paths" }
      var isDir: ObjCBool = false
      let bad = folders.filter { !FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) || !isDir.boolValue }
      guard bad.isEmpty else { return "not folders: \(bad.joined(separator: ", "))" }
      p.cleanupRoots = folders
      return nil
    }
    return "unknown or protected setting; readable keys: \(read().keys.sorted().joined(separator: ", "))"
  }
}
