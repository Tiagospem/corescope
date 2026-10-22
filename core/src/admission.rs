//! Admission for heavy commands: decide at once whether one may start, never hold it.
//!
//! Every agent session on the Mac shares one queue (a JSON file under a lock). A command that
//! cannot start now is deferred with why and what to do; it keeps its place while its agent
//! keeps asking (the gate hook, `wait_for_capacity`) and loses it when the agent stops asking or
//! its process ends. Admitted commands stay in the queue as running while the processes started
//! for them live, so the load already on the Mac is known, not guessed from one reading:
//! - at most `max_parallel` (by weight) run at once;
//! - one at a time per container a command loads (two suites on one MySQL is how it falls over);
//! - admissions are staggered, so the next waits until the readings show the last one's load.
use crate::capacity::{Blocker, Uses};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, Read, Seek, Write};
use std::path::PathBuf;

/// A waiting entry its agent stopped refreshing for this long is dropped.
pub const WAITING_TTL: f64 = 90.;
/// A granted reservation not used within this long is dropped.
pub const RESERVATION_TTL: f64 = 120.;
/// Seconds to leave after an admission, per unit of weight, before admitting the next.
pub const SETTLE_PER_WEIGHT: f64 = 15.;
/// An admitted command whose processes are not seen (yet) still counts as running this long.
pub const START_GRACE: f64 = 30.;
/// A running entry is dropped after this long whatever its processes do.
pub const RUNNING_MAX: f64 = 3. * 3600.;
const MAX_EVENTS: usize = 1000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Entry {
    /// The agent process (Claude Code, Codex…) the command belongs to.
    pub agent_pid: i32,
    pub folder: String,
    /// The heavy command as the project names it (`php artisan test`).
    pub command: String,
    pub uses: Uses,
    pub weight: f64,
    /// Containers it loads: one heavy command per container at a time.
    #[serde(default)]
    pub containers: Vec<String>,
    /// "waiting"; "granted" (a place its agent's next run of the command takes); "running".
    pub state: String,
    pub since: f64,
    /// Last time the agent asked (waiting), the grant (granted) or the admission (running).
    pub seen: f64,
    #[serde(default)]
    pub reason: String,
}
impl Entry {
    fn is(&self, agent_pid: i32, command: &str) -> bool {
        self.agent_pid == agent_pid && self.command == command
    }
    /// Running, or about to (a place granted): it counts against the limits.
    pub fn active(&self) -> bool {
        self.state == "running" || self.state == "granted"
    }
    fn shares(&self, containers: &[String]) -> Option<&str> {
        self.containers
            .iter()
            .find(|c| containers.contains(c))
            .map(String::as_str)
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
pub struct Queue {
    pub entries: Vec<Entry>,
    /// When the last heavy command was admitted, its weight and its agent.
    #[serde(default)]
    pub last_admitted: f64,
    #[serde(default)]
    pub last_weight: f64,
    #[serde(default)]
    pub last_agent: i32,
}

/// What is asked: run now (the hook), or hold a place to run within two minutes (MCP).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    Run,
    Reserve,
}

pub struct Request<'a> {
    pub agent_pid: i32,
    pub folder: &'a str,
    pub command: &'a str,
    pub uses: Uses,
    pub weight: f64,
    pub containers: &'a [String],
    /// Sum of weights allowed to run at once (the project's `max_parallel`).
    pub max_parallel: f64,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Decision {
    /// "admitted", "reserved" (a place held for the next run) or "deferred".
    pub outcome: &'static str,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub blockers: Vec<Blocker>,
    /// Commands ahead in the queue that could start now.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<usize>,
    /// When to ask again.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_seconds: Option<u64>,
    /// Waiting cannot help: every blocker needs an action.
    pub structural: bool,
    /// For the agent: what happened and what to do.
    pub message: String,
}
impl Decision {
    pub fn admitted(&self) -> bool {
        self.outcome != "deferred"
    }
    fn deferred(message: String, retry: u64) -> Decision {
        Decision {
            outcome: "deferred",
            blockers: vec![],
            position: None,
            retry_seconds: Some(retry.max(1)),
            structural: false,
            message,
        }
    }
}

/// Drops entries whose agent is gone, waiting entries nobody refreshes, stale grants and
/// commands that finished (`running` answers whether an admitted one's processes still live).
pub fn prune(
    q: &mut Queue,
    now: f64,
    alive: &impl Fn(i32) -> bool,
    running: &impl Fn(&Entry) -> bool,
) {
    q.entries.retain(|e| {
        alive(e.agent_pid)
            && match e.state.as_str() {
                "granted" => now - e.seen < RESERVATION_TTL,
                "running" => {
                    now - e.seen < RUNNING_MAX && (now - e.seen < START_GRACE || running(e))
                }
                _ => now - e.seen < WAITING_TTL,
            }
    });
}

fn names(list: &[&Entry]) -> String {
    list.iter()
        .map(|e| format!("`{}`", e.command))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The decision for one request, updating the queue. `blockers` answers from one reading for a
/// command's uses and containers; `alive` whether an agent process still runs; `running`
/// whether an admitted command's processes still run.
pub fn decide(
    q: &mut Queue,
    now: f64,
    request: &Request,
    mode: Mode,
    alive: &impl Fn(i32) -> bool,
    running: &impl Fn(&Entry) -> bool,
    blockers: &impl Fn(Uses, &[String]) -> Vec<Blocker>,
) -> Decision {
    prune(q, now, alive, running);
    // An agent asking again finished its previous command (or left it running in the
    // background, which `running` still sees): its own finished commands stop counting at once.
    let before = q.entries.len();
    q.entries
        .retain(|e| !(e.agent_pid == request.agent_pid && e.state == "running" && !running(e)));
    let own_finished = q.entries.len() < before
        && q.last_agent == request.agent_pid
        && !q
            .entries
            .iter()
            .any(|e| e.agent_pid == request.agent_pid && e.state == "running");
    let mine = q
        .entries
        .iter()
        .position(|e| e.is(request.agent_pid, request.command) && e.state != "running");
    // A place reserved earlier (wait_for_capacity, reserve_capacity, or Run now in the app).
    if let Some(i) = mine
        && q.entries[i].state == "granted"
    {
        if mode == Mode::Run {
            let e = &mut q.entries[i];
            e.state = "running".into();
            e.seen = now;
            q.last_agent = request.agent_pid;
        }
        return Decision {
            outcome: if mode == Mode::Run {
                "admitted"
            } else {
                "reserved"
            },
            blockers: vec![],
            position: None,
            retry_seconds: None,
            structural: false,
            message: format!("`{}` has its place: run it now.", request.command),
        };
    }
    let since = mine.map(|i| q.entries[i].since).unwrap_or(now);
    let wait = |q: &mut Queue, reason: &str| match q
        .entries
        .iter_mut()
        .find(|e| e.is(request.agent_pid, request.command) && e.state == "waiting")
    {
        Some(e) => {
            e.seen = now;
            e.reason = reason.into();
        }
        None => q.entries.push(Entry {
            agent_pid: request.agent_pid,
            folder: request.folder.into(),
            command: request.command.into(),
            uses: request.uses,
            weight: request.weight,
            containers: request.containers.to_vec(),
            state: "waiting".into(),
            since: now,
            seen: now,
            reason: reason.into(),
        }),
    };

    let found = blockers(request.uses, request.containers);
    if !found.is_empty() {
        let structural = found.iter().all(Blocker::structural);
        let reasons: Vec<&str> = found.iter().map(|b| b.reason.as_str()).collect();
        wait(q, &reasons.join("; "));
        let actions: Vec<&str> = found.iter().map(|b| b.action.as_str()).collect();
        return Decision {
            outcome: "deferred",
            message: format!(
                "CoreScope deferred `{}` (project rule: .corescope.yml › agents.wait_for_capacity): {}. {}",
                request.command,
                reasons.join("; "),
                actions.join(" ")
            ),
            blockers: found,
            position: None,
            retry_seconds: (!structural).then_some(30),
            structural,
        };
    }

    let others: Vec<&Entry> = q
        .entries
        .iter()
        .filter(|e| e.active() && !e.is(request.agent_pid, request.command))
        .collect();
    // One heavy command per container.
    if let Some((e, c)) = others
        .iter()
        .find_map(|e| e.shares(request.containers).map(|c| (*e, c.to_string())))
    {
        let message = format!(
            "CoreScope deferred `{}`: `{}` (another session) is loading {c} now, and two heavy commands on \
             one container is how it falls over. Call wait_for_capacity and try again; your place is kept.",
            request.command, e.command
        );
        wait(q, &format!("{c} busy with {}", e.command));
        return Decision::deferred(message, 30);
    }
    // At most `max_parallel` by weight; one alone always runs.
    let load: f64 = others.iter().map(|e| e.weight).sum();
    if load > 0. && load + request.weight > request.max_parallel {
        let message = format!(
            "CoreScope deferred `{}`: {} already running (weight {load:.0} of {:.0} allowed at once). \
             Call wait_for_capacity and try again; your place is kept.",
            request.command,
            names(&others),
            request.max_parallel
        );
        wait(q, "heavy commands running at the limit");
        return Decision::deferred(message, 30);
    }
    // Staggered: the last admission's load has to show in the readings first (unless it was this
    // agent's own command, which already ended).
    let settle = SETTLE_PER_WEIGHT * q.last_weight.max(1.);
    let since_last = now - q.last_admitted;
    if since_last < settle && !own_finished {
        let left = (settle - since_last).ceil() as u64;
        wait(q, "another heavy command just started");
        return Decision::deferred(
            format!(
                "CoreScope deferred `{}`: another heavy command started {since_last:.0} s ago and the \
                 readings need about {left} s more to show its load. Call wait_for_capacity and try again.",
                request.command
            ),
            left,
        );
    }
    // Fair order: earlier commands that could start now go first.
    let busy: Vec<String> = others.iter().flat_map(|e| e.containers.clone()).collect();
    let ahead = q
        .entries
        .iter()
        .filter(|e| {
            e.state == "waiting"
                && !e.is(request.agent_pid, request.command)
                && e.since < since
                && e.shares(&busy).is_none()
                && blockers(e.uses, &e.containers).is_empty()
        })
        .count();
    if ahead > 0 {
        wait(q, "queued behind earlier heavy commands");
        return Decision {
            position: Some(ahead),
            ..Decision::deferred(
                format!(
                    "CoreScope deferred `{}`: {ahead} heavy command(s) from other sessions are ahead in the \
                     queue and start one at a time. Call wait_for_capacity and try again; your place is kept \
                     while you keep asking.",
                    request.command
                ),
                SETTLE_PER_WEIGHT as u64,
            )
        };
    }

    q.entries
        .retain(|e| !(e.is(request.agent_pid, request.command) && e.state != "running"));
    q.last_admitted = now;
    q.last_weight = request.weight;
    q.last_agent = request.agent_pid;
    q.entries.push(Entry {
        agent_pid: request.agent_pid,
        folder: request.folder.into(),
        command: request.command.into(),
        uses: request.uses,
        weight: request.weight,
        containers: request.containers.to_vec(),
        state: if mode == Mode::Run {
            "running"
        } else {
            "granted"
        }
        .into(),
        since,
        seen: now,
        reason: String::new(),
    });
    Decision {
        outcome: if mode == Mode::Run {
            "admitted"
        } else {
            "reserved"
        },
        blockers: vec![],
        position: None,
        retry_seconds: None,
        structural: false,
        message: if mode == Mode::Run {
            format!("`{}` admitted.", request.command)
        } else {
            format!(
                "Room for `{}`: run it within {:.0} minutes; the place is held for you.",
                request.command,
                RESERVATION_TTL / 60.
            )
        },
    }
}

/// Gives a place to a waiting entry at once (the app's Run now): its next run is admitted.
pub fn grant(q: &mut Queue, agent_pid: i32, command: &str, now: f64) -> bool {
    match q
        .entries
        .iter_mut()
        .find(|e| e.is(agent_pid, command) && e.state == "waiting")
    {
        Some(e) => {
            e.state = "granted".into();
            e.seen = now;
            true
        }
        None => false,
    }
}

/// Removes an agent's entries (all of them, or one command's).
pub fn release(q: &mut Queue, agent_pid: i32, command: Option<&str>) -> usize {
    let before = q.entries.len();
    q.entries
        .retain(|e| !(e.agent_pid == agent_pid && command.is_none_or(|c| e.command == c)));
    before - q.entries.len()
}

// MARK: storage

fn dir() -> PathBuf {
    let home: PathBuf = std::env::var_os("HOME").map(Into::into).unwrap_or_default();
    home.join("Library/Application Support/CoreScope/admission")
}

/// Runs `f` on the shared queue under an exclusive lock and saves what it leaves.
pub fn with_queue<T>(f: impl FnOnce(&mut Queue) -> T) -> Result<T, String> {
    let dir = dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(dir.join("queue.json"))
        .map_err(|e| e.to_string())?;
    file.lock().map_err(|e| e.to_string())?;
    let mut text = String::new();
    let _ = file.read_to_string(&mut text);
    let mut q: Queue = serde_json::from_str(&text).unwrap_or_default();
    let out = f(&mut q);
    let body = serde_json::to_vec(&q).map_err(|e| e.to_string())?;
    file.set_len(0).map_err(|e| e.to_string())?;
    file.rewind().map_err(|e| e.to_string())?;
    file.write_all(&body).map_err(|e| e.to_string())?;
    Ok(out)
}

/// Whether a process still runs.
pub fn alive(pid: i32) -> bool {
    pid > 0 && crate::os::process(pid).is_some()
}

/// (pid, parent, start in µs) of every process: enough to tell whether an admitted command runs.
pub fn process_table() -> Vec<(i32, i32, u64)> {
    let mut pids = vec![0i32; 8192];
    // SAFETY: pids is a live buffer of the given capacity.
    let n = unsafe { crate::os::os_pids(pids.as_mut_ptr(), pids.len() as i32) };
    pids.truncate(n.max(0) as usize);
    pids.into_iter()
        .filter(|p| *p > 0)
        .filter_map(|p| crate::os::process(p).map(|r| (r.pid, r.ppid, r.start)))
        .collect()
}

/// Whether an admitted command still runs: a descendant of its agent started from just before
/// the admission to the end of the start grace (the shell running it, and what that started) is
/// alive. Later commands of the same agent start after that window and do not count.
pub fn running_in(table: &[(i32, i32, u64)], e: &Entry) -> bool {
    let from = ((e.seen - 3.) * 1e6) as u64;
    let to = ((e.seen + START_GRACE) * 1e6) as u64;
    let mut tree = vec![e.agent_pid];
    let mut i = 0;
    while i < tree.len() {
        let parent = tree[i];
        for (pid, ppid, start) in table {
            if *ppid == parent && !tree.contains(pid) {
                if (from..=to).contains(start) {
                    return true;
                }
                tree.push(*pid);
            }
        }
        i += 1;
    }
    false
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.)
}

/// One gate decision, for the app and `capacity_events`.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Event {
    pub at: f64,
    pub agent_pid: i32,
    pub folder: String,
    pub command: String,
    /// admitted, reserved, deferred, failed_open, released, granted_by_user.
    pub outcome: String,
    #[serde(default)]
    pub reason: String,
    /// Where it came from: hook, mcp, cli, app.
    pub via: String,
    #[serde(default)]
    pub millis: u64,
}

/// Appends a decision to the log (kept to the last 1000).
pub fn record(event: &Event) {
    let dir = dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let path = dir.join("events.jsonl");
    let Ok(line) = serde_json::to_string(event) else {
        return;
    };
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.lock();
        let _ = writeln!(f, "{line}");
        let big = f.metadata().map(|m| m.len() > 600_000).unwrap_or(false);
        if big {
            let kept: Vec<String> = events_in(&path, MAX_EVENTS / 2)
                .iter()
                .filter_map(|e| serde_json::to_string(e).ok())
                .collect();
            let _ = std::fs::write(&path, kept.join("\n") + "\n");
        }
    }
}

fn events_in(path: &std::path::Path, limit: usize) -> Vec<Event> {
    let Ok(f) = std::fs::File::open(path) else {
        return vec![];
    };
    let mut all: Vec<Event> = std::io::BufReader::new(f)
        .lines()
        .map_while(Result::ok)
        .filter_map(|l| serde_json::from_str(&l).ok())
        .collect();
    let skip = all.len().saturating_sub(limit);
    all.drain(..skip);
    all
}

/// The latest decisions, newest last.
pub fn events(limit: usize) -> Vec<Event> {
    events_in(&dir().join("events.jsonl"), limit)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cpu_block() -> Blocker {
        Blocker {
            resource: "cpu",
            kind: "transient",
            reason: "CPU at 90% (limit 70%)".into(),
            action: "Wait.".into(),
        }
    }
    fn vm_block() -> Blocker {
        Blocker {
            resource: "containers",
            kind: "structural",
            reason: "OrbStack VM memory 14% free of 4.2 GB (limit 15%)".into(),
            action: "Waiting won't help.".into(),
        }
    }
    fn request<'a>(pid: i32, command: &'a str, uses: Uses) -> Request<'a> {
        Request {
            agent_pid: pid,
            folder: "/p",
            command,
            uses,
            weight: 1.,
            containers: &[],
            max_parallel: 2.,
        }
    }
    const ALIVE: fn(i32) -> bool = |_| true;
    /// Admitted commands keep running until told otherwise.
    const RUNS: fn(&Entry) -> bool = |_| true;
    const DONE: fn(&Entry) -> bool = |_| false;
    fn idle(_: Uses, _: &[String]) -> Vec<Blocker> {
        vec![]
    }
    fn busy(_: Uses, _: &[String]) -> Vec<Blocker> {
        vec![cpu_block()]
    }

    #[test]
    fn the_incident_go_runs_php_waits_and_is_told_why() {
        // VM below its limit, Mac idle: only commands that use containers are held.
        let vm_low = |u: Uses, _: &[String]| {
            if u.containers {
                vec![vm_block()]
            } else {
                vec![]
            }
        };
        let mut q = Queue::default();
        let go = decide(
            &mut q,
            1000.,
            &request(1, "go test", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &vm_low,
        );
        assert_eq!(go.outcome, "admitted");
        let php = decide(
            &mut q,
            1100.,
            &request(2, "php artisan test", Uses::ALL),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &vm_low,
        );
        assert_eq!(php.outcome, "deferred");
        assert!(php.structural && php.retry_seconds.is_none());
        assert!(
            php.message.contains("Waiting won't help"),
            "{}",
            php.message
        );
        assert!(php.message.contains("14% free"), "{}", php.message);
        assert_eq!(q.entries.iter().filter(|e| e.state == "waiting").count(), 1);
    }

    #[test]
    fn cpu_is_transient_and_clears_on_a_later_try() {
        let mut q = Queue::default();
        let d = decide(
            &mut q,
            1000.,
            &request(1, "npm run build", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &busy,
        );
        assert_eq!(
            (d.outcome, d.structural, d.retry_seconds),
            ("deferred", false, Some(30))
        );
        let d = decide(
            &mut q,
            1040.,
            &request(1, "npm run build", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &idle,
        );
        assert_eq!(d.outcome, "admitted");
        assert_eq!(q.entries.len(), 1);
        assert_eq!(q.entries[0].state, "running");
    }

    #[test]
    fn three_waiting_commands_start_one_at_a_time() {
        let mut q = Queue::default();
        let lone = |pid| Request {
            max_parallel: 1.,
            ..request(pid, "make test", Uses::MAC)
        };
        for (pid, at) in [(1, 1000.), (2, 1001.), (3, 1002.)] {
            decide(&mut q, at, &lone(pid), Mode::Run, &ALIVE, &RUNS, &busy);
        }
        // The Mac frees up; the third asks first but the first in line goes first.
        let third = decide(&mut q, 1050., &lone(3), Mode::Run, &ALIVE, &RUNS, &idle);
        assert_eq!((third.outcome, third.position), ("deferred", Some(2)));
        let first = decide(&mut q, 1051., &lone(1), Mode::Run, &ALIVE, &RUNS, &idle);
        assert_eq!(first.outcome, "admitted");
        // While the first runs, one at a time means the second waits…
        let second = decide(&mut q, 1100., &lone(2), Mode::Run, &ALIVE, &RUNS, &idle);
        assert_eq!(second.outcome, "deferred");
        assert!(
            second.message.contains("already running"),
            "{}",
            second.message
        );
        // …and goes when it finishes; the third still waits for the readings to settle.
        let second = decide(&mut q, 1200., &lone(2), Mode::Run, &ALIVE, &DONE, &idle);
        assert_eq!(second.outcome, "admitted");
        let third = decide(&mut q, 1205., &lone(3), Mode::Run, &ALIVE, &DONE, &idle);
        assert_eq!(third.outcome, "deferred");
        let third = decide(&mut q, 1240., &lone(3), Mode::Run, &ALIVE, &DONE, &idle);
        assert_eq!(third.outcome, "admitted");
    }

    #[test]
    fn two_commands_on_one_container_never_run_together() {
        let mut q = Queue::default();
        let mysql = ["mysql".to_string()];
        let a = Request {
            containers: &mysql,
            ..request(1, "php artisan test", Uses::ALL)
        };
        let b = Request {
            containers: &mysql,
            ..request(2, "vendor/bin/pest", Uses::ALL)
        };
        assert_eq!(
            decide(&mut q, 1000., &a, Mode::Run, &ALIVE, &RUNS, &idle).outcome,
            "admitted"
        );
        let d = decide(&mut q, 1100., &b, Mode::Run, &ALIVE, &RUNS, &idle);
        assert_eq!(d.outcome, "deferred");
        assert!(d.message.contains("loading mysql now"), "{}", d.message);
        // Something on another container (or none) goes, within max_parallel.
        let go = decide(
            &mut q,
            1101.,
            &request(3, "go test", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &idle,
        );
        assert_eq!(go.outcome, "admitted");
        // Both running fill max_parallel 2: a third waits.
        let d = decide(
            &mut q,
            1200.,
            &request(4, "npm run build", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &idle,
        );
        assert!(d.message.contains("weight 2 of 2"), "{}", d.message);
    }

    #[test]
    fn a_dead_or_silent_session_does_not_hold_the_queue() {
        let mut q = Queue::default();
        decide(
            &mut q,
            1000.,
            &request(1, "make test", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &busy,
        );
        decide(
            &mut q,
            1001.,
            &request(2, "make test", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &busy,
        );
        // Agent 1 died: agent 2 goes.
        let only_two = |pid: i32| pid == 2;
        let d = decide(
            &mut q,
            1010.,
            &request(2, "make test", Uses::MAC),
            Mode::Run,
            &only_two,
            &RUNS,
            &idle,
        );
        assert_eq!(d.outcome, "admitted");
        // A reservation nobody uses expires.
        let mut q = Queue::default();
        decide(
            &mut q,
            2000.,
            &request(5, "go test", Uses::MAC),
            Mode::Reserve,
            &ALIVE,
            &RUNS,
            &idle,
        );
        assert_eq!(q.entries[0].state, "granted");
        prune(&mut q, 2000. + RESERVATION_TTL + 1., &ALIVE, &RUNS);
        assert!(q.entries.is_empty());
        // A waiting entry nobody refreshes expires.
        decide(
            &mut q,
            3000.,
            &request(6, "go test", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &busy,
        );
        prune(&mut q, 3000. + WAITING_TTL + 1., &ALIVE, &RUNS);
        assert!(q.entries.is_empty());
        // A running command counts until its processes end (after the start grace).
        decide(
            &mut q,
            4000.,
            &request(7, "go test", Uses::MAC),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &idle,
        );
        prune(&mut q, 4010., &ALIVE, &DONE);
        assert_eq!(q.entries.len(), 1, "not seen yet, but just admitted");
        prune(&mut q, 4000. + START_GRACE + 1., &ALIVE, &DONE);
        assert!(q.entries.is_empty());
    }

    #[test]
    fn a_reservation_is_used_by_the_next_run_and_counts_meanwhile() {
        let mut q = Queue::default();
        let lone = |pid| Request {
            max_parallel: 1.,
            ..request(pid, "go test", Uses::MAC)
        };
        let r = decide(&mut q, 1000., &lone(1), Mode::Reserve, &ALIVE, &RUNS, &idle);
        assert_eq!(r.outcome, "reserved");
        let other = decide(&mut q, 1030., &lone(2), Mode::Run, &ALIVE, &RUNS, &idle);
        assert_eq!(other.outcome, "deferred");
        let run = decide(&mut q, 1031., &lone(1), Mode::Run, &ALIVE, &RUNS, &idle);
        assert_eq!(run.outcome, "admitted");
        assert!(
            q.entries
                .iter()
                .any(|e| e.agent_pid == 1 && e.state == "running")
        );
        // The app's Run now: a waiting entry granted goes at once.
        assert!(grant(&mut q, 2, "go test", 1032.));
        let d = decide(&mut q, 1033., &lone(2), Mode::Run, &ALIVE, &RUNS, &busy);
        assert_eq!(d.outcome, "admitted");
        assert_eq!(release(&mut q, 9, None), 0);
        assert_eq!(release(&mut q, 1, Some("go test")), 1);
    }

    #[test]
    fn running_means_a_process_started_for_the_command_lives() {
        let e = Entry {
            agent_pid: 10,
            folder: "/p".into(),
            command: "go test".into(),
            uses: Uses::MAC,
            weight: 1.,
            containers: vec![],
            state: "running".into(),
            since: 100.,
            seen: 100.,
            reason: String::new(),
        };
        let mcp = (11, 10, 50_000_000); // the agent's MCP server, from before
        let shell = (12, 10, 101_000_000); // the command's shell, right after admission
        let later = (13, 10, 400_000_000); // a later command of the same agent
        let child = (14, 11, 102_000_000); // started by the MCP server, still in the window
        assert!(running_in(&[mcp, shell], &e));
        assert!(!running_in(&[mcp, later], &e));
        assert!(running_in(&[mcp, child], &e), "anywhere under the agent");
        assert!(!running_in(&[(20, 99, 101_000_000)], &e), "not the agent's");
    }

    #[test]
    fn an_agent_running_one_command_after_another_is_not_held_by_its_own() {
        let mut q = Queue::default();
        let lone = |cmd| Request {
            max_parallel: 1.,
            ..request(1, cmd, Uses::MAC)
        };
        assert_eq!(
            decide(
                &mut q,
                1000.,
                &lone("go test"),
                Mode::Run,
                &ALIVE,
                &RUNS,
                &idle
            )
            .outcome,
            "admitted"
        );
        // Its go test finished (no process left): the next command goes at once.
        let d = decide(
            &mut q,
            1005.,
            &lone("npm run build"),
            Mode::Run,
            &ALIVE,
            &DONE,
            &idle,
        );
        assert_eq!(d.outcome, "admitted", "{}", d.message);
        // Another agent right after still waits for the readings to settle.
        let other = Request {
            max_parallel: 2.,
            ..request(2, "go test", Uses::MAC)
        };
        assert_eq!(
            decide(&mut q, 1006., &other, Mode::Run, &ALIVE, &RUNS, &idle).outcome,
            "deferred"
        );
        // A command the agent left running in the background still counts.
        let d = decide(
            &mut q,
            1010.,
            &lone("make test"),
            Mode::Run,
            &ALIVE,
            &RUNS,
            &idle,
        );
        assert_eq!(d.outcome, "deferred");
    }

    #[test]
    fn heavier_commands_leave_more_room_before_the_next() {
        let mut q = Queue::default();
        let heavy = Request {
            weight: 3.,
            max_parallel: 4.,
            ..request(1, "php artisan test", Uses::ALL)
        };
        decide(&mut q, 1000., &heavy, Mode::Run, &ALIVE, &RUNS, &idle);
        let go = Request {
            max_parallel: 4.,
            ..request(2, "go test", Uses::MAC)
        };
        assert_eq!(
            decide(&mut q, 1030., &go, Mode::Run, &ALIVE, &RUNS, &idle).outcome,
            "deferred"
        );
        assert_eq!(
            decide(&mut q, 1046., &go, Mode::Run, &ALIVE, &RUNS, &idle).outcome,
            "admitted"
        );
    }
}
