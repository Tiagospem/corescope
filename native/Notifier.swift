import AppKit
import UserNotifications

/// Opt-in local notifications (UserNotifications; nothing leaves the Mac). Rules run on the
/// snapshots the collector already produces: no timer, no extra sampling. Only the user's own,
/// eligible processes are considered; protected and other users' processes never notify.
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  static let shared = Notifier()
  /// The user turned notifications off for CoreScope in System Settings.
  @Published var denied = false
  private var center: UNUserNotificationCenter?
  private var debounce = NotificationDebounce()
  private var orphans = NewArrivals()
  private var cpu = SustainTracker()
  private var memory = SustainTracker()
  private var lastPressure = 0
  private let ownPID = ProcessInfo.processInfo.processIdentifier
  private static let terminate = "terminate"
  private static let processCategory = "process"

  /// Sets up the delegate and action category once a notification kind is enabled. Asking for
  /// authorization prompts only the first time; afterwards it just reports the current choice.
  func activate() {
    guard Preferences.shared.notificationsEnabled else { return }
    let center = self.center ?? UNUserNotificationCenter.current()
    if self.center == nil {
      center.delegate = self
      self.center = center
    }
    // Re-registered on each activation so the button follows the interface language.
    let kill = UNNotificationAction(
      identifier: Self.terminate, title: L("Encerrar"), options: [.destructive])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: Self.processCategory, actions: [kill], intentIdentifiers: [])
    ])
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      DispatchQueue.main.async { self.denied = !granted }
    }
  }

  func evaluate(_ s: Snapshot) {
    let p = Preferences.shared
    guard p.notifyOrphans || p.notifyHeavy else {
      orphans = NewArrivals()
      cpu = SustainTracker()
      memory = SustainTracker()
      return
    }
    let mine = s.processes.filter { $0.eligible && $0.uid == s.current_uid && $0.pid != ownPID }
    let byID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    if p.notifyOrphans {
      for id in orphans.update(mine.filter { $0.orphan != nil }.map(\.id)) {
        guard let proc = byID[id] else { continue }
        post(
          key: id, title: L("Possível órfão: %@", proc.name), body: describe(proc),
          process: proc, at: s.at)
      }
    } else {
      orphans = NewArrivals()
    }
    if p.notifyHeavy {
      let limit = p.notifyMemoryGB * 1_073_741_824
      let heavy = memory.update(
        above: mine.filter { ($0.memory.value ?? 0) >= limit }.map(\.id), at: s.at,
        duration: p.notifySustain)
      let hot = cpu.update(
        above: mine.filter { ($0.cpu.value ?? 0) >= p.notifyCPU }.map(\.id), at: s.at,
        duration: p.notifySustain)
      for id in heavy {
        guard let proc = byID[id] else { continue }
        post(
          key: id, title: L("%@ usa %@ de memória", proc.name, proc.memory.bytes),
          body: L("Acima de %@ há mais de %@.", formatBytes(limit), formatDuration(p.notifySustain))
            + "\n" + describe(proc), process: nil, at: s.at)
      }
      for id in hot where !heavy.contains(id) {
        guard let proc = byID[id] else { continue }
        post(
          key: id, title: L("%@ usa %@ de CPU", proc.name, proc.cpu.percent),
          body: L("Acima de %@ há mais de %@.", "\(Int(p.notifyCPU))%", formatDuration(p.notifySustain))
            + "\n" + describe(proc), process: nil, at: s.at)
      }
    } else {
      cpu = SustainTracker()
      memory = SustainTracker()
    }
  }

  /// Called with each macOS memory-pressure event (0 normal, 1 warning, 2 critical).
  func pressureChanged(_ level: Int, snapshot: Snapshot?) {
    defer { lastPressure = level }
    guard Preferences.shared.notifyPressure, level > 0, level > lastPressure else { return }
    var body = L(
      level == 2
        ? "O macOS está sem memória livre e pode encerrar apps. Feche o que não estiver usando."
        : "O macOS começou a comprimir memória e pode usar swap.")
    if let s = snapshot,
      let top = s.processes.filter({ $0.uid == s.current_uid }).max(by: {
        $0.memoryValue < $1.memoryValue
      })
    {
      body += "\n" + L("Maior consumo: %@ (%@)", top.name, top.memory.bytes)
    }
    post(
      key: "pressure.\(level)",
      title: L(level == 2 ? "Pressão de memória crítica" : "Pressão de memória em atenção"),
      body: body, process: nil, at: Date().timeIntervalSince1970)
  }

  private var drain = SustainTracker()
  /// On battery, an agent session (with everything it started) above `drainWatts` for 5 minutes.
  func evaluateDrain(_ s: Snapshot) {
    let p = Preferences.shared
    guard p.notifyAgentDrain, let battery = s.battery, !battery.on_ac else {
      drain = SustainTracker()
      return
    }
    var watts: [String: (ProcessItem, Double)] = [:]
    for root in s.agentSessions {
      let total = s.subtree(of: root).compactMap { $0.energy?.value }.reduce(0, +)
      if total >= p.drainWatts { watts[root.id] = (root, total) }
    }
    for id in drain.update(above: Array(watts.keys), at: s.at, duration: 300) {
      guard let (root, total) = watts[id] else { continue }
      post(
        key: "drain.\(id)", title: L("%@ está gastando bateria", root.host ?? root.name),
        body: L("%@ por 5 min na bateria (%@%%)", String(format: "%.1f W", total), "\(battery.percent)")
          + "\n" + describe(root), process: nil, at: s.at)
    }
  }

  /// A watched service went down or came back; clicking opens the Services page.
  func serviceChanged(key: String, title: String, body: String) {
    if center == nil { activate() }
    guard let center, !denied else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = "services"
    center.add(UNNotificationRequest(identifier: "service.\(key).\(Date().timeIntervalSince1970)", content: content, trigger: nil))
  }

  /// A busy agent session stopped making progress; clicking opens it (Claude Desktop or Codex).
  func agentStalled(key: String, title: String, body: String, url: URL?) {
    if center == nil { activate() }
    guard let center, !denied else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = "agents"
    if let url { content.userInfo = ["open": url.absoluteString] }
    center.add(UNNotificationRequest(identifier: "stall.\(key)", content: content, trigger: nil))
  }

  /// The daily update check found a new version; clicking opens Settings › Updates. Shown only
  /// when CoreScope may already notify: turning update checks on never asks for permission.
  func updateAvailable(version: String) {
    let center = self.center ?? UNUserNotificationCenter.current()
    if self.center == nil {
      center.delegate = self
      self.center = center
    }
    let content = UNMutableNotificationContent()
    content.title = L("CoreScope %@ disponível", version)
    content.body = L("Veja as novidades e instale em Ajustes › Atualizações.")
    content.threadIdentifier = "update"
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized else { return }
      center.add(UNNotificationRequest(identifier: "update.\(version)", content: content, trigger: nil))
    }
  }

  private func describe(_ p: ProcessItem) -> String {
    let ports = p.ports.prefix(3).map { ":\($0.port)" }.joined(separator: " ")
    return [
      p.project ?? (p.cwd.isEmpty ? nil : p.shortCwd), ports.isEmpty ? nil : ports,
      p.origin.map { L("via %@", $0.label) }, L("rodando há %@", formatDuration(p.uptime)),
    ].compactMap { $0 }.joined(separator: " · ")
  }

  private func post(key: String, title: String, body: String, process: ProcessItem?, at: Double) {
    guard debounce.allow(key, at: at) else { return }
    if center == nil { activate() }
    guard let center, !denied else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.threadIdentifier = key.hasPrefix("pressure") ? "pressure" : "process"
    if let process {
      // Identity travels with the notification; the core revalidates it before signaling.
      content.categoryIdentifier = Self.processCategory
      content.userInfo = ["id": process.id]
    }
    center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["id"] as? String
    let action = response.actionIdentifier
    DispatchQueue.main.async {
      if action == Self.terminate, let id {
        self.terminate(id)
      } else if action == UNNotificationDefaultActionIdentifier {
        let info = response.notification.request.content.userInfo
        if let link = info["open"] as? String, let url = URL(string: link),
          ["claude", "codex"].contains(url.scheme ?? "")
        {
          NSWorkspace.shared.open(url)
        } else {
          let id = response.notification.request.identifier
          WindowOpener.shared.showMain(
            page: id.hasPrefix("update.") ? .settings : id.hasPrefix("stall.") ? .agents : id.hasPrefix("service.machine.") ? .machines
              : id.hasPrefix("service.") ? .health : id.hasPrefix("drain.") ? .energy : .processes)
        }
      }
      completionHandler()
    }
  }

  /// SIGTERM through the regular signal path; a process that already ended is just reported.
  private func terminate(_ id: String) {
    let monitor = Monitor.shared
    guard let proc = monitor.snapshot?.processes.first(where: { $0.id == id }) else {
      monitor.feedback = ActionFeedback(message: L("O processo já não está em execução."))
      return
    }
    monitor.signal([proc], force: false)
  }
}
