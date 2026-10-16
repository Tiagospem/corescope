import AppKit
import Combine
import SwiftUI

final class FloatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
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
        contentRect: NSRect(x: 80, y: 80, width: 270, height: 190),
        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
        defer: false)
      window.title = "CoreScope · Painel"
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.isFloatingPanel = true
      window.hidesOnDeactivate = false
      window.isReleasedWhenClosed = false
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.delegate = self
      window.contentView = NSHostingView(rootView: FloatingView())
      panel = window
      restoreVisiblePosition()
    }
    guard let panel else { return }
    panel.level = p.panelTop ? .floating : .normal
    panel.isMovable = !p.panelLocked
    panel.isMovableByWindowBackground = !p.panelLocked
    panel.alphaValue =
      NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : p.panelOpacity
    panel.setContentSize(
      NSSize(
        width: 270 * p.panelScale, height: (p.selectedSensor.isEmpty ? 190 : 215) * p.panelScale))
    clampToScreen()
    panel.orderFrontRegardless()
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
      panel.setFrame(NSRectFromString(frame), display: false)
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
    let visible = screen.visibleFrame
    panel.setFrame(clampPanel(panel.frame, to: visible), display: false)
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
struct FloatingView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @Environment(\.accessibilityReduceTransparency) var reduceTransparency
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("CoreScope", systemImage: "waveform.path.ecg").font(.headline)
        Spacer()
        Text(monitor.stale ? "Pausado" : "Ao vivo").font(.caption).foregroundStyle(.secondary)
        if prefs.panelLocked { Image(systemName: "lock.fill").font(.caption) }
        Button {
          prefs.panelVisible = false
          FloatingController.shared.apply()
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).help("Ocultar painel")
      }
      if let s = monitor.snapshot {
        HStack {
          Text("CPU").foregroundStyle(.secondary)
          Text(s.cpu.percent).monospacedDigit()
          Spacer()
          Sparkline(values: s.history.map(\.cpu)).frame(width: 85, height: 25)
        }
        HStack {
          Text("RAM¹").foregroundStyle(.secondary)
          Text(s.memorySummary).monospacedDigit()
          Spacer()
        }
        if prefs.thermalInPanel {
          HStack {
            Image(systemName: "thermometer.medium")
            Text(s.thermalLabel)
            Spacer()

          }
        }
        if let sensor = s.disks.first(where: { $0.id == prefs.selectedSensor }) {
          Text("SSD: \(sensor.temperature.temperature)").font(.caption).help(
            sensor.name + " · " + sensor.temperature.explanation)
        }
        Text("¹ Ativa + wired + compressor").font(.caption2).foregroundStyle(.secondary)
      } else {
        ProgressView("Coletando…")
      }
    }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(
      reduceTransparency
        ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial)
    )
  }
}
