import AppKit
import SwiftUI

/// Projects marked "Show in panel", with branch and change counts, for the floating panel and
/// the menu bar. Read when one of them appears; while one is on screen, file watchers (the same
/// rules as the changes panel) refresh a project's counts when its files change. Nothing runs
/// while neither is visible.
final class PanelProjectsStore: ObservableObject {
  static let shared = PanelProjectsStore()
  @Published private(set) var projects: [ProjectEntry] = []
  @Published private(set) var summaries: [String: GitSummary] = [:]
  @Published private(set) var branches: [String: String] = [:]
  private var users = Set<String>()
  private var roots: [String: String] = [:]
  private var watchers: [String: RepoWatcher] = [:]
  private let queue = DispatchQueue(label: "app.corescope.panel-projects", qos: .utility)

  /// `who` ("panel", "menu") shows the projects (true) or stopped (false).
  func use(_ who: String, _ on: Bool) {
    let wasIdle = users.isEmpty
    if on { users.insert(who) } else { users.remove(who) }
    if users.isEmpty {
      watchers = [:]
    } else if wasIdle || on {
      reload()
    }
  }

  func reload() {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let list = ((try? ProjectsTool.call(["op": "list"], as: [ProjectEntry].self).get()) ?? []).filter(\.show_in_panel)
      var roots: [String: String] = [:]
      var summaries: [String: GitSummary] = [:]
      for p in list {
        guard let c = try? ProjectsTool.call(["op": "check", "folder": p.folder], as: ProjectCheck.self).get(),
          c.git.is_repo, let root = c.git.root
        else { continue }
        roots[p.id] = root
        summaries[p.id] = try? ProjectsTool.call(["op": "summary", "folder": p.folder], as: GitSummary.self).get()
      }
      DispatchQueue.main.async {
        if list != self.projects { self.projects = list }
        if summaries != self.summaries { self.summaries = summaries }
        self.roots = roots
        self.syncWatchers()
      }
    }
  }

  private func refresh(_ id: String) {
    guard let p = projects.first(where: { $0.id == id }) else { return }
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects-git", cost) }
      let sum = try? ProjectsTool.call(["op": "summary", "folder": p.folder], as: GitSummary.self).get()
      DispatchQueue.main.async { if self.summaries[id] != sum { self.summaries[id] = sum } }
    }
  }

  private func syncWatchers() {
    guard !users.isEmpty else {
      watchers = [:]
      return
    }
    var next: [String: RepoWatcher] = [:]
    for p in projects {
      guard let root = roots[p.id] else { continue }
      next[p.id] = watchers[p.id] ?? RepoWatcher(folder: p.folder, root: root) { [weak self] in self?.refresh(p.id) }
    }
    watchers = next
  }

  /// Turns "Show in panel" on or off for a project (saved in projects.json).
  func setShown(_ project: ProjectEntry, _ on: Bool) {
    queue.async {
      _ = ProjectsTool.call(["op": "set", "id": project.id, "show_in_panel": on], as: ProjectEntry.self)
      DispatchQueue.main.async {
        ProjectsStore.shared.load()
        self.reload()
      }
    }
  }
}

/// What a compact project row says on the right: the counts that are not zero, or "clean".
struct ProjectCountsLabel: View {
  let summary: GitSummary?
  var size: CGFloat = 10
  var body: some View {
    HStack(spacing: 5) {
      if let s = summary {
        if s.total == 0 {
          Image(systemName: "checkmark").foregroundStyle(.secondary)
        } else {
          if s.conflicts > 0 { item("exclamationmark.triangle.fill", s.conflicts, .red) }
          if s.staged > 0 { item("checkmark.circle.fill", s.staged, .green) }
          if s.modified + s.removed > 0 { item("pencil", s.modified + s.removed, .orange) }
          if s.untracked > 0 { item("plus", s.untracked, .green) }
        }
        if let a = s.branch.ahead, a > 0, s.branch.upstream != nil { Text(verbatim: "↑\(a)").foregroundStyle(.secondary) }
        if let b = s.branch.behind, b > 0, s.branch.upstream != nil { Text(verbatim: "↓\(b)").foregroundStyle(.orange) }
      } else {
        Text("—").foregroundStyle(.secondary)
      }
    }
    .font(.system(size: size, weight: .medium)).monospacedDigit()
    .fixedSize()
  }
  private func item(_ symbol: String, _ n: Int, _ color: Color) -> some View {
    HStack(spacing: 2) {
      Image(systemName: symbol).font(.system(size: size - 2, weight: .bold))
      Text(verbatim: "\(n)")
    }.foregroundStyle(color)
  }
}

/// Spoken and tooltip text for a project's counts.
func projectCountsText(_ s: GitSummary?) -> String {
  guard let s else { return "" }
  if s.total == 0 { return L("Sem alterações") }
  return [
    s.conflicts > 0 ? L("%@ conflitos", "\(s.conflicts)") : nil,
    s.staged > 0 ? L("%@ em stage", "\(s.staged)") : nil,
    s.modified > 0 ? L("%@ modificados", "\(s.modified)") : nil,
    s.untracked > 0 ? L("%@ novos", "\(s.untracked)") : nil,
    s.removed > 0 ? L("%@ removidos", "\(s.removed)") : nil,
  ].compactMap { $0 }.joined(separator: " · ")
}

/// One project in the floating panel or the menu bar: name, branch, counts; a click opens its
/// changes in a window of their own.
struct PanelProjectRow: View {
  let project: ProjectEntry
  let summary: GitSummary?
  var scale: CGFloat = 1
  var onOpen: (() -> Void)? = nil
  var body: some View {
    Button {
      onOpen?()
      ProjectChangesWindows.show(project)
    } label: {
      HStack(spacing: 6 * scale) {
        Image(systemName: "folder.fill").font(.system(size: 10 * scale)).foregroundStyle(Tint.brand).frame(width: 14 * scale)
        Text(shownProjectName(project)).lineLimit(1)
        if let b = summary?.branch.head {
          Text(shownBranch(b)).font(.system(size: 9.5 * scale)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        Spacer(minLength: 4)
        ProjectCountsLabel(summary: summary, size: 10 * scale)
      }
      .font(.system(size: 11 * scale)).frame(height: 22 * scale).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help([shownProjectName(project), summary?.branch.head.map(shownBranch), projectCountsText(summary), L("Clique para abrir as alterações")].compactMap { $0 }.joined(separator: "\n"))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(shownProjectName(project))
    .accessibilityValue(projectCountsText(summary))
    .accessibilityAddTraits(.isButton)
  }
}

/// The changes view of a project in a window of its own (from the floating panel or the menu
/// bar), without the main window. One window per project; closing it stops its watcher and
/// ends the project's integrated terminal (asking first while it runs something).
enum ProjectChangesWindows {
  private static var windows: [String: NSPanel] = [:]
  private static var folders: [String: String] = [:]
  private static let delegate = CloseDelegate()

  static func show(_ project: ProjectEntry) {
    if let window = windows[project.id] {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.title = shownProjectName(project)
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.isReleasedWhenClosed = false
    panel.minSize = NSSize(width: 760, height: 460)
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.identifier = NSUserInterfaceItemIdentifier("project-changes-\(project.id)")
    panel.contentView = NSHostingView(
      rootView: ProjectChangesView(project: project, inWindow: true) { panel.performClose(nil) }
        .padding(.top, 22))
    panel.delegate = delegate
    panel.setFrameAutosaveName("project-changes")
    if panel.frame.origin == .zero { panel.center() }
    windows[project.id] = panel
    folders[project.id] = project.folder
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  fileprivate static func closed(_ window: NSWindow) {
    guard let id = windows.first(where: { $0.value === window })?.key else { return }
    // Dropping the hosting view ends the view's onDisappear, which stops its watcher.
    window.contentView = nil
    windows[id] = nil
    folders[id] = nil
  }

  fileprivate static func shouldClose(_ window: NSWindow) -> Bool {
    guard let id = windows.first(where: { $0.value === window })?.key, let folder = folders[id] else { return true }
    return ProjectShells.shared.close(folder)
  }

  private final class CloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { ProjectChangesWindows.shouldClose(sender) }
    func windowWillClose(_ notification: Notification) {
      if let window = notification.object as? NSWindow { ProjectChangesWindows.closed(window) }
    }
  }
}

/// The floating panel's projects section (standard and detailed layouts).
struct PanelProjectsSection: View {
  @ObservedObject var store = PanelProjectsStore.shared
  let scale: CGFloat
  var body: some View {
    if !store.projects.isEmpty {
      VStack(alignment: .leading, spacing: 5 * scale) {
        Divider().opacity(0.5)
        Button {
          WindowOpener.shared.showMain(page: .projects)
        } label: {
          HStack(spacing: 4 * scale) {
            Text(L("PROJETOS"))
            Text("\(store.projects.count)").foregroundStyle(.tertiary)
          }.font(.system(size: 9 * scale, weight: .bold)).foregroundStyle(.secondary)
        }.buttonStyle(.plain).help(L("Abrir %@", Page.projects.title))
        ForEach(store.projects) { p in PanelProjectRow(project: p, summary: store.summaries[p.id], scale: scale) }
      }
    }
  }
}

/// The menu bar's projects section.
struct MenuProjects: View {
  @ObservedObject var store = PanelProjectsStore.shared
  var body: some View {
    if !store.projects.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(L("PROJETOS")).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
          Badge(text: "\(store.projects.count)")
          Spacer()
        }
        ForEach(store.projects) { p in
          PanelProjectRow(project: p, summary: store.summaries[p.id]) { PortLookup.close() }
        }
      }
    }
  }
}

/// "Projects in the panel" in the floating panel's menu: a switch per registered project.
struct PanelProjectsMenu: View {
  @ObservedObject var projects = ProjectsStore.shared
  var body: some View {
    Menu(L("Projetos no painel")) {
      if projects.projects.isEmpty {
        Button(L("Adicionar projetos…")) { WindowOpener.shared.showMain(page: .projects) }
      }
      ForEach(projects.projects) { p in
        Toggle(shownProjectName(p), isOn: Binding(get: { p.show_in_panel }, set: { PanelProjectsStore.shared.setShown(p, $0) }))
      }
    }
    .onAppear { if projects.projects.isEmpty { projects.load() } }
  }
}
