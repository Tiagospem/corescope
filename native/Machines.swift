import AppKit
import SwiftUI

/// Read-only status script run on a remote host through `ssh … sh -s`: POSIX sh, Linux and macOS.
/// It only reads (uname, loadavg, meminfo/sysctl, df, ps, docker ps) and prints key=value lines.
let machineScript = #"""
echo "os=$(uname -s)"
echo "kernel=$(uname -r)"
echo "host=$(hostname)"
[ -r /etc/os-release ] && . /etc/os-release 2>/dev/null && echo "osname=$PRETTY_NAME"
[ "$(uname -s)" = Darwin ] && echo "osname=macOS $(sw_vers -productVersion 2>/dev/null)"
if [ -r /proc/loadavg ]; then read a b c rest < /proc/loadavg; echo "load=$a $b $c"; else echo "load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"; fi
echo "cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
if [ -r /proc/uptime ]; then read u rest < /proc/uptime; echo "uptime=${u%.*}"; else b=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\).*/\1/'); [ -n "$b" ] && echo "uptime=$(( $(date +%s) - b ))"; fi
if [ -r /proc/meminfo ]; then awk '/^MemTotal:/{printf "memtotal=%.0f\n", $2*1024} /^MemAvailable:/{printf "memavail=%.0f\n", $2*1024} /^SwapTotal:/{printf "swaptotal=%.0f\n", $2*1024} /^SwapFree:/{printf "swapfree=%.0f\n", $2*1024}' /proc/meminfo
else echo "memtotal=$(sysctl -n hw.memsize 2>/dev/null)"; vm_stat 2>/dev/null | awk '/page size of/{ps=$8} /Pages free/{f=$3} /Pages inactive/{i=$3} /Pages speculative/{s=$3} END{if(ps)printf "memavail=%.0f\n", (f+i+s)*ps}'; fi
df -kP / 2>/dev/null | awk 'NR==2{printf "disktotal=%.0f\ndiskused=%.0f\n", $2*1024, $3*1024}'
df -kP 2>/dev/null | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|overlay|shm|udev|none|map|devfs)/ {m=$6; for(i=7;i<=NF;i++) m=m" "$i; if (m ~ /^\/(dev|proc|sys|run|snap|etc|System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware))/) next; printf "disk=%s|%.0f|%.0f\n", m, $2*1024, $3*1024}' | head -8
ps -eo pcpu=,pmem=,comm= 2>/dev/null | sort -rn | head -5 | while read c m n; do echo "proc=$c|$m|$n"; done
ps -eo pmem=,pcpu=,comm= 2>/dev/null | sort -rn | head -5 | while read m c n; do echo "mproc=$c|$m|$n"; done
if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-legend --plain 2>/dev/null | awk '{print "failed=" $1}' | head -10; fi
if command -v docker >/dev/null 2>&1; then t=""; command -v timeout >/dev/null 2>&1 && t="timeout 4"
  n=$($t docker ps -q 2>/dev/null | wc -l | tr -d ' ') && echo "containers=$n"
  $t docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null | head -30 | sed 's/^/container=/'; fi
exit 0
"""#

struct MachineState {
  var stats: RemoteStats?
  var error: String?
  var at: Date
  var latency: Double
  var alerts: [MachineAlert] = []
}

/// A command run on a machine on demand. Built-in ones only read; your own are yours. Agents can
/// run recipes by name, never free-form commands.
struct Recipe: Codable, Hashable, Identifiable {
  let name: String
  let command: String
  var id: String { name }
  static let builtins: [Recipe] = [
    Recipe(name: "journal", command: "journalctl -n 80 --no-pager 2>/dev/null || tail -n 80 /var/log/syslog 2>/dev/null || tail -n 80 /var/log/messages"),
    Recipe(name: "failed-units", command: "systemctl --failed --no-pager"),
    Recipe(name: "disk", command: "df -h"),
    Recipe(name: "memory", command: "free -m 2>/dev/null || vm_stat"),
    Recipe(name: "containers", command: "docker ps -a --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"),
    Recipe(name: "top", command: "ps aux --sort=-%cpu 2>/dev/null | head -20 || ps aux -r | head -20"),
    Recipe(name: "listening", command: "ss -ltn 2>/dev/null || netstat -an | grep LISTEN"),
    Recipe(name: "nginx-errors", command: "tail -n 60 /var/log/nginx/error.log"),
  ]
}
extension MachineAlert {
  var text: String {
    switch self {
    case .disk(let mount, let percent): L("Disco %@ em %@%%", mount, "\(percent)")
    case .load(let load, let cores): L("Carga %@ em %@ núcleos", String(format: "%.1f", load), "\(cores)")
    case .failedUnits(let units): L("Serviços do systemd com falha: %@", units.prefix(3).joined(separator: ", "))
    case .containerStopped(let name, let status): L("Contêiner %@ parou (%@)", name, status)
    case .containerUnhealthy(let name): L("Contêiner %@ com falha no health check", name)
    }
  }
}

/// Machines the user listed, probed through their own `ssh` in BatchMode: keys and agent stay
/// with ssh, CoreScope never prompts for or reads credentials, and an unknown host key fails
/// instead of being accepted.
final class MachineStore: ObservableObject {
  static let shared = MachineStore()
  @Published var hosts: [String] {
    didSet {
      UserDefaults.standard.set(hosts, forKey: "sshHosts")
      states = states.filter { hosts.contains($0.key) }
    }
  }
  @Published private(set) var states: [String: MachineState] = [:]
  @Published private(set) var probing = Set<String>()
  /// Your own recipes per machine (built-ins are always there).
  @Published var customRecipes: [String: [Recipe]] {
    didSet {
      if let data = try? JSONEncoder().encode(customRecipes) { UserDefaults.standard.set(data, forKey: "sshRecipes") }
    }
  }
  /// Alerts already notified, so each one alerts once until it clears.
  private var notified: [String: Set<String>] = [:]
  private let queue = DispatchQueue(label: "app.corescope.machines", qos: .userInitiated, attributes: .concurrent)

  private init() {
    hosts = UserDefaults.standard.stringArray(forKey: "sshHosts") ?? []
    customRecipes = UserDefaults.standard.data(forKey: "sshRecipes")
      .flatMap { try? JSONDecoder().decode([String: [Recipe]].self, from: $0) } ?? [:]
  }
  func recipes(_ host: String) -> [Recipe] { Recipe.builtins + (customRecipes[host] ?? []) }

  /// Aliases from ~/.ssh/config (Host lines only) that are not listed yet.
  var suggestions: [String] {
    let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
    let config = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return sshConfigHosts(config).filter { !hosts.contains($0) && validSSHDestination($0) }
  }

  func refreshAll() { hosts.forEach(refresh) }
  func refresh(_ host: String) {
    guard validSSHDestination(host), !probing.contains(host) else { return }
    probing.insert(host)
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("machines", cost) }
      let started = Date()
      let (code, output, errors) = Self.ssh(host)
      let stats = RemoteStats(parsing: output)
      let error: String? =
        stats.valid ? nil : Self.explain(code: code, stderr: errors)
      DispatchQueue.main.async {
        self.probing.remove(host)
        guard self.hosts.contains(host) else { return }
        let previous = self.states[host]?.stats
        let alerts = stats.valid ? machineAlerts(stats, before: previous) : self.states[host]?.alerts ?? []
        self.states[host] = MachineState(
          stats: stats.valid ? stats : previous, error: error, at: Date(),
          latency: Date().timeIntervalSince(started), alerts: alerts)
        self.notify(host, alerts)
      }
    }
  }
  private func notify(_ host: String, _ alerts: [MachineAlert]) {
    let texts = Set(alerts.map(\.text))
    let fresh = texts.subtracting(notified[host] ?? [])
    notified[host] = texts
    guard Preferences.shared.notifyMachines, !fresh.isEmpty else { return }
    Notifier.shared.serviceChanged(key: "machine.\(host)", title: L("%@ precisa de atenção", host), body: fresh.sorted().joined(separator: "\n"))
  }

  /// Runs a recipe (by name) on a machine: (output, error). Blocking; call off the main thread.
  func run(_ recipe: Recipe, on host: String) -> (String, String?) {
    guard validSSHDestination(host) else { return ("", L("Destino inválido")) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=2", "-T", host, recipe.command,
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return ("", error.localizedDescription) }
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    var data = Data()
    let reader = DispatchQueue(label: "app.corescope.recipe")
    reader.async {
      while true {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        if data.count < 128 * 1024 { data.append(chunk) }
      }
    }
    if done.wait(timeout: .now() + 30) == .timedOut {
      process.terminate()
      return (String(decoding: data, as: UTF8.self), L("Sem resposta em 30 s"))
    }
    reader.sync {}
    let text = String(decoding: data.prefix(128 * 1024), as: UTF8.self)
    return (text, process.terminationStatus == 0 ? nil : L("Saiu com %@", "\(process.terminationStatus)"))
  }

  private static func explain(code: Int32, stderr: String) -> String {
    let e = stderr.lowercased()
    if code == -2 { return L("Sem resposta em 15 s") }
    if e.contains("host key verification failed") || e.contains("no matching host key") {
      return L("Chave do host desconhecida: conecte uma vez pelo Terminal para confirmá-la")
    }
    if e.contains("permission denied") { return L("Acesso negado: o ssh precisa de uma chave (o CoreScope não usa senhas)") }
    if e.contains("could not resolve") { return L("Host não encontrado") }
    if e.contains("connection refused") { return L("Conexão recusada") }
    if e.contains("timed out") { return L("Sem resposta") }
    let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    return last.isEmpty ? L("Falhou (código %@)", "\(code)") : String(last.prefix(160))
  }
  /// (exit code or -2 on timeout, stdout, stderr). Never interactive.
  private static func ssh(_ host: String) -> (Int32, String, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=1", "-T", host, "sh -s",
    ]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch { return (-1, "", error.localizedDescription) }
    input.fileHandleForWriting.write(Data((machineScript + "\n").utf8))
    try? input.fileHandleForWriting.close()
    let deadline = DispatchTime.now() + 15
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    var timedOut = false
    if done.wait(timeout: deadline) == .timedOut {
      timedOut = true
      process.terminate()
    }
    let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile().prefix(64 * 1024), as: UTF8.self)
    let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(8 * 1024), as: UTF8.self)
    return (timedOut ? -2 : process.terminationStatus, out, err)
  }
}

struct MachinesView: View {
  @ObservedObject var store = MachineStore.shared
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var draft = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Card {
          CardHeader(title: L("Adicionar máquina"), symbol: "plus.circle")
          HStack(spacing: 8) {
            TextField(L("Alias do ~/.ssh/config ou usuario@host"), text: $draft).textFieldStyle(.roundedBorder)
              .onSubmit(add)
            Button(L("Adicionar"), action: add).disabled(!validSSHDestination(draft.trimmingCharacters(in: .whitespaces)))
          }
          let suggestions = store.suggestions
          if !suggestions.isEmpty {
            HStack(spacing: 6) {
              Text(L("Do seu ~/.ssh/config:")).font(.caption).foregroundStyle(.secondary)
              ForEach(suggestions.prefix(8), id: \.self) { host in
                Button(host) {
                  store.hosts.append(host)
                  store.refresh(host)
                }.controlSize(.small)
              }
            }
          }
        }
        if store.hosts.isEmpty {
          Card { EmptyNote(text: L("Nenhuma máquina. Adicione servidores que você acessa por ssh com chave para ver carga, memória, disco e processos.")) }
        }
        ForEach(store.hosts, id: \.self) { host in
          MachineCard(host: host, state: store.states[host], probing: store.probing.contains(host)) {
            store.refresh(host)
          } remove: {
            store.hosts.removeAll { $0 == host }
          }
        }
        Toggle(L("Notificar quando uma máquina precisar de atenção"), isOn: $prefs.notifyMachines)
          .onChange(of: prefs.notifyMachines) { _, on in if on { Notifier.shared.activate() } }
        Text(
          L("Usa o seu próprio ssh em BatchMode: chaves e agente ficam com o ssh, nada pede senha e um host com chave desconhecida falha em vez de ser aceito. O comando remoto só lê (uname, carga, memória, df, ps, docker ps). Atualiza a cada 60 s enquanto esta página está aberta.")
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
    .task {
      while !Task.isCancelled {
        store.refreshAll()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
      }
    }
  }
  private func add() {
    let host = draft.trimmingCharacters(in: .whitespaces)
    guard validSSHDestination(host) else { return }
    if !store.hosts.contains(host) { store.hosts.append(host) }
    store.refresh(host)
    draft = ""
  }
}

private struct MachineCard: View {
  let host: String
  let state: MachineState?
  let probing: Bool
  let refresh: () -> Void
  let remove: () -> Void
  @ViewState private var recipesOpen = false
  @ViewState private var tab = 0
  var body: some View {
    let s = state?.stats
    Card {
      HStack(spacing: 10) {
        Image(systemName: "server.rack").font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
          .frame(width: 28, height: 28)
          .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(host).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let s, s.host != host, !s.host.isEmpty { Text(s.host).font(.caption).foregroundStyle(.secondary) }
          }
          Text(
            [s.map { $0.osName.isEmpty ? "\($0.os) \($0.kernel)" : $0.osName }, s?.uptime.map { L("no ar há %@", formatDuration($0)) },
             state.map { L("lido %@ (%@ s)", $0.at.formatted(date: .omitted, time: .standard), String(format: "%.1f", $0.latency)) }]
              .compactMap { $0 }.joined(separator: " · ")
          ).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
        if let s, let load = s.load.first {
          stat(L("Carga"), String(format: "%.2f", load), help: L("Média de 1 min; %@ núcleos", "\(s.cpus)"))
        }
        if let containers = s?.containers { stat(L("Contêineres"), "\(containers)") }
        if probing { ProgressView().controlSize(.small) }
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
          .help(L("Atualizar")).disabled(probing)
        Button {
          recipesOpen = true
        } label: {
          Label(L("Receitas"), systemImage: "list.bullet.rectangle")
        }.controlSize(.small).help(L("Comandos de leitura que rodam sob demanda (journal, df, contêineres…)"))
        Menu {
          Button(L("Abrir no Terminal")) { openSSH() }
          Button(L("Remover"), role: .destructive, action: remove)
        } label: {
          Image(systemName: "ellipsis.circle")
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      }
      if let error = state?.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
      }
      ForEach(Array((state?.alerts ?? []).enumerated()), id: \.offset) { _, alert in
        Label(alert.text, systemImage: "exclamationmark.octagon.fill").font(.callout).foregroundStyle(.red)
      }
      if let s {
        HStack(spacing: 16) {
          if let total = s.memoryTotal, let available = s.memoryAvailable, total > 0 {
            meter(L("Memória"), used: total - available, total: total)
          }
          if let total = s.diskTotal, let used = s.diskUsed, total > 0 {
            meter(L("Disco /"), used: used, total: total)
          }
          if let total = s.swapTotal, let free = s.swapFree, total > 0 {
            meter(L("Swap"), used: total - free, total: total)
          }
          if s.cpus > 0, let load = s.load.first {
            meter(L("Carga / núcleos"), fraction: load / Double(s.cpus), label: String(format: "%.2f / %d", load, s.cpus))
          }
        }
        Picker("", selection: $tab) {
          Text(L("CPU")).tag(0)
          Text(L("Memória")).tag(1)
          Text(L("Discos")).tag(2)
          Text(L("Contêineres")).tag(3)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
        if tab == 2 {
          ForEach(Array(s.disks.enumerated()), id: \.offset) { _, d in
            meter(d.mount, used: d.used, total: d.total)
          }
          if s.disks.isEmpty { EmptyNote(text: L("Sem discos além do /.")) }
        } else if tab == 3 {
          ForEach(Array(s.containerList.enumerated()), id: \.offset) { _, c in
            HStack(spacing: 8) {
              Circle().fill(c.state == "running" ? (c.status.contains("unhealthy") ? .orange : Tint.brand) : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
              Text(c.name).font(.callout).lineLimit(1)
              Spacer()
              Text(c.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          if s.containerList.isEmpty { EmptyNote(text: L("Nenhum contêiner (ou Docker indisponível).")) }
        }
        if tab < 2, !(tab == 0 ? s.processes : s.memoryProcesses).isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((tab == 0 ? s.processes : s.memoryProcesses).enumerated()), id: \.offset) { _, p in
              HStack(spacing: 8) {
                Text(p.name).font(.callout).lineLimit(1)
                Spacer()
                Text(String(format: "%.1f%% CPU", p.cpu)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text(String(format: "%.1f%% mem", p.memory)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                  .frame(width: 72, alignment: .trailing)
              }
            }
          }
        }
      }
    }
    .sheet(isPresented: $recipesOpen) { RecipesSheet(host: host) }
  }
  private var tint: Color {
    if !(state?.alerts.isEmpty ?? true) { return .red }
    return state?.error != nil ? .orange : state?.stats != nil ? Tint.brand : .secondary
  }
  private func stat(_ label: String, _ value: String, help: String = "") -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }.frame(minWidth: 60, alignment: .trailing).help(help)
  }
  private func meter(_ title: String, used: Double, total: Double) -> some View {
    meter(title, fraction: used / total, label: "\(formatBytes(used)) / \(formatBytes(total))")
  }
  private func meter(_ title: String, fraction: Double, label: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.caption.weight(.semibold))
        Spacer()
        Text(label).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      MeterBar(fraction: min(1, fraction), color: fraction > 0.9 ? .red : fraction > 0.75 ? .orange : Tint.brand)
        .frame(height: 6)
    }.frame(maxWidth: .infinity)
  }
  /// `ssh://host` opens a Terminal session (the system's handler); the destination was validated.
  private func openSSH() {
    if let url = URL(string: "ssh://\(host)") { NSWorkspace.shared.open(url) }
  }

}

/// Recipes for one machine: run on demand, output shown; add your own.
private struct RecipesSheet: View {
  let host: String
  @ObservedObject var store = MachineStore.shared
  @Environment(\.dismiss) private var dismiss
  @ViewState private var running: String?
  @ViewState private var output = ""
  @ViewState private var failure: String?
  @ViewState private var newName = ""
  @ViewState private var newCommand = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L("Receitas · %@", host)).font(.title3.weight(.semibold))
        Spacer()
        Button(L("Fechar")) { dismiss() }.keyboardShortcut(.cancelAction)
      }
      HStack(alignment: .top, spacing: 12) {
        List(store.recipes(host)) { r in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(r.name).font(.callout.weight(.medium))
              Text(r.command).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if running == r.name { ProgressView().controlSize(.small) }
            Button(L("Rodar")) { run(r) }.controlSize(.small).disabled(running != nil)
            if !Recipe.builtins.contains(r) {
              Button {
                store.customRecipes[host]?.removeAll { $0 == r }
              } label: {
                Image(systemName: "minus.circle")
              }.buttonStyle(.borderless)
            }
          }
        }.frame(width: 300)
        VStack(alignment: .leading, spacing: 6) {
          if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
          ScrollView {
            Text(output.isEmpty ? L("Escolha uma receita.") : output)
              .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
      }
      HStack {
        TextField(L("Nome"), text: $newName).textFieldStyle(.roundedBorder).frame(width: 140)
        TextField(L("Comando, ex.: tail -n 100 /var/www/app/storage/logs/laravel.log"), text: $newCommand)
          .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
        Button(L("Adicionar")) {
          let name = newName.trimmingCharacters(in: .whitespaces)
          let command = newCommand.trimmingCharacters(in: .whitespaces)
          guard !name.isEmpty, !command.isEmpty, !store.recipes(host).contains(where: { $0.name == name }) else { return }
          store.customRecipes[host, default: []].append(Recipe(name: name, command: command))
          newName = ""
          newCommand = ""
        }
      }
      Text(
        L("Rodam pelo seu ssh em BatchMode. As receitas prontas só leem; as suas são comandos seus — prefira comandos de leitura. Agentes podem rodar receitas pelo nome (MCP run_recipe), nunca comandos livres.")
      ).font(.caption).foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(width: 860, height: 560)
  }
  private func run(_ r: Recipe) {
    running = r.name
    failure = nil
    DispatchQueue.global(qos: .userInitiated).async {
      let (out, error) = MachineStore.shared.run(r, on: host)
      DispatchQueue.main.async {
        running = nil
        output = out
        failure = error
      }
    }
  }
}
