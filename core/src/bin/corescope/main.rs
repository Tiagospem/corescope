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
  corescope top [--mem|--energy|--disk] [-n N]
                                        top processes by CPU (or memory, power, disk I/O)
  corescope kill PID [--tree] [--force] stop a process (and its descendants with --tree)
  corescope space [FOLDER...]           reclaimable dev space: node_modules, Rust target/, Xcode,
                                        package caches, unused Docker data (read-only; delete
                                        from the CoreScope app, which moves folders to the Trash)
  corescope power                       battery, total power, top processes and agent sessions by watts
  corescope worktrees [FOLDER...]       git worktrees agents left (Claude Code, Codex, …): branch,
                                        merged, uncommitted changes, last commit, in use
  corescope exposure                    what listens beyond localhost (processes and containers), by risk
  corescope ports --check [FOLDER...]   projects' preferred ports (.corescope.yml): free, ours or taken
  corescope containers                  containers (state, ports, compose project, health), volumes
  corescope logs [FOLDER] [--errors] [--search TEXT] [-n N]
                                        the project's log files: tail, errors with traces, or search
  corescope wait [FOLDER] [--cpu-below N] [--memory normal|warning] [--max-wait MIN]
                                        wait until the Mac has room (the project's .corescope.yml
                                        agents.wait_for_capacity, or the flags), then exit 0
  corescope gate                        Claude Code PreToolUse hook: holds heavy Bash commands until
                                        there is room, in projects that enable it
  corescope config [FOLDER]             validate and show the project's .corescope.yml (default: here)
  corescope db snapshot PORT DATABASE   dump a MySQL/PostgreSQL database (inside its container,
                                        with the container's own credentials) to a gzipped file
  corescope db snapshots | db restore ID   list snapshots / put a database back (asks first)
  corescope db analyze FILE             a .sql / .sql.gz dump's tables, rows and what a restore leaves out
  corescope db import FILE --into NAME --container C [--replace] [--skip t1,t2]
                                        restore a dump into a new (or, --replace, existing) database;
                                        --skip creates those tables empty; --drop-triggers, --no-snapshot
  corescope db redis PORT [--db N]      Redis memory by key prefix and keys without TTL (sampled)
  corescope db                          local MySQL/PostgreSQL/Redis: size, connections, slow
                                        and long-running queries (containers read inside, read-only)
  corescope happened TIME [--minutes N] what the Mac was doing around TIME (14:05, 2:05 pm,
                                        yesterday 9:30, 2026-10-17 14:05): CPU, power, memory,
                                        swap, thermal and who dominated (needs History on)
  corescope disk-growth [--measure]     which usual folders grew today (caches, Xcode, simulators,
                                        container VMs, package stores, models, Downloads, Trash);
                                        --measure measures now (seconds) before reporting
  corescope version [--check]           this CoreScope's version and any update the app found;
                                        --check asks the app to check the release feed now
                                        (one request to GitHub, needs the app running)
  corescope space --plan                safe cleanup plan: caches and stores tools re-create, with
                                        estimates, the exact command and whether the tool is busy
  corescope large-files [--min-mb N] [-n N]
                                        largest files in your home (default 1024 MB, top 50): kind,
                                        age and the app that manages it (read-only)
  corescope eject-check VOLUME          what keeps a volume from ejecting: programs running from it,
                                        open files and working folders (read-only)
  corescope projects                    registered projects: branch, worktree, .corescope.yml status
  corescope context [FOLDER]            what the project's .corescope.yml asks of agents (capacity, ports,
                                        profiles, services, logs); --write CLAUDE.md|AGENTS.md|all puts it
                                        in a marked section, --remove takes it out; --hook for SessionStart
  corescope status [PROJECT|FOLDER]     git changes of a project (or this folder): branch, staged, modified, new
  corescope branches [PROJECT|FOLDER]   local branches: current, last commit, ahead/behind, worktree
  corescope disk-health                 SSD health from NVMe SMART: wear, data written, power-on
                                        hours, unsafe shutdowns, media errors and a verdict
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
        Some("ports") if flag("--check") => {
            let folders: Vec<std::path::PathBuf> = positional[1..].iter().map(Into::into).collect();
            print(json_out, port_claims(&folders))
        }
        Some("ports") => print(json_out, ports(&sample(false))),
        Some("exposure") => print(json_out, exposure()),
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
                } else if flag("--disk") {
                    "disk"
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
        Some("space") if flag("--plan") => {
            let home: std::path::PathBuf =
                std::env::var_os("HOME").map(Into::into).unwrap_or_default();
            let actions = corescope::cleanplan::plan(&home, &sample(false).processes, true);
            if json_out {
                print(true, json!(actions))
            } else {
                for a in &actions {
                    println!(
                        "{:>10}  {}{}\n            {}",
                        format!(
                            "{}{:.1} GB",
                            if a.up_to { "≤" } else { "" },
                            a.estimate as f64 / 1e9
                        ),
                        a.title,
                        a.busy
                            .as_ref()
                            .map(|b| format!("  [busy: {b}]"))
                            .unwrap_or_default(),
                        a.command
                    );
                }
                0
            }
        }
        Some("space") => {
            let folders: Vec<std::path::PathBuf> = positional[1..].iter().map(Into::into).collect();
            print(json_out, space(&folders, !flag("--no-docker")))
        }
        Some("db") if matches!(positional.get(1).copied(), Some("analyze" | "import")) => {
            db_dump(&args, &positional, json_out)
        }
        Some("db") if positional.len() > 1 => {
            let arg = |i: usize| positional.get(i).copied().unwrap_or("");
            let port = |i: usize| arg(i).parse::<u16>().ok();
            let request = match arg(1) {
                "snapshots" => json!({"op": "snapshots"}),
                "snapshot" => json!({"op": "snapshot", "port": port(2), "database": arg(3)}),
                "restore" => json!({"op": "restore", "id": arg(2)}),
                "databases" => json!({"op": "databases", "port": port(2)}),
                "redis" => {
                    json!({"op": "keyspace", "port": port(2), "db": number("--db").unwrap_or(0)})
                }
                other => {
                    std::process::exit(fail(json_out, &format!("unknown db command: {other}")));
                }
            };
            if arg(1) == "restore"
                && !flag("--yes")
                && !confirm(&format!(
                    "Restore {}? The database goes back to that snapshot",
                    arg(2)
                ))
            {
                std::process::exit(1);
            }
            match corescope::db_tool(&request) {
                Ok(v) => print(true, v),
                Err(e) => fail(json_out, &e),
            }
        }
        Some("db") => print(json_out, databases(&sample(false))),
        Some("logs") => {
            let folder = positional
                .get(1)
                .filter(|p| !p.is_empty())
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
            let query = args
                .iter()
                .position(|a| a == "--search")
                .and_then(|i| args.get(i + 1))
                .cloned();
            print(
                json_out,
                logs(
                    &folder,
                    flag("--errors"),
                    query.as_deref(),
                    number("-n").unwrap_or(40),
                ),
            )
        }
        Some("containers") => print(json_out, containers()),
        Some("worktrees") => {
            // A registered project's name stands for its folder.
            let folders: Vec<std::path::PathBuf> = positional[1..]
                .iter()
                .map(|t| {
                    project_folder(Some(t))
                        .unwrap_or_else(|_| t.to_string())
                        .into()
                })
                .collect();
            print(json_out, worktrees(&folders))
        }
        Some("gate") => gate(),
        Some("context") => context(&args, &positional, json_out),
        Some("wait") => {
            let folder = positional
                .get(1)
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
            let value = |name: &str| {
                args.iter()
                    .position(|a| a == name)
                    .and_then(|i| args.get(i + 1))
                    .cloned()
            };
            let mut spec = capacity_spec(&folder).unwrap_or_default();
            if let Some(v) = value("--cpu-below").and_then(|v| v.parse().ok()) {
                spec.cpu_below = v;
            }
            if let Some(v) = value("--memory") {
                spec.memory = v;
            }
            if let Some(v) = value("--max-wait").and_then(|v| v.parse().ok()) {
                spec.max_wait_minutes = v;
            }
            let outcome = wait_for_room(&spec, None, |line| eprintln!("corescope: {line}"));
            print(json_out, outcome)
        }
        Some("config") => {
            let folder = positional
                .get(1)
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
            match project_config(&folder) {
                Ok(v) if json_out => print(true, v),
                Ok(v) => {
                    println!("{}: valid", v["file"].as_str().unwrap_or(""));
                    0
                }
                Err(e) => fail(json_out, &e),
            }
        }
        Some("power") => print(json_out, power(&sample(true))),
        Some("large-files") => {
            let home: std::path::PathBuf =
                std::env::var_os("HOME").map(Into::into).unwrap_or_default();
            let s = corescope::largefiles::scan(
                &corescope::largefiles::default_roots(&home),
                (number("--min-mb").unwrap_or(1024) as u64) << 20,
                number("-n").unwrap_or(50),
                Duration::from_secs(120),
            );
            if json_out {
                print(true, json!(s))
            } else {
                for f in &s.files {
                    println!(
                        "{:>9}  {:<16} {}{}",
                        format!("{:.1} GB", f.bytes as f64 / 1e9),
                        f.kind,
                        f.path,
                        f.managed_by
                            .map(|m| format!("  [managed by {m}]"))
                            .unwrap_or_default()
                    );
                }
                println!(
                    "{} files scanned in {:.0} s{}",
                    s.scanned_files,
                    s.seconds,
                    if s.partial {
                        " (stopped at the time limit)"
                    } else {
                        ""
                    }
                );
                0
            }
        }
        Some("eject-check") => {
            let mount = positional[1..].join(" ");
            let holders = corescope::eject::holders(&mount, &sample(false).processes);
            if json_out {
                print(true, json!(holders))
            } else if holders.is_empty() {
                println!(
                    "Nothing of yours holds {mount}. System services (Spotlight) can still; macOS names them if the eject fails."
                );
                0
            } else {
                for h in &holders {
                    println!(
                        "{:>7}  {:<24} {:<15} {}{}",
                        h.pid,
                        h.name,
                        h.reason,
                        h.example,
                        if h.files > 1 {
                            format!("  (+{} more)", h.files - 1)
                        } else {
                            String::new()
                        }
                    );
                }
                0
            }
        }
        Some("status") => (|| -> i32 {
            let folder = match project_folder(positional.get(1).copied()) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("{e}");
                    return 1;
                }
            };
            let s = match corescope::projects_tool(&json!({"op": "status", "folder": folder})) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("{e}");
                    return 1;
                }
            };
            if json_out {
                return print(true, s);
            }
            let b = &s["branch"];
            let mut head = b["head"].as_str().unwrap_or("(detached)").to_string();
            if let Some(up) = b["upstream"].as_str() {
                head += &format!(
                    " → {up} ↑{} ↓{}",
                    b["ahead"].as_u64().unwrap_or(0),
                    b["behind"].as_u64().unwrap_or(0)
                );
            }
            println!("{head}");
            if let Some(c) = s["last_commit"].as_object() {
                println!(
                    "last commit {} {} ({})",
                    c["short"].as_str().unwrap_or(""),
                    c["subject"].as_str().unwrap_or(""),
                    c["author"].as_str().unwrap_or("")
                );
            }
            if s["locked"].as_bool() == Some(true) {
                println!("another git process holds index.lock");
            }
            let n = |k: &str| s[k].as_u64().unwrap_or(0);
            println!(
                "{} staged, {} modified, {} new, {} removed, {} conflicts",
                n("staged"),
                n("modified"),
                n("untracked"),
                n("removed_renamed"),
                n("conflicts")
            );
            let lines = |a: &Value, r: &Value| match (a.as_u64(), r.as_u64()) {
                (Some(a), Some(r)) => format!("+{a} -{r}"),
                _ => String::new(),
            };
            for f in s["files"].as_array().into_iter().flatten() {
                let code = format!(
                    "{}{}",
                    f["index"].as_str().unwrap_or("."),
                    f["worktree"].as_str().unwrap_or(".")
                );
                let mut path = f["path"].as_str().unwrap_or("").to_string();
                if let Some(o) = f["orig_path"].as_str() {
                    path = format!("{o} → {path}");
                }
                let changes = if f["staged_added"].is_null() {
                    lines(&f["added"], &f["removed"])
                } else {
                    lines(&f["staged_added"], &f["staged_removed"])
                };
                println!("  {code} {path} {changes}");
            }
            if n("truncated") > 0 {
                println!("  … and {} more", n("truncated"));
            }
            0
        })(),
        Some("branches") => (|| -> i32 {
            let folder = match project_folder(positional.get(1).copied()) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("{e}");
                    return 1;
                }
            };
            let v = match corescope::projects_tool(&json!({"op": "branches", "folder": folder})) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("{e}");
                    return 1;
                }
            };
            if json_out {
                return print(true, v);
            }
            for b in v["branches"].as_array().into_iter().flatten() {
                let mut sync = match (b["ahead"].as_u64(), b["behind"].as_u64()) {
                    _ if b["gone"].as_bool() == Some(true) => "upstream gone".to_string(),
                    (Some(a), Some(r)) => format!("↑{a} ↓{r}"),
                    _ => "no upstream".into(),
                };
                if let Some(w) = b["worktree"].as_str() {
                    sync += &format!("  (worktree {w})");
                }
                println!(
                    "{} {:<32} {:<9} {:<14} {}",
                    if b["current"].as_bool() == Some(true) {
                        "*"
                    } else {
                        " "
                    },
                    b["name"].as_str().unwrap_or(""),
                    b["head"].as_str().unwrap_or(""),
                    sync,
                    b["subject"].as_str().unwrap_or("")
                );
            }
            if let Some(n) = v["truncated"].as_u64().filter(|n| *n > 0) {
                println!("  … and {n} more");
            }
            0
        })(),
        Some("projects") => {
            let list = corescope::projects_tool(&json!({"op": "list"})).unwrap_or(json!([]));
            let rows: Vec<Value> = list
                .as_array()
                .into_iter()
                .flatten()
                .map(|p| {
                    let folder = p["folder"].as_str().unwrap_or("");
                    let check = corescope::projects_tool(&json!({"op": "check", "folder": folder}))
                        .unwrap_or(Value::Null);
                    json!({"project": p, "git": check["git"], "config": check["config"]})
                })
                .collect();
            if json_out {
                print(true, json!(rows))
            } else {
                if rows.is_empty() {
                    println!("No projects yet: add one on the Projects page.");
                }
                for r in &rows {
                    let git = &r["git"];
                    let branch = if git["is_repo"].as_bool() == Some(true) {
                        git["branch"].as_str().unwrap_or("(detached)").to_string()
                    } else {
                        "no git".into()
                    };
                    let config = match r["config"]["error"].as_str() {
                        Some(e) => format!("yml error: {e}"),
                        None => "yml ok".into(),
                    };
                    println!(
                        "{:<24} {:<20} {:<10} {}",
                        r["project"]["name"].as_str().unwrap_or(""),
                        branch,
                        config,
                        r["project"]["folder"].as_str().unwrap_or("")
                    );
                }
                0
            }
        }
        Some("disk-health") => {
            let disks = corescope::diskhealth::read();
            if json_out {
                print(true, json!(disks))
            } else {
                for d in &disks {
                    println!("{}", health_text(d));
                }
                0
            }
        }
        Some("disk-growth") => match corescope::disk_growth(flag("--measure")) {
            Ok(r) if json_out => print(true, json!(r)),
            Ok(r) => {
                println!("{}", growth_text(&r));
                0
            }
            Err(e) => fail(json_out, &e),
        },
        Some("happened") => {
            let skip = args.iter().position(|a| a == "--minutes").map(|i| i + 1);
            let when = args
                .iter()
                .enumerate()
                .skip(1)
                .filter(|(i, a)| !a.starts_with('-') && Some(*i) != skip)
                .map(|(_, a)| a.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            match happened(&when, number("--minutes").unwrap_or(10) as i64) {
                Ok(v) if json_out => print(true, v),
                Ok(v) => {
                    for line in v["findings"].as_array().into_iter().flatten() {
                        println!("{}", line.as_str().unwrap_or(""));
                    }
                    0
                }
                Err(e) => fail(json_out, &e),
            }
        }
        Some("version") => version(json_out, flag("--check")),
        Some("mcp") => mcp::serve(),
        Some(other) => fail(
            json_out,
            &format!("unknown command: {other}. Try `corescope help`."),
        ),
    };
    std::process::exit(code);
}

/// Version and build of the app bundle this command lives in (Contents/Resources/bin).
fn bundle_version() -> Option<(String, String)> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let plist = exe.parent()?.parent()?.parent()?.join("Info.plist");
    let text = std::fs::read_to_string(plist).ok()?;
    Some((
        plist_string(&text, "CFBundleShortVersionString")?,
        plist_string(&text, "CFBundleVersion").unwrap_or_default(),
    ))
}
/// The <string> after <key>KEY</key> in an XML plist.
pub fn plist_string(plist: &str, key: &str) -> Option<String> {
    let after = &plist[plist.find(&format!("<key>{key}</key>"))?..];
    let start = after.find("<string>")? + "<string>".len();
    let end = after[start..].find("</string>")?;
    Some(after[start..start + end].trim().to_string())
}

/// `corescope version [--check]`: the network request, when asked for, is made by the app.
fn version(json_out: bool, check: bool) -> i32 {
    let (version, build) = bundle_version().unwrap_or(("dev".into(), "0".into()));
    let status = mcp::app(
        if check {
            "app.update_check"
        } else {
            "app.update_status"
        },
        &json!({}),
    );
    if json_out {
        println!(
            "{}",
            json!({"version": version, "build": build, "update": status})
        );
        return if check && status.get("error").is_some() {
            1
        } else {
            0
        };
    }
    println!("CoreScope {version} (build {build})");
    if let Some(error) = status["error"].as_str() {
        if check || status["state"].as_str() == Some("error") {
            eprintln!("corescope: could not check for updates: {error}");
            return 1;
        }
        return 0;
    }
    if let Some(latest) = status["latest_version"].as_str() {
        println!(
            "Update available: {latest}. Install it from CoreScope › Settings › Updates (Install and relaunch)."
        );
        if check && let Some(notes) = status["release_notes"].as_str().filter(|n| !n.is_empty()) {
            println!("\n{notes}");
        }
    } else if check {
        println!("Up to date.");
    } else if status["check_for_updates"].as_bool() == Some(false) {
        println!(
            "Update checks are off (Settings › Updates); `corescope version --check` checks once."
        );
    }
    0
}

/// One disk's SMART health for people.
pub fn health_text(d: &corescope::diskhealth::Health) -> String {
    if d.status != "ok" {
        return format!("{}: no NVMe SMART data ({})", d.name, d.status);
    }
    let tb = |b: Option<u64>| {
        b.map(|b| format!("{:.2} TB", b as f64 / 1e12))
            .unwrap_or("—".into())
    };
    let n = |v: Option<u64>| v.map(|v| v.to_string()).unwrap_or("—".into());
    let mut out = format!(
        "{}: {} · {}% of rated endurance used · spare {}% (threshold {}%)\n  written {} · read {} · {} h powered on · {} power cycles · {} unsafe shutdowns · {} media errors",
        d.name,
        d.verdict.unwrap_or("?"),
        d.percentage_used.unwrap_or(0),
        d.available_spare.unwrap_or(0),
        d.spare_threshold.unwrap_or(0),
        tb(d.written_bytes),
        tb(d.read_bytes),
        n(d.power_on_hours),
        n(d.power_cycles),
        n(d.unsafe_shutdowns),
        n(d.media_errors)
    );
    for note in &d.notes {
        out.push_str(&format!("\n  {note}"));
    }
    out
}

/// The disk growth report as lines for people.
pub fn growth_text(r: &corescope::diskgrowth::Report) -> String {
    let gb = |b: i64| format!("{:+.2} GB", b as f64 / 1_073_741_824.);
    let size = |b: u64| format!("{:.1} GB", b as f64 / 1_073_741_824.);
    let Some(at) = r.measured_at else {
        return "Nothing measured yet: run `corescope disk-growth --measure`.".into();
    };
    let mut out = vec![match r.baseline_at {
        Some(b) => format!(
            "Measured {} against {}.",
            corescope::local_format(at),
            corescope::local_format(b)
        ),
        None => format!(
            "Measured {} (first measurement: growth shows from the next one).",
            corescope::local_format(at)
        ),
    }];
    if let Some(free) = r.free {
        let change = r
            .free_change
            .map(|c| format!(" ({})", gb(c)))
            .unwrap_or_default();
        out.push(format!("Free space: {}{change}.", size(free)));
    }
    out.push(format!(
        "{:<20} {:>10} {:>11}  PATH",
        "FOLDER", "SIZE", "CHANGE"
    ));
    for g in &r.folders {
        out.push(format!(
            "{:<20} {:>10} {:>11}  {}",
            g.label,
            size(g.bytes),
            g.change.map(gb).unwrap_or_else(|| "—".into()),
            g.path
        ));
    }
    out.join("\n")
}

/// History around a moment, with findings; the per-minute points are left out.
pub fn happened(when: &str, minutes: i64) -> Result<Value, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let at = corescope::parse_moment(when, now).ok_or_else(|| {
        format!("could not read the time {when:?}: use 14:05, 2:05 pm, yesterday 9:30 or 2026-10-17 14:05")
    })?;
    let h = corescope::history::happened(&corescope::history::default_path(), at, minutes)?;
    let findings = corescope::history::findings(&h);
    let mut v = serde_json::to_value(&h).map_err(|e| e.to_string())?;
    if let Some(o) = v.as_object_mut() {
        o.remove("points");
        for k in ["at", "from", "to", "cpu_max_at", "power_max_at"] {
            if let Some(t) = o.get(k).and_then(Value::as_i64) {
                o.insert(format!("{k}_local"), json!(corescope::local_format(t)));
            }
        }
    }
    v["findings"] = json!(findings);
    Ok(v)
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
        "disk_read_bps": p.read.value, "disk_write_bps": p.write.value,
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
    // Sessions working in the same working tree can fight over files, ports and dev servers.
    let mut trees: HashMap<String, Vec<i32>> = HashMap::new();
    for s in &sessions {
        if let (Some(cwd), Some(pid)) = (s["cwd"].as_str(), s["pid"].as_i64())
            && let Some(top) = corescope::worktrees::toplevel(std::path::Path::new(cwd))
        {
            trees
                .entry(top.to_string_lossy().into())
                .or_default()
                .push(pid as i32);
        }
    }
    let conflicts: Vec<Value> = trees
        .into_iter()
        .filter(|(_, pids)| pids.len() > 1)
        .map(|(tree, pids)| json!({"working_tree": tree, "session_pids": pids,
            "note": "several agent sessions in one working tree: they can overwrite each other's files and fight over ports; give each its own git worktree"}))
        .collect();
    json!({"agents": sessions, "conflicts": conflicts})
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
            "disk" => match (p.read.value, p.write.value) {
                (None, None) => None,
                (r, w) => Some(r.unwrap_or(0.) + w.unwrap_or(0.)),
            },
            _ => p.cpu.value,
        }
        .unwrap_or(-1.)
    };
    rows.sort_by(|a, b| key(b).total_cmp(&key(a)));
    json!({"by": by,
           "processes": rows.iter().take(count).map(|p| process_json(p)).collect::<Vec<_>>()})
}

/// Linked git worktrees under the folders (or the suggested project folders and the projects
/// agents work in) with what decides whether they can go.
pub fn worktrees(folders: &[std::path::PathBuf]) -> Value {
    use corescope::worktrees as w;
    let home: std::path::PathBuf = std::env::var_os("HOME").map(Into::into).unwrap_or_default();
    let snapshot = sample(false);
    let roots = devspace::normalize(if folders.is_empty() {
        devspace::auto_roots(&home, &snapshot.processes)
    } else {
        folders.to_vec()
    });
    let rows: Vec<Value> = devspace::worktree_paths(&roots, &snapshot.processes)
        .into_iter()
        .map(|path| {
            let repo = w::main_repo(&path).unwrap_or_default();
            let info = w::list(&repo).into_iter().find(|x| std::path::Path::new(&x.path) == path);
            let branch = info.as_ref().and_then(|i| i.branch.clone());
            let user = snapshot
                .processes
                .iter()
                .find(|p| !p.cwd.is_empty() && std::path::Path::new(&p.cwd).starts_with(&path))
                .map(|p| format!("{} (PID {})", p.name, p.pid));
            json!({"path": path, "repo": repo, "branch": branch, "agent": info.as_ref().and_then(|i| i.agent),
                   "merged": branch.as_deref().and_then(|b| w::merged(&repo, b)),
                   "uncommitted_changes": w::dirty(&path), "locked": info.as_ref().map(|i| i.locked),
                   "last_commit": w::last_commit(&path), "in_use_by": user})
        })
        .collect();
    json!({"worktrees": rows, "note": "Remove clean, unused ones from CoreScope › Cleanup (to the Trash) or with clean_dev_space."})
}

/// Listening ports reachable from the network, riskiest first, with advice.
pub fn exposure() -> Value {
    let snapshot = sample(false);
    let list = corescope::containers::Reader::default()
        .read(false)
        .containers;
    let rows = corescope::exposure::exposures(&snapshot, &list, project);
    json!({"exposed": rows, "note": "Only your own processes' ports are visible; ports bound to 127.0.0.1 are not listed."})
}

/// Each known project's preferred ports (.corescope.yml › ports): free, held by the project, or
/// taken by something else (with who and a free alternative).
pub fn port_claims(folders: &[std::path::PathBuf]) -> Value {
    let home: std::path::PathBuf = std::env::var_os("HOME").map(Into::into).unwrap_or_default();
    let snapshot = sample(false);
    let roots = devspace::normalize(if folders.is_empty() {
        devspace::auto_roots(&home, &snapshot.processes)
    } else {
        folders.to_vec()
    });
    let projects: Vec<corescope::exposure::ProjectPorts> =
        corescope::projectconfig::discover(&roots)
            .iter()
            .filter_map(|f| corescope::projectconfig::load(f))
            .filter_map(|found| {
                let c = found.config?;
                let name = c
                    .name
                    .clone()
                    .unwrap_or_else(|| found.folder.rsplit('/').next().unwrap_or("").to_string());
                (!c.ports.is_empty())
                    .then(|| (name, found.folder.clone(), c.ports.into_iter().collect()))
            })
            .collect();
    let list = corescope::containers::Reader::default()
        .read(false)
        .containers;
    let claims = corescope::exposure::claims(&snapshot, &list, &projects, |from| {
        free_port(from, &snapshot)["free_port"]
            .as_u64()
            .map(|p| p as u16)
    });
    json!({"port_claims": claims, "projects_checked": projects.len()})
}

/// Containers of every local engine with their compose project, plus volumes and restart policies.
pub fn containers() -> Value {
    let report = corescope::containers::Reader::default().read(false);
    let details = corescope::containers::details(&mut HashMap::new());
    let rows: Vec<Value> = report
        .containers
        .iter()
        .map(|c| {
            json!({"name": c.name, "image": c.image, "state": c.state, "status": c.status, "health": c.health,
                   "project": c.project, "service": c.service, "engine": c.engine,
                   "ports": c.ports.iter().map(|p| json!({"host": p.host, "container": p.container, "exposed": p.exposed})).collect::<Vec<_>>(),
                   "restart_policy": details.restart.get(&c.id)})
        })
        .collect();
    json!({"containers": rows, "volumes": details.volumes})
}

/// Log files of a project folder (plus its .corescope.yml `logs:` globs): their tails, the recent
/// errors with their traces, or lines matching a search.
pub fn logs(folder: &std::path::Path, errors: bool, query: Option<&str>, count: usize) -> Value {
    use corescope::logs as l;
    let globs = project_config(folder)
        .ok()
        .and_then(|v| serde_json::from_value::<Vec<String>>(v["config"]["logs"].clone()).ok())
        .unwrap_or_default();
    let sources: Vec<l::Source> = l::project_files(folder, &globs)
        .into_iter()
        .map(|p| l::Source {
            kind: "file".into(),
            name: p
                .strip_prefix(folder)
                .unwrap_or(&p)
                .to_string_lossy()
                .into(),
            project: None,
            target: p.to_string_lossy().into(),
        })
        .collect();
    if let Some(q) = query {
        return json!({"log_lines": l::search(&sources, q, count)});
    }
    if errors {
        return json!({"log_lines": l::errors(&sources, count, false).0});
    }
    let tails: Vec<Value> = sources
        .iter()
        .map(|s| json!({"source": s.name, "lines": l::tail(s, count).unwrap_or_default()}))
        .collect();
    json!({"log_sources": sources.iter().map(|s| &s.name).collect::<Vec<_>>(), "tails": tails})
}

/// The capacity rule of the project around `folder`, if it has one.
pub fn capacity_spec(folder: &std::path::Path) -> Option<corescope::projectconfig::CapacitySpec> {
    let v = project_config(folder).ok()?;
    serde_json::from_value(v["config"]["agents"]["wait_for_capacity"].clone()).ok()
}

/// Samples until the rule is met twice in a row (10 s apart), or `limit` passes. An immediate
/// pass needs one reading. Returns what happened, never fails: on timeout the caller proceeds.
pub fn wait_for_room(
    spec: &corescope::projectconfig::CapacitySpec,
    limit: Option<Duration>,
    mut say: impl FnMut(&str),
) -> Value {
    let started = std::time::Instant::now();
    let limit = limit.unwrap_or(Duration::from_secs_f64(spec.max_wait_minutes.max(0.) * 60.));
    let mut good = 0;
    let mut waited = false;
    loop {
        let reading = corescope::capacity::reading(&sample(true));
        let blockers = corescope::capacity::blockers(spec, &reading);
        if blockers.is_empty() {
            good += 1;
            if !waited || good >= 2 {
                return json!({"ready": true, "waited_seconds": started.elapsed().as_secs(), "reading": reading});
            }
        } else {
            good = 0;
            if !waited {
                say(&format!("waiting for room: {}", blockers.join(", ")));
            }
            waited = true;
            if started.elapsed() + Duration::from_millis(900) >= limit {
                return json!({"ready": false, "gave_up_after_seconds": started.elapsed().as_secs(),
                              "blockers": blockers, "reading": reading});
            }
        }
        // Never past the limit: the last check lands on it.
        let left = limit.saturating_sub(started.elapsed());
        std::thread::sleep(Duration::from_secs(10).min(left.max(Duration::from_millis(200))));
    }
}

/// Claude Code PreToolUse hook. Reads the tool call on stdin; for a heavy Bash command in a project
/// whose .corescope.yml enables `agents.wait_for_capacity`, waits for room (recording the wait so
/// CoreScope can show it). Always exits 0: it delays, it never blocks a command.
fn gate() -> i32 {
    use std::io::Read;
    let mut input = String::new();
    let _ = std::io::stdin().take(1 << 20).read_to_string(&mut input);
    let call: Value = serde_json::from_str(&input).unwrap_or_default();
    let Some((command, folder)) = gate_request(&call) else {
        return 0;
    };
    let command = command.as_str();
    let Some(spec) = capacity_spec(&folder) else {
        return 0;
    };
    let defaults: Vec<String> = corescope::capacity::DEFAULT_HEAVY
        .iter()
        .map(|s| s.to_string())
        .collect();
    let prefixes = if spec.heavy_commands.is_empty() {
        &defaults
    } else {
        &spec.heavy_commands
    };
    let Some(heavy) = corescope::capacity::heavy(command, prefixes) else {
        return 0;
    };
    // Visible to CoreScope while it lasts: who waits, for what, why.
    let dir = std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
        .join("Library/Application Support/CoreScope/gates");
    let _ = std::fs::create_dir_all(&dir);
    let file = dir.join(format!("{}.json", std::process::id()));
    let agent = std::os::unix::process::parent_id();
    let limit = Duration::from_secs_f64((spec.max_wait_minutes.clamp(0., 55.)) * 60.);
    let outcome = wait_for_room(&spec, Some(limit), |reason| {
        let note = json!({"agent_pid": agent, "folder": folder, "command": heavy, "reason": reason,
                          "since": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)});
        let _ = std::fs::write(&file, note.to_string());
        eprintln!("CoreScope: {reason}; `{heavy}` will start when the Mac has room");
    });
    let _ = std::fs::remove_file(&file);
    if outcome["ready"] == false {
        eprintln!(
            "CoreScope: still busy after the project's maximum wait; running `{heavy}` anyway"
        );
    }
    0
}

/// The shell command and working folder of a PreToolUse hook call. Claude Code and Codex send
/// the same shape: `tool_name` "Bash", `tool_input.command`, `cwd`.
fn gate_request(call: &Value) -> Option<(String, std::path::PathBuf)> {
    if call["tool_name"].as_str() != Some("Bash") {
        return None;
    }
    let command = call["tool_input"]["command"].as_str()?.to_string();
    let folder = call["cwd"]
        .as_str()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
    Some((command, folder))
}

/// `corescope context`: what the project's `.corescope.yml` asks of agents. `--hook` is the
/// SessionStart hook (Claude Code, Codex): the folder comes from the hook's JSON and the answer
/// is the hook's additional context; it never fails a session. `--write FILE` (CLAUDE.md,
/// AGENTS.md or all) puts the text in a marked section; `--remove` takes it out.
fn context(args: &[String], positional: &[&str], json_out: bool) -> i32 {
    use std::io::{IsTerminal, Read};
    let flag = |name: &str| args.iter().any(|a| a == name);
    if flag("--hook") {
        let mut input = String::new();
        if !std::io::stdin().is_terminal() {
            let _ = std::io::stdin().take(1 << 20).read_to_string(&mut input);
        }
        let call: Value = serde_json::from_str(&input).unwrap_or_default();
        let folder = call["cwd"]
            .as_str()
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
        if let Some(text) = corescope::agentcontext::for_folder(&folder) {
            println!("{}", corescope::agentcontext::hook_output(&text));
        }
        return 0;
    }
    let folder = positional
        .get(1)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
    let writes: Vec<String> = args
        .iter()
        .enumerate()
        .filter(|(_, a)| *a == "--write")
        .filter_map(|(i, _)| args.get(i + 1))
        .flat_map(|f| {
            if f == "all" {
                corescope::agentcontext::INSTRUCTION_FILES
                    .iter()
                    .map(|s| s.to_string())
                    .collect()
            } else {
                vec![f.clone()]
            }
        })
        .collect();
    let remove = flag("--remove");
    if !writes.is_empty() || remove {
        let files = if writes.is_empty() {
            corescope::agentcontext::INSTRUCTION_FILES
                .iter()
                .map(|s| s.to_string())
                .collect()
        } else {
            writes
        };
        return match corescope::agentcontext::write_instructions(&folder, &files, remove) {
            Ok(state) => {
                if json_out {
                    print(true, json!(state))
                } else {
                    for f in &state.files {
                        println!("{:<9} {}", f.state, f.file);
                    }
                    0
                }
            }
            Err(e) => {
                eprintln!("corescope: {e}");
                1
            }
        };
    }
    match corescope::agentcontext::for_folder(&folder) {
        Some(text) if json_out => print(true, json!({"context": text})),
        Some(text) => {
            println!("{text}");
            0
        }
        None => {
            eprintln!(
                "corescope: no .corescope.yml in {} or above it",
                folder.display()
            );
            1
        }
    }
}

/// The project file in `folder` (or the nearest parent with one), parsed and validated.
pub fn project_config(folder: &std::path::Path) -> Result<Value, String> {
    let dir = folder
        .ancestors()
        .find(|a| corescope::projectconfig::file_in(a).is_some())
        .ok_or_else(|| format!("no .corescope.yml in {} or its parents", folder.display()))?;
    let found = corescope::projectconfig::load(dir).ok_or("no .corescope.yml")?;
    match found.error {
        Some(e) => Err(format!("{}: {e}", found.file)),
        None => Ok(json!({"folder": found.folder, "file": found.file, "config": found.config})),
    }
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
pub fn english(error: &str) -> String {
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

/// Asks on the terminal; false (refuse) when there is no terminal to ask in.
/// `db analyze FILE` and `db import FILE --into NAME (--container C | --port P) [--replace]
/// [--skip t1,t2] [--drop-triggers] [--no-snapshot] [--yes]`.
fn db_dump(args: &[String], positional: &[&str], json_out: bool) -> i32 {
    let value = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let flag = |name: &str| args.iter().any(|a| a == name);
    let Some(file) = positional.get(2).map(|f| f.to_string()) else {
        return fail(
            json_out,
            "usage: corescope db analyze FILE | db import FILE --into NAME --container C [--replace] [--skip t1,t2]",
        );
    };
    let file = std::fs::canonicalize(&file)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or(file);
    if positional[1] == "analyze" {
        return match corescope::db_tool(&json!({"op": "dump_analyze", "file": file, "wait": true}))
        {
            Err(e) => fail(json_out, &e),
            Ok(v) if json_out => print(true, v),
            Ok(v) => {
                println!(
                    "{} dump, {} tables, {} rows{}",
                    v["dialect"].as_str().unwrap_or("?"),
                    v["tables"].as_array().map_or(0, Vec::len),
                    v["total_rows"],
                    v["source_database"]
                        .as_str()
                        .map(|d| format!(", from database {d}"))
                        .unwrap_or_default()
                );
                for t in v["tables"].as_array().into_iter().flatten().take(30) {
                    println!(
                        "{:>12} rows {:>10.1} MB  {}",
                        t["rows"],
                        t["data_bytes"].as_f64().unwrap_or(0.0) / 1e6,
                        t["name"].as_str().unwrap_or("")
                    );
                }
                0
            }
        };
    }
    let Some(target) = value("--into") else {
        return fail(json_out, "--into NAME is required");
    };
    let replace = flag("--replace");
    if replace
        && !flag("--yes")
        && !confirm(&format!(
            "Replace the database {target} with {file}? Its current data is dropped (a snapshot is taken first unless --no-snapshot)"
        ))
    {
        return 1;
    }
    let skip: Vec<String> = value("--skip")
        .map(|s| {
            s.split(',')
                .map(|t| t.trim().to_string())
                .filter(|t| !t.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let request = json!({
        "op": "dump_restore", "file": file, "target": target,
        "mode": if replace { "replace" } else { "create" },
        "container": value("--container"),
        "port": value("--port").and_then(|p| p.parse::<u16>().ok()),
        "skip_data": skip, "drop_triggers": flag("--drop-triggers"),
        "snapshot_first": !flag("--no-snapshot"),
    });
    let job = match corescope::db_tool(&request) {
        Ok(v) => v["job"].as_str().unwrap_or("").to_string(),
        Err(e) => return fail(json_out, &e),
    };
    let mut shown = 0;
    loop {
        std::thread::sleep(std::time::Duration::from_millis(500));
        let Ok(s) = corescope::db_tool(&json!({"op": "dump_job", "job": job})) else {
            return fail(json_out, "the job disappeared");
        };
        let log = s["log"].as_array().cloned().unwrap_or_default();
        if !json_out {
            for line in log.iter().skip(shown) {
                eprintln!("{}", line.as_str().unwrap_or(""));
            }
        }
        shown = log.len();
        if s["state"] != "running" {
            return if s["state"] == "succeeded" {
                print(json_out, s["result"].clone())
            } else {
                fail(json_out, s["error"].as_str().unwrap_or("failed"))
            };
        }
    }
}

fn confirm(question: &str) -> bool {
    if !std::io::stdin().is_terminal() {
        eprintln!("refusing without --yes when stdin is not a terminal");
        return false;
    }
    eprint!("{question}? [y/N] ");
    let _ = std::io::stderr().flush();
    let mut answer = String::new();
    let _ = std::io::stdin().read_line(&mut answer);
    matches!(answer.trim(), "y" | "Y" | "yes")
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
    } else if let Some(ready) = value["ready"].as_bool() {
        println!(
            "{}",
            if ready {
                format!("ready (waited {}s)", num(&value["waited_seconds"]))
            } else {
                format!(
                    "still busy after {}s: {}",
                    num(&value["gave_up_after_seconds"]),
                    value["blockers"]
                        .as_array()
                        .map(|b| b.iter().map(text).collect::<Vec<_>>().join(", "))
                        .unwrap_or_default()
                )
            }
        );
    } else if let Some(rows) = value["exposed"].as_array() {
        if rows.is_empty() {
            println!("nothing of yours listens beyond localhost");
        }
        for r in rows {
            println!(
                "{:<7} :{:<6} {:<34} {}",
                text(&r["risk"]).to_uppercase(),
                num(&r["port"]),
                text(&r["owner"]),
                text(&r["advice"])
            );
        }
    } else if let Some(rows) = value["port_claims"].as_array() {
        if rows.is_empty() {
            println!("no .corescope.yml with `ports:` found");
        }
        for r in rows {
            println!(
                "{:<20} {:<10} :{:<6} {:<6} {}{}",
                text(&r["project"]),
                text(&r["role"]),
                num(&r["port"]),
                text(&r["state"]),
                text(&r["held_by"]).replace('—', ""),
                r["suggestion"]
                    .as_u64()
                    .map(|p| format!("  → try :{p}"))
                    .unwrap_or_default()
            );
        }
    } else if let Some(rows) = value["worktrees"].as_array() {
        println!(
            "{:<44} {:<34} {:<12} {:>7}  IN USE",
            "WORKTREE", "BRANCH", "MERGED", "CHANGES"
        );
        for r in rows {
            let path = r["path"].as_str().unwrap_or("");
            let short = path
                .rsplit('/')
                .take(3)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join("/");
            println!(
                "{:<44} {:<34} {:<12} {:>7}  {}",
                short,
                text(&r["branch"]),
                match r["merged"].as_bool() {
                    Some(true) => "merged",
                    Some(false) => "not merged",
                    None => "?",
                },
                num(&r["uncommitted_changes"]),
                text(&r["in_use_by"])
            );
        }
    } else if let Some(rows) = value["containers"].as_array() {
        println!(
            "{:<34} {:<10} {:<18} {:<16} PORTS",
            "CONTAINER", "STATE", "PROJECT", "RESTART"
        );
        for r in rows {
            println!(
                "{:<34} {:<10} {:<18} {:<16} {}",
                text(&r["name"]),
                text(&r["state"]),
                text(&r["project"]),
                text(&r["restart_policy"]),
                r["ports"]
                    .as_array()
                    .map(|a| a
                        .iter()
                        .map(|p| format!(":{}", num(&p["host"])))
                        .collect::<Vec<_>>()
                        .join(" "))
                    .unwrap_or_default()
            );
        }
        let vols = value["volumes"].as_array().cloned().unwrap_or_default();
        if !vols.is_empty() {
            println!("\n{:<44} {:>10}  USED BY", "VOLUME", "SIZE");
            for v in vols {
                println!(
                    "{:<44} {:>10}  {}",
                    text(&v["name"]),
                    v["size"]
                        .as_f64()
                        .map(|b| format!("{:.0} MB", b / 1_048_576.))
                        .unwrap_or("—".into()),
                    match v["containers"].as_i64() {
                        Some(0) => "nothing (unused)".into(),
                        Some(n) if n > 0 => format!("{n} container(s)"),
                        _ => "?".into(),
                    }
                );
            }
        }
    } else if let Some(rows) = value["log_lines"].as_array() {
        if rows.is_empty() {
            println!("nothing found");
        }
        for r in rows {
            let times = r["count"]
                .as_u64()
                .filter(|c| *c > 1)
                .map(|c| format!(" (×{c})"))
                .unwrap_or_default();
            println!("[{}]{times} {}", text(&r["source"]), text(&r["text"]));
            for c in r["context"].as_array().into_iter().flatten() {
                println!("    {}", text(c));
            }
        }
    } else if let Some(tails) = value["tails"].as_array() {
        if tails.is_empty() {
            println!(
                "no log files found (looked in the project root, storage/logs, log, logs, var/log, tmp/logs)"
            );
        }
        for t in tails {
            println!("==> {} <==", text(&t["source"]));
            for line in t["lines"].as_array().into_iter().flatten() {
                println!("{}", text(line));
            }
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
                    Some("auth") => "needs a password (enter it on the Databases page; containers are read inside)".into(),
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

/// A registered project's folder (id or name), a folder given on the command line, or the
/// current folder.
fn project_folder(target: Option<&str>) -> Result<String, String> {
    let Some(t) = target else {
        return std::env::current_dir()
            .map(|d| d.to_string_lossy().into_owned())
            .map_err(|e| e.to_string());
    };
    if std::path::Path::new(t).is_dir() {
        return Ok(std::fs::canonicalize(t)
            .map(|d| d.to_string_lossy().into_owned())
            .unwrap_or_else(|_| t.to_string()));
    }
    let list = corescope::projects_tool(&json!({"op": "list"})).unwrap_or(json!([]));
    list.as_array()
        .into_iter()
        .flatten()
        .find(|p| {
            p["id"].as_str() == Some(t)
                || p["name"]
                    .as_str()
                    .is_some_and(|n| n.eq_ignore_ascii_case(t))
        })
        .and_then(|p| p["folder"].as_str().map(str::to_string))
        .ok_or_else(|| format!("No project or folder called {t}."))
}

#[cfg(test)]
mod tests {

    #[test]
    fn gate_reads_claude_code_and_codex_calls() {
        let claude = json!({"session_id": "s", "cwd": "/repo", "hook_event_name": "PreToolUse",
            "tool_name": "Bash", "tool_input": {"command": "npm test", "description": "x"}});
        let codex = json!({"session_id": "s", "turn_id": "t", "cwd": "/repo", "model": "gpt",
            "permission_mode": "default", "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_use_id": "u", "tool_input": {"command": "cargo build"}});
        assert_eq!(
            gate_request(&claude),
            Some(("npm test".into(), "/repo".into()))
        );
        assert_eq!(
            gate_request(&codex),
            Some(("cargo build".into(), "/repo".into()))
        );
        let patch =
            json!({"tool_name": "apply_patch", "tool_input": {"command": "*** Begin Patch"}});
        assert_eq!(gate_request(&patch), None, "only shell commands");
    }

    use super::*;
    #[test]
    fn plist_string_reads_the_value_after_its_key() {
        let plist = "<dict><key>CFBundleVersion</key><string>9</string>\n\
            <key>CFBundleShortVersionString</key>\n  <string> 0.6.0 </string></dict>";
        assert_eq!(
            plist_string(plist, "CFBundleShortVersionString").as_deref(),
            Some("0.6.0")
        );
        assert_eq!(plist_string(plist, "CFBundleVersion").as_deref(), Some("9"));
        assert_eq!(plist_string(plist, "SUFeedURL"), None);
    }
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
