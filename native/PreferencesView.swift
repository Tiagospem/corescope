import ServiceManagement
import SwiftUI

struct PreferencesView: View {
  @ObservedObject var p = Preferences.shared
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var loginEnabled = SMAppService.mainApp.status == .enabled
  @ViewState private var loginError: String?
  var body: some View {
    Form {
      Section("Aparência") {
        Picker("Tema", selection: $p.appearance) {
          ForEach(["Sistema", "Claro", "Escuro"], id: \.self) { Text($0) }
        }
      }
      Section("Coleta") {
        Picker("Atualização", selection: $p.interval) {
          Text("A cada 2 segundos").tag(2.0)
          Text("A cada 3 segundos").tag(3.0)
          Text("A cada 5 segundos").tag(5.0)
          Text("A cada 10 segundos").tag(10.0)
        }.onChange(of: p.interval) { _, _ in monitor.refresh() }
        Text(
          "Um único coletor atende todas as superfícies. Em economia de energia ou sem detalhes visíveis, o intervalo mínimo é 10 s. Pausa durante repouso; deltas são descartados no retorno."
        ).font(.caption).foregroundStyle(.secondary)
        Toggle("Iniciar ao entrar no macOS", isOn: $loginEnabled).onChange(of: loginEnabled) {
          _, enabled in
          do {
            if enabled {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
            loginError = nil
          } catch { loginError = error.localizedDescription }
        }
        if let loginError {
          Text("O macOS recusou a alteração: \(loginError)").font(.caption).foregroundStyle(.orange)
        }
      }
      Section("Barra de menus") {
        Toggle("Formato compacto", isOn: $p.compact)
        ForEach(["CPU", "Memória", "Disco", "Térmico", "Sensor"], id: \.self) { item in
          Toggle(
            item,
            isOn: Binding(
              get: { p.menuItems.contains(item) },
              set: { value in
                if value { p.menuItems.append(item) } else { p.menuItems.removeAll { $0 == item } }
              }))
        }
        ForEach(Array(p.menuItems.enumerated()), id: \.element) { index, item in
          HStack {
            Text("\(index+1). \(item)")
            Spacer()
            Button {
              p.menuItems.swapAt(index, index - 1)
            } label: {
              Image(systemName: "arrow.up")
            }.disabled(index == 0).help("Mover \(item) para a esquerda")
            Button {
              p.menuItems.swapAt(index, index + 1)
            } label: {
              Image(systemName: "arrow.down")
            }.disabled(index == p.menuItems.count - 1).help("Mover \(item) para a direita")
          }
        }
      }
      Section("Painel flutuante") {
        Toggle("Mostrar painel", isOn: $p.panelVisible)
        Toggle("Manter acima das janelas", isOn: $p.panelTop)
        Toggle("Travar posição", isOn: $p.panelLocked)
        LabeledContent("Opacidade") {
          Slider(value: $p.panelOpacity, in: 0.5...1).frame(width: 180)
          Text("\(Int(p.panelOpacity*100))%").monospacedDigit().frame(width: 40)
        }
        LabeledContent("Tamanho") {
          Slider(value: $p.panelScale, in: 0.85...1.4).frame(width: 180)
          Text("\(Int(p.panelScale*100))%").monospacedDigit().frame(width: 40)
        }
        Button("Trazer painel para a tela principal") { FloatingController.shared.recover() }
      }.onChange(of: p.panelVisible) { _, _ in FloatingController.shared.apply() }.onChange(
        of: p.panelTop
      ) { _, _ in FloatingController.shared.apply() }.onChange(of: p.panelLocked) { _, _ in
        FloatingController.shared.apply()
      }.onChange(of: p.panelOpacity) { _, _ in FloatingController.shared.apply() }.onChange(
        of: p.panelScale
      ) { _, _ in FloatingController.shared.apply() }
      Section("Limites e estabilidade") {
        LabeledContent("CPU · atenção") {
          Slider(value: $p.cpuWarning, in: 40...94, step: 1).frame(width: 180)
          Text("\(Int(p.cpuWarning))%").frame(width: 40)
        }
        LabeledContent("CPU · crítico") {
          Slider(value: $p.cpuCritical, in: max(p.cpuWarning + 1, 85)...100, step: 1).frame(
            width: 180)
          Text("\(Int(p.cpuCritical))%").frame(width: 40)
        }
        LabeledContent("Janela sustentada") {
          Slider(value: $p.sustain, in: 5...120, step: 5).frame(width: 180)
          Text("\(Int(p.sustain)) s").frame(width: 40)
        }
        LabeledContent("Espaço livre · atenção abaixo de") {
          Slider(value: $p.diskWarning, in: 6...25, step: 1).frame(width: 150)
          Text("\(Int(p.diskWarning))%").frame(width: 40)
        }
        LabeledContent("Espaço livre · crítico abaixo de") {
          Slider(value: $p.diskCritical, in: 1...min(5, p.diskWarning - 1), step: 1).frame(
            width: 150)
          Text("\(Int(p.diskCritical))%").frame(width: 40)
        }
        Text(
          "Histerese de saída: 5 pontos de CPU e 2 pontos de espaço livre. Memória usa eventos reais do macOS; térmico usa os estados sério/crítico, com estabilização de 5 s. Não há ajuste que transforme ocupação de RAM em pressão."
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section("Privacidade e custo do monitor") {
        Text(
          "Sem rede ou telemetria. Sem argumentos, ambiente, logs de processos ou banco de dados. Preferências e identidades acompanhadas/ignoradas ficam no UserDefaults. Histórico somente em RAM, até 120 amostras / 10 minutos."
        ).font(.callout)
        if let s = monitor.snapshot {
          LabeledContent(
            "Última passagem do coletor", value: String(format: "%.1f ms", s.collector_ms))
          MetricLine(
            title: "Despertares do pacote atribuídos ao app", metric: s.own_wakeups,
            text: s.own_wakeups.value.map { String(format: "%.2f/s", $0) } ?? "—")
          if let own = s.processes.first(where: {
            $0.pid == ProcessInfo.processInfo.processIdentifier
          }) {
            MetricLine(
              title: "CPU do CoreScope (um núcleo)", metric: own.cpu, text: own.cpu.percent)
            MetricLine(title: "Memória do CoreScope · phys_footprint", metric: own.memory)
          }
        }
        Text(
          "Energia em watts/joules e Energy Impact: indisponíveis por API pública integrada. Despertares de pacote não são todos os timers; custo total deve ser medido em uso real. Metas e medições estão no relatório do projeto."
        ).font(.caption).foregroundStyle(.secondary)
        Button("Limpar processos acompanhados e ignorados") {
          p.watched = []
          p.ignored = []
          monitor.refresh()
        }
      }
    }.formStyle(.grouped)
  }
}
