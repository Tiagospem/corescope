import AppKit
import SQLite3
import SwiftUI

/// A Codex desktop thread. The desktop runs every thread inside one backend process, so threads
/// come from Codex's own local databases (read-only), not from the process list.
struct CodexThread: Identifiable, Equatable {
  let id: String
  let title: String
  let cwd: String?
  let updated: Date
  /// A turn is in progress right now.
  let running: Bool
  var project: String? { cwd.flatMap { projectName($0) } }
  /// Opens the thread in the Codex app.
  var url: URL? { URL(string: "codex://threads/\(id)") }
}

enum CodexThreads {
  private static let home = FileManager.default.homeDirectoryForCurrentUser.path
  /// Work threads (not plain ChatGPT chats) that are running or were active in the last hour.
  static func read(activeWithin: TimeInterval = 3600) -> [CodexThread] {
    let running = runningThreadIDs()
    let now = Date().timeIntervalSince1970
    var out: [CodexThread] = []
    query(
      "\(home)/.codex/sqlite/codex-dev.db",
      """
      SELECT thread_id, display_title, cwd, source_updated_at FROM local_thread_catalog
      WHERE source_kind != 'chatgpt' AND source_updated_at > ?1
      ORDER BY source_updated_at DESC LIMIT 40
      """, bind: now - 86400
    ) { row in
      let id = text(row, 0) ?? ""
      let updated = sqlite3_column_double(row, 3)
      guard !id.isEmpty, running.contains(id) || now - updated <= activeWithin else { return }
      var cwd = text(row, 2)
      if Demo.enabled { cwd = cwd.map { Demo.path($0) } }
      let title = Demo.enabled ? Demo.sessionTitle(Int32(truncatingIfNeeded: id.utf8.reduce(0) { $0 &+ Int($1) })) : (text(row, 1) ?? "Codex")
      out.append(
        CodexThread(
          id: id, title: title, cwd: cwd, updated: Date(timeIntervalSince1970: updated),
          running: running.contains(id)))
    }
    // Running first, then most recent; stable between refreshes.
    return out.sorted { ($0.running ? 1 : 0, $0.updated) > ($1.running ? 1 : 0, $1.updated) }
  }
  /// Threads with a turn in progress, started in the last 6 hours (older ones are stale).
  private static func runningThreadIDs() -> Set<String> {
    var ids = Set<String>()
    query(
      "\(home)/.codex/thread_history_1.sqlite",
      "SELECT DISTINCT thread_id FROM thread_turns WHERE status = 'inProgress' AND started_at > ?1",
      bind: Date().timeIntervalSince1970 - 6 * 3600
    ) { row in
      if let id = text(row, 0) { ids.insert(id) }
    }
    return ids
  }
  private static func query(_ path: String, _ sql: String, bind: Double, row: (OpaquePointer) -> Void) {
    guard FileManager.default.fileExists(atPath: path) else { return }
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      sqlite3_close(db)
      return
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 200)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, bind)
    while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
  }
  private static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(row, column).map { String(cString: $0) }
  }
}

/// A Codex desktop thread on the Agents page: no process of its own, so no ✕ — open it in
/// Codex instead.
struct CodexThreadCard: View {
  let thread: CodexThread
  var body: some View {
    Card {
      HStack(spacing: 10) {
        Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Tint.netIn)
          .frame(width: 28, height: 28)
          .background(Tint.netIn.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(thread.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Badge(
              text: thread.running ? L("Trabalhando") : L("Ociosa"),
              color: thread.running ? Tint.brand : .secondary,
              symbol: thread.running ? "bolt.fill" : "moon.fill")
            Badge(text: "Desktop", color: Tint.netIn)
          }
          Text(
            ["Codex", thread.project, L("ativo %@", thread.updated.formatted(.relative(presentation: .named)))]
              .compactMap { $0 }.joined(separator: " · ")
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
      }
      HStack(spacing: 8) {
        Text(L("Roda dentro do app do Codex")).font(.callout).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        ViewThatFits(in: .horizontal) {
          actions(labels: true)
          actions(labels: false)
        }
      }
      .buttonStyle(.bordered).controlSize(.small)
    }
  }
  private func actions(labels: Bool) -> some View {
    HStack(spacing: 8) {
      if let url = thread.url {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          if labels {
            Label(L("Abrir no Codex"), systemImage: "arrow.up.forward.app")
          } else {
            Image(systemName: "arrow.up.forward.app")
          }
        }.help(L("Abre esta conversa no app do Codex"))
      }
      if let cwd = thread.cwd, !cwd.isEmpty {
        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        } label: {
          if labels { Label("Finder", systemImage: "folder") } else { Image(systemName: "folder") }
        }.help(L("Abrir no Finder"))
        Button {
          openTerminal(at: cwd)
        } label: {
          if labels { Label("Terminal", systemImage: "terminal") } else { Image(systemName: "terminal") }
        }.help(L("Abrir Terminal aqui"))
      }
    }.fixedSize()
  }
}
