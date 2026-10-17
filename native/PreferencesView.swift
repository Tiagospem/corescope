import ServiceManagement
import SwiftUI

struct PreferencesView: View {
  @ObservedObject var p = Preferences.shared
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var notifier = Notifier.shared
  @ObservedObject var hotkey = Hotkey.shared
  // Read on appear: SMAppService.status is a synchronous XPC call.
  @ViewState private var loginEnabled = false
  @ViewState private var loginError: String?
  var body: some View {
    Form {
      Section(L("Geral")) {
        Picker(L("Tema"), selection: $p.appearance) {
          ForEach(["Sistema", "Claro", "Escuro"], id: \.self) { Text(L($0)) }
        }
        Picker(L("Idioma"), selection: $p.language) {
          Text(L("Sistema")).tag("system")
          Text("Português").tag("pt")
          Text("English").tag("en")
          Text("Español").tag("es")
        }
        Picker(L("Ícone no Dock"), selection: $p.dockMode) {
          Text(L("Sempre")).tag("always")
          Text(L("Só com a janela aberta")).tag("window")
          Text(L("Nunca (só barra de menus)")).tag("never")
        }
        Toggle(L("Confirmar antes de encerrar processos"), isOn: $p.confirmTerminate)
        Text(
          L("Sem confirmação, o botão ✕ envia SIGTERM no primeiro clique. Encerrar árvore e forçar (SIGKILL) sempre pedem confirmação.")
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section(L("Coleta")) {
        Picker(L("Atualização"), selection: $p.interval) {
          Text(L("A cada 2 segundos")).tag(2.0)
          Text(L("A cada 3 segundos")).tag(3.0)
          Text(L("A cada 5 segundos")).tag(5.0)
          Text(L("A cada 10 segundos")).tag(10.0)
        }.onChange(of: p.interval) { _, _ in monitor.refresh() }
        Text(
          L("Um único coletor atende todas as superfícies. Em economia de energia ou sem detalhes visíveis, o intervalo mínimo é 10 s. Pausa durante repouso; deltas são descartados no retorno.")
        ).font(.caption).foregroundStyle(.secondary)
        Toggle(L("Iniciar ao entrar no macOS"), isOn: $loginEnabled).onChange(of: loginEnabled) {
          _, enabled in
          // Ignore the value loaded on appear; act only on a real change.
          guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
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
          Text(L("O macOS recusou a alteração: %@", "\(loginError)")).font(.caption).foregroundStyle(.orange)
        }
      }
      Section(L("Barra de menus")) {
        Toggle(L("Mostrar ícone"), isOn: $p.menuIcon)
        Toggle(L("Formato compacto"), isOn: $p.compact)
        ForEach(["CPU", "Memória", "Disco", "Rede", "Térmico", "Sensor"], id: \.self) { item in
          Toggle(
            L(item),
            isOn: Binding(
              get: { p.menuItems.contains(item) },
              set: { value in
                if value { p.menuItems.append(item) } else { p.menuItems.removeAll { $0 == item } }
              }))
        }
        ForEach(Array(p.menuItems.enumerated()), id: \.element) { index, item in
          HStack {
            Text("\(index+1). \(L(item))")
            Spacer()
            Button {
              p.menuItems.swapAt(index, index - 1)
            } label: {
              Image(systemName: "arrow.up")
            }.disabled(index == 0).help(L("Mover %@ para a esquerda", "\(item)"))
              .accessibilityLabel(L("Mover %@ para a esquerda", "\(item)"))
            Button {
              p.menuItems.swapAt(index, index + 1)
            } label: {
              Image(systemName: "arrow.down")
            }.disabled(index == p.menuItems.count - 1).help(L("Mover %@ para a direita", "\(item)"))
              .accessibilityLabel(L("Mover %@ para a direita", "\(item)"))
          }
        }
      }
      Section(L("Notificações")) {
        Toggle(L("Novo possível órfão"), isOn: notify($p.notifyOrphans))
        Toggle(L("Processo pesado por muito tempo"), isOn: notify($p.notifyHeavy))
        if p.notifyHeavy {
          LabeledContent(L("Memória acima de")) {
            Slider(value: $p.notifyMemoryGB, in: 0.5...16, step: 0.5).frame(width: 180)
            Text(String(format: "%.1f GB", p.notifyMemoryGB)).monospacedDigit().frame(width: 56)
          }
          LabeledContent(L("CPU acima de")) {
            Slider(value: $p.notifyCPU, in: 50...800, step: 10).frame(width: 180)
            Text("\(Int(p.notifyCPU))%").monospacedDigit().frame(width: 56)
          }
          LabeledContent(L("Por pelo menos")) {
            Slider(value: $p.notifySustain, in: 15...600, step: 15).frame(width: 180)
            Text(formatDuration(p.notifySustain)).monospacedDigit().frame(width: 56)
          }
        }
        Toggle(L("Pressão de memória do macOS (atenção/crítica)"), isOn: notify($p.notifyPressure))
        if notifier.denied && p.notificationsEnabled {
          HStack {
            Text(L("O macOS está bloqueando as notificações do CoreScope."))
              .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button(L("Abrir Ajustes do Sistema")) {
              if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
              }
            }
          }
        }
        Text(
          L("Desligadas por padrão e locais. No máximo uma notificação por processo (PID + início) por hora; processos protegidos ou de outros usuários nunca notificam. “Encerrar” envia SIGTERM pelo mesmo caminho do app, que revalida a identidade antes do sinal; nada é encerrado sem o seu clique.")
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section(L("Atalho de porta")) {
        Toggle(L("Atalho global para buscar porta"), isOn: $p.hotkeyEnabled)
        if p.hotkeyEnabled {
          LabeledContent(L("Combinação")) { ShortcutRecorder() }
          if hotkey.failed {
            Text(L("Outro app já usa esta combinação. Escolha outra."))
              .font(.caption).foregroundStyle(.orange)
          }
        }
        Text(
          L("Abre o menu do CoreScope com o campo Porta em foco. Registrado com RegisterEventHotKey: não pede permissão de Acessibilidade e o app recebe só esta combinação.")
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section(L("Agentes")) {
        Toggle(L("Limite do Codex na barra de menus"), isOn: $p.limitsInMenuBar)
        Toggle(L("Limite do Codex no painel flutuante"), isOn: $p.limitsInPanel)
        Toggle(L("Limites na visão geral"), isOn: $p.limitsInOverview)
        Text(
          L("O limite do Codex vem dos eventos rate_limits que o próprio Codex grava em ~/.codex/sessions (somente leitura local). O Claude Code não grava o limite semanal em disco; sessões do Claude vêm de ~/.claude/sessions.")
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section(L("Painel flutuante")) {
        Toggle(L("Mostrar painel"), isOn: $p.panelVisible)
        Picker(L("Layout"), selection: $p.panelMode) {
          Text(L("Compacto")).tag("compact")
          Text(L("Padrão")).tag("standard")
          Text(L("Detalhado · com processos")).tag("detailed")
        }
        Picker(L("Tamanho"), selection: $p.panelScale) {
          Text(L("Pequeno")).tag(0.88)
          Text(L("Médio")).tag(1.0)
          Text(L("Grande")).tag(1.18)
        }
        LabeledContent(L("Opacidade do fundo")) {
          Slider(value: $p.panelOpacity, in: 0.5...1).frame(width: 180)
          Text("\(Int(p.panelOpacity*100))%").monospacedDigit().frame(width: 40)
        }
        Toggle(L("Manter acima das janelas"), isOn: $p.panelTop)
        Toggle(L("Travar posição"), isOn: $p.panelLocked)
        Toggle(L("Mostrar rede"), isOn: $p.panelNetwork)
        Text(L("Todas essas opções também ficam no próprio painel: botão ⋯ ou clique com o botão direito."))
          .font(.caption).foregroundStyle(.secondary)
        Button(L("Trazer painel para a tela principal")) { FloatingController.shared.recover() }
      }
      Section(L("Limites e estabilidade")) {
        LabeledContent(L("CPU · atenção")) {
          Slider(value: $p.cpuWarning, in: 40...94, step: 1).frame(width: 180)
          Text("\(Int(p.cpuWarning))%").frame(width: 40)
        }
        LabeledContent(L("CPU · crítico")) {
          Slider(value: $p.cpuCritical, in: max(p.cpuWarning + 1, 85)...100, step: 1).frame(
            width: 180)
          Text("\(Int(p.cpuCritical))%").frame(width: 40)
        }
        LabeledContent(L("Janela sustentada")) {
          Slider(value: $p.sustain, in: 5...120, step: 5).frame(width: 180)
          Text(L("%@ s", "\(Int(p.sustain))")).frame(width: 40)
        }
        LabeledContent(L("Espaço livre · atenção abaixo de")) {
          Slider(value: $p.diskWarning, in: 6...25, step: 1).frame(width: 150)
          Text("\(Int(p.diskWarning))%").frame(width: 40)
        }
        LabeledContent(L("Espaço livre · crítico abaixo de")) {
          Slider(value: $p.diskCritical, in: 1...min(5, p.diskWarning - 1), step: 1).frame(
            width: 150)
          Text("\(Int(p.diskCritical))%").frame(width: 40)
        }
        Text(
          L("Histerese de saída: 5 pontos de CPU e 2 pontos de espaço livre. Memória usa eventos reais do macOS; térmico usa os estados sério/crítico, com estabilização de 5 s. Não há ajuste que transforme ocupação de RAM em pressão.")
        ).font(.caption).foregroundStyle(.secondary)
      }
      Section(L("Privacidade e custo do monitor")) {
        Text(
          L("Sem rede ou telemetria. Sem argumentos, ambiente, logs de processos ou banco de dados. Preferências e identidades acompanhadas/ignoradas ficam no UserDefaults. Histórico somente em RAM, até 120 amostras / 10 minutos.")
        ).font(.callout)
        if let s = monitor.snapshot {
          LabeledContent(
            L("Última passagem do coletor"), value: String(format: "%.1f ms", s.collector_ms))
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
          L("Energia em watts/joules e Energy Impact: indisponíveis por API pública integrada. Despertares de pacote não são todos os timers; custo total deve ser medido em uso real. Metas e medições estão no relatório do projeto.")
        ).font(.caption).foregroundStyle(.secondary)
        Button(L("Limpar processos acompanhados e ignorados")) {
          p.watched = []
          p.ignored = []
          monitor.refresh()
        }
      }
    }.formStyle(.grouped)
      .onAppear { if p.notificationsEnabled { notifier.activate() } }
      .onAppear { loginEnabled = SMAppService.mainApp.status == .enabled }
  }
  /// Turning a notification kind on asks macOS for permission the first time.
  private func notify(_ binding: Binding<Bool>) -> Binding<Bool> {
    Binding(
      get: { binding.wrappedValue },
      set: { value in
        binding.wrappedValue = value
        if value { notifier.activate() }
      })
  }
}
