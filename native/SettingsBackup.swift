import AppKit
import SwiftUI

/// Keeps a copy of the user's settings (preferences, profiles, Services, machines, recipes,
/// project folders) in a folder outside ~/Library, so updating, reinstalling or removing the app
/// with an uninstaller that deletes its preferences does not lose them. A first launch with empty
/// settings and a backup in that folder offers to restore it.
final class SettingsBackup: ObservableObject {
  static let shared = SettingsBackup()
  static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".corescope/backups")
  @Published var enabled = UserDefaults.standard.object(forKey: "settingsBackup") as? Bool ?? true {
    didSet {
      UserDefaults.standard.set(enabled, forKey: "settingsBackup")
      if enabled { scheduleWrite(delay: 1) }
    }
  }
  @Published var folder: URL = UserDefaults.standard.string(forKey: "settingsBackupFolder").map { URL(fileURLWithPath: $0) }
    ?? SettingsBackup.defaultFolder
  {
    didSet {
      UserDefaults.standard.set(folder.path, forKey: "settingsBackupFolder")
      lastHash = nil
      scheduleWrite(delay: 1)
    }
  }
  @Published private(set) var lastWritten: Date?
  @Published private(set) var lastError: String?
  private var lastHash: Int?
  private var pending: DispatchWorkItem?
  private var observer: NSObjectProtocol?
  private let queue = DispatchQueue(label: "app.corescope.settingsbackup", qos: .utility)
  /// Small files from Application Support kept with the settings.
  private static let dataFiles = ["services-history.json", "disk-growth.json"]
  private static var support: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CoreScope")
  }
  private static var domain: [String: Any] {
    UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "local.corescope.app") ?? [:]
  }

  /// At launch: offer the backup when the settings are empty; then watch for changes.
  func start() {
    if SettingsBackupLogic.isFresh(Self.domain), let latest = latestBackup() {
      offerRestore(latest)
    }
    lastWritten = (try? latestBackup()?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.scheduleWrite(delay: 8) }
    scheduleWrite(delay: 30)
  }
  func latestBackup() -> URL? {
    let url = folder.appendingPathComponent("latest.plist")
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }
  private func scheduleWrite(delay: Double) {
    guard enabled else { return }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.write(force: false) }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
  /// Writes `latest.plist` plus a dated copy when the settings changed since the last backup.
  func write(force: Bool, done: ((String?) -> Void)? = nil) {
    let settings = SettingsBackupLogic.settings(Self.domain)
    guard !settings.isEmpty else {
      done?(nil)
      return
    }
    let folder = self.folder
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("settingsbackup", cost) }
      var payload = settings
      payload["corescope.backup.version"] = AppVersion.short
      payload["corescope.backup.date"] = Date()
      var files: [String: Data] = [:]
      for name in Self.dataFiles {
        if let data = try? Data(contentsOf: Self.support.appendingPathComponent(name)), data.count < 4 << 20 { files[name] = data }
      }
      payload["corescope.backup.files"] = files
      let hashable = (try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0))?.hashValue
      if !force, hashable != nil, hashable == self.lastHash {
        DispatchQueue.main.async { done?(nil) }
        return
      }
      var failure: String?
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        let stamp = Self.stamp.string(from: Date())
        try data.write(to: folder.appendingPathComponent("settings-\(stamp).plist"), options: .atomic)
        try data.write(to: folder.appendingPathComponent("latest.plist"), options: .atomic)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for old in SettingsBackupLogic.expired(names, keep: 20) {
          try? FileManager.default.removeItem(at: folder.appendingPathComponent(old))
        }
      } catch { failure = error.localizedDescription }
      DispatchQueue.main.async {
        if failure == nil {
          self.lastHash = hashable
          self.lastWritten = Date()
        }
        self.lastError = failure
        done?(failure)
      }
    }
  }
  private static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return f
  }()

  /// Reads a backup file: its settings and when it was made.
  static func read(_ url: URL) -> (settings: [String: Any], files: [String: Data], date: Date?, version: String?)? {
    guard let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    let files = plist["corescope.backup.files"] as? [String: Data] ?? [:]
    return (
      SettingsBackupLogic.settings(plist).filter { !$0.key.hasPrefix("corescope.backup.") }, files,
      plist["corescope.backup.date"] as? Date, plist["corescope.backup.version"] as? String
    )
  }
  private func offerRestore(_ url: URL) {
    guard let backup = Self.read(url) else { return }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = L("Restaurar suas configurações?")
    alert.informativeText = L(
      "O CoreScope abriu sem configurações, mas há um backup de %@ em %@ (perfis, Serviços, máquinas e preferências).",
      backup.date?.formatted(date: .abbreviated, time: .shortened) ?? "?", abbreviateHome(folder.path))
    alert.addButton(withTitle: L("Restaurar"))
    alert.addButton(withTitle: L("Começar do zero"))
    if alert.runModal() == .alertFirstButtonReturn { restore(url) }
  }
  /// Applies a backup and relaunches, so every part of the app starts from the restored values.
  func restore(_ url: URL) {
    guard let backup = Self.read(url) else {
      lastError = L("Backup ilegível: %@", url.lastPathComponent)
      return
    }
    let defaults = UserDefaults.standard
    for (key, value) in backup.settings { defaults.set(value, forKey: key) }
    try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
    for (name, data) in backup.files where Self.dataFiles.contains(name) {
      try? data.write(to: Self.support.appendingPathComponent(name), options: .atomic)
    }
    defaults.synchronize()
    let relaunch = Process()
    relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
    relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? relaunch.run()
    NSApp.terminate(nil)
  }
}

/// Settings › Backup.
struct SettingsBackupSection: View {
  @ObservedObject var backup = SettingsBackup.shared
  @ViewState private var message: String?
  var body: some View {
    Section(L("Backup das configurações")) {
      Toggle(L("Manter um backup das configurações"), isOn: $backup.enabled)
      LabeledContent(L("Pasta")) {
        HStack {
          Text(abbreviateHome(backup.folder.path)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          Button(L("Alterar…")) { choose() }.controlSize(.small)
          Button { NSWorkspace.shared.activateFileViewerSelecting([backup.folder]) } label: { Image(systemName: "folder") }
            .buttonStyle(HoverButtonStyle()).help(L("Mostrar no Finder"))
        }
      }
      LabeledContent(L("Último backup")) {
        Text(backup.lastWritten.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? L("ainda não"))
      }
      HStack {
        Button(L("Fazer backup agora")) {
          backup.write(force: true) { error in message = error ?? L("Backup salvo.") }
        }
        Button(L("Restaurar…")) { pickRestore() }
        Spacer()
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
      }
      if let error = backup.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
      Text(
        L("Atualizar o app mantém as configurações. Desinstaladores (AppCleaner, CleanMyMac, brew uninstall --zap) apagam ~/Library/Preferences e Application Support; com o backup numa pasta fora de ~/Library, o CoreScope oferece restaurar ao abrir sem configurações. Guarda perfis, Serviços, máquinas, receitas, pastas de projeto e preferências; não guarda o histórico nem os snapshots de banco. Escolha uma pasta no iCloud Drive para levar para outro Mac.")
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = backup.folder
    panel.prompt = L("Usar esta pasta")
    if panel.runModal() == .OK, let url = panel.url { backup.folder = url }
  }
  private func pickRestore() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.propertyList]
    panel.directoryURL = backup.folder
    panel.prompt = L("Restaurar")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let alert = NSAlert()
    alert.messageText = L("Restaurar este backup?")
    alert.informativeText = L("As configurações atuais são substituídas pelas do backup e o CoreScope reinicia.")
    alert.addButton(withTitle: L("Restaurar e reiniciar"))
    alert.addButton(withTitle: L("Cancelar"))
    if alert.runModal() == .alertFirstButtonReturn { backup.restore(url) }
  }
}
