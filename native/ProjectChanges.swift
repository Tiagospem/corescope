import AppKit
import CoreServices
import SwiftUI

struct GitFileChange: Decodable, Equatable {
  let path: String
  let orig_path: String?
  let index: String
  let worktree: String
  let conflict: Bool
  let untracked: Bool
  let staged_added: Int?
  let staged_removed: Int?
  let added: Int?
  let removed: Int?
  let binary: Bool
  var staged: Bool { !conflict && index != "." && index != "?" }
  var unstaged: Bool { untracked || (!conflict && worktree != ".") }
}
struct GitBranchState: Decodable, Equatable {
  let head: String?
  let oid: String?
  let upstream: String?
  let ahead: Int?
  let behind: Int?
}
struct GitLastCommit: Decodable, Equatable {
  let short: String
  let subject: String
  let author: String
  let time: Double
}
struct GitStatus: Decodable, Equatable {
  let root: String
  let branch: GitBranchState
  let last_commit: GitLastCommit?
  let files: [GitFileChange]
  let truncated: Int
  let staged: Int
  let modified: Int
  let untracked: Int
  let removed_renamed: Int
  let conflicts: Int
  let locked: Bool
}
private struct GitDiff: Decodable { let diff: String }
private struct GitCommitOutput: Decodable { let output: String }
private struct GitIgnored: Decodable { let ignored: [String] }
private struct GitDone: Decodable {}

/// The groups of the changes list, in order. A partially staged file is in Staged and in one
/// unstaged group.
enum ChangeGroup: String, CaseIterable {
  case conflicts, staged, modified, untracked, removed
  var title: String {
    switch self {
    case .conflicts: L("Conflitos")
    case .staged: L("Staged")
    case .modified: L("Modificados")
    case .untracked: L("Novos")
    case .removed: L("Removidos/Renomeados")
    }
  }
  func contains(_ f: GitFileChange) -> Bool {
    switch self {
    case .conflicts: f.conflict
    case .staged: f.staged
    case .untracked: f.untracked
    case .removed: !f.conflict && f.worktree == "D"
    case .modified: !f.conflict && !f.untracked && f.worktree != "." && f.worktree != "D"
    }
  }
}
struct ChangeRow: Identifiable, Hashable {
  let group: ChangeGroup
  let file: GitFileChange
  var id: String { "\(group.rawValue):\(file.path)" }
  static func == (a: ChangeRow, b: ChangeRow) -> Bool { a.id == b.id }
  func hash(into h: inout Hasher) { h.combine(id) }
  /// The status letter shown for this row.
  var letter: String {
    if group == .conflicts { return "!" }
    if group == .untracked { return "U" }
    let c = group == .staged ? file.index : file.worktree
    return c == "." ? "M" : c
  }
  var lines: (Int, Int)? {
    let pair = group == .staged ? (file.staged_added, file.staged_removed) : (file.added, file.removed)
    guard let a = pair.0, let r = pair.1 else { return nil }
    return (a, r)
  }
}

/// One project's working tree: status, the selected file's diff, and the git commands of the
/// commit panel. Reads run on a serial queue; the file watcher only exists while the view is on
/// screen.
final class ProjectChangesStore: ObservableObject {
  let folder: String
  @Published private(set) var status: GitStatus?
  @Published private(set) var root: String?
  @Published private(set) var loading = false
  @Published var error: String?
  @Published var commitOutput: String?
  @Published var commitFailed = false
  @Published private(set) var diff: String?
  @Published private(set) var diffFor: String?
  @Published private(set) var busy = false
  private let queue = DispatchQueue(label: "app.corescope.project-changes", qos: .userInitiated)
  private var watcher: RepoWatcher?
  private var reloadPending = false

  init(folder: String) { self.folder = folder }

  private var active = false
  func start() {
    active = true
    reload()
  }
  func stop() {
    active = false
    watcher = nil
    root = nil
  }

  func reload() {
    if reloadPending { return }
    reloadPending = true
    loading = status == nil
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let r = ProjectsTool.call(["op": "status", "folder": self.folder], as: GitStatus.self)
      DispatchQueue.main.async {
        self.reloadPending = false
        self.loading = false
        switch r {
        case .success(let s):
          if s != self.status { self.status = s }
          if self.active && self.root != s.root {
            self.root = s.root
            self.watch(s.root)
          }
        case .failure(let e): self.error = e.message
        }
      }
    }
  }

  private func watch(_ root: String) {
    watcher = RepoWatcher(folder: folder, root: root) { [weak self] in
      guard let self, self.active else { return }
      self.reload()
    }
  }

  func loadDiff(_ row: ChangeRow?) {
    guard let row else {
      diff = nil
      diffFor = nil
      return
    }
    let key = row.id
    diffFor = key
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let r = ProjectsTool.call(["op": "diff", "folder": self.folder, "path": row.file.path, "staged": row.group == .staged], as: GitDiff.self)
      DispatchQueue.main.async {
        guard self.diffFor == key else { return }
        switch r {
        case .success(let d): self.diff = d.diff
        case .failure(let e): self.diff = e.message
        }
      }
    }
  }

  private func run(_ request: [String: Any], done: (() -> Void)? = nil) {
    busy = true
    error = nil
    queue.async {
      var request = request
      request["folder"] = self.folder
      let r = ProjectsTool.call(request, as: GitDone.self)
      DispatchQueue.main.async {
        self.busy = false
        if case .failure(let e) = r { self.error = e.message } else { self.error = nil }
        self.reload()
        done?()
      }
    }
  }
  func stage(_ paths: [String]) { if !paths.isEmpty { run(["op": "stage", "paths": paths]) } }
  func unstage(_ paths: [String]) { if !paths.isEmpty { run(["op": "unstage", "paths": paths]) } }

  /// Tracked files go back to the last commit; new files go to the Trash, as in Cleanup.
  func discard(_ files: [GitFileChange]) {
    let tracked = files.filter { !$0.untracked }.map(\.path)
    let untracked = files.filter(\.untracked).map(\.path)
    if let root {
      var failed: [String] = []
      for path in untracked {
        do {
          try FileManager.default.trashItem(at: URL(fileURLWithPath: root).appendingPathComponent(path), resultingItemURL: nil)
        } catch { failed.append(path) }
      }
      if !failed.isEmpty { error = L("Não foi possível mover para o Lixo: %@", failed.joined(separator: ", ")) }
    }
    if tracked.isEmpty { reload() } else { run(["op": "discard", "paths": tracked]) }
  }

  func commit(_ message: String, done: @escaping (Bool) -> Void) {
    busy = true
    commitOutput = nil
    queue.async {
      let r = ProjectsTool.call(["op": "commit", "folder": self.folder, "message": message], as: GitCommitOutput.self)
      DispatchQueue.main.async {
        self.busy = false
        switch r {
        case .success(let o):
          self.commitOutput = o.output
          self.commitFailed = false
          done(true)
        case .failure(let e):
          self.commitOutput = e.message
          self.commitFailed = true
          done(false)
        }
        self.reload()
      }
    }
  }
}

/// A repository's working tree watched for changes that matter to git: inside `.git` only HEAD,
/// the index, refs and MERGE_HEAD count, and paths `.gitignore` covers are dropped (one
/// `git check-ignore` per folder, cached). Calls `onChange` at most every half second.
final class RepoWatcher {
  private let folder: String
  private let root: String
  private let onChange: () -> Void
  private var watcher: FileWatcher?
  private var ignoredDirs: [String: Bool] = [:]
  private var scheduled = false
  private let queue = DispatchQueue(label: "app.corescope.repo-watcher", qos: .utility)

  init(folder: String, root: String, onChange: @escaping () -> Void) {
    self.folder = folder
    self.root = root
    self.onChange = onChange
    watcher = FileWatcher(path: root) { [weak self] paths in self?.changed(paths) }
  }

  private func schedule() {
    if scheduled { return }
    scheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self else { return }
      self.scheduled = false
      self.onChange()
    }
  }

  private func changed(_ paths: [String]) {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var relevant: [String] = []
    var gitState = false
    for path in paths {
      guard path.hasPrefix(prefix) else { continue }
      let rel = String(path.dropFirst(prefix.count))
      if rel == ".git" || rel.hasPrefix(".git/") {
        let inner = rel.dropFirst(5)
        if inner == "HEAD" || inner == "index" || inner.hasPrefix("refs/") || inner == "MERGE_HEAD" { gitState = true }
        continue
      }
      if !rel.isEmpty { relevant.append(rel) }
    }
    if gitState {
      schedule()
      return
    }
    // Under a folder already known to be ignored: nothing to ask.
    relevant.removeAll { path in pathAncestors(path).contains { ignoredDirs[$0] == true } }
    guard !relevant.isEmpty else { return }
    let unknown = Set(relevant.flatMap(pathAncestors)).filter { ignoredDirs[$0] == nil }
    let folder = folder
    queue.async { [weak self] in
      var answers: [String: Bool] = [:]
      var ignoredFiles = Set<String>()
      let ask = Array(unknown.map { $0 + "/" }) + relevant
      if let r = try? ProjectsTool.call(["op": "ignored", "folder": folder, "paths": Array(ask.prefix(500))], as: GitIgnored.self).get() {
        let hits = Set(r.ignored)
        for dir in unknown { answers[dir] = hits.contains(dir + "/") }
        ignoredFiles = hits
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.ignoredDirs.merge(answers) { $1 }
        let kept = relevant.filter { path in
          !ignoredFiles.contains(path) && !pathAncestors(path).contains { self.ignoredDirs[$0] == true }
        }
        if !kept.isEmpty { self.schedule() }
      }
    }
  }
}

/// FSEvents on one folder tree, coalesced by the system for half a second.
final class FileWatcher {
  private var stream: FSEventStreamRef?
  private let handler: ([String]) -> Void

  init?(path: String, handler: @escaping ([String]) -> Void) {
    self.handler = handler
    var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    context.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
      watcher.handler(Array(list.prefix(count)))
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    FSEventStreamStart(stream)
  }
  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }
}

/// Editors that open a file (first one installed is the default; the choice is remembered).
enum CodeEditor {
  static let known: [(name: String, bundle: String)] = [
    ("Zed", "dev.zed.Zed"), ("Cursor", "com.todesktop.230313mzl4w4u92"), ("Visual Studio Code", "com.microsoft.VSCode"),
    ("PhpStorm", "com.jetbrains.PhpStorm"), ("WebStorm", "com.jetbrains.WebStorm"), ("IntelliJ IDEA", "com.jetbrains.intellij"),
    ("RustRover", "com.jetbrains.rustrover"), ("Sublime Text", "com.sublimetext.4"), ("Xcode", "com.apple.dt.Xcode"),
    ("Nova", "com.panic.Nova"), ("BBEdit", "com.barebones.bbedit"),
  ]
  static var installed: [(name: String, bundle: String, url: URL)] {
    known.compactMap { e in NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundle).map { (e.name, e.bundle, $0) } }
  }
  static var preferred: String? {
    get { UserDefaults.standard.string(forKey: "projectsEditor") }
    set { UserDefaults.standard.set(newValue, forKey: "projectsEditor") }
  }
  static func open(_ file: URL, with bundle: String? = nil) {
    let apps = installed
    let pick = bundle ?? preferred
    if let app = apps.first(where: { $0.bundle == pick }) ?? (pick == "default" ? nil : apps.first) {
      if bundle != nil { preferred = bundle }
      NSWorkspace.shared.open([file], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    } else {
      if bundle != nil { preferred = bundle }
      NSWorkspace.shared.open(file)
    }
  }
}

private func shownPath(_ path: String) -> String { Demo.enabled ? Demo.path(path) : abbreviateHome(path) }
/// In demo mode file names stay, folders are anonymized.
private func shownRelative(_ path: String) -> String {
  guard Demo.enabled else { return path }
  let name = (path as NSString).lastPathComponent
  let dir = (path as NSString).deletingLastPathComponent
  return dir.isEmpty ? name : "\(demoPick(["src", "app", "lib", "tests", "docs"], dir))/\(name)"
}

/// The commit panel of one project: header, grouped changes, diff and the commit box.
struct ProjectChangesView: View {
  let project: ProjectEntry
  let back: () -> Void
  @StateObject private var store: ProjectChangesStore
  @ViewState private var selection: Set<String> = []
  @ViewState private var message = ""
  @ViewState private var confirmDiscard: [GitFileChange]?

  init(project: ProjectEntry, back: @escaping () -> Void) {
    self.project = project
    self.back = back
    _store = StateObject(wrappedValue: ProjectChangesStore(folder: project.folder))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, 20).padding(.vertical, 12)
      Divider()
      if let error = store.error { banner(error, symbol: "exclamationmark.triangle.fill", color: .red) }
      if store.status?.locked == true {
        banner(L("Outro processo git está usando este repositório (index.lock). Espere ele terminar ou remova o lock antigo."), symbol: "lock.fill", color: .orange)
      }
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          list
          Divider()
          commitBox.padding(12)
        }
        .frame(width: 400)
        Divider()
        DiffView(text: store.diff, empty: selectedRows.count > 1 ? L("%@ arquivos selecionados", "\(selectedRows.count)") : L("Selecione um arquivo para ver o diff."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear { store.start() }
    .onDisappear { store.stop() }
    .onChange(of: selection) { _, _ in store.loadDiff(selectedRows.count == 1 ? selectedRows.first : nil) }
    .onChange(of: store.status) { _, _ in
      let ids = Set(rows.map(\.id))
      let kept = selection.intersection(ids)
      if kept != selection { selection = kept } else if let row = selectedRows.first, selectedRows.count == 1 { store.loadDiff(row) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.reload() }
    .confirmationDialog(discardTitle, isPresented: Binding(get: { confirmDiscard != nil }, set: { if !$0 { confirmDiscard = nil } })) {
      Button(L("Descartar"), role: .destructive) {
        if let files = confirmDiscard { store.discard(files) }
        confirmDiscard = nil
      }
      Button(L("Cancelar"), role: .cancel) { confirmDiscard = nil }
    } message: {
      Text(discardMessage)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button(action: back) { Label(L("Projetos"), systemImage: "chevron.left") }.buttonStyle(.borderless)
        Text(shownProjectName(project)).font(.title3.weight(.semibold))
        Spacer()
        if store.loading || store.busy { ProgressView().controlSize(.small) }
        Button {
          store.reload()
        } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(HoverButtonStyle()).help(L("Atualizar"))
          .accessibilityLabel(L("Atualizar"))
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.folder)])
        } label: { Image(systemName: "folder") }.buttonStyle(HoverButtonStyle()).help(L("Mostrar no Finder"))
          .accessibilityLabel(L("Mostrar no Finder"))
      }
      if let s = store.status {
        HStack(spacing: 8) {
          Image(systemName: "arrow.triangle.branch").foregroundStyle(Tint.brand)
          Text(s.branch.head.map(shownBranch) ?? L("HEAD destacado em %@", s.branch.oid.map { String($0.prefix(7)) } ?? "?")).font(.callout.weight(.medium))
          if let up = s.branch.upstream {
            Text(Demo.enabled ? "origin" : up).font(.caption).foregroundStyle(.secondary)
            Badge(text: "↑\(s.branch.ahead ?? 0)  ↓\(s.branch.behind ?? 0)", color: (s.branch.behind ?? 0) > 0 ? .orange : .secondary)
              .help(L("Commits à frente / atrás do upstream"))
          } else {
            Badge(text: L("sem upstream"), color: .secondary)
          }
          Spacer()
        }
        if let c = s.last_commit {
          HStack(spacing: 6) {
            Text(c.short).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text(Demo.enabled ? L("Último commit") : c.subject).font(.caption).lineLimit(1)
            Text("· \(Demo.enabled ? "dev" : c.author) · \(Date(timeIntervalSince1970: c.time).formatted(.relative(presentation: .named)))")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        } else if s.branch.oid == nil {
          Text(L("Sem commits ainda")).font(.caption).foregroundStyle(.secondary)
        }
      } else {
        Text(shownPath(project.folder)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func banner(_ text: String, symbol: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(color)
      Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(6)
      Spacer()
      if store.error == text {
        Button {
          store.error = nil
        } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(L("Fechar"))
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 8).background(color.opacity(0.08))
  }

  private var rows: [ChangeRow] {
    guard let s = store.status else { return [] }
    return ChangeGroup.allCases.flatMap { g in s.files.filter(g.contains).map { ChangeRow(group: g, file: $0) } }
  }
  private var selectedRows: [ChangeRow] { rows.filter { selection.contains($0.id) } }

  private var list: some View {
    let all = rows
    return VStack(spacing: 0) {
      HStack(spacing: 8) {
        let s = store.status
        Text(s.map { L("%@ alterações", "\($0.files.count + $0.truncated)") } ?? "").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(L("Stage em tudo")) { store.stage(all.filter { $0.group != .staged && $0.group != .conflicts }.map(\.file.path)) }
          .controlSize(.small).disabled(store.busy || !all.contains { $0.group != .staged && $0.group != .conflicts })
        Button(L("Unstage em tudo")) { store.unstage(all.filter { $0.group == .staged }.map(\.file.path)) }
          .controlSize(.small).disabled(store.busy || !all.contains { $0.group == .staged })
      }.padding(.horizontal, 12).padding(.vertical, 8)
      if let s = store.status, s.files.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.green)
          Text(L("Nada para commitar: a árvore de trabalho está limpa.")).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $selection) {
          ForEach(ChangeGroup.allCases, id: \.self) { group in
            let items = all.filter { $0.group == group }
            if !items.isEmpty {
              Section {
                ForEach(items) { row in
                  ChangeRowView(row: row, busy: store.busy) { checked in
                    let paths = targets(row).map(\.file.path)
                    checked ? store.stage(paths) : store.unstage(paths)
                  }
                  .tag(row.id)
                  .contextMenu { menu(for: row) }
                }
              } header: {
                HStack {
                  Text(group.title)
                  Badge(text: "\(items.count)", color: group == .conflicts ? .red : .secondary)
                }
              }
            }
          }
          if let s = store.status, s.truncated > 0 {
            Text(L("… e mais %@ (limite de exibição)", "\(s.truncated)")).font(.caption).foregroundStyle(.secondary)
          }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { askDiscard(selectedRows.isEmpty ? [] : selectedRows) }
      }
    }
  }

  /// The row itself, or every selected row when it is part of the selection.
  private func targets(_ row: ChangeRow) -> [ChangeRow] {
    selection.contains(row.id) ? selectedRows.filter { $0.group == row.group } : [row]
  }

  @ViewBuilder private func menu(for row: ChangeRow) -> some View {
    let rows = selection.contains(row.id) ? selectedRows : [row]
    let stageable = rows.filter { $0.group != .staged && $0.group != .conflicts }
    let unstageable = rows.filter { $0.group == .staged }
    if !stageable.isEmpty { Button(rows.count > 1 ? L("Stage (%@)", "\(stageable.count)") : L("Stage")) { store.stage(stageable.map(\.file.path)) } }
    if !unstageable.isEmpty { Button(rows.count > 1 ? L("Unstage (%@)", "\(unstageable.count)") : L("Unstage")) { store.unstage(unstageable.map(\.file.path)) } }
    if rows.contains(where: { $0.group == .conflicts }) {
      Button(L("Marcar como resolvido (stage)")) { store.stage(rows.filter { $0.group == .conflicts }.map(\.file.path)) }
    }
    Divider()
    if let root = store.root {
      let url = URL(fileURLWithPath: root).appendingPathComponent(row.file.path)
      Menu(L("Abrir no editor")) {
        ForEach(CodeEditor.installed, id: \.bundle) { e in Button(e.name) { CodeEditor.open(url, with: e.bundle) } }
        Divider()
        Button(L("App padrão do arquivo")) { CodeEditor.open(url, with: "default") }
      }
      Button(L("Mostrar no Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      Button(L("Copiar caminho")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.file.path, forType: .string)
      }
    }
    Divider()
    Button(rows.count > 1 ? L("Descartar alterações (%@)…", "\(rows.count)") : L("Descartar alterações…"), role: .destructive) { askDiscard(rows) }
  }

  private func askDiscard(_ rows: [ChangeRow]) {
    var seen = Set<String>()
    let files = rows.map(\.file).filter { seen.insert($0.path).inserted }
    if !files.isEmpty { confirmDiscard = files }
  }
  private var discardTitle: String {
    guard let files = confirmDiscard else { return "" }
    return files.count == 1 ? L("Descartar as alterações de %@?", (shownRelative(files[0].path) as NSString).lastPathComponent) : L("Descartar as alterações de %@ arquivos?", "\(files.count)")
  }
  private var discardMessage: String {
    let files = confirmDiscard ?? []
    let new = files.filter(\.untracked).count
    let tracked = files.count - new
    var parts: [String] = []
    if tracked > 0 { parts.append(L("%@ arquivo(s) voltam ao último commit, incluindo o que está em stage. Não dá para desfazer.", "\(tracked)")) }
    if new > 0 { parts.append(L("%@ arquivo(s) novo(s) vão para o Lixo.", "\(new)")) }
    return parts.joined(separator: " ")
  }

  private var stagedCount: Int { store.status?.staged ?? 0 }
  private var canCommit: Bool {
    !store.busy && stagedCount > 0 && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (store.status?.conflicts ?? 0) == 0
  }
  private var commitBox: some View {
    VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topLeading) {
        TextEditor(text: $message).font(.system(.callout)).frame(minHeight: 54, maxHeight: 110)
          .scrollContentBackground(.hidden).padding(4)
          .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        if message.isEmpty {
          Text(L("Mensagem do commit")).font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
        }
      }
      HStack {
        Text(commitHint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        Button {
          store.commit(message) { ok in if ok { message = "" } }
        } label: {
          Text(stagedCount > 0 ? L("Commit (%@)", "\(stagedCount)") : L("Commit"))
        }
        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command).disabled(!canCommit)
        .help(L("⌘↩ faz o commit do que está em stage"))
      }
      if let out = store.commitOutput, !out.isEmpty {
        ScrollView {
          Text(out).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120).padding(6)
        .background((store.commitFailed ? Color.red : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
          Button {
            store.commitOutput = nil
          } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).padding(4).accessibilityLabel(L("Fechar"))
        }
      }
    }
  }
  private var commitHint: String {
    if (store.status?.conflicts ?? 0) > 0 { return L("Resolva os conflitos antes de commitar.") }
    if stagedCount == 0 { return L("Nada em stage: marque os arquivos que entram no commit.") }
    return L("Os hooks e a assinatura do seu git rodam normalmente.")
  }
}

private struct ChangeRowView: View {
  let row: ChangeRow
  let busy: Bool
  let toggle: (Bool) -> Void
  var body: some View {
    let path = shownRelative(row.file.path)
    let name = (path as NSString).lastPathComponent
    let dir = (path as NSString).deletingLastPathComponent
    HStack(spacing: 6) {
      if row.group != .conflicts {
        Toggle(
          "", isOn: Binding(get: { row.group == .staged }, set: { toggle($0) })
        ).toggleStyle(.checkbox).labelsHidden().disabled(busy)
          .help(row.group == .staged ? L("Tirar do stage") : L("Colocar em stage"))
      } else {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).frame(width: 16)
      }
      Text(name).lineLimit(1)
      if let orig = row.file.orig_path, row.group == .staged {
        Text("← \((shownRelative(orig) as NSString).lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Text(dir).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
      Spacer(minLength: 4)
      if row.file.binary {
        Text(L("binário")).font(.caption2).foregroundStyle(.secondary)
      } else if let (a, r) = row.lines {
        if a > 0 { Text(verbatim: "+\(a)").font(.caption.monospacedDigit()).foregroundStyle(.green) }
        if r > 0 { Text(verbatim: "−\(r)").font(.caption.monospacedDigit()).foregroundStyle(.red) }
      }
      Text(verbatim: row.letter).font(.system(.caption, design: .monospaced).weight(.bold)).foregroundStyle(color).frame(width: 12)
    }
    .help(row.file.path)
  }
  private var color: Color {
    switch row.letter {
    case "U", "A": .green
    case "D": .red
    case "R", "C": .blue
    case "!": .red
    default: .orange
    }
  }
}

/// A unified diff with added and removed lines tinted.
private struct DiffView: View {
  let text: String?
  let empty: String
  var body: some View {
    if text != nil, Demo.enabled {
      placeholder(L("O diff fica oculto no modo de demonstração."))
    } else if let text {
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      if lines.allSatisfy({ $0.isEmpty }) {
        placeholder(L("Sem diferenças de texto (só o modo do arquivo mudou, ou é binário)."))
      } else {
        ScrollView([.vertical, .horizontal]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              Text(verbatim: line.isEmpty ? " " : String(line))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(foreground(line))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(line))
            }
          }.textSelection(.enabled).padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
      }
    } else {
      placeholder(empty)
    }
  }
  private func placeholder(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func foreground(_ line: Substring) -> Color {
    if line.hasPrefix("@@") { return .blue }
    if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
    return .primary
  }
  private func background(_ line: Substring) -> Color {
    if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
    if line.hasPrefix("+") { return Color.green.opacity(0.13) }
    if line.hasPrefix("-") { return Color.red.opacity(0.13) }
    return .clear
  }
}
