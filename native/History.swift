import AppKit
import Combine
import SwiftUI

struct HistoryBucket: Decodable {
  let at: Double
  let samples: Int
  let cpu: Double?
  let cpu_count: Int
  let cpu_max: Double?
  let memory: Double?
  let memory_count: Int
  let swap: Double?
  let disk_read: Double?
  let disk_read_count: Int
  let disk_write: Double?
  let disk_write_count: Int
  let net_in: Double?
  let net_in_count: Int
  let net_out: Double?
  let net_out_count: Int
  let thermal: Int?
  let pressure: Int?
  let pressure_pct: Double?
  var date: Date { Date(timeIntervalSince1970: at) }
}
struct HistoryInfo: Decodable {
  let bytes: Double
  let oldest: Double?
  let newest: Double?
  let minutes: Int
}
struct HistorySeries: Decodable {
  let from: Double
  let to: Double
  let bucket: Double
  let points: [HistoryBucket]
  let info: HistoryInfo
}
struct HistoryProcess: Decodable, Identifiable {
  var name: String
  var path: String
  var cwd: String
  let origin: String
  let cpu: Double
  let cpu_peak: Double
  let memory: Double
  let minutes: Int
  var id: String { [name, path, cwd, origin].joined(separator: "|") }
  var project: String? { projectName(cwd) }
  var subtitle: String {
    [project, origin.isEmpty ? nil : L("via %@", origin)].compactMap { $0 }.joined(separator: " · ")
  }
}
struct HistoryTop: Decodable {
  let from: Double
  let to: Double
  let minutes: Int
  var cpu: [HistoryProcess]
  var memory: [HistoryProcess]
}

enum HistoryRange: String, CaseIterable, Identifiable {
  case hour = "1 h"
  case day = "24 h"
  case week = "7 d"
  var id: String { rawValue }
  var span: Double { self == .hour ? 3600 : self == .day ? 86400 : 7 * 86400 }
  /// 60, 288 and 336 points: one-minute rollups, 5-minute and 30-minute buckets.
  var bucket: Double { self == .hour ? 60 : self == .day ? 300 : 1800 }
}

/// Reads the local history through the Rust core on its own queue (never the collector's).
final class HistoryStore: ObservableObject {
  static let shared = HistoryStore()
  @Published var series: HistorySeries?
  @Published var top: HistoryTop?
  @Published var info: HistoryInfo?
  @Published var error: String?
  private let queue = DispatchQueue(label: "app.corescope.history", qos: .utility)
  private var generation = 0
  private var topGeneration = 0
  static func call(_ request: [String: Any]) throws -> Data {
    let json = String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8) ?? "{}"
    guard let pointer = json.withCString({ cs_history($0) }) else {
      throw NSError(domain: "CoreScope", code: 1, userInfo: [NSLocalizedDescriptionKey: L("O núcleo não retornou dados")])
    }
    defer { cs_free(pointer) }
    let data = Data(bytes: pointer, count: strlen(pointer))
    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = obj["error"] as? String
    {
      throw NSError(domain: "CoreScope", code: 2, userInfo: [NSLocalizedDescriptionKey: L(error)])
    }
    return data
  }
  /// Writes the minute in progress; used on quit.
  static func flush() { _ = try? call(["op": "flush"]) }
  func load(range: HistoryRange, end: Date, completion: @escaping (HistorySeries?) -> Void) {
    let to = (end.timeIntervalSince1970 / range.bucket).rounded(.up) * range.bucket
    let from = to - range.span
    generation += 1
    let current = generation
    queue.async {
      let result = Result {
        try JSONDecoder().decode(
          HistorySeries.self,
          from: Self.call(["op": "series", "from": Int(from), "to": Int(to), "bucket": Int(range.bucket)]))
      }
      DispatchQueue.main.async {
        guard current == self.generation else { return }
        switch result {
        case .success(let s):
          self.series = s
          self.info = s.info
          self.error = nil
          completion(s)
        case .failure(let e):
          self.error = e.localizedDescription
          completion(nil)
        }
      }
    }
  }
  func loadTop(from: Double, to: Double) {
    topGeneration += 1
    let current = topGeneration
    queue.async {
      let result = Result {
        try JSONDecoder().decode(
          HistoryTop.self, from: Self.call(["op": "top", "from": Int(from), "to": Int(to)]))
      }
      DispatchQueue.main.async {
        guard current == self.topGeneration else { return }
        switch result {
        case .success(var t):
          if Demo.enabled {
            for i in t.cpu.indices { t.cpu[i].cwd = Demo.path(t.cpu[i].cwd); t.cpu[i].path = Demo.path(t.cpu[i].path) }
            for i in t.memory.indices { t.memory[i].cwd = Demo.path(t.memory[i].cwd); t.memory[i].path = Demo.path(t.memory[i].path) }
          }
          self.top = t
        case .failure(let e): self.error = e.localizedDescription
        }
      }
    }
  }
  func loadInfo() {
    queue.async {
      let info = try? JSONDecoder().decode(HistoryInfo.self, from: Self.call(["op": "info"]))
      DispatchQueue.main.async { self.info = info }
    }
  }
  func delete(then: @escaping () -> Void = {}) {
    queue.async {
      let result = Result { try Self.call(["op": "delete"]) }
      DispatchQueue.main.async {
        if case .failure(let e) = result { self.error = e.localizedDescription }
        self.series = nil
        self.top = nil
        self.loadInfo()
        then()
      }
    }
  }
}

struct HistoryView: View {
  @ObservedObject var store = HistoryStore.shared
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var range: HistoryRange = .day
  /// nil follows the present; otherwise the window ends at this moment.
  @ViewState private var end: Date?
  @ViewState private var selected: Int?
  private let tick = Timer.publish(every: 60, tolerance: 10, on: .main, in: .common).autoconnect()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !prefs.historyEnabled && (store.info?.minutes ?? 0) == 0 {
          HistoryIntro()
        } else {
          toolbar
          if !prefs.historyEnabled {
            Label(
              L("Gravação desligada: mostrando o histórico já salvo. Ative em Ajustes › Histórico."),
              systemImage: "pause.circle"
            ).font(.callout).foregroundStyle(.secondary)
          }
          if let error = store.error {
            Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
          }
          if let s = store.series { charts(s) }
          if let s = store.series { DominatorsCard(series: s, selected: selected, top: store.top) }
        }
      }.padding(20)
    }
    .onAppear { reload() }
    .onChange(of: range) { _, _ in reload() }
    .onChange(of: end) { _, _ in reload() }
    .onChange(of: selected) { _, _ in loadTop() }
    .onReceive(tick) { _ in if end == nil { reload(keepSelection: true) } }
  }
  private func reload(keepSelection: Bool = false) {
    let selectedAt: Double? = keepSelection ? selected.flatMap { i in
      store.series.flatMap { $0.points.indices.contains(i) ? $0.points[i].at : nil }
    } : nil
    if !keepSelection { selected = nil }
    store.load(range: range, end: end ?? Date()) { series in
      guard let series else {
        self.selected = nil
        self.loadTop()
        return
      }
      if let selectedAt {
        self.selected = series.points.firstIndex { $0.at == selectedAt }
      } else if keepSelection {
        self.selected = nil
      }
      self.loadTop()
    }
  }
  private func loadTop() {
    let to = ((end ?? Date()).timeIntervalSince1970 / range.bucket).rounded(.up) * range.bucket
    if let selected, let s = store.series, s.points.indices.contains(selected) {
      store.loadTop(from: s.points[selected].at, to: s.points[selected].at + s.bucket)
    } else {
      store.loadTop(from: to - range.span, to: to)
    }
  }
  private var toolbar: some View {
    HStack(spacing: 10) {
      Picker(L("Período"), selection: $range) {
        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
      Button {
        end = (end ?? Date()).addingTimeInterval(-range.span)
      } label: {
        Image(systemName: "chevron.left")
      }.help(L("Período anterior"))
      Button {
        let next = (end ?? Date()).addingTimeInterval(range.span)
        end = next >= Date() ? nil : next
      } label: {
        Image(systemName: "chevron.right")
      }.disabled(end == nil).help(L("Próximo período"))
      DatePicker(
        L("Até"),
        selection: Binding(get: { end ?? Date() }, set: { end = $0 >= Date() ? nil : $0 }),
        in: ...Date(), displayedComponents: [.date, .hourAndMinute]
      ).datePickerStyle(.compact).frame(maxWidth: 220)
      Button(L("Agora")) { end = nil }.disabled(end == nil)
      Spacer()
      if let info = store.info {
        Text(
          prefs.historyEnabled
            ? L("Gravando · %@ dias · %@", "\(prefs.historyRetention)", formatBytes(info.bytes))
            : formatBytes(info.bytes)
        ).font(.caption).foregroundStyle(.secondary).help(infoHelp(info))
      }
    }
  }
  private func infoHelp(_ info: HistoryInfo) -> String {
    let oldest = info.oldest.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "—"
    return L("%@ minutos salvos desde %@. Resumos de 1 minuto, gravados uma vez por minuto.", "\(info.minutes)", oldest)
  }
  @ViewBuilder private func charts(_ s: HistorySeries) -> some View {
    let p = s.points
    let physical = Monitor.shared.snapshot?.physical.value
    let percent: (Double) -> String = { String(format: "%.0f%%", $0) }
    TimeAxis(series: s, selected: selected)
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2),
      alignment: .leading, spacing: 12
    ) {
      HistoryChart(
        title: L("CPU"), symbol: "cpu", value: summary(
          p, \.cpu, \.cpu_max, \.cpu_count, \.cpu_count,
          format: { String(format: "%.0f%%", $0) }, labels: ("", L("pico")), secondIsPeak: true),
        series: [
          ChartSeries(values: p.map(\.cpu_max), color: Tint.cpu.opacity(0.45), name: L("pico"), format: percent),
          ChartSeries(values: p.map(\.cpu), color: Tint.cpu, name: L("média"), format: percent),
        ], ceiling: 100, legend: [("média", Tint.cpu), ("pico", Tint.cpu.opacity(0.45))],
        selected: $selected, times: p.map(\.at), bucket: s.bucket)
      HistoryChart(
        title: L("Memória"), symbol: "memorychip", value: summary(
          p, \.memory, \.swap, \.memory_count, \.memory_count,
          format: formatBytes, labels: ("", L("swap")), secondIsPeak: true),
        series: [
          ChartSeries(values: p.map(\.memory), color: Tint.memory, name: L("usada"), format: formatBytes),
          ChartSeries(values: p.map(\.swap), color: .orange, name: L("swap"), format: formatBytes),
        ], ceiling: physical, legend: [("usada", Tint.memory), ("swap", .orange)],
        selected: $selected, times: p.map(\.at), bucket: s.bucket)
      HistoryChart(
        title: L("Disco"), symbol: "internaldrive", value: summary(
          p, \.disk_read, \.disk_write, \.disk_read_count, \.disk_write_count,
          format: formatRate, labels: ("↓", "↑"), secondIsPeak: false),
        series: [
          .diskRead(p.map(\.disk_read)), .diskWrite(p.map(\.disk_write)),
        ], legend: [("leitura", Tint.diskRead), ("escrita", Tint.diskWrite)],
        selected: $selected, times: p.map(\.at), bucket: s.bucket)
      HistoryChart(
        title: L("Rede"), symbol: "arrow.up.arrow.down", value: summary(
          p, \.net_in, \.net_out, \.net_in_count, \.net_out_count,
          format: formatRate, labels: ("↓", "↑"), secondIsPeak: false),
        series: [
          .netIn(p.map(\.net_in)), .netOut(p.map(\.net_out)),
        ], legend: [("entrada", Tint.netIn), ("saída", Tint.netOut)],
        selected: $selected, times: p.map(\.at), bucket: s.bucket)
    }
    StateStrips(points: p, selected: $selected)
  }
  /// Values at the selected bucket; otherwise the window's mean of the first series and the
  /// mean (rates) or maximum (peaks, swap) of the second.
  private func summary(
    _ points: [HistoryBucket], _ first: KeyPath<HistoryBucket, Double?>,
    _ second: KeyPath<HistoryBucket, Double?>, _ firstCount: KeyPath<HistoryBucket, Int>,
    _ secondCount: KeyPath<HistoryBucket, Int>, format: @escaping (Double) -> String, labels: (String, String),
    secondIsPeak: Bool
  ) -> String {
    let label = { (text: String, value: Double) in text.isEmpty ? format(value) : text + " " + format(value) }
    if let selected, points.indices.contains(selected) {
      let b = points[selected]
      let parts = [b[keyPath: first].map { label(labels.0, $0) }, b[keyPath: second].map { label(labels.1, $0) }]
      return parts.compactMap { $0 }.joined(separator: " · ").nonEmpty ?? L("Sem dados")
    }
    func mean(_ key: KeyPath<HistoryBucket, Double?>, count: KeyPath<HistoryBucket, Int>) -> Double? {
      let values = points.compactMap { point -> (Double, Int)? in
        guard let value = point[keyPath: key], point[keyPath: count] > 0 else { return nil }
        return (value, point[keyPath: count])
      }
      let total = values.reduce(0) { $0 + $1.1 }
      return total == 0 ? nil : values.reduce(0) { $0 + $1.0 * Double($1.1) } / Double(total)
    }
    guard let a = mean(first, count: firstCount) else { return L("Sem dados") }
    let b = secondIsPeak ? points.compactMap { $0[keyPath: second] }.max() : mean(second, count: secondCount)
    return [L("média %@", label(labels.0, a)), b.map { (secondIsPeak ? L("máx. %@", label(labels.1, $0)) : label(labels.1, $0)) }]
      .compactMap { $0 }.joined(separator: " · ")
  }
}

extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

private struct HistoryIntro: View {
  @ObservedObject var prefs = Preferences.shared
  var body: some View {
    Card {
      CardHeader(title: L("Histórico persistente"), symbol: "clock.arrow.circlepath", tint: .accentColor)
      Text(
        L("Responda “o que deixou o Mac lento ontem às 15h?”: com o histórico ligado, o CoreScope guarda a cada minuto CPU, memória, swap, disco, rede, estado térmico e os 10 processos que mais usaram CPU e memória.")
      ).fixedSize(horizontal: false, vertical: true)
      Text(
        L("Fica só neste Mac, em ~/Library/Application Support/CoreScope. Nunca grava argumentos ou variáveis de ambiente. Desligado por padrão; apague tudo quando quiser.")
      ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(L("Ativar histórico (7 dias)")) {
          prefs.historyRetention = 7
          prefs.historyEnabled = true
        }.buttonStyle(.borderedProminent)
        Button(L("Abrir ajustes")) { navigate(.settings) }
      }
    }
  }
}

/// Start, middle and end labels of the window, or the selected bucket.
private struct TimeAxis: View {
  let series: HistorySeries
  let selected: Int?
  var body: some View {
    HStack {
      if let selected, series.points.indices.contains(selected) {
        let b = series.points[selected]
        Label(
          L("Selecionado: %@ – %@", label(b.at, full: true), label(b.at + series.bucket, full: false)),
          systemImage: "scope"
        ).foregroundStyle(Color.accentColor)
        Spacer()
        Text(b.samples > 0 ? L("%@ amostras", "\(b.samples)") : L("Sem registro neste intervalo"))
      } else {
        Text(label(series.from, full: true))
        Spacer()
        Text(L("Clique em um gráfico para ver o que dominou naquele momento"))
        Spacer()
        Text(label(series.to, full: true))
      }
    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
  }
  private func label(_ t: Double, full: Bool) -> String {
    let d = Date(timeIntervalSince1970: t)
    return full && !Calendar.current.isDateInToday(d)
      ? d.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())
      : d.formatted(date: .omitted, time: .shortened)
  }
}

/// AreaChart with a shared, clickable selection; gaps stay gaps.
private struct HistoryChart: View {
  let title: String
  let symbol: String
  let value: String
  let series: [ChartSeries]
  var ceiling: Double? = nil
  var legend: [(String, Color)] = []
  @Binding var selected: Int?
  let times: [Double]
  let bucket: Double
  var body: some View {
    let count = series.first?.values.count ?? 0
    Card {
      HStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
          .foregroundStyle(series.last?.color ?? .secondary).accessibilityHidden(true)
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        ForEach(legend, id: \.0) { item in
          HStack(spacing: 3) {
            Circle().fill(item.1).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(L(item.0)).font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }
      }
      Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
      AreaChart(series: series, ceiling: ceiling, capacity: max(2, count), title: title)
        .frame(height: 96)
        .overlay { SelectionLayer(count: count, selected: $selected) }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(selectedInterval)
        .accessibilityAdjustableAction { direction in
          moveSelection(direction == .increment ? 1 : -1)
        }
        .focusable()
        .onKeyPress(.leftArrow) { moveSelection(-1) }
        .onKeyPress(.rightArrow) { moveSelection(1) }
    }
  }
  private var selectedInterval: String {
    guard let selected, times.indices.contains(selected) else { return L("Nenhum intervalo selecionado") }
    let start = Date(timeIntervalSince1970: times[selected])
    let end = start.addingTimeInterval(bucket)
    return "\(start.formatted(date: .complete, time: .shortened)) – \(end.formatted(date: .complete, time: .shortened))"
  }
  private func moveSelection(_ direction: Int) -> KeyPress.Result {
    let count = times.count
    guard count > 0 else { return .ignored }
    let current = selected ?? (direction > 0 ? -1 : count)
    selected = min(count - 1, max(0, current + direction))
    return .handled
  }
}
private struct SelectionLayer: View {
  let count: Int
  @Binding var selected: Int?
  var body: some View {
    GeometryReader { g in
      let step = g.size.width / CGFloat(max(1, count - 1))
      ZStack(alignment: .topLeading) {
        if let selected {
          Rectangle().fill(Color.accentColor.opacity(0.8)).frame(width: 1.5, height: g.size.height)
            .offset(x: CGFloat(selected) * step - 0.75).accessibilityHidden(true)
        }
        Color.clear.contentShape(Rectangle()).accessibilityHidden(true)
          .gesture(
            DragGesture(minimumDistance: 0).onChanged { v in
              guard count > 0 else { return }
              selected = min(count - 1, max(0, Int((v.location.x / step).rounded())))
            })
      }
    }
  }
}

/// Thermal state and memory-pressure events as colored cells, plus pressure % over time.
private struct StateStrips: View {
  let points: [HistoryBucket]
  @Binding var selected: Int?
  var body: some View {
    Card {
      CardHeader(title: L("Térmico e pressão de memória"), symbol: "thermometer.medium", tint: .orange)
      strip(L("Térmico"), values: points.map(\.thermal), names: ["Nominal", "Moderado", "Sério", "Crítico"]) { v in
        [Color.green.opacity(0.35), .yellow, .orange, .red][min(3, max(0, v))]
      }
      strip(L("Eventos de pressão"), values: points.map(\.pressure), names: ["Normal", "Atenção", "Crítica"]) { v in
        [Color.green.opacity(0.35), .orange, .red][min(2, max(0, v))]
      }
      HStack(alignment: .top, spacing: 8) {
        Text(L("Pressão %")).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
          .accessibilityHidden(true)
        AreaChart(
          series: [
            ChartSeries(values: points.map(\.pressure_pct), color: .orange, format: { String(format: "%.0f%%", $0) })
          ], ceiling: 100, capacity: max(2, points.count), grid: false, title: L("Pressão %")
        ).frame(height: 36).overlay { SelectionLayer(count: points.count, selected: $selected) }
      }
      Text(
        L("Térmico: pior estado do macOS no intervalo (não é °C). Eventos: pior aviso Dispatch de pressão. Pressão %: 100 − memória disponível segundo o kernel (kern.memorystatus_level), máximo do intervalo.")
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func strip(_ title: String, values: [Int?], names: [String], color: @escaping (Int) -> Color) -> some View {
    let worst = values.compactMap { $0 }.max()
    return HStack(spacing: 8) {
      Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
      Canvas { context, size in
        let width = size.width / CGFloat(max(1, values.count))
        for (i, v) in values.enumerated() {
          guard let v else { continue }
          let rect = CGRect(x: CGFloat(i) * width, y: 0, width: max(1, width - 0.5), height: size.height)
          context.fill(Path(rect), with: .color(color(v)))
        }
      }.frame(height: 12).background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    // Spoken as the worst state of the window; the cells are visual only.
    .accessibilityElement()
    .accessibilityLabel(title)
    .accessibilityValue(worst.map { L("pior: %@", L(names[min(names.count - 1, max(0, $0))])) } ?? L("Sem dados"))
  }
}

/// The processes that dominated the selected bucket (or the whole window).
private struct DominatorsCard: View {
  let series: HistorySeries
  let selected: Int?
  let top: HistoryTop?
  var body: some View {
    Card {
      CardHeader(title: L("O que dominou"), symbol: "flame", tint: Tint.cpu) {
        if let top {
          Text(L("%@ minutos registrados", "\(top.minutes)")).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let top, top.minutes > 0 {
        HStack(alignment: .top, spacing: 20) {
          column(L("Maior CPU"), top.cpu, tint: Tint.cpu) { p in
            (String(format: L("%.1f%%"), p.cpu), L("pico %@", String(format: "%.0f%%", p.cpu_peak)))
          }
          column(L("Maior memória"), top.memory, tint: Tint.memory) { p in
            (formatBytes(p.memory), L("%@ min no top", "\(p.minutes)"))
          }
        }
        Text(
          L("CPU: média em % de um núcleo sobre os minutos do intervalo; minutos fora do top 10 contam como zero. Memória: maior phys_footprint registrado. Agrupado por executável, diretório e origem.")
        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        EmptyNote(text: L("Nada registrado neste intervalo (Mac em repouso, app fechado ou histórico desligado)."))
      }
    }
  }
  private func column(
    _ title: String, _ items: [HistoryProcess], tint: Color, value: @escaping (HistoryProcess) -> (String, String)
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
        .accessibilityAddTraits(.isHeader)
      ForEach(items) { p in
        HStack(spacing: 8) {
          HistoryIcon(path: p.path, origin: p.origin)
          VStack(alignment: .leading, spacing: 1) {
            Text(p.name).lineLimit(1)
            if !p.subtitle.isEmpty {
              Text(p.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
          }
          Spacer(minLength: 6)
          let (main, detail) = value(p)
          VStack(alignment: .trailing, spacing: 1) {
            Text(main).monospacedDigit()
            Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
          }
        }.font(.callout).help([p.path, abbreviateHome(p.cwd)].filter { !$0.isEmpty }.joined(separator: "\n"))
          .accessibilityElement(children: .combine)
      }
    }.frame(maxWidth: .infinity, alignment: .topLeading)
  }
}
private struct HistoryIcon: View {
  let path: String
  let origin: String
  var body: some View {
    icon.accessibilityHidden(true)
  }
  @ViewBuilder private var icon: some View {
    if let range = path.range(of: ".app/") {
      Image(nsImage: IconCache.image(for: String(path[..<range.lowerBound]) + ".app")).resizable()
        .frame(width: 18, height: 18)
    } else {
      Image(systemName: origin.isEmpty ? "app.dashed" : "sparkles")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(origin.isEmpty ? Color.secondary : Color.orange)
        .frame(width: 18, height: 18)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
  }
}
