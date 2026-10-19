import AppKit
import SwiftUI

struct ProjectEntry: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let folder: String
  let show_in_panel: Bool
  let notify_minutes: Int?
  let added: Double
}
struct ProjectConfigSummary: Decodable, Equatable {
  let exists: Bool
  let file: String?
  let name: String?
  let error: String?
  let error_line: Int?
  let profiles: [String]
  let ports: [String]
  let services: Int
  let logs: Int
  let wait_for_capacity: Bool
}
struct RepoInfo: Decodable, Equatable {
  let is_repo: Bool
  let root: String?
  let main_repo: String?
  let is_worktree: Bool
  let branch: String?
  let head: String?
  let detached: Bool
  let subfolder: String?
}
struct ProjectCheck: Decodable, Equatable {
  let folder: String
  let default_name: String
  let config: ProjectConfigSummary
  let git: RepoInfo
  let registered: String?
}

/// `cs_projects` (core `projects_tool`).
enum ProjectsTool {
  static func call<T: Decodable>(_ request: [String: Any], as: T.Type) -> Result<T, DBError> {
    guard let data = try? JSONSerialization.data(withJSONObject: request),
      let json = String(data: data, encoding: .utf8),
      let pointer = json.withCString({ cs_projects($0) })
    else { return .failure(DBError(message: L("O núcleo não retornou dados"))) }
    defer { cs_free(pointer) }
    let body = Data(bytes: pointer, count: strlen(pointer))
    if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let error = obj["error"] as? String {
      return .failure(DBError(message: error))
    }
    guard let decoded = try? JSONDecoder().decode(T.self, from: body) else {
      return .failure(DBError(message: L("Resposta inválida")))
    }
    return .success(decoded)
  }
}
private struct Ignored: Decodable {}
struct GitSummary: Decodable, Equatable {
  let branch: GitBranchState
  let staged: Int
  let modified: Int
  let untracked: Int
  let removed: Int
  let conflicts: Int
  var total: Int { staged + modified + untracked + removed + conflicts }
}

/// Registered projects and what their folders hold (config summary, git), read when the page
/// opens and after every change. A project's changes (ProjectChanges.swift) are watched only while shown.
final class ProjectsStore: ObservableObject {
  static let shared = ProjectsStore()
  @Published private(set) var projects: [ProjectEntry] = []
  @Published private(set) var checks: [String: ProjectCheck] = [:]
  @Published var message: String?
  /// The project whose changes are on screen (id).
  @Published var opened: String?
  /// Branch and change counts per project (id), so the list tells what changed without opening.
  @Published private(set) var summaries: [String: GitSummary] = [:]
  /// File watchers while the list is on screen, one per repository.
  private var watchers: [String: RepoWatcher] = [:]
  private var listVisible = false
  private let queue = DispatchQueue(label: "app.corescope.projects", qos: .userInitiated)

  func load() {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let list = (try? ProjectsTool.call(["op": "list"], as: [ProjectEntry].self).get()) ?? []
      var checks: [String: ProjectCheck] = [:]
      var summaries: [String: GitSummary] = [:]
      for p in list {
        guard let c = try? ProjectsTool.call(["op": "check", "folder": p.folder], as: ProjectCheck.self).get() else { continue }
        checks[p.id] = c
        if c.git.is_repo, let sum = try? ProjectsTool.call(["op": "summary", "folder": p.folder], as: GitSummary.self).get() {
          summaries[p.id] = sum
        }
      }
      DispatchQueue.main.async {
        if list != self.projects { self.projects = list }
        if checks != self.checks { self.checks = checks }
        if summaries != self.summaries { self.summaries = summaries }
        // A setting changed elsewhere (MCP set_project, the CLI): follow it.
        let notifying = Set(list.filter { $0.notify_minutes != nil }.map(\.id))
        if notifying != Set(ProjectNotifier.shared.projects.map(\.id)) { ProjectNotifier.shared.sync() }
        self.syncWatchers()
      }
    }
  }
  /// One project's counts again (its watcher saw a change).
  private func refreshSummary(_ id: String) {
    guard let p = projects.first(where: { $0.id == id }) else { return }
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let sum = try? ProjectsTool.call(["op": "summary", "folder": p.folder], as: GitSummary.self).get()
      DispatchQueue.main.async { if self.summaries[id] != sum { self.summaries[id] = sum } }
    }
  }
  /// The list is on screen (true) or not: watchers exist only while it is.
  func setListVisible(_ visible: Bool) {
    listVisible = visible
    syncWatchers()
    if visible { load() }
  }
  private func syncWatchers() {
    guard listVisible else {
      watchers = [:]
      return
    }
    var next: [String: RepoWatcher] = [:]
    for p in projects {
      guard let root = checks[p.id]?.git.root else { continue }
      next[p.id] = watchers[p.id] ?? RepoWatcher(folder: p.folder, root: root) { [weak self] in self?.refreshSummary(p.id) }
    }
    watchers = next
  }
  func check(_ folder: String, done: @escaping (Result<ProjectCheck, DBError>) -> Void) {
    queue.async {
      let r = ProjectsTool.call(["op": "check", "folder": folder], as: ProjectCheck.self)
      DispatchQueue.main.async { done(r) }
    }
  }
  private func run(_ request: [String: Any], done: ((String?) -> Void)? = nil) {
    queue.async {
      let r = ProjectsTool.call(request, as: Ignored.self)
      DispatchQueue.main.async {
        var failure: String?
        if case .failure(let e) = r { failure = e.message }
        self.message = failure
        done?(failure)
        self.load()
      }
    }
  }
  func add(_ folder: String, name: String, template: Bool, done: @escaping (String?) -> Void) {
    run(["op": "add", "folder": folder, "name": name, "template": template], done: done)
  }
  func rename(_ p: ProjectEntry, to name: String) { run(["op": "rename", "id": p.id, "name": name]) }
  func remove(_ p: ProjectEntry) { run(["op": "remove", "id": p.id]) }
  func initRepository(_ folder: String) { run(["op": "init", "folder": folder]) }
  /// Opens a project's changes by id or name (corescope://project/…), once the list is read.
  func open(_ key: String) {
    queue.async {
      let list = (try? ProjectsTool.call(["op": "list"], as: [ProjectEntry].self).get()) ?? []
      let match = list.first { $0.id == key } ?? list.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
      DispatchQueue.main.async {
        if list != self.projects { self.projects = list }
        if let match { self.opened = match.id } else { self.message = L("Nenhum projeto chamado %@.", key) }
      }
    }
  }
}

private func shown(_ path: String) -> String { Demo.enabled ? Demo.path(path) : abbreviateHome(path) }

struct ProjectsView: View {
  @ObservedObject var store = ProjectsStore.shared
  @ViewState private var adding: ProjectCheck?
  var body: some View {
    if let id = store.opened, let project = store.projects.first(where: { $0.id == id }) {
      ProjectChangesView(project: project) { store.opened = nil }.id(project.id)
    } else {
      list
    }
  }
  private var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text(L("Repositórios locais que você acompanha: a configuração do .corescope.yml e o estado do git."))
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          Button {
            choose()
          } label: {
            Label(L("Adicionar projeto…"), systemImage: "plus")
          }
        }
        if let message = store.message { Text(message).font(.caption).foregroundStyle(.orange) }
        if store.projects.isEmpty {
          Card {
            EmptyNote(text: L("Nenhum projeto ainda. Adicione a pasta de um repositório: o CoreScope lê o .corescope.yml (ou oferece criar um) e o git dela, sem abrir uma IDE."))
          }
        }
        ForEach(store.projects) { p in ProjectCard(project: p, check: store.checks[p.id], summary: store.summaries[p.id]) { store.opened = p.id } }
      }.padding(20)
    }
    .onAppear { store.setListVisible(true) }
    .onDisappear { store.setListVisible(false) }
    .sheet(item: Binding(get: { adding.map(AddingProject.init) }, set: { adding = $0?.check })) { AddProjectSheet(check: $0.check) }
  }
  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = L("Escolher pasta")
    panel.message = L("Escolha a pasta do projeto (a raiz do repositório ou uma subpasta).")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.check(url.path) { r in
      switch r {
      case .success(let c): adding = c
      case .failure(let e): store.message = e.message
      }
    }
  }
}
private struct AddingProject: Identifiable {
  let check: ProjectCheck
  var id: String { check.folder }
}

/// Name, configuration and repository of a folder before it is added.
private struct AddProjectSheet: View {
  let check: ProjectCheck
  @ObservedObject var store = ProjectsStore.shared
  @Environment(\.dismiss) private var dismiss
  @ViewState private var name = ""
  @ViewState private var error: String?
  @ViewState private var confirmInit = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Adicionar projeto")).font(.title3.weight(.semibold))
      Text(shown(check.folder)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if check.registered != nil {
        Label(L("Esta pasta já está na lista."), systemImage: "checkmark.circle").foregroundStyle(.secondary)
      }
      LabeledContent(L("Nome")) { TextField(check.default_name, text: $name).textFieldStyle(.roundedBorder) }
      ProjectConfigView(config: check.config)
      if !check.config.exists {
        Label(L("Esta pasta não tem .corescope.yml. O CoreScope cria um modelo mínimo (só o nome) com o mesmo gravador do resto do app; sem ele o projeto não é adicionado."), systemImage: "doc.badge.plus")
          .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
      }
      ProjectGitView(git: check.git) { confirmInit = true }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button(L("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(check.config.exists ? L("Adicionar") : L("Criar .corescope.yml e adicionar")) { add() }
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(check.registered != nil || resolvedName.isEmpty)
      }
    }
    .padding(18).frame(width: 520)
    .onAppear { name = check.default_name }
    .confirmationDialog(L("Inicializar um repositório git aqui?"), isPresented: $confirmInit) {
      Button(L("Inicializar repositório")) {
        store.initRepository(check.folder)
        dismiss()
      }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("Roda git init em %@. Nada é commitado.", shown(check.folder)))
    }
  }
  private var resolvedName: String { name.trimmingCharacters(in: .whitespaces) }
  private func add() {
    if !check.config.exists {
      let alert = NSAlert()
      alert.messageText = L("Criar .corescope.yml?")
      alert.informativeText = L("Um arquivo mínimo com o nome do projeto. Se você recusar, o projeto não é adicionado.")
      alert.addButton(withTitle: L("Criar e adicionar"))
      alert.addButton(withTitle: L("Não adicionar"))
      guard alert.runModal() == .alertFirstButtonReturn else {
        dismiss()
        return
      }
    }
    store.add(check.folder, name: resolvedName, template: !check.config.exists) { failure in
      if let failure { error = failure } else { dismiss() }
    }
  }
}

/// What `.corescope.yml` enables, or its first error with the line.
struct ProjectConfigView: View {
  let config: ProjectConfigSummary
  var body: some View {
    if let error = config.error {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        VStack(alignment: .leading, spacing: 2) {
          Text(config.error_line.map { L(".corescope.yml, linha %@", "\($0)") } ?? ".corescope.yml").font(.callout.weight(.medium))
          Text(error).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Spacer()
        if let file = config.file {
          Button(L("Abrir")) { NSWorkspace.shared.open(URL(fileURLWithPath: file)) }.controlSize(.small)
        }
      }
    } else if config.exists {
      let parts: [String] = [
        config.profiles.isEmpty ? nil : L("perfis: %@", config.profiles.joined(separator: ", ")),
        config.ports.isEmpty ? nil : L("portas: %@", config.ports.joined(separator: ", ")),
        config.services > 0 ? L("%@ serviços", "\(config.services)") : nil,
        config.logs > 0 ? L("%@ logs", "\(config.logs)") : nil,
        config.wait_for_capacity ? L("agentes esperam capacidade") : nil,
      ].compactMap { $0 }
      Label(parts.isEmpty ? L(".corescope.yml válido, só com o nome") : parts.joined(separator: " · "), systemImage: "checkmark.seal")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// Branch, worktree and parent repository, or the offer to initialize one.
struct ProjectGitView: View {
  let git: RepoInfo
  let initialize: () -> Void
  var body: some View {
    if git.is_repo {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch").foregroundStyle(Tint.brand)
        Text(git.branch.map(shownBranch) ?? (git.detached ? L("HEAD destacado em %@", git.head ?? "?") : L("sem commits ainda")))
          .font(.callout.weight(.medium))
        if git.is_worktree { Badge(text: L("worktree"), color: .orange) }
        if let sub = git.subfolder { Badge(text: L("subpasta %@", sub), color: .secondary) }
        Spacer()
      }
      if let main = git.main_repo {
        Text(L("Worktree do repositório %@", shown(main))).font(.caption).foregroundStyle(.secondary)
      } else if git.subfolder != nil, let root = git.root {
        Text(L("Dentro do repositório %@", shown(root))).font(.caption).foregroundStyle(.secondary)
      }
    } else {
      HStack {
        Label(L("Sem repositório git"), systemImage: "questionmark.folder").font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button(L("Inicializar repositório…"), action: initialize).controlSize(.small)
      }
    }
  }
}

private struct ProjectCard: View {
  let project: ProjectEntry
  let check: ProjectCheck?
  let summary: GitSummary?
  let openChanges: () -> Void
  @ObservedObject var store = ProjectsStore.shared
  @ViewState private var editing = false
  @ViewState private var draft = ""
  @ViewState private var confirmRemove = false
  @ViewState private var confirmInit = false
  @ViewState private var instructions = false
  @ViewState private var removingUnused = false
  var body: some View {
    Card {
      HStack(spacing: 10) {
        Image(systemName: "folder.fill").foregroundStyle(Tint.brand).frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          if editing {
            TextField(L("Nome"), text: $draft).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
              .onSubmit(save)
          } else {
            HStack(spacing: 5) {
              Text(shownProjectName(project)).font(.system(size: 14, weight: .semibold))
              if let n = project.notify_minutes {
                Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.secondary)
                  .help(L("Notifica alterações a cada %@ min", "\(n)"))
              }
            }
          }
          Text(shown(project.folder)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        if editing {
          Button(L("Salvar"), action: save).controlSize(.small)
          Button(L("Cancelar")) { editing = false }.controlSize(.small)
        } else {
          if check?.git.is_repo == true {
            Button(action: openChanges) {
              HStack(spacing: 5) {
                Label(L("Alterações"), systemImage: "plusminus")
                if let n = summary?.total, n > 0 { Text(verbatim: "\(n)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.orange) }
              }
            }.controlSize(.small)
          }
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.folder)])
          } label: { Image(systemName: "folder") }.buttonStyle(HoverButtonStyle()).help(L("Mostrar no Finder"))
            .accessibilityLabel(L("Mostrar no Finder"))
          Menu {
            Button(L("Renomear")) {
              draft = project.name
              editing = true
            }
            ProjectNotifyPicker(project: project).disabled(check?.git.is_repo != true)
            Toggle(L("Mostrar no painel"), isOn: Binding(get: { project.show_in_panel }, set: { PanelProjectsStore.shared.setShown(project, $0) }))
              .disabled(check?.git.is_repo != true)
            Button(L("Instruções para agentes…")) { instructions = true }
              .disabled(check?.config.exists != true || check?.config.error != nil)
            Button(L("Remover worktrees e branches não usados…")) { removingUnused = true }
              .disabled(check?.git.is_repo != true)
            Divider()
            Button(L("Remover da lista…"), role: .destructive) { confirmRemove = true }
          } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }
      }
      if let check {
        ProjectGitView(git: check.git) { confirmInit = true }
        if check.git.is_repo, let summary { ChangeCounts(summary: summary, open: openChanges) }
        ProjectConfigView(config: check.config)
        if check.git.is_repo {
          Divider()
          ProjectBranchesSection(project: project) { removingUnused = true }
          ProjectWorktreesSection(project: project) { removingUnused = true }
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .sheet(isPresented: $instructions) { AgentInstructionsSheet(project: project) }
    .sheet(isPresented: $removingUnused) { RemoveUnusedSheet(project: project) }
    .confirmationDialog(L("Remover %@ da lista?", shownProjectName(project)), isPresented: $confirmRemove) {
      Button(L("Remover"), role: .destructive) { store.remove(project) }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("Só sai do CoreScope: a pasta, o .corescope.yml e o repositório ficam como estão."))
    }
    .confirmationDialog(L("Inicializar um repositório git aqui?"), isPresented: $confirmInit) {
      Button(L("Inicializar repositório")) { store.initRepository(project.folder) }
      Button(L("Cancelar"), role: .cancel) {}
    } message: {
      Text(L("Roda git init em %@. Nada é commitado.", shown(project.folder)))
    }
  }
  private func save() {
    let name = draft.trimmingCharacters(in: .whitespaces)
    if !name.isEmpty && name != project.name { store.rename(project, to: name) }
    editing = false
  }
}

/// What changed in a project, at a glance: counts by kind and the distance from upstream.
struct ChangeCounts: View {
  let summary: GitSummary
  let open: () -> Void
  var body: some View {
    HStack(spacing: 6) {
      if summary.total == 0 {
        Label(L("Sem alterações"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
      } else {
        Button(action: open) {
          HStack(spacing: 5) {
            if summary.conflicts > 0 { Badge(text: L("%@ conflitos", "\(summary.conflicts)"), color: .red, symbol: "exclamationmark.triangle.fill") }
            if summary.staged > 0 { Badge(text: L("%@ em stage", "\(summary.staged)"), color: .green) }
            if summary.modified > 0 { Badge(text: L("%@ modificados", "\(summary.modified)"), color: .orange) }
            if summary.untracked > 0 { Badge(text: L("%@ novos", "\(summary.untracked)"), color: .green) }
            if summary.removed > 0 { Badge(text: L("%@ removidos", "\(summary.removed)"), color: .red) }
          }
        }
        .buttonStyle(.plain).help(L("Abrir as alterações"))
      }
      if summary.branch.upstream != nil, let a = summary.branch.ahead, let b = summary.branch.behind, a + b > 0 {
        Badge(text: "↑\(a)  ↓\(b)", color: b > 0 ? .orange : .secondary).help(L("Commits à frente / atrás do upstream"))
      }
      Spacer()
    }
  }
}
