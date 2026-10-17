import AppKit
import SwiftUI

struct MetricLine: View {
  let title: String
  let metric: Metric
  var text: String? = nil
  var body: some View {
    HStack {
      Text(L(title))
      Spacer()
      Text(text ?? metric.bytes).monospacedDigit().foregroundStyle(.secondary)
    }.help(metric.explanation).accessibilityElement(children: .combine)
  }
}
struct SectionHeading: View {
  let title: String
  var subtitle: String? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.title2.weight(.semibold))
      if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
    }
  }
}
struct StateFooter: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    HStack(spacing: 8) {
      LiveDot(stale: monitor.stale)
      Text(
        monitor.sleeping
          ? L("Em repouso") : monitor.manuallyPaused ? L("Coleta pausada") : monitor.stale ? L("Dados antigos") : L("Coleta local ao vivo"))
      Spacer()
      if let s = monitor.snapshot {
        Text(L("%@ processos · %@ servidores · %@ órfãos", "\(s.processes.count)", "\(s.servers.count)", "\(s.orphans.count)"))
        Text("·")
        Text(Date(timeIntervalSince1970: s.at), style: .time)
      }
    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
      .padding(.horizontal, 16).padding(.vertical, 7)
      .background(.bar)
  }
}
enum Page: String, CaseIterable, Identifiable {
  case overview = "Visão geral"
  case processes = "Processos"
  case agents = "Agentes"
  case history = "Histórico"
  case storage = "Armazenamento"
  case sensors = "Sensores"
  case settings = "Ajustes"
  var id: String { rawValue }
  var title: String { L(rawValue) }
  var icon: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .processes: "list.bullet.indent"
    case .agents: "sparkles"
    case .history: "clock.arrow.circlepath"
    case .storage: "internaldrive"
    case .sensors: "thermometer.medium"
    case .settings: "gearshape"
    }
  }
}
struct MainView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @Environment(\.openWindow) private var openWindow
  @ViewState private var page: Page? = .overview
  var body: some View {
    NavigationSplitView {
      // Data-driven List with an explicit tag per row: the ForEach + .badge form did not
      // register clicks as selection changes.
      List(Page.allCases, selection: $page) { item in
        HStack {
          Label(item.title, systemImage: item.icon)
          Spacer(minLength: 4)
          if item == .processes, let count = monitor.snapshot?.orphans.count, count > 0 {
            Badge(text: "\(count)", color: .orange).help(L("%@ possíveis órfãos", String(count)))
          }
        }.tag(item).padding(.vertical, 3)
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
      .safeAreaInset(edge: .bottom) {
        HStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
          VStack(alignment: .leading, spacing: 1) {
            Text(L("CoreScope")).font(.system(size: 13, weight: .semibold))
            Text(L("Monitor para desenvolvedores")).font(.caption2).foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
      }
    } detail: {
      VStack(spacing: 0) {
        if monitor.stale, monitor.snapshot != nil {
          Label(
            monitor.sleeping
              ? L("Em repouso · dados anteriores")
              : monitor.manuallyPaused
                ? L("Coleta pausada · dados anteriores") : L("Dados antigos · aguardando coleta"),
            systemImage: "clock.badge.exclamationmark"
          ).font(.callout).frame(maxWidth: .infinity).padding(7).background(
            Color.orange.opacity(0.12))
        }
        if let error = monitor.error {
          Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red).padding(8)
        }
        Group {
          switch page ?? .overview {
          case .overview: OverviewView()
          case .processes: ProcessesView()
          case .agents: AgentsView()
          case .history: HistoryView()
          case .storage: StorageView()
          case .sensors: SensorsView()
          case .settings: PreferencesView()
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        StateFooter()
      }
      .overlay(alignment: .bottom) { FeedbackToast().padding(.bottom, 44).padding(.horizontal, 40) }
      .navigationTitle(page?.title ?? "CoreScope")
      .toolbar {
        ToolbarItemGroup {
          Button {
            prefs.panelVisible.toggle()
          } label: {
            Label(L("Painel flutuante"), systemImage: prefs.panelVisible ? "pip.fill" : "pip")
          }.help(L("Mostrar ou ocultar o painel flutuante (⇧⌘P)"))
          Button {
            monitor.setPaused(!monitor.manuallyPaused)
          } label: {
            Label(
              monitor.manuallyPaused ? L("Retomar") : L("Pausar"),
              systemImage: monitor.manuallyPaused ? "play.fill" : "pause.fill")
          }.help(monitor.manuallyPaused ? L("Retomar coleta") : L("Pausar coleta"))
          Button {
            monitor.refresh()
          } label: {
            Label(L("Atualizar"), systemImage: "arrow.clockwise")
          }.keyboardShortcut("r", modifiers: .command).help(L("Atualizar agora (⌘R)"))
        }
      }
    }
    .id(prefs.language)
    .modifier(KillConfirmation())
    .frame(minWidth: 900, minHeight: 600)
    .onAppear { WindowOpener.shared.open = { openWindow(id: "main") } }
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CoreScope.navigate"))) {
      event in if let selected = event.object as? Page { page = selected }
    }
  }
}
struct StorageView: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let s = monitor.snapshot {
          ResourceCard(
            title: L("Atividade de disco"), symbol: "internaldrive", value: s.diskRate,
            detail: L("↓ %@  ↑ %@ · soma dos dispositivos físicos", "\(s.disk_read.rate)", "\(s.disk_write.rate)"),
            series: [
              ChartSeries(values: s.history.map(\.disk_read), color: Tint.diskRead),
              ChartSeries(values: s.history.map(\.disk_write), color: Tint.diskWrite),
            ], legend: [("leitura", Tint.diskRead), ("escrita", Tint.diskWrite)])
          Card {
            CardHeader(title: L("Dispositivos"), symbol: "externaldrive", count: s.disks.count)
            if s.disks.isEmpty {
              EmptyNote(
                text:
                  L("Contadores físicos %@.", L(s.disk_state == "unsupported" ? "não suportados" : "temporariamente indisponíveis")))
            }
            ForEach(s.disks) { d in
              HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                  Text(d.name).font(.headline)
                  Text(L("Registro IOKit %@", "\(d.id)")).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                  HStack(spacing: 12) {
                    Label(d.read.rate, systemImage: "arrow.down").foregroundStyle(Tint.diskRead)
                      .help(d.read.explanation)
                    Label(d.write.rate, systemImage: "arrow.up").foregroundStyle(Tint.diskWrite)
                      .help(d.write.explanation)
                  }.monospacedDigit().font(.callout)
                  Text(d.temperature.temperature).font(.caption).foregroundStyle(.secondary)
                    .help(d.temperature.explanation)
                }
              }.padding(.vertical, 4)
            }
            Text(
              L("Contadores por dispositivo do IOKit, não por volume APFS. I/O alto não mede saturação ou latência.")
            ).font(.caption).foregroundStyle(.secondary)
          }
          Card {
            CardHeader(title: L("Volumes montados"), symbol: "folder", count: s.volumes.count)
            if s.volumes.isEmpty { EmptyNote(text: L("Inventário temporariamente indisponível.")) }
            ForEach(Array(s.volumes.enumerated()), id: \.offset) { _, v in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(v.mount).font(.callout.weight(.medium)).textSelection(.enabled)
                  Badge(text: v.kind.uppercased())
                  Spacer()
                  Text(L("%@ livres de %@", "\(v.available.bytes)", "\(v.total.bytes)")).font(.caption)
                    .foregroundStyle(.secondary).monospacedDigit()
                }
                if let total = v.total.value, let available = v.available.value, total > 0 {
                  let free = available / total
                  MeterBar(
                    fraction: 1 - free,
                    color: free < 0.05 ? .red : free < 0.1 ? .orange : Color.accentColor)
                }
              }.padding(.vertical, 4).help(v.id)
            }
            Text(
              L("Atualizado a cada 30 s. Volumes APFS do mesmo contêiner compartilham espaço: não some capacidades.")
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.padding(20)
    }
  }
}
struct SensorsView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let s = monitor.snapshot {
          Card {
            HStack(spacing: 14) {
              Image(systemName: "thermometer.medium").font(.system(size: 28))
                .foregroundStyle(s.thermalColor)
              VStack(alignment: .leading, spacing: 3) {
                Text(L("Estado térmico do macOS")).font(.caption).foregroundStyle(.secondary)
                Text(s.thermalLabel).font(.system(size: 24, weight: .semibold, design: .rounded))
              }
              Spacer()
              Toggle(L("Mostrar no painel"), isOn: $prefs.thermalInPanel)
            }.help(s.thermal.explanation)
            Text(L("Estado informado pelo sistema; não é uma temperatura em °C.")).font(.caption)
              .foregroundStyle(.secondary)
          }
          Card {
            CardHeader(title: L("Temperatura NVMe"), symbol: "internaldrive")
            ForEach(s.disks) { d in
              HStack {
                Text(d.name)
                Spacer()
                Text(d.temperature.temperature).monospacedDigit()
                  .foregroundStyle(d.temperature.value == nil ? .secondary : .primary)
              }.help(d.temperature.explanation)
            }
            Picker(L("Sensor no menu e painel"), selection: $prefs.selectedSensor) {
              Text(L("Nenhum")).tag("")
              ForEach(s.disks.filter { $0.temperature.value != nil }) { d in Text(d.name).tag(d.id) }
            }
            Text(
              L("Leitura pública NVMe SMART a cada 30 s (temperatura composta do controlador), sem root e sem comandos de escrita. Adaptadores USB/SATA podem não expor SMART; ausência de leitura não significa temperatura normal.")
            ).font(.caption).foregroundStyle(.secondary)
          }
          Card {
            Label(L("Temperatura de CPU / SoC: não suportado"), systemImage: "minus.circle")
              .font(.callout.weight(.semibold))
            Text(
              L("Não há fonte pública em °C integrada para este hardware; APIs privadas de SMC/HID não são usadas.")
            ).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.padding(20)
    }
  }
}
