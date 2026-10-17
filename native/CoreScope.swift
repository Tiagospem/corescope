import AppKit
import SwiftUI

enum AppIcon {
  /// The bundle icon, set explicitly so the Dock never shows a stale generic tile.
  static let image: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
    .flatMap { NSImage(contentsOf: $0) }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var observers: [NSObjectProtocol] = []
  func applicationDidFinishLaunching(_ notification: Notification) {
    if let icon = AppIcon.image { NSApp.applicationIconImage = icon }
    Preferences.shared.applyAppearance()
    NSApp.activate(ignoringOtherApps: true)
    FloatingController.shared.apply()
    // Dock presence follows the main window when the user chose "only while open".
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { note in
          guard (note.object as? NSWindow)?.identifier?.rawValue.contains("main") == true else {
            return
          }
          // willClose fires while the window is still visible: re-evaluate on the next turn.
          DispatchQueue.main.async { Preferences.shared.applyActivationPolicy() }
        })
    }
    DispatchQueue.main.async { Preferences.shared.applyActivationPolicy() }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { WindowOpener.shared.showMain() }
    return true
  }
}
@main
struct CoreScopeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  // Not observed on purpose: observing here re-evaluates every scene on each snapshot.
  private let monitor = Monitor.shared
  private let prefs = Preferences.shared
  var body: some Scene {
    Window("CoreScope", id: "main") { MainView() }.defaultSize(width: 1180, height: 780)
      .commands {
        CommandGroup(replacing: .appInfo) {
          Button(L("Sobre o CoreScope")) {
            NSApp.orderFrontStandardAboutPanel(options: [
              .applicationName: "CoreScope", .applicationVersion: "0.2.0",
              .credits: NSAttributedString(
                string:
                  "Monitor local para desenvolvedores · Rust + SwiftUI\n© 2026 Tiago Padilha · MIT License\ngithub.com/Tiagospem/corescope"),
            ])
          }
        }
        CommandGroup(after: .windowArrangement) {
          Button(L("Mostrar ou ocultar painel flutuante")) {
            prefs.panelVisible.toggle()
          }.keyboardShortcut("p", modifiers: [.command, .shift])
          Button(L("Pausar ou retomar coleta")) {
            monitor.setPaused(!monitor.manuallyPaused)
          }.keyboardShortcut(" ", modifiers: [.command, .shift])
        }
        CommandMenu("Navegar") {
          ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
            Button(page.title) { navigate(page) }
              .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
          }
        }
      }
    MenuBarExtra {
      MenuSummary()
    } label: {
      MenuBarLabel()
    }.menuBarExtraStyle(.window)
    Settings { PreferencesView().frame(width: 650, height: 730) }
  }
}

struct MenuBarLabel: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @ObservedObject var agents = AgentStore.shared
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    HStack(spacing: 4) {
      if prefs.menuIcon || title.isEmpty {
        Image(systemName: monitor.stale ? "pause.circle" : "waveform.path.ecg")
      }
      if !title.isEmpty { Text(title).monospacedDigit() }
    }
    .id(prefs.language)
    .onAppear { WindowOpener.shared.open = { openWindow(id: "main") } }
  }
  private var title: String {
    guard let s = monitor.snapshot, !monitor.stale else { return "" }
    var limit: [String] = []
    if prefs.limitsInMenuBar, let w = agents.codex.weekly {
      limit = ["Cx \(Int(w.usedPercent))%"]
    }
    return (prefs.menuItems.map { item -> String in
      switch item {
      case "CPU":
        return prefs.compact
          ? "\(s.cpu.value.map { String(Int($0)) + "%" } ?? "—")" : "CPU \(s.cpu.percent)"
      case "Memória": return prefs.compact ? s.memorySummary : "RAM \(s.memorySummary)"
      case "Disco": return prefs.compact ? s.diskRate : L("Disco %@", s.diskRate)
      case "Rede":
        return formatRate((s.net_in.value ?? 0) + (s.net_out.value ?? 0))
      case "Sensor":
        return
          "SSD \(s.disks.first{$0.id==prefs.selectedSensor}?.temperature.value.map{String(format:"%.0f°C",$0)} ?? "—")"
      default: return s.thermalLabel
      }
    } + limit).joined(separator: prefs.compact ? "  " : "  ·  ")
  }
}

private struct MiniTile: View {
  let title: String
  let value: String
  let detail: String
  let series: [ChartSeries]
  var ceiling: Double? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
        Spacer()
        Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
      }
      Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
      AreaChart(series: series, ceiling: ceiling, capacity: 80, grid: false, lineWidth: 1.3)
        .frame(height: 30)
    }
    .padding(9)
    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
  }
}

/// Inline two-step action for a group (e.g. every orphan) inside popovers.
struct KillAllButton: View {
  let items: [ProcessItem]
  var label = L("Encerrar todos")
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var armed = false
  var body: some View {
    if armed {
      HStack(spacing: 4) {
        Button(L("Encerrar %@", "\(items.count)")) {
          armed = false
          monitor.signal(items, force: false)
        }.buttonStyle(.borderedProminent).tint(.red)
        Button(L("Cancelar")) { armed = false }.buttonStyle(.bordered)
      }
    } else {
      Button(label, role: .destructive) { armed = true }.buttonStyle(.bordered)
        .disabled(items.allSatisfy { !$0.eligible })
    }
  }
}

struct MenuSummary: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @ObservedObject var agents = AgentStore.shared
  @ObservedObject var containers = ContainerStore.shared
  @Environment(\.openWindow) var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 7) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
        Text(L("CoreScope")).font(.system(size: 13, weight: .semibold))
        LiveDot(stale: monitor.stale)
        Text(monitor.manuallyPaused ? L("Pausado") : monitor.stale ? L("Dados antigos") : L("Ao vivo"))
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button {
          monitor.setPaused(!monitor.manuallyPaused)
        } label: {
          Image(systemName: monitor.manuallyPaused ? "play.fill" : "pause.fill")
        }.buttonStyle(HoverButtonStyle()).help(monitor.manuallyPaused ? L("Retomar") : L("Pausar"))
        Button {
          prefs.panelVisible.toggle()
        } label: {
          Image(systemName: prefs.panelVisible ? "pip.fill" : "pip")
        }.buttonStyle(HoverButtonStyle(tint: .accentColor))
          .help(prefs.panelVisible ? L("Ocultar painel flutuante") : L("Mostrar painel flutuante"))
        Button {
          open(.settings)
        } label: {
          Image(systemName: "gearshape")
        }.buttonStyle(HoverButtonStyle()).help(L("Ajustes"))
      }
      if let s = monitor.snapshot {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
          GridRow {
            MiniTile(
              title: L("CPU"), value: s.cpu.percent, detail: L("%@ núcleos", "\(s.cores)"),
              series: [ChartSeries(values: s.history.map(\.cpu), color: Tint.cpu)], ceiling: 100)
            MiniTile(
              title: L("MEMÓRIA"), value: s.memorySummary,
              detail: s.memoryFraction.map { String(format: L("%.0f%% de %@"), $0 * 100, s.physical.bytes) } ?? "",
              series: [ChartSeries(values: s.history.map(\.memory), color: Tint.memory)],
              ceiling: s.physical.value)
          }
          GridRow {
            MiniTile(
              title: L("DISCO"), value: s.diskRate, detail: "↓\(s.disk_read.rate)",
              series: [
                ChartSeries(values: s.history.map(\.disk_read), color: Tint.diskRead),
                ChartSeries(values: s.history.map(\.disk_write), color: Tint.diskWrite),
              ])
            MiniTile(
              title: L("REDE"), value: formatRate((s.net_in.value ?? 0) + (s.net_out.value ?? 0)),
              detail: "↓\(s.net_in.rate)",
              series: [
                ChartSeries(values: s.history.map(\.net_in), color: Tint.netIn),
                ChartSeries(values: s.history.map(\.net_out), color: Tint.netOut),
              ])
          }
        }
        HStack(spacing: 10) {
          Label(s.thermalLabel, systemImage: "thermometer.medium").foregroundStyle(s.thermalColor)
          Label(L("Swap %@", "\(s.swap.bytes)"), systemImage: "arrow.left.arrow.right")
          Spacer()
          if let alert = s.diagnostics.first(where: { $0.level > 0 }) {
            Label(alert.localizedTitle, systemImage: alert.symbol).foregroundStyle(alert.color).lineLimit(1)
          }
        }.font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)

        if prefs.limitsInMenuBar && !agents.codex.windows.isEmpty {
          VStack(spacing: 6) {
            ForEach(agents.codex.windows) { w in LimitBar(title: "Codex", window: w, compact: true) }
          }
        }
        if !s.orphans.isEmpty {
          section(L("Possíveis órfãos"), count: s.orphans.count, tint: .orange) {
            KillAllButton(items: s.orphans)
          } content: {
            ForEach(s.orphans.prefix(3)) { p in
              ProcessLine(process: p, subtitle: devSubtitle(p)) { KillButton(process: p) }
                .help(L(p.orphan ?? ""))
            }
          }
        }
        if !s.agentSessions.isEmpty {
          section(L("Sessões de agentes"), count: s.agentSessions.count, tint: .orange) {
            EmptyView()
          } content: {
            ForEach(s.agentSessions.prefix(4)) { p in
              let tree = s.subtree(of: p)
              ProcessLine(
                process: p,
                subtitle: [p.project, p.sessionSource, L("%@ proc.", "\(tree.count)"), formatBytes(tree.compactMap(\.memory.value).reduce(0, +))]
                  .compactMap { $0 }.joined(separator: " · ")
              ) {
                KillButton(process: p, targets: tree)
              }
            }
          }
        }
        let servers = serverEntries(s.serverGroups, owners: containers.owners)
        if !servers.isEmpty {
          section(L("Servidores em escuta"), count: servers.count, tint: Tint.netIn) {
            EmptyView()
          } content: {
            ForEach(servers.prefix(4)) { entry in
              switch entry {
              case .container(let c, let via, let ports):
                ContainerServerLine(container: c, via: via, ports: ports, maxPorts: 1)
              case .process(let p, _, let ports):
                ProcessLine(process: p, subtitle: devSubtitle(p)) {
                  if let port = ports.first {
                    Badge(text: ":\(port.port)", color: port.exposed ? .orange : Tint.netIn)
                    OpenPortButton(port: port.port)
                  }
                  KillButton(process: p)
                }
              }
            }
          }
        }
        section(L("Maior CPU"), count: nil, tint: Tint.cpu) {
          EmptyView()
        } content: {
          ForEach(s.processes.prefix(4)) { p in
            ProcessLine(process: p, subtitle: p.project ?? p.origin.map { L("via %@", "\($0.label)") }) {
              Text(p.cpu.percent).monospacedDigit().foregroundStyle(.secondary)
              KillButton(process: p)
            }
          }
        }
      } else {
        ProgressView(L("Coletando…")).frame(maxWidth: .infinity, minHeight: 120)
      }
      FeedbackToast()
      Divider()
      HStack {
        Button(L("Abrir CoreScope")) { open(nil) }.keyboardShortcut("o")
        Button(L("Processos")) { open(.processes) }
        Spacer()
        Button(L("Sair")) { NSApp.terminate(nil) }.keyboardShortcut("q")
      }.controlSize(.regular)
    }.padding(14).frame(width: 372).id(prefs.language).watchesContainers(stats: false)
  }
  private func open(_ page: Page?) {
    // The popover is the key window at click time; dismiss it before showing the main window.
    NSApp.keyWindow?.orderOut(nil)
    WindowOpener.shared.open = { openWindow(id: "main") }
    WindowOpener.shared.showMain(page: page)
  }
  private func section<Trailing: View, Content: View>(
    _ title: String, count: Int?, tint: Color, @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
        if let count { Badge(text: "\(count)", color: tint) }
        Spacer()
        trailing()
      }
      content()
    }
  }
}
