//! `corescope`: command-line access to CoreScope's process view, for people and for agents.
//! Same sampling and the same safe termination as the app: only the current user's eligible
//! processes, identity (PID + start time + executable) revalidated right before each signal.
mod mcp;

use corescope::{Collector, Config, Process, Snapshot, cs_is_same, devspace, signal_process};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{IsTerminal, Write};
use std::net::TcpListener;
use std::time::Duration;

const HELP: &str = "corescope — developer-focused process view for macOS

USAGE:
  corescope ports                       listening TCP ports with process, project and origin
  corescope free-port [FROM]            first free localhost port from FROM (default 3000)
  corescope kill-port PORT [--force]    stop the processes listening on PORT
  corescope agents                      AI agent sessions and what they started
  corescope orphans                     dev runtimes left running without their parent
  corescope top [--mem|--energy] [-n N] top processes by CPU (or memory, or power)
  corescope kill PID [--tree] [--force] stop a process (and its descendants with --tree)
  corescope space [FOLDER...]           reclaimable dev space: node_modules, Rust target/, Xcode,
                                        package caches, unused Docker data (read-only; delete
                                        from the CoreScope app, which moves folders to the Trash)
  corescope power                       battery, total power, top processes and agent sessions by watts
  corescope db                          local MySQL/PostgreSQL/Redis: size, connections, slow
                                        and long-running queries (no passwords used or read)
  corescope mcp                         run the local MCP server on stdio

OPTIONS:
  --json     machine-readable output
  --yes      do not ask for confirmation (required when stdin is not a terminal)
  --force    SIGKILL instead of SIGTERM

Only your own, eligible processes can be stopped; system services and CoreScope's own
ancestors are refused. Nothing runs in the background and nothing is sent anywhere.";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| args.iter().any(|a| a == name);
    let json_out = flag("--json");
    let positional: Vec<&str> = args
        .iter()
        .filter(|a| !a.starts_with('-'))
        .map(String::as_str)
        .collect();
    let number = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .and_then(|v| v.parse::<usize>().ok())
    };
    let code = match positional.first().copied() {
        None | Some("help") => {
            println!("{HELP}");
            0
        }
        Some("ports") => print(json_out, ports(&sample(false))),
        Some("free-port") => {
            let from = positional
                .get(1)
                .and_then(|v| v.parse().ok())
                .unwrap_or(3000);
            print(json_out, free_port(from, &sample(false)))
        }
        Some("agents") => print(json_out, agents(&sample(true))),
        Some("orphans") => print(json_out, orphans(&sample(false))),
        Some("top") => print(
            json_out,
            top(
                &sample(true),
                if flag("--mem") {
                    "memory"
                } else if flag("--energy") {
                    "energy"
                } else {
                    "cpu"
                },
                number("-n").unwrap_or(10),
            ),
        ),
        Some("kill-port") => match positional.get(1).and_then(|v| v.parse::<u16>().ok()) {
            Some(port) => {
                let snapshot = sample(false);
                let targets: Vec<&Process> = snapshot
                    .processes
                    .iter()
                    .filter(|p| p.ports.iter().any(|x| x.port == port))
                    .collect();
                terminate(&targets, flag("--force"), flag("--yes"), json_out)
            }
            None => fail(
                json_out,
                "usage: corescope kill-port PORT [--force] [--yes]",
            ),
        },
        Some("kill") => match positional.get(1).and_then(|v| v.parse::<i32>().ok()) {
            Some(pid) => {
                let snapshot = sample(false);
                let targets = if flag("--tree") {
                    subtree(&snapshot, pid)
                } else {
                    snapshot.processes.iter().filter(|p| p.pid == pid).collect()
                };
                terminate(&targets, flag("--force"), flag("--yes"), json_out)
            }
            None => fail(
                json_out,
                "usage: corescope kill PID [--tree] [--force] [--yes]",
            ),
        },
        Some("space") => {
            let folders: Vec<std::path::PathBuf> = positional[1..].iter().map(Into::into).collect();
            print(json_out, space(&folders, !flag("--no-docker")))
        }
        Some("db") => print(json_out, databases(&sample(false))),
        Some("power") => print(json_out, power(&sample(true))),
        Some("mcp") => mcp::serve(),
        Some(other) => fail(
            json_out,
            &format!("unknown command: {other}. Try `corescope help`."),
        ),
    };
    std::process::exit(code);
}

/// One sample gives ports, folders and origins; CPU needs a second one a moment later.
pub fn sample(with_cpu: bool) -> Snapshot {
    let mut collector = Collector::default();
    let first = collector.sample(Config::default());
    if !with_cpu {
        return first;
    }
    std::thread::sleep(Duration::from_millis(700));
    collector.sample(Config::default())
}

/// Parent of each process, and the process itself, for tree walks.
fn by_pid(snapshot: &Snapshot) -> HashMap<i32, &Process> {
    snapshot.processes.iter().map(|p| (p.pid, p)).collect()
}
/// Root first, then every descendant (children before parents when reversed for signaling).
pub fn subtree(snapshot: &Snapshot, root: i32) -> Vec<&Process> {
    let index = by_pid(snapshot);
    let mut ids = vec![root];
    let mut seen: HashSet<i32> = HashSet::from([root]);
    let mut i = 0;
    while i < ids.len() {
        for p in &snapshot.processes {
            if p.ppid == ids[i] && seen.insert(p.pid) {
                ids.push(p.pid);
            }
        }
        i += 1;
    }
    ids.iter().filter_map(|id| index.get(id).copied()).collect()
}
fn project(p: &Process) -> Option<String> {
    let home = std::env::var("HOME").unwrap_or_default();
    (!p.cwd.is_empty()
        && p.cwd != "/"
        && p.cwd != home
        && !p.cwd.starts_with(&format!("{home}/Library/")))
    .then(|| p.cwd.rsplit('/').next().unwrap_or("").to_string())
}
fn process_json(p: &Process) -> Value {
    json!({
        "pid": p.pid, "ppid": p.ppid, "name": p.name, "path": p.path, "cwd": p.cwd,
        "project": project(p),
        "origin": p.origin.as_ref().map(|o| json!({"label": o.label, "kind": o.kind, "pid": o.pid})),
        "ports": p.ports.iter().map(|x| json!({"port": x.port, "exposed": x.exposed})).collect::<Vec<_>>(),
        "cpu_percent": p.cpu.value, "memory_bytes": p.memory.value, "power_watts": p.energy.value,
        "eligible": p.eligible, "orphan": p.orphan.is_some(),
    })
}

pub fn ports(snapshot: &Snapshot) -> Value {
    let mut rows: Vec<Value> = snapshot
        .processes
        .iter()
        .filter(|p| !p.ports.is_empty())
        .flat_map(|p| {
            p.ports.iter().map(
                move |x| json!({"port": x.port, "exposed": x.exposed, "process": process_json(p)}),
            )
        })
        .collect();
    rows.sort_by_key(|r| r["port"].as_u64().unwrap_or(0));
    rows.dedup_by(|a, b| a["port"] == b["port"] && a["process"]["name"] == b["process"]["name"]);
    json!({"ports": rows})
}

pub fn free_port(from: u16, snapshot: &Snapshot) -> Value {
    let taken: HashSet<u16> = snapshot
        .processes
        .iter()
        .flat_map(|p| p.ports.iter().map(|x| x.port))
        .collect();
    let free = (from..=u16::MAX).find(|port| {
        !taken.contains(port)
            && TcpListener::bind(("127.0.0.1", *port)).is_ok()
            && TcpListener::bind(("0.0.0.0", *port)).is_ok()
    });
    json!({"free_port": free, "from": from})
}

pub fn agents(snapshot: &Snapshot) -> Value {
    let roots = snapshot.processes.iter().filter(|p| {
        p.tags.contains(&"agent")
            && !p.host.is_some_and(|h| h.ends_with("Desktop"))
            && p.origin.as_ref().map(|o| o.label) != p.host
    });
    let sessions: Vec<Value> = roots
        .map(|root| {
            let tree = subtree(snapshot, root.pid);
            json!({
                "agent": root.host, "pid": root.pid, "project": project(root), "cwd": root.cwd,
                "started_via": root.origin.as_ref().map(|o| o.label),
                "processes": tree.len(),
                "cpu_percent": tree.iter().filter_map(|p| p.cpu.value).sum::<f64>(),
                "memory_bytes": tree.iter().filter_map(|p| p.memory.value).sum::<f64>(),
                "power_watts": tree.iter().filter_map(|p| p.energy.value).sum::<f64>(),
                "ports": tree.iter().flat_map(|p| p.ports.iter().map(|x| x.port)).collect::<Vec<_>>(),
                "children": tree.iter().skip(1).map(|p| process_json(p)).collect::<Vec<_>>(),
            })
        })
        .collect();
    json!({"agents": sessions})
}

pub fn orphans(snapshot: &Snapshot) -> Value {
    let rows: Vec<Value> = snapshot
        .processes
        .iter()
        .filter(|p| p.orphan.is_some())
        .map(|p| {
            let mut v = process_json(p);
            v["reason"] = json!(p.orphan.as_deref().map(english));
            v
        })
        .collect();
    json!({"orphans": rows})
}

/// Battery, total power and who uses it: processes and agent sessions (with what they started).
pub fn power(snapshot: &Snapshot) -> Value {
    let mut sessions = agents(snapshot)["agents"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    for s in &mut sessions {
        if let Some(o) = s.as_object_mut() {
            o.remove("children");
        }
    }
    sessions.sort_by(|a, b| {
        b["power_watts"]
            .as_f64()
            .unwrap_or(0.)
            .total_cmp(&a["power_watts"].as_f64().unwrap_or(0.))
    });
    json!({
        "battery": snapshot.battery.as_ref().map(|b| json!({
            "percent": b.percent, "charging": b.charging, "on_ac_power": b.on_ac, "minutes": b.minutes})),
        "total_watts": snapshot.power.value,
        "top": top(snapshot, "energy", 10)["processes"],
        "agent_sessions": sessions,
    })
}

/// Heaviest processes by "cpu", "memory" or "energy" (average watts billed since the last sample).
pub fn top(snapshot: &Snapshot, by: &str, count: usize) -> Value {
    let mut rows: Vec<&Process> = snapshot.processes.iter().collect();
    let key = |p: &&Process| {
        match by {
            "memory" => p.memory.value,
            "energy" => p.energy.value,
            _ => p.cpu.value,
        }
        .unwrap_or(-1.)
    };
    rows.sort_by(|a, b| key(b).total_cmp(&key(a)));
    json!({"by": by,
           "processes": rows.iter().take(count).map(|p| process_json(p)).collect::<Vec<_>>()})
}

/// Local databases found among processes and containers, probed read-only.
pub fn databases(snapshot: &Snapshot) -> Value {
    let containers = corescope::containers::Reader::default()
        .read(false)
        .containers;
    let found = corescope::databases::probe(corescope::databases::detect(
        &snapshot.processes,
        &containers,
    ));
    json!({ "databases": found })
}

/// Reclaimable space under FOLDERs, or under the suggested folders when none are given.
pub fn space(folders: &[std::path::PathBuf], docker: bool) -> Value {
    let home: std::path::PathBuf = std::env::var_os("HOME").map(Into::into).unwrap_or_default();
    let snapshot = sample(false);
    let roots = devspace::normalize(if folders.is_empty() {
        devspace::auto_roots(&home, &snapshot.processes)
    } else {
        folders.to_vec()
    });
    let report = devspace::scan(&roots, &home, &snapshot.processes, docker);
    let total: u64 = report
        .items
        .iter()
        .filter(|i| i.busy.is_none())
        .map(|i| i.bytes)
        .sum();
    json!({"space": report.items, "roots": report.roots, "reclaimable_bytes": total,
           "docker_error": report.docker_error, "seconds": report.seconds})
}

/// Core messages are Portuguese (the app translates them); the CLI speaks English.
fn english(error: &str) -> String {
    let table = [
        ("Pertence a outro usuário", "belongs to another user"),
        ("Serviço essencial protegido", "protected system service"),
        (
            "Processo protegido ou ancestral do CoreScope",
            "protected, or an ancestor of this command",
        ),
        (
            "Identidade inválida ou processo do sistema",
            "invalid identity or system process",
        ),
        (
            "Executável indisponível; ação bloqueada",
            "executable unavailable; refused",
        ),
        (
            "Processo encerrou ou está sem permissão",
            "already exited or not accessible",
        ),
        ("Identidade mudou", "identity changed (PID reused); refused"),
        ("Conexão recusada", "connection refused"),
        ("Sem resposta", "no answer"),
        ("Não é MySQL", "not a MySQL server"),
        ("Não é PostgreSQL", "not a PostgreSQL server"),
        ("Não é Redis", "not a Redis server"),
        (
            "O processo pai encerrou",
            "its parent exited and it kept running, adopted by launchd",
        ),
        (
            "Sem processo pai",
            "no parent process (adopted by launchd); dev runtimes usually run under a terminal, editor or agent — may be a service started on purpose",
        ),
    ];
    table
        .iter()
        .find(|(pt, _)| error.starts_with(pt))
        .map(|(_, en)| en.to_string())
        .unwrap_or_else(|| error.to_string())
}

/// SIGTERM (or SIGKILL) children first, then reports what is gone after two seconds.
pub fn terminate(targets: &[&Process], force: bool, yes: bool, json_out: bool) -> i32 {
    if targets.is_empty() {
        return fail(json_out, "no matching process");
    }
    if !yes {
        if !std::io::stdin().is_terminal() {
            return fail(
                json_out,
                "refusing without --yes when stdin is not a terminal",
            );
        }
        eprintln!(
            "{} will be sent to:",
            if force { "SIGKILL" } else { "SIGTERM" }
        );
        for p in targets {
            eprintln!(
                "  {} (PID {}) {}",
                p.name,
                p.pid,
                project(p).unwrap_or_default()
            );
        }
        eprint!("Proceed? [y/N] ");
        let _ = std::io::stderr().flush();
        let mut answer = String::new();
        let _ = std::io::stdin().read_line(&mut answer);
        if !matches!(answer.trim(), "y" | "Y" | "yes") {
            return fail(json_out, "cancelled");
        }
    }
    let mut results = Vec::new();
    let mut sent = Vec::new();
    for p in targets.iter().rev() {
        match signal_process(p.pid, p.start, &p.path, force) {
            Ok(()) => sent.push(*p),
            Err(e) => results.push(
                json!({"pid": p.pid, "name": p.name, "status": "refused", "reason": english(&e)}),
            ),
        }
    }
    if !sent.is_empty() {
        std::thread::sleep(Duration::from_secs(2));
    }
    for p in sent {
        let alive = cs_is_same(p.pid, p.start) == 1;
        results.push(json!({"pid": p.pid, "name": p.name,
            "status": if alive {"still running"} else {"terminated"}}));
    }
    let ok = results.iter().all(|r| r["status"] == "terminated");
    print(
        json_out,
        json!({"signal": if force {"SIGKILL"} else {"SIGTERM"}, "results": results}),
    );
    if ok { 0 } else { 2 }
}

fn fail(json_out: bool, message: &str) -> i32 {
    if json_out {
        println!("{}", json!({"error": message}));
    } else {
        eprintln!("corescope: {message}");
    }
    1
}

/// JSON as-is, or a readable table for people.
fn print(json_out: bool, value: Value) -> i32 {
    if json_out {
        println!("{value}");
        return 0;
    }
    let mb = |v: &Value| {
        v.as_f64()
            .map(|b| format!("{:.0} MB", b / 1_048_576.))
            .unwrap_or("—".into())
    };
    let pct = |v: &Value| v.as_f64().map(|c| format!("{c:.1}%")).unwrap_or("—".into());
    let text = |v: &Value| v.as_str().unwrap_or("—").to_string();
    // serde_json numbers ignore width specifiers: format them as strings first.
    let num = |v: &Value| {
        if v.is_null() {
            "—".to_string()
        } else {
            v.to_string()
        }
    };
    if let Some(rows) = value["ports"].as_array() {
        println!(
            "{:<7} {:<8} {:<24} {:<22} ORIGIN",
            "PORT", "PID", "PROCESS", "PROJECT"
        );
        for r in rows {
            let p = &r["process"];
            println!(
                "{:<7} {:<8} {:<24} {:<22} {}{}",
                num(&r["port"]),
                num(&p["pid"]),
                text(&p["name"]),
                text(&p["project"]),
                text(&p["origin"]["label"]),
                if r["exposed"] == true {
                    "  (network)"
                } else {
                    ""
                }
            );
        }
    } else if value.get("total_watts").is_some() {
        if let Some(b) = value["battery"].as_object() {
            println!(
                "Battery {}%{}{}",
                num(&b["percent"]),
                if b["charging"] == true {
                    " · charging"
                } else if b["on_ac_power"] == true {
                    " · on AC power"
                } else {
                    " · on battery"
                },
                b["minutes"]
                    .as_i64()
                    .map(|m| format!(" · {}h{:02} left", m / 60, m % 60))
                    .unwrap_or_default()
            );
        } else {
            println!("No battery");
        }
        println!(
            "Processes now: {}",
            value["total_watts"]
                .as_f64()
                .map(|w| format!("{w:.2} W"))
                .unwrap_or("—".into())
        );
        println!("\nAGENT SESSIONS");
        for s in value["agent_sessions"].as_array().into_iter().flatten() {
            println!(
                "  {:<14} {:<22} {:>8}",
                text(&s["agent"]),
                text(&s["project"]),
                s["power_watts"]
                    .as_f64()
                    .map(|w| format!("{w:.2} W"))
                    .unwrap_or("—".into())
            );
        }
        println!("\nTOP PROCESSES");
        for p in value["top"].as_array().into_iter().flatten() {
            println!(
                "  {:<8} {:<28} {:>8}",
                num(&p["pid"]),
                text(&p["name"]),
                p["power_watts"]
                    .as_f64()
                    .map(|w| format!("{w:.2} W"))
                    .unwrap_or("—".into())
            );
        }
    } else if let Some(rows) = value["databases"].as_array() {
        if rows.is_empty() {
            println!("no local MySQL, PostgreSQL or Redis found");
        }
        for r in rows {
            let size = r["size"]
                .as_f64()
                .map(|b| format!("{:.1} MB", b / 1_048_576.))
                .unwrap_or("—".into());
            println!(
                "{} :{} {} — {}",
                text(&r["kind"]),
                num(&r["port"]),
                text(&r["label"]),
                match r["status"].as_str() {
                    Some("ok") => format!(
                        "v{} · {} connections · {} · {} slow queries",
                        text(&r["version"]),
                        num(&r["connections"]),
                        size,
                        num(&r["slow_queries"])
                    ),
                    Some("auth") => "needs a password (CoreScope does not use passwords)".into(),
                    _ => english(r["error"].as_str().unwrap_or("error")),
                }
            );
            for d in r["databases"].as_array().into_iter().flatten().take(8) {
                let detail = d["keys"]
                    .as_u64()
                    .map(|k| format!("{k} keys"))
                    .or_else(|| {
                        d["bytes"]
                            .as_f64()
                            .map(|b| format!("{:.1} MB", b / 1_048_576.))
                    })
                    .unwrap_or_default();
                println!("    {:<28} {detail}", text(&d["name"]));
            }
            for q in r["long_queries"].as_array().into_iter().flatten() {
                println!(
                    "    running {}s [{}] {}",
                    num(&q["seconds"]),
                    text(&q["database"]),
                    text(&q["query"])
                );
            }
        }
    } else if let Some(rows) = value["space"].as_array() {
        let size = |v: &Value| {
            let b = v.as_f64().unwrap_or(0.);
            if b >= 1_073_741_824. {
                format!("{:.1} GB", b / 1_073_741_824.)
            } else {
                format!("{:.0} MB", b / 1_048_576.)
            }
        };
        println!("{:>9}  {:<18} {:<34} PATH", "SIZE", "KIND", "NAME");
        for r in rows {
            println!(
                "{:>9}  {:<18} {:<34} {}{}",
                size(&r["bytes"]),
                text(&r["kind"]),
                text(&r["name"]),
                text(&r["path"]),
                r["busy"]
                    .as_str()
                    .map(|b| format!("  (in use by {b})"))
                    .unwrap_or_default()
            );
        }
        println!(
            "\n{} reclaimable · scanned {}",
            size(&value["reclaimable_bytes"]),
            value["roots"]
                .as_array()
                .map(|a| a.iter().map(text).collect::<Vec<_>>().join(", "))
                .unwrap_or_default()
        );
    } else if let Some(port) = value.get("free_port") {
        println!(
            "{}",
            port.as_u64()
                .map(|p| p.to_string())
                .unwrap_or("none".into())
        );
    } else if let Some(rows) = value["agents"].as_array() {
        println!(
            "{:<14} {:<8} {:<22} {:<12} {:>5} {:>7} {:>9}  PORTS",
            "AGENT", "PID", "PROJECT", "VIA", "PROCS", "CPU", "MEMORY"
        );
        for r in rows {
            println!(
                "{:<14} {:<8} {:<22} {:<12} {:>5} {:>7} {:>9}  {}",
                text(&r["agent"]),
                num(&r["pid"]),
                text(&r["project"]),
                text(&r["started_via"]),
                num(&r["processes"]),
                pct(&r["cpu_percent"]),
                mb(&r["memory_bytes"]),
                r["ports"]
                    .as_array()
                    .map(|a| a
                        .iter()
                        .map(|p| format!(":{p}"))
                        .collect::<Vec<_>>()
                        .join(" "))
                    .unwrap_or_default()
            );
        }
    } else if let Some(rows) = value["orphans"].as_array() {
        println!(
            "{:<8} {:<24} {:<22} {:>9}  REASON",
            "PID", "PROCESS", "PROJECT", "MEMORY"
        );
        for r in rows {
            println!(
                "{:<8} {:<24} {:<22} {:>9}  {}",
                num(&r["pid"]),
                text(&r["name"]),
                text(&r["project"]),
                mb(&r["memory_bytes"]),
                text(&r["reason"])
            );
        }
    } else if let Some(rows) = value["processes"].as_array() {
        println!(
            "{:<8} {:<28} {:<22} {:>7} {:>9} {:>8}",
            "PID", "PROCESS", "PROJECT", "CPU", "MEMORY", "POWER"
        );
        for r in rows {
            println!(
                "{:<8} {:<28} {:<22} {:>7} {:>9} {:>8}",
                num(&r["pid"]),
                text(&r["name"]),
                text(&r["project"]),
                pct(&r["cpu_percent"]),
                mb(&r["memory_bytes"]),
                r["power_watts"]
                    .as_f64()
                    .map(|w| format!("{w:.2} W"))
                    .unwrap_or("—".into())
            );
        }
    } else if let Some(rows) = value["results"].as_array() {
        for r in rows {
            println!(
                "{} (PID {}): {}{}",
                text(&r["name"]),
                r["pid"],
                text(&r["status"]),
                r["reason"]
                    .as_str()
                    .map(|x| format!(" — {x}"))
                    .unwrap_or_default()
            );
        }
    } else {
        println!("{value}");
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn free_port_is_bindable_and_skips_taken() {
        let held = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = held.local_addr().unwrap().port();
        let found = free_port(port, &sample(false))["free_port"]
            .as_u64()
            .unwrap() as u16;
        assert!(found > port, "a port in use must be skipped");
        assert!(TcpListener::bind(("127.0.0.1", found)).is_ok());
    }
    #[test]
    #[cfg_attr(not(target_os = "macos"), ignore = "reads the macOS process table")]
    fn subtree_starts_at_root_and_includes_children() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("5")
            .spawn()
            .unwrap();
        let snapshot = sample(false);
        let me = std::process::id() as i32;
        let tree = subtree(&snapshot, me);
        assert_eq!(tree.first().map(|p| p.pid), Some(me));
        assert!(tree.iter().any(|p| p.pid == child.id() as i32));
        child.kill().ok();
        child.wait().ok();
    }
    #[test]
    fn core_errors_are_translated() {
        assert_eq!(
            english("Pertence a outro usuário"),
            "belongs to another user"
        );
        assert!(english("Sem processo pai: adotado").starts_with("no parent process"));
        assert_eq!(english("anything else"), "anything else");
    }
}
