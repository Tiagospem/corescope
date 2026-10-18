import Foundation

/// Opt-in bridge to the Claude Code status line, the documented place where Claude Code exposes
/// plan usage (`rate_limits.five_hour` / `seven_day`). CoreScope installs a small shell command as
/// the status line; on each Claude Code reply it saves only `rate_limits` to Application Support,
/// and CoreScope reads that file. No Keychain, no credentials, no network.
///
/// Nothing here runs unless the user turns the option on; turning it off restores the
/// statusLine exactly as it was (a backup of settings.json is kept before every change).
enum ClaudeLimitsBridge {
  private static let home = FileManager.default.homeDirectoryForCurrentUser
  static let support = home.appendingPathComponent("Library/Application Support/CoreScope")
  static let script = support.appendingPathComponent("claude-statusline.sh")
  static let limitsFile = support.appendingPathComponent("claude-limits.json")
  private static let stateFile = support.appendingPathComponent("claude-statusline-state.json")
  private static let enabledFile = support.appendingPathComponent("claude-statusline-enabled")
  private static let backups = support.appendingPathComponent("backups")
  /// Follows a dotfiles symlink so the real file is edited and the link survives.
  static var settingsFile: URL {
    home.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
  }

  enum Failure: Error {
    case unreadable
    case notObject
    case changedSince
    case io(String)
    var message: String {
      switch self {
      case .unreadable: L("~/.claude/settings.json não é um JSON válido; nada foi alterado.")
      case .notObject: L("~/.claude/settings.json não é um objeto JSON; nada foi alterado.")
      case .changedSince:
        L("O statusLine mudou desde que o CoreScope o instalou; ele foi mantido como está.")
      case .io(let detail): L("Não foi possível gravar: %@", detail)
      }
    }
  }

  /// The status line itself: saves `rate_limits` (only when present: Pro/Max plans, after the
  /// first reply) and prints model + usage, or with `--record` passes stdin through to a chained
  /// command. `LC_ALL=C` keeps printf's decimal point independent of the user's locale.
  static let scriptText = #"""
    #!/bin/sh
    # CoreScope: saves Claude Code's plan usage (rate_limits) for the CoreScope monitor.
    # Installed from CoreScope > Settings > Agents; turning that option off removes it.
    # Reads the status line JSON on stdin, keeps only rate_limits, never uses the network.
    export LC_ALL=C
    umask 077
    dir="$HOME/Library/Application Support/CoreScope"
    input=$(cat; printf '.')
    input=${input%.}
    if [ -f "$dir/claude-statusline-enabled" ]; then
      limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
      if [ -n "$limits" ]; then
        file="$dir/claude-limits.json"
        if [ "$(cat "$file" 2>/dev/null)" = "$limits" ]; then
          touch "$file"
        else
          mkdir -p "$dir" && printf '%s' "$limits" > "$file.$$" && mv -f "$file.$$" "$file"
        fi
      fi
    fi
    if [ "$1" = "--record" ]; then
      printf '%s' "$input"
      exit 0
    fi
    pct() {
      v=$(printf '%s' "$input" | /usr/bin/plutil -extract "rate_limits.$1.used_percentage" raw -o - - 2>/dev/null) &&
        printf '%s %.0f%%' "$2" "$v"
    }
    line=$(printf '%s' "$input" | /usr/bin/plutil -extract model.display_name raw -o - - 2>/dev/null)
    for part in "$(pct five_hour 5h)" "$(pct seven_day 7d)"; do
      [ -n "$part" ] && line="${line:+$line · }$part"
    done
    printf '%s\n' "$line"

    """#

  /// Current link, read only when the option is on. nil when settings.json cannot be parsed.
  static func currentLink() -> ClaudeStatusLine.Link? {
    guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { return .absent }
    guard let settings = try? OrderedJSON.parse(text) else { return nil }
    return ClaudeStatusLine.link(of: settings, script: script.path)
  }

  /// Installs the status line when none exists, or chains in front of the user's own when
  /// `chain` is true (an explicit second step). An existing status line is otherwise untouched.
  static func enable(chain: Bool) -> Result<ClaudeStatusLine.Link, Failure> {
    do {
      try writeScript()
      let file = settingsFile
      let existed = FileManager.default.fileExists(atPath: file.path)
      let text = existed ? try String(contentsOf: file, encoding: .utf8) : "{}\n"
      guard let settings = try? OrderedJSON.parse(text) else { return .failure(.unreadable) }
      guard case .object = settings else { return .failure(.notObject) }
      let link = ClaudeStatusLine.link(of: settings, script: script.path)
      if link == .installed || link == .chained {
        try write("", to: enabledFile)
        return .success(link)
      }
      let previous = settings["statusLine"]
      guard let installed = ClaudeStatusLine.installing(over: previous, script: script.path, chain: chain)
      else { return .success(link) }
      if existed { try backup(text) }
      var state: [OrderedJSON.Member] = [
        .init(key: "installed", value: installed), .init(key: "fileExisted", value: .bool(existed)),
      ]
      if let previous { state.insert(.init(key: "previous", value: previous), at: 0) }
      try write(OrderedJSON.object(state).serialized() + "\n", to: stateFile)
      try write(settings.setting("statusLine", installed).serialized() + trailing(text), to: file)
      try write("", to: enabledFile)
      return .success(ClaudeStatusLine.link(of: settings.setting("statusLine", installed), script: script.path))
    } catch let failure as Failure {
      return .failure(failure)
    } catch {
      return .failure(.io(error.localizedDescription))
    }
  }

  /// Puts back the statusLine CoreScope replaced (or removes the one it added) and deletes the
  /// saved limits. A statusLine the user edited since is left alone.
  static func disable() -> Result<ClaudeStatusLine.Link, Failure> {
    defer { try? FileManager.default.removeItem(at: enabledFile) }
    defer { try? FileManager.default.removeItem(at: limitsFile) }
    do {
      let file = settingsFile
      guard let stateText = try? String(contentsOf: stateFile, encoding: .utf8),
        let state = try? OrderedJSON.parse(stateText), let installed = state["installed"]
      else {
        removeScriptIfUnused()
        return .success(currentLink() ?? .absent)
      }
      guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        if !FileManager.default.fileExists(atPath: file.path), state["fileExisted"] == .bool(false) {
          try FileManager.default.removeItem(at: stateFile)
          removeScriptIfUnused()
          return .success(.absent)
        }
        return .failure(.io("Could not read ~/.claude/settings.json"))
      }
      guard let settings = try? OrderedJSON.parse(text) else { return .failure(.unreadable) }
      guard case .object = settings else { return .failure(.notObject) }
      guard settings["statusLine"] == installed else {
        try? FileManager.default.removeItem(at: stateFile)
        removeScriptIfUnused()
        return .failure(.changedSince)
      }
      try backup(text)
      let restored = settings.setting("statusLine", state["previous"])
      if state["fileExisted"] == .bool(false), restored == .object([]) {
        try FileManager.default.removeItem(at: file)
      } else {
        try write(restored.serialized() + trailing(text), to: file)
      }
      try? FileManager.default.removeItem(at: stateFile)
      removeScriptIfUnused()
      return .success(ClaudeStatusLine.link(of: restored, script: script.path))
    } catch let failure as Failure {
      return .failure(failure)
    } catch {
      return .failure(.io(error.localizedDescription))
    }
  }

  static func trailing(_ original: String) -> String { original.hasSuffix("\n") ? "\n" : "" }
  private static func writeScript() throws {
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    if (try? String(contentsOf: script, encoding: .utf8)) != scriptText {
      try scriptText.write(to: script, atomically: true, encoding: .utf8)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  }
  /// Keeps the script while any status line (for example a hand-made chain) still calls it.
  private static func removeScriptIfUnused() {
    guard let text = try? String(contentsOf: settingsFile, encoding: .utf8),
      let settings = try? OrderedJSON.parse(text), case .object = settings
    else { return }
    if !referencesScript(settings) { try? FileManager.default.removeItem(at: script) }
  }
  private static func referencesScript(_ value: OrderedJSON) -> Bool {
    switch value {
    case .object(let members): members.contains { referencesScript($0.value) }
    case .array(let values): values.contains { referencesScript($0) }
    case .string(let string): string.contains(script.lastPathComponent)
    case .number, .bool, .null: false
    }
  }
  /// settings-<timestamp>.json next to the other CoreScope files; the newest 10 are kept.
  static func backup(_ text: String, prefix: String = "settings") throws {
    let fm = FileManager.default
    try fm.createDirectory(at: backups, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    try write(text, to: backups.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString).json"))
    let old = ((try? fm.contentsOfDirectory(
      at: backups, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
      .sorted {
        let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return left < right
      }.dropLast(10)
    for file in old { try? fm.removeItem(at: file) }
  }
  /// Atomic replace that keeps the original file's permissions (settings.json is often 0600).
  static func write(_ text: String, to url: URL) throws {
    let fm = FileManager.default
    let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: url.path)
  }
}
