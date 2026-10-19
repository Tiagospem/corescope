import AppKit
import SwiftUI

/// Text in the interface language (the Overview card) and in English (what agents read).
struct AuditText {
  let ui: String
  let en: String
  init(raw: String) {
    ui = raw
    en = raw
  }
  init(_ key: String, _ args: AuditText...) {
    ui = L(key, args.map(\.ui))
    let english = Localization.table[key]?.en ?? key
    en = args.isEmpty ? english : String(format: english, arguments: args.map { $0.en as NSString })
  }
}
private func raw(_ s: String) -> AuditText { AuditText(raw: s) }

/// One thing the user could stop, remove or turn off, with what it would give back and the MCP
/// tool that acts on it. The audit itself never acts.
struct AuditFinding: Identifiable {
  let id: String
  let category: String
  let title: AuditText
  let why: AuditText
  var impact = AuditImpact()
  let confidence: AuditConfidence
  var tool: String?
  var arguments: [String: Any] = [:]
  /// Only the user can act (an app to quit, a setting that reaches outside the Mac).
  var userOnly = false
  /// For agents, in English: limits of the tool or where the user acts instead.
  var note: String?
  /// Where the Overview card sends the user.
  var page: Page = .overview
  var score = 0.0
}

/// Sweeps what CoreScope already holds (the latest snapshot, the cached Cleanup scan and plan,
/// Disk growth's last measurement, profiles, Services, its own cost) for things worth freeing.
/// Nothing here walks the disk or starts a scan; stale sources are reported with the tool that
/// refreshes them.
enum PerformanceAudit {
  /// `performance_audit`: reads containers off the main thread when no page keeps them fresh.
  static func run(_ args: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    let limit = min(max(args["limit"] as? Int ?? 20, 1), 50)
    let category = (args["category"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let finish: ([ContainerItem]?) -> Void = { containers in
      guard let s = Monitor.shared.snapshot else {
        return reply(["error": "CoreScope has no reading yet; try again in a few seconds"])
      }
      let list = findings(s, containers: containers)
      reply(json(s, list.filter { category == nil || $0.category == category }, containers: containers, limit: limit))
    }
    if let report = ContainerStore.shared.report { return finish(report.containers) }
    DispatchQueue.global(qos: .userInitiated).async {
      var list: [ContainerItem]?
      if let pointer = cs_containers(0) {
        let data = Data(bytes: pointer, count: strlen(pointer))
        cs_free(pointer)
        list = (try? JSONDecoder().decode(ContainerReport.self, from: data))?.containers
      }
      DispatchQueue.main.async { finish(list) }
    }
  }

  static func context(_ s: Snapshot) -> AuditContext {
    let root = s.volumes.first { $0.mount == "/System/Volumes/Data" } ?? s.volumes.first { $0.mount == "/" }
    return AuditContext(
      pressure: s.pressure.value, swap: s.swap.value, diskFree: root?.available.value, diskTotal: root?.total.value,
      onBattery: s.battery.map { !$0.on_ac } ?? false)
  }

  /// Every finding, ranked. Main thread (it reads the stores).
  static func findings(_ s: Snapshot, containers: [ContainerItem]?) -> [AuditFinding] {
    let ctx = context(s)
    var out: [AuditFinding] = []
    let own = getpid()
    let profiles = ProfileStore.shared
    let started = profiles.allProfiles.filter { profiles.active.contains($0.id) }
    var profilePIDs = Set<Int32>()
    var profileContainers = Set<String>()
    func sum(_ list: [ProcessItem]) -> AuditImpact {
      AuditImpact(
        cpu: list.reduce(0) { $0 + max(0, $1.cpu.value ?? 0) }, memory: list.reduce(0) { $0 + max(0, $1.memory.value ?? 0) },
        watts: list.reduce(0) { $0 + max(0, $1.energy?.value ?? 0) })
    }
    let stopNote =
      "stop_process acts only on processes this agent session started; otherwise the user stops it in CoreScope (Processes)."

    // Started profiles: everything they run, with their containers.
    for p in started {
      let members = p.commands.flatMap { profiles.members($0) }
      members.forEach { profilePIDs.insert($0.pid) }
      p.containers.forEach { profileContainers.insert($0) }
      let running = (containers ?? []).filter { $0.running && p.containers.contains($0.name) }
      guard !members.isEmpty || !running.isEmpty else { continue }
      var impact = sum(members)
      impact.cpu += running.compactMap(\.cpu).reduce(0, +)
      impact.memory += running.compactMap(\.memory).reduce(0, +)
      out.append(
        AuditFinding(
          id: "profile:\(p.name)", category: "profiles", title: AuditText("Perfil iniciado: %@", raw(p.name)),
          why: AuditText("%@ processos e %@ contêineres em execução por ele.", raw("\(members.count)"), raw("\(running.count)")),
          impact: impact, confidence: .low, tool: "stop_profile", arguments: ["name": p.name],
          note: "Stops what the profile started; containers another started profile uses are kept. Ask the user: it may be in use.",
          page: .profiles))
    }

    // Orphans: dev runtimes whose terminal, editor or agent went away.
    var claimed = profilePIDs
    for p in s.orphans where !claimed.contains(p.pid) {
      let tree = s.subtree(of: p)
      let impact = sum(tree)
      guard auditOrphanWorthStopping(cpu: impact.cpu, memory: impact.memory, listening: tree.contains { $0.isServer }) else {
        continue
      }
      tree.forEach { claimed.insert($0.pid) }
      out.append(
        AuditFinding(
          id: "orphan:\(p.pid)", category: "orphans", title: AuditText("Órfão %@ (PID %@)", raw(p.name), raw("\(p.pid)")),
          why: AuditText(p.orphan ?? "Rodando sem o processo pai."), impact: impact, confidence: .medium,
          tool: "stop_process", arguments: ["pid": Int(p.pid), "tree": true], note: stopNote))
    }

    // Agent sessions that look stuck or draw a lot of power.
    let watch = StallWatch.shared
    for root in s.agentSessions {
      let tree = s.subtree(of: root)
      tree.forEach { claimed.insert($0.pid) }
      let meta = AgentStore.shared.claudeSessions[root.pid]
      let stall = watch.stall(root: root, tree: tree, meta: meta).flatMap { $0.suspicious ? $0 : nil }
      let impact = sum(tree)
      let draining = impact.watts >= Preferences.shared.drainWatts
      guard stall != nil || draining else { continue }
      let name = raw(meta?.name ?? root.project ?? root.name)
      out.append(
        AuditFinding(
          id: "agent:\(root.pid)", category: "agents",
          title: stall != nil ? AuditText("Sessão de agente parada: %@", name) : AuditText("Sessão de agente gastando energia: %@", name),
          why: stall.map { raw($0.summary) } ?? AuditText("Ela e o que iniciou somam %@ W.", raw(String(format: "%.1f", impact.watts))),
          impact: impact, confidence: .low, userOnly: true,
          note: "The user's own session: ask them. list_stuck_agents shows what its commands are doing.", page: .agents))
    }
    for t in AgentStore.shared.codexThreads where t.running {
      guard let stall = watch.stall(thread: t), stall.suspicious else { continue }
      out.append(
        AuditFinding(
          id: "agent:codex:\(t.id)", category: "agents", title: AuditText("Sessão de agente parada: %@", raw(t.title)),
          why: raw(stall.summary), confidence: .low, userOnly: true,
          note: "A Codex thread: the user stops it in Codex. list_stuck_agents has the details.", page: .agents))
    }

    // Heavy apps and processes, an app's helpers counted together.
    var groups: [String: [ProcessItem]] = [:]
    for p in s.processes
    where p.uid == s.current_uid && p.pid != own && p.ppid != own && !isCoreScopeHelper(path: p.path)
      && !claimed.contains(p.pid)
    {
      groups[p.bundlePath ?? "pid:\(p.pid)", default: []].append(p)
    }
    for (key, list) in groups {
      let impact = sum(list)
      let high = list.map(\.high_cpu_seconds).max() ?? 0
      guard auditHeavyProcess(cpu: impact.cpu, memory: impact.memory, highCPUSeconds: high), let first = list.first else { continue }
      if key.hasPrefix("pid:") {
        out.append(
          AuditFinding(
            id: "process:\(first.pid)", category: "processes", title: raw("\(first.name) (PID \(first.pid))"),
            why: AuditText("Pesando agora: CPU alta ou muita memória."), impact: impact,
            confidence: first.isDev ? .medium : .low, tool: "stop_process", arguments: ["pid": Int(first.pid), "tree": true],
            note: stopNote, page: .processes))
      } else {
        let app = ((key as NSString).lastPathComponent as NSString).deletingPathExtension
        out.append(
          AuditFinding(
            id: "app:\(app)", category: "processes", title: raw(app),
            why: AuditText("Pesando agora: %@ processos deste app somados.", raw("\(list.count)")), impact: impact,
            confidence: .low, userOnly: true,
            note: "An app the user runs: they quit it (or close what is heavy in it) if they are not using it.",
            page: .processes))
      }
    }

    // Containers: idle ones holding memory, and stopped ones keeping images and volumes.
    if let containers {
      for c in containers where c.running && !profileContainers.contains(c.name) {
        guard auditIdleContainer(cpu: c.cpu, memory: c.memory, inActiveProfile: false) else { continue }
        out.append(
          AuditFinding(
            id: "container:\(c.name)", category: "containers", title: AuditText("Contêiner ocioso: %@", raw(c.name)),
            why: AuditText("Rodando quase sem CPU e segurando memória; nenhum perfil iniciado o usa."),
            impact: AuditImpact(cpu: c.cpu ?? 0, memory: c.memory ?? 0), confidence: .low, tool: "container_action",
            arguments: ["name": c.name, "action": "stop"], note: "A database or queue may still be in use: ask the user first.",
            page: .containers))
      }
      let stopped = containers.filter { ["exited", "created", "dead"].contains($0.state) }
      if !stopped.isEmpty {
        out.append(
          AuditFinding(
            id: "containers:stopped", category: "containers",
            title: AuditText("%@ contêineres parados", raw("\(stopped.count)")),
            why: AuditText("Não gastam CPU nem memória, mas prendem imagens e volumes que a limpeza não pode remover."),
            confidence: .low, tool: "list_containers", userOnly: true,
            note: "CoreScope does not remove containers: the user does it in Docker (e.g. docker container prune) if they are no longer needed. Names: "
              + stopped.prefix(12).map(\.name).joined(separator: ", "),
            page: .containers))
      }
    }

    // Disk: the safe cleanup plan when it was read, the Cleanup page's cached scan, Disk growth.
    let plan = CleanupPlanStore.shared.actions
    let now = Date().timeIntervalSince1970
    for a in plan where a.busy == nil && a.estimate >= AuditThreshold.diskItem {
      out.append(
        AuditFinding(
          id: "plan:\(a.id)", category: "disk", title: raw(a.title), why: raw(a.note),
          impact: AuditImpact(disk: a.estimate), confidence: .high, tool: "run_cleanup_plan", arguments: ["ids": [a.id]],
          note: a.kind == "docker" ? "Docker removes it (permanent, but re-created on demand)." : "Folders go to the Trash.",
          page: .storage))
    }
    let covered: Set<String> = plan.isEmpty ? [] : ["docker_build_cache", "derived_data"]
    let scanned = (CleanupStore.shared.report?.items ?? []).filter { $0.busy == nil && !covered.contains($0.kind) }
    let isMerged = { (i: DevSpaceItem) in (i.detail ?? "").components(separatedBy: " · ").contains("merged") }
    // Merged worktrees are each small but add up: one finding for all of them.
    let merged = scanned.filter { $0.kind == "worktree" && isMerged($0) }
    let mergedBytes = merged.reduce(0) { $0 + $1.bytes }
    if merged.count > 1, mergedBytes >= AuditThreshold.diskItem {
      out.append(
        AuditFinding(
          id: "space:merged-worktrees", category: "disk",
          title: AuditText("%@ worktrees já mergeados", raw("\(merged.count)")),
          why: AuditText("Os branches já estão no principal; nada se perde além da pasta de trabalho."),
          impact: AuditImpact(disk: mergedBytes), confidence: .high, tool: "clean_dev_space", arguments: ["ids": merged.map(\.id)],
          note: "Moved to the Trash (recoverable until it is emptied); git's worktree entry is pruned. From the cached scan: "
            + merged.prefix(12).map { abbreviateHome($0.path) }.joined(separator: ", "),
          page: .cleanup))
    }
    let grouped = merged.count > 1 && mergedBytes >= AuditThreshold.diskItem ? Set(merged.map(\.id)) : []
    let items = scanned.filter { $0.bytes >= AuditThreshold.diskItem && !grouped.contains($0.id) }.sorted { $0.bytes > $1.bytes }
    for i in items.prefix(10) {
      let confidence = auditDiskConfidence(kind: i.kind, modified: i.modified, merged: isMerged(i), now: now)
      let why: AuditText
      switch i.kind {
      case "worktree": why = AuditText("Worktree: %@.", raw(i.detail ?? i.path))
      case "node_modules", "rust_target":
        why = AuditText(
          "Pasta de build que volta no próximo build ou install; sem mudanças há %@ dias.",
          raw("\(i.modified > 0 ? Int((now - i.modified) / 86400) : 0)"))
      default: why = AuditText("Recriado sob demanda pela ferramenta que o usa.")
      }
      out.append(
        AuditFinding(
          id: "space:\(i.id)", category: "disk", title: AuditText("%@ · %@", AuditText(i.kindLabel), raw(i.name)), why: why,
          impact: AuditImpact(disk: i.bytes), confidence: confidence, tool: "clean_dev_space", arguments: ["ids": [i.id]],
          note: (i.isDocker ? "Removed by Docker (permanent)." : "Moved to the Trash (recoverable until it is emptied).")
            + " From the cached scan: \(abbreviateHome(i.path)).",
          page: .cleanup))
    }
    let planIDs = Set(plan.map(\.id))
    for g in DiskGrowthStore.shared.report?.folders ?? [] where (g.change ?? 0) >= AuditThreshold.growth {
      if let action = g.cleanup, planIDs.contains(action) { continue }
      let label = raw(g.label.isEmpty ? (g.path as NSString).lastPathComponent : g.label)
      out.append(
        AuditFinding(
          id: "growth:\(g.path)", category: "disk", title: AuditText("%@ cresceu %@ hoje", label, raw(diskBytes(g.change ?? 0))),
          why: g.cleanup != nil
            ? AuditText("Uma ação da limpeza segura libera esta pasta.")
            : AuditText("Sem ação automática: veja o que há dentro em Armazenamento."),
          impact: AuditImpact(disk: g.cleanup != nil ? g.bytes : g.change ?? 0), confidence: g.cleanup != nil ? .medium : .low,
          tool: g.cleanup != nil ? "run_cleanup_plan" : "large_files",
          arguments: g.cleanup.map { ["ids": [$0]] } ?? ["min_mb": 500],
          note: "From Disk growth's last measurement (\(abbreviateHome(g.path))).", page: .storage))
    }

    // Services checks that are down nearly all day.
    for c in HealthStore.shared.allChecks {
      guard HealthStore.shared.results[c.id] != nil, auditDeadService(uptime24h: HealthStore.shared.uptime(c.id, hours: 24)) else {
        continue
      }
      let up = (HealthStore.shared.uptime(c.id, hours: 24) ?? 0) * 100
      out.append(
        AuditFinding(
          id: "service:\(c.name)", category: "services", title: AuditText("Serviço sempre fora: %@", raw(c.name)),
          why: AuditText("No ar %@%% das últimas 24 h; a verificação ainda roda a cada 30 s.", raw(String(format: "%.0f", up))),
          impact: AuditImpact(cpu: 0.01), confidence: .medium, tool: c.source == nil ? "remove_service" : nil,
          arguments: c.source == nil ? ["name": c.name] : [:], userOnly: c.source != nil,
          note: c.source.map { "Defined in \($0): the user removes it there (write_project_config), or starts what it checks." }
            ?? "Removing only stops the check; or start what it checks (list_profiles).",
          page: .health))
    }

    out += corescope(s)
    for i in out.indices { out[i].score = auditScore(out[i].impact, confidence: out[i].confidence, context: ctx) }
    return rankAudit(out) { $0.score }
  }

  /// CoreScope's own switches that cost the most right now.
  private static func corescope(_ s: Snapshot) -> [AuditFinding] {
    let p = Preferences.shared
    let cost = SelfCost.current()
    var out: [AuditFinding] = []
    let feature = { (id: String) in cost.features.first { $0.id == id } }
    let collector = feature("collector")?.cpu ?? 0
    func title(_ id: String) -> AuditText { AuditText("CoreScope: %@", raw(feature(id)?.title ?? id)) }
    if p.interval < 5 {
      out.append(
        AuditFinding(
          id: "corescope:collector", category: "corescope", title: title("collector"),
          why: AuditText("Coleta a cada %@ s; 5 s gasta menos da metade.", raw("\(Int(p.interval))")),
          impact: AuditImpact(cpu: collector * (1 - p.interval / 5)), confidence: .medium, tool: "set_setting",
          arguments: ["key": "collector_interval_seconds", "value": 5], page: .settings))
    }
    if p.panelVisible, !cost.windowOpen {
      out.append(
        AuditFinding(
          id: "corescope:panel", category: "corescope", title: title("panel"),
          why: AuditText("Mantém o coletor no intervalo rápido mesmo com a janela fechada."),
          impact: AuditImpact(cpu: collector * max(0, 1 - p.interval / 10)), confidence: .low, tool: "set_setting",
          arguments: ["key": "floating_panel", "value": false], note: "Only if the user does not rely on the panel.",
          page: .settings))
    }
    if p.panelVisible, p.panelMachines, !MachineStore.shared.panelHosts.isEmpty {
      out.append(
        AuditFinding(
          id: "corescope:panel-machines", category: "corescope", title: title("machines"),
          why: raw(feature("machines")?.cadence ?? ""), impact: AuditImpact(cpu: feature("machines")?.cpu ?? 0),
          confidence: .medium, tool: "set_setting", arguments: ["key": "panel_machines", "value": false], page: .settings))
    }
    if p.codexLiveLimits {
      let codex = s.processes.filter { $0.ppid == getpid() && $0.name.lowercased().contains("codex") }
      out.append(
        AuditFinding(
          id: "corescope:codex-live", category: "corescope", title: title("codexLive"),
          why: raw(feature("codexLive")?.cadence ?? ""),
          impact: AuditImpact(
            cpu: codex.reduce(0) { $0 + max(0, $1.cpu.value ?? 0) }, memory: codex.reduce(0) { $0 + max(0, $1.memory.value ?? 0) }),
          confidence: .medium, userOnly: true,
          note: "Settings › Agents: it asks OpenAI through Codex, so only the user switches it.", page: .settings))
    }
    if p.historyEnabled, let h = feature("history"), h.weight >= .medium {
      out.append(
        AuditFinding(
          id: "corescope:history", category: "corescope", title: title("history"), why: raw(h.cadence),
          impact: AuditImpact(cpu: h.cpu ?? 0), confidence: .low, userOnly: true,
          note: "Settings › History: what_happened needs it, so ask the user.", page: .settings))
    }
    return out
  }

  /// What `performance_audit` returns.
  static func json(_ s: Snapshot, _ list: [AuditFinding], containers: [ContainerItem]?, limit: Int) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    let ctx = context(s)
    let now = Date()
    let r = { (v: Double, digits: Double) in (v * digits).rounded() / digits }
    let findings = list.prefix(limit).enumerated().map { n, f -> [String: Any] in
      [
        "rank": n + 1, "id": f.id, "category": f.category, "title": f.title.en, "why": f.why.en,
        "impact": [
          "cpu_percent": r(f.impact.cpu, 10), "memory_bytes": Int(f.impact.memory), "disk_bytes": Int(f.impact.disk),
          "watts": r(f.impact.watts, 100),
        ],
        "confidence": f.confidence.name, "score": r(f.score, 100),
        "action": f.tool.map { ["tool": $0, "arguments": f.arguments] as [String: Any] } ?? NSNull(),
        "who_acts": f.userOnly ? "the user" : "an agent, after the user agrees",
        "note": f.note ?? NSNull(),
      ]
    }
    let cleanup = CleanupStore.shared
    let scanAge = auditStaleAge(scannedAt: cleanup.scannedAt?.timeIntervalSince1970, now: now.timeIntervalSince1970)
    let rootsChanged = cleanup.scannedAt != nil && Set(Preferences.shared.cleanupRoots) != Set(cleanup.scannedRoots)
    let growthAt = DiskGrowthStore.shared.report?.measured_at
    let statsKnown = containers?.contains { $0.cpu != nil } ?? false
    let sources: [[String: Any]] = [
      [
        "name": "snapshot", "at": iso.string(from: Date(timeIntervalSince1970: s.at)),
        "stale": false, "note": "processes, orphans, agents, energy and memory: the collector's latest pass",
      ],
      [
        "name": "dev_space_scan", "at": cleanup.scannedAt.map { iso.string(from: $0) } ?? NSNull(),
        "stale": scanAge != nil || rootsChanged,
        "note": cleanup.scannedAt == nil
          ? "never scanned: reclaimable node_modules, target/, worktrees and Docker data are missing"
          : rootsChanged ? "the cleanup folders changed since the scan" : scanAge.map { "\(Int($0 / 3600)) h old" } ?? "recent",
        "refresh_with": "scan_dev_space (about 30 s; ask the user first)",
      ],
      [
        "name": "cleanup_plan", "stale": CleanupPlanStore.shared.actions.isEmpty,
        "note": CleanupPlanStore.shared.actions.isEmpty
          ? "not read in this run of the app: caches (npm, Cargo, Homebrew…) are missing" : "read in this run of the app",
        "refresh_with": "cleanup_plan",
      ],
      [
        "name": "disk_growth", "at": growthAt.map { iso.string(from: Date(timeIntervalSince1970: $0)) } ?? NSNull(),
        "stale": auditStaleAge(scannedAt: growthAt, now: now.timeIntervalSince1970, limit: 24 * 3600) != nil,
        "refresh_with": "disk_growth with measure: true",
      ],
      [
        "name": "container_stats", "stale": !statsKnown,
        "note": containers == nil
          ? "no container engine answered" : statsKnown ? "CPU and memory per container read recently"
          : "CPU and memory per container are read only while CoreScope's Containers page or Overview is open; idle containers are not judged",
        "refresh_with": "list_containers",
      ],
    ]
    return [
      "findings": findings, "total_findings": list.count,
      "context": [
        "memory_tight": ctx.memoryTight, "disk_tight": ctx.diskTight, "on_battery": ctx.onBattery,
        "cpu_percent": s.cpu.value.map { $0 as Any } ?? NSNull(),
        "memory_pressure": s.pressure.value.map { $0 as Any } ?? NSNull(), "swap_bytes": s.swap.value.map { $0 as Any } ?? NSNull(),
      ],
      "sources": sources,
      "not_covered": [
        "Unused Docker volumes: list_containers lists named volumes with size and use; removing one deletes its data, so the user does it in Docker.",
        "Worktrees outside the last scan: list_worktrees or project_worktrees.",
      ],
      "note": "Read-only: nothing was stopped, removed or changed. Ranked by score (CPU, memory, disk and power, weighted by "
        + "what is tight now and by confidence). Ask the user before each action; impact is what acting would give back.",
    ]
  }
}

/// Overview: the same findings as `performance_audit`, the top ones, each opening its page.
struct AuditCard: View {
  @ObservedObject var monitor = Monitor.shared
  @ObservedObject var containers = ContainerStore.shared
  private static var cache: (at: Double, list: [AuditFinding]) = (-1, [])
  var body: some View {
    let list = findings
    Card {
      CardHeader(title: L("Para aliviar o Mac"), symbol: "leaf", tint: Tint.brand, count: list.count)
      if list.isEmpty {
        EmptyNote(text: L("Nada pesando que dê para parar ou liberar agora."))
      }
      ForEach(list.prefix(5)) { f in
        Button {
          navigate(f.page)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(f.category)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
              Text(f.title.ui).font(.callout).lineLimit(1)
              Text(f.why.ui).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Text(figure(f.impact)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Badge(text: confidence(f.confidence), color: f.confidence == .high ? Tint.brand : .secondary)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
      Text(L("Só leitura: cada linha abre a página onde agir. Agentes veem a lista completa no MCP performance_audit."))
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  private var findings: [AuditFinding] {
    guard let s = monitor.snapshot else { return [] }
    if Self.cache.at == s.at { return Self.cache.list }
    let list = PerformanceAudit.findings(s, containers: containers.report?.containers).filter { $0.score >= 0.05 }
    Self.cache = (s.at, list)
    return list
  }
  private func symbol(_ category: String) -> String {
    switch category {
    case "orphans": "exclamationmark.triangle"
    case "agents": "sparkles"
    case "profiles": "play.rectangle"
    case "containers": "shippingbox"
    case "disk": "internaldrive"
    case "services": "stethoscope"
    case "corescope": "gauge.with.dots.needle.33percent"
    default: "cpu"
    }
  }
  private func figure(_ i: AuditImpact) -> String {
    var parts: [String] = []
    if i.memory >= 50 * 1_048_576 { parts.append(formatBytes(i.memory)) }
    if i.cpu >= 1 { parts.append(String(format: "%.0f%% CPU", i.cpu)) }
    if i.disk > 0 { parts.append(diskBytes(i.disk)) }
    if i.watts >= 0.5 { parts.append(String(format: "%.1f W", i.watts)) }
    return parts.joined(separator: " · ")
  }
  private func confidence(_ c: AuditConfidence) -> String {
    switch c {
    case .high: L("certeza alta")
    case .medium: L("certeza média")
    case .low: L("verifique")
    }
  }
}
