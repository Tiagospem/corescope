//! Whether the Mac has room for heavy work right now, and which commands count as heavy. Agents
//! are admitted or deferred on this (a Claude Code / Codex hook running `corescope gate`, the MCP
//! tools `system_capacity`, `reserve_capacity` and `wait_for_capacity`) before builds and test
//! suites, so a busy machine is not pushed into hours-long sessions.
use crate::projectconfig::{CapacitySpec, HeavyCommand};
use serde::{Deserialize, Serialize};

/// What a heavy command draws on: the Mac's CPU and memory, and the container VM's memory.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct Uses {
    pub cpu: bool,
    pub memory: bool,
    pub containers: bool,
}
impl Uses {
    /// A command that runs on the Mac only.
    pub const MAC: Uses = Uses {
        cpu: true,
        memory: true,
        containers: false,
    };
    /// Everything: for a wait that does not say what it runs.
    pub const ALL: Uses = Uses {
        cpu: true,
        memory: true,
        containers: true,
    };
    /// From `.corescope.yml` names (`cpu`, `memory`, `containers`).
    pub fn parse(names: &[String]) -> Result<Uses, String> {
        let mut out = Uses::default();
        for n in names {
            match n.trim() {
                "cpu" => out.cpu = true,
                "memory" => out.memory = true,
                "containers" => out.containers = true,
                other => return Err(format!("`{other}` (use cpu, memory or containers)")),
            }
        }
        if out == Uses::default() {
            return Err("an empty list".into());
        }
        Ok(out)
    }
    pub fn names(&self) -> Vec<&'static str> {
        [
            (self.cpu, "cpu"),
            (self.memory, "memory"),
            (self.containers, "containers"),
        ]
        .into_iter()
        .filter_map(|(on, n)| on.then_some(n))
        .collect()
    }
    pub fn union(self, other: Uses) -> Uses {
        Uses {
            cpu: self.cpu || other.cpu,
            memory: self.memory || other.memory,
            containers: self.containers || other.containers,
        }
    }
}

/// A process and how much it takes, to name who uses most.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Consumer {
    pub name: String,
    pub value: f64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Reading {
    /// Busy CPU across all cores, percent.
    pub cpu: f64,
    /// "normal", "warning" or "critical"; None when unknown (treated as normal).
    pub memory: Option<String>,
    /// Memory the kernel considers available, percent (kern.memorystatus_level).
    pub available: Option<f64>,
    /// Container engines' VMs: their memory is capped apart from the Mac's.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub containers: Vec<crate::containers::VmMemory>,
    /// Busiest processes (percent of one core) and biggest (bytes), for the advice.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub top_cpu: Vec<Consumer>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub top_memory: Vec<Consumer>,
}

/// Why a heavy command cannot start now, and what to do about it.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Blocker {
    /// "cpu", "memory" or "containers".
    pub resource: &'static str,
    /// "transient" clears by itself (waiting helps); "structural" only clears with an action
    /// (stopping containers, a bigger VM), so waiting is lost time.
    pub kind: &'static str,
    pub reason: String,
    pub action: String,
}
impl Blocker {
    pub fn structural(&self) -> bool {
        self.kind == "structural"
    }
}

/// The pressure that counts: the kernel's "warning" lingers long after memory frees up (and
/// shows while half of it is available), so it counts only with 35% or less available;
/// "critical" always counts.
pub fn effective_memory(kernel: Option<&str>, available: Option<f64>) -> Option<String> {
    match (kernel, available) {
        (Some("warning"), Some(a)) if a > 35. => Some("normal".into()),
        (k, _) => k.map(String::from),
    }
}

fn rank(level: &str) -> u8 {
    match level {
        "normal" => 0,
        "warning" => 1,
        _ => 2,
    }
}

fn list(consumers: &[Consumer], show: impl Fn(f64) -> String) -> String {
    consumers
        .iter()
        .take(3)
        .map(|c| format!("{} {}", c.name, show(c.value)))
        .collect::<Vec<_>>()
        .join(", ")
}

/// What would hold back a command that uses `uses` and loads the containers `targets`; empty
/// when there is room.
pub fn blockers(spec: &CapacitySpec, r: &Reading, uses: Uses, targets: &[String]) -> Vec<Blocker> {
    let mut out = vec![];
    if uses.cpu && r.cpu >= spec.cpu_below {
        let busiest = list(&r.top_cpu, |v| format!("{v:.0}%"));
        out.push(Blocker {
            resource: "cpu",
            kind: "transient",
            reason: format!("CPU at {:.0}% (limit {:.0}%)", r.cpu, spec.cpu_below),
            action: format!(
                "Wait: CPU settles as builds and tests finish, usually within minutes{}. Call \
                 wait_for_capacity (up to 55 s per call) and try again.",
                if busiest.is_empty() {
                    String::new()
                } else {
                    format!(" (busiest now: {busiest})")
                }
            ),
        });
    }
    if uses.memory
        && let Some(m) = &r.memory
        && rank(m) > rank(&spec.memory)
    {
        let available = r
            .available
            .map(|a| format!(", {a:.0}% available"))
            .unwrap_or_default();
        let biggest = list(&r.top_memory, gb);
        out.push(Blocker {
            resource: "memory",
            kind: "transient",
            reason: format!("Mac memory pressure {m}{available} (limit {})", spec.memory),
            action: format!(
                "Wait with wait_for_capacity, or ask the user to close what they don't need{}.",
                if biggest.is_empty() {
                    String::new()
                } else {
                    format!(" (biggest: {biggest})")
                }
            ),
        });
    }
    if uses.containers && spec.container_memory_free > 0. {
        for vm in &r.containers {
            let free = vm.free_percent();
            if free >= spec.container_memory_free {
                continue;
            }
            let needed = (spec.container_memory_free - free) / 100. * vm.total;
            let top = vm
                .top
                .iter()
                .take(3)
                .map(|c| format!("{} {}", c.name, gb(c.used)))
                .collect::<Vec<_>>()
                .join(", ");
            let grow = match vm.engine {
                "OrbStack" => {
                    "OrbStack › Settings › System › Memory limit, or `orb config set memory_mib <MiB>`"
                }
                "Docker Desktop" => "Docker Desktop › Settings › Resources › Memory",
                "Colima" => "`colima stop && colima start --memory <GiB>`",
                _ => "the engine's memory setting",
            };
            out.push(Blocker {
                resource: "containers",
                kind: "structural",
                reason: format!(
                    "{} VM memory {free:.0}% free of {} (limit {:.0}%){}",
                    vm.engine,
                    gb(vm.total),
                    spec.container_memory_free,
                    if top.is_empty() {
                        String::new()
                    } else {
                        format!("; using most: {top}")
                    }
                ),
                action: format!(
                    "Waiting won't help: the VM's memory frees only when containers stop or \
                     shrink. Free at least {}: stop a container that is not in use (ask the user \
                     which), or give the VM more memory ({grow}). Then try again.",
                    gb(needed.max(0.))
                ),
            });
        }
    }
    // The containers it loads: each running, with room under its own limit. Unknown when no
    // engine answered.
    if !r.containers.is_empty() {
        for name in targets {
            let found = r
                .containers
                .iter()
                .flat_map(|vm| vm.running.iter())
                .find(|c| c.answers_to(name));
            match found {
                None => out.push(Blocker {
                    resource: "containers",
                    kind: "structural",
                    reason: format!("container {name} is not running"),
                    action:
                        "Start the environment it belongs to (the project's profile or its own \
                             command) before this command; waiting won't start it."
                            .into(),
                }),
                Some(c) => {
                    if let (Some(pct), Some(limit)) = (c.limit_percent(), c.limit)
                        && pct >= NEAR_LIMIT
                    {
                        out.push(Blocker {
                            resource: "containers",
                            kind: "structural",
                            reason: format!(
                                "{} uses {} of its {} memory limit ({pct:.0}%)",
                                c.name,
                                gb(c.used),
                                gb(limit)
                            ),
                            action: format!(
                                "This command's load would get {} killed (exit 137). Raise its memory \
                                 limit (compose mem_limit or deploy.resources.limits.memory) or restart \
                                 it to release memory (ask the user), then try again.",
                                c.name
                            ),
                        });
                    }
                }
            }
        }
    }
    out
}

/// A container at this share of its own memory limit is one spike from being killed.
pub const NEAR_LIMIT: f64 = 90.;

fn gb(bytes: f64) -> String {
    if bytes >= 1e9 {
        format!("{:.1} GB", bytes / 1e9)
    } else {
        format!("{:.0} MB", bytes / 1e6)
    }
}

/// What does not block but an agent should know before heavy work: containers at their own
/// memory limit, and containers killed lately.
pub fn warnings(r: &Reading, now: f64) -> Vec<String> {
    let mut out = vec![];
    for vm in &r.containers {
        for c in &vm.near_limit {
            if let Some(limit) = c.limit {
                out.push(format!(
                    "{} uses {} of its {} limit ({:.0}%): more load on it gets it killed (exit 137); \
                     raise its mem_limit or lighten the work",
                    c.name,
                    gb(c.used),
                    gb(limit),
                    c.used / limit * 100.
                ));
            }
        }
        for k in &vm.killed {
            let minutes = ((now - k.at) / 60.).max(0.).round();
            out.push(format!(
                "{} was killed {minutes:.0} min ago ({}) in the {} VM",
                k.name,
                if k.oom { "out of memory" } else { "exit 137" },
                vm.engine
            ));
        }
    }
    out
}

/// CPU from a snapshot (sampled twice, so it is a real average) and the kernel's memory pressure.
pub fn reading(snapshot: &crate::Snapshot) -> Reading {
    let available = snapshot
        .pressure_percent
        .value
        .map(|p| (100. - p).clamp(0., 100.));
    let own = std::process::id() as i32;
    let mut cpu: Vec<Consumer> = vec![];
    let mut memory: Vec<Consumer> = vec![];
    for p in snapshot.processes.iter().filter(|p| p.pid != own) {
        if let Some(v) = p.cpu.value.filter(|v| *v >= 20.) {
            cpu.push(Consumer {
                name: p.name.clone(),
                value: v,
            });
        }
        if let Some(v) = p.memory.value.filter(|v| *v >= 500e6) {
            memory.push(Consumer {
                name: p.name.clone(),
                value: v,
            });
        }
    }
    cpu.sort_by(|a, b| b.value.total_cmp(&a.value));
    memory.sort_by(|a, b| b.value.total_cmp(&a.value));
    cpu.truncate(3);
    memory.truncate(3);
    Reading {
        cpu: snapshot.cpu.value.unwrap_or(0.),
        memory: effective_memory(crate::os::pressure_level(), available),
        available,
        containers: vec![],
        top_cpu: cpu,
        top_memory: memory,
    }
}

/// `reading` plus the container engines' VMs (a few requests to each engine) when `uses` asks.
pub fn full_reading(snapshot: &crate::Snapshot, uses: Uses) -> Reading {
    Reading {
        containers: if uses.containers {
            crate::containers::vm_memory()
        } else {
            vec![]
        },
        ..reading(snapshot)
    }
}

/// Each step of a shell command line (`a && b; c | d`), without leading `VAR=value` assignments.
pub fn steps(command: &str) -> Vec<String> {
    let mut out = vec![];
    for part in command.split(['\n', ';', '|', '&']) {
        let mut words = part.split_whitespace().peekable();
        while words
            .peek()
            .is_some_and(|w| w.contains('=') && !w.starts_with('=') && !w.starts_with('-'))
        {
            words.next();
        }
        let step = words.collect::<Vec<_>>().join(" ");
        if !step.is_empty() {
            out.push(step);
        }
    }
    out
}

/// The heavy command a command line runs, if any (`npm run build` matches `npm run build -- --watch`;
/// `cd web && npm test` matches `npm test`).
pub fn heavy<'a>(command: &str, list: &'a [HeavyCommand]) -> Option<&'a HeavyCommand> {
    let steps = steps(command);
    list.iter().find(|h| {
        let p = h.command().trim();
        !p.is_empty()
            && steps
                .iter()
                .any(|s| s == p || s.starts_with(&format!("{p} ")))
    })
}

/// The project's heavy commands, or the defaults when it lists none.
pub fn heavy_list(spec: &CapacitySpec) -> Vec<HeavyCommand> {
    if spec.heavy_commands.is_empty() {
        default_heavy()
    } else {
        spec.heavy_commands.clone()
    }
}

/// Used when a project enables waiting but lists no commands: common builds, test suites and
/// container builds across stacks. `true`: it also uses the container VM (Docker itself, and
/// PHP suites, which usually test against a database in a container).
pub const DEFAULT_HEAVY: [(&str, bool); 25] = [
    ("npm run build", false),
    ("npm test", false),
    ("npm run test", false),
    ("pnpm build", false),
    ("pnpm test", false),
    ("yarn build", false),
    ("yarn test", false),
    ("npx playwright test", false),
    ("cargo build", false),
    ("cargo test", false),
    ("go build", false),
    ("go test", false),
    ("php artisan test", true),
    ("vendor/bin/phpunit", true),
    ("vendor/bin/pest", true),
    ("./vendor/bin/pest", true),
    ("composer install", false),
    ("pytest", false),
    ("docker build", true),
    ("docker compose build", true),
    ("docker compose up", true),
    ("docker-compose up", true),
    ("docker run", true),
    ("xcodebuild", false),
    ("swift build", false),
];

pub fn default_heavy() -> Vec<HeavyCommand> {
    DEFAULT_HEAVY
        .iter()
        .map(|(c, containers)| {
            if *containers {
                HeavyCommand::with_uses(c, Uses::ALL)
            } else {
                HeavyCommand::Prefix(c.to_string())
            }
        })
        .collect()
}

/// A proposed heavy command for `.corescope.yml`, with why.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CommandAdvice {
    pub command: String,
    pub uses: Vec<&'static str>,
    pub containers: Vec<String>,
    pub weight: f64,
    pub why: String,
}

/// What `capacity_advice` found and proposes; the YAML is a starting point to review.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Advice {
    pub findings: Vec<String>,
    pub commands: Vec<CommandAdvice>,
    pub container_memory_free: f64,
    pub max_parallel: f64,
    pub yaml: String,
}

/// Suites that usually run against a database or cache in a container.
const DB_SUITES: [&str; 11] = [
    "php artisan test",
    "vendor/bin/pest",
    "./vendor/bin/pest",
    "vendor/bin/phpunit",
    "./vendor/bin/phpunit",
    "pytest",
    "python manage.py test",
    "bundle exec rspec",
    "bin/rails test",
    "rails test",
    "mix test",
];
/// Services a test suite loads: databases, caches, search.
const BACKING: [&str; 10] = [
    "mysql",
    "mariadb",
    "postgres",
    "redis",
    "valkey",
    "mongo",
    "typesense",
    "elastic",
    "opensearch",
    "meili",
];

/// A proposal from what runs now: the container VMs, the project's own containers (named in its
/// profiles, databases and environment), and its heavy commands (or the defaults).
pub fn advice(
    current: Option<&CapacitySpec>,
    vms: &[crate::containers::VmMemory],
    project_containers: &[String],
    cores: usize,
) -> Advice {
    let mut findings = vec![];
    for vm in vms {
        let limits: f64 = vm.running.iter().filter_map(|c| c.limit).sum();
        let unlimited: Vec<&str> = vm
            .running
            .iter()
            .filter(|c| c.limit.is_none())
            .map(|c| c.name.as_str())
            .collect();
        findings.push(format!(
            "{} VM: {} total, {} used by {} running containers, {:.0}% free.",
            vm.engine,
            gb(vm.total),
            gb(vm.containers_used),
            vm.running.len(),
            vm.free_percent()
        ));
        if limits > vm.total * 0.85 {
            findings.push(format!(
                "Container limits add up to {} on a {} VM: they can't all reach them at once. Give the VM \
                 at least {} or lower the limits.",
                gb(limits),
                gb(vm.total),
                gb(limits / 0.85)
            ));
        }
        if !unlimited.is_empty() {
            findings.push(format!(
                "Without a memory limit (any of them can take the whole VM): {}. A mem_limit makes a \
                 runaway container fail alone instead of taking the others down.",
                unlimited.join(", ")
            ));
        }
        for c in &vm.running {
            if let (Some(pct), Some(limit)) = (c.limit_percent(), c.limit)
                && pct >= 75.
            {
                findings.push(format!(
                    "{} sits at {pct:.0}% of its {} limit while idle: a test suite on it will push it \
                     over. Raise the limit (or its own settings, e.g. innodb_buffer_pool_size).",
                    c.name,
                    gb(limit)
                ));
            }
        }
        for k in &vm.killed {
            findings.push(format!(
                "{} was killed lately ({}).",
                k.name,
                if k.oom { "out of memory" } else { "exit 137" }
            ));
        }
    }
    if vms.is_empty() {
        findings.push(
            "No container engine answered: commands are checked against the Mac only.".into(),
        );
    }
    // The project's backing services that are running, by the names its .corescope.yml uses.
    let running: Vec<&crate::containers::ContainerMemory> =
        vms.iter().flat_map(|vm| vm.running.iter()).collect();
    let backing: Vec<String> = project_containers
        .iter()
        .filter(|name| {
            let n = name.to_lowercase();
            BACKING.iter().any(|b| n.contains(b))
        })
        .filter(|name| running.iter().any(|c| c.answers_to(name)))
        .cloned()
        .collect();
    let list = current.map(heavy_list).unwrap_or_else(default_heavy);
    let commands: Vec<CommandAdvice> = list
        .iter()
        .map(|h| {
            let c = h.command();
            let docker = c.starts_with("docker");
            let suite = DB_SUITES
                .iter()
                .any(|s| c == *s || c.starts_with(&format!("{s} ")));
            let (uses, containers, weight, why) = if !h.containers().is_empty() {
                (
                    h.uses(),
                    h.containers().to_vec(),
                    h.weight(),
                    "as configured".to_string(),
                )
            } else if docker {
                (
                    Uses::ALL,
                    vec![],
                    2.,
                    "builds or starts containers: draws on the VM".into(),
                )
            } else if suite && !backing.is_empty() {
                (
                    Uses::ALL,
                    backing.clone(),
                    2.,
                    format!("a test suite; likely runs against {}", backing.join(", ")),
                )
            } else if suite {
                (
                    Uses::ALL,
                    vec![],
                    2.,
                    "a test suite that usually needs a database".into(),
                )
            } else {
                (Uses::MAC, vec![], h.weight(), "runs on the Mac only".into())
            };
            CommandAdvice {
                command: c.into(),
                uses: uses.names(),
                containers,
                weight,
                why,
            }
        })
        .collect();
    let container_memory_free = current.map(|c| c.container_memory_free).unwrap_or(15.);
    // A heavy command per four cores at once, at least one.
    let max_parallel = current
        .map(|c| c.max_parallel)
        .unwrap_or(((cores as f64) / 4.).floor().clamp(1., 4.));
    let mut yaml = String::from("agents:\n  wait_for_capacity:\n");
    yaml += &format!(
        "    cpu_below: {:.0}\n    memory: {}\n    max_wait_minutes: {:.0}\n    container_memory_free: {container_memory_free:.0}\n    max_parallel: {max_parallel:.0}\n    heavy_commands:\n",
        current.map(|c| c.cpu_below).unwrap_or(70.),
        current.map(|c| c.memory.as_str()).unwrap_or("normal"),
        current.map(|c| c.max_wait_minutes).unwrap_or(30.)
    );
    for c in &commands {
        if c.uses == Uses::MAC.names() && c.containers.is_empty() && c.weight == 1. {
            yaml += &format!("      - {}            # {}\n", c.command, c.why);
            continue;
        }
        yaml += &format!("      - command: {}            # {}\n", c.command, c.why);
        yaml += &format!("        uses: [{}]\n", c.uses.join(", "));
        if !c.containers.is_empty() {
            yaml += &format!("        containers: [{}]\n", c.containers.join(", "));
        }
        if c.weight != 1. {
            yaml += &format!("        weight: {:.0}\n", c.weight);
        }
    }
    Advice {
        findings,
        commands,
        container_memory_free,
        max_parallel,
        yaml,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reading(cpu: f64, memory: &str) -> Reading {
        Reading {
            cpu,
            memory: Some(memory.into()),
            available: None,
            containers: vec![],
            top_cpu: vec![],
            top_memory: vec![],
        }
    }

    #[test]
    fn heavy_commands_are_found_in_chains() {
        let p = vec![
            HeavyCommand::Prefix("npm run build".into()),
            HeavyCommand::with_uses("php artisan test", Uses::ALL),
        ];
        assert_eq!(
            heavy("cd web && npm run build -- --mode qa", &p).map(|h| h.command()),
            Some("npm run build")
        );
        let php = heavy("APP_ENV=testing php artisan test --parallel", &p).unwrap();
        assert_eq!((php.command(), php.uses()), ("php artisan test", Uses::ALL));
        assert!(
            heavy("npm run build-storybook", &p).is_none(),
            "a longer script name is another command"
        );
        assert!(heavy("git status; ls -la | grep x", &p).is_none());
        assert_eq!(
            steps("A=1 B=2 make test && echo ok"),
            ["make test", "echo ok"]
        );
        let defaults = default_heavy();
        assert_eq!(
            heavy("go test ./internal/http/", &defaults).unwrap().uses(),
            Uses::MAC
        );
        assert_eq!(
            heavy("php artisan test", &defaults).unwrap().uses(),
            Uses::ALL
        );
        assert_eq!(
            heavy("docker compose up -d", &defaults).unwrap().uses(),
            Uses::ALL
        );
    }

    #[test]
    fn the_incident_vm_blocks_only_commands_that_use_containers() {
        use crate::containers::{ContainerMemory, Killed, VmMemory};
        let mysql = ContainerMemory {
            name: "TO--mysql".into(),
            used: 1.4e9,
            limit: Some(1.5e9),
            project: None,
            service: Some("mysql".into()),
        };
        let vm = VmMemory {
            engine: "OrbStack",
            total: 4.2e9,
            available: Some(0.59e9),
            containers_used: 2e9,
            top: vec![mysql.clone()],
            running: vec![mysql.clone()],
            near_limit: vec![mysql],
            killed: vec![Killed {
                name: "redis".into(),
                at: 1000.,
                oom: true,
            }],
        };
        let r = Reading {
            containers: vec![vm.clone()],
            available: Some(60.),
            ..reading(12., "normal")
        };
        let spec = CapacitySpec::default();
        assert!(
            blockers(&spec, &r, Uses::MAC, &[]).is_empty(),
            "go test runs"
        );
        let b = blockers(&spec, &r, Uses::ALL, &[]);
        assert_eq!(b.len(), 1, "{b:?}");
        assert_eq!((b[0].resource, b[0].kind), ("containers", "structural"));
        assert!(
            b[0].reason
                .starts_with("OrbStack VM memory 14% free of 4.2 GB (limit 15%)"),
            "{}",
            b[0].reason
        );
        assert!(b[0].reason.contains("TO--mysql 1.4 GB"), "{}", b[0].reason);
        assert!(
            b[0].action.starts_with("Waiting won't help"),
            "{}",
            b[0].action
        );
        assert!(
            b[0].action.contains("orb config set memory_mib"),
            "{}",
            b[0].action
        );
        let off = CapacitySpec {
            container_memory_free: 0.,
            ..Default::default()
        };
        assert!(blockers(&off, &r, Uses::ALL, &[]).is_empty());
        let roomy = Reading {
            containers: vec![VmMemory {
                available: Some(2e9),
                ..vm
            }],
            ..r
        };
        assert!(blockers(&spec, &roomy, Uses::ALL, &[]).is_empty());
        // Loading that MySQL, at 93% of its own limit, is held whatever the VM has.
        let b = blockers(&spec, &roomy, Uses::ALL, &["mysql".into()]);
        assert_eq!((b.len(), b[0].kind), (1, "structural"));
        assert!(
            b[0].reason
                .starts_with("TO--mysql uses 1.4 GB of its 1.5 GB memory limit (93%)"),
            "{}",
            b[0].reason
        );
        let b = blockers(&spec, &roomy, Uses::ALL, &["redis".into()]);
        assert_eq!(b[0].reason, "container redis is not running");
        let w = warnings(&roomy, 1000. + 300.);
        assert_eq!(w.len(), 2, "{w:?}");
        assert!(
            w[0].starts_with("TO--mysql uses 1.4 GB of its 1.5 GB limit (93%)"),
            "{}",
            w[0]
        );
        assert_eq!(
            w[1],
            "redis was killed 5 min ago (out of memory) in the OrbStack VM"
        );
    }

    #[test]
    fn kernel_warning_counts_only_with_little_memory_available() {
        assert_eq!(
            effective_memory(Some("warning"), Some(52.)).as_deref(),
            Some("normal")
        );
        assert_eq!(
            effective_memory(Some("warning"), Some(30.)).as_deref(),
            Some("warning")
        );
        assert_eq!(
            effective_memory(Some("warning"), None).as_deref(),
            Some("warning")
        );
        assert_eq!(
            effective_memory(Some("critical"), Some(60.)).as_deref(),
            Some("critical")
        );
        assert_eq!(effective_memory(None, Some(10.)), None);
    }

    #[test]
    fn cpu_and_memory_are_transient() {
        let spec = CapacitySpec {
            cpu_below: 70.,
            memory: "normal".into(),
            ..Default::default()
        };
        assert!(blockers(&spec, &reading(40., "normal"), Uses::MAC, &[]).is_empty());
        let busy = Reading {
            top_cpu: vec![Consumer {
                name: "php".into(),
                value: 380.,
            }],
            ..reading(85., "normal")
        };
        let b = blockers(&spec, &busy, Uses::MAC, &[]);
        assert_eq!((b.len(), b[0].kind), (1, "transient"));
        assert!(
            b[0].action.contains("busiest now: php 380%"),
            "{}",
            b[0].action
        );
        assert!(
            blockers(
                &spec,
                &busy,
                Uses {
                    cpu: false,
                    ..Uses::MAC
                },
                &[]
            )
            .is_empty()
        );
        let both = blockers(&spec, &reading(90., "warning"), Uses::MAC, &[]);
        assert_eq!(both.len(), 2, "{both:?}");
        assert!(both.iter().all(|b| !b.structural()));
        let relaxed = CapacitySpec {
            memory: "warning".into(),
            ..spec
        };
        assert!(blockers(&relaxed, &reading(10., "warning"), Uses::MAC, &[]).is_empty());
        assert!(!blockers(&relaxed, &reading(10., "critical"), Uses::MAC, &[]).is_empty());
    }

    #[test]
    fn uses_parse_and_names() {
        let names = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(Uses::parse(&names(&["cpu", "memory"])), Ok(Uses::MAC));
        assert_eq!(Uses::ALL.names(), ["cpu", "memory", "containers"]);
        assert!(Uses::parse(&names(&[])).is_err());
        assert!(Uses::parse(&names(&["disk"])).unwrap_err().contains("disk"));
        assert_eq!(
            Uses::MAC.union(Uses {
                containers: true,
                ..Default::default()
            }),
            Uses::ALL
        );
    }

    #[test]
    fn advice_reads_the_vm_and_proposes_what_commands_load() {
        use crate::containers::{ContainerMemory, VmMemory};
        let c = |name: &str, used: f64, limit: Option<f64>| ContainerMemory {
            name: name.into(),
            used,
            limit,
            project: Some("leilotech".into()),
            service: Some(
                name.trim_start_matches("leilotech-")
                    .trim_end_matches("-1")
                    .into(),
            ),
        };
        let running = vec![
            c("leilotech-mysql-1", 0.98e9, Some(1.07e9)),
            c("leilotech-redis-1", 0.03e9, Some(0.5e9)),
            c("leilotech-hindsight", 0.9e9, None),
        ];
        let vm = VmMemory {
            engine: "OrbStack",
            total: 4.2e9,
            available: Some(1.3e9),
            containers_used: 1.9e9,
            top: running.clone(),
            running,
            near_limit: vec![],
            killed: vec![],
        };
        let spec = CapacitySpec {
            heavy_commands: vec![
                HeavyCommand::Prefix("php artisan test".into()),
                HeavyCommand::Prefix("go test".into()),
                HeavyCommand::Prefix("docker compose up".into()),
            ],
            ..Default::default()
        };
        let a = advice(
            Some(&spec),
            &[vm],
            &["mysql".into(), "redis".into(), "s3".into()],
            10,
        );
        assert!(
            a.findings
                .iter()
                .any(|f| f.contains("Without a memory limit") && f.contains("leilotech-hindsight")),
            "{:?}",
            a.findings
        );
        assert!(
            a.findings
                .iter()
                .any(|f| f.starts_with("leilotech-mysql-1 sits at 92%")),
            "{:?}",
            a.findings
        );
        assert_eq!(a.commands[0].containers, ["mysql", "redis"]);
        assert_eq!(a.commands[0].uses, ["cpu", "memory", "containers"]);
        assert_eq!(
            (a.commands[1].uses.len(), a.commands[1].containers.len()),
            (2, 0)
        );
        assert!(a.yaml.contains("      - go test"), "{}", a.yaml);
        assert!(
            a.yaml.contains("        containers: [mysql, redis]"),
            "{}",
            a.yaml
        );
        let parsed = crate::projectconfig::parse(&a.yaml).unwrap();
        let w = parsed.agents.unwrap().wait_for_capacity.unwrap();
        assert_eq!(w.heavy_commands.len(), 3);
        assert_eq!(w.heavy_commands[0].containers(), ["mysql", "redis"]);
    }
}
