import AppKit
import SwiftUI

/// Read-only status script run on a remote host through `ssh … sh -s`: POSIX sh, Linux and macOS.
/// It only reads (uname, loadavg, meminfo/sysctl, df, ps, docker ps) and prints key=value lines.
let machineScript = #"""
echo "os=$(uname -s)"
echo "kernel=$(uname -r)"
echo "host=$(hostname)"
if [ -r /proc/loadavg ]; then read a b c rest < /proc/loadavg; echo "load=$a $b $c"; else echo "load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"; fi
echo "cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
if [ -r /proc/uptime ]; then read u rest < /proc/uptime; echo "uptime=${u%.*}"; else b=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\).*/\1/'); [ -n "$b" ] && echo "uptime=$(( $(date +%s) - b ))"; fi
if [ -r /proc/meminfo ]; then awk '/^MemTotal:/{printf "memtotal=%.0f\n", $2*1024} /^MemAvailable:/{printf "memavail=%.0f\n", $2*1024}' /proc/meminfo
else echo "memtotal=$(sysctl -n hw.memsize 2>/dev/null)"; vm_stat 2>/dev/null | awk '/page size of/{ps=$8} /Pages free/{f=$3} /Pages inactive/{i=$3} /Pages speculative/{s=$3} END{if(ps)printf "memavail=%.0f\n", (f+i+s)*ps}'; fi
df -kP / 2>/dev/null | awk 'NR==2{printf "disktotal=%.0f\ndiskused=%.0f\n", $2*1024, $3*1024}'
ps -eo pcpu=,pmem=,comm= 2>/dev/null | sort -rn | head -5 | while read c m n; do echo "proc=$c|$m|$n"; done
if command -v docker >/dev/null 2>&1; then t=""; command -v timeout >/dev/null 2>&1 && t="timeout 3"; n=$($t docker ps -q 2>/dev/null | wc -l | tr -d ' ') && echo "containers=$n"; fi
exit 0
"""#

struct MachineState {
  var stats: RemoteStats?
  var error: String?
  var at: Date
  var latency: Double
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
  private let queue = DispatchQueue(label: "app.corescope.machines", qos: .userInitiated, attributes: .concurrent)

  private init() { hosts = UserDefaults.standard.stringArray(forKey: "sshHosts") ?? [] }

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
      let started = Date()
      let (code, output, errors) = Self.ssh(host)
      let stats = RemoteStats(parsing: output)
      let error: String? =
        stats.valid ? nil : Self.explain(code: code, stderr: errors)
      DispatchQueue.main.async {
        self.probing.remove(host)
        guard self.hosts.contains(host) else { return }
        self.states[host] = MachineState(
          stats: stats.valid ? stats : self.states[host]?.stats, error: error, at: Date(),
          latency: Date().timeIntervalSince(started))
      }
    }
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
            [s.map { "\($0.os) \($0.kernel)" }, s?.uptime.map { L("no ar há %@", formatDuration($0)) },
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
      if let s {
        HStack(spacing: 16) {
          if let total = s.memoryTotal, let available = s.memoryAvailable, total > 0 {
            meter(L("Memória"), used: total - available, total: total)
          }
          if let total = s.diskTotal, let used = s.diskUsed, total > 0 {
            meter(L("Disco /"), used: used, total: total)
          }
          if s.cpus > 0, let load = s.load.first {
            meter(L("Carga / núcleos"), fraction: load / Double(s.cpus), label: String(format: "%.2f / %d", load, s.cpus))
          }
        }
        if !s.processes.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(s.processes.enumerated()), id: \.offset) { _, p in
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
  }
  private var tint: Color { state?.error != nil ? .orange : state?.stats != nil ? Tint.brand : .secondary }
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
