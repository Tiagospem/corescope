import Foundation

/// Reads the Codex account's rate limits through Codex's own app-server (`codex app-server`,
/// JSON-RPC over stdio, method `account/rateLimits/read`) — the same call the Codex app makes.
/// Codex performs the request with its own login; CoreScope never reads credentials. Opt-in,
/// because it makes Codex contact OpenAI. Newer Codex versions no longer write `rate_limits`
/// events to local session logs, so this is the only source that stays current.
enum CodexAppServer {
  /// Native Codex binaries first (a node-based `codex` needs a shell PATH a GUI app lacks).
  static var binary: URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
      "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
      "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  /// Blocking: call from a background queue. Nil when Codex is missing, signed out or slow.
  static func readLimits(timeout: TimeInterval = 20) -> CodexUsage? {
    guard let binary else { return nil }
    let process = Process()
    process.executableURL = binary
    process.arguments = ["app-server"]
    var env = ProcessInfo.processInfo.environment
    // Same as Codex's own launcher: use the ChatGPT login, not API keys from the environment.
    for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL"] {
      env[key] = nil
    }
    process.environment = env
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var buffer = Data()
    var result: [String: Any]?
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock()
      defer { lock.unlock() }
      guard result == nil else { return }
      if chunk.isEmpty {
        done.signal()
        return
      }
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          object["id"] as? Int == 2
        else { continue }
        result = (object["result"] as? [String: Any]) ?? [:]
        done.signal()
        return
      }
    }
    do { try process.run() } catch { return nil }
    let messages = [
      #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"corescope","title":"CoreScope","version":"1"}}}"#,
      #"{"method":"initialized"}"#,
      #"{"id":2,"method":"account/rateLimits/read"}"#,
    ]
    input.fileHandleForWriting.write(Data((messages.joined(separator: "\n") + "\n").utf8))
    _ = done.wait(timeout: .now() + timeout)
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if process.isRunning { process.terminate() }
    lock.lock()
    let response = result
    lock.unlock()
    return response.flatMap(parse)
  }

  /// `rateLimits.primary/secondary` → windows; plan, credit balance and free reset credits.
  static func parse(_ result: [String: Any]) -> CodexUsage? {
    guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
    var usage = CodexUsage(observedAt: Date(), live: true)
    for key in ["primary", "secondary"] {
      guard let w = limits[key] as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue
      else { continue }
      let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0
      let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
      usage.windows.append(LimitWindow(id: key, usedPercent: used, windowMinutes: minutes, resetsAt: reset))
    }
    guard !usage.windows.isEmpty else { return nil }
    usage.plan = limits["planType"] as? String
    if let credits = limits["credits"] as? [String: Any], let balance = credits["balance"] as? String,
      let value = Double(balance), !Demo.enabled
    {
      usage.credits = String(format: "%.0f", value)
    }
    if let resets = result["rateLimitResetCredits"] as? [String: Any] {
      usage.resetCredits = (resets["availableCount"] as? NSNumber)?.intValue
    }
    return usage
  }
}
