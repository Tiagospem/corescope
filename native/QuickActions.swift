import AppKit
import SwiftUI

/// One thing the ⌥⌘K palette can do.
struct QuickAction: Identifiable {
  let id: String
  let title: String
  var subtitle: String? = nil
  let symbol: String
  /// Navigation and long work close the popover; toggles leave it open.
  var closes = true
  let run: () -> Void
}

enum QuickActions {
  /// Every action, in a stable order; the palette filters and ranks them.
  static func all(query: String) -> [QuickAction] {
    var out: [QuickAction] = []
    if looksLikeTime(query) {
      out.append(
        QuickAction(id: "happened", title: L("O que aconteceu às %@", query), subtitle: L("Histórico"), symbol: "clock.arrow.circlepath") {
          AppLinks.happened(query)
        })
    }
    let profiles = ProfileStore.shared
    for p in profiles.allProfiles {
      let on = profiles.active.contains(p.id)
      out.append(
        QuickAction(
          id: "profile-\(p.id)", title: on ? L("Parar perfil %@", p.name) : L("Iniciar perfil %@", p.name),
          subtitle: abbreviateHome(p.folder), symbol: on ? "stop.circle" : "play.circle", closes: false
        ) { on ? profiles.stop(p) : profiles.start(p) })
    }
    let health = HealthStore.shared
    if !health.allChecks.isEmpty {
      out.append(QuickAction(id: "services", title: L("Verificar serviços"), symbol: "checkmark.seal", closes: false) { health.runAll() })
      for c in health.allChecks {
        out.append(
          QuickAction(id: "service-\(c.id)", title: L("Verificar %@", c.name), subtitle: c.target, symbol: "waveform.path", closes: false) {
            health.run(c)
          })
      }
    }
    var folders: [(String, String)] = profiles.allProfiles.map { ($0.name, $0.folder) }
    folders += ProjectFileStore.shared.files.map { ($0.project, $0.folder) }
    var seen = Set<String>()
    for (name, folder) in folders where seen.insert(folder).inserted {
      out.append(
        QuickAction(id: "folder-\(folder)", title: L("Abrir projeto %@", (folder as NSString).lastPathComponent), subtitle: name, symbol: "folder") {
          NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        })
    }
    for page in Page.allCases {
      out.append(QuickAction(id: "page-\(page.slug)", title: L("Abrir %@", page.title), symbol: page.icon) { AppLinks.show(page) })
    }
    let monitor = Monitor.shared
    out.append(
      QuickAction(
        id: "pause", title: monitor.manuallyPaused ? L("Retomar coleta") : L("Pausar coleta"), symbol: "pause.circle", closes: false
      ) { monitor.setPaused(!monitor.manuallyPaused) })
    let prefs = Preferences.shared
    out.append(
      QuickAction(
        id: "panel", title: prefs.panelVisible ? L("Ocultar painel flutuante") : L("Mostrar painel flutuante"), symbol: "pip",
        closes: false
      ) { prefs.panelVisible.toggle() })
    return out
  }
  /// The best matches for the text typed in the palette.
  static func matches(_ query: String, limit: Int = 6) -> [QuickAction] {
    let all = all(query: query)
    if looksLikeTime(query), let first = all.first { return [first] }
    return
      all.enumerated().compactMap { i, a in quickScore(query, a.title).map { ($0, i, a) } }
      .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
  }
}

/// `corescope://` links: Shortcuts ("Open URL"), Raycast quicklinks, scripts (`open corescope://…`).
enum AppLinks {
  static func handle(_ url: URL) {
    guard let link = AppLink(url) else {
      NSSound.beep()
      return
    }
    switch link {
    case .open(let slug):
      show(slug.flatMap { s in Page.allCases.first { $0.slug == s } })
    case .profile(let action, let name):
      profile(action, name: name)
    case .lookup(let port):
      PortLookup.pendingText = port.map { "\($0)" }
      PortLookup.open()
    case .checkServices:
      HealthStore.shared.runAll()
    case .happened(let at):
      happened(at)
    case .palette:
      PortLookup.open()
    case .project(let key):
      show(.projects)
      ProjectsStore.shared.open(key)
    }
  }
  static func show(_ page: Page?) {
    PortLookup.close()
    WindowOpener.shared.showMain(page: page)
  }
  static func happened(_ text: String) {
    show(.history)
    HistoryStore.shared.explain(text: text)
  }
  /// Profiles from a `.corescope.yml` came with a repository: a link starting one asks first,
  /// so a web page cannot run a cloned project's commands. Stopping never asks.
  private static func profile(_ action: String, name: String) {
    let store = ProfileStore.shared
    guard
      let p = store.allProfiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        ?? store.allProfiles.first(where: { $0.name.lowercased().hasSuffix("/" + name.lowercased()) })
    else {
      Monitor.shared.feedback = ActionFeedback(message: L("Nenhum perfil chamado %@.", name), failed: true)
      return
    }
    let on = store.active.contains(p.id)
    let start = action == "start" || (action == "toggle" && !on)
    guard start else {
      if on { store.stop(p) }
      return
    }
    guard !on else { return }
    if p.source != nil {
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = L("Iniciar o perfil %@?", p.name)
      alert.informativeText =
        L("Pedido por um link corescope://. Os comandos vêm de %@:", p.source ?? "")
        + "\n\n" + p.commands.map { "• \($0.command)" }.joined(separator: "\n")
      alert.addButton(withTitle: L("Iniciar"))
      alert.addButton(withTitle: L("Cancelar"))
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    store.start(p)
  }
}

/// Profiles to start or stop and the Services at a glance, in the menu bar popover.
struct MenuProfilesAndServices: View {
  @ObservedObject var profiles = ProfileStore.shared
  @ObservedObject var health = HealthStore.shared
  var body: some View {
    let list = Array(profiles.allProfiles.prefix(5))
    if !list.isEmpty {
      VStack(alignment: .leading, spacing: 5) {
        Text(L("Perfis").uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(Tint.brand)
        ForEach(list) { p in
          let on = profiles.active.contains(p.id)
          HStack(spacing: 7) {
            Circle().fill(on ? Tint.brand : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
            Text(p.name).font(.callout).lineLimit(1)
            Spacer()
            if profiles.busy.contains(p.id) {
              ProgressView().controlSize(.mini)
            } else {
              Button {
                on ? profiles.stop(p) : profiles.start(p)
              } label: {
                Image(systemName: on ? "stop.fill" : "play.fill")
              }.buttonStyle(HoverButtonStyle(tint: on ? .red : Tint.brand))
                .help(on ? L("Parar perfil %@", p.name) : L("Iniciar perfil %@", p.name))
                .accessibilityLabel(on ? L("Parar perfil %@", p.name) : L("Iniciar perfil %@", p.name))
            }
          }
        }
      }
    }
    if !health.allChecks.isEmpty {
      HStack(spacing: 6) {
        Text(L("Serviços").uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        ForEach(health.allChecks.prefix(14)) { c in
          let r = health.results[c.id]
          Circle().fill(r?.level.color ?? Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
            .help("\(c.name): \(r?.detail ?? L("ainda não verificado"))")
            .accessibilityLabel("\(c.name): \(r?.detail ?? L("ainda não verificado"))")
        }
        Spacer()
        Button {
          AppLinks.show(.health)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }.buttonStyle(HoverButtonStyle()).help(L("Abrir Serviços"))
      }
    }
  }
}
