import ServiceManagement
import SwiftUI

/// Not observing the Monitor on purpose: the Form would rebuild on every sample (measured at
/// ~8 % of a core more); what changes per sample lives in small subviews.
struct PreferencesView: View {
  @ObservedObject var p = Preferences.shared
  @ObservedObject var agents = AgentStore.shared
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
      UpdateSettings()
      Section(L("Coleta")) {
        Picker(L("Atualização"), selection: $p.interval) {
          Text(L("A cada 2 segundos")).tag(2.0)
          Text(L("A cada 3 segundos")).tag(3.0)
          Text(L("A cada 5 segundos")).tag(5.0)
          Text(L("A cada 10 segundos")).tag(10.0)
        }.onChange(of: p.interval) { _, _ in Monitor.shared.refresh() }
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
        Toggle(L("Agente parece travado"), isOn: notify($p.notifyStalls))
        LabeledContent(L("Travado após")) {
          Picker("", selection: $p.stallMinutes) {
            ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text(L("%@ min sem atividade", "\(Int($0))")).tag($0) }
          }.labelsHidden().frame(width: 200)
        }
        Text(
          L("Uma sessão ocupada (Claude Code, Codex) que não escreve na própria transcrição por esse tempo. Se um comando iniciado nesta vez está usando CPU, é só um comando longo; se está parado, pode estar esperando uma entrada. Vale também para o selo na página Agentes. Lê apenas datas de modificação, nunca o conteúdo.")
        ).font(.caption).foregroundStyle(.secondary)
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
      CommandLineSettings()
      MCPSettings()
      Section(L("Agentes")) {
        Toggle(L("Ler o limite atual pelo Codex"), isOn: $p.codexLiveLimits)
          .onChange(of: p.codexLiveLimits) { _, on in if on { AgentStore.shared.refreshCodexLive() } }
        Text(
          L("O Codex não grava mais o limite em disco. Com isto ligado, o CoreScope executa o app-server do próprio Codex a cada 5 minutos e pede o limite; o Codex consulta a OpenAI com o login dele. Nenhuma credencial é lida pelo CoreScope.")
        ).font(.caption).foregroundStyle(.secondary)
        Toggle(L("Limites na barra de menus"), isOn: $p.limitsInMenuBar)
        Toggle(L("Limites no painel flutuante"), isOn: $p.limitsInPanel)
        Toggle(L("Limites na visão geral"), isOn: $p.limitsInOverview)
        Text(
          L("O limite do Codex vem dos eventos rate_limits que o próprio Codex grava em ~/.codex/sessions (somente leitura local). Sessões do Claude vêm de ~/.claude/sessions.")
        ).font(.caption).foregroundStyle(.secondary)
        Toggle(L("Ler limite do Claude pelo status line"), isOn: $p.claudeLimits)
        Text(
          L("Desligado por padrão. Ao ligar, o CoreScope instala um comando de status line em ~/.claude/settings.json (com backup; se você já tiver um status line, nada é trocado sem sua confirmação). A cada resposta, o próprio Claude Code passa o uso do plano a esse comando, que grava só rate_limits em ~/Library/Application Support/CoreScope. Sem Keychain, sem credenciais, sem rede. Desligar restaura o statusLine anterior. Só planos Pro e Max informam o limite.")
        ).font(.caption).foregroundStyle(.secondary)
        if p.claudeLimits || agents.claudeError != nil { ClaudeLinkStatus() }
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
        Toggle(L("Mostrar agentes"), isOn: $p.panelAgents)
          .help(L("Sessões do Claude Code, Codex e outros agentes: projeto, se está trabalhando, aguardando ou parece travada, e os limites de uso."))
        Toggle(L("Mostrar máquinas remotas"), isOn: $p.panelMachines)
        if p.panelMachines { PanelMachinesPicker() }
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
      HistorySettings()
      Section(L("Custo do CoreScope")) { SelfCostView() }
      Section(L("Privacidade e custo do monitor")) {
        Text(
          L("Sem rede ou telemetria. Sem argumentos, ambiente ou logs de processos. Preferências e identidades acompanhadas/ignoradas ficam no UserDefaults. Gráficos ao vivo em RAM (120 amostras / 10 minutos); o histórico persistente é opcional e local.")
        ).font(.callout)
        CollectorFigures()
        Text(
          L("Energia em watts/joules e Energy Impact: indisponíveis por API pública integrada. Despertares de pacote não são todos os timers; custo total deve ser medido em uso real. Metas e medições estão no relatório do projeto.")
        ).font(.caption).foregroundStyle(.secondary)
        Button(L("Limpar processos acompanhados e ignorados")) {
          p.watched = []
          p.ignored = []
          Monitor.shared.refresh()
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

/// Collector timing and wakeups, the only per-sample lines in Settings.
private struct CollectorFigures: View {
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    if let s = monitor.snapshot {
      LabeledContent(L("Última passagem do coletor"), value: String(format: "%.1f ms", s.collector_ms))
      MetricLine(
        title: "Despertares do pacote atribuídos ao app", metric: s.own_wakeups,
        text: s.own_wakeups.value.map { String(format: "%.2f/s", $0) } ?? "—")
    }
  }
}
/// Where CoreScope's Claude status line stands, with the explicit step to chain an existing one.
private struct ClaudeLinkStatus: View {
  @ObservedObject var agents = AgentStore.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let error = agents.claudeError {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      switch agents.claudeLink {
      case .installed?:
        Label(L("Status line do CoreScope instalado."), systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .chained?:
        Label(
          L("Encadeado com o seu status line; a saída dele continua a mesma."), systemImage: "link.circle.fill"
        ).foregroundStyle(.green)
      case .foreign(let command)?:
        Text(L("Você já tem um status line, por isso nada foi alterado:"))
        Text(command.isEmpty ? "statusLine" : command).font(.system(.caption, design: .monospaced))
          .lineLimit(3).textSelection(.enabled)
        if !command.isEmpty {
          Button(L("Encadear com o status line atual")) { agents.setClaudeLimits(true, chain: true) }
            .help(L("Coloca o comando do CoreScope antes do seu; a saída do seu status line não muda."))
        }
        Text(L("Ou edite à mão: comece o comando com"))
        Text(ClaudeStatusLine.command(script: ClaudeLimitsBridge.script.path) + " --record | ")
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      case .absent?, nil:
        EmptyView()
      }
    }.font(.caption)
  }
}

/// Opt-in persistent history: toggle, retention, size and deletion.
private struct HistorySettings: View {
  @ObservedObject var p = Preferences.shared
  @ObservedObject var store = HistoryStore.shared
  @ObservedObject var monitor = Monitor.shared
  @ViewState private var confirmDelete = false
  var body: some View {
    Section(L("Histórico")) {
      Toggle(L("Gravar histórico neste Mac"), isOn: $p.historyEnabled)
      Picker(L("Manter por"), selection: $p.historyRetention) {
        Text(L("1 dia")).tag(1)
        Text(L("7 dias")).tag(7)
        Text(L("30 dias")).tag(30)
      }.disabled(!p.historyEnabled)
      Text(
        L("Um resumo por minuto (CPU, memória, swap, disco, rede, térmico e os 10 processos com mais CPU e memória: nome, executável, diretório e origem; nunca argumentos ou ambiente), gravado em uma transação por minuto em ~/Library/Application Support/CoreScope/history.sqlite. Dados além da retenção são apagados automaticamente. Desligar interrompe a gravação; o que já foi salvo fica até você apagar.")
      ).font(.caption).foregroundStyle(.secondary)
      if let state = monitor.snapshot?.history_state, state != "off", state != "recording" {
        Text(L("Falha ao gravar: %@", state)).font(.caption).foregroundStyle(.orange)
      }
      LabeledContent(L("Armazenado")) {
        if let info = store.info, info.minutes > 0 {
          Text(
            L(
              "%@ · %@ minutos desde %@", formatBytes(info.bytes), "\(info.minutes)",
              Date(timeIntervalSince1970: info.oldest ?? 0).formatted(date: .abbreviated, time: .shortened))
          ).monospacedDigit()
        } else {
          Text(L("Nada salvo"))
        }
      }
      Button(L("Apagar histórico…"), role: .destructive) { confirmDelete = true }
        .disabled((store.info?.bytes ?? 0) == 0)
        .confirmationDialog(L("Apagar todo o histórico salvo?"), isPresented: $confirmDelete) {
          Button(L("Apagar histórico"), role: .destructive) { store.delete() }
          Button(L("Cancelar"), role: .cancel) {}
        } message: {
          Text(L("Remove o arquivo do disco. A gravação continua se estiver ligada."))
        }
    }
    .onAppear { store.loadInfo() }
    .onChange(of: p.historyEnabled) { _, _ in store.loadInfo() }
    .onChange(of: monitor.snapshot.map { Int($0.at / 60) }) { _, _ in store.loadInfo() }
  }
}

/// Which machines from the Machines page the floating panel shows. Its own view, so readings
/// arriving from ssh redraw only this list.
private struct PanelMachinesPicker: View {
  @ObservedObject var store = MachineStore.shared
  @ObservedObject var p = Preferences.shared
  var body: some View {
    if store.hosts.isEmpty {
      HStack {
        Text(L("Nenhuma máquina ainda.")).foregroundStyle(.secondary)
        Button(L("Abrir Máquinas")) { WindowOpener.shared.showMain(page: .machines) }
      }
    } else {
      ForEach(store.hosts, id: \.self) { host in
        Toggle(host, isOn: shown(host)).toggleStyle(.checkbox)
      }
    }
    Text(
      L("As máquinas marcadas são lidas pelo ssh a cada 60 s enquanto o painel está visível, no mesmo ritmo da página Máquinas (as duas abertas não leem mais vezes).")
    ).font(.caption).foregroundStyle(.secondary)
  }
  private func shown(_ host: String) -> Binding<Bool> {
    Binding(
      get: { p.panelMachineHosts.contains(host) },
      set: { on in
        let selected = on ? p.panelMachineHosts + [host] : p.panelMachineHosts.filter { $0 != host }
        p.panelMachineHosts = panelMachineHosts(selected: selected, hosts: store.hosts)
      })
  }
}
