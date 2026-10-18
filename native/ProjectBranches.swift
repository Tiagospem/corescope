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
  var id: String { name }
}
struct BranchList: Decodable, Equatable {
  let branches: [LocalBranch]
  let truncated: Int
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
  let changes: Int?
  let in_use: String?
  let last_commit: Double?
  let size: UInt64?
  var id: String { path }
}
private struct WorktreeSize: Decodable {
  let path: String
  let bytes: UInt64
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

  func loadBranches(_ p: ProjectEntry) {
    let key = "b:" + p.id
    guard !loading.contains(key) else { return }
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
      }
    }
  }

  func loadWorktrees(_ p: ProjectEntry) {
    let key = "w:" + p.id
    guard !loading.contains(key) else { return }
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

/// Local branches, closed by default; opening it reads them.
struct ProjectBranchesSection: View {
  let project: ProjectEntry
  @ObservedObject var store = ProjectRefsStore.shared
  @ViewState private var open = false
  @ViewState private var showAll = false
  private let first = 12
  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      let key = "b:" + project.id
      if let error = store.errors[key] {
        Text(error).font(.caption).foregroundStyle(.red)
      } else if let list = store.branches[project.id] {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(showAll ? list.branches : Array(list.branches.prefix(first))) { BranchRow(branch: $0) }
          if !showAll && list.branches.count > first {
            Button(L("Mostrar todas (%@)", "\(list.branches.count)")) { showAll = true }.buttonStyle(.borderless).controlSize(.small)
          }
          if showAll && list.truncated > 0 {
            Text(L("… e mais %@ (limite de exibição)", "\(list.truncated)")).font(.caption).foregroundStyle(.secondary)
          }
        }.padding(.top, 4)
      } else {
        ProgressView().controlSize(.small)
      }
    } label: {
      HStack(spacing: 6) {
        Text(L("Branches locais")).font(.callout.weight(.medium))
        if let n = store.branches[project.id]?.branches.count { Badge(text: "\(n + (store.branches[project.id]?.truncated ?? 0))") }
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
      if let wt = branch.worktree {
        Badge(text: L("worktree"), color: .orange).help(L("Em uso no worktree %@", shownFolder(wt)))
      }
      sync
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

/// The repository's worktrees, closed by default; removal stays on the Cleanup page.
struct ProjectWorktreesSection: View {
  let project: ProjectEntry
  @ObservedObject var store = ProjectRefsStore.shared
  @ViewState private var open = false
  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      let key = "w:" + project.id
      VStack(alignment: .leading, spacing: 6) {
        if let error = store.errors[key] {
          Text(error).font(.caption).foregroundStyle(.red)
        } else if let list = store.worktrees[project.id] {
          let main = list.first(where: \.main)?.path
          ForEach(list) { WorktreeRow(worktree: $0, size: store.sizes[$0.path], mainPath: main) }
          if list.count == 1 {
            Text(L("Só o working tree principal: nenhum git worktree add neste repositório.")).font(.caption).foregroundStyle(.secondary)
          }
        } else {
          ProgressView().controlSize(.small)
        }
        HStack {
          Spacer()
          Button {
            AppLinks.show(.cleanup)
          } label: { Label(L("Limpar worktrees na Limpeza"), systemImage: "arrow.right.circle") }
            .buttonStyle(.borderless).controlSize(.small)
        }
      }.padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Text(L("Worktrees")).font(.callout.weight(.medium))
        if let n = store.worktrees[project.id]?.count { Badge(text: "\(n)") }
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
}

private struct WorktreeRow: View {
  let worktree: WorktreeView
  let size: UInt64?
  let mainPath: String?
  /// Worktrees inside the main one (`.claude/worktrees/…`) show their path relative to it.
  private var place: String {
    if let main = mainPath, !worktree.main, worktree.path.hasPrefix(main + "/") {
      return String(worktree.path.dropFirst(main.count + 1))
    }
    return shownFolder(worktree.path)
  }
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
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)])
          } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help(L("Mostrar no Finder")).accessibilityLabel(L("Mostrar no Finder"))
        }
      }
      HStack(spacing: 5) {
        Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 4)
        switch w.merged {
        case .some(true): Badge(text: L("mergeado"), color: .green)
        case .some(false): Badge(text: L("não mergeado"), color: .orange)
        case .none: EmptyView()
        }
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
