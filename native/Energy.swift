import SwiftUI

/// Battery, the power processes draw right now (per-process energy from rusage v6) and which agent
/// sessions — with everything they started — are behind it.
struct EnergyView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let s = monitor.snapshot {
          batteryCard(s)
          sessionsCard(s)
          processesCard(s)
        } else {
          ProgressView(L("Lendo processos…")).frame(maxWidth: .infinity, minHeight: 240)
        }
        Card {
          Toggle(L("Notificar quando um agente gastar bateria"), isOn: $prefs.notifyAgentDrain)
            .onChange(of: prefs.notifyAgentDrain) { _, on in if on { Notifier.shared.activate() } }
          LabeledContent(L("Acima de")) {
            Slider(value: $prefs.drainWatts, in: 0.5...10, step: 0.5).frame(width: 180)
            Text(String(format: "%.1f W", prefs.drainWatts)).monospacedDigit().frame(width: 56)
          }.disabled(!prefs.notifyAgentDrain)
          Text(
            L("Só na bateria: avisa quando uma sessão de agente, somando os processos que ela iniciou, passa do limite por 5 minutos (no máximo uma vez por hora por sessão).")
          ).font(.caption).foregroundStyle(.secondary)
        }
        Text(
          L("Watts estimados pelo macOS para cada processo (energia de CPU e GPU atribuída a ele, rusage v6). Não inclui tela, rádios e outros componentes, então a soma fica abaixo do consumo total do Mac.")
        ).font(.caption).foregroundStyle(.secondary)
      }.padding(20)
    }
  }

  private func batteryCard(_ s: Snapshot) -> some View {
    Card {
      HStack(alignment: .firstTextBaseline, spacing: 18) {
        VStack(alignment: .leading, spacing: 4) {
          if let b = s.battery {
            Text("\(b.percent)%").font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(batteryState(b)).font(.callout).foregroundStyle(.secondary)
          } else {
            Text(L("Sem bateria")).font(.title3.weight(.semibold))
            Text(L("Este Mac usa só energia da tomada.")).font(.callout).foregroundStyle(.secondary)
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text(s.power?.value.map { String(format: "%.2f W", $0) } ?? "—")
            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
          Text(L("processos agora")).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let b = s.battery {
        MeterBar(fraction: Double(b.percent) / 100, color: b.percent <= 10 ? .red : b.percent <= 20 ? .orange : Tint.brand)
          .frame(height: 8)
      }
    }
  }
  private func batteryState(_ b: BatteryInfo) -> String {
    let time = b.minutes.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
    if b.charging { return time.map { L("Carregando · cheia em %@", $0) } ?? L("Carregando") }
    if b.on_ac { return L("Na tomada, sem carregar") }
    return time.map { L("Na bateria · %@ restantes", $0) } ?? L("Na bateria")
  }

  private func sessionsCard(_ s: Snapshot) -> some View {
    let rows = s.agentSessions.map { root in
      (root, s.subtree(of: root).compactMap { $0.energy?.value }.reduce(0, +))
    }.sorted { $0.1 > $1.1 }
    return Card {
      CardHeader(title: L("Sessões de agente"), symbol: "sparkles", count: rows.count)
      if rows.isEmpty { EmptyNote(text: L("Nenhuma sessão de agente rodando.")) }
      ForEach(rows, id: \.0.id) { root, watts in
        ProcessLine(process: root, subtitle: [root.host, root.project].compactMap { $0 }.joined(separator: " · ")) {
          Text(String(format: "%.2f W", watts)).font(.callout.weight(.semibold)).monospacedDigit()
            .foregroundStyle(watts >= prefs.drainWatts ? .orange : .primary)
            .help(L("Soma da sessão e de tudo que ela iniciou"))
        }
      }
    }
  }

  private func processesCard(_ s: Snapshot) -> some View {
    let top = s.processes.filter { ($0.energy?.value ?? 0) > 0 }
      .sorted { ($0.energy?.value ?? 0, $0.pid) > ($1.energy?.value ?? 0, $1.pid) }.prefix(12)
    return Card {
      CardHeader(title: L("Processos que mais gastam"), symbol: "bolt", count: top.count)
      if top.isEmpty { EmptyNote(text: L("Sem leitura de energia por processo neste macOS.")) }
      ForEach(Array(top)) { p in
        ProcessLine(process: p, subtitle: [p.project, p.origin.map { L("via %@", $0.label) }].compactMap { $0 }.joined(separator: " · ")) {
          HStack(spacing: 8) {
            Text(String(format: "%.2f W", p.energy?.value ?? 0)).font(.callout.weight(.semibold)).monospacedDigit()
            Text(p.cpu.percent).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
            KillButton(process: p)
          }
        }
      }
    }
  }
}
