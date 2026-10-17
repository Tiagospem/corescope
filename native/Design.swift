import AppKit
import SwiftUI

/// Series colors stay fixed so each resource is recognizable across window, menu and panel.
enum Tint {
  static let brand = Color(red: 0.24, green: 0.86, blue: 0.52)
  static let cpu = brand
  static let memory = Color(red: 0.40, green: 0.62, blue: 1.0)
  static let diskRead = Color(red: 1.0, green: 0.62, blue: 0.25)
  static let diskWrite = Color(red: 1.0, green: 0.42, blue: 0.55)
  static let netIn = Color(red: 0.30, green: 0.82, blue: 0.95)
  static let netOut = Color(red: 0.70, green: 0.55, blue: 1.0)
  static let warning = Color.orange
  static let danger = Color.red
}

struct ChartSeries {
  var values: [Double?]
  var color: Color
  /// Series name and value format spoken by VoiceOver (e.g. "leitura", formatRate).
  var name: String? = nil
  var format: (Double) -> String = { String(format: "%.1f", $0) }
}
/// Fixed series per resource: color, spoken name and unit stay consistent everywhere.
extension ChartSeries {
  static func cpu(_ values: [Double?]) -> ChartSeries {
    ChartSeries(values: values, color: Tint.cpu, format: { String(format: "%.1f%%", $0) })
  }
  static func memory(_ values: [Double?]) -> ChartSeries {
    ChartSeries(values: values, color: Tint.memory, format: formatBytes)
  }
  static func diskRead(_ values: [Double?]) -> ChartSeries {
    ChartSeries(values: values, color: Tint.diskRead, name: L("leitura"), format: formatRate)
  }
  static func diskWrite(_ values: [Double?]) -> ChartSeries {
    ChartSeries(values: values, color: Tint.diskWrite, name: L("escrita"), format: formatRate)
  }
  static func netIn(_ values: [Double?]) -> ChartSeries {
    ChartSeries(values: values, color: Tint.netIn, name: L("entrada"), format: formatRate)
  }
  static func netOut(_ values: [Double?]) -> ChartSeries {
    ChartSeries(values: values, color: Tint.netOut, name: L("saída"), format: formatRate)
  }
}
/// Right-aligned area chart: the newest sample sits on the right edge and gaps break the line.
struct AreaChart: View {
  var series: [ChartSeries]
  /// Fixed upper bound (e.g. 100 for percentages); nil scales to the visible peak.
  var ceiling: Double? = nil
  var capacity = 120
  var grid = true
  var lineWidth: CGFloat = 1.5
  /// Resource name for VoiceOver (e.g. "CPU").
  var title: String? = nil
  var body: some View {
    Canvas { context, size in
      let peak = series.flatMap { $0.values.compactMap { $0 } }.max() ?? 0
      let top = max(ceiling ?? 0, ceiling == nil ? max(peak * 1.18, 1) : peak)
      if grid {
        for fraction in [0.33, 0.66] {
          var line = Path()
          let y = size.height * fraction
          line.move(to: CGPoint(x: 0, y: y))
          line.addLine(to: CGPoint(x: size.width, y: y))
          context.stroke(
            line, with: .color(.primary.opacity(0.07)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
      }
      let step = size.width / CGFloat(max(1, capacity - 1))
      for s in series {
        let count = s.values.count
        var segments: [[CGPoint]] = [[]]
        for (index, value) in s.values.enumerated() {
          guard let value else {
            if !(segments.last?.isEmpty ?? true) { segments.append([]) }
            continue
          }
          let x = size.width - CGFloat(count - 1 - index) * step
          let y = size.height - 1 - CGFloat(min(value, top) / top) * (size.height - 3)
          segments[segments.count - 1].append(CGPoint(x: x, y: y))
        }
        for points in segments where points.count > 1 {
          var line = Path()
          line.addLines(points)
          var area = line
          area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
          area.addLine(to: CGPoint(x: points.first!.x, y: size.height))
          area.closeSubpath()
          context.fill(
            area,
            with: .linearGradient(
              Gradient(colors: [s.color.opacity(0.30), s.color.opacity(0.02)]),
              startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
          context.stroke(
            line, with: .color(s.color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .accessibilityElement()
    .accessibilityLabel(title.map { L("Histórico de %@", $0) } ?? L("Histórico"))
    .accessibilityValue(spokenValue)
  }
  /// Latest and peak of each series, in its own unit; gaps read as unavailable.
  private var spokenValue: String {
    series.map { s in
      let latest = s.values.last.flatMap { $0 }.map(s.format) ?? L("indisponível")
      let peak = s.values.compactMap { $0 }.max().map(s.format) ?? L("indisponível")
      let text = L("último %@, pico %@", latest, peak)
      return s.name.map { "\($0): \(text)" } ?? text
    }.joined(separator: "; ")
  }
}
/// Compatibility wrapper for single-series charts.
struct Sparkline: View {
  let values: [Double?]
  var ceiling: Double = 100
  var color: Color = Tint.cpu
  var body: some View {
    AreaChart(series: [ChartSeries(values: values, color: color)], ceiling: ceiling, grid: false)
  }
}

struct Card<Content: View>: View {
  var padding: CGFloat = 14
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 10) { content }
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
  }
}
struct CardHeader<Trailing: View>: View {
  let title: String
  let symbol: String
  var tint: Color = .secondary
  var count: Int? = nil
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 12, weight: .semibold))
        .accessibilityHidden(true)
      Text(title).font(.system(size: 13, weight: .semibold))
      if let count { Badge(text: "\(count)", color: count > 0 ? tint : .secondary) }
      Spacer(minLength: 4)
      trailing
    }
  }
}
extension CardHeader where Trailing == EmptyView {
  init(title: String, symbol: String, tint: Color = .secondary, count: Int? = nil) {
    self.init(title: title, symbol: symbol, tint: tint, count: count) { EmptyView() }
  }
}

struct Badge: View {
  let text: String
  var color: Color = .secondary
  var symbol: String? = nil
  var body: some View {
    HStack(spacing: 3) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 8, weight: .bold)).accessibilityHidden(true)
      }
      Text(text).lineLimit(1)
    }
    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
    .padding(.horizontal, 6).padding(.vertical, 2)
    .foregroundStyle(color)
    .background(color.opacity(0.14), in: Capsule())
    .accessibilityElement(children: .combine)
  }
}
/// Listening port; orange when reachable from the network.
struct PortBadge: View {
  let port: PortInfo
  var body: some View {
    Badge(text: ":\(port.port)", color: port.exposed ? .orange : Tint.netIn)
      .help(port.exposed ? L("Acessível na rede") : L("Somente local"))
      .accessibilityLabel(L("Porta %@", "\(port.port)"))
      .accessibilityValue(port.exposed ? L("Acessível na rede") : L("Somente local"))
  }
}
struct MeterBar: View {
  let fraction: Double
  var color: Color
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.08))
        Capsule().fill(color).frame(width: max(2, g.size.width * min(1, max(0, fraction))))
      }
    }.frame(height: 4)
      .accessibilityElement()
      .accessibilityLabel(L("Uso"))
      .accessibilityValue(String(format: "%.0f%%", min(1, max(0, fraction)) * 100))
  }
}
struct LiveDot: View {
  let stale: Bool
  var body: some View {
    // Always paired with a "Live" / "Paused" text, so VoiceOver skips the dot.
    Circle().fill(stale ? Color.orange : Tint.brand).frame(width: 7, height: 7)
      .shadow(color: (stale ? Color.orange : Tint.brand).opacity(0.6), radius: 3)
      .accessibilityHidden(true)
  }
}

/// Plain icon button with a hover plate; works in non-activating panels and popovers.
struct HoverButtonStyle: ButtonStyle {
  var tint: Color = .primary
  var size: CGFloat = 24
  func makeBody(configuration: Configuration) -> some View {
    HoverPlate(pressed: configuration.isPressed, tint: tint, size: size) { configuration.label }
  }
}
private struct HoverPlate<Label: View>: View {
  let pressed: Bool
  let tint: Color
  let size: CGFloat
  @ViewBuilder var label: Label
  @ViewState private var hovering = false
  var body: some View {
    label
      .foregroundStyle(hovering ? tint : .secondary)
      .frame(minWidth: size, minHeight: size)
      .background(
        RoundedRectangle(cornerRadius: 6).fill(
          Color.primary.opacity(pressed ? 0.16 : hovering ? 0.09 : 0))
      )
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

enum IconCache {
  private static var images: [String: NSImage] = [:]
  static func image(for bundle: String) -> NSImage {
    if let cached = images[bundle] { return cached }
    let image = NSWorkspace.shared.icon(forFile: bundle)
    images[bundle] = image
    return image
  }
}
/// Real app icon for bundled executables; a symbol describing the role otherwise.
/// Decorative: the process name is always next to it, so VoiceOver skips the icon.
struct ProcessIcon: View {
  let process: ProcessItem
  var size: CGFloat = 16
  var body: some View {
    icon.accessibilityHidden(true)
  }
  @ViewBuilder private var icon: some View {
    // Bundled agent CLIs (e.g. claude-code/<v>/claude.app) ship no icon of their own.
    let bundledCLI = process.tags.contains("agent") && !(process.host ?? "").hasSuffix("Desktop")
    if let bundle = process.bundlePath, !bundledCLI {
      Image(nsImage: IconCache.image(for: bundle)).resizable().interpolation(.high)
        .frame(width: size, height: size)
    } else {
      let (symbol, color) = Self.symbol(for: process)
      Image(systemName: symbol)
        .font(.system(size: size * 0.62, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25))
    }
  }
  static func symbol(for p: ProcessItem) -> (String, Color) {
    let t = Set(p.tags)
    if t.contains("agent") { return ("sparkles", .orange) }
    if t.contains("database") { return ("cylinder.split.1x2", .indigo) }
    if t.contains("server") { return ("network", Tint.netIn) }
    if t.contains("mcp") { return ("puzzlepiece.extension", .purple) }
    if t.contains("container") { return ("shippingbox", .blue) }
    if t.contains("runtime") { return ("chevron.left.forwardslash.chevron.right", Tint.brand) }
    if t.contains("shell") { return ("terminal", .gray) }
    if p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/") || p.uid == 0 {
      return ("gearshape", .gray)
    }
    return ("app.dashed", .secondary)
  }
}

/// Two-step action in place: one click arms, a second confirms; it disarms itself after 4 s.
/// Avoids opening any window to act on a row.
struct ArmedButton: View {
  let symbol: String
  let confirm: String
  let help: String
  /// VoiceOver names for the idle button and for the confirm step.
  var label: String? = nil
  var confirmLabel: String? = nil
  var tint: Color = Tint.danger
  /// False acts on the first click (the user disabled confirmation for this action).
  var needsConfirm = true
  let action: () -> Void
  @ViewState private var armed = false
  @ViewState private var token = 0
  var body: some View {
    if armed {
      HStack(spacing: 2) {
        Button(confirm) {
          armed = false
          action()
        }.buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
          .accessibilityLabel(confirmLabel ?? confirm)
        Button {
          armed = false
        } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        }.buttonStyle(HoverButtonStyle(size: 20)).help(L("Cancelar")).accessibilityLabel(L("Cancelar"))
      }
    } else {
      Button {
        guard needsConfirm else { return action() }
        armed = true
        token += 1
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
          if token == current { armed = false }
        }
      } label: {
        Image(systemName: symbol).font(.system(size: 13))
      }
      .buttonStyle(HoverButtonStyle(tint: tint, size: 22))
      .help(help)
      .accessibilityLabel(label ?? help)
    }
  }
}
/// Terminate in place (or a single click when the user disabled confirmation).
struct KillButton: View {
  let process: ProcessItem
  var force = false
  /// Everything to signal on confirm (e.g. a whole agent session); defaults to the process.
  /// Group kills always ask for the second click, whatever the confirmation preference.
  var targets: [ProcessItem]? = nil
  private var group: [ProcessItem] { targets ?? [process] }
  // Not observed: hundreds of rows would otherwise re-render on every snapshot.
  private var monitor: Monitor { Monitor.shared }
  private var prefs: Preferences { Preferences.shared }
  var body: some View {
    if !process.eligible {
      Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
        .frame(width: 22, height: 22).help(L(process.blocked))
        .accessibilityLabel(L("%@ não pode ser encerrado", "\(process.name)"))
        .accessibilityHint(L(process.blocked))
    } else {
      ArmedButton(
        symbol: force ? "bolt.circle" : "xmark.circle",
        confirm: force ? L("Forçar") : L("Encerrar"),
        help: group.count > 1
          ? L("Encerra a sessão e os %@ processos que ela iniciou", String(group.count - 1))
          : force
            ? L("Forçar encerramento (SIGKILL) de %@", "\(process.name)")
            : L("Encerrar %@ (SIGTERM)", "\(process.name)"),
        label: group.count > 1
          ? L("Encerrar sessão %@", "\(process.name)")
          : force ? L("Forçar encerramento de %@", "\(process.name)") : L("Encerrar %@", "\(process.name)"),
        confirmLabel: force
          ? L("Confirmar: forçar %@", "\(process.name)") : L("Confirmar: encerrar %@", "\(process.name)"),
        needsConfirm: prefs.confirmTerminate || force || group.count > 1
      ) {
        monitor.signal(group, force: force)
      }
    }
  }
}
struct OpenPortButton: View {
  let port: UInt16
  var body: some View {
    Button {
      if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    } label: {
      Image(systemName: "safari").font(.system(size: 12))
    }.buttonStyle(HoverButtonStyle(tint: .accentColor, size: 22)).help(L("Abrir http://localhost:%@", "\(port)"))
      .accessibilityLabel(L("Abrir localhost:%@ no navegador", "\(port)"))
  }
}

/// Result of the last termination, with a one-click escalation when processes ignored SIGTERM.
struct FeedbackToast: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    if let f = monitor.feedback {
      HStack(spacing: 10) {
        if f.pending {
          ProgressView().controlSize(.small)
        } else {
          Image(
            systemName: f.failed || !f.survivors.isEmpty
              ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
          ).foregroundStyle(f.failed || !f.survivors.isEmpty ? Color.orange : Tint.brand)
        }
        Text(f.message).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 6)
        if !f.survivors.isEmpty {
          Button(L("Forçar encerramento")) {
            monitor.signal(f.survivors, force: true)
          }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
        }
        Button {
          monitor.feedback = nil
        } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
        }.buttonStyle(HoverButtonStyle(size: 20)).help(L("Dispensar")).accessibilityLabel(L("Dispensar"))
      }
      .padding(.horizontal, 12).padding(.vertical, 9)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
      .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
      .id(f.id)
      .task(id: f.id) {
        // The toast never takes focus; announce the result so VoiceOver users hear it.
        AccessibilityNotification.Announcement(f.message).post()
        guard !f.pending, f.survivors.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        if monitor.feedback?.id == f.id { monitor.feedback = nil }
      }
    }
  }
}

/// Confirmation used by the main window for selection, tree and force actions.
struct KillConfirmation: ViewModifier {
  @ObservedObject var monitor = Monitor.shared
  func body(content: Content) -> some View {
    content.alert(
      monitor.pendingKill?.title ?? "",
      isPresented: Binding(
        get: { monitor.pendingKill != nil }, set: { if !$0 { monitor.pendingKill = nil } }),
      presenting: monitor.pendingKill
    ) { request in
      Button(request.force ? L("Forçar encerramento") : L("Encerrar"), role: .destructive) {
        monitor.signal(request.targets, force: request.force)
      }.keyboardShortcut(.defaultAction)
      if !request.force {
        Button(L("Forçar (SIGKILL)")) { monitor.signal(request.targets, force: true) }
      }
      Button(L("Cancelar"), role: .cancel) {}
    } message: { request in
      Text(request.detail)
    }
  }
}

/// Opens the main window from places outside its scene (floating panel, Dock reopen).
final class WindowOpener {
  static let shared = WindowOpener()
  var open: (() -> Void)?
  func showMain(page: Page? = nil) {
    if Preferences.shared.dockMode == "window" { NSApp.setActivationPolicy(.regular) }
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
      window.makeKeyAndOrderFront(nil)
    } else {
      open?()
    }
    NSApp.activate(ignoringOtherApps: true)
    if let page {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        NotificationCenter.default.post(name: Notification.Name("CoreScope.navigate"), object: page)
      }
    }
  }
}
