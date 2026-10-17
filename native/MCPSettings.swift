import Foundation
import SwiftUI

/// Registers `corescope mcp` with Claude Code and Codex through their own CLIs
/// (`claude mcp add --scope user`, `codex mcp add`). Off until the user turns it on per agent.
enum MCPRegistration {
  enum Agent: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"
    var id: String { rawValue }
  }
  enum State: Equatable {
    case missingCLI, off, on, otherCopy(String)
  }
  static let name = "corescope"
  private static let home = FileManager.default.homeDirectoryForCurrentUser.path
  /// The command registered: the CLI inside this app bundle.
  static var command: String? { CommandLineTool.bundled?.path }

  static func cli(_ agent: Agent) -> String? {
    let fm = FileManager.default
    switch agent {
    case .codex:
      return CodexAppServer.binary?.path
    case .claude:
      let fixed = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
      if let path = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) { return path }
      // The copy Claude Desktop keeps for its Code sessions (newest version).
      let base = "\(home)/Library/Application Support/Claude/claude-code"
      let versions = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted {
        $0.compare($1, options: .numeric) == .orderedDescending
      }
      for version in versions {
        for build in (try? fm.contentsOfDirectory(atPath: "\(base)/\(version)")) ?? [] {
          let path = "\(base)/\(version)/\(build)/claude.app/Contents/MacOS/claude"
          if fm.isExecutableFile(atPath: path) { return path }
        }
      }
      return nil
    }
  }

  /// Blocking (runs the agent's CLI or reads its config): call from a background queue.
  static func state(_ agent: Agent) -> State {
    guard let cli = cli(agent) else { return .missingCLI }
    let registered: String?
    switch agent {
    case .claude:
      let (code, output) = run(cli, ["mcp", "get", name])
      registered = code == 0 ? output : nil
    case .codex:
      let config = (try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8)) ?? ""
      registered = config.range(of: "[mcp_servers.\(name)]").map { String(config[$0.lowerBound...].prefix(600)) }
    }
    guard let registered else { return .off }
    if let command, registered.contains(command) { return .on }
    let path = registered.components(separatedBy: .newlines)
      .first { $0.contains("corescope") && ($0.contains("/") || $0.contains("command")) } ?? ""
    return .otherCopy(path.trimmingCharacters(in: .whitespaces))
  }

  /// Adds (replacing any previous registration) or removes the server. Returns an error message.
  static func set(_ agent: Agent, enabled: Bool) -> String? {
    guard let cli = cli(agent) else { return L("CLI do agente não encontrado.") }
    if agent == .codex {
      // `codex mcp add/remove` rewrites config.toml with its own formatter: keep the user's copy once.
      let config = "\(home)/.codex/config.toml", backup = config + ".corescope.bak"
      if !FileManager.default.fileExists(atPath: backup) { try? FileManager.default.copyItem(atPath: config, toPath: backup) }
    }
    let remove: [String] = agent == .claude ? ["mcp", "remove", "--scope", "user", name] : ["mcp", "remove", name]
    _ = run(cli, remove)
    guard enabled else { return nil }
    guard let command else { return L("Comando corescope não encontrado no app.") }
    let add: [String] =
      agent == .claude
      ? ["mcp", "add", "--scope", "user", name, "--", command, "mcp"]
      : ["mcp", "add", name, "--", command, "mcp"]
    let (code, output) = run(cli, add)
    return code == 0 ? nil : output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL"] { env[key] = nil }
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

struct MCPSettings: View {
  @ViewState private var states: [MCPRegistration.Agent: MCPRegistration.State] = [:]
  @ViewState private var busy = Set<MCPRegistration.Agent>()
  @ViewState private var error: String?
  private let queue = DispatchQueue(label: "app.corescope.mcp", qos: .userInitiated)
  var body: some View {
    Section(L("Servidor MCP para agentes")) {
      ForEach(MCPRegistration.Agent.allCases) { agent in
        LabeledContent(agent.rawValue) {
          HStack(spacing: 8) {
            if busy.contains(agent) {
              ProgressView().controlSize(.small)
            } else {
              status(states[agent])
            }
            switch states[agent] {
            case .on:
              Button(L("Desativar")) { toggle(agent, false) }
            case .off, .otherCopy:
              Button(L("Ativar")) { toggle(agent, true) }.disabled(MCPRegistration.command == nil)
            default:
              EmptyView()
            }
          }
        }
      }
      Text(
        L("Opcional. Registra corescope mcp no Claude Code e no Codex (pelos comandos mcp add deles). Os agentes podem consultar portas, porta livre, maiores processos, sessões e órfãos, e encerrar só o que a própria sessão iniciou — nunca outras sessões, outros usuários ou serviços do sistema. Tudo local, sem rede.")
      ).font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
    .onAppear(perform: reload)
  }
  @ViewBuilder private func status(_ state: MCPRegistration.State?) -> some View {
    switch state {
    case .on: Label(L("Ativo"), systemImage: "checkmark.circle.fill").foregroundStyle(Tint.brand)
    case .off: Text(L("Desativado")).foregroundStyle(.secondary)
    case .missingCLI: Text(L("Não instalado")).foregroundStyle(.secondary)
    case .otherCopy: Label(L("Aponta para outra cópia do app"), systemImage: "exclamationmark.triangle")
      .foregroundStyle(.orange)
    case nil: ProgressView().controlSize(.small)
    }
  }
  private func reload() {
    queue.async {
      var next: [MCPRegistration.Agent: MCPRegistration.State] = [:]
      for agent in MCPRegistration.Agent.allCases { next[agent] = MCPRegistration.state(agent) }
      DispatchQueue.main.async { states = next }
    }
  }
  private func toggle(_ agent: MCPRegistration.Agent, _ enabled: Bool) {
    busy.insert(agent)
    queue.async {
      let failure = MCPRegistration.set(agent, enabled: enabled)
      let state = MCPRegistration.state(agent)
      DispatchQueue.main.async {
        busy.remove(agent)
        states[agent] = state
        error = failure.map { "\(agent.rawValue): \($0)" }
      }
    }
  }
}
