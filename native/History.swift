import AppKit
import Combine
import SwiftUI

struct HistoryBucket: Decodable {
  let at: Double
  let samples: Int
  let cpu: Double?
  let cpu_minutes: Int
  let cpu_max: Double?
  let memory: Double?
  let memory_minutes: Int
  let swap: Double?
  let disk_read: Double?
  let disk_read_minutes: Int
  let disk_write: Double?
  let disk_write_minutes: Int
  let net_in: Double?
  let net_in_minutes: Int
  let net_out: Double?
  let net_out_minutes: Int
  let thermal: Int?
  let pressure: Int?
  let pressure_pct: Double?
  /// Watts (processes' sum); nil in minutes recorded before 0.5.
  let power: Double?
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
  let energy: Double?
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
  var energy: [HistoryProcess]?
}
/// What the Mac was doing around a moment (`cs_history` op `happened`).
struct HistoryHappened: Decodable {
  let at: Double
  let from: Double
  let to: Double
  let minutes: Int
  let cpu: Double?
  let cpu_max: Double?
  let cpu_max_at: Double?
  let cpu_before: Double?
  let memory_max: Double?
  let swap_start: Double?
  let swap_end: Double?
  let power: Double?
  let power_max: Double?
  let power_max_at: Double?
  let power_before: Double?
  let disk_write_max: Double?
  let thermal_max: Int?
  let pressure_max: Int?
  var top: HistoryTop
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
  @Published var happened: HistoryHappened?
  /// The moment last asked about (palette, corescope:// links, the History card).
  @Published var happenedAt: Date?
  private let queue = DispatchQueue(label: "app.corescope.history", qos: .utility)
  private var generation = 0
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
  func load(range: HistoryRange, end: Date, then: ((HistorySeries?) -> Void)? = nil) {
    let to = (end.timeIntervalSince1970 / range.bucket).rounded(.up) * range.bucket
    let from = to - range.span
    generation += 1
    let current = generation
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("history", cost) }
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
          then?(s)
        case .failure(let e):
          self.error = e.localizedDescription
          then?(nil)
        }
      }
    }
  }
  func loadTop(from: Double, to: Double) {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("history", cost) }
      let result = Result {
        try JSONDecoder().decode(
          HistoryTop.self, from: Self.call(["op": "top", "from": Int(from), "to": Int(to)]))
      }
      DispatchQueue.main.async {
        switch result {
        case .success(var t):
          if Demo.enabled {
            for i in t.cpu.indices { t.cpu[i].cwd = Demo.path(t.cpu[i].cwd); t.cpu[i].path = Demo.path(t.cpu[i].path, executable: true) }
            for i in t.memory.indices { t.memory[i].cwd = Demo.path(t.memory[i].cwd); t.memory[i].path = Demo.path(t.memory[i].path, executable: true) }
          }
          self.top = t
        case .failure(let e): self.error = e.localizedDescription
        }
      }
    }
  }
  /// Same, from a time as people write it ("14:05", "2:05 pm", "ontem 9:30"); the core reads it.
  func explain(text: String, minutes: Int = 10) {
    queue.async {
      let result = Result {
        try JSONDecoder().decode(
          HistoryHappened.self, from: Self.call(["op": "happened", "when": text, "minutes": minutes]))
      }
      DispatchQueue.main.async {
        switch result {
        case .success(let h):
          self.happenedAt = Date(timeIntervalSince1970: h.at)
          self.happened = h
        case .failure(let e): self.error = e.localizedDescription
        }
      }
    }
  }
  func explain(_ date: Date, minutes: Int = 10) {
    happenedAt = date
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("history", cost) }
      let result = Result {
        try JSONDecoder().decode(
          HistoryHappened.self,
          from: Self.call(["op": "happened", "at": Int(date.timeIntervalSince1970), "minutes": minutes]))
      }
      DispatchQueue.main.async {
        switch result {
        case .success(let h):
          self.happened = h
        case .failure(let e):
          self.happened = nil
          self.error = e.localizedDescription
        }
      }
    }
  }
  func loadInfo() {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("history", cost) }
      let info = try? JSONDecoder().decode(HistoryInfo.self, from: Self.call(["op": "info"]))
      DispatchQueue.main.async { self.info = info }
    }
  }
  func delete(then: @escaping () -> Void = {}) {
    queue.async {
      let cost = CostMeter.begin()
      defer { CostMeter.end("history", cost) }
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
  // Tour captures start on 1 h so a fresh recording fills the charts.
  @ViewState private var range: HistoryRange = Tour.folder != nil ? .hour : .day
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
          HappenedCard()
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
    let selectedAt: Double?
    if keepSelection, let selected, let series = store.series, series.points.indices.contains(selected) {
      selectedAt = series.points[selected].at
    } else {
      selectedAt = nil
    }
    if !keepSelection { selected = nil }
    store.load(range: range, end: end ?? Date()) { series in
      if let selectedAt, let index = series?.points.firstIndex(where: { $0.at == selectedAt }) {
        selected = index
      } else {
        selected = nil
      }
      loadTop()
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
          p, \.cpu, firstCount: \.cpu_minutes, \.cpu_max, secondCount: nil,
          format: { String(format: "%.0f%%", $0) }, labels: ("", L("pico")), secondIsPeak: true),
        series: [
          ChartSeries(values: p.map(\.cpu_max), color: Tint.cpu.opacity(0.45), name: L("pico"), format: percent),
          ChartSeries(values: p.map(\.cpu), color: Tint.cpu, name: L("média"), format: percent),
        ], times: p.map(\.at), ceiling: 100, legend: [("média", Tint.cpu), ("pico", Tint.cpu.opacity(0.45))],
        selected: $selected)
      HistoryChart(
        title: L("Memória"), symbol: "memorychip", value: summary(
          p, \.memory, firstCount: \.memory_minutes, \.swap, secondCount: nil,
          format: formatBytes, labels: ("", L("swap")), secondIsPeak: true),
        series: [
          ChartSeries(values: p.map(\.memory), color: Tint.memory, name: L("usada"), format: formatBytes),
          ChartSeries(values: p.map(\.swap), color: .orange, name: L("swap"), format: formatBytes),
        ], times: p.map(\.at), ceiling: physical, legend: [("usada", Tint.memory), ("swap", .orange)],
        selected: $selected)
      HistoryChart(
        title: L("Disco"), symbol: "internaldrive", value: summary(
          p, \.disk_read, firstCount: \.disk_read_minutes, \.disk_write, secondCount: \.disk_write_minutes,
          format: formatRate, labels: ("↓", "↑"), secondIsPeak: false),
        series: [
          .diskRead(p.map(\.disk_read)), .diskWrite(p.map(\.disk_write)),
        ], times: p.map(\.at), legend: [("leitura", Tint.diskRead), ("escrita", Tint.diskWrite)], selected: $selected)
      HistoryChart(
        title: L("Rede"), symbol: "arrow.up.arrow.down", value: summary(
          p, \.net_in, firstCount: \.net_in_minutes, \.net_out, secondCount: \.net_out_minutes,
          format: formatRate, labels: ("↓", "↑"), secondIsPeak: false),
        series: [
          .netIn(p.map(\.net_in)), .netOut(p.map(\.net_out)),
        ], times: p.map(\.at), legend: [("entrada", Tint.netIn), ("saída", Tint.netOut)], selected: $selected)
    }
    StateStrips(points: p, selected: $selected)
  }
  /// Values at the selected bucket; otherwise the window's mean of the first series and the
  /// mean (rates) or maximum (peaks, swap) of the second.
  private func summary(
    _ points: [HistoryBucket], _ first: KeyPath<HistoryBucket, Double?>,
    firstCount: KeyPath<HistoryBucket, Int>, _ second: KeyPath<HistoryBucket, Double?>,
    secondCount: KeyPath<HistoryBucket, Int>?, format: @escaping (Double) -> String, labels: (String, String),
    secondIsPeak: Bool
  ) -> String {
    let label = { (text: String, value: Double) in text.isEmpty ? format(value) : text + " " + format(value) }
    if let selected, points.indices.contains(selected) {
      let b = points[selected]
      let parts = [b[keyPath: first].map { label(labels.0, $0) }, b[keyPath: second].map { label(labels.1, $0) }]
      return parts.compactMap { $0 }.joined(separator: " · ").nonEmpty ?? L("Sem dados")
    }
    func mean(_ key: KeyPath<HistoryBucket, Double?>, count: KeyPath<HistoryBucket, Int>) -> Double? {
      var total = 0
      var weightedSum = 0.0
      for point in points {
        let minutes = point[keyPath: count]
        if minutes > 0, let value = point[keyPath: key] {
          total += minutes
          weightedSum += value * Double(minutes)
        }
      }
      return total > 0 ? weightedSum / Double(total) : nil
    }
    guard let a = mean(first, count: firstCount) else { return L("Sem dados") }
    let b = secondIsPeak ? points.compactMap { $0[keyPath: second] }.max() : secondCount.flatMap { mean(second, count: $0) }
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
  let times: [Double]
  var ceiling: Double? = nil
  var legend: [(String, Color)] = []
  @Binding var selected: Int?
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
        .overlay { SelectionLayer(times: times, title: title, selected: $selected) }
    }
  }
}
private struct SelectionLayer: View {
  let times: [Double]
  let title: String
  @Binding var selected: Int?
  private var count: Int { times.count }
  private var selectedTime: String {
    guard let selected, times.indices.contains(selected) else { return L("Nenhum momento selecionado") }
    return Date(timeIntervalSince1970: times[selected]).formatted(date: .complete, time: .shortened)
  }
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
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(L("Selecionar horário de %@", title))
    .accessibilityValue(selectedTime)
    .accessibilityHint(L("Use as setas esquerda e direita ou ações do VoiceOver para mudar o horário"))
    .accessibilityAdjustableAction { direction in
      moveSelection(increment: direction == .increment)
    }
    .focusable()
    .onMoveCommand { direction in
      if direction == .left { moveSelection(increment: false) }
      if direction == .right { moveSelection(increment: true) }
    }
  }
  private func moveSelection(increment: Bool) {
    guard count > 0 else { return }
    let current = selected ?? count - 1
    selected = increment ? min(count - 1, current + 1) : max(0, current - 1)
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
        ).frame(height: 36)
          .overlay { SelectionLayer(times: points.map(\.at), title: L("Pressão %"), selected: $selected) }
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
  static func columnView(
    _ title: String, _ items: [HistoryProcess], tint: Color, value: @escaping (HistoryProcess) -> (String, String)
  ) -> some View {
    DominatorsCard(series: nil, selected: nil, top: nil).column(title, items, tint: tint, value: value)
  }
  let series: HistorySeries?
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
          if let energy = top.energy, !energy.isEmpty {
            column(L("Maior energia"), energy, tint: .yellow) { p in
              (String(format: "%.1f W", p.energy ?? 0), L("%@ min no top", "\(p.minutes)"))
            }
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
  fileprivate func column(
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
/// "What happened at 2:05 pm?": the window around a moment, against the hour before.
private struct HappenedCard: View {
  @ObservedObject var store = HistoryStore.shared
  @ViewState private var when = Date().addingTimeInterval(-3600)
  var body: some View {
    Card {
      CardHeader(title: L("O que aconteceu às…"), symbol: "clock.arrow.circlepath", tint: Tint.brand) {
        DatePicker("", selection: $when, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
          .labelsHidden().datePickerStyle(.compact)
        Button(L("Ver")) { store.explain(when) }.controlSize(.small)
      }
      if let h = store.happened {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(facts(h), id: \.self) { Text($0).font(.callout) }
        }
        if h.minutes > 0 {
          let top = h.top
          HStack(alignment: .top, spacing: 20) {
            DominatorsCard.columnView(L("Maior CPU"), Array(top.cpu.prefix(3)), tint: Tint.cpu) { p in
              (String(format: L("%.1f%%"), p.cpu), L("pico %@", String(format: "%.0f%%", p.cpu_peak)))
            }
            DominatorsCard.columnView(L("Maior memória"), Array(top.memory.prefix(3)), tint: Tint.memory) { p in
              (formatBytes(p.memory), L("%@ min no top", "\(p.minutes)"))
            }
            if let energy = top.energy, !energy.isEmpty {
              DominatorsCard.columnView(L("Maior energia"), Array(energy.prefix(3)), tint: .yellow) { p in
                (String(format: "%.1f W", p.energy ?? 0), L("%@ min no top", "\(p.minutes)"))
              }
            }
          }
        }
      } else {
        Text(L("Escolha um momento para ver CPU, energia, memória e quem dominou nos 10 minutos em volta, comparados com a hora anterior. Também pelo ⌥⌘K, por corescope://happened?at=14:05 e pelo MCP (what_happened)."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .onAppear { if let at = store.happenedAt { when = at } }
    .onChange(of: store.happenedAt) { _, at in if let at { when = at } }
  }
  private func facts(_ h: HistoryHappened) -> [String] {
    let time = { (t: Double) in Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened) }
    let from = Date(timeIntervalSince1970: h.from).formatted(date: .abbreviated, time: .shortened)
    guard h.minutes > 0 else {
      return [L("Nada registrado entre %@ e %@: Mac em repouso, CoreScope fechado ou histórico desligado.", from, time(h.to))]
    }
    var out = [L("%@ minutos registrados entre %@ e %@.", "\(h.minutes)", from, time(h.to))]
    if let cpu = h.cpu, let max = h.cpu_max, let at = h.cpu_max_at {
      let line = L("CPU média de %@ (pico de %@ às %@).", String(format: "%.0f%%", cpu), String(format: "%.0f%%", max), time(at))
      out.append(h.cpu_before.map { line + " " + L("Na hora anterior: %@.", String(format: "%.0f%%", $0)) } ?? line)
    }
    if let power = h.power, let max = h.power_max, let at = h.power_max_at {
      let line = L(
        "Energia dos processos: média de %@ (pico de %@ às %@).", String(format: "%.1f W", power),
        String(format: "%.1f W", max), time(at))
      out.append(h.power_before.map { line + " " + L("Na hora anterior: %@.", String(format: "%.1f W", $0)) } ?? line)
    }
    if let a = h.swap_start, let b = h.swap_end, b - a > 268_435_456 {
      out.append(L("Swap cresceu %@ (para %@).", formatBytes(b - a), formatBytes(b)))
    }
    if let p = h.pressure_max, p > 0 {
      out.append(p >= 2 ? L("Pressão de memória chegou a crítica.") : L("Pressão de memória chegou a atenção."))
    }
    if let t = h.thermal_max, t >= 2 {
      out.append(t >= 3 ? L("Estado térmico chegou a crítico.") : L("Estado térmico chegou a sério (com redução de desempenho)."))
    }
    if let w = h.disk_write_max, w > 50 * 1_048_576 { out.append(L("Gravação em disco chegou a %@.", formatRate(w))) }
    return out
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
