import AppKit
import SwiftUI

struct LocalBranch: Decodable, Equatable, Identifiable {
  let name: String
  let current: Bool
  let head: String
  let subject: String
  let author: String
  let time: Double
  let upstream: String?
  let ahead: Int?
  let behind: Int?
  let gone: Bool
  let worktree: String?
  let merged: Bool?
  var id: String { name }
  var facts: BranchFacts { BranchFacts(name: name, current: current, worktree: worktree, merged: merged, gone: gone) }
}
struct BranchList: Decodable, Equatable {
  let branches: [LocalBranch]
  let truncated: Int
  /// The branch merged work lands on (`origin/main`…).
  let `default`: String?
}
struct WorktreeView: Decodable, Equatable, Identifiable {
  let path: String
  let branch: String?
  let head: String
  let main: Bool
  let current: Bool
  let agent: String?
  let locked: Bool
  let prunable: Bool
  let merged: Bool?
  let gone: Bool
  let changes: Int?
  let in_use: String?
  let last_commit: Double?
  let size: UInt64?
  var id: String { path }
  var facts: WorktreeFacts {
    WorktreeFacts(
      path: path, branch: branch, main: main, current: current, locked: locked, prunable: prunable, merged: merged,
      gone: gone, changes: changes, inUse: in_use)
  }
}
private struct WorktreeSize: Decodable {
  let path: String
  let bytes: UInt64
}
/// One item of a removal: removed, refused by a rule (`reason`, a `PruneBlock` code) or failed in
/// git (`message`).
struct RemovalResult: Decodable, Equatable, Identifiable {
  let kind: String
  let target: String
  let status: String
  let reason: String?
  let message: String?
  var id: String { kind + ":" + target }
}

/// Branches and worktrees of each project, read only when their section is opened (and again on
/// request). Worktree sizes are measured one at a time afterwards and cached by the core.
final class ProjectRefsStore: ObservableObject {
  static let shared = ProjectRefsStore()
  @Published private(set) var branches: [String: BranchList] = [:]
  @Published private(set) var worktrees: [String: [WorktreeView]] = [:]
  @Published private(set) var sizes: [String: UInt64] = [:]
  @Published private(set) var loading: Set<String> = []
  @Published private(set) var errors: [String: String] = [:]
  private let queue = DispatchQueue(label: "app.corescope.project-refs", qos: .utility)
  /// Reads asked for while one was running: run again when it ends, so a read never shows the
  /// state from before a removal.
  private var again: Set<String> = []

  func loadBranches(_ p: ProjectEntry) {
    let key = "b:" + p.id
    guard !loading.contains(key) else {
      again.insert(key)
      return
    }
    loading.insert(key)
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let r = ProjectsTool.call(["op": "branches", "folder": p.folder], as: BranchList.self)
      DispatchQueue.main.async {
        self.loading.remove(key)
        switch r {
        case .success(let list):
          self.branches[p.id] = list
          self.errors[key] = nil
        case .failure(let e): self.errors[key] = e.message
        }
        if self.again.remove(key) != nil { self.loadBranches(p) }
      }
    }
  }

  func loadWorktrees(_ p: ProjectEntry) {
    let key = "w:" + p.id
    guard !loading.contains(key) else {
      again.insert(key)
      return
    }
    loading.insert(key)
    queue.async {
      let cost = CostMeter.begin()
      let r = ProjectsTool.call(["op": "worktrees", "folder": p.folder], as: [WorktreeView].self)
      CostMeter.end("projects-git", cost)
      DispatchQueue.main.async {
        self.loading.remove(key)
        switch r {
        case .success(let list):
          self.worktrees[p.id] = list
          self.errors[key] = nil
          for w in list { if let s = w.size { self.sizes[w.path] = s } }
          self.measure(p, list.filter { $0.size == nil && !$0.prunable }.map(\.path))
        case .failure(let e): self.errors[key] = e.message
        }
        if self.again.remove(key) != nil { self.loadWorktrees(p) }
      }
    }
  }

  /// Sizes in the background, one worktree at a time (a folder walk each).
  private func measure(_ p: ProjectEntry, _ paths: [String]) {
    for path in paths {
      queue.async {
        let cost = CostMeter.begin()
        defer { CostMeter.end("projects-git", cost) }
        guard let r = try? ProjectsTool.call(["op": "worktree_size", "folder": p.folder, "path": path], as: WorktreeSize.self).get() else { return }
        DispatchQueue.main.async { self.sizes[r.path] = r.bytes }
      }
    }
  }

  /// `git worktree remove` for the worktrees, then `git branch -d` for the branches; the core
  /// checks each one again and refuses what its rules keep. Both lists are read again after.
  func removeUnused(
    _ p: ProjectEntry, worktrees: [String], branches: [String], allowDirty: Bool,
    done: @escaping (Result<[RemovalResult], DBError>) -> Void
  ) {
    struct Reply: Decodable { let results: [RemovalResult] }
    DispatchQueue.global(qos: .userInitiated).async {
      let r = ProjectsTool.call(
        ["op": "remove_unused", "folder": p.folder, "worktrees": worktrees, "branches": branches, "allow_dirty": allowDirty],
        as: Reply.self)
      DispatchQueue.main.async {
        done(r.map(\.results))
        self.loadWorktrees(p)
        self.loadBranches(p)
      }
    }
  }

  /// Removable worktrees (with their known size) and branches, once both lists were read.
  func removable(_ p: ProjectEntry) -> (worktrees: Int, branches: Int, bytes: UInt64)? {
    guard let wts = worktrees[p.id], let list = branches[p.id] else { return nil }
    let gone = wts.filter { worktreeGroup($0.facts) == .removable }
    let refs = list.branches.filter { branchGroup($0.facts, defaultBranch: list.default) == .removable }
    return (gone.count, refs.count, gone.compactMap { sizes[$0.path] }.reduce(0, +))
  }
}

/// In demo mode branch names other than the usual defaults and commit subjects are made up.
func shownBranch(_ name: String) -> String {
  guard Demo.enabled, !["main", "master", "develop", "dev", "trunk"].contains(name) else { return name }
  return "feature/" + demoPick(["login-form", "search", "billing", "dark-mode", "onboarding", "api-cache"], name)
}
private func shownSubject(_ subject: String) -> String {
  Demo.enabled ? demoPick(["Fix flaky tests", "Add search endpoint", "Refactor auth middleware", "Update dependencies", "Improve error messages"], subject) : subject
}
private func shownFolder(_ path: String) -> String { Demo.enabled ? Demo.path(path) : abbreviateHome(path) }
/// In demo mode the project is named after its anonymized folder.
func shownProjectName(_ p: ProjectEntry) -> String {
  Demo.enabled ? (Demo.path(p.folder) as NSString).lastPathComponent : p.name
}
private func ago(_ seconds: Double) -> String { Date(timeIntervalSince1970: seconds).formatted(.relative(presentation: .named)) }
/// Worktrees inside the main one (`.claude/worktrees/…`) show their path relative to it.
private func place(_ path: String, main: String?) -> String {
  if let main, path != main, path.hasPrefix(main + "/") { return String(path.dropFirst(main.count + 1)) }
  return shownFolder(path)
}

private extension RefGroup {
  func title(branches: Bool) -> String {
    switch self {
    case .inUse: L("Em uso")
    case .removable: L("Removíveis")
    case .other: branches ? L("Outras") : L("Outros")
    }
  }
  var symbol: String {
    switch self {
    case .inUse: "circle.fill"
    case .removable: "trash"
    case .other: "circle"
    }
  }
  var tint: Color {
    switch self {
    case .inUse: .blue
    case .removable: .green
    case .other: .secondary
    }
  }
}

/// A group of rows with its title and count; long groups show their first rows and a button.
private struct RefGroupBlock<Item: Identifiable, Row: View>: View {
  let group: RefGroup
  let branches: Bool
  let items: [Item]
  var detail: String? = nil
  var limit = 6
  @ViewBuilder let row: (Item) -> Row
  @ViewState private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Image(systemName: group.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(group.tint).accessibilityHidden(true)
        Text(group.title(branches: branches)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(verbatim: "\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        if let detail { Text(verbatim: "· " + detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        Spacer()
      }
      .padding(.top, 2)
      ForEach(expanded ? items : Array(items.prefix(limit))) { row($0) }
      if items.count > limit {
        Button(expanded ? L("Mostrar menos") : L("Mostrar todos (%@)", "\(items.count)")) { expanded.toggle() }
          .buttonStyle(.borderless).controlSize(.small)
      }
    }
  }
}

/// The badges branch and worktree rows share, in the same order and colors: merged into the
/// default branch, upstream state, where it is in use.
private struct MergedBadge: View {
  let merged: Bool?
  var showUnmerged = true
  var body: some View {
    switch merged {
    case .some(true): Badge(text: L("mergeado"), color: .green).help(L("Mergeado no branch padrão"))
    case .some(false) where showUnmerged: Badge(text: L("não mergeado"), color: .orange)
    default: EmptyView()
    }
  }
}

/// The footer both sections share: the removal sheet, and the Cleanup page for worktrees.
private struct RemoveUnusedFooter: View {
  let cleanupLink: Bool
  let action: () -> Void
  var body: some View {
    HStack {
      Button(action: action) { Label(L("Remover não usados…"), systemImage: "trash") }.controlSize(.small)
      Spacer()
      if cleanupLink {
        Button {
          AppLinks.show(.cleanup)
        } label: { Label(L("Limpar worktrees na Limpeza"), systemImage: "arrow.right.circle") }
          .buttonStyle(.borderless).controlSize(.small)
      }
    }
    .padding(.top, 4)
  }
}

/// "9 removíveis · 3,1 GB" next to a section's title, once its list was read.
private func removableNote(_ count: Int, bytes: UInt64?) -> String? {
  guard count > 0 else { return nil }
  let n = L("%@ removíveis", "\(count)")
  guard let bytes, bytes > 0 else { return n }
  return n + " · " + formatBytes(Double(bytes))
}

/// Local branches, closed by default; opening it reads them. Grouped like the worktrees: in use
/// (current, checked out in a worktree), removable (merged, checked out nowhere), the rest.
struct ProjectBranchesSection: View {
  let project: ProjectEntry
  let removeUnused: () -> Void
  @ObservedObject var store = ProjectRefsStore.shared
  @ViewState private var open = false
  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      let key = "b:" + project.id
      if let error = store.errors[key] {
        Text(error).font(.caption).foregroundStyle(.red)
      } else if let list = store.branches[project.id] {
        let groups = Dictionary(grouping: list.branches) { branchGroup($0.facts, defaultBranch: list.default) }
        VStack(alignment: .leading, spacing: 8) {
          ForEach(RefGroup.allCases, id: \.self) { g in
            if let items = groups[g], !items.isEmpty {
              RefGroupBlock(group: g, branches: true, items: items, limit: g == .other ? 10 : 6) { BranchRow(branch: $0) }
            }
          }
          if list.truncated > 0 {
            Text(L("… e mais %@ (limite de exibição)", "\(list.truncated)")).font(.caption).foregroundStyle(.secondary)
          }
          RemoveUnusedFooter(cleanupLink: false, action: removeUnused)
        }.padding(.top, 4)
      } else {
        ProgressView().controlSize(.small)
      }
    } label: {
      HStack(spacing: 6) {
        Text(L("Branches locais")).font(.callout.weight(.medium))
        if let list = store.branches[project.id] {
          Badge(text: "\(list.branches.count + list.truncated)")
          let n = list.branches.filter { branchGroup($0.facts, defaultBranch: list.default) == .removable }.count
          if let note = removableNote(n, bytes: nil) { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        if open {
          if store.loading.contains("b:" + project.id) { ProgressView().controlSize(.mini) }
          Button {
            store.loadBranches(project)
          } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(L("Atualizar")).accessibilityLabel(L("Atualizar"))
        }
      }
    }
    .onChange(of: open) { _, isOpen in if isOpen { store.loadBranches(project) } }
  }
}

private struct BranchRow: View {
  let branch: LocalBranch
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: branch.current ? "checkmark.circle.fill" : "arrow.triangle.branch")
        .foregroundStyle(branch.current ? Tint.brand : .secondary).frame(width: 14)
      Text(shownBranch(branch.name)).font(.callout.weight(branch.current ? .semibold : .regular)).lineLimit(1)
      Text(branch.head).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
      Text(shownSubject(branch.subject)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 6)
      MergedBadge(merged: branch.merged, showUnmerged: false)
      sync
      if let wt = branch.worktree {
        Badge(text: L("worktree"), color: .blue).help(L("Em uso no worktree %@", shownFolder(wt)))
      }
      Text(ago(branch.time)).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(minWidth: 80, alignment: .trailing)
    }
    .help(branch.upstream.map { L("Upstream: %@", Demo.enabled ? "origin" : $0) } ?? L("sem upstream"))
  }
  @ViewBuilder private var sync: some View {
    if branch.gone {
      Badge(text: L("upstream removido"), color: .secondary)
    } else if let a = branch.ahead, let b = branch.behind {
      if a == 0 && b == 0 {
        Badge(text: L("em dia"), color: .green)
      } else {
        Badge(text: "↑\(a)  ↓\(b)", color: b > 0 ? .orange : .secondary)
      }
    } else {
      Badge(text: L("sem upstream"), color: .secondary)
    }
  }
}

/// The repository's worktrees, closed by default, grouped into in use (the checkout, the main
/// tree, a process inside), removable and the rest.
struct ProjectWorktreesSection: View {
  let project: ProjectEntry
  let removeUnused: () -> Void
  @ObservedObject var store = ProjectRefsStore.shared
  @ViewState private var open = false
  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      let key = "w:" + project.id
      VStack(alignment: .leading, spacing: 8) {
        if let error = store.errors[key] {
          Text(error).font(.caption).foregroundStyle(.red)
        } else if let list = store.worktrees[project.id] {
          let main = list.first(where: \.main)?.path
          let groups = Dictionary(grouping: list) { worktreeGroup($0.facts) }
          ForEach(RefGroup.allCases, id: \.self) { g in
            if let items = groups[g], !items.isEmpty {
              RefGroupBlock(group: g, branches: false, items: items, detail: g == .removable ? total(items) : nil, limit: g == .removable ? 5 : 8) {
                WorktreeRow(worktree: $0, size: store.sizes[$0.path], mainPath: main)
              }
            }
          }
          if list.count == 1 {
            Text(L("Só o working tree principal: nenhum git worktree add neste repositório.")).font(.caption).foregroundStyle(.secondary)
          }
        } else {
          ProgressView().controlSize(.small)
        }
        RemoveUnusedFooter(cleanupLink: true, action: removeUnused)
      }.padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Text(L("Worktrees")).font(.callout.weight(.medium))
        if let list = store.worktrees[project.id] {
          Badge(text: "\(list.count)")
          let gone = list.filter { worktreeGroup($0.facts) == .removable }
          if let note = removableNote(gone.count, bytes: gone.compactMap { store.sizes[$0.path] }.reduce(0, +)) {
            Text(note).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if open {
          if store.loading.contains("w:" + project.id) { ProgressView().controlSize(.mini) }
          Button {
            store.loadWorktrees(project)
          } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(L("Atualizar")).accessibilityLabel(L("Atualizar"))
        }
      }
    }
    .onChange(of: open) { _, isOpen in if isOpen { store.loadWorktrees(project) } }
  }
  private func total(_ items: [WorktreeView]) -> String? {
    let bytes = items.compactMap { store.sizes[$0.path] }.reduce(0, +)
    return bytes > 0 ? formatBytes(Double(bytes)) : nil
  }
}

private struct WorktreeRow: View {
  let worktree: WorktreeView
  let size: UInt64?
  let mainPath: String?
  var body: some View {
    let w = worktree
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: w.main ? "house" : "arrow.triangle.branch").foregroundStyle(w.current ? Tint.brand : .secondary).frame(width: 14)
        Text(w.branch.map(shownBranch) ?? L("HEAD destacado em %@", w.head)).font(.callout.weight(w.current ? .semibold : .regular)).lineLimit(1)
        if w.main { Badge(text: L("principal"), color: .secondary) }
        if w.current { Badge(text: L("este projeto"), color: Tint.brand) }
        if let agent = w.agent { Badge(text: agent, color: .purple) }
        Spacer(minLength: 6)
        if w.prunable {
          Badge(text: L("pasta sumiu"), color: .red).help(L("O git ainda lista este worktree; git worktree prune (ou a Limpeza) tira da lista."))
        } else if let size {
          Text(formatBytes(Double(size))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else {
          ProgressView().controlSize(.mini).help(L("Medindo o tamanho…"))
        }
        if !w.prunable {
          OpenTerminalButton(folder: w.path, borderless: true)
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
          } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L("Mostrar no Finder")).accessibilityLabel(L("Mostrar no Finder"))
        }
      }
      HStack(spacing: 5) {
        Text(place(w.path, main: mainPath)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 4)
        MergedBadge(merged: w.merged)
        if w.gone { Badge(text: L("upstream removido"), color: .secondary) }
        if let n = w.changes, n > 0 { Badge(text: L("%@ alterações", "\(n)"), color: .orange) }
        if let user = w.in_use { Badge(text: L("em uso"), color: .blue).help(L("Em uso por %@", user)) }
        if w.locked { Badge(text: L("bloqueado"), color: .secondary, symbol: "lock.fill").help(L("git worktree lock: o git não remove este worktree")) }
        if let t = w.last_commit { Text(ago(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
      }.padding(.leading, 20)
    }
    .padding(.vertical, 2)
  }
}

struct InstructionFileState: Decodable, Equatable {
  let file: String
  let exists: Bool
  let state: String
  var name: String { (file as NSString).lastPathComponent }
}
struct AgentInstructions: Decodable, Equatable {
  let folder: String
  let text: String?
  let files: [InstructionFileState]
}

/// What the project's .corescope.yml asks of agents, and the marked section in CLAUDE.md /
/// AGENTS.md for agents without CoreScope's session hook. Writes only after a click.
struct AgentInstructionsSheet: View {
  let project: ProjectEntry
  @Environment(\.dismiss) private var dismiss
  @ViewState private var state: AgentInstructions?
  @ViewState private var error: String?
  @ViewState private var chosen: Set<String> = ["CLAUDE.md", "AGENTS.md"]
  @ViewState private var busy = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Instruções para agentes")).font(.title3.weight(.semibold))
      Text(L("O que o .corescope.yml deste projeto pede aos agentes. Com o hook de contexto ligado (Ajustes › Servidor MCP), Claude Code e Codex recebem isto no início de cada sessão; para outros agentes, grave como uma seção marcada no CLAUDE.md / AGENTS.md (o resto do arquivo fica como está)."))
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let state, let text = state.text {
        ScrollView {
          Text(Demo.enabled ? L("O texto fica oculto no modo de demonstração.") : text)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .frame(height: 190)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        ForEach(state.files, id: \.file) { f in
          HStack {
            Toggle(f.name, isOn: Binding(get: { chosen.contains(f.name) }, set: { if $0 { chosen.insert(f.name) } else { chosen.remove(f.name) } }))
              .toggleStyle(.checkbox)
            Spacer()
            Badge(text: label(f), color: f.state == "current" ? .green : f.state == "outdated" ? .orange : .secondary)
          }
        }
      } else if error == nil {
        ProgressView().controlSize(.small)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if state?.files.contains(where: { $0.state != "missing" && chosen.contains($0.name) }) == true {
          Button(L("Remover seção"), role: .destructive) { run(remove: true) }.disabled(busy)
        }
        Spacer()
        Button(L("Fechar")) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(L("Gravar seção")) { run(remove: false) }
          .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
          .disabled(busy || chosen.isEmpty || state?.text == nil)
      }
    }
    .padding(18).frame(width: 560)
    .onAppear { load() }
  }
  private func label(_ f: InstructionFileState) -> String {
    if !f.exists { return L("arquivo não existe (será criado)") }
    switch f.state {
    case "current": return L("seção em dia")
    case "outdated": return L("seção desatualizada")
    default: return L("sem a seção")
    }
  }
  private func load() {
    DispatchQueue.global(qos: .userInitiated).async {
      let r = ProjectsTool.call(["op": "instructions", "folder": project.folder], as: AgentInstructions.self)
      DispatchQueue.main.async {
        switch r {
        case .success(let s): state = s
        case .failure(let e): error = e.message
        }
      }
    }
  }
  private func run(remove: Bool) {
    busy = true
    let files = Array(chosen).sorted()
    DispatchQueue.global(qos: .userInitiated).async {
      let r = ProjectsTool.call(["op": "write_instructions", "folder": project.folder, "files": files, "remove": remove], as: AgentInstructions.self)
      DispatchQueue.main.async {
        busy = false
        switch r {
        case .success(let s):
          state = s
          error = nil
        case .failure(let e): error = e.message
        }
      }
    }
  }
}

private func reasonText(_ r: PruneReason, defaultBranch: String?) -> String {
  switch r {
  case .merged: defaultBranch.map { L("mergeado em %@", shownBranch($0)) } ?? L("mergeado")
  case .upstreamGone: L("upstream removido")
  case .folderGone: L("pasta sumiu")
  case .worktreeRemoved: L("sai junto com o worktree")
  }
}
/// Why an item stays, or why the core refused it (`detail`: the process, the change count).
func pruneBlockText(_ b: PruneBlock, detail: String? = nil) -> String {
  switch b {
  case .main: L("working tree principal")
  case .current: L("é o checkout atual")
  case .inUse: detail.map { L("em uso por %@", $0) } ?? L("em uso")
  case .locked: L("bloqueado (git worktree lock)")
  case .notMerged: L("não mergeado")
  case .defaultBranch: L("é o branch padrão")
  case .checkedOut: L("aberto num worktree que fica")
  case .unknownChanges: L("o git não conseguiu ler as alterações")
  case .dirty: detail.map { L("%@ alterações não commitadas", $0) } ?? L("alterações não commitadas")
  case .notAWorktree: L("não é mais um worktree deste projeto")
  case .noSuchBranch: L("o branch não existe mais")
  }
}

/// Confirmation before removing a project's unused worktrees and branches: exactly what goes,
/// why each qualifies, what stays and why; checkboxes per item. Lists are read again on opening
/// and the core checks every item again before `git worktree remove` / `git branch -d`.
struct RemoveUnusedSheet: View {
  let project: ProjectEntry
  @ObservedObject var store = ProjectRefsStore.shared
  @Environment(\.dismiss) private var dismiss
  @ViewState private var requested = false
  @ViewState private var seeded = false
  @ViewState private var chosen: Set<String> = []
  @ViewState private var allowDirty = false
  @ViewState private var busy = false
  @ViewState private var results: [RemovalResult]?
  @ViewState private var error: String?

  private var trees: [WorktreeView] { store.worktrees[project.id] ?? [] }
  private var list: BranchList? { store.branches[project.id] }
  private var ready: Bool {
    requested && store.worktrees[project.id] != nil && list != nil
      && !store.loading.contains("w:" + project.id) && !store.loading.contains("b:" + project.id)
  }
  private func candidates(chosenWorktrees: Set<String>) -> [PruneCandidate] {
    pruneCandidates(
      worktrees: trees.map(\.facts), branches: list?.branches.map(\.facts) ?? [], defaultBranch: list?.default,
      allowDirty: allowDirty, chosenWorktrees: chosenWorktrees)
  }
  private var current: [PruneCandidate] {
    candidates(chosenWorktrees: Set(chosen.filter { $0.hasPrefix("w:") }.map { String($0.dropFirst(2)) }))
  }
  /// The ticked items the rules allow right now.
  private var selected: [PruneCandidate] { current.filter { $0.verdict.removable && chosen.contains($0.key) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L("Remover worktrees e branches não usados")).font(.title3.weight(.semibold))
      Text(
        L(
          "Worktrees mergeados (ou com o upstream removido) que nenhum processo está usando, e branches locais mergeados em %@ sem worktree. Usa git worktree remove e git branch -d: nada é forçado e o git recusa o que tiver trabalho não salvo. Arquivos ignorados dentro de um worktree (node_modules, builds, .env) saem junto com ele.",
          shownBranch(list?.default ?? "main"))
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let results {
        resultList(results)
      } else if ready {
        candidateList
      } else {
        HStack {
          ProgressView().controlSize(.small)
          Text(L("Lendo worktrees e branches…")).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if results == nil, ready {
          Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Spacer()
        if results != nil {
          Button(L("Fechar")) { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
          Button(L("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
          Button(L("Remover"), role: .destructive) { remove() }
            .buttonStyle(.borderedProminent).tint(.red)
            .disabled(busy || !ready || selected.isEmpty)
        }
      }
    }
    .padding(18).frame(width: 640)
    .onAppear {
      store.loadWorktrees(project)
      store.loadBranches(project)
      requested = true
    }
    .onChange(of: ready) { _, isReady in
      guard isReady, !seeded else { return }
      seeded = true
      let all = candidates(chosenWorktrees: Set(trees.map(\.path)))
      chosen = defaultPruneSelection(all, worktrees: trees.map(\.facts))
    }
  }

  private var summary: String {
    let w = selected.filter { $0.kind == .worktree }
    let b = selected.count - w.count
    let bytes = w.compactMap { store.sizes[$0.target] }.reduce(0, +)
    var text = L("%@ worktrees · %@ branches", "\(w.count)", "\(b)")
    if bytes > 0 { text += " · " + formatBytes(Double(bytes)) }
    return text
  }

  @ViewBuilder private var candidateList: some View {
    let items = current
    let wts = items.filter { $0.kind == .worktree }
    let brs = items.filter { $0.kind == .branch }
    if items.isEmpty {
      Label(L("Nada para remover: nenhum worktree ou branch mergeado fora de uso."), systemImage: "checkmark.circle")
        .font(.callout).foregroundStyle(.secondary)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if !wts.isEmpty { section(L("Worktrees"), wts) }
          if !brs.isEmpty { section(L("Branches locais"), brs) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 380)
      if trees.contains(where: { worktreeVerdict($0.facts).block == .dirty }) {
        Toggle(isOn: $allowDirty) {
          Text(L("Permitir worktrees com alterações não commitadas (git worktree remove --force; as alterações se perdem)"))
        }
        .toggleStyle(.checkbox).font(.callout)
        .onChange(of: allowDirty) { _, on in
          if !on { chosen = chosen.filter { key in !trees.contains { "w:" + $0.path == key && ($0.changes ?? 0) > 0 } } }
        }
      }
    }
  }

  private func section(_ title: String, _ items: [PruneCandidate]) -> some View {
    let choosable = items.filter(\.verdict.removable).map(\.key)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.callout.weight(.semibold))
        Badge(text: "\(choosable.count)/\(items.count)")
        Spacer()
        if !choosable.isEmpty {
          let all = choosable.allSatisfy(chosen.contains)
          Button(all ? L("Nenhum") : L("Selecionar tudo")) {
            if all { chosen.subtract(choosable) } else { chosen.formUnion(choosable) }
          }
          .buttonStyle(.borderless).controlSize(.small)
        }
      }
      ForEach(items, id: \.key) { row($0) }
    }
  }

  private func row(_ c: PruneCandidate) -> some View {
    let w = c.kind == .worktree ? trees.first { $0.path == c.target } : nil
    let main = trees.first(where: \.main)?.path
    let title = c.kind == .branch ? shownBranch(c.target) : (w?.branch.map(shownBranch) ?? L("HEAD destacado em %@", w?.head ?? "?"))
    let detail: String? =
      switch c.verdict.block {
      case .inUse: w?.in_use
      case .dirty: w?.changes.map { "\($0)" }
      default: nil
      }
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Toggle(
        "",
        isOn: Binding(
          get: { c.verdict.removable && chosen.contains(c.key) },
          set: { if $0 { chosen.insert(c.key) } else { chosen.remove(c.key) } })
      )
      .toggleStyle(.checkbox).labelsHidden().disabled(!c.verdict.removable)
      .accessibilityLabel(title)
      Image(systemName: c.kind == .worktree ? "folder" : "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title).font(.callout.weight(.medium)).lineLimit(1)
          if let agent = w?.agent { Badge(text: agent, color: .purple) }
          Spacer(minLength: 6)
          if let w, !w.prunable {
            if let size = store.sizes[w.path] {
              Text(formatBytes(Double(size))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
              ProgressView().controlSize(.mini).help(L("Medindo o tamanho…"))
            }
          }
        }
        if let w { Text(place(w.path, main: main)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        HStack(spacing: 5) {
          Text(c.verdict.reasons.map { reasonText($0, defaultBranch: list?.default) }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary)
          if let block = c.verdict.block {
            Label(pruneBlockText(block, detail: detail), systemImage: "exclamationmark.circle")
              .font(.caption).foregroundStyle(.orange)
          }
        }
      }
    }
    .opacity(c.verdict.removable ? 1 : 0.7)
  }

  private func resultList(_ results: [RemovalResult]) -> some View {
    let main = trees.first(where: \.main)?.path
    let removed = results.filter { $0.status == "removed" }.count
    return VStack(alignment: .leading, spacing: 8) {
      Label(L("%@ de %@ removidos", "\(removed)", "\(results.count)"), systemImage: removed == results.count ? "checkmark.circle.fill" : "exclamationmark.circle")
        .font(.callout.weight(.medium)).foregroundStyle(removed == results.count ? .green : .orange)
      ScrollView {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(results) { r in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Image(systemName: r.status == "removed" ? "checkmark.circle.fill" : r.status == "refused" ? "minus.circle" : "xmark.octagon")
                .foregroundStyle(r.status == "removed" ? .green : r.status == "refused" ? .orange : .red).frame(width: 14)
              Text(r.kind == "branch" ? shownBranch(r.target) : place(r.target, main: main)).font(.callout).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: 6)
              if let reason = r.reason {
                Text(PruneBlock(rawValue: reason).map { pruneBlockText($0) } ?? reason).font(.caption).foregroundStyle(.orange)
              } else if let message = r.message {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 380)
    }
  }

  private func remove() {
    let items = selected
    busy = true
    error = nil
    store.removeUnused(
      project, worktrees: items.filter { $0.kind == .worktree }.map(\.target), branches: items.filter { $0.kind == .branch }.map(\.target),
      allowDirty: allowDirty
    ) { r in
      busy = false
      switch r {
      case .success(let list): results = list
      case .failure(let e): error = e.message
      }
    }
  }
}
