import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global shortcut for the port lookup. RegisterEventHotKey delivers only this one key
/// combination to the app: no Accessibility or Input Monitoring permission, no key logging.
final class Hotkey: ObservableObject {
  static let shared = Hotkey()
  /// Another app already owns the combination.
  @Published var failed = false
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?

  func apply() {
    unregister()
    let p = Preferences.shared
    guard p.hotkeyEnabled else {
      failed = false
      return
    }
    if handler == nil {
      var spec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      InstallEventHandler(
        GetApplicationEventTarget(),
        { _, _, _ in
          DispatchQueue.main.async { PortLookup.open() }
          return noErr
        }, 1, &spec, nil, &handler)
    }
    // Signature "CSpt".
    let id = EventHotKeyID(signature: OSType(0x4353_7074), id: 1)
    let status = RegisterEventHotKey(
      UInt32(p.hotkeyCode), UInt32(p.hotkeyModifiers), id, GetApplicationEventTarget(), 0, &ref)
    failed = status != noErr
  }

  /// Released while the user records a new combination, so the old one reaches the recorder.
  func unregister() {
    if let ref { UnregisterEventHotKey(ref) }
    ref = nil
  }

  static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    var out = 0
    if flags.contains(.command) { out |= HotkeyModifier.command }
    if flags.contains(.shift) { out |= HotkeyModifier.shift }
    if flags.contains(.option) { out |= HotkeyModifier.option }
    if flags.contains(.control) { out |= HotkeyModifier.control }
    return out
  }
}

/// Opens the menu bar popover with the port field focused.
enum PortLookup {
  static let focus = Notification.Name("CoreScope.focusPort")
  /// Read by the popover when it appears, for the case where it was closed.
  static var pendingFocus = false
  /// Fallback popover, alive only while shown.
  private static var popover: NSPopover?
  private static var closeObserver: NSObjectProtocol?

  static func open() {
    pendingFocus = true
    NSApp.activate(ignoringOtherApps: true)
    // Fresh ports: the collector otherwise runs every 10 s while no window is visible.
    Monitor.shared.refresh()
    if let window = NSApp.windows.first(where: {
      $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtraWindow")
    }) {
      window.makeKeyAndOrderFront(nil)
    } else if let popover, popover.isShown {
      popover.contentViewController?.view.window?.makeKey()
    } else if let button = statusButton() {
      if button.action != nil {
        // macOS 14–26: SwiftUI wires the MenuBarExtra to the button's target/action.
        button.performClick(nil)
      } else {
        // macOS 27 presents MenuBarExtra windows through private API only, so the same menu
        // content is shown in a public NSPopover anchored to the status item.
        show(from: button)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      NotificationCenter.default.post(name: focus, object: nil)
    }
  }

  static func close() { popover?.performClose(nil) }

  private static func show(from button: NSStatusBarButton) {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(rootView: MenuSummary())
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
    self.popover = popover
    closeObserver = NotificationCenter.default.addObserver(
      forName: NSPopover.didCloseNotification, object: popover, queue: .main
    ) { _ in
      // Release the hosted view: nothing stays in memory between lookups.
      if let observer = Self.closeObserver { NotificationCenter.default.removeObserver(observer) }
      Self.closeObserver = nil
      Self.popover = nil
    }
  }

  /// The MenuBarExtra's status item button (the app has exactly one status item).
  private static func statusButton() -> NSStatusBarButton? {
    func find(_ view: NSView?) -> NSStatusBarButton? {
      guard let view else { return nil }
      if let button = view as? NSStatusBarButton { return button }
      for sub in view.subviews { if let found = find(sub) { return found } }
      return nil
    }
    for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
      if let button = find(window.contentView) { return button }
    }
    return nil
  }
}

/// Records a new global shortcut from the next key press in this window (a local monitor:
/// no global key access). Requires ⌘, ⌃ or ⌥; Esc cancels.
struct ShortcutRecorder: View {
  @ObservedObject var p = Preferences.shared
  @ViewState private var recording = false
  @ViewState private var monitor: Any?
  var body: some View {
    Button(recording ? L("Pressione o atalho…") : p.hotkeyLabel) {
      recording ? stop() : start()
    }.monospacedDigit()
  }
  private func start() {
    recording = true
    Hotkey.shared.unregister()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == UInt16(kVK_Escape) {
        stop()
        return nil
      }
      let mods = Hotkey.carbonModifiers(event.modifierFlags)
      let required = HotkeyModifier.command | HotkeyModifier.control | HotkeyModifier.option
      guard mods & required != 0, let key = event.charactersIgnoringModifiers, !key.isEmpty
      else {
        NSSound.beep()
        return nil
      }
      p.hotkeyCode = Int(event.keyCode)
      p.hotkeyModifiers = mods
      p.hotkeyKey = key.uppercased()
      stop()
      return nil
    }
  }
  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
    Hotkey.shared.apply()
  }
}

/// Popover field: which of the user's processes listens on a port, with open and stop actions.
struct PortQuickLookup: View {
  let snapshot: Snapshot
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var text = ""
  @FocusState private var focused: Bool
  private var port: UInt16? { parsePort(text) }
  private var matches: [(ProcessItem, Int)] {
    guard let port else { return [] }
    return snapshot.serverGroups.filter { $0.0.ports.contains { $0.port == port } }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
        TextField(L("Porta"), text: $text).textFieldStyle(.roundedBorder).frame(width: 90)
          .focused($focused)
          .onChange(of: text) { _, value in
            let digits = String(value.filter(\.isNumber).prefix(5))
            if digits != value { text = digits }
          }
          .onExitCommand { text = "" }
        if let port, matches.isEmpty {
          Label(L("Livre"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            .font(.caption).help(L("Nenhum processo seu escuta em :%@", "\(port)"))
        } else if port == nil && !text.isEmpty {
          Text(L("Porta inválida")).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if prefs.hotkeyEnabled && !Hotkey.shared.failed {
          Text(prefs.hotkeyLabel).font(.caption2).foregroundStyle(.tertiary)
            .help(L("Atalho global para buscar porta"))
        }
      }
      ForEach(matches, id: \.0.id) { p, instances in
        ProcessLine(
          process: p,
          subtitle: [devSubtitle(p), instances > 1 ? L("×%@", "\(instances)") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        ) {
          if let port { OpenPortButton(port: port) }
          KillButton(process: p)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: PortLookup.focus)) { _ in focus() }
    .onAppear { if PortLookup.pendingFocus { DispatchQueue.main.async { focus() } } }
  }
  private func focus() {
    PortLookup.pendingFocus = false
    focused = true
  }
}
