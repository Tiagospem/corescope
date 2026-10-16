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
        if !s.orphans.isEmpty {
          Badge(text: "\(s.orphans.count)", color: .orange, symbol: "exclamationmark.triangle.fill")
            .help(L("%@ possíveis órfãos", "\(s.orphans.count)"))
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
      Text(value).font(.system(size: 13 * k, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1)
      if let fraction { MeterBar(fraction: fraction, color: color).frame(width: 44 * k) }
    }
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
        Button {
          prefs.panelLocked.toggle()
        } label: {
          Image(systemName: prefs.panelLocked ? "lock.fill" : "lock.open").font(.system(size: 10 * k))
        }.buttonStyle(HoverButtonStyle(tint: .accentColor, size: 20 * k))
          .help(prefs.panelLocked ? L("Posição travada") : L("Travar posição"))
        menuButton
        Button {
          prefs.panelVisible = false
        } label: {
          Image(systemName: "xmark").font(.system(size: 9 * k, weight: .bold))
        }.buttonStyle(HoverButtonStyle(size: 20 * k)).help(L("Ocultar painel"))
      }
      if let s = monitor.snapshot {
        metricRow(
          L("CPU"), s.cpu.value.map { String(format: "%.1f%%", $0) } ?? "—",
          [ChartSeries(values: s.history.map(\.cpu), color: Tint.cpu)], ceiling: 100)
        metricRow(
          L("Memória"), s.memorySummary,
          [ChartSeries(values: s.history.map(\.memory), color: Tint.memory)],
          ceiling: s.physical.value,
          detail: s.memoryFraction.map { String(format: L("%.0f%%"), $0 * 100) })
        metricRow(
          L("Disco"), s.diskRate,
          [
            ChartSeries(values: s.history.map(\.disk_read), color: Tint.diskRead),
            ChartSeries(values: s.history.map(\.disk_write), color: Tint.diskWrite),
          ])
        if prefs.panelNetwork {
          metricRow(
            L("Rede"), formatRate((s.net_in.value ?? 0) + (s.net_out.value ?? 0)),
            [
              ChartSeries(values: s.history.map(\.net_in), color: Tint.netIn),
              ChartSeries(values: s.history.map(\.net_out), color: Tint.netOut),
            ])
        }
        if prefs.limitsInPanel {
          ForEach(agents.codex.windows) { w in LimitBar(title: "Codex", window: w, compact: true) }
        }
        statusLine(s)
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
      AreaChart(series: series, ceiling: ceiling, capacity: 60, grid: false, lineWidth: 1.3)
        .frame(width: chartWidth, height: 26 * k)
    }
  }
  private func statusLine(_ s: Snapshot) -> some View {
    HStack(spacing: 8 * k) {
      if prefs.thermalInPanel {
        HStack(spacing: 3) {
          Circle().fill(s.thermalColor).frame(width: 6, height: 6)
          Text(s.thermalLabel)
        }.help(L("Estado térmico do macOS"))
      }
      if let sensor = s.disks.first(where: { $0.id == prefs.selectedSensor }) {
        Text(L("SSD %@", "\(sensor.temperature.value.map { String(format: "%.0f °C", $0) } ?? "—")"))
          .help(sensor.name)
      }
      Spacer(minLength: 0)
      if !s.servers.isEmpty {
        Label("\(s.servers.count)", systemImage: "network").help(L("%@ servidores em escuta", "\(s.servers.count)"))
      }
      if !s.orphans.isEmpty {
        Label("\(s.orphans.count)", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange).help(L("%@ possíveis órfãos", "\(s.orphans.count)"))
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
  private var menuButton: some View {
    Menu {
      PanelMenu()
    } label: {
      Image(systemName: "ellipsis.circle").font(.system(size: 11 * k))
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help(L("Layout, tamanho, opacidade e opções"))
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
    Toggle(L("Mostrar limite do Codex"), isOn: $prefs.limitsInPanel)
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
