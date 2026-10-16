//! CoreScope: bounded local telemetry and explicitly authorized process control.
mod os;
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
#[derive(Clone, Serialize)]
pub struct Point {
    pub at: f64,
    pub cpu: Option<f64>,
    pub memory: Option<f64>,
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
    pub cpu: Metric,
    pub memory: Metric,
    pub resident: Metric,
    pub threads: Metric,
    pub read: Metric,
    pub write: Metric,
    pub eligible: bool,
    pub blocked: String,
    pub candidate: Option<String>,
    pub attribution: Option<String>,
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
    pub pressure: Metric,
    pub thermal: Metric,
    pub processes: Vec<Process>,
    pub volumes: Vec<Volume>,
    pub disks: Vec<Disk>,
    pub diagnostics: Vec<Diagnostic>,
    pub history: VecDeque<Point>,
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
    volume_state: String,
    disk_state: String,
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
fn dev_name(name: &str) -> bool {
    [
        "codex", "claude", "node", "python", "cargo", "rustc", "npm", "docker", "swift",
    ]
    .iter()
    .any(|s| name.to_lowercase().contains(s))
}
fn candidate_evidence(
    parent: Option<&str>,
    age: f64,
    memory: u64,
    cpu: Option<f64>,
) -> Option<String> {
    parent.filter(|_|age>=300. && (memory>=100*1024*1024||cpu.is_some_and(|v|v>=1.))).map(|p|format!("Confiança moderada: mudança observada de pai ({p}) para launchd; idade ≥ 5 min e recursos retidos. Pode ser um serviço legítimo. Confirme a finalidade antes de agir."))
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
                if dev_name(&name) {
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
            let attribution = path
                .find(".app/")
                .map(|i| format!("Executável dentro de {}", &path[..i + 4]));
            processes.push(Process {
                id: id.clone(),
                pid: raw.pid,
                ppid: raw.ppid,
                uid: raw.uid,
                user: string(&raw.user),
                start: raw.start,
                name: string(&raw.name),
                path,
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
                candidate: if config.ignored.contains(&id) || !reason.is_empty() {
                    None
                } else {
                    candidate_evidence(
                        lost.as_deref(),
                        at - raw.start as f64 / 1e6,
                        raw.footprint,
                        pcpu,
                    )
                },
                attribution,
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
        processes.sort_by(|a, b| {
            b.cpu
                .value
                .unwrap_or(-1.)
                .total_cmp(&a.cpu.value.unwrap_or(-1.))
        });
        self.refresh_storage(at);
        push(
            &mut self.history,
            Point {
                at,
                cpu,
                memory: mem(h.active + h.wired + h.compressed),
            },
        );
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
        diagnostics.push(Diagnostic{id:"cpu",level,title:if cpu.is_none(){"CPU em aquecimento".into()}else if level>0{"CPU elevada de forma sustentada".into()}else{"CPU sem alerta sustentado".into()},detail:format!("Total normalizado em 0–100%. Janela de {:.0} s; saída 5 pontos abaixo do limite. Consumo alto não comprova a causa de lentidão.",config.sustain)});
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
            processes,
            volumes: self.volumes.clone(),
            disks: self.disks.clone(),
            diagnostics,
            history: self.history.clone(),
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
        if self.last_disks.is_none_or(|t| t.elapsed().as_secs() >= 6) {
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
/// Null or a pointer returned by cs_snapshot/cs_signal, not freed before; no borrowed references survive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        let _ = catch_unwind(|| unsafe { drop(CString::from_raw(pointer)) });
    }
}

/// Observes identity without modifying the collector or sending signals.
#[unsafe(no_mangle)]
pub extern "C" fn cs_is_same(pid: i32, start: u64) -> i32 {
    catch_unwind(|| i32::from(process(pid).is_some_and(|p| p.start == start))).unwrap_or(-1)
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
                    cpu: None,
                    memory: None,
                },
            );
        }
        assert_eq!(h.len(), 120);
        push(
            &mut h,
            Point {
                at: 1200.,
                cpu: None,
                memory: None,
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
    fn ppid_one_age_or_low_cpu_not_enough() {
        assert!(candidate_evidence(None, 99999., 999999999, None).is_none());
        assert!(candidate_evidence(Some("codex"), 100., 999999999, Some(100.)).is_none());
    }
    #[test]
    fn candidate_requires_observed_parent_and_resources() {
        assert!(candidate_evidence(Some("codex"), 600., 200 * 1024 * 1024, Some(0.)).is_some());
    }
    #[test]
    fn invalid_and_self_signals_are_blocked() {
        assert!(signal_process(-1, 1, "/bin/sleep", false).is_err());
        let p = process(unsafe { os_self() }).unwrap();
        assert!(signal_process(p.pid, p.start, &string(&p.path), false).is_err());
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
