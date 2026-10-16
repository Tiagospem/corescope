import AppKit
import SwiftUI

struct Sparkline: View {
  let values: [Double?]
  var ceiling: Double = 100
  var color: Color = .accentColor
  var body: some View {
    Canvas { context, size in
      let valid = values.compactMap { $0 }
      let maxValue = max(ceiling, valid.max() ?? 1)
      var path = Path()
      var connected = false
      for (index, value) in values.enumerated() {
        guard let value else {
          connected = false
          continue
        }
        let point = CGPoint(
          x: Double(index) / Double(max(1, values.count - 1)) * size.width,
          y: size.height - 3 - (value / maxValue) * (size.height - 6))
        if connected {
          path.addLine(to: point)
        } else {
          path.move(to: point)
          connected = true
        }
      }
      context.stroke(
        path, with: .color(color),
        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
    }.accessibilityLabel(
      "Histórico de \(values.count) amostras; último valor \(values.last.flatMap{$0}.map{String(format:"%.1f",$0)} ?? "indisponível")"
    )
  }
}
struct MetricLine: View {
  let title: String
  let metric: Metric
  var text: String? = nil
  var body: some View {
    HStack {
      Text(title)
      Spacer()
      Text(text ?? metric.bytes).monospacedDigit().foregroundStyle(.secondary)
    }.help(metric.explanation).accessibilityElement(children: .combine)
  }
}
struct SectionHeading: View {
  let title: String
  var subtitle: String? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.title2.weight(.semibold))
      if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
    }
  }
}
struct StateFooter: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: monitor.stale ? "pause.circle" : "circle.fill").font(
        .system(size: monitor.stale ? 12 : 5))
      Text(monitor.stale ? "Leituras pausadas ou antigas" : "Coleta local")
      Spacer()
      if let s = monitor.snapshot {
        Text(Date(timeIntervalSince1970: s.at), style: .time)
        Text("· \(s.processes.count) processos")
      }
    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
      .background(.bar)
  }
}
enum Page: String, CaseIterable, Identifiable {
  case overview = "Visão geral"
  case processes = "Processos"
  case storage = "Armazenamento"
  case sensors = "Sensores"
  case settings = "Ajustes"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .overview: "waveform.path.ecg"
    case .processes: "list.bullet.rectangle"
    case .storage: "externaldrive"
    case .sensors: "thermometer.medium"
    case .settings: "slider.horizontal.3"
    }
  }
}
struct MainView: View {
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var page: Page? = .overview
  var body: some View {
    NavigationSplitView {
      List(Page.allCases, selection: $page) { item in
        Label(item.rawValue, systemImage: item.icon).tag(item).padding(.vertical, 4)
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 6) {
          Label("CoreScope", systemImage: "waveform.path.ecg").font(.headline)
          Text("Seu Mac, em perspectiva.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
      }
    } detail: {
      VStack(spacing: 0) {
        if monitor.stale, monitor.snapshot != nil {
          Label(
            monitor.sleeping
              ? "Em repouso · dados anteriores"
              : monitor.manuallyPaused
                ? "Coleta pausada · dados anteriores" : "Dados antigos · aguardando coleta",
            systemImage: "clock.badge.exclamationmark"
          ).font(.callout).frame(maxWidth: .infinity).padding(8).background(
            Color.orange.opacity(0.12))
        }
        if let error = monitor.error { Text(error).foregroundStyle(.red).padding() }
        Group {
          switch page ?? .overview {
          case .overview: OverviewView()
          case .processes: ProcessesView()
          case .storage: StorageView()
          case .sensors: SensorsView()
          case .settings: PreferencesView()
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        StateFooter()
      }.navigationTitle(page?.rawValue ?? "CoreScope")
        .toolbar {
          ToolbarItemGroup {
            Button {
              Preferences.shared.panelVisible.toggle()
              FloatingController.shared.apply()
            } label: {
              Image(systemName: "pip")
            }.help("Mostrar ou ocultar painel flutuante")
            Button {
              monitor.setPaused(!monitor.manuallyPaused)
            } label: {
              Image(systemName: monitor.manuallyPaused ? "play" : "pause")
            }.help(monitor.manuallyPaused ? "Retomar coleta" : "Pausar coleta")
            Button {
              monitor.refresh()
            } label: {
              Image(systemName: "arrow.clockwise")
            }.keyboardShortcut("r", modifiers: .command).help("Atualizar agora")
          }
        }
    }.frame(minWidth: 850, minHeight: 590).onReceive(
      NotificationCenter.default.publisher(for: Notification.Name("CoreScope.navigate"))
    ) { event in if let selected = event.object as? Page { page = selected } }
  }
}
struct OverviewView: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        SectionHeading(
          title: "O que merece atenção", subtitle: "Sinais do sistema, contexto para decidir.")
        if let s = monitor.snapshot {
          if let d = s.diagnostics.first {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: d.symbol).font(.title2).foregroundStyle(d.color)
              VStack(alignment: .leading, spacing: 6) {
                Text(
                  s.diagnostics.allSatisfy { $0.level == 0 }
                    ? "Nenhum alerta sustentado nos sinais disponíveis" : d.title
                ).font(.headline)
                Text(
                  s.diagnostics.allSatisfy { $0.level == 0 }
                    ? "Consulte os sinais abaixo. Ausência de alerta não exclui lentidão nem comprova que todos os sensores estão disponíveis."
                    : d.detail
                ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
              .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
          }
          HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
              Label("CPU total", systemImage: "cpu").font(.headline)
              HStack(alignment: .firstTextBaseline) {
                Text(s.cpu.percent).font(.system(size: 30, weight: .medium, design: .rounded))
                  .monospacedDigit()
                Text("de \(s.cores) núcleos lógicos").font(.caption).foregroundStyle(.secondary)
              }
              Sparkline(values: s.history.map(\.cpu)).frame(height: 62)
              Text("0–100% · até 10 min de histórico").font(.caption).foregroundStyle(.secondary)
            }.help(s.cpu.explanation)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
              Label("Memória", systemImage: "memorychip").font(.headline)
              HStack(alignment: .firstTextBaseline) {
                Text(s.memorySummary).font(.system(size: 30, weight: .medium, design: .rounded))
                  .monospacedDigit()
                Text("de \(s.physical.bytes)").font(.caption).foregroundStyle(.secondary)
              }
              Sparkline(
                values: s.history.map(\.memory), ceiling: s.physical.value ?? 1, color: .teal
              ).frame(height: 62)
              Text("Ativa + wired + compressor · não é pressão").font(.caption).foregroundStyle(
                .secondary)
            }
          }.frame(height: 155)
          Divider()
          VStack(spacing: 12) {
            MetricLine(title: "Compressor físico", metric: s.compressed)
            MetricLine(title: "Swap ocupado", metric: s.swap)
            MetricLine(title: "Estado térmico do macOS", metric: s.thermal, text: s.thermalLabel)
            MetricLine(
              title: "Pressão de memória · último evento", metric: s.pressure,
              text: s.pressure.value.map {
                ["Normal", "Atenção", "Crítica"][min(2, max(0, Int($0)))]
              } ?? "Aguardando evento do sistema")
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("Maior consumo de CPU agora").font(.headline)
            ForEach(Array(s.processes.prefix(5))) { p in
              HStack {
                Text(p.name).lineLimit(1)
                Text("\(p.pid)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(p.memory.bytes).foregroundStyle(.secondary).frame(
                  width: 85, alignment: .trailing)
                Text(p.cpu.percent).monospacedDigit().frame(width: 70, alignment: .trailing)
              }.font(.callout)
            }
          }
          DisclosureGroup("Como interpretar os sinais") {
            VStack(alignment: .leading, spacing: 14) {
              ForEach(s.diagnostics) { d in
                VStack(alignment: .leading, spacing: 5) {
                  Label(d.title, systemImage: d.symbol).font(.headline)
                  Text(d.detail).foregroundStyle(.secondary)
                }
              }
            }.padding(.top, 12)
          }
        } else {
          ProgressView("Lendo métricas do macOS…").frame(maxWidth: .infinity, minHeight: 280)
        }
      }.padding(26)
    }
  }
}
struct ProcessesView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var query = ""
  @ViewState private var filter = "Todos"
  @ViewState private var selection: String?
  @ViewState private var details: ProcessItem?
  @ViewState private var sort = [KeyPathComparator(\ProcessItem.cpuValue, order: .reverse)]
  @ViewState private var tree = false
  @ViewState private var minCPU = ""
  @ViewState private var minMemory = ""
  @ViewState private var minThreads = ""
  private var rows: [ProcessItem] {
    var rows = (monitor.snapshot?.processes ?? []).filter { p in
      let matches =
        query.isEmpty
        || "\(p.name) \(p.pid) \(p.ppid) \(p.user) \(p.uid)".localizedCaseInsensitiveContains(query)
      let mode =
        filter == "Todos" || filter == "Meus" && p.uid == monitor.snapshot?.current_uid
        || filter == "Revisar" && p.candidate != nil
        || filter == "Acompanhados" && prefs.watched.contains(p.id)
      return matches && mode && (minCPU.isEmpty || p.cpuValue >= (Double(minCPU) ?? .infinity))
        && (minMemory.isEmpty || p.memoryValue >= (Double(minMemory) ?? .infinity) * 1_048_576)
        && (minThreads.isEmpty || p.threadValue >= (Double(minThreads) ?? .infinity))
    }.sorted(using: sort)
    if tree {
      let ids = Set(rows.map(\.pid))
      let all = rows
      let children = Dictionary(grouping: all, by: \.ppid)
      var result: [ProcessItem] = []
      var visited = Set<Int32>()
      func visit(_ p: ProcessItem) {
        guard visited.insert(p.pid).inserted else { return }
        result.append(p)
        for c in children[p.pid] ?? [] { visit(c) }
      }
      for p in all where !ids.contains(p.ppid) { visit(p) }
      for p in all { visit(p) }
      rows = result
    }
    return rows
  }
  private func treeDepths() -> [Int32: Int] {
    guard tree else { return [:] }
    let all = monitor.snapshot?.processes ?? []
    let parents = Dictionary(uniqueKeysWithValues: all.map { ($0.pid, $0.ppid) })
    var result: [Int32: Int] = [:]
    for p in all {
      var current = p.ppid
      var seen = Set<Int32>()
      var depth = 0
      while let parent = parents[current], depth < 6, seen.insert(current).inserted {
        depth += 1
        current = parent
      }
      result[p.pid] = depth
    }
    return result
  }
  var body: some View {
    let rows = self.rows
    let depths = treeDepths()
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(
        title: "Explorar processos",
        subtitle: "CPU por núcleo: 100% = um núcleo ocupado. Memória = phys_footprint.")
      HStack {
        TextField("Buscar nome, PID ou usuário", text: $query).textFieldStyle(.roundedBorder)
        Picker("Filtro", selection: $filter) {
          ForEach(["Todos", "Meus", "Revisar", "Acompanhados"], id: \.self) { Text($0) }
        }.labelsHidden().frame(width: 145)
        Toggle("Árvore", isOn: $tree).toggleStyle(.checkbox)
      }
      HStack(spacing: 12) {
        Text("Mínimos").foregroundStyle(.secondary)
        TextField("CPU %", text: $minCPU).frame(width: 75)
        TextField("Mem. MiB", text: $minMemory).frame(width: 85)
        TextField("Threads", text: $minThreads).frame(width: 75)
        Spacer()
        Text("\(rows.count) resultados").foregroundStyle(.secondary)
      }.font(.caption).textFieldStyle(.roundedBorder)
      if filter == "Revisar" {
        Text(
          "Candidatos para revisão manual, não processos comprovadamente abandonados. Só aparecem após mudança de pai observada e sinais adicionais."
        ).font(.callout).foregroundStyle(.secondary)
      }
      Table(rows, selection: $selection, sortOrder: $sort) {
        TableColumn("Processo", value: \.name) { p in
          HStack(spacing: 5) {
            if prefs.watched.contains(p.id) {
              Image(systemName: "star.fill").foregroundStyle(.secondary)
            }
            Text(p.name).lineLimit(1)
          }.padding(.leading, CGFloat(depths[p.pid] ?? 0) * 10)
        }.width(min: 130, ideal: 200)
        TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }.width(55)
        TableColumn("Usuário", value: \.user).width(min: 65, ideal: 85)
        TableColumn("CPU", value: \.cpuValue) { Text($0.cpu.percent).monospacedDigit() }.width(65)
        TableColumn("Memória", value: \.memoryValue) { Text($0.memory.bytes).monospacedDigit() }
          .width(80)
        TableColumn("Threads", value: \.threadValue) {
          Text($0.threads.value.map { String(Int($0)) } ?? "—").monospacedDigit()
        }.width(60)
      }.contextMenu(forSelectionType: String.self) { ids in
        if let id = ids.first, let p = rows.first(where: { $0.id == id }) {
          Button("Examinar processo") { details = p }
          Button(prefs.watched.contains(id) ? "Parar de acompanhar" : "Acompanhar") {
            prefs.toggleWatch(id)
          }
        }
      } primaryAction: { ids in
        if let id = ids.first { details = rows.first { $0.id == id } }
      }
      HStack {
        if let p = rows.first(where: { $0.id == selection }) {
          Text("Pai: \(p.ppid)").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Examinar \(p.name)") { details = p }.keyboardShortcut(.return, modifiers: [])
        } else {
          Text(
            rows.isEmpty
              ? "Nenhum processo corresponde aos filtros."
              : "Selecione um processo para examinar origem, histórico e ações."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.frame(height: 30)
    }.padding(22).sheet(item: $details) { p in ProcessDetail(process: p) }
  }
}
struct ProcessDetail: View {
  let process: ProcessItem
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @Environment(\.dismiss) var dismiss
  @ViewState private var confirmation = false
  @ViewState private var force = false
  @ViewState private var targets: [ProcessItem] = []
  var current: ProcessItem { monitor.snapshot?.processes.first { $0.id == process.id } ?? process }
  var exists: Bool { monitor.snapshot?.processes.contains { $0.id == process.id } ?? false }
  func prepare(force: Bool, tree: Bool) {
    self.force = force
    let p = current
    let all = monitor.snapshot?.processes ?? []
    let ids = tree ? descendantIDs(root: p.pid, nodes: all.map { ($0.pid, $0.ppid) }) : [p.pid]
    targets = ids.compactMap { id in all.first { $0.pid == id } }
    confirmation = !targets.isEmpty
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "app.dashed").font(.largeTitle).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(current.name).font(.title2.bold())
          Text("PID \(current.pid) · \(current.user) · pai \(current.ppid)").foregroundStyle(
            .secondary)
        }
        Spacer()
        Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if !exists {
        Label("Processo encerrado · últimas leituras", systemImage: "clock").foregroundStyle(
          .orange)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 15) {
          Text(current.path.isEmpty ? "Executável sem permissão ou indisponível" : current.path)
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(
              horizontal: false, vertical: true)
          Text(
            "Início: \(current.startDate.formatted()) · duração: \(max(0,Int(Date().timeIntervalSince(current.startDate)/60))) min"
          ).font(.callout)
          if let a = current.attribution { Label(a, systemImage: "link").font(.callout) }
          Text(
            "Projeto/agente: sem atribuição comprovada. Argumentos e ambiente não são coletados."
          ).font(.caption).foregroundStyle(.secondary)
          Divider()
          MetricLine(title: "CPU · 100% por núcleo", metric: current.cpu, text: current.cpu.percent)
          MetricLine(title: "Memória física atribuída (phys_footprint)", metric: current.memory)
          MetricLine(title: "Páginas residentes (resident_size)", metric: current.resident)
          MetricLine(
            title: "Threads · quantidade não é diagnóstico", metric: current.threads,
            text: current.threads.value.map { String(Int($0)) } ?? "—")
          MetricLine(title: "Leitura atribuída", metric: current.read, text: current.read.rate)
          MetricLine(title: "Escrita atribuída", metric: current.write, text: current.write.rate)
          if current.high_cpu_seconds >= 20 {
            Text(
              "Este processo mantém CPU ≥ 80% de um núcleo há \(Int(current.high_cpu_seconds)) s. Isso não comprova que causou lentidão."
            ).font(.callout)
          }
          if let reason = current.candidate {
            Label("Revisão manual", systemImage: "eye").font(.headline)
            Text(reason).font(.callout)
            Button("Ignorar esta identidade") {
              prefs.ignored.append(current.id)
              monitor.refresh()
            }
          }
          HStack {
            Button(
              prefs.watched.contains(current.id)
                ? "Parar de acompanhar" : "Acompanhar CPU e memória"
            ) {
              prefs.toggleWatch(current.id)
              monitor.refresh()
            }.disabled(!prefs.watched.contains(current.id) && prefs.watched.count >= 12)
            Text("Até 12 processos · 120 amostras / 10 min").font(.caption).foregroundStyle(
              .secondary)
          }
          if !current.history.isEmpty {
            Sparkline(values: current.history.map(\.cpu)).frame(height: 55)
            Text("CPU por núcleo · escala ajustada ao pico").font(.caption).foregroundStyle(
              .secondary)
            Sparkline(values: current.history.map(\.memory), ceiling: 1, color: .teal).frame(
              height: 45)
            Text("Memória phys_footprint").font(.caption).foregroundStyle(.secondary)
          }
          if !current.eligible { Label(current.blocked, systemImage: "lock").font(.callout) }
          if let result = monitor.actionResults {
            Text(result).font(.callout).textSelection(.enabled)
          }
        }
      }
      Divider()
      HStack {
        Button("Encerrar…") { prepare(force: false, tree: false) }
        Button("Encerrar árvore…") { prepare(force: false, tree: true) }
        Spacer()
        Button("Encerrar à força…", role: .destructive) { prepare(force: true, tree: false) }
      }.disabled(!current.eligible || !exists || monitor.stale)
    }.padding(24).frame(width: 650, height: 650).sheet(isPresented: $confirmation) {
      VStack(alignment: .leading, spacing: 18) {
        Text(
          force
            ? "Encerrar à força?"
            : targets.count > 1 ? "Encerrar estes processos?" : "Solicitar encerramento?"
        ).font(.title2.bold())
        Text(
          force
            ? "SIGKILL não permite salvar trabalho. Dados não salvos podem ser perdidos."
            : "SIGTERM pede que o processo encerre. Builds, agentes e tarefas em andamento podem ser interrompidos; o processo pode ignorar o pedido."
        ).fixedSize(horizontal: false, vertical: true)
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ForEach(targets) { p in
              VStack(alignment: .leading, spacing: 4) {
                Text("\(p.name) · PID \(p.pid)").font(.headline)
                Text(p.path).font(.caption).textSelection(.enabled)
                if !p.eligible { Text(p.blocked).foregroundStyle(.red) }
              }
            }
          }
        }.frame(maxHeight: 220)
        Text(
          "A lista acima é fixa. Cada identidade será revalidada imediatamente antes do sinal. Nenhum outro descendente será incluído."
        ).font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Cancelar") { confirmation = false }.keyboardShortcut(.cancelAction)
          Spacer()
          Button(force ? "Confirmar SIGKILL" : "Confirmar SIGTERM", role: .destructive) {
            monitor.signal(targets, force: force)
            confirmation = false
          }.disabled(targets.contains { !$0.eligible })
        }
      }.padding(24).frame(width: 550)
    }
  }
}
struct StorageView: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SectionHeading(
          title: "Armazenamento e I/O",
          subtitle:
            "Capacidade por volume. Atividade por dispositivo, sem contagem duplicada de volumes.")
        if let s = monitor.snapshot {
          Text("Dispositivos · IOBlockStorageDriver").font(.headline)
          if s.disks.isEmpty {
            Text(
              "Contadores físicos \(s.disk_state == "unsupported" ? "não suportados" : "temporariamente indisponíveis")."
            ).foregroundStyle(.secondary)
          }
          ForEach(s.disks) { d in
            HStack(alignment: .top) {
              Image(systemName: "externaldrive").font(.title2).foregroundStyle(.secondary)
              VStack(alignment: .leading, spacing: 6) {
                Text(d.name).font(.headline)
                Text("Registro IOKit \(d.id)").font(.caption).foregroundStyle(.secondary)
                Text(d.temperature.temperature).font(.callout).help(d.temperature.explanation)
                HStack(spacing: 24) {
                  Label(d.read.rate, systemImage: "arrow.down").help(d.read.explanation)
                  Label(d.write.rate, systemImage: "arrow.up").help(d.write.explanation)
                }.monospacedDigit()
              }
              Spacer()
            }.padding(.vertical, 6)
          }
          Text(
            "Os contadores representam dispositivos/driver do IOKit, não cada volume APFS. O macOS pode omitir alguns dispositivos. Não há medida confiável de saturação ou latência nesta versão."
          ).font(.callout).foregroundStyle(.secondary)
          Divider()
          Text("Volumes locais montados").font(.headline)
          if s.volumes.isEmpty { Text("Inventário temporariamente indisponível.") }
          ForEach(Array(s.volumes.enumerated()), id: \.offset) { _, v in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(v.mount).font(.headline).textSelection(.enabled)
                Spacer()
                Text(v.kind.uppercased()).font(.caption).foregroundStyle(.secondary)
              }
              Text(v.id).font(.caption).foregroundStyle(.secondary)
              if let total = v.total.value, let available = v.available.value, total > 0 {
                ProgressView(value: max(0, total - available), total: total).tint(
                  available / total < 0.1 ? .orange : .accentColor)
              }
              MetricLine(
                title: "Disponível / capacidade", metric: v.available,
                text: "\(v.available.bytes) / \(v.total.bytes)")
            }.padding(.vertical, 8)
          }
          Text(
            "Inventário a cada 30 s, com dados em cache do kernel. Capacidades de volumes APFS podem ser compartilhadas: não devem ser somadas. Montagens e dispositivos removidos desaparecem na próxima leitura."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.padding(26)
    }
  }
}
struct SensorsView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        SectionHeading(
          title: "Sensores disponíveis",
          subtitle: "Só leituras identificadas. Estado térmico não é temperatura.")
        if let s = monitor.snapshot {
          HStack {
            Image(systemName: "thermometer.medium").font(.largeTitle).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
              Text("Estado térmico do macOS").font(.headline)
              Text(s.thermalLabel).font(.title2)
            }
            Spacer()
          }.help(s.thermal.explanation)
          Toggle("Exibir estado térmico no painel", isOn: $prefs.thermalInPanel)
          Divider()
          Label("Temperatura de CPU / SoC: não suportado", systemImage: "minus.circle").font(
            .headline)
          Text(
            "Nenhuma fonte pública de temperatura em °C foi integrada para este hardware. APIs privadas de SMC/HID e sensores experimentais não são usados."
          ).foregroundStyle(.secondary)
          ForEach(s.disks) { d in
            VStack(alignment: .leading, spacing: 6) {
              Text(d.name).font(.headline)
              Text("Temperatura composta NVMe: \(d.temperature.temperature)").foregroundStyle(
                .secondary)
              Text(d.temperature.explanation).font(.caption).foregroundStyle(.secondary)
            }
          }
          Picker("Sensor no menu e painel", selection: $prefs.selectedSensor) {
            Text("Nenhum").tag("")
            ForEach(s.disks.filter { $0.temperature.value != nil }) { d in Text(d.name).tag(d.id) }
          }
          Text(
            "Leitura pública NVMe SMART a cada 30 s, associada ao dispositivo físico. Temperatura composta do controlador; não identifica cada chip ou adaptador. Nenhum comando SMART de ativação ou escrita é enviado."
          ).font(.callout).foregroundStyle(.secondary)
          Text(
            "SSD interno, dispositivos USB/Thunderbolt e seus adaptadores não têm suporte universal a SMART ou temperatura. A ausência de leitura não significa temperatura normal. Nenhuma permissão adicional é solicitada."
          ).font(.callout).foregroundStyle(.secondary)
        }
      }.padding(26)
    }
  }
}
