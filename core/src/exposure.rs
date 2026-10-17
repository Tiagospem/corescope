//! What listens beyond localhost (processes and containers), how risky that is, and projects
//! whose preferred ports (`.corescope.yml` › ports) are held by something else.
use crate::{Process, Snapshot, containers};
use serde::Serialize;
use std::path::Path;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Exposure {
    pub port: u16,
    /// Process name, or `container <name>`.
    pub owner: String,
    pub pid: Option<i32>,
    pub container: Option<String>,
    pub project: Option<String>,
    /// "database", "cache", "search", "queue", "mail", "dev", "system" or "other".
    pub kind: &'static str,
    /// "high", "medium" or "low".
    pub risk: &'static str,
    pub advice: String,
}

/// Well-known service ports and what they are.
pub fn service(port: u16) -> Option<(&'static str, &'static str)> {
    Some(match port {
        3306 | 33060 => ("database", "MySQL"),
        5432 => ("database", "PostgreSQL"),
        27017 => ("database", "MongoDB"),
        1433 => ("database", "SQL Server"),
        9042 => ("database", "Cassandra"),
        6379 => ("cache", "Redis"),
        11211 => ("cache", "Memcached"),
        9200 | 9300 => ("search", "Elasticsearch"),
        7700 => ("search", "Meilisearch"),
        8108 => ("search", "Typesense"),
        5672 | 15672 => ("queue", "RabbitMQ"),
        9092 => ("queue", "Kafka"),
        1025 | 8025 => ("mail", "Mailpit/MailHog"),
        _ => return None,
    })
}

fn classify(
    port: u16,
    name: &str,
    tags: &[&str],
    container: bool,
) -> (&'static str, &'static str, String) {
    if let Some((kind, what)) = service(port) {
        let risk = if matches!(kind, "database" | "cache" | "queue") {
            "high"
        } else {
            "medium"
        };
        let fix = if container {
            format!("publish it on 127.0.0.1 only (compose: \"127.0.0.1:{port}:{port}\")")
        } else {
            "bind it to 127.0.0.1 in its config".to_string()
        };
        return (
            kind,
            risk,
            format!(
                "{what} reachable from your network, often with default or no credentials; {fix}"
            ),
        );
    }
    let lower = name.to_lowercase();
    let system = [
        "controlcenter",
        "rapportd",
        "sharingd",
        "airplay",
        "remoted",
        "screensharing",
        "launchd",
    ];
    if system.iter().any(|s| lower.contains(s)) {
        return ("system", "low", "macOS service (AirPlay, Handoff, sharing); turn it off in System Settings if you do not use it".into());
    }
    if container || tags.contains(&"runtime") || tags.contains(&"server") {
        return (
            "dev",
            "medium",
            "dev server reachable from your network (cafés, offices); start it with --host 127.0.0.1 unless you test from another device".into(),
        );
    }
    ("other", "low", "listening on all interfaces".into())
}

/// Everything listening beyond loopback, riskiest first.
pub fn exposures(
    snapshot: &Snapshot,
    list: &[containers::Container],
    project: impl Fn(&Process) -> Option<String>,
) -> Vec<Exposure> {
    let mut out = vec![];
    // Ports a container publishes are held on the host by the VM helper: report the container.
    let mut by_container = std::collections::HashSet::new();
    for c in list.iter().filter(|c| c.state == "running") {
        for p in c.ports.iter().filter(|p| p.exposed && p.proto == "tcp") {
            by_container.insert(p.host);
            let (kind, risk, advice) = classify(p.container, &c.image, &[], true);
            out.push(Exposure {
                port: p.host,
                owner: format!("container {}", c.name),
                pid: None,
                container: Some(c.name.clone()),
                project: c.project.clone(),
                kind,
                risk,
                advice,
            });
        }
    }
    for p in &snapshot.processes {
        for port in p
            .ports
            .iter()
            .filter(|x| x.exposed && !by_container.contains(&x.port))
        {
            let (kind, risk, advice) = classify(port.port, &p.name, &p.tags, false);
            out.push(Exposure {
                port: port.port,
                owner: p.name.clone(),
                pid: Some(p.pid),
                container: None,
                project: project(p),
                kind,
                risk,
                advice,
            });
        }
    }
    let order = |r: &str| match r {
        "high" => 0,
        "medium" => 1,
        _ => 2,
    };
    out.sort_by_key(|e| (order(e.risk), e.port));
    out.dedup_by(|a, b| a.port == b.port && a.owner == b.owner);
    out
}

/// First port at or above `from` that nothing listens on and that binds on loopback and on all
/// interfaces.
pub fn free_port(from: u16, snapshot: &Snapshot) -> Option<u16> {
    let taken: std::collections::HashSet<u16> = snapshot
        .processes
        .iter()
        .flat_map(|p| p.ports.iter().map(|x| x.port))
        .collect();
    (from.max(1)..=u16::MAX).find(|port| {
        !taken.contains(port)
            && std::net::TcpListener::bind(("127.0.0.1", *port)).is_ok()
            && std::net::TcpListener::bind(("0.0.0.0", *port)).is_ok()
    })
}

/// (project name, folder, [(role, port)]).
pub type ProjectPorts = (String, String, Vec<(String, u16)>);

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct PortClaim {
    pub project: String,
    pub folder: String,
    pub role: String,
    pub port: u16,
    /// "free", "ours" (held by this project's own processes) or "taken".
    pub state: &'static str,
    pub held_by: Option<String>,
    pub held_by_project: Option<String>,
    /// A free port near the preferred one when it is taken.
    pub suggestion: Option<u16>,
}

/// Each project's preferred ports, and who holds them.
pub fn claims(
    snapshot: &Snapshot,
    list: &[containers::Container],
    projects: &[ProjectPorts],
    free: impl Fn(u16) -> Option<u16>,
) -> Vec<PortClaim> {
    let mut out = vec![];
    for (name, folder, ports) in projects {
        for (role, port) in ports {
            let holder = snapshot
                .processes
                .iter()
                .find(|p| p.ports.iter().any(|x| x.port == *port));
            let container = list
                .iter()
                .find(|c| c.state == "running" && c.ports.iter().any(|x| x.host == *port));
            let (state, held_by, held_project) = match (holder, container) {
                (_, Some(c)) => {
                    let ours = c
                        .project
                        .as_deref()
                        .is_some_and(|p| folder.ends_with(p) || name.eq_ignore_ascii_case(p));
                    (
                        if ours { "ours" } else { "taken" },
                        Some(format!("container {}", c.name)),
                        c.project.clone(),
                    )
                }
                (Some(p), None) => {
                    let ours = !p.cwd.is_empty() && Path::new(&p.cwd).starts_with(folder);
                    let other = (!p.cwd.is_empty()).then(|| p.cwd.clone());
                    (
                        if ours { "ours" } else { "taken" },
                        Some(format!("{} (PID {})", p.name, p.pid)),
                        other,
                    )
                }
                (None, None) => ("free", None, None),
            };
            out.push(PortClaim {
                project: name.clone(),
                folder: folder.clone(),
                role: role.clone(),
                port: *port,
                state,
                held_by,
                held_by_project: held_project,
                suggestion: (state == "taken")
                    .then(|| free(port.saturating_add(1)))
                    .flatten(),
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn risks_by_port_and_owner() {
        assert_eq!(classify(3306, "mysqld", &[], false).1, "high");
        assert_eq!(classify(6379, "redis", &[], true).0, "cache");
        assert!(
            classify(3306, "x", &[], true)
                .2
                .contains("127.0.0.1:3306:3306")
        );
        assert_eq!(classify(5000, "ControlCenter", &[], false).0, "system");
        assert_eq!(classify(5173, "node", &["runtime"], false).1, "medium");
        assert_eq!(classify(49152, "Spotify", &[], false).1, "low");
    }

    #[test]
    fn preferred_ports_held_by_others() {
        let mut snap_proc = crate::process_fixture();
        snap_proc.ports = vec![crate::Port {
            port: 8000,
            exposed: false,
        }];
        snap_proc.cwd = "/work/other".into();
        let mut ours = crate::process_fixture();
        ours.pid = 7;
        ours.ports = vec![crate::Port {
            port: 5173,
            exposed: false,
        }];
        ours.cwd = "/work/shop/web".into();
        let snapshot = Snapshot::for_tests(vec![snap_proc, ours]);
        let projects = vec![(
            "shop".to_string(),
            "/work/shop".to_string(),
            vec![
                ("web".to_string(), 8000),
                ("vite".to_string(), 5173),
                ("db".to_string(), 3307),
            ],
        )];
        let c = claims(&snapshot, &[], &projects, Some);
        let states: Vec<_> = c.iter().map(|x| (x.port, x.state, x.suggestion)).collect();
        assert_eq!(
            states,
            [
                (8000, "taken", Some(8001)),
                (5173, "ours", None),
                (3307, "free", None)
            ]
        );
    }
}
