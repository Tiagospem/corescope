import AppKit
import SwiftUI
import UserNotifications

private struct NotifyCheck: Decodable {
  let summary: GitSummary
  let delta: ChangeDelta?
}
struct ChangeDelta: Decodable, Equatable {
  struct Count: Decodable, Equatable {
    let kind: String
    let before: Int
    let after: Int
  }
  let changes: [Count]
  let branch_from: String?
  let branch_to: String?
  let new_head: Bool
  let total: Int
}

/// Change notifications per project (opt-in, off by default; 1, 5 or 15 minutes). A file watcher
/// only marks a project as touched; at its interval a touched project is read once (`git status`)
/// and compared with what was last notified (the core's delta). Nothing is said when nothing that
/// counts moved, so saving a file never notifies by itself, and there is at most one notification
/// per project per interval.
final class ProjectNotifier {
  static let shared = ProjectNotifier()
  private(set) var projects: [ProjectEntry] = []
  /// Last summary notified (or the baseline), as the core's JSON.
  private var last: [String: Any] = [:]
  private var touched = Set<String>()
  private var checked: [String: Date] = [:]
  private var watchers: [String: RepoWatcher] = [:]
  private var timer: Timer?
  private let queue = DispatchQueue(label: "app.corescope.project-notify", qos: .utility)

  /// Some project wants notifications (asks macOS for permission once).
  var active: Bool { !projects.isEmpty }

  /// Re-reads which projects notify; call at launch and after a project's setting changes.
  func sync() {
    guard Tour.folder == nil else { return }
    queue.async {
      let list = ((try? ProjectsTool.call(["op": "list"], as: [ProjectEntry].self).get()) ?? []).filter { $0.notify_minutes != nil }
      var roots: [String: String] = [:]
      var baselines: [String: Any] = [:]
      for p in list {
        guard let c = try? ProjectsTool.call(["op": "check", "folder": p.folder], as: ProjectCheck.self).get(),
          c.git.is_repo, let root = c.git.root
        else { continue }
        roots[p.id] = root
        if let raw = Self.check(p, before: nil) { baselines[p.id] = raw["summary"] }
      }
      DispatchQueue.main.async {
        let ids = Set(list.map(\.id))
        self.projects = list.filter { roots[$0.id] != nil }
        for (id, summary) in baselines where self.last[id] == nil { self.last[id] = summary }
        self.last = self.last.filter { ids.contains($0.key) }
        var next: [String: RepoWatcher] = [:]
        for p in self.projects {
          guard let root = roots[p.id] else { continue }
          next[p.id] = self.watchers[p.id] ?? RepoWatcher(folder: p.folder, root: root) { [weak self] in self?.touched.insert(p.id) }
        }
        self.watchers = next
        if self.active {
          Notifier.shared.activate()
          if self.timer == nil {
            self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
            self.timer?.tolerance = 10
          }
        } else {
          self.timer?.invalidate()
          self.timer = nil
          self.touched = []
        }
      }
    }
  }

  private func tick() {
    let now = Date()
    for p in projects where touched.contains(p.id) {
      let minutes = Double(p.notify_minutes ?? 5)
      if let at = checked[p.id], now.timeIntervalSince(at) < minutes * 60 - 5 { continue }
      touched.remove(p.id)
      checked[p.id] = now
      let before = last[p.id]
      queue.async {
        let cost = CostMeter.begin()
        defer { CostMeter.end("projects-git", cost) }
        guard let raw = Self.check(p, before: before),
          let data = try? JSONSerialization.data(withJSONObject: raw),
          let result = try? JSONDecoder().decode(NotifyCheck.self, from: data)
        else { return }
        DispatchQueue.main.async {
          guard let delta = result.delta else { return }
          self.last[p.id] = raw["summary"]
          self.post(p, delta, result.summary)
        }
      }
    }
  }

  private static func check(_ p: ProjectEntry, before: Any?) -> [String: Any]? {
    var request: [String: Any] = ["op": "notify_check", "folder": p.folder]
    if let before { request["before"] = before }
    guard let data = try? JSONSerialization.data(withJSONObject: request),
      let json = String(data: data, encoding: .utf8),
      let pointer = json.withCString({ cs_projects($0) })
    else { return nil }
    defer { cs_free(pointer) }
    let body = Data(bytes: pointer, count: strlen(pointer))
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], obj["error"] == nil else { return nil }
    return obj
  }

  private func post(_ p: ProjectEntry, _ delta: ChangeDelta, _ summary: GitSummary) {
    let body = changeDeltaText(delta, branch: summary.branch.head)
    guard !body.isEmpty else { return }
    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = shownProjectName(p)
    content.body = body
    content.threadIdentifier = "project.\(p.id)"
    content.userInfo = ["open": "corescope://project/\(p.id)"]
    center.add(UNNotificationRequest(identifier: "project.\(p.id)", content: content, trigger: nil))
  }

  /// Sets a project's interval (nil turns it off) and applies it.
  func set(_ project: ProjectEntry, minutes: Int?) {
    queue.async {
      _ = ProjectsTool.call(["op": "set", "id": project.id, "notify_minutes": minutes.map { $0 as Any } ?? NSNull()], as: ProjectEntry.self)
      DispatchQueue.main.async {
        ProjectsStore.shared.load()
        self.sync()
      }
    }
  }
}

/// "+3 new, 5 modified (was 2) · 1 commit on main · 9 changes now" in the interface language.
func changeDeltaText(_ d: ChangeDelta, branch: String?) -> String {
  let names: [String: String] = [
    "conflicts": L("conflitos"), "staged": L("em stage"), "modified": L("modificados"), "untracked": L("novos"),
    "removed": L("removidos"),
  ]
  var parts: [String] = d.changes.map { c in
    let diff = c.after - c.before
    let sign = diff > 0 ? "+" : "−"
    return "\(sign)\(abs(diff)) \(names[c.kind] ?? c.kind)"
  }
  if let to = d.branch_to {
    parts.append(L("branch: %@ → %@", shownBranch(d.branch_from ?? "?"), shownBranch(to)))
  } else if d.new_head {
    parts.append(branch.map { L("novo commit em %@", shownBranch($0)) } ?? L("novo commit"))
  }
  guard !parts.isEmpty else { return "" }
  let now = d.total == 0 ? L("sem alterações agora") : d.total == 1 ? L("1 alteração agora") : L("%@ alterações agora", "\(d.total)")
  return parts.joined(separator: ", ") + " · " + now
}

/// Off / 1 / 5 / 15 minutes for one project.
struct ProjectNotifyPicker: View {
  let project: ProjectEntry
  var label: String = L("Notificar alterações")
  var body: some View {
    Picker(label, selection: Binding(get: { project.notify_minutes ?? 0 }, set: { ProjectNotifier.shared.set(project, minutes: $0 == 0 ? nil : $0) })) {
      Text(L("Desligado")).tag(0)
      Text(L("A cada 1 min")).tag(1)
      Text(L("A cada 5 min")).tag(5)
      Text(L("A cada 15 min")).tag(15)
    }
  }
}

/// Settings › Notifications: the projects' change notifications.
struct ProjectNotifySettings: View {
  @ObservedObject var store = ProjectsStore.shared
  var body: some View {
    let repos = store.projects.filter { store.checks[$0.id]?.git.is_repo == true }
    if repos.isEmpty {
      LabeledContent(L("Alterações nos projetos")) {
        Button(L("Adicionar projetos…")) { WindowOpener.shared.showMain(page: .projects) }
      }
    } else {
      ForEach(repos) { p in
        ProjectNotifyPicker(project: p, label: L("Alterações em %@", shownProjectName(p)))
      }
    }
    Text(L("Desligadas por padrão. Uma notificação local por projeto no máximo a cada intervalo, só quando algo mudou desde a última (novos, modificados, em stage, commits, troca de branch) — salvar um arquivo já modificado não conta. Clicar abre as alterações."))
      .font(.caption).foregroundStyle(.secondary)
      .onAppear { if store.projects.isEmpty { store.load() } }
  }
}
