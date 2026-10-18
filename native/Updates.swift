import AppKit
import Sparkle
import SwiftUI

/// Opt-in updates through Sparkle. Off by default and Sparkle is not even started until the user
/// turns checks on or clicks Check now, so with the toggle off the app makes no request. The feed
/// (SUFeedURL) is the appcast of the latest GitHub release; the appcast and the update archive
/// must carry EdDSA signatures from the release key (SUPublicEDKey), which is what lets an ad hoc
/// signed app trust an update. Installing happens only after the user clicks Install and relaunch.
final class UpdateStore: NSObject, ObservableObject {
  static let shared = UpdateStore()
  enum Phase: Equatable {
    case idle, checking, downloading(Double?), extracting(Double), installing
    case failed(String)
  }
  struct Release: Equatable {
    var version: String
    var build: String
    var notes: String
    var date: Date?
  }
  @Published private(set) var phase: Phase = .idle
  /// A release newer than this build, from the last check (kept across launches).
  @Published private(set) var available: Release?
  @Published private(set) var lastCheck: Date?
  /// The last check found nothing newer.
  @Published private(set) var upToDate = false

  /// The bundle carries a feed and a public key; local builds without the key cannot update.
  let supported: Bool
  private var updater: SPUUpdater?
  private lazy var driver = UpdateDriver(store: self)
  private var installRequested = false
  private var expected: UInt64 = 0
  private var received: UInt64 = 0
  private var cancelDownload: (() -> Void)?
  /// Callers of check() waiting for the answer (CLI `corescope version --check`).
  private var waiters: [() -> Void] = []
  private let defaults = UserDefaults.standard

  override init() {
    let info = Bundle.main.infoDictionary ?? [:]
    supported = !((info["SUPublicEDKey"] as? String) ?? "").isEmpty && info["SUFeedURL"] != nil
    super.init()
    lastCheck = defaults.object(forKey: "updateLastCheck") as? Date
    if let saved = defaults.dictionary(forKey: "updateAvailable"), let version = saved["version"] as? String,
      UpdateLogic.isNewer(version, than: AppVersion.short)
    {
      available = Release(
        version: version, build: saved["build"] as? String ?? "", notes: saved["notes"] as? String ?? "",
        date: saved["date"] as? Date)
    } else {
      defaults.removeObject(forKey: "updateAvailable")
    }
  }

  /// Follows the Settings toggle: starts Sparkle's daily schedule, or stops it.
  func apply() {
    let on = Preferences.shared.checkForUpdates
    if on { start() }
    updater?.automaticallyChecksForUpdates = on
  }
  /// Check now (Settings, CLI); runs even with the daily check off, because the user asked.
  func check(then done: (() -> Void)? = nil) {
    if let done { waiters.append(done) }
    guard start(), let updater else { return finish() }
    guard updater.canCheckForUpdates else { return finish() }
    phase = .checking
    updater.checkForUpdates()
  }
  /// Install and relaunch: Sparkle fetches the appcast again, downloads, verifies and installs.
  func install() {
    guard start(), let updater, updater.canCheckForUpdates else { return }
    installRequested = true
    phase = .checking
    updater.checkForUpdates()
  }
  func cancel() {
    cancelDownload?()
    cancelDownload = nil
    installRequested = false
    phase = .idle
  }

  @discardableResult private func start() -> Bool {
    guard supported else {
      phase = .failed(L("Esta cópia não tem a chave de atualização (build local)."))
      return false
    }
    if updater != nil { return true }
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    do {
      try updater.start()
    } catch {
      phase = .failed(error.localizedDescription)
      return false
    }
    updater.sendsSystemProfile = false
    updater.automaticallyDownloadsUpdates = false
    updater.updateCheckInterval = 86400
    updater.automaticallyChecksForUpdates = Preferences.shared.checkForUpdates
    self.updater = updater
    return true
  }
  private func finish() {
    let pending = waiters
    waiters = []
    pending.forEach { $0() }
  }
  private func checked() {
    lastCheck = Date()
    defaults.set(lastCheck, forKey: "updateLastCheck")
  }

  // MARK: Sparkle user driver callbacks (main thread)

  fileprivate func found(_ item: SUAppcastItem, userInitiated: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    checked()
    upToDate = false
    let release = Release(
      version: item.displayVersionString, build: item.versionString, notes: item.itemDescription ?? "",
      date: item.date)
    let isNew = available?.version != release.version
    available = release
    defaults.set(
      ["version": release.version, "build": release.build, "notes": release.notes, "date": release.date ?? Date()],
      forKey: "updateAvailable")
    finish()
    if installRequested {
      installRequested = false
      reply(.install)
      return
    }
    phase = .idle
    // Sparkle reminds again on the next daily check; the card and the footer badge stay.
    reply(.dismiss)
    if !userInitiated && isNew {
      Notifier.shared.updateAvailable(version: release.version)
    }
  }
  fileprivate func notFound() {
    checked()
    upToDate = true
    available = nil
    defaults.removeObject(forKey: "updateAvailable")
    installRequested = false
    phase = .idle
    finish()
  }
  fileprivate func failed(_ error: Error) {
    installRequested = false
    cancelDownload = nil
    phase = .failed(error.localizedDescription)
    finish()
  }
  fileprivate func downloadStarted(cancel: @escaping () -> Void) {
    cancelDownload = cancel
    expected = 0
    received = 0
    phase = .downloading(nil)
  }
  fileprivate func downloadExpected(_ length: UInt64) {
    expected = length
    received = 0
  }
  fileprivate func downloadReceived(_ length: UInt64) {
    received += length
    phase = .downloading(expected > 0 ? min(1, Double(received) / Double(expected)) : nil)
  }
  fileprivate func extracting(_ progress: Double) {
    cancelDownload = nil
    phase = .extracting(progress)
  }
  fileprivate func installing() { phase = .installing }
  fileprivate func dismissed() {
    cancelDownload = nil
    if case .failed = phase { return }
    phase = .idle
  }

  /// What `app.update_status` returns to agents and the CLI.
  func json() -> [String: Any] {
    var out: [String: Any] = [
      "check_for_updates": Preferences.shared.checkForUpdates,
      "current_version": AppVersion.short, "current_build": AppVersion.build,
      "update_available": available != nil, "supported": supported,
      "feed": UserDefaults.standard.string(forKey: "updateFeedURL")
        ?? Bundle.main.infoDictionary?["SUFeedURL"] as? String ?? "",
      "last_check": lastCheck.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
    ]
    switch phase {
    case .idle: out["state"] = upToDate ? "up to date" : "idle"
    case .checking: out["state"] = "checking"
    case .downloading: out["state"] = "downloading"
    case .extracting: out["state"] = "extracting"
    case .installing: out["state"] = "installing"
    case .failed(let message):
      out["state"] = "error"
      out["error"] = message
    }
    if let available {
      out["latest_version"] = available.version
      out["latest_build"] = available.build
      out["release_notes"] = available.notes
      out["install"] = "The user installs it from CoreScope › Settings › Updates (Install and relaunch)."
    }
    return out
  }
}

extension UpdateStore: SPUUpdaterDelegate {
  /// `defaults write local.corescope.app updateFeedURL …` points at a test feed (CONTRIBUTING.md);
  /// its updates still need the release key's signatures.
  func feedURLString(for updater: SPUUpdater) -> String? {
    UserDefaults.standard.string(forKey: "updateFeedURL")
  }
}

/// Sparkle's user interface, drawn by CoreScope: the Settings card, the sidebar badge and one
/// notification, instead of Sparkle's own windows.
private final class UpdateDriver: NSObject, SPUUserDriver {
  unowned let store: UpdateStore
  init(store: UpdateStore) { self.store = store }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: Preferences.shared.checkForUpdates, sendSystemProfile: false))
  }
  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
  func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    store.found(appcastItem, userInitiated: state.userInitiated, reply: reply)
  }
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    store.notFound()
    acknowledgement()
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    store.failed(error)
    acknowledgement()
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) { store.downloadStarted(cancel: cancellation) }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    store.downloadExpected(expectedContentLength)
  }
  func showDownloadDidReceiveData(ofLength length: UInt64) { store.downloadReceived(length) }
  func showDownloadDidStartExtractingUpdate() { store.extracting(0) }
  func showExtractionReceivedProgress(_ progress: Double) { store.extracting(progress) }
  /// The user already chose Install and relaunch; nothing else to confirm.
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    store.installing()
    reply(.install)
  }
  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    store.installing()
  }
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }
  func showUpdateInFocus() { WindowOpener.shared.showMain(page: .settings) }
  func dismissUpdateInstallation() { store.dismissed() }
}

/// Settings › Updates.
struct UpdateSettings: View {
  @ObservedObject var p = Preferences.shared
  @ObservedObject var store = UpdateStore.shared
  var body: some View {
    Section(L("Atualizações")) {
      Toggle(L("Procurar atualizações (uma vez por dia)"), isOn: $p.checkForUpdates)
        .disabled(!store.supported)
      LabeledContent(L("Versão instalada")) {
        HStack(spacing: 8) {
          Text(verbatim: "\(AppVersion.short) (build \(AppVersion.build))").monospacedDigit()
            .foregroundStyle(.secondary)
          if store.phase == .checking {
            ProgressView().controlSize(.small)
          } else {
            Button(L("Procurar agora")) { store.check() }.disabled(!store.supported || busy)
          }
        }
      }
      if let release = store.available {
        UpdateCard(release: release)
      } else if store.upToDate, let last = store.lastCheck {
        Label(L("Você está na versão mais recente · verificado %@", relative(last)), systemImage: "checkmark.circle.fill")
          .font(.caption).foregroundStyle(Tint.brand)
      } else if let last = store.lastCheck {
        Text(L("Última verificação %@", relative(last))).font(.caption).foregroundStyle(.secondary)
      }
      if case .failed(let message) = store.phase {
        Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
      }
      Text(
        L("Desligado por padrão. Ligado, o CoreScope busca no máximo uma vez por dia o appcast da última versão no GitHub (github.com e o servidor de downloads do GitHub), sem identificadores nem dados do Mac. Só instala quando você clica em Instalar e reabrir, e só uma atualização assinada com a chave do projeto (EdDSA). Também: corescope version --check.")
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private var busy: Bool {
    switch store.phase {
    case .idle, .failed: false
    default: true
    }
  }
  private func relative(_ date: Date) -> String {
    date.formatted(.relative(presentation: .named))
  }
}

/// The new version with its CHANGELOG section and the install button.
private struct UpdateCard: View {
  let release: UpdateStore.Release
  @ObservedObject var store = UpdateStore.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(L("CoreScope %@ disponível", release.version), systemImage: "arrow.down.circle.fill")
          .font(.headline).foregroundStyle(Tint.brand)
        Spacer()
        if let date = release.date {
          Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
        }
      }
      if !release.notes.isEmpty {
        ScrollView {
          ReleaseNotesView(markdown: release.notes).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 220)
      }
      HStack(spacing: 8) {
        switch store.phase {
        case .downloading(let progress):
          ProgressView(value: progress ?? 0).frame(maxWidth: 220)
          Text(L("Baixando…")).font(.caption).foregroundStyle(.secondary)
          Button(L("Cancelar")) { store.cancel() }
        case .extracting(let progress):
          ProgressView(value: progress).frame(maxWidth: 220)
          Text(L("Verificando…")).font(.caption).foregroundStyle(.secondary)
        case .installing:
          ProgressView().controlSize(.small)
          Text(L("Instalando e reabrindo…")).font(.caption).foregroundStyle(.secondary)
        case .checking:
          ProgressView().controlSize(.small)
        case .idle, .failed:
          Button(L("Instalar e reabrir")) { store.install() }.buttonStyle(.borderedProminent)
          Button(L("Ver no GitHub")) {
            if let url = URL(string: "https://github.com/Tiagospem/corescope/releases/tag/v\(release.version)") {
              NSWorkspace.shared.open(url)
            }
          }
        }
      }
    }.padding(10).background(Tint.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
  }
}

/// A CHANGELOG section: headings, bullets and paragraphs with inline markdown.
struct ReleaseNotesView: View {
  let markdown: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(NoteBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let text):
          Text(inline(text)).font(.caption.weight(.semibold)).padding(.top, 4)
        case .bullet(let text):
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: "•").foregroundStyle(.secondary)
            Text(inline(text))
          }.font(.caption)
        case .text(let text):
          Text(inline(text)).font(.caption)
        }
      }
    }.textSelection(.enabled)
  }
  private func inline(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// "↑ 0.6.0" (sidebar footer, menu bar popover) while an update is available, else `placeholder`.
struct UpdateBadge<Placeholder: View>: View {
  @ObservedObject var store = UpdateStore.shared
  let action: () -> Void
  @ViewBuilder let placeholder: () -> Placeholder
  var body: some View {
    if let release = store.available {
      Button(action: action) {
        Text(verbatim: "↑ \(release.version)").font(.caption2.weight(.semibold)).monospacedDigit()
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Tint.brand.opacity(0.15), in: Capsule()).foregroundStyle(Tint.brand)
      }.buttonStyle(.plain).help(L("CoreScope %@ disponível", release.version))
        .accessibilityLabel(L("CoreScope %@ disponível", release.version))
    } else {
      placeholder()
    }
  }
}
