//! Whether the Mac has room for heavy work right now, and which commands count as heavy. Agents
//! wait on this (a Claude Code hook running `corescope gate`, or the MCP tool `wait_for_capacity`)
//! before builds and test suites, so a busy machine is not pushed into hours-long sessions.
use crate::projectconfig::CapacitySpec;
use serde::Serialize;

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

/// Empty when there is room; otherwise why not, in plain words.
pub fn blockers(spec: &CapacitySpec, r: &Reading) -> Vec<String> {
    let mut out = vec![];
    if r.cpu >= spec.cpu_below {
        out.push(format!(
            "CPU at {:.0}% (limit {:.0}%)",
            r.cpu, spec.cpu_below
        ));
    }
    if let Some(m) = &r.memory
        && rank(m) > rank(&spec.memory)
    {
        let available = r
            .available
            .map(|a| format!(", {a:.0}% available"))
            .unwrap_or_default();
        out.push(format!(
            "memory pressure {m}{available} (limit {})",
            spec.memory
        ));
    }
    for vm in &r.containers {
        let free = vm.free_percent();
        if spec.container_memory_free > 0. && free < spec.container_memory_free {
            let top = vm
                .top
                .iter()
                .take(3)
                .map(|c| format!("{} {}", c.name, gb(c.used)))
                .collect::<Vec<_>>()
                .join(", ");
            out.push(format!(
                "{} VM memory {free:.0}% free of {} (limit {:.0}%); containers using most: {top}. \
                 This only clears when containers stop or use less: stop the ones you don't need",
                vm.engine,
                gb(vm.total),
                spec.container_memory_free
            ));
        }
    }
    out
}

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
    Reading {
        cpu: snapshot.cpu.value.unwrap_or(0.),
        memory: effective_memory(crate::os::pressure_level(), available),
        available,
        containers: vec![],
    }
}

/// `reading` plus the container engines' VMs (a few requests to each engine): for the gate.
pub fn full_reading(snapshot: &crate::Snapshot) -> Reading {
    Reading {
        containers: crate::containers::vm_memory(),
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

/// The heavy prefix a command runs, if any (`npm run build` matches `npm run build -- --watch`;
/// `cd web && npm test` matches `npm test`).
pub fn heavy<'a>(command: &str, prefixes: &'a [String]) -> Option<&'a str> {
    let steps = steps(command);
    prefixes.iter().map(String::as_str).find(|p| {
        let p = p.trim();
        !p.is_empty()
            && steps
                .iter()
                .any(|s| s == p || s.starts_with(&format!("{p} ")))
    })
}

/// Prefixes used when a project enables waiting but lists no commands: common builds, test
/// suites and container builds across stacks.
pub const DEFAULT_HEAVY: [&str; 25] = [
    "npm run build",
    "npm test",
    "npm run test",
    "pnpm build",
    "pnpm test",
    "yarn build",
    "yarn test",
    "npx playwright test",
    "cargo build",
    "cargo test",
    "go build",
    "go test",
    "php artisan test",
    "vendor/bin/phpunit",
    "vendor/bin/pest",
    "./vendor/bin/pest",
    "composer install",
    "pytest",
    "docker build",
    "docker compose build",
    "docker compose up",
    "docker-compose up",
    "docker run",
    "xcodebuild",
    "swift build",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heavy_commands_are_found_in_chains() {
        let p: Vec<String> = ["npm run build", "php artisan test"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(
            heavy("cd web && npm run build -- --mode qa", &p),
            Some("npm run build")
        );
        assert_eq!(
            heavy("APP_ENV=testing php artisan test --parallel", &p),
            Some("php artisan test")
        );
        assert_eq!(
            heavy("npm run build-storybook", &p),
            None,
            "a longer script name is another command"
        );
        assert_eq!(heavy("git status; ls -la | grep x", &p), None);
        assert_eq!(
            steps("A=1 B=2 make test && echo ok"),
            ["make test", "echo ok"]
        );
    }

    #[test]
    fn container_vm_memory_blocks_and_warns() {
        use crate::containers::{ContainerMemory, Killed, VmMemory};
        let mysql = ContainerMemory {
            name: "mysql".into(),
            used: 0.96e9,
            limit: Some(1e9),
        };
        let vm = VmMemory {
            engine: "OrbStack",
            total: 4e9,
            available: Some(0.4e9),
            containers_used: 3.4e9,
            top: vec![mysql.clone()],
            near_limit: vec![mysql],
            killed: vec![Killed {
                name: "redis".into(),
                at: 1000.,
                oom: true,
            }],
        };
        let r = Reading {
            cpu: 10.,
            memory: Some("normal".into()),
            available: Some(60.),
            containers: vec![vm.clone()],
        };
        let b = blockers(&CapacitySpec::default(), &r);
        assert_eq!(b.len(), 1, "{b:?}");
        assert!(
            b[0].starts_with("OrbStack VM memory 10% free of 4.0 GB"),
            "{}",
            b[0]
        );
        assert!(b[0].contains("mysql 960 MB"), "{}", b[0]);
        let off = CapacitySpec {
            container_memory_free: 0.,
            ..Default::default()
        };
        assert!(blockers(&off, &r).is_empty());
        let roomy = Reading {
            containers: vec![VmMemory {
                available: Some(2e9),
                ..vm
            }],
            ..r
        };
        assert!(blockers(&CapacitySpec::default(), &roomy).is_empty());
        let w = warnings(&roomy, 1000. + 300.);
        assert_eq!(w.len(), 2, "{w:?}");
        assert!(
            w[0].starts_with("mysql uses 960 MB of its 1.0 GB limit (96%)"),
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
    fn blocks_on_cpu_and_memory() {
        let spec = CapacitySpec {
            cpu_below: 70.,
            memory: "normal".into(),
            ..Default::default()
        };
        assert!(
            blockers(
                &spec,
                &Reading {
                    cpu: 40.,
                    memory: Some("normal".into()),
                    available: None,
                    containers: vec![],
                }
            )
            .is_empty()
        );
        assert_eq!(
            blockers(
                &spec,
                &Reading {
                    cpu: 85.,
                    memory: None,
                    available: None,
                    containers: vec![],
                }
            )
            .len(),
            1
        );
        let both = blockers(
            &spec,
            &Reading {
                cpu: 90.,
                memory: Some("warning".into()),
                available: None,
                containers: vec![],
            },
        );
        assert_eq!(both.len(), 2, "{both:?}");
        let relaxed = CapacitySpec {
            memory: "warning".into(),
            ..spec
        };
        assert!(
            blockers(
                &relaxed,
                &Reading {
                    cpu: 10.,
                    memory: Some("warning".into()),
                    available: None,
                    containers: vec![],
                }
            )
            .is_empty()
        );
        assert!(
            !blockers(
                &relaxed,
                &Reading {
                    cpu: 10.,
                    memory: Some("critical".into()),
                    available: None,
                    containers: vec![],
                }
            )
            .is_empty()
        );
    }
}
