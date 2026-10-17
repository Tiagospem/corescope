//! `corescope mcp`: a local MCP server (JSON-RPC 2.0 over stdio) so coding agents can ask about
//! ports and resources and stop what they themselves started.
//!
//! Stopping is scoped to the calling session: the server finds the agent process that launched
//! it (its nearest ancestor that is a Claude Code / Codex / … session) and only signals that
//! session's descendants — never other sessions, other users, system services, the agent itself
//! or the server's own ancestors. Identity is revalidated by the core right before each signal.
use crate::{agents, databases, free_port, orphans, ports, power, sample, space, subtree, top};
use corescope::{Process, Snapshot, cs_is_same, signal_process};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, Write};
use std::time::Duration;

const SUPPORTED: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

pub fn serve() -> i32 {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let Ok(message) = serde_json::from_str::<Value>(&line) else {
            write(
                &mut out,
                json!({"jsonrpc": "2.0", "id": null,
                "error": {"code": -32700, "message": "parse error"}}),
            );
            continue;
        };
        // Notifications (no id) get no response.
        let Some(id) = message.get("id").cloned() else {
            continue;
        };
        let method = message["method"].as_str().unwrap_or("");
        let response = match method {
            "initialize" => Ok(initialize(&message["params"])),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": tools()})),
            "tools/call" => Ok(call(&message["params"])),
            _ => Err(json!({"code": -32601, "message": format!("method not found: {method}")})),
        };
        write(
            &mut out,
            match response {
                Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                Err(error) => json!({"jsonrpc": "2.0", "id": id, "error": error}),
            },
        );
    }
    0
}

fn write(out: &mut std::io::Stdout, value: Value) {
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn initialize(params: &Value) -> Value {
    let requested = params["protocolVersion"].as_str().unwrap_or("");
    let version = if SUPPORTED.contains(&requested) {
        requested
    } else {
        SUPPORTED[1]
    };
    json!({
        "protocolVersion": version,
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": "corescope", "title": "CoreScope", "version": env!("CARGO_PKG_VERSION")},
        "instructions": "Local view of this Mac's processes, listening ports and resources. Use \
    find_free_port before starting a dev server, list_ports to see what is running where, and \
    stop_port / stop_process to clean up servers you started in this session. Stopping is limited \
    to processes this agent session started."
    })
}

fn tool(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({"name": name, "description": description,
           "inputSchema": {"type": "object", "properties": properties, "required": required}})
}
fn tools() -> Vec<Value> {
    vec![
        tool(
            "list_ports",
            "Listening TCP ports on this Mac with the process, its project folder, \
             what started it (agent, editor, terminal) and whether it is reachable from the network.",
            json!({}),
            &[],
        ),
        tool(
            "find_free_port",
            "First free localhost TCP port at or above `from` (default 3000). \
             Use before starting a dev server.",
            json!({"from": {"type": "integer", "minimum": 1, "maximum": 65535}}),
            &[],
        ),
        tool(
            "top_processes",
            "Processes using the most CPU (percent of one core) or memory (bytes).",
            json!({"by": {"type": "string", "enum": ["cpu", "memory", "energy"]}, "limit": {"type": "integer", "minimum": 1, "maximum": 50}}),
            &[],
        ),
        tool(
            "system_summary",
            "Overall CPU, memory, swap and thermal state, plus counts of listening \
             servers and orphaned dev processes.",
            json!({}),
            &[],
        ),
        tool(
            "list_agent_sessions",
            "AI agent sessions (Claude Code, Codex, …) with their project, the \
             processes they started, ports, CPU and memory.",
            json!({}),
            &[],
        ),
        tool(
            "list_orphans",
            "Dev runtimes still running without their parent (their terminal, editor \
             or agent went away).",
            json!({}),
            &[],
        ),
        tool(
            "list_dev_space",
            "Reclaimable developer disk space: node_modules, Rust target/, Xcode DerivedData, \
             package-manager caches and unused Docker data, with sizes and whether a process \
             uses each one. Read-only and takes a few seconds; deleting is done by the user in \
             the CoreScope app. Optional folders to scan (default: detected project folders).",
            json!({"folders": {"type": "array", "items": {"type": "string"}}}),
            &[],
        ),
        tool(
            "power_usage",
            "Battery (percent, charging, time left), total power drawn by processes, the top \
             processes by watts and each agent session's power including what it started.",
            json!({}),
            &[],
        ),
        tool(
            "list_databases",
            "Local MySQL/MariaDB, PostgreSQL and Redis servers (processes and containers): \
             version, size per database, connections, slow and long-running queries. \
             Read-only; servers that need a password are reported as such (none is used).",
            json!({}),
            &[],
        ),
        tool(
            "list_my_processes",
            "Processes started by this agent session (the ones stop_process and \
             stop_port may act on).",
            json!({}),
            &[],
        ),
        tool(
            "stop_port",
            "Stop the process(es) listening on a port, only if this agent session \
             started them. SIGTERM by default; force=true sends SIGKILL.",
            json!({"port": {"type": "integer", "minimum": 1, "maximum": 65535}, "force": {"type": "boolean"}}),
            &["port"],
        ),
        tool(
            "stop_process",
            "Stop a process (tree=true also stops its descendants), only if this agent \
             session started it. SIGTERM by default; force=true sends SIGKILL.",
            json!({"pid": {"type": "integer"}, "tree": {"type": "boolean"}, "force": {"type": "boolean"}}),
            &["pid"],
        ),
    ]
}

fn text(value: Value, error: bool) -> Value {
    json!({"content": [{"type": "text", "text": value.to_string()}], "isError": error})
}

fn call(params: &Value) -> Value {
    let args = &params["arguments"];
    let name = params["name"].as_str().unwrap_or("");
    match name {
        "list_ports" => text(ports(&sample(false)), false),
        "find_free_port" => {
            let from = args["from"].as_u64().unwrap_or(3000).clamp(1, 65535) as u16;
            text(free_port(from, &sample(false)), false)
        }
        "top_processes" => {
            let by = match args["by"].as_str() {
                Some("memory") => "memory",
                Some("energy") => "energy",
                _ => "cpu",
            };
            let limit = args["limit"].as_u64().unwrap_or(10).clamp(1, 50) as usize;
            text(top(&sample(true), by, limit), false)
        }
        "system_summary" => text(summary(&sample(true)), false),
        "list_agent_sessions" => text(agents(&sample(true)), false),
        "list_orphans" => text(orphans(&sample(false)), false),
        "list_databases" => text(databases(&sample(false)), false),
        "power_usage" => text(power(&sample(true)), false),
        "list_dev_space" => {
            let folders: Vec<std::path::PathBuf> = args["folders"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(Into::into)
                .collect();
            text(space(&folders, true), false)
        }
        "list_my_processes" => {
            let snapshot = sample(false);
            match session(&snapshot) {
                Some(root) => text(
                    json!({"session": root_json(root),
                    "processes": own(&snapshot, root).iter().map(|p| brief(p)).collect::<Vec<_>>()}),
                    false,
                ),
                None => text(json!({"error": NO_SESSION}), true),
            }
        }
        "stop_port" => match args["port"].as_u64().filter(|p| (1..=65535).contains(p)) {
            Some(port) => {
                let snapshot = sample(false);
                let listening: Vec<&Process> = snapshot
                    .processes
                    .iter()
                    .filter(|p| p.ports.iter().any(|x| u64::from(x.port) == port))
                    .collect();
                if listening.is_empty() {
                    return text(
                        json!({"error": format!("nothing is listening on port {port}")}),
                        true,
                    );
                }
                stop(
                    &snapshot,
                    listening,
                    args["force"].as_bool().unwrap_or(false),
                )
            }
            None => text(
                json!({"error": "port must be an integer between 1 and 65535"}),
                true,
            ),
        },
        "stop_process" => match args["pid"].as_i64().and_then(|p| i32::try_from(p).ok()) {
            Some(pid) => {
                let snapshot = sample(false);
                let targets: Vec<&Process> = if args["tree"].as_bool().unwrap_or(false) {
                    subtree(&snapshot, pid)
                } else {
                    snapshot.processes.iter().filter(|p| p.pid == pid).collect()
                };
                if targets.is_empty() {
                    return text(json!({"error": format!("no process with PID {pid}")}), true);
                }
                stop(&snapshot, targets, args["force"].as_bool().unwrap_or(false))
            }
            None => text(json!({"error": "pid must be an integer"}), true),
        },
        _ => text(json!({"error": format!("unknown tool: {name}")}), true),
    }
}

const NO_SESSION: &str = "this MCP server was not launched by a recognized agent session, so it \
cannot tell which processes are yours; stopping is disabled";

/// The agent session that launched this server: nearest ancestor that is an agent process.
pub fn session(snapshot: &Snapshot) -> Option<&Process> {
    let index: HashMap<i32, &Process> = snapshot.processes.iter().map(|p| (p.pid, p)).collect();
    let mut pid = std::os::unix::process::parent_id() as i32;
    for _ in 0..48 {
        let p = index.get(&pid)?;
        if p.tags.contains(&"agent") {
            return Some(p);
        }
        if p.ppid <= 1 {
            return None;
        }
        pid = p.ppid;
    }
    None
}
/// What this session may stop: its descendants (minus this server and its own ancestors), plus
/// processes it started in the background that launchd adopted once their shell exited (see
/// `claims`).
fn own<'a>(snapshot: &'a Snapshot, root: &Process) -> Vec<&'a Process> {
    let index: HashMap<i32, &Process> = snapshot.processes.iter().map(|p| (p.pid, p)).collect();
    let mut chain: HashSet<i32> = HashSet::from([std::process::id() as i32]);
    let mut pid = std::os::unix::process::parent_id() as i32;
    while let Some(p) = index.get(&pid) {
        if !chain.insert(pid) || p.ppid <= 1 {
            break;
        }
        pid = p.ppid;
    }
    let mut out: Vec<&Process> = subtree(snapshot, root.pid)
        .into_iter()
        .filter(|p| p.pid != root.pid && !chain.contains(&p.pid))
        .collect();
    let sessions: Vec<(i32, &str, u64)> = snapshot
        .processes
        .iter()
        .filter(|p| p.tags.contains(&"agent"))
        .map(|p| (p.pid, p.cwd.as_str(), p.start))
        .collect();
    for p in &snapshot.processes {
        let detached = p.ppid == 1
            && p.uid == root.uid
            && p.eligible
            // GUI apps are never "started in the background" by a session; tool runtimes that
            // live in a bundle (e.g. Command Line Tools' Python.app) still count.
            && !(p.path.contains("/Applications/") && p.path.contains(".app/"));
        if detached
            && !out.iter().any(|o| o.pid == p.pid)
            && claims(
                (root.pid, &root.cwd, root.start),
                (&p.cwd, p.start),
                &sessions,
            )
        {
            out.push(p);
        }
    }
    out
}
/// Is `folder` the same as or a parent of `cwd` (whole path components only)?
fn inside(cwd: &str, folder: &str) -> bool {
    !folder.is_empty() && folder != "/" && (cwd == folder || cwd.starts_with(&format!("{folder}/")))
}
/// A detached process (cwd, start) belongs to session `root` (pid, cwd, start) when it started
/// after the session, inside its folder, and no other live session covers it at least as
/// specifically and started before it (then the owner is ambiguous and nobody claims it).
fn claims(root: (i32, &str, u64), process: (&str, u64), sessions: &[(i32, &str, u64)]) -> bool {
    let (root_pid, root_cwd, root_start) = root;
    let (cwd, start) = process;
    if start < root_start || !inside(cwd, root_cwd) {
        return false;
    }
    !sessions.iter().any(|&(pid, folder, began)| {
        pid != root_pid
            && began <= start
            && inside(cwd, folder)
            && !(inside(root_cwd, folder) && root_cwd != folder)
    })
}
fn root_json(root: &Process) -> Value {
    json!({"agent": root.host, "pid": root.pid, "cwd": root.cwd})
}
fn brief(p: &Process) -> Value {
    json!({"pid": p.pid, "name": p.name, "cwd": p.cwd,
           "relation": if p.ppid == 1 { "started in this session's folder, now detached" } else { "child of this session" },
           "ports": p.ports.iter().map(|x| x.port).collect::<Vec<_>>(),
           "memory_bytes": p.memory.value})
}

/// Signals only targets inside the calling session; reports everything else as refused.
fn stop(snapshot: &Snapshot, targets: Vec<&Process>, force: bool) -> Value {
    let Some(root) = session(snapshot) else {
        return text(json!({"error": NO_SESSION}), true);
    };
    let allowed: HashSet<i32> = own(snapshot, root).iter().map(|p| p.pid).collect();
    let mut results = Vec::new();
    let mut sent = Vec::new();
    // Children first, so a parent does not respawn them.
    for p in targets.iter().rev() {
        if !allowed.contains(&p.pid) {
            results.push(json!({"pid": p.pid, "name": p.name, "status": "refused",
                "reason": "not started by this agent session (ask the user, or use the CoreScope app)"}));
            continue;
        }
        match signal_process(p.pid, p.start, &p.path, force) {
            Ok(()) => sent.push(*p),
            Err(e) => results.push(json!({"pid": p.pid, "name": p.name, "status": "refused",
                "reason": crate::english(&e)})),
        }
    }
    if !sent.is_empty() {
        std::thread::sleep(Duration::from_secs(2));
    }
    for p in sent {
        let alive = cs_is_same(p.pid, p.start) == 1;
        results.push(json!({"pid": p.pid, "name": p.name,
            "status": if alive {"still running (retry with force=true)"} else {"terminated"}}));
    }
    let failed = !results.iter().any(|r| r["status"] == "terminated");
    text(
        json!({"signal": if force {"SIGKILL"} else {"SIGTERM"}, "session": root_json(root),
                "results": results}),
        failed,
    )
}

fn summary(snapshot: &Snapshot) -> Value {
    let used = [&snapshot.active, &snapshot.wired, &snapshot.compressed]
        .iter()
        .map(|m| m.value)
        .sum::<Option<f64>>();
    json!({
        "cpu_percent": snapshot.cpu.value, "cores": snapshot.cores,
        "memory_used_bytes": used, "memory_total_bytes": snapshot.physical.value,
        "swap_used_bytes": snapshot.swap.value,
        "thermal_state": snapshot.thermal.value,
        "listening_servers": snapshot.processes.iter().filter(|p| !p.ports.is_empty()).count(),
        "orphans": snapshot.processes.iter().filter(|p| p.orphan.is_some()).count(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detached_processes_are_claimed_only_without_ambiguity() {
        let root = (10, "/work/app", 100);
        assert!(claims(root, ("/work/app", 150), &[root]));
        assert!(claims(root, ("/work/app/web", 150), &[root]));
        assert!(
            !claims(root, ("/work/application", 150), &[root]),
            "prefix is not a folder"
        );
        assert!(
            !claims(root, ("/work/app", 50), &[root]),
            "started before the session"
        );
        assert!(
            !claims(root, ("/tmp", 150), &[root]),
            "outside the session folder"
        );
        // Another session in the same folder that started before the process: ambiguous.
        assert!(!claims(
            root,
            ("/work/app", 150),
            &[root, (11, "/work/app", 120)]
        ));
        // A more specific session (subfolder) owns processes started there.
        assert!(!claims(
            root,
            ("/work/app/web", 150),
            &[root, (12, "/work/app/web", 110)]
        ));
        // A session on a parent folder does not compete with the more specific one.
        assert!(claims(root, ("/work/app", 150), &[root, (13, "/work", 90)]));
    }
    #[test]
    fn protocol_version_is_negotiated() {
        assert_eq!(
            initialize(&json!({"protocolVersion": "2025-03-26"}))["protocolVersion"],
            "2025-03-26"
        );
        assert_eq!(
            initialize(&json!({"protocolVersion": "1999-01-01"}))["protocolVersion"],
            SUPPORTED[1]
        );
    }
    #[test]
    fn every_tool_has_an_object_schema() {
        for t in tools() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
            assert!(t["description"].as_str().unwrap().len() > 20);
        }
    }
    #[test]
    fn processes_outside_the_session_are_never_stopped() {
        // Detached to launchd and started outside any project folder, so no agent session
        // (whichever ran the tests) can claim it.
        let out = std::process::Command::new("/bin/sh")
            .args(["-c", "/bin/sleep 30 >/dev/null 2>&1 & echo $!"])
            .current_dir(std::env::temp_dir())
            .output()
            .unwrap();
        let pid: i32 = String::from_utf8_lossy(&out.stdout).trim().parse().unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let reply = call(&json!({"name": "stop_process", "arguments": {"pid": pid}}));
        assert_eq!(reply["isError"], true);
        let alive = std::process::Command::new("/bin/kill")
            .args(["-0", &pid.to_string()])
            .status()
            .unwrap()
            .success();
        assert!(alive, "a process outside the session must still be running");
        let _ = std::process::Command::new("/bin/kill")
            .arg(pid.to_string())
            .status();
    }
}
