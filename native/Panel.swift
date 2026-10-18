import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  private var pressed: NSEvent?
  /// SwiftUI's hosting view never reports its background as draggable, so
  /// isMovableByWindowBackground does nothing here: start the window drag once the pointer
  /// moves a few points after a press. Plain clicks still reach buttons and menus.
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      pressed = event
    case .leftMouseDragged:
      if let down = pressed, isMovable,
        hypot(event.locationInWindow.x - down.locationInWindow.x,
          event.locationInWindow.y - down.locationInWindow.y) > 3
      {
        pressed = nil
        performDrag(with: down)
        return
      }
    case .leftMouseUp:
      pressed = nil
    default: break
    }
    super.sendEvent(event)
  }
}
final class FloatingController: NSObject, NSWindowDelegate {
  static let shared = FloatingController()
  private var panel: FloatingPanel?
  private var restoring = false
  private var currentScreen: String?
  private var observer: NSObjectProtocol?
  override init() {
    super.init()
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.restoreVisiblePosition() }
  }
  func apply() {
    let p = Preferences.shared
    guard p.panelVisible else {
      panel?.orderOut(nil)
      return
    }
    if panel == nil {
      let window = FloatingPanel(
        contentRect: NSRect(x: 80, y: 80, width: 280, height: 200),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      window.title = "CoreScope · Painel"
      window.isFloatingPanel = true
      window.hidesOnDeactivate = false
      window.isReleasedWhenClosed = false
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      window.becomesKeyOnlyIfNeeded = true
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.delegate = self
      let hosting = NSHostingView(rootView: FloatingView())
      hosting.sizingOptions = []
      window.contentView = hosting
      panel = window
      restoreVisiblePosition()
    }
    guard let panel else { return }
    panel.level = p.panelTop ? .floating : .normal
    panel.isMovable = !p.panelLocked
    panel.isMovableByWindowBackground = !p.panelLocked
    clampToScreen()
    panel.orderFrontRegardless()
  }
  /// Resizes to the SwiftUI content while keeping the top-left corner fixed.
  func fit(_ size: CGSize) {
    guard let panel, size.width > 10, size.height > 10 else { return }
    let frame = panel.frame
    guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
    restoring = true
    defer { restoring = false }
    panel.setFrame(
      NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
      display: true)
    clampToScreen()
    panel.invalidateShadow()
  }
  func windowDidMove(_ notification: Notification) {
    guard !restoring, let panel, let screen = panel.screen else { return }
    let id = screenID(screen)
    currentScreen = id
    UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "panel.frame.\(id)")
    UserDefaults.standard.set(id, forKey: "panel.lastScreen")
  }
  private func screenID(_ screen: NSScreen) -> String {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
    else { return "main" }
    return CFUUIDCreateString(nil, uuid) as String
  }
  private func restoreVisiblePosition() {
    guard let panel else { return }
    restoring = true
    defer { restoring = false }
    let saved = UserDefaults.standard.string(forKey: "panel.lastScreen")
    let screen =
      NSScreen.screens.first { screenID($0) == saved } ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else { return }
    let id = screenID(screen)
    currentScreen = id
    if let frame = UserDefaults.standard.string(forKey: "panel.frame.\(id)") {
      let saved = NSRectFromString(frame)
      // Keep the saved top-left corner; the size always comes from the current content.
      panel.setFrameTopLeftPoint(NSPoint(x: saved.minX, y: saved.maxY))
    } else {
      panel.setFrameOrigin(
        NSPoint(
          x: screen.visibleFrame.maxX - panel.frame.width - 24,
          y: screen.visibleFrame.maxY - panel.frame.height - 24))
    }
    clampToScreen()
  }
  private func clampToScreen() {
    guard let panel else { return }
    let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else { return }
    panel.setFrame(clampPanel(panel.frame, to: screen.visibleFrame), display: false)
  }
  func recover() {
    guard let panel, let screen = NSScreen.main else {
      apply()
      return
    }
    panel.setFrameOrigin(
      NSPoint(
        x: screen.visibleFrame.maxX - panel.frame.width - 24,
        y: screen.visibleFrame.maxY - panel.frame.height - 24))
    clampToScreen()
    panel.orderFrontRegardless()
  }
}

/// Behind-window blur that stays vibrant even though the panel never becomes key.
struct VisualEffect: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .hudWindow
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = .behindWindow
    view.state = .active
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
private struct PanelSizeKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct FloatingView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @ObservedObject var agents = AgentStore.shared
  @ObservedObject var machines = MachineStore.shared
  @ObservedObject var panelProjects = PanelProjectsStore.shared
  @Environment(\.accessibilityReduceTransparency) var reduceTransparency
  private var k: CGFloat { CGFloat(prefs.panelScale) }
  /// The panel is sized to its content, so flexible children need explicit widths.
  private var cardWidth: CGFloat { (prefs.panelMode == "detailed" ? 320 : 280) * k }
  private var chartWidth: CGFloat { cardWidth - 24 * k - 104 * k - 10 * k }
  var body: some View {
    Group {
      if prefs.panelMode == "compact" {
        compact
      } else {
        expanded
      }
    }
    .background {
      ZStack {
        if reduceTransparency {
          Color(nsColor: .windowBackgroundColor)
        } else {
          VisualEffect().opacity(prefs.panelOpacity)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 14 * k, style: .continuous))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 14 * k, style: .continuous).strokeBorder(
        Color.white.opacity(0.12))
    )
    .contextMenu { PanelMenu() }
    .id(prefs.language)
    .fixedSize()
    .background(GeometryReader { g in Color.clear.preference(key: PanelSizeKey.self, value: g.size) })
    .onPreferenceChange(PanelSizeKey.self) { size in
      DispatchQueue.main.async { FloatingController.shared.fit(size) }
    }
    // The panel's machines are read once a minute while it shows them; the Machines page shares
    // the cadence (refreshStale), so both open never probe a host more often.
    // Projects marked "Show in panel": read and watched only while the panel is visible.
    .onAppear { PanelProjectsStore.shared.use("panel", prefs.panelVisible) }
    .onChange(of: prefs.panelVisible) { _, visible in PanelProjectsStore.shared.use("panel", visible) }
    .task(id: polledMachines) {
      let hosts = polledMachines
      guard !hosts.isEmpty else { return }
      while !Task.isCancelled {
        MachineStore.shared.refreshStale(hosts)
        try? await Task.sleep(nanoseconds: 60_000_000_000)
      }
    }
  }
  private var polledMachines: [String] {
    prefs.panelVisible && prefs.panelMachines ? machines.panelHosts : []
  }

  // MARK: Compact strip
  private var compact: some View {
    HStack(spacing: 12 * k) {
      LiveDot(stale: monitor.stale)
      if let s = monitor.snapshot {
        stripMetric(L("CPU"), s.cpu.value.map { String(format: "%.0f%%", $0) } ?? "—", Tint.cpu, (s.cpu.value ?? 0) / 100)
        stripMetric(L("RAM"), s.memorySummary, Tint.memory, s.memoryFraction)
        stripMetric(L("DISCO"), s.diskRate, Tint.diskRead, nil)
        if prefs.panelNetwork {
          stripMetric(L("REDE"), formatRate((s.net_in.value ?? 0) + (s.net_out.value ?? 0)), Tint.netIn, nil)
        }
        if let sensor = s.disks.first(where: { $0.id == prefs.selectedSensor }),
          let t = sensor.temperature.value
        {
          stripMetric(L("SSD"), String(format: "%.0f°", t), .secondary, nil)
        }
        if prefs.limitsInPanel, let w = agents.codex.weekly {
          stripMetric("CODEX", String(format: "%.0f%%", w.usedPercent), w.color, w.usedPercent / 100)
        }
        if prefs.limitsInPanel, let w = agents.claude.weekly {
          stripMetric("CLAUDE", String(format: "%.0f%%", w.usedPercent), w.color, w.usedPercent / 100)
        }
        if prefs.panelAgents {
          let rows = panelAgents(s)
          let stuck = rows.filter { $0.state == .stuck }.count
          stripMetric(
            L("AGENTES"), "\(rows.count)",
            stuck > 0 ? .orange : rows.contains { $0.state == .busy } ? Tint.brand : .secondary, nil
          ).help(agentsSummary(rows))
        }
        if prefs.panelMachines {
          ForEach(machines.panelHosts.prefix(3), id: \.self) { host in
            let state = machines.states[host]
            stripMetric(
              String(host.uppercased().prefix(12)),
              state?.stats?.loadFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
              machineTint(state), state?.stats?.loadFraction.map { min(1, $0) }
            ).help(machineHelp(host, state))
          }
        }
        ForEach(panelProjects.projects.prefix(3)) { p in
          let sum = panelProjects.summaries[p.id]
          Button {
            ProjectChangesWindows.show(p)
          } label: {
            VStack(alignment: .leading, spacing: 2 * k) {
              Text(String(shownProjectName(p).uppercased().prefix(12))).font(.system(size: 8.5 * k, weight: .bold))
                .foregroundStyle(Tint.brand.opacity(0.9)).lineLimit(1).fixedSize()
              ProjectCountsLabel(summary: sum, size: 11 * k)
            }
          }
          .buttonStyle(.plain)
          .help([shownProjectName(p), sum?.branch.head.map(shownBranch), projectCountsText(sum)].compactMap { $0 }.joined(separator: "\n"))
        }
        if !s.orphans.isEmpty {
          Badge(text: "\(s.orphans.count)", color: .orange, symbol: "exclamationmark.triangle.fill")
            .help(L("%@ possíveis órfãos", "\(s.orphans.count)"))
            .accessibilityLabel(L("%@ possíveis órfãos", "\(s.orphans.count)"))
        }
      } else {
        ProgressView().controlSize(.small)
      }
      menuButton
    }
    .padding(.horizontal, 12 * k).padding(.vertical, 8 * k)
  }
  private func stripMetric(_ label: String, _ value: String, _ color: Color, _ fraction: Double?)
    -> some View
  {
    VStack(alignment: .leading, spacing: 2 * k) {
      Text(label).font(.system(size: 8.5 * k, weight: .bold)).foregroundStyle(color.opacity(0.9))
        .lineLimit(1).fixedSize()
      Text(value).font(.system(size: 13 * k, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1)
      if let fraction { MeterBar(fraction: fraction, color: color).frame(width: 44 * k) }
    }.accessibilityElement(children: .combine)
  }

  // MARK: Standard / detailed card
  private var expanded: some View {
    VStack(alignment: .leading, spacing: 10 * k) {
      HStack(spacing: 6 * k) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16 * k, height: 16 * k)
        Text(L("CoreScope")).font(.system(size: 12 * k, weight: .semibold)).fixedSize()
        LiveDot(stale: monitor.stale)
        Text(monitor.manuallyPaused ? L("Pausado") : monitor.stale ? L("Antigo") : L("Ao vivo"))
          .font(.system(size: 10 * k)).foregroundStyle(.secondary).fixedSize()
        Spacer(minLength: 4)
        Button {
          prefs.panelTop.toggle()
        } label: {
          Image(systemName: prefs.panelTop ? "pin.fill" : "pin").font(.system(size: 10 * k))
        }.buttonStyle(HoverButtonStyle(tint: .accentColor, size: 20 * k))
          .help(prefs.panelTop ? L("Fixado acima das janelas") : L("Fixar acima das janelas"))
          .accessibilityLabel(L("Manter acima das janelas"))
          .accessibilityValue(prefs.panelTop ? L("Ativado") : L("Desativado"))
        Button {
          prefs.panelLocked.toggle()
        } label: {
          Image(systemName: prefs.panelLocked ? "lock.fill" : "lock.open").font(.system(size: 10 * k))
        }.buttonStyle(HoverButtonStyle(tint: .accentColor, size: 20 * k))
          .help(prefs.panelLocked ? L("Posição travada") : L("Travar posição"))
          .accessibilityLabel(L("Travar posição"))
          .accessibilityValue(prefs.panelLocked ? L("Ativado") : L("Desativado"))
        menuButton
        Button {
          prefs.panelVisible = false
        } label: {
          Image(systemName: "xmark").font(.system(size: 9 * k, weight: .bold))
        }.buttonStyle(HoverButtonStyle(size: 20 * k)).help(L("Ocultar painel"))
          .accessibilityLabel(L("Ocultar painel"))
      }
      if let s = monitor.snapshot {
        metricRow(
          L("CPU"), s.cpu.value.map { String(format: "%.1f%%", $0) } ?? "—",
          [.cpu(s.history.map(\.cpu))], ceiling: 100)
        metricRow(
          L("Memória"), s.memorySummary,
          [.memory(s.history.map(\.memory))],
          ceiling: s.physical.value,
          detail: s.memoryFraction.map { String(format: L("%.0f%%"), $0 * 100) })
        metricRow(
          L("Disco"), s.diskRate,
          [
            .diskRead(s.history.map(\.disk_read)),
            .diskWrite(s.history.map(\.disk_write)),
          ])
        if prefs.panelNetwork {
          metricRow(
            L("Rede"), formatRate((s.net_in.value ?? 0) + (s.net_out.value ?? 0)),
            [
              .netIn(s.history.map(\.net_in)),
              .netOut(s.history.map(\.net_out)),
            ])
        }
        if prefs.limitsInPanel && !prefs.panelAgents {
          ForEach(agents.limits) { row in LimitBar(title: row.title, window: row.window, compact: true) }
        }
        statusLine(s)
        if prefs.panelAgents { agentsSection(s) }
        if prefs.panelMachines { machinesSection }
        PanelProjectsSection(scale: k)
        if prefs.panelMode == "detailed" { detail(s) }
      } else {
        ProgressView(L("Coletando…")).controlSize(.small)
      }
    }
    .padding(12 * k)
    .frame(width: cardWidth)
  }
  private func metricRow(
    _ title: String, _ value: String, _ series: [ChartSeries], ceiling: Double? = nil,
    detail: String? = nil
  ) -> some View {
    HStack(spacing: 10 * k) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 10 * k, weight: .medium)).foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(value).font(.system(size: 15 * k, weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1)
          if let detail {
            Text(detail).font(.system(size: 9.5 * k)).foregroundStyle(.secondary).monospacedDigit()
          }
        }
      }.frame(width: 104 * k, alignment: .leading)
      AreaChart(series: series, ceiling: ceiling, capacity: 60, grid: false, lineWidth: 1.3, title: title)
        .frame(width: chartWidth, height: 26 * k)
    }
    .accessibilityElement(children: .combine)
  }
  private func statusLine(_ s: Snapshot) -> some View {
    HStack(spacing: 8 * k) {
      if prefs.thermalInPanel {
        HStack(spacing: 3) {
          Circle().fill(s.thermalColor).frame(width: 6, height: 6)
          Text(s.thermalLabel)
        }.help(L("Estado térmico do macOS"))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(L("Estado térmico do macOS"))
          .accessibilityValue(s.thermalLabel)
      }
      if let sensor = s.disks.first(where: { $0.id == prefs.selectedSensor }) {
        Text(L("SSD %@", "\(sensor.temperature.value.map { String(format: "%.0f °C", $0) } ?? "—")"))
          .help(sensor.name)
      }
      Spacer(minLength: 0)
      if !s.servers.isEmpty {
        Label("\(s.servers.count)", systemImage: "network").help(L("%@ servidores em escuta", "\(s.servers.count)"))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(L("%@ servidores em escuta", "\(s.servers.count)"))
      }
      if !s.orphans.isEmpty {
        Label("\(s.orphans.count)", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).help(L("%@ possíveis órfãos", "\(s.orphans.count)"))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(L("%@ possíveis órfãos", "\(s.orphans.count)"))
      }
    }
    .font(.system(size: 10 * k)).foregroundStyle(.secondary).labelStyle(CompactLabel())
  }
  private func detail(_ s: Snapshot) -> some View {
    VStack(alignment: .leading, spacing: 5 * k) {
      Divider().opacity(0.5)
      Text(L("MAIS CPU")).font(.system(size: 9 * k, weight: .bold)).foregroundStyle(.secondary)
      ForEach(s.processes.prefix(4)) { p in
        panelLine(p, value: p.cpu.percent)
      }
      if !s.orphans.isEmpty || !s.servers.isEmpty {
        Text(s.orphans.isEmpty ? L("SERVIDORES") : L("ÓRFÃOS")).font(.system(size: 9 * k, weight: .bold))
          .foregroundStyle(s.orphans.isEmpty ? Color.secondary : Color.orange)
        ForEach((s.orphans.isEmpty ? s.servers : s.orphans).prefix(3)) { p in
          panelLine(p, value: p.ports.isEmpty ? p.memory.bytes : p.portsLabel)
        }
      }
    }
  }
  private func panelLine(_ p: ProcessItem, value: String) -> some View {
    HStack(spacing: 6 * k) {
      ProcessIcon(process: p, size: 14 * k)
      Text(p.name).lineLimit(1)
      Spacer(minLength: 4)
      Text(value).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
      KillButton(process: p)
    }.font(.system(size: 11 * k)).frame(height: 22 * k)
  }

  // MARK: Agents
  /// Agent sessions with a process (terminal, editor, desktop) and Codex desktop threads,
  /// most urgent first; the order inside a state follows the Agents page.
  private func panelAgents(_ s: Snapshot) -> [PanelAgent] {
    var out: [PanelAgent] = []
    for root in s.agentSessions {
      let meta = agents.claudeSessions[root.pid]
      let stall = StallWatch.shared.stall(root: root, tree: s.subtree(of: root), meta: meta)
      let title = meta?.name ?? root.project ?? root.host ?? root.name
      let context = [root.host, title == root.project ? nil : root.project].compactMap { $0 }
      out.append(
        PanelAgent(
          id: "pid:\(root.pid)", title: title, subtitle: context.joined(separator: " · "),
          state: agentPanelState(status: meta?.status, stall: stall), stall: stall, process: root,
          open: .session(root, meta)))
    }
    // Desktop threads have no process of their own; shown while the Codex app is open.
    if s.processes.contains(where: { $0.host == "Codex Desktop" }) {
      for t in agents.codexThreads {
        let stall = StallWatch.shared.stall(thread: t)
        out.append(
          PanelAgent(
            id: "codex:\(t.id)", title: t.title, subtitle: ["Codex", t.project].compactMap { $0 }.joined(separator: " · "),
            state: t.running ? agentPanelState(status: "busy", stall: stall) : .waiting, stall: stall, process: nil,
            open: t.url.map { .url($0) }))
      }
    }
    return out.enumerated().sorted { ($0.element.state, $0.offset) < ($1.element.state, $1.offset) }.map(\.element)
  }
  private func agentsSummary(_ rows: [PanelAgent]) -> String {
    rows.isEmpty
      ? L("Nenhum agente em execução")
      : rows.map { "\($0.title): \($0.stateText)" }.joined(separator: "\n")
  }
  private func agentsSection(_ s: Snapshot) -> some View {
    let rows = panelAgents(s)
    return VStack(alignment: .leading, spacing: 5 * k) {
      Divider().opacity(0.5)
      sectionTitle(L("AGENTES"), count: rows.count, page: .agents)
      if prefs.limitsInPanel {
        ForEach(agents.limits) { row in LimitBar(title: row.title, window: row.window, compact: true) }
      }
      if rows.isEmpty {
        Text(L("Nenhum agente em execução")).font(.system(size: 10.5 * k)).foregroundStyle(.secondary)
      }
      ForEach(rows.prefix(5)) { row in agentLine(row) }
      if rows.count > 5 {
        Button(L("+ %@ na página Agentes", "\(rows.count - 5)")) { WindowOpener.shared.showMain(page: .agents) }
          .buttonStyle(.plain).font(.system(size: 10 * k)).foregroundStyle(.secondary)
      }
    }
  }
  private func agentLine(_ a: PanelAgent) -> some View {
    Button {
      a.open?.perform()
    } label: {
      HStack(spacing: 6 * k) {
        if let p = a.process {
          ProcessIcon(process: p, size: 14 * k)
        } else {
          Image(systemName: "sparkles").font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(Tint.netIn)
            .frame(width: 14 * k, height: 14 * k)
        }
        // The project/host goes when it does not fit whole, instead of shrinking to one letter.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 5 * k) {
            Text(a.title).lineLimit(1).fixedSize()
            Text(a.subtitle).font(.system(size: 9.5 * k)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
          }
          HStack(spacing: 0) {
            Text(a.title).lineLimit(1)
            Spacer(minLength: 0)
          }
        }
        Spacer(minLength: 4)
        HStack(spacing: 3 * k) {
          Image(systemName: a.symbol).font(.system(size: 8 * k, weight: .bold))
          Text(a.shortStateText).lineLimit(1)
        }
        .font(.system(size: 10 * k, weight: .medium)).monospacedDigit().foregroundStyle(a.color)
        .fixedSize()
      }
      .font(.system(size: 11 * k)).frame(height: 22 * k).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help([a.title, a.subtitle, a.stateText].filter { !$0.isEmpty }.joined(separator: "\n"))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(a.title)
    .accessibilityValue(a.stateText)
    .accessibilityAddTraits(.isButton)
  }

  // MARK: Remote machines
  private var machinesSection: some View {
    let hosts = machines.panelHosts
    return VStack(alignment: .leading, spacing: 5 * k) {
      Divider().opacity(0.5)
      sectionTitle(L("MÁQUINAS"), count: hosts.count, page: .machines)
      if hosts.isEmpty {
        Button(L("Escolha as máquinas em Ajustes › Painel flutuante")) {
          WindowOpener.shared.showMain(page: .settings)
        }.buttonStyle(.plain).font(.system(size: 10.5 * k)).foregroundStyle(.secondary)
      }
      ForEach(hosts, id: \.self) { host in machineLine(host, machines.states[host]) }
    }
  }
  private func machineLine(_ host: String, _ state: MachineState?) -> some View {
    Button {
      WindowOpener.shared.showMain(page: .machines)
    } label: {
      HStack(spacing: 6 * k) {
        Image(systemName: "server.rack").font(.system(size: 9.5 * k, weight: .semibold))
          .foregroundStyle(machineTint(state)).frame(width: 14 * k, height: 14 * k)
        Text(host).lineLimit(1)
        Spacer(minLength: 4)
        if let s = state?.stats {
          HStack(spacing: 7 * k) {
            machineValue("cpu", s.loadFraction)
            machineValue("memorychip", s.memoryFraction)
            machineValue("internaldrive", s.diskFraction)
          }.opacity(state?.error == nil ? 1 : 0.5)
        } else if state?.error != nil {
          Text(L("sem conexão")).font(.system(size: 10 * k)).foregroundStyle(.orange)
        } else if machines.probing.contains(host) {
          ProgressView().controlSize(.mini)
        } else {
          Text("—").foregroundStyle(.secondary)
        }
        if let alerts = state?.alerts, !alerts.isEmpty {
          Label("\(alerts.count)", systemImage: "exclamationmark.octagon.fill").labelStyle(CompactLabel())
            .font(.system(size: 10 * k, weight: .semibold)).foregroundStyle(.red)
        }
      }
      .font(.system(size: 11 * k)).frame(height: 22 * k).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(machineHelp(host, state))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(host)
    .accessibilityValue(machineHelp(host, state))
    .accessibilityAddTraits(.isButton)
  }
  private func machineValue(_ symbol: String, _ fraction: Double?) -> some View {
    HStack(spacing: 2 * k) {
      Image(systemName: symbol).font(.system(size: 8.5 * k)).foregroundStyle(.secondary)
      Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
        .font(.system(size: 10.5 * k, weight: .medium, design: .rounded)).monospacedDigit()
        .foregroundStyle(fraction.map { $0 > 0.9 ? Color.red : $0 > 0.75 ? .orange : .primary } ?? .secondary)
    }.fixedSize()
  }
  private func machineTint(_ state: MachineState?) -> Color {
    if !(state?.alerts.isEmpty ?? true) { return .red }
    return state?.error != nil ? .orange : state?.stats != nil ? Tint.brand : .secondary
  }
  private func machineHelp(_ host: String, _ state: MachineState?) -> String {
    var lines = [host]
    if let s = state?.stats {
      if let load = s.load.first { lines.append(L("Carga %@ em %@ núcleos", String(format: "%.2f", load), "\(s.cpus)")) }
      if let total = s.memoryTotal, let available = s.memoryAvailable {
        lines.append(L("Memória %@ de %@", formatBytes(total - available), formatBytes(total)))
      }
      if let total = s.diskTotal, let used = s.diskUsed {
        lines.append(L("Disco / %@ de %@", formatBytes(used), formatBytes(total)))
      }
    }
    if let error = state?.error { lines.append(error) }
    lines += (state?.alerts ?? []).map(\.text)
    if let at = state?.at { lines.append(L("lido %@", at.formatted(date: .omitted, time: .shortened))) }
    return lines.joined(separator: "\n")
  }
  private func sectionTitle(_ title: String, count: Int, page: Page) -> some View {
    Button {
      WindowOpener.shared.showMain(page: page)
    } label: {
      HStack(spacing: 4 * k) {
        Text(title)
        if count > 0 { Text("\(count)").foregroundStyle(.tertiary) }
      }.font(.system(size: 9 * k, weight: .bold)).foregroundStyle(.secondary)
    }.buttonStyle(.plain).help(L("Abrir %@", page.title))
  }

  private var menuButton: some View {
    Menu {
      PanelMenu()
    } label: {
      Image(systemName: "ellipsis.circle").font(.system(size: 11 * k))
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help(L("Layout, tamanho, opacidade e opções"))
    .accessibilityLabel(L("Opções do painel"))
  }
}
/// One row of the panel's Agents section.
private struct PanelAgent: Identifiable {
  enum Open {
    case session(ProcessItem, ClaudeSessionMeta?)
    case url(URL)
    /// Resolved on click: walking up to the hosting app costs too much for every redraw.
    func perform() {
      switch self {
      case .session(let root, let meta):
        if let jump = SessionJump.target(for: root, meta: meta, in: Monitor.shared.snapshot) {
          jump.open()
        } else {
          WindowOpener.shared.showMain(page: .agents)
        }
      case .url(let url): NSWorkspace.shared.open(url)
      }
    }
  }
  let id: String
  let title: String
  let subtitle: String
  let state: AgentPanelState
  let stall: AgentStall?
  let process: ProcessItem?
  let open: Open?
  var color: Color {
    switch state {
    case .stuck: .orange
    case .longCommand: .yellow
    case .busy: Tint.brand
    case .waiting, .unknown: .secondary
    }
  }
  var symbol: String {
    switch state {
    case .stuck: "exclamationmark.triangle.fill"
    case .longCommand: "hourglass"
    case .busy: "bolt.fill"
    case .waiting: "moon.fill"
    case .unknown: "circle.fill"
    }
  }
  var shortStateText: String {
    switch state {
    case .stuck: L("Parece travada · %@ min", "\(stall?.minutes ?? 1)")
    case .longCommand: L("Comando longo · %@ min", "\(stall?.minutes ?? 1)")
    case .busy: L("Trabalhando")
    case .waiting: L("Aguardando")
    case .unknown: L("Ativa")
    }
  }
  var stateText: String {
    if let stall { return stall.summary }
    switch state {
    case .waiting: return L("Aguardando sua próxima mensagem")
    case .unknown: return L("Em execução (o agente não informa o estado)")
    default: return shortStateText
    }
  }
}
private struct CompactLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 3) {
      configuration.icon
      configuration.title
    }
  }
}

/// Every panel option, reachable from the panel itself (ellipsis button or right click).
struct PanelMenu: View {
  @ObservedObject var prefs = Preferences.shared
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    Picker(L("Layout"), selection: $prefs.panelMode) {
      Text(L("Compacto")).tag("compact")
      Text(L("Padrão")).tag("standard")
      Text(L("Detalhado · processos")).tag("detailed")
    }
    Picker(L("Tamanho"), selection: $prefs.panelScale) {
      Text(L("Pequeno")).tag(0.88)
      Text(L("Médio")).tag(1.0)
      Text(L("Grande")).tag(1.18)
    }
    Picker(L("Opacidade do fundo"), selection: $prefs.panelOpacity) {
      Text("100%").tag(1.0)
      Text("92%").tag(0.92)
      Text("80%").tag(0.8)
      Text("65%").tag(0.65)
      Text("50%").tag(0.5)
    }
    Divider()
    Toggle(L("Manter acima das janelas"), isOn: $prefs.panelTop)
    Toggle(L("Travar posição"), isOn: $prefs.panelLocked)
    Toggle(L("Mostrar rede"), isOn: $prefs.panelNetwork)
    Toggle(L("Mostrar estado térmico"), isOn: $prefs.thermalInPanel)
    Toggle(L("Mostrar limites dos agentes"), isOn: $prefs.limitsInPanel)
    Toggle(L("Mostrar agentes"), isOn: $prefs.panelAgents)
    Toggle(L("Mostrar máquinas remotas"), isOn: $prefs.panelMachines)
    PanelProjectsMenu()
    Divider()
    Button(L("Abrir CoreScope")) { WindowOpener.shared.showMain() }
    Button(L("Ver processos")) { WindowOpener.shared.showMain(page: .processes) }
    Button(monitor.manuallyPaused ? L("Retomar coleta") : L("Pausar coleta")) {
      monitor.setPaused(!monitor.manuallyPaused)
    }
    Button(L("Ajustes…")) { WindowOpener.shared.showMain(page: .settings) }
    Divider()
    Button(L("Trazer para a tela principal")) { FloatingController.shared.recover() }
    Button(L("Ocultar painel")) { prefs.panelVisible = false }
  }
}
