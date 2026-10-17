import Foundation
import SwiftUI

/// The `corescope` command bundled in the app, linked into ~/.local/bin on request.
enum CommandLineTool {
  static var bundled: URL? {
    Bundle.main.resourceURL.map { $0.appendingPathComponent("bin/corescope") }
      .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
  }
  static var link: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/corescope")
  }
  /// The link exists and points at this app's copy.
  static var installed: Bool {
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
      return false
    }
    return target == bundled?.path
  }
  /// Creates (or repoints) ~/.local/bin/corescope; never overwrites a regular file.
  static func install() throws {
    guard let bundled else { throw CocoaError(.fileNoSuchFile) }
    let fm = FileManager.default
    try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
      try fm.removeItem(at: link)
    } else if fm.fileExists(atPath: link.path) {
      throw CocoaError(.fileWriteFileExists)
    }
    try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
  }
  static func uninstall() throws {
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
      try FileManager.default.removeItem(at: link)
    }
  }
}

struct CommandLineSettings: View {
  @ViewState private var installed = CommandLineTool.installed
  @ViewState private var error: String?
  var body: some View {
    Section(L("Linha de comando")) {
      LabeledContent(L("Comando corescope")) {
        if installed {
          Label(L("Instalado em ~/.local/bin"), systemImage: "checkmark.circle.fill")
            .foregroundStyle(Tint.brand)
          Button(L("Remover")) { run(CommandLineTool.uninstall) }
        } else {
          Button(L("Instalar")) { run(CommandLineTool.install) }
            .disabled(CommandLineTool.bundled == nil)
        }
      }
      Text(
        L("corescope ports · free-port · kill-port 3000 · agents · orphans · top · kill PID --tree. Todos aceitam --json. Se o terminal não encontrar o comando, adicione ~/.local/bin ao PATH.")
      ).font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
  }
  private func run(_ action: () throws -> Void) {
    do {
      try action()
      error = nil
    } catch { self.error = error.localizedDescription }
    installed = CommandLineTool.installed
  }
}
