import AppKit
import SwiftUI

/// Big-number resource card with a right-aligned history chart.
struct ResourceCard: View {
  let title: String
  let symbol: String
  let value: String
  var unit: String = ""
  let detail: String
  let series: [ChartSeries]
  var ceiling: Double? = nil
  var fraction: Double? = nil
  var legend: [(String, Color)] = []
  var help: String = ""
  var body: some View {
    Card {
      HStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
          .foregroundStyle(series.first?.color ?? .secondary).accessibilityHidden(true)
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        Spacer()
        ForEach(legend, id: \.0) { item in
          HStack(spacing: 3) {
            Circle().fill(item.1).frame(width: 6, height: 6)
            Text(L(item.0)).font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
      }
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.7)
        if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
      }
      // Every card reserves the meter row so the grid stays aligned.
      if let fraction, let color = series.first?.color {
        MeterBar(fraction: fraction, color: color)
      } else {
        Color.clear.frame(height: 4)
      }
      AreaChart(series: series, ceiling: ceiling, title: title).frame(height: 54)
      Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }.help(help)
    .accessibilityElement(children: .combine)
  }
}

struct OverviewView: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    ScrollView {
      if let s = monitor.snapshot {
        VStack(alignment: .leading, spacing: 16) {
          let alerts = s.diagnostics.filter { $0.level > 0 }
          if !alerts.isEmpty { AlertStrip(alerts: alerts) }
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 12), count: 4),
            alignment: .leading, spacing: 12
          ) {
            ResourceCard(
              title: L("CPU"), symbol: "cpu",
              value: s.cpu.value.map { String(format: "%.0f", $0) } ?? "—", unit: "%",
              detail: L("%@ núcleos · térmico %@", "\(s.cores)", "\(s.thermalLabel.lowercased())"),
              series: [.cpu(s.history.map(\.cpu))], ceiling: 100,
              help: s.cpu.explanation)
            ResourceCard(
              title: L("Memória"), symbol: "memorychip", value: s.memorySummary,
              detail: L("de %@ · swap %@", "\(s.physical.bytes)", "\(s.swap.bytes)"),
              series: [.memory(s.history.map(\.memory))],
              ceiling: s.physical.value, fraction: s.memoryFraction,
              help: L(
                "Ativa + wired + compressor (%@). Pressão de memória: %@.", s.compressed.bytes,
                s.pressureLabel.lowercased()))
            ResourceCard(
              title: L("Disco"), symbol: "internaldrive", value: s.diskRate,
              detail: "↓ \(s.disk_read.rate)  ↑ \(s.disk_write.rate)",
              series: [
                .diskRead(s.history.map(\.disk_read)),
                .diskWrite(s.history.map(\.disk_write)),
              ], legend: [("leitura", Tint.diskRead), ("escrita", Tint.diskWrite)],
              help: s.disk_read.explanation)
            ResourceCard(
              title: L("Rede"), symbol: "arrow.up.arrow.down",
              value: formatRate((s.net_in.value ?? 0) + (s.net_out.value ?? 0)),
              detail: "↓ \(s.net_in.rate)  ↑ \(s.net_out.rate)",
              series: [
                .netIn(s.history.map(\.net_in)),
                .netOut(s.history.map(\.net_out)),
              ], legend: [("entrada", Tint.netIn), ("saída", Tint.netOut)],
              help: s.net_in.explanation)
          }
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2),
            alignment: .leading, spacing: 12
          ) {
            CoresCard(snapshot: s)
            MemoryBreakdownCard(snapshot: s)
          }
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2),
            alignment: .leading, spacing: 12
          ) {
            ServersCard(groups: s.serverGroups)
            OrphansCard(orphans: s.orphans)
          }
          AuditCard()
          if Preferences.shared.limitsInOverview { LimitsCard() }
          AgentSessionsCard(snapshot: s)
          HealthCard()
          ContainersCard()
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2),
            alignment: .leading, spacing: 12
          ) {
            TopCard(
              title: "Maior CPU", symbol: "flame", tint: Tint.cpu,
              items: Array(s.processes.prefix(6)), value: { $0.cpu.percent })
            TopCard(
              title: "Maior memória", symbol: "memorychip", tint: Tint.memory,
              items: Array(s.processes.sorted { $0.memoryValue > $1.memoryValue }.prefix(6)),
              value: { $0.memory.bytes })
          }
        }.padding(20)
      } else {
        ProgressView(L("Lendo métricas do macOS…")).frame(maxWidth: .infinity, minHeight: 320)
      }
    }
  }
}

/// Busy % per logical CPU, grouped by performance (P) and efficiency (E) cores: one tile per core
/// that fills up and warms from green to orange with load, the percentage written inside.
private struct CoresCard: View {
  let snapshot: Snapshot
  var body: some View {
    let cores = Array(snapshot.core_load.enumerated())
    let groups: [CoreGroup] =
      cores.contains { $0.element.kind.isEmpty }
      ? [CoreGroup(kind: "", cores: cores)]
      : [CoreGroup(kind: "P", cores: cores.filter { $0.element.kind == "P" }),
        CoreGroup(kind: "E", cores: cores.filter { $0.element.kind == "E" })].filter { !$0.cores.isEmpty }
    Card {
      CardHeader(title: L("CPU por núcleo"), symbol: "cpu", tint: Tint.cpu) {
        Text(L("%@ núcleos", "\(cores.count)")).font(.caption).foregroundStyle(.secondary)
      }
      if cores.isEmpty {
        EmptyNote(text: L("Contadores por núcleo temporariamente indisponíveis."))
      }
      // One column grid for every group, so P and E tiles line up and fill the card.
      let columns = min(8, max(1, groups.map(\.cores.count).max() ?? 1))
      ForEach(groups, id: \.kind) { group in CoreGroupView(group: group, columns: columns) }
      CoreLegend()
        .help(
          L(snapshot.core_source) + "\n"
            + L("Ticks por CPU lógica via host_processor_info; o tipo de cada núcleo vem do IODeviceTree e é conferido com sysctl hw.perflevel0/1."))
    }
  }
}

private struct CoreGroup {
  let kind: String
  let cores: [(offset: Int, element: CoreLoad)]
  var average: Double? {
    let values = cores.compactMap(\.element.value)
    return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }
  var title: String {
    switch kind {
    case "P": L("Desempenho")
    case "E": L("Eficiência")
    default: L("Núcleos")
    }
  }
  var symbol: String {
    switch kind {
    case "P": "bolt.fill"
    case "E": "leaf.fill"
    default: "cpu"
    }
  }
  var subtitle: String? {
    switch kind {
    case "P": L("Rápidos: builds, testes e o app em uso")
    case "E": L("Econômicos: tarefas leves e em segundo plano")
    default: nil
    }
  }
}

/// Green while calm, yellow when busy, orange near the limit; the same scale as the legend.
private func coreHeat(_ value: Double) -> Color {
  value >= 85 ? Tint.warning : value >= 50 ? coreBusy : Tint.cpu
}
private let coreBusy = Color(red: 0.98, green: 0.78, blue: 0.24)

private struct CoreGroupView: View {
  let group: CoreGroup
  let columns: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 9) {
        Image(systemName: group.symbol).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(group.kind == "E" ? Tint.cpu.opacity(0.75) : Tint.cpu)
          .frame(width: 26, height: 26)
          .background(Tint.cpu.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(L("%@ · %@", group.title, "\(group.cores.count)")).font(.callout.weight(.semibold))
          if let subtitle = group.subtitle {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 6)
        VStack(alignment: .trailing, spacing: 0) {
          Text(group.average.map { String(format: "%.0f%%", $0) } ?? "—")
            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
          HStack(spacing: 4) {
            Circle().fill(group.average.map(coreHeat) ?? .secondary).frame(width: 6, height: 6)
            Text(L("média")).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
        ForEach(group.cores, id: \.offset) { index, core in CoreTile(index: index, core: core) }
      }
    }
  }
}

private struct CoreTile: View {
  let index: Int
  let core: CoreLoad
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let value = min(100, max(0, core.value ?? 0))
    let color = coreHeat(value)
    ZStack(alignment: .bottom) {
      RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
      GeometryReader { g in
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          LinearGradient(colors: [color.opacity(0.55), color.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            .frame(height: core.value == nil ? 0 : max(3, g.size.height * value / 100))
        }
      }.clipShape(RoundedRectangle(cornerRadius: 7))
      RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(core.value == nil ? 0 : 0.35), lineWidth: 1)
      Text(core.value.map { String(format: "%.0f%%", $0) } ?? "—")
        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0), radius: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(height: 46)
    .help(core.kind.isEmpty
      ? L("Núcleo %@: %@", "\(index)", core.value.map { String(format: "%.0f%%", $0) } ?? "—")
      : L("Núcleo %@ (%@): %@", "\(index)", core.kind == "P" ? L("desempenho") : L("eficiência"), core.value.map { String(format: "%.0f%%", $0) } ?? "—"))
    .accessibilityElement()
    .accessibilityLabel(core.kind.isEmpty ? L("Núcleo %@", "\(index)") : L("Núcleo %@ (%@)", "\(index)", core.kind))
    .accessibilityValue(core.value.map { String(format: "%.0f%%", $0) } ?? L("indisponível"))
  }
}

/// How to read the tiles, in place of the data source (now on hover).
private struct CoreLegend: View {
  var body: some View {
    HStack(spacing: 12) {
      Text(L("Cada quadrado é um núcleo; mais cheio, mais ocupado.")).foregroundStyle(.secondary)
      Spacer(minLength: 4)
      ForEach([(Tint.cpu, L("folga")), (coreBusy, L("ocupado")), (Tint.warning, L("no limite"))], id: \.1) { color, label in
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.7)).frame(width: 9, height: 9)
          Text(label).foregroundStyle(.secondary)
        }
      }
    }.font(.caption).lineLimit(1).minimumScaleFactor(0.85)
  }
}

/// Activity Monitor style memory categories, swap and the kernel's pressure percentage.
private struct MemoryBreakdownCard: View {
  let snapshot: Snapshot
  @ObservedObject private var vmStore = ContainerVMStore.shared
  var body: some View {
    let s = snapshot
    let total = s.physical.value ?? 0
    let parts: [(String, Metric, Color)] = [
      ("Memória de apps", s.app_memory, Tint.memory),
      ("Wired", s.wired, .orange),
      ("Comprimida", s.compressed, Tint.netOut),
      ("Arquivos em cache", s.cached_files, .gray),
    ]
    Card {
      CardHeader(title: L("Detalhe da memória"), symbol: "memorychip", tint: Tint.memory) {
        Text(L("de %@", s.physical.bytes)).font(.caption).foregroundStyle(.secondary)
      }
      GeometryReader { g in
        HStack(spacing: 1) {
          ForEach(parts, id: \.0) { _, metric, color in
            color.frame(width: total > 0 ? g.size.width * min(1, (metric.value ?? 0) / total) : 0)
          }
          Spacer(minLength: 0)
        }.background(Color.primary.opacity(0.07))
      }.frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
        // The stacked bar repeats the rows below; VoiceOver reads the rows instead.
        .accessibilityHidden(true)
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
        ForEach(parts, id: \.0) { title, metric, color in
          GridRow {
            HStack(spacing: 5) {
              Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
              Text(L(title))
            }
            Text(metric.bytes).monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
          }.help(metric.explanation).accessibilityElement(children: .combine)
        }
        GridRow {
          HStack(spacing: 5) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 8)).frame(width: 7)
              .accessibilityHidden(true)
            Text(L("Swap usado"))
          }
          Text(s.swap.bytes).monospacedDigit().foregroundStyle(.secondary)
        }.help(s.swap.explanation).accessibilityElement(children: .combine)
      }.font(.callout)
      Divider()
      HStack(spacing: 8) {
        Text(L("Pressão de memória")).font(.callout).accessibilityHidden(true)
        if let pct = s.pressure_percent.value {
          MeterBar(fraction: pct / 100, color: pct >= 80 ? Tint.danger : pct >= 60 ? Tint.warning : Tint.cpu)
            .frame(maxWidth: 140)
            .accessibilityLabel(L("Pressão de memória"))
        }
        Text(s.pressure_percent.percent).monospacedDigit()
          .accessibilityLabel(s.pressure_percent.value == nil ? L("Pressão de memória") : "")
          .accessibilityHidden(s.pressure_percent.value != nil)
        Spacer()
        // Colored only while the alert counts: a lingering "warning" with memory to spare is gray.
        let level = s.diagnostics.first { $0.id == "memory" }?.level ?? 0
        Badge(
          text: L("evento: %@", s.pressureLabel.lowercased()),
          color: level >= 2 ? .red : level >= 1 ? .orange : .secondary)
      }.help(s.pressure_percent.explanation + "\n" + s.pressure.explanation)
      Text(
        L("Pressão % = 100 − memória disponível segundo o kernel (kern.memorystatus_level). Os eventos são os avisos do macOS; RAM ocupada, sozinha, não é pressão.")
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      ForEach(vmStore.vms) { vm in
        Divider()
        ContainerVMRow(vm: vm)
      }
    }
    .onAppear { vmStore.appear() }
    .onDisappear { vmStore.disappear() }
  }
}

/// A container VM's memory: how much is free, who uses it, who is at its own limit or got killed.
private struct ContainerVMRow: View {
  let vm: ContainerVM
  var body: some View {
    let used = vm.usedFraction
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(L("VM de contêineres (%@)", vm.engine)).font(.callout)
        MeterBar(fraction: used, color: used >= 0.85 ? Tint.danger : used >= 0.7 ? Tint.warning : Tint.cpu)
          .frame(maxWidth: 140)
        Spacer()
        Text(L("%@ livres de %@", formatBytes(vm.free), formatBytes(vm.total)))
          .monospacedDigit().font(.callout).foregroundStyle(.secondary).fixedSize()
      }
      if !vm.top.isEmpty {
        Text(vm.top.prefix(3).map { "\($0.name) \(formatBytes($0.used))" }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      ForEach(vm.near_limit, id: \.name) { c in
        Label(
          L("%@ no limite: %@ de %@; mais carga e ele é encerrado", c.name, formatBytes(c.used), formatBytes(c.limit ?? 0)),
          systemImage: "exclamationmark.triangle.fill"
        ).font(.caption).foregroundStyle(Tint.warning)
      }
      ForEach(vm.killed, id: \.name) { k in
        let minutes = Int(max(0, (Date().timeIntervalSince1970 - k.at) / 60).rounded())
        Label(
          L(k.oom ? "%@ encerrado há %@ min por falta de memória" : "%@ encerrado há %@ min (código 137)", k.name, "\(minutes)"),
          systemImage: "xmark.octagon.fill"
        ).font(.caption).foregroundStyle(Tint.danger)
      }
    }
    .help(L("A VM tem memória própria, separada da do Mac: os contêineres podem ficar sem memória (e ser encerrados) mesmo com o Mac folgado."))
  }
}

private struct AlertStrip: View {
  let alerts: [Diagnostic]
  @ViewState private var open = false
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(alerts) { d in
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: d.symbol).foregroundStyle(d.color)
          VStack(alignment: .leading, spacing: 3) {
            Text(d.localizedTitle).font(.callout.weight(.semibold))
            if open { Text(d.localizedDetail).font(.caption).foregroundStyle(.secondary) }
          }
          Spacer()
        }
      }
    }
    .padding(12)
    .background(alerts.first!.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    .overlay(alignment: .topTrailing) {
      Button(open ? L("Menos") : L("Detalhes")) { open.toggle() }.buttonStyle(.link).font(.caption)
        .padding(12)
    }
  }
}

/// Compact process line used by overview cards and the menu bar popover.
struct ProcessLine<Trailing: View>: View {
  let process: ProcessItem
  var subtitle: String? = nil
  @ViewBuilder var trailing: Trailing
  var body: some View {
    HStack(spacing: 8) {
      ProcessIcon(process: process, size: 18)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(process.name).lineLimit(1)
          Text(String(process.pid)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 6)
      trailing
    }
    .font(.callout)
    .contentShape(Rectangle())
    .help(process.path)
  }
}
func devSubtitle(_ p: ProcessItem) -> String {
  [p.project, p.origin.map { "via \($0.label)" }, formatDuration(p.uptime)]
    .compactMap { $0 }.joined(separator: " · ")
}

private struct ServersCard: View {
  let groups: [(ProcessItem, Int)]
  @ObservedObject var containers = ContainerStore.shared
  var body: some View {
    let entries = serverEntries(groups, owners: containers.owners)
    Card {
      CardHeader(title: L("Servidores em escuta"), symbol: "network", tint: Tint.netIn, count: entries.count) {
        Button(L("Ver todos")) { navigate(.processes) }.buttonStyle(.link).font(.caption)
      }
      if entries.isEmpty {
        EmptyNote(text: L("Nenhuma porta TCP aberta por processos seus."))
      }
      ForEach(entries.prefix(7)) { entry in
        switch entry {
        case .container(let c, let via, let ports):
          ContainerServerLine(container: c, via: via, ports: ports)
        case .process(let p, let instances, let ports):
          ProcessLine(process: p, subtitle: devSubtitle(p)) {
            HStack(spacing: 3) {
              if instances > 1 {
                Text(L("×%@", "\(instances)")).font(.caption2).foregroundStyle(.secondary)
                  .help(L("%@ processos compartilham estas portas", "\(instances)"))
              }
              ForEach(ports.prefix(2), id: \.port) { port in PortBadge(port: port) }
              if let port = ports.first?.port { OpenPortButton(port: port) }
              KillButton(process: p)
            }
          }
        }
      }
      if entries.count > 7 {
        Text(L("+ %@ servidores", "\(entries.count - 7)")).font(.caption).foregroundStyle(.secondary)
      }
    }.watchesContainers(stats: false)
  }
}

private struct OrphansCard: View {
  let orphans: [ProcessItem]
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    Card {
      CardHeader(
        title: L("Possíveis órfãos"), symbol: "exclamationmark.triangle", tint: .orange,
        count: orphans.count
      ) {
        if orphans.count > 1 {
          Button(L("Encerrar todos…")) { monitor.requestKill(orphans) }.buttonStyle(.link).font(.caption)
        }
      }
      if orphans.isEmpty {
        EmptyNote(text: L("Nenhum runtime de desenvolvimento rodando sem pai."))
      }
      ForEach(orphans.prefix(7)) { p in
        ProcessLine(
          process: p,
          subtitle: [p.project, p.ports.isEmpty ? nil : p.portsLabel, formatDuration(p.uptime), p.memory.bytes]
            .compactMap { $0 }.joined(separator: " · ")
        ) {
          KillButton(process: p)
        }.help(L(p.orphan ?? ""))
      }
    }
  }
}

private struct AgentSession: Identifiable {
  let root: ProcessItem
  let tree: [ProcessItem]
  var id: String { root.id }
  var cpu: Double { tree.compactMap(\.cpu.value).reduce(0, +) }
  var memory: Double { tree.compactMap(\.memory.value).reduce(0, +) }
  var ports: [String] { tree.flatMap(\.ports).map { ":\($0.port)" } }
}
private struct AgentSessionsCard: View {
  let snapshot: Snapshot
  private var sessions: [AgentSession] {
    snapshot.agentSessions
      .map { AgentSession(root: $0, tree: snapshot.subtree(of: $0)) }
  }
  var body: some View {
    let sessions = self.sessions
    Card {
      CardHeader(title: L("Sessões de agentes"), symbol: "sparkles", tint: .orange, count: sessions.count) {
        Button(L("Ver agentes")) { navigate(.agents) }.buttonStyle(.link).font(.caption)
      }
      if sessions.isEmpty {
        EmptyNote(text: L("Nenhuma sessão de Claude Code, Codex ou outro agente em execução (desktop ou terminal)."))
      } else {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
          GridRow {
            Text(L("Agente"))
            Text(L("Onde"))
            Text(L("Projeto"))
            Text(L("Processos"))
            Text(L("Portas"))
            Text(L("CPU"))
            Text(L("Memória"))
            Text("")
          }.font(.caption).foregroundStyle(.secondary)
          ForEach(sessions.prefix(10)) { session in SessionRow(session: session) }
        }
      }
    }
  }
}
private struct SessionRow: View {
  let session: AgentSession
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    let root = session.root
    let ports = session.ports
    GridRow {
      HStack(spacing: 6) {
        ProcessIcon(process: root, size: 16)
        Text(root.host ?? root.name)
        Text(String(root.pid)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
      }
      Badge(text: root.sessionSource, color: root.sessionSource == "Desktop" ? .orange : .secondary)
        .help(root.origin.map { L("Iniciado via %@ · PID %@", "\($0.label)", "\($0.pid)") } ?? L("Sem app de origem"))
      Text(root.project ?? "—").lineLimit(1).help(root.shortCwd)
      Text("\(session.tree.count)").monospacedDigit()
      Text(ports.isEmpty ? "—" : ports.prefix(3).joined(separator: " ")).font(.caption)
        .foregroundStyle(ports.isEmpty ? Color.secondary : Tint.netIn).lineLimit(1)
      Text(String(format: L("%.1f%%"), session.cpu)).monospacedDigit()
      Text(formatBytes(session.memory)).monospacedDigit()
      HStack(spacing: 4) {
        SessionJumpButton(root: root, meta: AgentStore.shared.claudeSessions[root.pid], compact: true)
        KillButton(process: root, targets: session.tree)
      }
    }.font(.callout)
  }
}

private struct TopCard: View {
  let title: String
  let symbol: String
  let tint: Color
  let items: [ProcessItem]
  let value: (ProcessItem) -> String
  var body: some View {
    Card {
      CardHeader(title: L(title), symbol: symbol, tint: tint)
      ForEach(items) { p in
        ProcessLine(process: p, subtitle: p.project ?? p.origin.map { L("via %@", "\($0.label)") }) {
          Text(value(p)).monospacedDigit().foregroundStyle(.secondary)
          KillButton(process: p)
        }
      }
    }
  }
}

struct EmptyNote: View {
  let text: String
  var body: some View {
    Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
  }
}
func navigate(_ page: Page) {
  NotificationCenter.default.post(name: Notification.Name("CoreScope.navigate"), object: page)
}
