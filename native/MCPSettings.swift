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
  @ViewState private var hooks: [String: Bool] = [:]
  @ViewState private var codexTrust: [String: String]?
  @ObservedObject var prefs = Preferences.shared
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
      Toggle(L("Agentes podem usar o app pelo MCP"), isOn: $prefs.mcpAppAccess)
      AgentHooksTable(hooks: hooks, codexTrust: codexTrust) { hook, host, on in
        queue.async {
          let failure = AgentHooksBridge.set(hook, in: host, on)
          let now = AgentHooksBridge.installed(hook, in: host)
          let trust = host == .codex ? CodexAppServer.coreScopeHookTrust() : nil
          DispatchQueue.main.async {
            hooks[hookKey(hook, host)] = now
            if host == .codex { codexTrust = trust }
            error = failure.map { "\(host.rawValue): \($0)" }
          }
        }
      }
      Text(
        L("Perfis (criar, iniciar, parar, logs), Serviços, Máquinas, limpeza (analisar e mover para a Lixeira o que a análise encontrou) e ajustes de notificação. Pelo socket local do app, só para o seu usuário. O agente pede a sua aprovação antes de cada ação.")
      ).font(.caption).foregroundStyle(.secondary)
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
      var installed: [String: Bool] = [:]
      for host in HookHost.allCases {
        for hook in AgentHook.allCases { installed[hookKey(hook, host)] = AgentHooksBridge.installed(hook, in: host) }
      }
      // Codex's own view of their trust, only when one of CoreScope's hooks is there to ask about.
      let trust = AgentHook.allCases.contains { installed[hookKey($0, .codex)] == true } ? CodexAppServer.coreScopeHookTrust() : nil
      DispatchQueue.main.async {
        hooks = installed
        codexTrust = trust
      }
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

func hookKey(_ hook: AgentHook, _ host: HookHost) -> String { "\(host.rawValue)-\(hook.rawValue)" }

/// Which CoreScope hooks each agent has, with a switch per cell, and Codex's trust step.
private struct AgentHooksTable: View {
  let hooks: [String: Bool]
  let codexTrust: [String: String]?
  let set: (AgentHook, HookHost, Bool) -> Void
  /// Separate Form rows (a Grid inside one row mis-measures its height).
  var body: some View {
    ForEach(AgentHook.allCases, id: \.self) { hook in
      VStack(alignment: .leading, spacing: 6) {
        Text(title(hook))
        Text(detail(hook)).font(.caption).foregroundStyle(.secondary)
        HStack(spacing: 18) {
          ForEach(HookHost.allCases) { host in
            Toggle(host.rawValue, isOn: Binding(get: { hooks[hookKey(hook, host)] == true }, set: { set(hook, host, $0) }))
              .toggleStyle(.switch).controlSize(.small).disabled(!host.available)
              .help(host.available ? host.shortPath : L("%@ não está configurado neste Mac", host.rawValue))
          }
        }
      }
      .padding(.vertical, 2)
    }
    if AgentHook.allCases.contains(where: { hooks[hookKey($0, .codex)] == true }) { codexNote }
    Text(L("Os hooks rodam o corescope deste app; cada arquivo ganha um backup antes de mudar e só as entradas do CoreScope são mexidas. Agentes sem hooks recebem o mesmo pelo MCP (agent_context) ou pela seção no CLAUDE.md / AGENTS.md de cada projeto."))
      .font(.caption).foregroundStyle(.secondary)
  }
  private func title(_ hook: AgentHook) -> String {
    hook == .context ? L("Contexto do projeto no início da sessão") : L("Esperar folga antes de comandos pesados")
  }
  private func detail(_ hook: AgentHook) -> String {
    hook == .context
      ? L("O agente recebe o que o .corescope.yml pede: capacidade, portas, perfis, serviços e logs.")
      : L("Builds e testes esperam CPU e memória normalizarem nos projetos com agents.wait_for_capacity.")
  }
  /// Codex runs a user hook only after it is reviewed in its /hooks screen.
  @ViewBuilder private var codexNote: some View {
    let states = AgentHook.allCases.filter { hooks[hookKey($0, .codex)] == true }
      .map { codexTrust?[$0 == .gate ? "preToolUse" : "sessionStart"] }
    let trusted = states.allSatisfy { $0 == "trusted" || $0 == "managed" }
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: trusted ? "checkmark.seal.fill" : "hand.raised.fill").foregroundStyle(trusted ? .green : .orange)
      if codexTrust == nil {
        Text(L("O Codex só roda hooks que você aprovou: abra o Codex, digite /hooks e confie nos do CoreScope (de novo se o app mudar de lugar)."))
      } else if trusted {
        Text(L("O Codex confia nos hooks do CoreScope."))
      } else {
        Text(L("O Codex ainda não roda estes hooks: abra o Codex, digite /hooks e confie nos do CoreScope. Depois disso eles rodam em toda sessão."))
      }
    }
    .font(.caption)
  }
}
