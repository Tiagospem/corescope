import AppKit
import Security
import SwiftUI

/// Commit messages written by a model (opt-in, off by default). The only thing sent is the
/// staged diff — lockfiles and binaries left out, cut at a size limit — with the repository's
/// name, branch and file list. The message fills the field; committing stays a click of yours.
///
/// Providers: an agent already signed in on this Mac (Claude Code `claude -p`, Codex
/// `codex exec`, no key needed), a provider's API (OpenAI, Anthropic, Gemini; the key lives in
/// the Keychain only), or a local server (Ollama, LM Studio). Model names are free text with
/// suggestions, since providers rename them.
enum AIProvider: String, CaseIterable, Identifiable {
  case claudeCLI = "claude-cli"
  case codexCLI = "codex-cli"
  case anthropic
  case openai
  case gemini
  case ollama
  case lmstudio
  var id: String { rawValue }
  var title: String {
    switch self {
    case .claudeCLI: L("Claude Code instalado (claude -p)")
    case .codexCLI: L("Codex instalado (codex exec)")
    case .anthropic: "Anthropic API"
    case .openai: "OpenAI API"
    case .gemini: "Gemini API"
    case .ollama: L("Ollama (local)")
    case .lmstudio: L("LM Studio (local)")
    }
  }
  var needsKey: Bool { self == .anthropic || self == .openai || self == .gemini }
  var isLocalServer: Bool { self == .ollama || self == .lmstudio }
  /// Fast, inexpensive models at the time of writing; the field takes any name.
  var suggestions: [String] {
    switch self {
    case .claudeCLI: ["haiku", "sonnet"]
    case .codexCLI: []
    case .anthropic: ["claude-haiku-5-5", "claude-sonnet-5-5"]
    case .openai: ["gpt-6-luna", "gpt-6-astra"]
    case .gemini: ["gemini-3.5-flash-lite", "gemini-3.8-flash"]
    case .ollama: ["qwen3:8b", "llama3.2:3b"]
    case .lmstudio: []
    }
  }
  var defaultBaseURL: String { self == .ollama ? "http://localhost:11434" : "http://localhost:1234" }
  /// Where to get a key, for the help line.
  var keyHelp: String {
    switch self {
    case .anthropic: L("Crie uma chave em platform.claude.com › API keys.")
    case .openai: L("Crie uma chave em platform.openai.com › API keys.")
    case .gemini: L("Crie uma chave em aistudio.google.com › Get API key.")
    case .claudeCLI: L("Usa o login do próprio Claude Code; nenhuma chave aqui.")
    case .codexCLI: L("Usa o login do próprio Codex; nenhuma chave aqui.")
    case .ollama, .lmstudio: L("Roda no seu Mac; nada sai da máquina.")
    }
  }
  /// Whether the request leaves this Mac.
  var sendsOut: Bool { !isLocalServer }
}

/// AI settings (UserDefaults; never the key).
final class AISettings: ObservableObject {
  static let shared = AISettings()
  private let d = UserDefaults.standard
  @Published var enabled: Bool { didSet { d.set(enabled, forKey: "ai.enabled") } }
  @Published var provider: AIProvider { didSet { d.set(provider.rawValue, forKey: "ai.provider") } }
  @Published var models: [String: String] { didSet { d.set(models, forKey: "ai.models") } }
  @Published var baseURLs: [String: String] { didSet { d.set(baseURLs, forKey: "ai.baseURLs") } }
  @Published var instructions: String { didSet { d.set(instructions, forKey: "ai.instructions") } }
  /// "auto" follows the app's language.
  @Published var language: String { didSet { d.set(language, forKey: "ai.language") } }
  @Published var maxDiffKB: Int { didSet { d.set(maxDiffKB, forKey: "ai.maxDiffKB") } }
  /// Providers the user agreed to send a diff to, after seeing what goes.
  @Published var consented: [String] { didSet { d.set(consented, forKey: "ai.consented") } }

  static let defaultInstructions = """
    Write a git commit message for the staged changes below, following Conventional Commits: \
    a title line "type(scope): summary" of at most 72 characters (types: feat, fix, refactor, \
    docs, test, chore, perf, build, ci, style), a blank line, then a short body of plain \
    sentences or "- " bullets saying what changed and why, wrapped at 72 columns. Leave the body \
    out when the title says it all. Describe only what the diff shows. Reply with the message \
    only: no quotes, no code fences, no preamble.
    """

  private init() {
    enabled = d.bool(forKey: "ai.enabled")
    provider = AIProvider(rawValue: d.string(forKey: "ai.provider") ?? "") ?? .claudeCLI
    models = d.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
    baseURLs = d.dictionary(forKey: "ai.baseURLs") as? [String: String] ?? [:]
    instructions = d.string(forKey: "ai.instructions") ?? Self.defaultInstructions
    language = d.string(forKey: "ai.language") ?? "auto"
    maxDiffKB = d.object(forKey: "ai.maxDiffKB") as? Int ?? 24
    consented = d.stringArray(forKey: "ai.consented") ?? []
  }

  var model: String {
    get { models[provider.rawValue] ?? provider.suggestions.first ?? "" }
    set { models[provider.rawValue] = newValue }
  }
  var baseURL: String {
    get { baseURLs[provider.rawValue] ?? provider.defaultBaseURL }
    set { baseURLs[provider.rawValue] = newValue }
  }
  var languageName: String {
    let code = language == "auto" ? Localization.current : language
    switch code {
    case "en": return "English"
    case "es": return "Spanish"
    case "pt", "pt-BR", "": return "Brazilian Portuguese"
    default: return code
    }
  }
}

/// API keys in the login Keychain (service "local.corescope.ai", one item per provider). They are
/// never written to UserDefaults, files or logs, and are read only to make a request.
enum AIKeychain {
  private static let service = "local.corescope.ai"
  static func get(_ p: AIProvider) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: p.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func has(_ p: AIProvider) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }
  @discardableResult static func set(_ p: AIProvider, _ key: String) -> Bool {
    delete(p)
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue,
      kSecAttrLabel as String: "CoreScope · \(p.title)", kSecValueData as String: Data(key.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
    ]
    return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
  }
  static func delete(_ p: AIProvider) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue,
    ]
    SecItemDelete(query as CFDictionary)
  }
}

struct StagedFileInfo: Decodable, Equatable {
  let path: String
  let added: Int?
  let removed: Int?
  let omitted: String?
}
struct CommitContextData: Decodable, Equatable {
  let repo: String
  let branch: String?
  let files: [StagedFileInfo]
  let diff: String
  let truncated: Bool
}

enum AICommit {
  struct Failure: Error { let message: String }

  static func context(folder: String) -> Result<CommitContextData, DBError> {
    ProjectsTool.call(["op": "commit_context", "folder": folder, "max_bytes": AISettings.shared.maxDiffKB * 1024], as: CommitContextData.self)
  }

  /// The system instructions and the user text for one request.
  static func prompt(_ c: CommitContextData) -> (system: String, user: String) {
    let s = AISettings.shared
    let system = s.instructions + "\n\nWrite the message in \(s.languageName)."
    var lines = ["Repository: \(c.repo)"]
    if let b = c.branch { lines.append("Branch: \(b)") }
    lines.append("Staged files:")
    for f in c.files {
      let stat = f.added.map { "+\($0) -\(f.removed ?? 0)" } ?? "binary"
      lines.append("- \(f.path) (\(stat))" + (f.omitted.map { ", diff left out: \($0)" } ?? ""))
    }
    lines.append("")
    lines.append(c.truncated ? "Staged diff (cut to fit):" : "Staged diff:")
    lines.append(c.diff)
    return (system, lines.joined(separator: "\n"))
  }

  /// Blocking (call off the main thread): the generated message, cleaned of fences and quotes.
  static func generate(_ c: CommitContextData) -> Result<String, Failure> {
    let (system, user) = prompt(c)
    return send(system: system, user: user, timeout: 120).map(clean)
  }

  /// A tiny request that sends no code, to check the provider, model and key.
  static func test() -> Result<String, Failure> {
    send(system: "Reply with the single word OK.", user: "Connection test from CoreScope.", timeout: 60)
  }

  static func clean(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("```") {
      t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
      if let end = t.range(of: "```", options: .backwards) { t = String(t[..<end.lowerBound]) }
      t = t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if t.count > 1, let f = t.first, let l = t.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
      t = String(t.dropFirst().dropLast())
    }
    return t
  }

  private static func send(system: String, user: String, timeout: TimeInterval) -> Result<String, Failure> {
    let s = AISettings.shared
    let model = s.model.trimmingCharacters(in: .whitespaces)
    switch s.provider {
    case .claudeCLI:
      var args = ["-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--output-format", "text", "--system-prompt", system]
      if !model.isEmpty { args += ["--model", model] }
      return runCLI(candidates: ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"], args: args, stdin: user, timeout: timeout, name: "claude")
    case .codexCLI:
      let out = FileManager.default.temporaryDirectory.appendingPathComponent("corescope-codex-\(UUID().uuidString).txt")
      defer { try? FileManager.default.removeItem(at: out) }
      var args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "--color", "never", "-o", out.path]
      if !model.isEmpty { args += ["-m", model] }
      args.append("-")
      let codex = [CodexAppServer.binary?.path].compactMap { $0 } + ["~/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
      return runCLI(candidates: codex, args: args, stdin: system + "\n\n" + user, timeout: timeout, name: "codex").flatMap { _ in
        let text = (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? .failure(Failure(message: L("O Codex não devolveu uma mensagem."))) : .success(text)
      }
    case .anthropic:
      guard let key = AIKeychain.get(.anthropic) else { return .failure(Failure(message: L("Falta a chave da API no Keychain."))) }
      let body: [String: Any] = ["model": model, "max_tokens": 1024, "system": system, "messages": [["role": "user", "content": user]]]
      return post("https://api.anthropic.com/v1/messages", body, headers: ["x-api-key": key, "anthropic-version": "2023-06-01"], timeout: timeout) { json in
        (json["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
      }
    case .openai:
      guard let key = AIKeychain.get(.openai) else { return .failure(Failure(message: L("Falta a chave da API no Keychain."))) }
      let body: [String: Any] = ["model": model, "instructions": system, "input": user]
      return post("https://api.openai.com/v1/responses", body, headers: ["Authorization": "Bearer \(key)"], timeout: timeout) { json in
        (json["output"] as? [[String: Any]])?.filter { $0["type"] as? String == "message" }
          .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
          .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined()
      }
    case .gemini:
      guard let key = AIKeychain.get(.gemini) else { return .failure(Failure(message: L("Falta a chave da API no Keychain."))) }
      let name = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
      let body: [String: Any] = [
        "systemInstruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": user]]]],
      ]
      return post("https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent", body, headers: ["x-goog-api-key": key], timeout: timeout) { json in
        ((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]).flatMap { ($0["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() }
      }
    case .ollama:
      let body: [String: Any] = ["model": model, "stream": false, "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
      return post(s.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat", body, headers: [:], timeout: timeout) { json in
        (json["message"] as? [String: Any])?["content"] as? String
      }
    case .lmstudio:
      var body: [String: Any] = ["messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
      if !model.isEmpty { body["model"] = model }
      return post(s.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/chat/completions", body, headers: [:], timeout: timeout) { json in
        ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
      }
    }
  }

  private static func post(
    _ url: String, _ body: [String: Any], headers: [String: String], timeout: TimeInterval, extract: @escaping ([String: Any]) -> String?
  ) -> Result<String, Failure> {
    guard let u = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else {
      return .failure(Failure(message: L("Endereço inválido: %@", url)))
    }
    var request = URLRequest(url: u, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    let done = DispatchSemaphore(value: 0)
    var result: Result<String, Failure> = .failure(Failure(message: L("Sem resposta.")))
    // An ephemeral session: no cookies, cache or credentials kept.
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
      defer { done.signal() }
      if let error {
        result = .failure(Failure(message: error.localizedDescription))
        return
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
      guard (200..<300).contains(status) else {
        // Provider error text only; request headers (the key) are never echoed.
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)"
        result = .failure(Failure(message: "HTTP \(status): \(message)"))
        return
      }
      if let text = extract(json), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result = .success(text)
      } else {
        result = .failure(Failure(message: L("A resposta veio sem texto.")))
      }
    }.resume()
    _ = done.wait(timeout: .now() + timeout + 5)
    return result
  }

  private static func runCLI(candidates: [String], args: [String], stdin: String, timeout: TimeInterval, name: String) -> Result<String, Failure> {
    let home = NSHomeDirectory()
    guard
      let path = candidates.map({ $0.replacingOccurrences(of: "~", with: home) }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return .failure(Failure(message: L("%@ não foi encontrado neste Mac.", name))) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    // Outside any project: no project instructions, hooks or settings get pulled in.
    p.currentDirectoryURL = FileManager.default.temporaryDirectory
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = errors
    do { try p.run() } catch { return .failure(Failure(message: error.localizedDescription)) }
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try? input.fileHandleForWriting.close()
    var out = Data()
    var err = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      out = output.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      err = errors.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    if group.wait(timeout: .now() + timeout) == .timedOut {
      p.terminate()
      return .failure(Failure(message: L("%@ demorou demais.", name)))
    }
    p.waitUntilExit()
    let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard p.terminationStatus == 0 else {
      let message = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return .failure(Failure(message: String((message.isEmpty ? text : message).suffix(600))))
    }
    return .success(text)
  }
}

/// Settings › AI.
struct AISettingsSection: View {
  @ObservedObject var s = AISettings.shared
  @ViewState private var key = ""
  @ViewState private var hasKey = false
  @ViewState private var testing = false
  @ViewState private var testResult: (ok: Bool, text: String)?
  var body: some View {
    Section(L("IA (opcional)")) {
      Toggle(L("Gerar mensagens de commit com IA"), isOn: $s.enabled)
      Text(L("Desligado por padrão: é o único recurso do CoreScope que pode mandar código para fora do Mac. Ligado, nada é enviado sozinho — só quando você clica em Gerar mensagem, e na primeira vez com cada provedor o CoreScope mostra exatamente o que vai: o nome do repositório, a branch, a lista de arquivos e o diff em stage (sem lockfiles nem binários, cortado no limite abaixo). O commit continua sendo um clique seu."))
        .font(.caption).foregroundStyle(.secondary)
      if s.enabled {
        Picker(L("Provedor"), selection: $s.provider) {
          ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
        }
        LabeledContent(L("Modelo")) {
          HStack(spacing: 6) {
            TextField("", text: Binding(get: { s.model }, set: { s.model = $0 }), prompt: Text(L("padrão do provedor")))
              .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            if !s.provider.suggestions.isEmpty {
              Menu {
                ForEach(s.provider.suggestions, id: \.self) { m in Button(m) { s.model = m } }
              } label: { Image(systemName: "list.bullet") }.menuStyle(.borderlessButton).fixedSize()
                .help(L("Sugestões de modelos rápidos e baratos; confira os nomes atuais na documentação do provedor."))
            }
          }
        }
        if s.provider.needsKey {
          LabeledContent(L("Chave da API")) {
            HStack(spacing: 6) {
              SecureField("", text: $key, prompt: Text(hasKey ? L("salva no Keychain") : L("cole a chave")))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
              Button(L("Salvar")) {
                AIKeychain.set(s.provider, key.trimmingCharacters(in: .whitespacesAndNewlines))
                key = ""
                hasKey = AIKeychain.has(s.provider)
              }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
              if hasKey { Button(L("Remover")) {
                AIKeychain.delete(s.provider)
                hasKey = false
              } }
            }
          }
        }
        if s.provider.isLocalServer {
          LabeledContent(L("Endereço")) {
            TextField("", text: Binding(get: { s.baseURL }, set: { s.baseURL = $0 }), prompt: Text(s.provider.defaultBaseURL))
              .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 240)
          }
        }
        Text(s.provider.keyHelp + (s.provider.needsKey ? " " + L("A chave fica só no Keychain do macOS, nunca em preferências, arquivos ou logs.") : ""))
          .font(.caption).foregroundStyle(.secondary)
        Picker(L("Idioma da mensagem"), selection: $s.language) {
          Text(L("O do app")).tag("auto")
          Text("Português").tag("pt-BR")
          Text("English").tag("en")
          Text("Español").tag("es")
        }
        Stepper(value: $s.maxDiffKB, in: 4...256, step: 4) {
          LabeledContent(L("Limite do diff enviado"), value: "\(s.maxDiffKB) KB")
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(L("Instruções"))
            Spacer()
            Button(L("Restaurar padrão")) { s.instructions = AISettings.defaultInstructions }
              .controlSize(.small).disabled(s.instructions == AISettings.defaultInstructions)
          }
          TextEditor(text: $s.instructions).font(.system(.caption, design: .monospaced)).frame(height: 110)
            .scrollContentBackground(.hidden).padding(4)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
        HStack {
          Button(L("Testar conexão")) { test() }.disabled(testing)
          if testing { ProgressView().controlSize(.small) }
          if let r = testResult {
            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
              .font(.caption).foregroundStyle(r.ok ? .green : .red).lineLimit(3)
          }
          Spacer()
          if !s.consented.isEmpty {
            Button(L("Pedir confirmação de novo")) { s.consented = [] }.controlSize(.small)
              .help(L("Mostra outra vez o que será enviado antes do próximo envio a cada provedor."))
          }
        }
        Text(L("O teste manda só uma frase curta, nenhum código."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear { hasKey = AIKeychain.has(s.provider) }
    .onChange(of: s.provider) { _, p in
      hasKey = AIKeychain.has(p)
      key = ""
      testResult = nil
    }
  }
  private func test() {
    testing = true
    testResult = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let r = AICommit.test()
      DispatchQueue.main.async {
        testing = false
        switch r {
        case .success(let text): testResult = (true, L("Respondeu: %@", String(text.prefix(40))))
        case .failure(let f): testResult = (false, f.message)
        }
      }
    }
  }
}

/// Before the first request to a provider: exactly what will be sent, and to whom.
struct AIConsentSheet: View {
  let context: CommitContextData
  let accept: () -> Void
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var s = AISettings.shared
  var body: some View {
    let prompt = AICommit.prompt(context)
    VStack(alignment: .leading, spacing: 10) {
      Text(L("Enviar para %@?", s.provider.title)).font(.title3.weight(.semibold))
      Text(
        s.provider.sendsOut
          ? L("Isto sai do seu Mac e vai para o provedor escolhido, que processa conforme os termos dele. Só desta vez a cada provedor o CoreScope pergunta; depois, Gerar mensagem envia direto.")
          : L("Vai para o servidor local configurado; nada sai do Mac.")
      ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text(L("Repositório %@ · %@ arquivos · %@ do diff%@", context.repo, "\(context.files.count)", formatBytes(Double(context.diff.utf8.count)), context.truncated ? " " + L("(cortado)") : ""))
        .font(.caption.weight(.medium))
      ScrollView {
        Text(Demo.enabled ? L("O texto fica oculto no modo de demonstração.") : prompt.user)
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      .frame(height: 260)
      .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
      HStack {
        Spacer()
        Button(L("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L("Enviar e gerar")) {
          if !s.consented.contains(s.provider.rawValue) { s.consented.append(s.provider.rawValue) }
          dismiss()
          accept()
        }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
      }
    }
    .padding(18).frame(width: 640)
  }
}
