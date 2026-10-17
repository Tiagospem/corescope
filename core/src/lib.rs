//! CoreScope: bounded local telemetry and explicitly authorized process control.
pub mod containers;
pub mod history;
mod os;
mod sqlite;
use os::*;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    ffi::{CStr, CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Mutex, OnceLock},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
#[derive(Clone, Serialize)]
pub struct Metric {
    pub value: Option<f64>,
    pub unit: &'static str,
    pub source: &'static str,
    pub at: f64,
    pub state: &'static str,
}
impl Metric {
    fn new(value: Option<f64>, unit: &'static str, source: &'static str, at: f64) -> Self {
        Self {
            value,
            unit,
            source,
            at,
            state: if value.is_some() {
                "available"
            } else {
                "unavailable"
            },
        }
    }
    fn permission(mut self, error: i32) -> Self {
        if self.value.is_none() && (error == 1 || error == 13) {
            self.state = "permission";
        }
        self
    }
    fn unsupported(source: &'static str, at: f64) -> Self {
        Self {
            value: None,
            unit: "°C",
            source,
            at,
            state: "unsupported",
        }
    }
}
/// Per-process metrics travel as `{"value":x}` (plus `state` when not available): source and
/// unit are fixed per field and the timestamp equals the snapshot's, so repeating them for
/// every process made each sample several hundred KB.
fn lean<S: serde::Serializer>(m: &Metric, s: S) -> Result<S::Ok, S::Error> {
    use serde::ser::SerializeMap;
    let mut map = s.serialize_map(None)?;
    map.serialize_entry("value", &m.value)?;
    if m.state != "available" {
        map.serialize_entry("state", m.state)?;
    }
    map.end()
}
fn temperature(kelvin: u32, status: i32, at: f64) -> Metric {
    let valid = status == 0 && (173..=473).contains(&kelvin);
    let mut metric = Metric::new(
        valid.then_some(kelvin as f64 - 273.15),
        "°C",
        "IOKit · NVMe SMART · temperatura composta do controlador",
        at,
    );
    metric.state = if valid {
        "available"
    } else {
        match status {
            1 => "unsupported",
            2 => "permission",
            _ => "unavailable",
        }
    };
    metric
}
#[derive(Deserialize)]
#[serde(default)]
pub struct Config {
    pub thermal: i32,
    pub pressure: i32,
    pub pressure_at: f64,
    pub cpu_warning: f64,
    pub cpu_critical: f64,
    pub sustain: f64,
    pub disk_warning: f64,
    pub disk_critical: f64,
    pub watched: Vec<String>,
    pub ignored: Vec<String>,
    /// Persistent history retention in days; 0 keeps history off (the default).
    pub history_days: u32,
    /// Database file; empty uses ~/Library/Application Support/CoreScope/history.sqlite.
    pub history_path: String,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            thermal: -1,
            pressure: -1,
            pressure_at: 0.,
            cpu_warning: 80.,
            cpu_critical: 95.,
            sustain: 20.,
            disk_warning: 10.,
            disk_critical: 5.,
            watched: vec![],
            ignored: vec![],
            history_days: 0,
            history_path: String::new(),
        }
    }
}
impl Config {
    fn sanitize(&mut self) {
        self.cpu_warning = self.cpu_warning.clamp(10., 95.);
        self.cpu_critical = self.cpu_critical.clamp(self.cpu_warning + 1., 100.);
        self.sustain = self.sustain.clamp(5., 300.);
        self.disk_warning = self.disk_warning.clamp(2., 50.);
        self.disk_critical = self.disk_critical.clamp(1., self.disk_warning - 1.);
        self.watched.truncate(12);
        self.ignored.truncate(256);
        // Only the retentions offered in the interface: 1, 7 or 30 days.
        self.history_days = match self.history_days {
            0 => 0,
            1 => 1,
            2..=7 => 7,
            _ => 30,
        };
    }
}
#[derive(Default)]
struct Gate {
    level: u8,
    pending: u8,
    since: f64,
}
impl Gate {
    fn update(&mut self, desired: u8, time: f64, hold: f64) -> u8 {
        if desired == self.level || desired != self.pending {
            self.pending = desired;
            self.since = time;
        } else if time - self.since >= hold {
            self.level = desired;
        }
        self.level
    }
}
fn cpu_percent(old: &[u64; 4], new: &[u64; 4]) -> Option<f64> {
    if new.iter().zip(old).any(|(a, b)| a < b) {
        return None;
    }
    let d: Vec<u64> = new.iter().zip(old).map(|(a, b)| a - b).collect();
    let sum: u64 = d.iter().sum();
    (sum > 0).then(|| ((sum - d[2]) as f64 / sum as f64 * 100.).clamp(0., 100.))
}
fn rate(old: u64, new: u64, elapsed: f64) -> Option<f64> {
    (elapsed > 0. && elapsed <= 60. && new >= old).then(|| (new - old) as f64 / elapsed)
}
/// Core type per logical CPU. The device tree map is used only when it covers every CPU and
/// agrees with the sysctl performance-level counts; otherwise types stay unknown (empty).
fn classify_cores(
    tree: &[u8],
    perf: (u32, u32),
    count: usize,
) -> (Vec<&'static str>, &'static str) {
    let unknown = vec![""; count];
    if count == 0 {
        return (unknown, "host_processor_info indisponível");
    }
    if perf.1 == 0 {
        return (unknown, "sysctl · um único nível de desempenho");
    }
    let mapped = tree.len() >= count && tree[..count].iter().all(|k| *k == b'P' || *k == b'E');
    let performance = tree.iter().take(count).filter(|k| **k == b'P').count();
    if !mapped || performance != perf.0 as usize || count - performance != perf.1 as usize {
        return (
            unknown,
            "Tipo por núcleo indisponível (mapa do IODeviceTree incompleto)",
        );
    }
    (
        tree[..count]
            .iter()
            .map(|k| if *k == b'P' { "P" } else { "E" })
            .collect(),
        "IODeviceTree · cluster-type, conferido com sysctl hw.perflevel0/1",
    )
}
/// Activity Monitor's categories from host_statistics64: app memory is anonymous memory that
/// is not purgeable; cached files are file-backed plus purgeable pages.
fn memory_breakdown(internal: u64, purgeable: u64, external: u64) -> (u64, u64) {
    (internal.saturating_sub(purgeable), external + purgeable)
}
/// kern.memorystatus_level is the share of memory the kernel considers available.
fn pressure_percent(level: i32) -> Option<f64> {
    (0..=100).contains(&level).then_some(100. - level as f64)
}
#[derive(Clone, Serialize)]
pub struct CoreLoad {
    /// "P", "E" or "" when the type is unknown.
    pub kind: &'static str,
    pub value: Option<f64>,
}
#[derive(Clone, Default, Serialize)]
pub struct Point {
    pub at: f64,
    pub cpu: Option<f64>,
    pub memory: Option<f64>,
    pub disk_read: Option<f64>,
    pub disk_write: Option<f64>,
    pub net_in: Option<f64>,
    pub net_out: Option<f64>,
}
#[derive(Clone, Serialize)]
pub struct Port {
    pub port: u16,
    /// Bound beyond loopback (all interfaces or a LAN address).
    pub exposed: bool,
}
/// Nearest ancestor that hosts developer work: agent, editor or terminal.
#[derive(Clone, Serialize)]
pub struct Origin {
    pub label: &'static str,
    pub kind: &'static str,
    pub pid: i32,
}
fn app_bundle(path: &str, bundle: &str) -> bool {
    path.contains(&format!("/{bundle}.app/"))
}
/// Main executable of an app bundle; helpers under Frameworks/Helpers are excluded.
fn app_main(path: &str, bundle: &str) -> bool {
    path.contains(&format!("/{bundle}.app/Contents/MacOS/"))
}
/// Identifies processes that start developer work. Name-based heuristic; never used to act automatically.
pub fn host(name: &str, path: &str) -> Option<(&'static str, &'static str)> {
    let lower = name.to_lowercase();
    // Desktop apps host sessions; their bundled CLIs (e.g. claude-code/<v>/claude.app) are the sessions.
    if app_main(path, "Claude") {
        return Some(("Claude Desktop", "agent"));
    }
    if app_main(path, "Codex") {
        return Some(("Codex Desktop", "agent"));
    }
    if lower == "claude" || path.contains("/claude/versions/") || path.contains("/claude-code/") {
        return Some(("Claude Code", "agent"));
    }
    if lower.starts_with("codex") {
        return Some(("Codex", "agent"));
    }
    for (bin, label) in [
        ("gemini", "Gemini CLI"),
        ("aider", "Aider"),
        ("opencode", "OpenCode"),
        ("cursor-agent", "Cursor Agent"),
        ("copilot", "Copilot CLI"),
        ("amp", "Amp"),
    ] {
        if lower == bin {
            return Some((label, "agent"));
        }
    }
    for (bundle, label) in [
        ("Visual Studio Code", "VS Code"),
        ("Cursor", "Cursor"),
        ("Zed", "Zed"),
        ("Zed Preview", "Zed"),
        ("Windsurf", "Windsurf"),
        ("Xcode", "Xcode"),
        ("PhpStorm", "PhpStorm"),
        ("WebStorm", "WebStorm"),
        ("PyCharm", "PyCharm"),
        ("GoLand", "GoLand"),
        ("RustRover", "RustRover"),
        ("IntelliJ IDEA", "IntelliJ IDEA"),
        ("Android Studio", "Android Studio"),
        ("Sublime Text", "Sublime Text"),
        ("Nova", "Nova"),
    ] {
        if app_main(path, bundle) {
            return Some((label, "editor"));
        }
    }
    if lower == "zed" || lower == "nvim" || lower == "vim" || lower == "emacs" {
        return Some(match lower.as_str() {
            "zed" => ("Zed", "editor"),
            "emacs" => ("Emacs", "editor"),
            _ => ("Neovim", "editor"),
        });
    }
    for (bundle, label) in [
        ("Terminal", "Terminal"),
        ("iTerm", "iTerm2"),
        ("Warp", "Warp"),
        ("Ghostty", "Ghostty"),
        ("WezTerm", "WezTerm"),
        ("kitty", "kitty"),
        ("Alacritty", "Alacritty"),
        ("Hyper", "Hyper"),
        ("Tabby", "Tabby"),
    ] {
        if app_main(path, bundle) {
            return Some((label, "terminal"));
        }
    }
    (lower == "tmux" || lower == "zellij").then_some(("tmux", "terminal"))
}
/// Descriptive tags for grouping and filtering in the interface.
pub fn tags(name: &str, path: &str, listening: bool) -> Vec<&'static str> {
    let lower = name.to_lowercase();
    let mut out = Vec::new();
    if let Some((_, kind)) = host(name, path) {
        out.push(kind);
    }
    const RUNTIMES: [&str; 34] = [
        "node",
        "bun",
        "deno",
        "python",
        "ruby",
        "php",
        "java",
        "go",
        "cargo",
        "rustc",
        "npm",
        "npx",
        "pnpm",
        "yarn",
        "tsx",
        "ts-node",
        "esbuild",
        "vite",
        "next-server",
        "nodemon",
        "uvicorn",
        "gunicorn",
        "rails",
        "puma",
        "sidekiq",
        "dotnet",
        "beam.smp",
        "elixir",
        "mix",
        "turbo",
        "webpack",
        "jest",
        "vitest",
        "playwright",
    ];
    let runtime = RUNTIMES.iter().any(|r| {
        lower == *r
            || lower.starts_with(&format!("{r}."))
            || lower.starts_with(&format!("{r}-"))
            || (r.len() > 3 && lower.starts_with(r))
    }) || lower.starts_with("python")
        || lower.starts_with("php")
        || path.contains("/go-build")
        || path.contains("/node_modules/");
    if lower.contains("mcp") {
        out.push("mcp");
    }
    if runtime || lower.contains("mcp") {
        out.push("runtime");
    }
    if ["zsh", "bash", "sh", "fish", "nu", "dash", "login"].contains(&lower.as_str()) {
        out.push("shell");
    }
    if [
        "docker",
        "com.docker",
        "orbstack",
        "qemu-system",
        "vfkit",
        "colima",
        "limactl",
        "podman",
        "containerd",
        "krunvm",
    ]
    .iter()
    .any(|c| lower.starts_with(c))
        || app_bundle(path, "OrbStack")
        || app_bundle(path, "Docker")
    {
        out.push("container");
    }
    if [
        "postgres",
        "redis-server",
        "mysqld",
        "mariadbd",
        "mongod",
        "memcached",
        "valkey-server",
        "clickhouse",
        "meilisearch",
        "typesense-server",
    ]
    .iter()
    .any(|d| lower.starts_with(d))
    {
        out.push("database");
    }
    if listening {
        out.push("server");
    }
    out
}
/// Orphan evidence for same-user, eligible processes. Moderate confidence; no automatic action.
pub fn orphan_reason(
    ppid: i32,
    lost_parent: Option<&str>,
    age: f64,
    path: &str,
    tags: &[&str],
) -> Option<String> {
    // Texts are stable keys: the interface translates them, values travel in separate fields.
    if lost_parent.is_some() && age >= 30. {
        return Some(
            "O processo pai encerrou e este continuou rodando, adotado pelo launchd.".into(),
        );
    }
    let dev = tags.contains(&"runtime") && !tags.contains(&"agent") && !tags.contains(&"editor");
    (ppid == 1 && dev && age >= 60. && !path.contains(".app/") && !path.starts_with("/Library/"))
        .then(|| "Sem processo pai: adotado pelo launchd. Runtimes de desenvolvimento costumam ter terminal, editor ou agente como pai; pode ser um serviço iniciado de propósito.".into())
}
fn push(history: &mut VecDeque<Point>, point: Point) {
    let cutoff = point.at - 600.;
    history.push_back(point);
    while history.len() > 120 || history.front().is_some_and(|p| p.at < cutoff) {
        history.pop_front();
    }
}
#[derive(Serialize)]
pub struct Process {
    pub id: String,
    pub pid: i32,
    pub ppid: i32,
    pub uid: u32,
    pub user: String,
    pub start: u64,
    pub name: String,
    pub path: String,
    #[serde(serialize_with = "lean")]
    pub cpu: Metric,
    #[serde(serialize_with = "lean")]
    pub memory: Metric,
    #[serde(serialize_with = "lean")]
    pub resident: Metric,
    #[serde(serialize_with = "lean")]
    pub threads: Metric,
    #[serde(serialize_with = "lean")]
    pub read: Metric,
    #[serde(serialize_with = "lean")]
    pub write: Metric,
    pub eligible: bool,
    pub blocked: String,
    pub orphan: Option<String>,
    /// Parent observed before reparenting to launchd, when known.
    pub orphan_parent: Option<String>,
    pub cwd: String,
    pub ports: Vec<Port>,
    pub tags: Vec<&'static str>,
    /// Label when this process itself hosts developer work (agent, editor, terminal).
    pub host: Option<&'static str>,
    pub origin: Option<Origin>,
    pub high_cpu_seconds: f64,
    pub history: VecDeque<Point>,
}
#[derive(Clone, Serialize)]
pub struct Volume {
    pub id: String,
    pub mount: String,
    pub kind: String,
    pub total: Metric,
    pub available: Metric,
    pub temperature: Metric,
}
#[derive(Clone, Serialize)]
pub struct Disk {
    pub id: String,
    pub name: String,
    pub read: Metric,
    pub write: Metric,
    pub temperature: Metric,
}
#[derive(Serialize)]
pub struct Diagnostic {
    pub id: &'static str,
    pub level: u8,
    pub title: String,
    pub detail: String,
}
#[derive(Serialize)]
pub struct Snapshot {
    pub at: f64,
    pub cores: u32,
    pub cpu: Metric,
    pub physical: Metric,
    pub active: Metric,
    pub wired: Metric,
    pub compressed: Metric,
    pub swap: Metric,
    pub app_memory: Metric,
    pub cached_files: Metric,
    pub pressure_percent: Metric,
    pub pressure: Metric,
    pub thermal: Metric,
    pub core_load: Vec<CoreLoad>,
    pub core_source: &'static str,
    /// "off", "recording" or the last write error.
    pub history_state: String,
    pub processes: Vec<Process>,
    pub volumes: Vec<Volume>,
    pub disks: Vec<Disk>,
    pub diagnostics: Vec<Diagnostic>,
    pub history: VecDeque<Point>,
    pub disk_read: Metric,
    pub disk_write: Metric,
    pub net_in: Metric,
    pub net_out: Metric,
    pub collector_ms: f64,
    pub own_wakeups: Metric,
    pub process_state: String,
    pub volume_state: String,
    pub disk_state: String,
    pub current_uid: u32,
}
struct Previous {
    raw: RawProcess,
    high_since: Option<f64>,
    lost_parent: Option<String>,
    history: VecDeque<Point>,
}
#[derive(Default)]
pub struct Collector {
    last: Option<Instant>,
    clock: Option<Instant>,
    ticks: Option<[u64; 4]>,
    previous: HashMap<i32, Previous>,
    history: VecDeque<Point>,
    gates: HashMap<&'static str, Gate>,
    volumes: Vec<Volume>,
    disks: Vec<Disk>,
    disk_raw: HashMap<u64, (u64, u64)>,
    temperatures: HashMap<u64, (Instant, Metric)>,
    last_volumes: Option<Instant>,
    last_disks: Option<Instant>,
    /// cwd and listening ports per pid, keyed by start time; refreshed every 5 s.
    extras: HashMap<i32, (u64, String, Vec<Port>)>,
    last_extras: Option<Instant>,
    net_raw: Option<(Instant, u64, u64)>,
    volume_state: String,
    disk_state: String,
    core_ticks: Option<Vec<[u64; 4]>>,
    /// Core types never change while the app runs: read once.
    core_kinds: Option<(Vec<&'static str>, &'static str)>,
    recorder: history::Recorder,
}
fn blocked(p: &RawProcess, uid: u32, protected: &HashSet<i32>) -> &'static str {
    let name = string(&p.name);
    let path = string(&p.path);
    if p.pid <= 1 || p.start == 0 {
        return "Identidade inválida ou processo do sistema";
    }
    if p.uid != uid {
        return "Pertence a outro usuário";
    }
    if p.flags & 1 != 0 || protected.contains(&p.pid) {
        return "Processo protegido ou ancestral do CoreScope";
    }
    if [
        "launchd",
        "kernel_task",
        "WindowServer",
        "loginwindow",
        "Finder",
        "Dock",
        "SystemUIServer",
        "runningboardd",
        "watchdogd",
        "securityd",
    ]
    .contains(&name.as_str())
        || path.starts_with("/System/")
        || path.starts_with("/usr/libexec/")
    {
        return "Serviço essencial protegido";
    }
    if path.is_empty() {
        return "Executável indisponível; ação bloqueada";
    }
    ""
}
fn protected() -> HashSet<i32> {
    let mut out = HashSet::new();
    let mut pid = unsafe { os_self() };
    for _ in 0..64 {
        if pid <= 1 || !out.insert(pid) {
            break;
        }
        let Some(p) = process(pid) else { break };
        pid = p.ppid;
    }
    out
}
fn dev_name(name: &str, path: &str) -> bool {
    host(name, path).is_some()
        || tags(name, path, false)
            .iter()
            .any(|t| ["runtime", "shell"].contains(t))
}
/// Fills `origin` with the nearest strict ancestor that is an agent, editor or terminal.
fn assign_origins(processes: &mut [Process]) {
    let index: HashMap<i32, usize> = processes
        .iter()
        .enumerate()
        .map(|(i, p)| (p.pid, i))
        .collect();
    let hosts: Vec<Option<(&'static str, &'static str)>> =
        processes.iter().map(|p| host(&p.name, &p.path)).collect();
    for i in 0..processes.len() {
        let mut current = processes[i].ppid;
        let mut origin = None;
        for _ in 0..48 {
            if current <= 1 {
                break;
            }
            let Some(&j) = index.get(&current) else { break };
            if let Some((label, kind)) = hosts[j] {
                origin = Some(Origin {
                    label,
                    kind,
                    pid: current,
                });
                break;
            }
            current = processes[j].ppid;
        }
        processes[i].origin = origin;
    }
}
impl Collector {
    pub fn reset(&mut self) {
        self.last = None;
        self.clock = None;
        self.ticks = None;
        self.previous.clear();
        self.history.clear();
        self.gates.clear();
        self.last_volumes = None;
        self.last_disks = None;
        self.disk_raw.clear();
        self.temperatures.clear();
        self.extras.clear();
        self.last_extras = None;
        self.net_raw = None;
        self.core_ticks = None;
    }
    pub fn sample(&mut self, mut config: Config) -> Snapshot {
        config.sanitize();
        let begin = Instant::now();
        let at = now();
        let dt = self.last.map(|v| v.elapsed().as_secs_f64());
        if dt.is_some_and(|v| v > 60.) {
            self.reset();
        }
        let dt = dt.filter(|v| *v <= 60.);
        self.last = Some(begin);
        let elapsed = self.clock.get_or_insert(begin).elapsed().as_secs_f64();
        let mut h = Host::default();
        unsafe { os_host(&mut h) };
        let cpu = if h.cpu_ok != 0 {
            self.ticks.and_then(|old| cpu_percent(&old, &h.ticks))
        } else {
            None
        };
        self.ticks = (h.cpu_ok != 0).then_some(h.ticks);
        let mem = |v: u64| (h.memory_ok != 0).then_some(v as f64);
        let core_load = self.sample_cores();
        let (app_memory, cached_files) = memory_breakdown(h.internal, h.purgeable, h.external);
        let pressure_pct = pressure_percent(h.memory_level);
        let mut pids = vec![0i32; 8192];
        let count = unsafe { os_pids(pids.as_mut_ptr(), pids.len() as i32) };
        pids.truncate(count.max(0) as usize);
        let raws: Vec<_> = pids
            .into_iter()
            .filter(|p| *p > 0)
            .filter_map(process)
            .collect();
        let uid = unsafe { os_uid() };
        let protected = protected();
        let own = unsafe { os_self() };
        let mut own_wakeups = None;
        let refresh_extras = self
            .last_extras
            .is_none_or(|t| t.elapsed().as_secs_f64() >= 5.);
        if refresh_extras {
            self.last_extras = Some(Instant::now());
        }
        let mut extras = HashMap::new();
        let mut previous = HashMap::with_capacity(raws.len());
        let mut processes = Vec::with_capacity(raws.len());
        for raw in raws {
            let id = format!("{}:{}", raw.pid, raw.start);
            let old = self
                .previous
                .get(&raw.pid)
                .filter(|p| p.raw.start == raw.start);
            let usage = (raw.task_ok != 0 || raw.usage_ok != 0).then_some(raw.cpu_ns);
            let pcpu = old
                .filter(|p| p.raw.task_ok != 0 || p.raw.usage_ok != 0)
                .and_then(|p| usage.and_then(|ns| dt.and_then(|d| rate(p.raw.cpu_ns, ns, d))))
                .map(|v| v / 1e7);
            let memory = (raw.usage_ok != 0).then_some(raw.footprint as f64);
            let mut lost = old.and_then(|p| p.lost_parent.clone());
            if let Some(old) = old
                && old.raw.ppid != raw.ppid
                && raw.ppid == 1
                && let Some(parent) = self.previous.get(&old.raw.ppid)
            {
                let name = string(&parent.raw.name);
                if dev_name(&name, &string(&parent.raw.path)) {
                    lost = Some(format!("{} · PID {}", name, parent.raw.pid));
                }
            }
            let high = if pcpu.is_some_and(|v| v >= 80.) {
                Some(old.and_then(|p| p.high_since).unwrap_or(elapsed))
            } else {
                None
            };
            let mut history = if config.watched.contains(&id) {
                old.map(|p| p.history.clone()).unwrap_or_default()
            } else {
                VecDeque::new()
            };
            if config.watched.contains(&id) {
                push(
                    &mut history,
                    Point {
                        at,
                        cpu: pcpu,
                        memory,
                        ..Default::default()
                    },
                );
            }
            let reason = blocked(&raw, uid, &protected);
            let io = |v: u64, old_v: Option<u64>| {
                old_v
                    .and_then(|prev| dt.and_then(|d| rate(prev, v, d)))
                    .filter(|_| raw.usage_ok != 0)
            };
            if raw.pid == own {
                own_wakeups = io(raw.wakeups, old.map(|p| p.raw.wakeups));
            }
            let path = string(&raw.path);
            let name = string(&raw.name);
            // Same-user only: other users' descriptors and cwd are not readable without privileges.
            let (cwd, listening) = if raw.uid != uid {
                (String::new(), vec![])
            } else {
                match self.extras.get(&raw.pid) {
                    Some((start, cwd, ports)) if *start == raw.start && !refresh_extras => {
                        (cwd.clone(), ports.clone())
                    }
                    _ => (
                        cwd(raw.pid),
                        ports(raw.pid)
                            .into_iter()
                            .map(|p| Port {
                                port: p.port,
                                exposed: p.exposed != 0,
                            })
                            .collect(),
                    ),
                }
            };
            if raw.uid == uid {
                extras.insert(raw.pid, (raw.start, cwd.clone(), listening.clone()));
            }
            let tags = tags(&name, &path, !listening.is_empty());
            let host_label = host(&name, &path).map(|h| h.0);
            let age = at - raw.start as f64 / 1e6;
            processes.push(Process {
                id: id.clone(),
                pid: raw.pid,
                ppid: raw.ppid,
                uid: raw.uid,
                user: string(&raw.user),
                start: raw.start,
                name,
                orphan: if config.ignored.contains(&id) || !reason.is_empty() {
                    None
                } else {
                    orphan_reason(raw.ppid, lost.as_deref(), age, &path, &tags)
                },
                orphan_parent: lost.clone(),
                path,
                cwd,
                ports: listening,
                host: host_label,
                tags,
                origin: None,
                cpu: Metric::new(pcpu, "% de um núcleo", "libproc · delta de tempo CPU", at),
                memory: Metric::new(memory, "B", "proc_pid_rusage · phys_footprint", at),
                resident: Metric::new(
                    (raw.task_ok != 0).then_some(raw.resident as f64),
                    "B",
                    "PROC_PIDTASKINFO · resident_size",
                    at,
                )
                .permission(raw.task_error),
                threads: Metric::new(
                    (raw.task_ok != 0).then_some(raw.threads as f64),
                    "threads",
                    "PROC_PIDTASKINFO",
                    at,
                )
                .permission(raw.task_error),
                read: Metric::new(
                    io(raw.read_bytes, old.map(|p| p.raw.read_bytes)),
                    "B/s",
                    "proc_pid_rusage · diskio_bytesread",
                    at,
                ),
                write: Metric::new(
                    io(raw.write_bytes, old.map(|p| p.raw.write_bytes)),
                    "B/s",
                    "proc_pid_rusage · diskio_byteswritten",
                    at,
                ),
                eligible: reason.is_empty(),
                blocked: reason.into(),
                high_cpu_seconds: high.map(|t| elapsed - t).unwrap_or(0.),
                history: history.clone(),
            });
            previous.insert(
                raw.pid,
                Previous {
                    raw,
                    high_since: high,
                    lost_parent: lost,
                    history,
                },
            );
        }
        self.previous = previous;
        self.extras = extras;
        assign_origins(&mut processes);
        processes.sort_by(|a, b| {
            b.cpu
                .value
                .unwrap_or(-1.)
                .total_cmp(&a.cpu.value.unwrap_or(-1.))
        });
        self.refresh_storage(at);
        let total = |f: fn(&Disk) -> Option<f64>| {
            let values: Vec<f64> = self.disks.iter().filter_map(f).collect();
            (!values.is_empty()).then(|| values.iter().sum::<f64>())
        };
        let disk_read = total(|d| d.read.value);
        let disk_write = total(|d| d.write.value);
        let (net_in, net_out) = self.sample_network();
        let memory_used = mem(h.active + h.wired + h.compressed);
        push(
            &mut self.history,
            Point {
                at,
                cpu,
                memory: memory_used,
                disk_read,
                disk_write,
                net_in,
                net_out,
            },
        );
        let history_state = if config.history_days == 0 {
            self.recorder.disable();
            "off".to_string()
        } else {
            let path = if config.history_path.is_empty() {
                history::default_path()
            } else {
                config.history_path.clone()
            };
            self.recorder.set_path(&path);
            let system = history::System {
                cpu,
                memory: memory_used,
                swap: (h.swap_ok != 0).then_some(h.swap as f64),
                disk_read,
                disk_write,
                net_in,
                net_out,
                thermal: Some(config.thermal as i64),
                pressure: Some(config.pressure as i64),
                pressure_pct,
            };
            self.recorder.add(
                at,
                config.history_days,
                system,
                processes.iter().map(|p| history::Proc {
                    key: (p.pid, p.start),
                    name: &p.name,
                    path: &p.path,
                    cwd: &p.cwd,
                    origin: p.origin.as_ref().map_or("", |o| o.label),
                    cpu: p.cpu.value,
                    memory: p.memory.value,
                }),
            );
            self.recorder
                .error
                .clone()
                .unwrap_or_else(|| "recording".into())
        };
        let mut diagnostics = Vec::new();
        let current = self.gates.entry("cpu").or_default().level;
        let desired = cpu
            .map(|v| {
                if v >= config.cpu_critical {
                    2
                } else if v >= config.cpu_warning || (current > 0 && v >= config.cpu_warning - 5.) {
                    1
                } else {
                    0
                }
            })
            .unwrap_or(0);
        let level = self
            .gates
            .entry("cpu")
            .or_default()
            .update(desired, elapsed, config.sustain);
        diagnostics.push(Diagnostic{id:"cpu",level,title:if cpu.is_none(){"CPU em aquecimento".into()}else if level>0{"CPU elevada de forma sustentada".into()}else{"CPU sem alerta sustentado".into()},detail:"Total normalizado em 0–100%, com janela sustentada configurável; saída 5 pontos abaixo do limite. Consumo alto não comprova a causa de lentidão.".into()});
        let mem_level = match config.pressure {
            2 => 2,
            1 => 1,
            _ => 0,
        };
        let level = self
            .gates
            .entry("memory")
            .or_default()
            .update(mem_level, elapsed, 5.);
        diagnostics.push(Diagnostic{id:"memory",level,title:match config.pressure {2=>"Evento de pressão crítica de memória",1=>"Evento de pressão de memória",0=>"Último evento de memória: normal",_=>"Pressão de memória ainda não informada"}.into(),detail:"Fonte: eventos Dispatch do macOS. RAM ativa, wired e compressor são contagens distintas; não equivalem à pressão. Swap ocupado, isoladamente, não indica problema atual.".into()});
        let thermal_level = match config.thermal {
            3 => 2,
            2 => 1,
            _ => 0,
        };
        let level = self
            .gates
            .entry("thermal")
            .or_default()
            .update(thermal_level, elapsed, 5.);
        diagnostics.push(Diagnostic{id:"thermal",level,title:match config.thermal{0=>"Condição térmica nominal",1=>"Condição térmica moderada",2=>"Condição térmica séria",3=>"Condição térmica crítica",_=>"Condição térmica indisponível"}.into(),detail:"Estado informado pelo macOS; não é temperatura em °C. Em estado sério/crítico, reduza tarefas concorrentes e verifique ventilação.".into()});
        let available = self
            .volumes
            .iter()
            .filter(|v| {
                v.mount == "/"
                    || v.mount == "/System/Volumes/Data"
                    || (v.mount.starts_with("/Volumes/") && v.mount != "/Volumes/Recovery")
            })
            .filter_map(|v| v.available.value.zip(v.total.value))
            .filter(|(_, t)| *t > 0.)
            .map(|(a, t)| 100. * a / t)
            .reduce(f64::min);
        let current = self.gates.entry("storage").or_default().level;
        let desired = available
            .map(|v| {
                if v < config.disk_critical {
                    2
                } else if v < config.disk_warning || (current > 0 && v < config.disk_warning + 2.) {
                    1
                } else {
                    0
                }
            })
            .unwrap_or(0);
        let level =
            self.gates
                .entry("storage")
                .or_default()
                .update(desired, elapsed, config.sustain);
        diagnostics.push(Diagnostic{id:"storage",level,title:if level>0{"Pouco espaço em um volume"}else{"Armazenamento: confira capacidade e atividade"}.into(),detail:"Volumes APFS podem compartilhar espaço: não some suas capacidades. Taxa alta de I/O não mede saturação ou latência; esta versão não diagnostica pressão de I/O.".into()});
        diagnostics.sort_by_key(|d| std::cmp::Reverse(d.level));
        Snapshot {
            at,
            cores: h.cores,
            cpu: Metric::new(cpu, "%", "host_statistics · CPU ticks", at),
            physical: Metric::new(mem(h.physical), "B", "sysctl · hw.memsize", at),
            active: Metric::new(mem(h.active), "B", "host_statistics64 · active_count", at),
            wired: Metric::new(mem(h.wired), "B", "host_statistics64 · wire_count", at),
            compressed: Metric::new(
                mem(h.compressed),
                "B",
                "host_statistics64 · compressor_page_count",
                at,
            ),
            swap: Metric::new(
                (h.swap_ok != 0).then_some(h.swap as f64),
                "B",
                "sysctl · vm.swapusage",
                at,
            ),
            app_memory: Metric::new(
                mem(app_memory),
                "B",
                "host_statistics64 · internal − purgeable",
                at,
            ),
            cached_files: Metric::new(
                mem(cached_files),
                "B",
                "host_statistics64 · external + purgeable",
                at,
            ),
            pressure_percent: Metric::new(
                pressure_pct,
                "%",
                "100 − sysctl kern.memorystatus_level (memória disponível segundo o kernel)",
                at,
            ),
            pressure: Metric::new(
                (config.pressure >= 0).then_some(config.pressure as f64),
                "estado",
                "DispatchSourceMemoryPressure · último evento",
                config.pressure_at,
            ),
            thermal: Metric::new(
                (config.thermal >= 0).then_some(config.thermal as f64),
                "estado",
                "ProcessInfo.thermalState",
                at,
            ),
            core_source: self.core_kinds.as_ref().map_or("", |k| k.1),
            core_load,
            history_state,
            processes,
            volumes: self.volumes.clone(),
            disks: self.disks.clone(),
            diagnostics,
            history: self.history.clone(),
            disk_read: Metric::new(
                disk_read,
                "B/s",
                "IOBlockStorageDriver · soma dos dispositivos",
                at,
            ),
            disk_write: Metric::new(
                disk_write,
                "B/s",
                "IOBlockStorageDriver · soma dos dispositivos",
                at,
            ),
            net_in: Metric::new(
                net_in,
                "B/s",
                "sysctl NET_RT_IFLIST2 · interfaces sem loopback",
                at,
            ),
            net_out: Metric::new(
                net_out,
                "B/s",
                "sysctl NET_RT_IFLIST2 · interfaces sem loopback",
                at,
            ),
            collector_ms: begin.elapsed().as_secs_f64() * 1000.,
            own_wakeups: Metric::new(
                own_wakeups,
                "despertares/s",
                "proc_pid_rusage · pkg_idle_wkups (não todos os timers)",
                at,
            ),
            process_state: if count < 0 {
                "unavailable"
            } else if count >= 8192 {
                "truncated"
            } else {
                "available"
            }
            .into(),
            volume_state: self.volume_state.clone(),
            disk_state: self.disk_state.clone(),
            current_uid: uid,
        }
    }
    /// Busy % per logical CPU from tick deltas, tagged with its core type.
    fn sample_cores(&mut self) -> Vec<CoreLoad> {
        let ticks = core_ticks();
        let count = ticks.as_ref().map_or(0, Vec::len);
        if self.core_kinds.as_ref().is_none_or(|k| k.0.len() != count) {
            self.core_kinds = Some(classify_cores(&core_kinds(count), perflevels(), count));
        }
        let kinds = &self.core_kinds.as_ref().expect("set above").0;
        let out = match (&self.core_ticks, &ticks) {
            (Some(old), Some(new)) if old.len() == new.len() => old
                .iter()
                .zip(new)
                .zip(kinds)
                .map(|((o, n), kind)| CoreLoad {
                    kind,
                    value: cpu_percent(o, n),
                })
                .collect(),
            _ => kinds
                .iter()
                .map(|kind| CoreLoad { kind, value: None })
                .collect(),
        };
        self.core_ticks = ticks;
        out
    }
    fn sample_network(&mut self) -> (Option<f64>, Option<f64>) {
        let Some((rx, tx)) = network() else {
            self.net_raw = None;
            return (None, None);
        };
        let now = Instant::now();
        let result = self.net_raw.map_or((None, None), |(t, prx, ptx)| {
            let d = now.duration_since(t).as_secs_f64();
            (rate(prx, rx, d), rate(ptx, tx, d))
        });
        self.net_raw = Some((now, rx, tx));
        result
    }
    fn refresh_storage(&mut self, at: f64) {
        if self
            .last_volumes
            .is_none_or(|t| t.elapsed().as_secs() >= 30)
        {
            let mut raw: Vec<RawVolume> = (0..256).map(|_| unsafe { std::mem::zeroed() }).collect();
            let n = unsafe { os_volumes(raw.as_mut_ptr(), 256) };
            self.volume_state = if n < 0 { "unavailable" } else { "available" }.into();
            self.volumes = raw
                .into_iter()
                .take(n.max(0) as usize)
                .map(|v| Volume {
                    id: string(&v.device),
                    mount: string(&v.mount),
                    kind: string(&v.kind),
                    total: Metric::new(Some(v.total as f64), "B", "getmntinfo · statfs", at),
                    available: Metric::new(
                        Some(v.available as f64),
                        "B",
                        "getmntinfo · f_bavail (cache do kernel)",
                        at,
                    ),
                    temperature: Metric::unsupported(
                        "Sem API pública de temperatura de volume",
                        at,
                    ),
                })
                .collect();
            self.last_volumes = Some(Instant::now());
        }
        if self
            .last_disks
            .is_none_or(|t| t.elapsed().as_secs_f64() >= 1.5)
        {
            let dt = self.last_disks.map(|t| t.elapsed().as_secs_f64());
            let mut raw: Vec<RawDisk> = (0..128).map(|_| unsafe { std::mem::zeroed() }).collect();
            let n = unsafe { os_disks(raw.as_mut_ptr(), 128) };
            self.disk_state = if n < 0 {
                "unavailable"
            } else if n == 0 {
                "unsupported"
            } else {
                "available"
            }
            .into();
            let mut previous = HashMap::new();
            self.disks = raw
                .into_iter()
                .take(n.max(0) as usize)
                .map(|r| {
                    let old = self.disk_raw.get(&r.id);
                    let read = old
                        .and_then(|p| dt.and_then(|d| rate(p.0, r.read_bytes, d)))
                        .filter(|_| r.ok != 0);
                    let write = old
                        .and_then(|p| dt.and_then(|d| rate(p.1, r.write_bytes, d)))
                        .filter(|_| r.ok != 0);
                    if r.ok != 0 {
                        previous.insert(r.id, (r.read_bytes, r.write_bytes));
                    }
                    Disk {
                        id: r.id.to_string(),
                        name: string(&r.name),
                        read: Metric::new(read, "B/s", "IOBlockStorageDriver · Statistics", at),
                        write: Metric::new(write, "B/s", "IOBlockStorageDriver · Statistics", at),
                        temperature: {
                            if !self
                                .temperatures
                                .get(&r.id)
                                .is_some_and(|(time, _)| time.elapsed().as_secs() < 30)
                            {
                                let mut kelvin = 0;
                                let status = unsafe { os_nvme_temperature(r.id, &mut kelvin) };
                                self.temperatures.insert(
                                    r.id,
                                    (Instant::now(), temperature(kelvin, status, at)),
                                );
                            }
                            self.temperatures
                                .get(&r.id)
                                .map(|(_, metric)| metric.clone())
                                .unwrap_or_else(|| temperature(0, 3, at))
                        },
                    }
                })
                .collect();
            self.temperatures.retain(|id, _| previous.contains_key(id));
            self.disk_raw = previous;
            self.last_disks = Some(Instant::now());
        }
    }
}
/// Revalidate identity immediately before signaling. Only callers with explicit user confirmation may invoke this.
pub fn signal_process(pid: i32, start: u64, path: &str, force: bool) -> Result<(), String> {
    if pid <= 1 || start == 0 || path.is_empty() {
        return Err("Identidade inválida".into());
    }
    let p = process(pid).ok_or("Processo encerrou ou está sem permissão")?;
    let reason = blocked(&p, unsafe { os_uid() }, &protected());
    if !reason.is_empty() {
        return Err(reason.into());
    }
    if p.start != start || string(&p.path) != path {
        return Err("Identidade mudou; PID reutilizado ou executável alterado".into());
    }
    let latest = process(pid).ok_or("Processo não está mais disponível")?;
    if latest.start != start || latest.uid != p.uid || string(&latest.path) != path {
        return Err("Identidade mudou durante a confirmação".into());
    }
    let err = unsafe { os_signal(pid, i32::from(force)) };
    if err == 0 {
        Ok(())
    } else {
        Err(format!("O macOS recusou o sinal (errno {err})"))
    }
}
static COLLECTOR: OnceLock<Mutex<Collector>> = OnceLock::new();
fn collector() -> &'static Mutex<Collector> {
    COLLECTOR.get_or_init(|| Mutex::new(Collector::default()))
}
fn response(f: impl FnOnce() -> Result<String, String>) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(f));
    let text = match result {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => serde_json::json!({"error":e}).to_string(),
        Err(_) => "{\"error\":\"Falha interna contida; reinicie a coleta\"}".into(),
    };
    CString::new(text)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}
/// # Safety
/// `config` is a valid NUL-terminated UTF-8 JSON pointer for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_snapshot(config: *const c_char) -> *mut c_char {
    response(|| {
        if config.is_null() {
            return Err("Configuração ausente".into());
        }
        let bytes = unsafe { CStr::from_ptr(config) }.to_bytes();
        let cfg = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        let sample = collector()
            .lock()
            .map_err(|_| "Coletor indisponível")?
            .sample(cfg);
        serde_json::to_string(&sample).map_err(|e| e.to_string())
    })
}
/// # Safety
/// `path` must be a valid NUL-terminated string. User must have confirmed this exact target and signal.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_signal(
    pid: i32,
    start: u64,
    path: *const c_char,
    force: i32,
) -> *mut c_char {
    response(|| {
        if path.is_null() {
            return Err("Executável ausente".into());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "Executável inválido")?;
        signal_process(pid, start, path, force != 0)?;
        Ok("{\"ok\":true}".into())
    })
}
/// Clears delta baselines after sleep without passing a panic across FFI.
#[unsafe(no_mangle)]
pub extern "C" fn cs_reset() {
    let _ = catch_unwind(|| {
        if let Ok(mut c) = collector().lock() {
            c.reset()
        }
    });
}
/// # Safety
/// Null or a pointer returned by a cs_* function, not freed before; no borrowed references survive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        let _ = catch_unwind(|| unsafe { drop(CString::from_raw(pointer)) });
    }
}

fn json<T: Serialize>(value: Result<T, String>) -> Result<String, String> {
    value.and_then(|v| serde_json::to_string(&v).map_err(|e| e.to_string()))
}
#[derive(Deserialize, Default)]
#[serde(default)]
struct HistoryRequest {
    op: String,
    from: i64,
    to: i64,
    bucket: i64,
    path: String,
}
/// Persistent history: `series`, `top` and `info` read through their own read-only connection;
/// `flush` writes the pending minute and `delete` closes the file and removes it.
///
/// # Safety
/// `request` is a valid NUL-terminated UTF-8 JSON pointer for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_history(request: *const c_char) -> *mut c_char {
    response(|| {
        if request.is_null() {
            return Err("Consulta ausente".into());
        }
        let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
        let r: HistoryRequest = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        let path = if r.path.is_empty() {
            history::default_path()
        } else {
            r.path
        };
        match r.op.as_str() {
            "series" => json(history::series(&path, r.from, r.to, r.bucket)),
            "top" => json(history::top(&path, r.from, r.to)),
            "info" => json(history::info(&path)),
            "flush" | "delete" => {
                let mut c = collector().lock().map_err(|_| "Coletor indisponível")?;
                if r.op == "flush" {
                    // No purge here: retention is applied by the minute writes.
                    c.recorder.flush(0);
                    return Ok("{\"ok\":true}".into());
                }
                c.recorder.set_path(&path);
                c.recorder.delete()?;
                Ok("{\"ok\":true}".into())
            }
            _ => Err("Operação desconhecida".into()),
        }
    })
}

/// Observes identity without modifying the collector or sending signals.
#[unsafe(no_mangle)]
pub extern "C" fn cs_is_same(pid: i32, start: u64) -> i32 {
    catch_unwind(|| i32::from(process(pid).is_some_and(|p| p.start == start))).unwrap_or(-1)
}

/// Separate lock from the process collector: a slow engine never delays system samples.
static CONTAINERS: OnceLock<Mutex<containers::Reader>> = OnceLock::new();
/// Lists containers from local engine sockets; `stats` != 0 adds CPU and memory per running container.
#[unsafe(no_mangle)]
pub extern "C" fn cs_containers(stats: i32) -> *mut c_char {
    response(|| {
        let report = CONTAINERS
            .get_or_init(|| Mutex::new(containers::Reader::default()))
            .lock()
            .map_err(|_| "Leitor de contêineres indisponível")?
            .read(stats != 0);
        serde_json::to_string(&report).map_err(|e| e.to_string())
    })
}
/// # Safety
/// `id` and `action` are valid NUL-terminated strings. User must have confirmed this container and action.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_container_action(
    id: *const c_char,
    action: *const c_char,
) -> *mut c_char {
    response(|| {
        if id.is_null() || action.is_null() {
            return Err("Ação de contêiner inválida".into());
        }
        let id = unsafe { CStr::from_ptr(id) }
            .to_str()
            .map_err(|_| "Identificador de contêiner inválido")?;
        let action = unsafe { CStr::from_ptr(action) }
            .to_str()
            .map_err(|_| "Ação de contêiner inválida")?;
        containers::act(id, action)?;
        Ok("{\"ok\":true}".into())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nvme_temperature_kelvin_and_failures() {
        assert!((temperature(313, 0, 1.).value.unwrap() - 39.85).abs() < 0.001);
        assert!(temperature(0, 0, 1.).value.is_none());
        assert_eq!(temperature(313, 2, 1.).state, "permission");
        assert!(temperature(313, 3, 1.).value.is_none());
        assert_eq!(temperature(0, 1, 1.).state, "unsupported");
    }
    #[test]
    fn cpu_normalized_and_idle() {
        assert_eq!(cpu_percent(&[0, 0, 0, 0], &[20, 10, 70, 0]), Some(30.));
    }
    #[test]
    fn reset_counter_is_unavailable() {
        assert_eq!(rate(100, 1, 3.), None);
    }
    #[test]
    fn no_delta_after_sleep() {
        assert_eq!(rate(1, 100, 61.), None);
    }
    #[test]
    fn hysteresis_requires_sustained_transition() {
        let mut g = Gate::default();
        assert_eq!(g.update(1, 0., 10.), 0);
        assert_eq!(g.update(1, 9., 10.), 0);
        assert_eq!(g.update(1, 10., 10.), 1);
        assert_eq!(g.update(0, 11., 10.), 1);
        assert_eq!(g.update(0, 21., 10.), 0);
    }
    #[test]
    fn history_has_fixed_capacity_and_age() {
        let mut h = VecDeque::new();
        for i in 0..500 {
            push(
                &mut h,
                Point {
                    at: i as f64,
                    ..Default::default()
                },
            );
        }
        assert_eq!(h.len(), 120);
        push(
            &mut h,
            Point {
                at: 1200.,
                ..Default::default()
            },
        );
        assert_eq!(h.len(), 1);
    }
    #[test]
    fn unsupported_sensor_has_no_fabricated_value() {
        let m = Metric::unsupported("test", 1.);
        assert_eq!(m.state, "unsupported");
        assert!(m.value.is_none());
    }
    #[test]
    fn orphan_requires_dev_runtime_without_parent() {
        let node = tags("node", "/opt/homebrew/bin/node", false);
        assert!(orphan_reason(1, None, 600., "/opt/homebrew/bin/node", &node).is_some());
        assert!(orphan_reason(1, None, 10., "/opt/homebrew/bin/node", &node).is_none());
        assert!(orphan_reason(500, None, 600., "/opt/homebrew/bin/node", &node).is_none());
        let app = tags(
            "Slack",
            "/Applications/Slack.app/Contents/MacOS/Slack",
            false,
        );
        assert!(
            orphan_reason(
                1,
                None,
                600.,
                "/Applications/Slack.app/Contents/MacOS/Slack",
                &app
            )
            .is_none()
        );
    }
    #[test]
    fn observed_parent_loss_is_orphan_evidence() {
        assert!(orphan_reason(1, Some("codex · PID 9"), 60., "/bin/x", &[]).is_some());
        assert!(orphan_reason(1, Some("codex · PID 9"), 5., "/bin/x", &[]).is_none());
    }
    #[test]
    fn hosts_and_tags_identify_dev_tools() {
        assert_eq!(
            host("2.1.3", "/Users/a/.local/share/claude/versions/2.1.3").map(|h| h.0),
            Some("Claude Code")
        );
        assert_eq!(
            host("codex", "/opt/homebrew/bin/codex").map(|h| h.1),
            Some("agent")
        );
        assert_eq!(
            host(
                "zsh",
                "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            )
            .map(|h| h.1),
            Some("terminal")
        );
        assert!(host("node", "/opt/homebrew/bin/node").is_none());
        assert_eq!(
            host("Claude", "/Applications/Claude.app/Contents/MacOS/Claude").map(|h| h.0),
            Some("Claude Desktop")
        );
        let bundled = "/Users/a/Library/Application Support/Claude/claude-code/2.1.2/ab/claude.app/Contents/MacOS/claude";
        assert_eq!(host("claude", bundled).map(|h| h.0), Some("Claude Code"));
        assert!(tags("node", "/opt/homebrew/bin/node", true).contains(&"server"));
        assert!(tags("python3.12", "/usr/bin/python3", false).contains(&"runtime"));
        assert!(tags("github-mcp-server", "/x/github-mcp-server", false).contains(&"mcp"));
        assert!(tags("postgres", "/opt/homebrew/bin/postgres", false).contains(&"database"));
        assert!(
            !tags(
                "Safari",
                "/Applications/Safari.app/Contents/MacOS/Safari",
                false
            )
            .contains(&"runtime")
        );
    }
    #[test]
    fn listening_port_and_cwd_of_own_child() {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let own = unsafe { os_self() };
        let found = ports(own);
        assert!(found.iter().any(|p| p.port == port && p.exposed == 0));
        assert_eq!(cwd(own), std::env::current_dir().unwrap().to_string_lossy());
        assert!(network().is_some());
    }
    #[test]
    fn invalid_and_self_signals_are_blocked() {
        assert!(signal_process(-1, 1, "/bin/sleep", false).is_err());
        let p = process(unsafe { os_self() }).unwrap();
        assert!(signal_process(p.pid, p.start, &string(&p.path), false).is_err());
    }
    #[test]
    fn volumes_are_safe_to_read_from_several_threads() {
        // getmntinfo() shares one buffer per process; concurrent samples crashed intermittently.
        let threads: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(|| {
                    let mut raw: Vec<RawVolume> =
                        (0..256).map(|_| unsafe { std::mem::zeroed() }).collect();
                    (0..2000)
                        .map(|_| unsafe { os_volumes(raw.as_mut_ptr(), 256) })
                        .min()
                })
            })
            .collect();
        for t in threads {
            assert!(t.join().unwrap().unwrap() > 0);
        }
    }
    #[test]
    fn termination_only_disposable_child() {
        use std::process::Command;
        let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let p = process(child.id() as i32).unwrap();
        let path = string(&p.path);
        assert!(signal_process(p.pid, p.start + 1, &path, false).is_err());
        assert!(signal_process(p.pid, p.start, "/wrong", true).is_err());
        assert!(child.try_wait().unwrap().is_none());
        assert!(signal_process(p.pid, p.start, &path, false).is_ok());
        child.wait().unwrap();
    }
    #[test]
    fn forced_termination_only_disposable_child() {
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let p = process(child.id() as i32).unwrap();
        assert!(signal_process(p.pid, p.start, &string(&p.path), true).is_ok());
        child.wait().unwrap();
    }
    #[test]
    fn live_snapshot_and_wake_reset() {
        let mut c = Collector::default();
        let a = c.sample(Config::default());
        assert!(a.physical.value.unwrap() > 0.);
        assert!(!a.processes.is_empty());
        assert!(a.cpu.value.is_none());
        c.reset();
        assert!(c.sample(Config::default()).cpu.value.is_none());
    }
    #[test]
    fn apple_silicon_cpu_time_has_correct_units() {
        use std::process::{Command, Stdio};
        let mut child = Command::new("/usr/bin/yes")
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let before = process(child.id() as i32).unwrap();
        let start = Instant::now();
        std::thread::sleep(std::time::Duration::from_millis(500));
        let after = process(child.id() as i32).unwrap();
        let cpu = (after.cpu_ns - before.cpu_ns) as f64 / start.elapsed().as_secs_f64() / 1e7;
        let result = signal_process(after.pid, after.start, &string(&after.path), false);
        child.wait().unwrap();
        assert!(result.is_ok());
        assert!(
            (5.0..=120.0).contains(&cpu),
            "discardable single-thread CPU load measured {cpu}%"
        );
    }
    #[test]
    fn core_types_need_a_complete_consistent_map() {
        let (kinds, _) = classify_cores(b"EEEEEEPPPP", (4, 6), 10);
        assert_eq!(kinds.iter().filter(|k| **k == "P").count(), 4);
        assert_eq!(kinds[0], "E");
        // Missing entries or counts that disagree with sysctl never guess a type.
        assert!(
            classify_cores(b"EEEEEEPPP\0", (4, 6), 10)
                .0
                .iter()
                .all(|k| k.is_empty())
        );
        assert!(
            classify_cores(b"EEEEEEEPPP", (4, 6), 10)
                .0
                .iter()
                .all(|k| k.is_empty())
        );
        assert!(
            classify_cores(b"", (8, 0), 8)
                .0
                .iter()
                .all(|k| k.is_empty())
        );
    }
    #[test]
    fn memory_categories_and_pressure_percent() {
        assert_eq!(memory_breakdown(10, 3, 5), (7, 8));
        assert_eq!(memory_breakdown(1, 3, 0), (0, 3));
        assert_eq!(pressure_percent(74), Some(26.));
        assert_eq!(pressure_percent(-1), None);
        assert_eq!(pressure_percent(101), None);
    }
    #[test]
    fn live_cores_have_types_and_load_on_second_sample() {
        let mut c = Collector::default();
        let first = c.sample(Config::default());
        assert_eq!(first.core_load.len(), first.cores as usize);
        assert!(first.core_load.iter().all(|c| c.value.is_none()));
        std::thread::sleep(std::time::Duration::from_millis(200));
        let second = c.sample(Config::default());
        assert!(second.core_load.iter().all(|c| c.value.is_some()));
        let (p, e) = perflevels();
        if e > 0 && !second.core_load[0].kind.is_empty() {
            let count = |k| second.core_load.iter().filter(|c| c.kind == k).count() as u32;
            assert_eq!((count("P"), count("E")), (p, e));
        }
        assert!(second.app_memory.value.unwrap() > 0.);
        assert!(second.cached_files.value.is_some());
        assert!((0. ..=100.).contains(&second.pressure_percent.value.unwrap()));
        assert_eq!(second.history_state, "off");
    }
    fn temp_db(tag: &str) -> String {
        let dir = std::env::temp_dir().join(format!(
            "corescope-test-{}-{tag}-{}",
            std::process::id(),
            now()
        ));
        dir.join("history.sqlite").to_string_lossy().into_owned()
    }
    fn proc_sample(i: i32) -> (String, String) {
        (format!("p{i}"), format!("/bin/p{i}"))
    }
    #[test]
    fn history_writes_once_per_minute_and_ranks_top_ten() {
        let path = temp_db("rollup");
        let mut r = history::Recorder::new(&path);
        let names: Vec<(String, String)> = (0..15).map(proc_sample).collect();
        let base = 1_800_000_000.; // a minute boundary
        for step in 0..6 {
            let at = base + step as f64 * 10.;
            let system = history::System {
                cpu: Some(10. + step as f64),
                memory: Some(1e9),
                thermal: Some(if step == 3 { 2 } else { 0 }),
                ..Default::default()
            };
            r.add(
                at,
                7,
                system,
                names
                    .iter()
                    .enumerate()
                    .map(|(i, (name, path))| history::Proc {
                        key: (i as i32 + 100, 1),
                        name,
                        path,
                        cwd: "/tmp/project",
                        origin: if i == 0 { "Claude Code" } else { "" },
                        cpu: Some(i as f64),
                        memory: Some(1e6 * (15 - i) as f64),
                    }),
            );
            // Nothing is written while the minute is open.
            assert!(!std::path::Path::new(&path).exists());
        }
        r.add(
            base + 60.,
            7,
            history::System::default(),
            std::iter::empty(),
        );
        assert!(r.error.is_none(), "{:?}", r.error);
        let series = history::series(&path, base as i64, base as i64 + 180, 60).unwrap();
        assert_eq!(series.points.len(), 3);
        let first = &series.points[0];
        assert_eq!(first.samples, 6);
        assert!((first.cpu.unwrap() - 12.5).abs() < 1e-9);
        assert_eq!(first.cpu_max, Some(15.));
        assert_eq!(first.thermal, Some(2));
        // The open minute and the future are gaps, never zeros.
        assert!(series.points[1].cpu.is_none() && series.points[2].samples == 0);
        let top = history::top(&path, base as i64, base as i64 + 60).unwrap();
        assert_eq!(top.minutes, 1);
        assert_eq!(top.cpu.len(), history::TOP);
        assert_eq!(top.cpu[0].name, "p14");
        assert!((top.cpu[0].cpu - 14.).abs() < 1e-9);
        assert!(top.cpu.windows(2).all(|w| w[0].cpu >= w[1].cpu));
        assert_eq!(top.memory[0].name, "p0");
        assert_eq!(top.memory[0].origin, "Claude Code");
        assert_eq!(top.memory[0].cwd, "/tmp/project");
        assert_eq!(top.memory.len(), history::TOP);
        r.delete().unwrap();
        assert!(!std::path::Path::new(&path).exists());
        assert_eq!(history::info(&path).unwrap().minutes, 0);
    }
    #[test]
    fn history_merges_repeated_partial_minute_writes() {
        let path = temp_db("repeated-minute");
        let base = 1_800_000_000.;
        let (first_name, first_path) = proc_sample(0);
        let (second_name, second_path) = proc_sample(1);
        let mut first = history::Recorder::new(&path);
        first.add(
            base,
            7,
            history::System {
                cpu: Some(10.),
                ..Default::default()
            },
            std::iter::once(history::Proc {
                key: (100, 1),
                name: &first_name,
                path: &first_path,
                cwd: "/tmp",
                origin: "",
                cpu: Some(80.),
                memory: Some(500.),
            }),
        );
        first.flush(7);
        first.disable();

        let mut second = history::Recorder::new(&path);
        second.add(
            base + 10.,
            7,
            history::System {
                cpu: Some(30.),
                ..Default::default()
            },
            std::iter::once(history::Proc {
                key: (200, 1),
                name: &second_name,
                path: &second_path,
                cwd: "/tmp",
                origin: "",
                cpu: Some(100.),
                memory: Some(1_000.),
            }),
        );
        second.add(
            base + 60.,
            7,
            history::System::default(),
            std::iter::empty(),
        );

        let series = history::series(&path, base as i64, base as i64 + 60, 60).unwrap();
        assert_eq!(series.points[0].samples, 2);
        assert_eq!(series.points[0].cpu, Some(20.));
        assert_eq!(series.points[0].cpu_max, Some(30.));
        let top = history::top(&path, base as i64, base as i64 + 60).unwrap();
        assert_eq!(top.cpu.len(), 2);
        assert_eq!(top.cpu[0].name, second_name);
        assert_eq!(top.cpu[0].cpu, 50.);
        assert_eq!(top.cpu[1].name, first_name);
        assert_eq!(top.cpu[1].cpu, 40.);
        second.delete().unwrap();
    }
    #[test]
    fn history_series_counts_valid_minutes_per_metric() {
        let path = temp_db("metric-counts");
        let mut r = history::Recorder::new(&path);
        let base = 1_800_000_000.;
        r.add(
            base,
            7,
            history::System {
                cpu: Some(100.),
                memory: Some(1.),
                net_in: Some(1.),
                ..Default::default()
            },
            std::iter::empty(),
        );
        for step in 0..30 {
            r.add(
                base + 1800. + step as f64 * 60.,
                7,
                history::System {
                    cpu: Some(0.),
                    memory: Some(0.),
                    ..Default::default()
                },
                std::iter::empty(),
            );
        }
        r.add(
            base + 3600.,
            7,
            history::System::default(),
            std::iter::empty(),
        );
        r.flush(7);

        let series = history::series(&path, base as i64, base as i64 + 3600, 1800).unwrap();
        assert_eq!(series.points[0].cpu_minutes, 1);
        assert_eq!(series.points[1].cpu_minutes, 30);
        assert_eq!(series.points[0].memory_minutes, 1);
        assert_eq!(series.points[1].memory_minutes, 30);
        assert_eq!(series.points[0].net_in_minutes, 1);
        assert_eq!(series.points[1].net_in_minutes, 0);
        r.delete().unwrap();
    }
    #[test]
    fn history_retention_purges_old_minutes() {
        let path = temp_db("retention");
        let mut r = history::Recorder::new(&path);
        let now = 1_800_000_000.;
        for at in [
            now - 3. * 86400.,
            now - 2. * 86400.,
            now - 3600.,
            now,
            now + 60.,
        ] {
            let s = history::System {
                cpu: Some(5.),
                ..Default::default()
            };
            r.add(at, 30, s, std::iter::empty());
        }
        assert_eq!(history::info(&path).unwrap().minutes, 4);
        // Shrinking retention to one day purges on the next minute write.
        r.add(
            now + 120.,
            1,
            history::System::default(),
            std::iter::empty(),
        );
        let info = history::info(&path).unwrap();
        assert_eq!(info.minutes, 3);
        assert_eq!(info.oldest, Some(now as i64 - 3600));
        assert!(info.bytes > 0);
        r.disable();
        // A read-only connection still works after the writer closed the WAL.
        assert_eq!(history::top(&path, 0, i64::MAX).unwrap().minutes, 3);
        r.delete().unwrap();
    }
    #[test]
    fn history_ffi_reads_and_rejects_unknown_ops() {
        let path = temp_db("ffi");
        let request = CString::new(format!(
            "{{\"op\":\"series\",\"from\":0,\"to\":600,\"bucket\":60,\"path\":\"{path}\"}}"
        ))
        .unwrap();
        unsafe {
            let p = cs_history(request.as_ptr());
            let v: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(p).to_bytes()).unwrap();
            assert_eq!(v["points"].as_array().unwrap().len(), 10);
            assert_eq!(v["info"]["minutes"], 0);
            cs_free(p);
            let bad = CString::new("{\"op\":\"drop\"}").unwrap();
            let p = cs_history(bad.as_ptr());
            assert!(CStr::from_ptr(p).to_str().unwrap().contains("error"));
            cs_free(p);
        }
    }
    #[test]
    fn ffi_roundtrip_and_invalid_json() {
        let config = CString::new("{}").unwrap();
        unsafe {
            let p = cs_snapshot(config.as_ptr());
            assert!(!p.is_null());
            let v: serde_json::Value =
                serde_json::from_slice(CStr::from_ptr(p).to_bytes()).unwrap();
            assert!(v.get("processes").is_some());
            cs_free(p);
            let p = cs_snapshot(std::ptr::null());
            assert!(CStr::from_ptr(p).to_str().unwrap().contains("error"));
            cs_free(p);
            cs_free(std::ptr::null_mut());
        }
    }
}
