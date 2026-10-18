import Foundation

/// Reads the current Claude plan limits through Claude Code's own `/usage` command
/// (`claude -p /usage`), the same numbers Claude Code and Claude Desktop show. Claude Code asks
/// Anthropic with its own login; CoreScope never reads credentials and makes no request itself.
/// It is a local command: no model turn, no tokens spent. Opt-in, because it makes Claude Code
/// contact Anthropic. The status line and Claude Desktop's samples only refresh while those are
/// in use, so this is the source that stays current.
enum ClaudeUsageCLI {
  private static let home = FileManager.default.homeDirectoryForCurrentUser.path
  /// Native builds only (an npm `claude` is a node script that needs a shell PATH a GUI app
  /// lacks), then the copy Claude Desktop ships for its Code tab.
  static var binary: URL? { locate() }
  /// Checked once, for the interface (locating lists Claude Desktop's folders).
  static let available = locate() != nil
  private static func locate() -> URL? {
    let fm = FileManager.default
    let installed = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if let path = installed.first(where: { fm.isExecutableFile(atPath: $0) && !isScript($0) }) {
      return URL(fileURLWithPath: path)
    }
    let bundled = "\(home)/Library/Application Support/Claude/claude-code"
    let versions = ((try? fm.contentsOfDirectory(atPath: bundled)) ?? [])
      .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    for version in versions {
      for build in (try? fm.contentsOfDirectory(atPath: "\(bundled)/\(version)")) ?? [] {
        let path = "\(bundled)/\(version)/\(build)/claude.app/Contents/MacOS/claude"
        if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
      }
    }
    return nil
  }
  private static func isScript(_ path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return true }
    defer { try? handle.close() }
    return handle.readData(ofLength: 2) == Data("#!".utf8)
  }
  /// Claude Code keeps per-folder state; one fixed folder of CoreScope's keeps it to one entry.
  private static let folder = URL(fileURLWithPath: "\(home)/Library/Application Support/CoreScope/claude-usage")

  private static let lock = NSLock()
  private static var running: Int32 = 0
  /// Pid of the `claude` CoreScope is running right now, kept out of the agent session lists.
  static var runningPID: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  /// Blocking: call from a background queue. Nil when Claude Code is missing, signed out (or on
  /// an API key, which has no plan limits) or slow.
  static func readLimits(timeout: TimeInterval = 45) -> ClaudeUsage? {
    guard let binary else { return nil }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = binary
    // No session saved, no hooks (the user's or CoreScope's own), no MCP servers started.
    process.arguments = [
      "-p", "/usage", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config",
      "--settings", #"{"disableAllHooks":true}"#,
    ]
    process.currentDirectoryURL = folder
    var env = ProcessInfo.processInfo.environment
    // Plan limits belong to the claude.ai login, not to API keys in the environment.
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
      env[key] = nil
    }
    process.environment = env
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let lockData = NSLock()
    var data = Data()
    let done = DispatchSemaphore(value: 0)
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lockData.lock()
      defer { lockData.unlock() }
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        done.signal()
      } else if data.count < 256 * 1024 {
        data.append(chunk)
      }
    }
    do { try process.run() } catch { return nil }
    lock.lock()
    running = process.processIdentifier
    lock.unlock()
    defer {
      lock.lock()
      running = 0
      lock.unlock()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      output.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      return nil
    }
    process.waitUntilExit()
    lockData.lock()
    let reply = data
    lockData.unlock()
    guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
      object["is_error"] as? Bool != true, let text = object["result"] as? String
    else { return nil }
    let now = Date()
    let windows = parseClaudeUsageText(text, now: now).map {
      LimitWindow(id: $0.id, usedPercent: $0.usedPercent, windowMinutes: $0.windowMinutes, resetsAt: $0.resetsAt)
    }
    return windows.isEmpty ? nil : ClaudeUsage(windows: windows, observedAt: now, source: "claude-code")
  }
}
