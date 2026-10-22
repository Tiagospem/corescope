import CryptoKit
import Foundation

/// `.corescope.yml` as the core parses it.
struct ProjectConfig: Codable, Equatable {
  struct Command: Codable, Equatable {
    var name: String?
    var run: String
    var stop: String?
  }
  struct Profile: Codable, Equatable {
    var commands: [Command]?
    var containers: [String]?
  }
  struct Service: Codable, Equatable {
    var name: String?
    var target: String
    /// Profiles of the file that need it (expected while one is on).
    var profiles: [String]?
    /// A component of the status output.
    var component: String?
    /// An app of `environment.apps`.
    var app: String?
  }
  struct Status: Codable, Equatable {
    var run: String
    var timeout_seconds: Double?
  }
  struct Action: Codable, Equatable {
    var run: String
    var description: String?
    var timeout_minutes: Double?
    var confirm: Bool?
    var preview: String?
    var heavy: Bool?
    /// setup, run, diagnostics, data, stop or other; guessed from the name when absent.
    var kind: String?
  }
  struct Capacity: Codable, Equatable {
    var cpu_below: Double
    var memory: String
    var max_wait_minutes: Double
    var heavy_commands: [HeavyCommand]
    var container_memory_free: Double?
    var max_parallel: Double?
  }
  /// A prefix (runs on the Mac), or `{command, uses, weight, containers}`.
  struct HeavyCommand: Codable, Equatable {
    var command: String
    var uses: [String]?
    var weight: Double?
    var containers: [String]?
    init(from decoder: Decoder) throws {
      if let text = try? decoder.singleValueContainer().decode(String.self) {
        command = text
        return
      }
      let c = try decoder.container(keyedBy: CodingKeys.self)
      command = try c.decode(String.self, forKey: .command)
      uses = try c.decodeIfPresent([String].self, forKey: .uses)
      weight = try c.decodeIfPresent(Double.self, forKey: .weight)
      containers = try c.decodeIfPresent([String].self, forKey: .containers)
    }
    func encode(to encoder: Encoder) throws {
      if uses == nil && weight == nil && (containers ?? []).isEmpty {
        var c = encoder.singleValueContainer()
        try c.encode(command)
        return
      }
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(command, forKey: .command)
      try c.encodeIfPresent(uses, forKey: .uses)
      try c.encodeIfPresent(weight, forKey: .weight)
      if let containers, !containers.isEmpty { try c.encode(containers, forKey: .containers) }
    }
    private enum CodingKeys: String, CodingKey { case command, uses, weight, containers }
  }
  struct Agents: Codable, Equatable {
    var wait_for_capacity: Capacity?
  }
  var name: String?
  var profiles: [String: Profile]?
  var ports: [String: Int]?
  /// An app of the project's environment controller: the modes it comes up in, how it goes
  /// down, containers to watch and its actions.
  struct App: Codable, Equatable {
    var title: String?
    var modes: [String: String]?
    var down: String?
    var containers: [String]?
    var actions: [String: Action]?
  }
  struct Environment: Codable, Equatable {
    var status: Status?
    var apps: [String: App]?
    var actions: [String: Action]?
  }
  var services: [Service]?
  var environment: Environment?
  var logs: [String]?
  var agents: Agents?
}
struct ProjectFile: Codable, Equatable, Identifiable {
  let folder: String
  let file: String
  let config: ProjectConfig?
  let error: String?
  var id: String { file }
  /// The project's display name: `name:` in the file, else the folder name.
  var project: String { config?.name ?? (folder as NSString).lastPathComponent }
}

/// Stable ids for things defined in files, so running state survives edits and restarts.
func stableID(_ key: String) -> UUID {
  var bytes = Array(Insecure.MD5.hash(data: Data(key.utf8)))
  bytes[6] = (bytes[6] & 0x0F) | 0x30
  bytes[8] = (bytes[8] & 0x3F) | 0x80
  return UUID(uuid: (
    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

/// Finds project files in the folders the user works in (agents, editors, terminals, profile
/// folders, Cleanup folders, common project folders) once a minute and on demand.
final class ProjectFileStore: ObservableObject {
  static let shared = ProjectFileStore()
  @Published private(set) var files: [ProjectFile] = []
  @Published private(set) var loading = false
  private let queue = DispatchQueue(label: "app.corescope.projectfiles", qos: .utility)
  private var timer: Timer?

  private init() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    timer?.tolerance = 15
  }
  /// The tree walk (and the process list it needs for agent and editor folders) runs every 10
  /// minutes; in between, the known files and the root folders themselves are re-read.
  private var lastWalk = Date.distantPast
  private var lastRoots: Set<String> = []
  private func tick() {
    let roots = currentRoots()
    if -lastWalk.timeIntervalSinceNow >= 600 || roots != lastRoots {
      refresh()
    } else {
      refresh(quick: Array(Set(files.map(\.folder)).union(roots)))
    }
  }
  private func currentRoots() -> Set<String> {
    let remembered = UserDefaults.standard.stringArray(forKey: "projectFolders") ?? []
    return Set(ProfileStore.shared.profiles.map(\.folder) + Preferences.shared.cleanupRoots + remembered)
  }

  /// Callers that asked while a scan was running: served by one more scan right after it.
  private var waiting: [() -> Void] = []
  private var rerun = false

  func refresh(quick known: [String]? = nil, done: (() -> Void)? = nil) {
    guard !loading else {
      rerun = true
      if let done { waiting.append(done) }
      return
    }
    loading = true
    let roots = currentRoots()
    if known == nil {
      lastWalk = Date()
      lastRoots = roots
    }
    let body: [String: Any] = known.map { ["folders": $0] } ?? ["roots": Array(roots), "auto": true]
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("projects", cost) }
      let request = (try? JSONSerialization.data(withJSONObject: body))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
      var found: [ProjectFile] = []
      if let pointer = request.withCString({ cs_project_configs($0) }) {
        let data = Data(bytes: pointer, count: strlen(pointer))
        cs_free(pointer)
        found = (try? JSONDecoder().decode([ProjectFile].self, from: data)) ?? []
      }
      DispatchQueue.main.async {
        self.loading = false
        if found != self.files {
          self.files = found
          ProfileStore.shared.reloadFileProfiles()
          HealthStore.shared.reloadFileChecks()
          EnvironmentStore.shared.reload()
          ActionStore.shared.reload()
        }
        done?()
        if self.rerun {
          self.rerun = false
          let callers = self.waiting
          self.waiting = []
          self.refresh { callers.forEach { $0() } }
        }
      }
    }
  }

  /// Keeps a project folder in the scan (one an agent wrote a file to, outside the usual places).
  func remember(_ folder: String) {
    var list = UserDefaults.standard.stringArray(forKey: "projectFolders") ?? []
    guard !list.contains(folder) else { return }
    list.append(folder)
    UserDefaults.standard.set(Array(list.suffix(100)), forKey: "projectFolders")
  }
  /// The project file whose folder contains `path` (deepest match).
  func file(containing path: String) -> ProjectFile? {
    files.filter { path == $0.folder || path.hasPrefix($0.folder + "/") }.max { $0.folder.count < $1.folder.count }
  }
}
