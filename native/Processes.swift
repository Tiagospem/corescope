import AppKit
import SwiftUI

enum ProcessScope: String, CaseIterable, Identifiable {
  case all = "Todos"
  case mine = "Meus"
  case dev = "Dev"
  case agents = "Agentes"
  case servers = "Servidores"
  case orphans = "Órfãos"
  case watched = "Acompanhados"
  var id: String { rawValue }
  var title: String { L(rawValue) }
  var symbol: String {
    switch self {
    case .all: "square.stack.3d.up"
    case .mine: "person"
    case .dev: "chevron.left.forwardslash.chevron.right"
    case .agents: "sparkles"
    case .servers: "network"
    case .orphans: "exclamationmark.triangle"
    case .watched: "star"
    }
  }
}

struct ProcessRow: Identifiable {
  let item: ProcessItem
  let depth: Int
  let children: Int
  let expanded: Bool
  let totalCPU: Double
  let totalMemory: Double
  /// Shown only as an ancestor of a filter match.
  let context: Bool
  var id: String { item.id }
  var name: String { item.name.lowercased() }
  var pid: Int32 { item.pid }
  var cpu: Double { totalCPU }
  var memory: Double { totalMemory }
  var origin: String { (item.project ?? "") + (item.origin?.label ?? "") }
  var port: Int { item.ports.first.map { Int($0.port) } ?? Int.max }
}

func tagLabel(_ tag: String) -> String {
  [
    "agent": "Agente", "editor": "Editor", "terminal": "Terminal", "runtime": "Runtime",
    "shell": "Shell", "mcp": "MCP", "container": "Container", "database": "Banco de dados",
    "server": "Servidor",
  ][tag].map { L($0) } ?? tag
}

struct ProcessesView: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  @ViewState private var query = ""
  @ViewState private var scope = ProcessScope.all
  @ViewState private var selection = Set<String>()
  @ViewState private var expanded = Set<String>()
  @ViewState private var showInspector = false
  @ViewState private var sort = [KeyPathComparator(\ProcessRow.cpu, order: .reverse)]

  private func matches(_ p: ProcessItem, _ s: Snapshot) -> Bool {
    let inScope: Bool
    switch scope {
    case .all: inScope = true
    case .mine: inScope = p.uid == s.current_uid
    case .dev: inScope = p.isDev
    case .agents: inScope = p.inAgentSession
    case .servers: inScope = p.isServer
    case .orphans: inScope = p.orphan != nil
    case .watched: inScope = prefs.watched.contains(p.id)
    }
    guard inScope else { return false }
    guard !query.isEmpty else { return true }
    let haystack =
      "\(p.name) \(p.pid) \(p.user) \(p.cwd) \(p.portsLabel) \(p.origin?.label ?? "") \(p.host ?? "")"
    return query.split(separator: " ").allSatisfy {
      haystack.localizedCaseInsensitiveContains($0)
    }
  }
  private var filtering: Bool { scope != .all || !query.isEmpty }
  private func rows(_ s: Snapshot) -> [ProcessRow] {
    let all = s.processes
    let byPID = Dictionary(all.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    let forest = ProcessForest(all.map { ($0.pid, $0.ppid) })
    let cpu = forest.totals { byPID[$0]?.cpu.value ?? 0 }
    let memory = forest.totals { byPID[$0]?.memory.value ?? 0 }
    let matched = Set(all.filter { matches($0, s) }.map(\.pid))
    func row(_ p: ProcessItem, depth: Int, children: Int, open: Bool, tree: Bool) -> ProcessRow {
      ProcessRow(
        item: p, depth: depth, children: children, expanded: open,
        totalCPU: tree ? cpu[p.pid] ?? 0 : p.cpu.value ?? -1,
        totalMemory: tree ? memory[p.pid] ?? 0 : p.memory.value ?? -1,
        context: !matched.contains(p.pid))
    }
    guard prefs.processTree else {
      return all.filter { matched.contains($0.pid) }
        .map { row($0, depth: 0, children: 0, open: false, tree: false) }
        .sorted(using: sort)
    }
    let parent = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
    let visible = filtering ? matched.union(forest.ancestors(of: matched, parent: parent)) : nil
    let draft = Dictionary(
      all.map { ($0.pid, row($0, depth: 0, children: 0, open: false, tree: true)) },
      uniquingKeysWith: { a, _ in a })
    let comparator = sort.first ?? KeyPathComparator(\ProcessRow.cpu, order: .reverse)
    let isOpen: (Int32) -> Bool = { pid in
      filtering || byPID[pid].map { expanded.contains($0.id) } ?? false
    }
    return forest.flatten(
      visible: visible, expanded: isOpen,
      order: { a, b in
        guard let ra = draft[a], let rb = draft[b] else { return a < b }
        return comparator.compare(ra, rb) == .orderedAscending
      }
    ).compactMap { node in
      byPID[node.pid].map {
        row($0, depth: node.depth, children: node.children, open: isOpen(node.pid), tree: true)
      }
    }
  }
  private func count(_ scope: ProcessScope, _ s: Snapshot) -> Int? {
    switch scope {
    case .agents: s.agentSessions.count
    case .servers: s.servers.count
    case .orphans: s.orphans.count
    case .watched: prefs.watched.isEmpty ? nil : prefs.watched.count
    default: nil
    }
  }
  private func selected(_ s: Snapshot) -> [ProcessItem] {
    s.processes.filter { selection.contains($0.id) }
  }

  var body: some View {
    if let s = monitor.snapshot {
      content(s)
    } else {
      ProgressView(L("Lendo processos…")).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  @ViewBuilder private func content(_ s: Snapshot) -> some View {
    let rows = self.rows(s)
    let chosen = selected(s)
    VStack(spacing: 0) {
      VStack(spacing: 10) {
        HStack(spacing: 10) {
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L("Nome, PID, porta, projeto ou agente"), text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
              Button {
                query = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
              }.buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel(L("Limpar busca"))
            }
          }
          .padding(.horizontal, 9).padding(.vertical, 6)
          .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          .frame(maxWidth: 360)
          Spacer()
          Picker(L("Exibição"), selection: $prefs.processTree) {
            Image(systemName: "list.bullet.indent").help(L("Árvore")).accessibilityLabel(L("Árvore")).tag(true)
            Image(systemName: "list.bullet").help(L("Lista")).accessibilityLabel(L("Lista")).tag(false)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 84)
          if prefs.processTree {
            Button {
              expanded = Set(s.processes.map(\.id))
            } label: {
              Image(systemName: "plus.square.on.square")
            }.buttonStyle(HoverButtonStyle(size: 26)).help(L("Expandir tudo")).accessibilityLabel(L("Expandir tudo"))
            Button {
              expanded = []
            } label: {
              Image(systemName: "minus.square")
            }.buttonStyle(HoverButtonStyle(size: 26)).help(L("Recolher tudo")).accessibilityLabel(L("Recolher tudo"))
          }
          Button {
            showInspector.toggle()
          } label: {
            Image(systemName: "sidebar.right")
          }.buttonStyle(HoverButtonStyle(size: 26)).help(L("Mostrar ou ocultar detalhes"))
            .accessibilityLabel(showInspector ? L("Ocultar detalhes") : L("Mostrar detalhes"))
        }
        HStack(spacing: 6) {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(ProcessScope.allCases) { item in
                ScopeChip(scope: item, selected: scope == item, count: count(item, s)) { scope = item }
              }
            }
          }
          Spacer(minLength: 8)
          Text(L("%@ de %@", "\(rows.filter { !$0.context }.count)", "\(s.processes.count)"))
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        if scope == .orphans {
          Text(
            L("Processos de desenvolvimento sem pai (adotados pelo launchd) ou cujo pai encerrou enquanto o CoreScope observava. Confirme a finalidade antes de encerrar.")
          ).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

      Table(rows, selection: $selection, sortOrder: $sort) {
        TableColumn(L("Processo"), value: \.name) { row in
          NameCell(row: row, tree: prefs.processTree, watched: prefs.watched.contains(row.id)) {
            if expanded.contains(row.id) {
              expanded.remove(row.id)
            } else {
              expanded.insert(row.id)
            }
          }
        }.width(min: 200, ideal: 250)
        TableColumn(L("PID"), value: \.pid) { row in
          Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
        }.width(min: 50, ideal: 58)
        TableColumn(L("Projeto · origem"), value: \.origin) { row in OriginCell(item: row.item) }
          .width(min: 90, ideal: 140)
        TableColumn(L("Portas"), value: \.port) { row in PortsCell(ports: row.item.ports) }
          .width(min: 56, ideal: 80)
        TableColumn(L("CPU"), value: \.cpu) { row in
          ValueCell(
            own: row.item.cpu.percent, total: row.children > 0 ? row.totalCPU : nil,
            format: { String(format: "%.1f%%", $0) }, hot: (row.item.cpu.value ?? 0) >= 80)
        }.width(min: 90, ideal: 118)
        TableColumn(L("Memória"), value: \.memory) { row in
          ValueCell(
            own: row.item.memory.bytes, total: row.children > 0 ? row.totalMemory : nil,
            format: formatBytes, hot: (row.item.memory.value ?? 0) >= 2_000_000_000)
        }.width(min: 100, ideal: 138)
        TableColumn("") { row in
          HStack(spacing: 0) {
            if let port = row.item.ports.first?.port { OpenPortButton(port: port) }
            KillButton(process: row.item)
          }.frame(maxWidth: .infinity, alignment: .trailing)
        }.width(min: 52, ideal: 64)
      }
      .contextMenu(forSelectionType: String.self) { ids in
        RowMenu(items: s.processes.filter { ids.contains($0.id) }, expanded: $expanded)
      } primaryAction: { ids in
        if prefs.processTree, ids.count == 1, let id = ids.first,
          let row = rows.first(where: { $0.id == id }), row.children > 0
        {
          if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        } else {
          showInspector = true
        }
      }
      .onDeleteCommand { monitor.requestKill(chosen) }
      .onKeyPress(.rightArrow) {
        guard prefs.processTree, !selection.isEmpty else { return .ignored }
        expanded.formUnion(selection)
        return .handled
      }
      .onKeyPress(.leftArrow) {
        guard prefs.processTree, !selection.isEmpty else { return .ignored }
        expanded.subtract(selection)
        return .handled
      }

      SelectionBar(items: chosen, inspectorVisible: showInspector) { showInspector = true }
    }
    .inspector(isPresented: $showInspector) {
      ProcessInspector(id: selection.count == 1 ? selection.first : nil) { pid in
        if let target = s.process(pid: pid) {
          selection = [target.id]
          scope = .all
          query = ""
          var current = target.ppid
          while let p = s.process(pid: current), current > 1 {
            expanded.insert(p.id)
            current = p.ppid
          }
        }
      }
      .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
    }
  }
}

private struct ScopeChip: View {
  let scope: ProcessScope
  let selected: Bool
  let count: Int?
  let action: () -> Void
  @ViewState private var hovering = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: scope.symbol).font(.system(size: 10, weight: .semibold))
          .accessibilityHidden(true)
        Text(scope.title)
        if let count {
          Text("\(count)").monospacedDigit().foregroundStyle(
            selected ? AnyShapeStyle(Color.white.opacity(0.85))
              : scope == .orphans && count > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
      }
      .font(.system(size: 11.5, weight: .medium))
      .lineLimit(1).fixedSize()
      .padding(.horizontal, 10).padding(.vertical, 5)
      .foregroundStyle(selected ? Color.white : Color.primary)
      .background(
        Capsule().fill(
          selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.09 : 0.05)))
      .contentShape(Capsule())
    }.buttonStyle(.plain).onHover { hovering = $0 }
  }
}

private struct NameCell: View {
  let row: ProcessRow
  let tree: Bool
  let watched: Bool
  let toggle: () -> Void
  var body: some View {
    HStack(spacing: 5) {
      if tree {
        Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
        if row.children > 0 {
          Button(action: toggle) {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
              .rotationEffect(.degrees(row.expanded ? 90 : 0))
              .frame(width: 14, height: 16)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(.secondary)
            .help(row.expanded ? L("Recolher") : L("Expandir"))
            .accessibilityLabel(row.expanded ? L("Recolher %@", "\(row.item.name)") : L("Expandir %@", "\(row.item.name)"))
        } else {
          Color.clear.frame(width: 14, height: 1)
        }
      }
      ProcessIcon(process: row.item)
      Text(row.item.name).lineLimit(1)
        .fontWeight(tree && row.depth == 0 && row.children > 0 ? .medium : .regular)
        .foregroundStyle(row.context ? .secondary : .primary)
      if tree && row.children > 0 && !row.expanded {
        Text("\(row.children)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Color.primary.opacity(0.08), in: Capsule()).foregroundStyle(.secondary)
          .help(L("%@ processos filhos", "\(row.children)"))
          .accessibilityLabel(L("%@ processos filhos", "\(row.children)"))
      }
      if watched {
        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
          .help(L("Acompanhado")).accessibilityLabel(L("Acompanhado"))
      }
      if row.item.orphan != nil { Badge(text: L("órfão"), color: .orange) }
      if row.item.isAgentSession { Badge(text: row.item.sessionSource, color: .orange) }
    }.help(row.item.path.isEmpty ? row.item.name : row.item.path)
  }
}
private struct OriginCell: View {
  let item: ProcessItem
  var body: some View {
    HStack(spacing: 5) {
      if let project = item.project {
        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(project).lineLimit(1)
      }
      if let origin = item.origin {
        Text(origin.label).lineLimit(1).foregroundStyle(.secondary).font(.caption)
      }
    }.help(
      [item.cwd.isEmpty ? nil : L("Diretório: %@", "\(item.shortCwd)"),
       item.origin.map { L("Iniciado via %@ (PID %@)", "\($0.label)", "\($0.pid)") }]
        .compactMap { $0 }.joined(separator: L("\n")))
  }
}
private struct PortsCell: View {
  let ports: [PortInfo]
  var body: some View {
    HStack(spacing: 3) {
      ForEach(ports.prefix(2), id: \.port) { p in
        PortBadge(port: p)
          .help(p.exposed ? L("Escutando em todas as interfaces (acessível na rede)") : L("Somente local (loopback)"))
      }
      if ports.count > 2 { Text("+\(ports.count - 2)").font(.caption2).foregroundStyle(.secondary) }
    }
  }
}
private struct ValueCell: View {
  let own: String
  let total: Double?
  let format: (Double) -> String
  let hot: Bool
  var body: some View {
    HStack(spacing: 4) {
      Text(own).monospacedDigit().foregroundStyle(hot ? Color.orange : Color.primary)
      if let total {
        Text("Σ " + format(total)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
          .help(L("Soma do processo e de todos os descendentes"))
          .accessibilityLabel(L("Total com descendentes: %@", format(total)))
      }
    }
  }
}

/// Actions shared by the table context menu.
struct RowMenu: View {
  let items: [ProcessItem]
  @Binding var expanded: Set<String>
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  var body: some View {
    if let p = items.first {
      let label = items.count == 1 ? p.name : "\(items.count) processos"
      Button(L("Encerrar %@", "\(label)")) { monitor.requestKill(items) }
      Button(L("Encerrar %@ e descendentes…", "\(label)")) { monitor.requestKill(items, tree: true) }
      Button(L("Forçar encerramento…")) { monitor.requestKill(items, force: true) }
      Divider()
      if items.count == 1 {
        ForEach(p.ports.prefix(4), id: \.port) { port in
          Button(L("Abrir http://localhost:%@", "\(port.port)")) {
            if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
          }
        }
        if !p.cwd.isEmpty {
          Button(L("Abrir diretório no Finder")) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p.cwd))
          }
          Button(L("Abrir Terminal no diretório")) { openTerminal(at: p.cwd) }
        }
        if !p.path.isEmpty {
          Button(L("Mostrar executável no Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
          }
        }
        Divider()
        Button(L("Copiar PID")) { copy(String(p.pid)) }
        if !p.path.isEmpty { Button(L("Copiar caminho")) { copy(p.path) } }
        if !p.cwd.isEmpty { Button(L("Copiar diretório")) { copy(p.cwd) } }
        Divider()
      }
      Button(L("Expandir")) { expanded.formUnion(items.map(\.id)) }
      Button(L("Recolher")) { expanded.subtract(items.map(\.id)) }
      if items.count == 1 {
        Button(prefs.watched.contains(p.id) ? L("Parar de acompanhar") : L("Acompanhar CPU e memória")) {
          prefs.toggleWatch(p.id)
          monitor.refresh()
        }
        if p.orphan != nil {
          Button(L("Não marcar como órfão")) {
            prefs.ignored.append(p.id)
            monitor.refresh()
          }
        }
      }
    }
  }
}
func copy(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}
func openTerminal(at path: String) {
  guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
  else { return }
  NSWorkspace.shared.open(
    [URL(fileURLWithPath: path)], withApplicationAt: terminal,
    configuration: NSWorkspace.OpenConfiguration())
}

private struct SelectionBar: View {
  let items: [ProcessItem]
  let inspectorVisible: Bool
  let inspect: () -> Void
  @ObservedObject var monitor = Monitor.shared
  var body: some View {
    HStack(spacing: 8) {
      if items.isEmpty {
        Text(L("Selecione processos para agir · ⌫ encerra · ←/→ recolhe e expande"))
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
      } else {
        let cpu = items.compactMap(\.cpu.value).reduce(0, +)
        let memory = items.compactMap(\.memory.value).reduce(0, +)
        Text(
          L("%@ · CPU %@ · %@", "\(items.count == 1 ? items[0].name : "\(items.count) selecionados")", "\(String(format: "%.1f%%", cpu))", "\(formatBytes(memory))")
        ).font(.callout).monospacedDigit().lineLimit(1)
        Spacer()
        if !inspectorVisible && items.count == 1 { Button(L("Detalhes"), action: inspect) }
        Button(L("Encerrar")) { monitor.requestKill(items) }
          .keyboardShortcut(.delete, modifiers: .command)
        Button(L("Encerrar árvore")) { monitor.requestKill(items, tree: true) }
          .keyboardShortcut(.delete, modifiers: [.command, .shift])
        Button(L("Forçar"), role: .destructive) { monitor.requestKill(items, force: true) }
          .keyboardShortcut(.delete, modifiers: [.command, .option])
      }
    }
    .disabled(monitor.stale && !items.isEmpty)
    .controlSize(.regular)
    .padding(.horizontal, 18).padding(.vertical, 9)
    .frame(minHeight: 44)
    .background(.bar)
  }
}

struct ProcessInspector: View {
  let id: String?
  var reveal: (Int32) -> Void = { _ in }
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var prefs = Preferences.shared
  var body: some View {
    if let s = monitor.snapshot, let id, let p = s.processes.first(where: { $0.id == id }) {
      details(p, s)
    } else {
      ContentUnavailableView(
        L("Nenhum processo"), systemImage: "cursorarrow.click",
        description: Text(L("Selecione um processo para ver origem, portas, recursos e ações.")))
    }
  }
  private func details(_ p: ProcessItem, _ s: Snapshot) -> some View {
    let descendants = s.subtree(of: p).count - 1
    return ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 12) {
          ProcessIcon(process: p, size: 38)
          VStack(alignment: .leading, spacing: 3) {
            Text(p.name).font(.title3.weight(.semibold)).lineLimit(2).textSelection(.enabled)
            Text(L("PID %@ · %@ · pai %@", "\(String(p.pid))", "\(p.user)", "\(String(p.ppid))")).font(.caption)
              .foregroundStyle(.secondary).monospacedDigit()
          }
        }
        let tags = p.tags.filter { $0 != "server" }
        if !tags.isEmpty || p.orphan != nil {
          HStack(spacing: 4) {
            if p.orphan != nil { Badge(text: L("órfão"), color: .orange) }
            ForEach(tags, id: \.self) { Badge(text: tagLabel($0), color: .secondary) }
          }
        }
        HStack(spacing: 6) {
          Button(L("Encerrar")) { monitor.requestKill([p]) }
          if descendants > 0 {
            Button(L("Árvore (%@)", "\(descendants + 1)")) { monitor.requestKill([p], tree: true) }
          }
          Button(L("Forçar"), role: .destructive) { monitor.requestKill([p], force: true) }
        }.disabled(!p.eligible || monitor.stale).controlSize(.small)
        if !p.eligible { Label(L(p.blocked), systemImage: "lock").font(.caption).foregroundStyle(.secondary) }

        if let reason = p.orphan {
          VStack(alignment: .leading, spacing: 6) {
            Label(L("Possível órfão"), systemImage: "exclamationmark.triangle.fill")
              .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(L(reason)).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let parent = p.orphan_parent {
              Text(L("Pai observado: %@", parent)).font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Não marcar novamente")) {
              prefs.ignored.append(p.id)
              monitor.refresh()
            }.controlSize(.small)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }

        if !p.ports.isEmpty {
          section(L("Portas em escuta")) {
            ForEach(p.ports, id: \.port) { port in
              HStack {
                Text(":\(port.port)").font(.system(.body, design: .monospaced))
                Badge(text: port.exposed ? L("rede") : L("local"), color: port.exposed ? .orange : Tint.netIn)
                Spacer()
                OpenPortButton(port: port.port)
              }
            }
          }
        }
        section(L("Origem")) {
          if let o = p.origin {
            Button {
              reveal(o.pid)
            } label: {
              Label(L("Iniciado via %@ · PID %@", "\(o.label)", "\(String(o.pid))"), systemImage: "arrow.turn.left.up")
            }.buttonStyle(.link).help(L("Selecionar o processo de origem"))
          } else if p.ppid == 1 {
            Text(L("Iniciado pelo launchd (sem pai interativo)")).font(.callout).foregroundStyle(.secondary)
          }
          if !p.cwd.isEmpty {
            pathRow(L("Diretório"), abbreviateHome(p.cwd)) {
              Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: p.cwd))
              } label: {
                Image(systemName: "folder")
              }.buttonStyle(HoverButtonStyle(size: 22)).help(L("Abrir no Finder")).accessibilityLabel(L("Abrir diretório no Finder"))
              Button {
                openTerminal(at: p.cwd)
              } label: {
                Image(systemName: "terminal")
              }.buttonStyle(HoverButtonStyle(size: 22)).help(L("Abrir Terminal aqui")).accessibilityLabel(L("Abrir Terminal no diretório"))
            }
          }
          pathRow(L("Executável"), p.path.isEmpty ? "Indisponível" : abbreviateHome(p.path)) {
            if !p.path.isEmpty {
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
              } label: {
                Image(systemName: "magnifyingglass")
              }.buttonStyle(HoverButtonStyle(size: 22)).help(L("Mostrar no Finder")).accessibilityLabel(L("Mostrar executável no Finder"))
            }
          }
          Text(L("Início %@ · ativo há %@", "\(p.startDate.formatted(date: .abbreviated, time: .shortened))", "\(formatDuration(p.uptime))"))
            .font(.caption).foregroundStyle(.secondary)
        }
        section(L("Recursos")) {
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
              stat(L("CPU"), p.cpu.percent, p.cpu)
              stat(L("Memória"), p.memory.bytes, p.memory)
            }
            GridRow {
              stat(L("Residente"), p.resident.bytes, p.resident)
              stat(L("Threads"), p.threads.value.map { String(Int($0)) } ?? "—", p.threads)
            }
            GridRow {
              stat(L("Leitura"), p.read.rate, p.read)
              stat(L("Escrita"), p.write.rate, p.write)
            }
          }
          if descendants > 0 {
            let tree = s.subtree(of: p)
            Text(
              L("Com %@ descendente%@: CPU %@ · %@", "\(descendants)", "\(descendants == 1 ? "" : "s")", "\(String(format: "%.1f%%", tree.compactMap(\.cpu.value).reduce(0, +)))", "\(formatBytes(tree.compactMap(\.memory.value).reduce(0, +)))")
            ).font(.caption).foregroundStyle(.secondary)
          }
          if p.high_cpu_seconds >= 20 {
            Text(L("CPU ≥ 80%% de um núcleo há %@ s.", "\(Int(p.high_cpu_seconds))")).font(.caption)
              .foregroundStyle(.orange)
          }
        }
        section(L("Histórico")) {
          Toggle(
            L("Acompanhar CPU e memória"),
            isOn: Binding(
              get: { prefs.watched.contains(p.id) },
              set: { _ in
                prefs.toggleWatch(p.id)
                monitor.refresh()
              })
          ).disabled(!prefs.watched.contains(p.id) && prefs.watched.count >= 12)
          if p.history.count > 1 {
            AreaChart(
              series: [.cpu(p.history.map(\.cpu))], ceiling: 100, title: L("CPU")
            ).frame(height: 46)
            AreaChart(series: [.memory(p.history.map(\.memory))], title: L("Memória"))
              .frame(height: 38)
            Text(L("CPU (verde) e memória (azul) · até 10 min")).font(.caption2).foregroundStyle(.secondary)
          } else {
            Text(L("Até 12 processos · 120 amostras em memória.")).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.padding(16)
    }
  }
  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      content()
    }
  }
  private func pathRow<Actions: View>(
    _ title: String, _ value: String, @ViewBuilder actions: () -> Actions
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Spacer()
        actions()
      }
      Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func stat(_ title: String, _ value: String, _ metric: Metric) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(.callout, design: .rounded).weight(.medium)).monospacedDigit()
    }.help(metric.explanation).accessibilityElement(children: .combine)
  }
}
