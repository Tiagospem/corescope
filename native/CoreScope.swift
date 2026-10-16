import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Preferences.shared.applyAppearance()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    FloatingController.shared.apply()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main
struct CoreScopeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var monitor = Monitor.shared
  @StateObject private var prefs = Preferences.shared
  var body: some Scene {
    Window("CoreScope", id: "main") { MainView() }.defaultSize(width: 1080, height: 760)
      .commands {
        CommandGroup(replacing: .appInfo) {
          Button("Sobre o CoreScope") {
            NSApp.orderFrontStandardAboutPanel(options: [
              .applicationName: "CoreScope", .applicationVersion: "0.1.0",
              .credits: NSAttributedString(
                string: "Monitor local · Rust + SwiftUI\nDesenvolvimento · assinatura ad hoc"),
            ])
          }
        }
        CommandGroup(after: .windowArrangement) {
          Button("Painel flutuante") {
            prefs.panelVisible.toggle()
            FloatingController.shared.apply()
          }.keyboardShortcut("p", modifiers: [.command, .shift])
          Button(monitor.manuallyPaused ? "Retomar coleta" : "Pausar coleta") {
            monitor.setPaused(!monitor.manuallyPaused)
          }.keyboardShortcut(" ", modifiers: [.command, .shift])
        }
        CommandMenu("Navegar") {
          ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
            Button(page.rawValue) {
              NotificationCenter.default.post(
                name: Notification.Name("CoreScope.navigate"), object: page)
            }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
          }
        }
      }
    MenuBarExtra {
      MenuSummary()
    } label: {
      Text(menuTitle).monospacedDigit()
    }.menuBarExtraStyle(.window)
    Settings { PreferencesView().frame(width: 650, height: 730) }
  }
  private var menuTitle: String {
    guard let s = monitor.snapshot else { return "CoreScope —" }
    if monitor.stale { return "CoreScope Ⅱ" }
    let parts = prefs.menuItems.map { item in
      switch item {
      case "CPU":
        return prefs.compact
          ? "C \(s.cpu.value.map { String(Int($0)) + "%" } ?? "—")" : "CPU \(s.cpu.percent)"
      case "Memória": return prefs.compact ? "M \(s.memorySummary)" : "RAM \(s.memorySummary)"
      case "Disco": return "D \(s.diskRate)"
      case "Sensor":
        return
          "SSD \(s.disks.first{$0.id==prefs.selectedSensor}?.temperature.value.map{String(format:"%.0f°C",$0)} ?? "—")"
      default: return "T \(s.thermalLabel)"
      }
    }
    return parts.isEmpty ? "CoreScope" : parts.joined(separator: "  ·  ")
  }
}
struct MenuSummary: View {
  @ObservedObject var monitor = Monitor.shared
  @Environment(\.openWindow) var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("CoreScope", systemImage: "waveform.path.ecg").font(.headline)
        Spacer()
        Text(monitor.stale ? "Pausado" : "Local").font(.caption).foregroundStyle(.secondary)
      }
      if let s = monitor.snapshot {
        MetricLine(title: "CPU total", metric: s.cpu, text: s.cpu.percent)
        Sparkline(values: s.history.map(\.cpu)).frame(height: 35)
        MetricLine(
          title: "Memória¹", metric: s.physical, text: "\(s.memorySummary) / \(s.physical.bytes)")
        MetricLine(title: "Swap", metric: s.swap)
        MetricLine(title: "Estado térmico", metric: s.thermal, text: s.thermalLabel)
        if let d = s.diagnostics.first {
          Label(d.level > 0 ? d.title : "Nenhum alerta sustentado", systemImage: d.symbol).font(
            .caption
          ).foregroundStyle(d.color)
        }
        Text("¹ Ativa + wired + compressor; não é pressão.").font(.caption2).foregroundStyle(
          .secondary)
      }
      Divider()
      Button("Abrir CoreScope") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }.keyboardShortcut("o")
      Button(Preferences.shared.panelVisible ? "Ocultar painel" : "Mostrar painel") {
        Preferences.shared.panelVisible.toggle()
        FloatingController.shared.apply()
      }
      HStack {
        Button(monitor.manuallyPaused ? "Retomar" : "Pausar") {
          monitor.setPaused(!monitor.manuallyPaused)
        }
        Spacer()
        Button("Sair") { NSApp.terminate(nil) }
      }
    }.padding(20).frame(width: 330).background(Color(nsColor: .windowBackgroundColor))
  }
}
