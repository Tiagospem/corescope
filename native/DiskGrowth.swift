import AppKit
import SwiftUI

struct GrowthChild: Decodable, Hashable {
  let name: String
  let path: String
  let bytes: Double
  let change: Double?
}
struct GrowthFolder: Decodable, Hashable {
  let label: String
  let path: String
  let bytes: Double
  let change: Double?
  let children: [GrowthChild]?
  /// A cleanup plan action that frees this folder.
  let cleanup: String?
}
struct GrowthReport: Decodable, Equatable {
  let measured_at: Double?
  let baseline_at: Double?
  let free: Double?
  let free_change: Double?
  let folders: [GrowthFolder]
}

/// Which usual folders grew today. Measured at most every 6 hours in the background (a walk of
/// caches and stores that takes seconds) and whenever asked; the report itself is a file read.
final class DiskGrowthStore: ObservableObject {
  static let shared = DiskGrowthStore()
  @Published private(set) var report: GrowthReport?
  @Published private(set) var measuring = false
  private let queue = DispatchQueue(label: "app.corescope.diskgrowth", qos: .utility)

  private init() {
    load()
    // Not at launch: the first minutes belong to the collector and the agents' first reads.
    DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in self?.measureIfOld() }
    Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.measureIfOld() }.tolerance = 300
  }
  private func measureIfOld() {
    guard !Monitor.shared.sleeping, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
    // The walk costs a minute of CPU and a lot of disk reads: only on an idle Mac (tried hourly).
    if let s = Monitor.shared.snapshot,
      (s.cpu.value ?? 0) > 40 || (s.pressure_percent.value ?? 0) > 60 || (s.disk_read.value ?? 0) > 20_000_000
    {
      return
    }
    let last = report?.measured_at ?? 0
    if Date().timeIntervalSince1970 - last >= 6 * 3600 { measure() }
  }
  func load() { call(measure: false) }
  func measure() {
    guard !measuring else { return }
    measuring = true
    call(measure: true)
  }
  private func call(measure: Bool) {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("diskgrowth", cost) }
      let request = measure ? #"{"op":"measure"}"# : #"{"op":"report"}"#
      var next: GrowthReport?
      if let pointer = request.withCString({ cs_disk_growth($0) }) {
        next = try? JSONDecoder().decode(GrowthReport.self, from: Data(bytes: pointer, count: strlen(pointer)))
        cs_free(pointer)
      }
      DispatchQueue.main.async {
        if measure { self.measuring = false }
        if let next, next != self.report { self.report = next }
      }
    }
  }
}

struct DiskGrowthCard: View {
  @ObservedObject var store = DiskGrowthStore.shared
  @ObservedObject var plan = CleanupPlanStore.shared
  @ViewState private var expanded: Set<String> = []
  var body: some View {
    Card {
      CardHeader(title: L("O que cresceu hoje"), symbol: "chart.line.uptrend.xyaxis", tint: .orange) {
        if store.measuring {
          ProgressView().controlSize(.small)
        } else {
          Button(L("Medir agora")) { store.measure() }.controlSize(.small)
        }
      }
      if let r = store.report, let at = r.measured_at {
        let date = { (t: Double) in Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened) }
        Text(
          r.baseline_at.map { L("Medido em %@, comparado com %@.", date(at), date($0)) }
            ?? L("Primeira medição em %@: o crescimento aparece a partir da próxima.", date(at))
        ).font(.caption).foregroundStyle(.secondary)
        if let free = r.free {
          HStack {
            Text(L("Espaço livre"))
            Spacer()
            Text(formatBytes(free)).monospacedDigit()
            if let c = r.free_change { change(c, downIsBad: true) }
          }.font(.callout)
        }
        ForEach(r.folders.prefix(10), id: \.self) { g in
          let kids = (g.children ?? []).filter { ($0.change ?? 0) > 1_048_576 || g.change == nil }
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
              Button {
                if expanded.contains(g.path) { expanded.remove(g.path) } else { expanded.insert(g.path) }
              } label: {
                Image(systemName: expanded.contains(g.path) ? "chevron.down" : "chevron.right").frame(width: 12)
              }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(g.children?.isEmpty ?? true)
                .help(L("Subpastas que mais cresceram"))
              VStack(alignment: .leading, spacing: 1) {
                Text(g.label.isEmpty ? (g.path as NSString).lastPathComponent : g.label).font(.callout)
                Text(abbreviateHome(g.path)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
              }
              Spacer()
              if let id = g.cleanup, let action = plan.actions.first(where: { $0.id == id }) {
                Button(L("Liberar %@", formatBytes(action.estimate))) {
                  plan.selected.insert(id)
                }.controlSize(.small).help(L("Marca \"%@\" no plano de limpeza abaixo.", action.title))
              }
              Text(formatBytes(g.bytes)).monospacedDigit().foregroundStyle(.secondary)
              if let c = g.change { change(c) } else { Text("—").foregroundStyle(.tertiary).frame(width: 90, alignment: .trailing) }
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.path)])
              } label: {
                Image(systemName: "folder")
              }.buttonStyle(HoverButtonStyle()).help(L("Mostrar no Finder"))
            }
            if expanded.contains(g.path) {
              ForEach((kids.isEmpty ? Array((g.children ?? []).prefix(5)) : kids), id: \.self) { k in
                HStack(spacing: 10) {
                  Text(k.name).font(.caption).lineLimit(1).truncationMode(.middle)
                  Spacer()
                  Text(formatBytes(k.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                  if let c = k.change { change(c) } else { Text("—").font(.caption).foregroundStyle(.tertiary).frame(width: 90, alignment: .trailing) }
                  Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: k.path)])
                  } label: {
                    Image(systemName: "folder")
                  }.buttonStyle(HoverButtonStyle(size: 20)).help(L("Mostrar no Finder"))
                }.padding(.leading, 22)
              }
            }
          }
        }
      } else {
        EmptyNote(text: L("Ainda não medido. A primeira medição roda 3 minutos depois de abrir o app, ou agora pelo botão."))
      }
      Text(
        L("Pastas que costumam encher o disco de quem desenvolve: caches, Xcode e simuladores, VMs de contêiner, lojas de pacotes, modelos, Downloads, Lixeira e dados de agentes. Medidas no máximo a cada 6 h em segundo plano (alguns segundos de disco); limpar continua com você, na Limpeza. Também: corescope disk-growth e MCP disk_growth.")
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  /// A folder growing (or free space shrinking) is orange; the other way is green.
  private func change(_ bytes: Double, downIsBad: Bool = false) -> some View {
    let up = bytes > 1_048_576
    let down = bytes < -1_048_576
    let bad = downIsBad ? down : up
    let text = up ? "+" + formatBytes(bytes) : down ? "−" + formatBytes(-bytes) : "±0"
    return Text(text).monospacedDigit().font(.callout.weight(bad ? .semibold : .regular))
      .foregroundStyle(bad ? Color.orange : (up || down) ? .green : .secondary)
      .frame(width: 90, alignment: .trailing)
  }
}
