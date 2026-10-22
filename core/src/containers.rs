//! Docker Engine API over local Unix sockets only (OrbStack, Docker Desktop, Colima).
//! No TCP, no credentials: DOCKER_HOST is honored only when it names a `unix://` socket.
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::{Path, PathBuf},
    time::Duration,
};

/// Containers listed per engine; stats run for running ones only.
const MAX_CONTAINERS: usize = 64;
/// Parallel stats requests; each is a short one-shot read.
const STATS_WORKERS: usize = 4;
const MAX_RESPONSE: usize = 8 * 1024 * 1024;
/// Error prefix the app localizes; the engine's own detail follows it untranslated.
pub const REFUSED: &str = "O motor recusou a ação";

#[derive(Clone, Serialize, PartialEq, Debug)]
pub struct Published {
    pub host: u16,
    pub container: u16,
    pub proto: String,
    /// Bound beyond loopback (all interfaces or a LAN address).
    pub exposed: bool,
}
#[derive(Serialize)]
pub struct Container {
    pub id: String,
    pub name: String,
    pub image: String,
    pub engine: &'static str,
    pub state: String,
    pub status: String,
    pub health: Option<String>,
    pub project: Option<String>,
    pub service: Option<String>,
    pub created: f64,
    pub ports: Vec<Published>,
    /// Percent of one core, like process CPU; None until two samples exist.
    pub cpu: Option<f64>,
    pub memory: Option<f64>,
    pub memory_limit: Option<f64>,
    /// A Redis password given on its command line (`--requirepass x`), for reading that local
    /// Redis from inside its container. Never serialized, logged or shown.
    #[serde(skip)]
    pub requirepass: Option<String>,
}
#[derive(Serialize)]
pub struct Engine {
    pub name: &'static str,
    pub socket: String,
    /// "ok", "unreachable" (socket present, nothing answering), "permission" or "error".
    pub state: &'static str,
}
#[derive(Serialize)]
pub struct Report {
    pub engines: Vec<Engine>,
    pub containers: Vec<Container>,
}

/// Engine label from where its socket lives (after resolving symlinks).
pub fn engine_name(path: &str) -> &'static str {
    if path.contains("/.orbstack/") {
        "OrbStack"
    } else if path.contains("/.colima/") {
        "Colima"
    } else if path.contains("/.docker/") || path.contains("/Docker.app/") {
        "Docker Desktop"
    } else if path.contains("/.rd/") {
        "Rancher Desktop"
    } else {
        "Docker"
    }
}

/// Candidate sockets in priority order, deduplicated by their resolved target.
pub fn sockets(home: &Path, docker_host: Option<&str>) -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = vec![];
    if let Some(path) = docker_host.and_then(|h| h.strip_prefix("unix://")) {
        candidates.push(PathBuf::from(path));
    }
    for rel in [
        ".orbstack/run/docker.sock",
        ".docker/run/docker.sock",
        ".colima/default/docker.sock",
        ".rd/docker.sock",
    ] {
        candidates.push(home.join(rel));
    }
    candidates.push(PathBuf::from("/var/run/docker.sock"));
    let mut seen = HashSet::new();
    candidates
        .into_iter()
        .filter_map(|p| std::fs::canonicalize(&p).ok())
        .filter(|p| seen.insert(p.clone()))
        .collect()
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Splits an HTTP/1.x response; decodes chunked bodies.
pub fn parse_response(raw: &[u8]) -> Result<Response, String> {
    let end = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("Resposta HTTP incompleta")?;
    let head = String::from_utf8_lossy(&raw[..end]);
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .and_then(|l| l.split(' ').nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or("Resposta HTTP inválida")?;
    let chunked = lines.any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    let body = &raw[end + 4..];
    let body = if chunked {
        dechunk(body)?
    } else {
        body.to_vec()
    };
    Ok(Response { status, body })
}
fn dechunk(mut data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = vec![];
    loop {
        let line = data
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or("Bloco HTTP incompleto")?;
        let size = std::str::from_utf8(&data[..line])
            .ok()
            .and_then(|s| usize::from_str_radix(s.split(';').next()?.trim(), 16).ok())
            .ok_or("Bloco HTTP inválido")?;
        data = &data[line + 2..];
        if size == 0 {
            return Ok(out);
        }
        if data.len() < size {
            return Err("Bloco HTTP incompleto".into());
        }
        out.extend_from_slice(&data[..size]);
        data = data.get(size + 2..).unwrap_or_default();
    }
}

/// Container ids from the engine are lowercase hex; anything else never reaches a request path.
pub fn valid_id(id: &str) -> bool {
    (12..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_hexdigit())
}

pub fn request(
    socket: &Path,
    method: &str,
    path: &str,
    timeout: Duration,
) -> Result<Response, std::io::Error> {
    request_json(socket, method, path, "", timeout)
}

/// `request` with a JSON body (empty: none).
pub fn request_json(
    socket: &Path,
    method: &str,
    path: &str,
    body: &str,
    timeout: Duration,
) -> Result<Response, std::io::Error> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let kind = if body.is_empty() {
        ""
    } else {
        "Content-Type: application/json\r\n"
    };
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: docker\r\nUser-Agent: CoreScope\r\n{kind}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )?;
    let mut raw = vec![];
    stream.take(MAX_RESPONSE as u64).read_to_end(&mut raw)?;
    parse_response(&raw).map_err(std::io::Error::other)
}

fn label(c: &Value, key: &str) -> Option<String> {
    c["Labels"][key]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(String::from)
}
/// IPv4 and IPv6 bindings of the same port collapse into one entry.
pub fn published(ports: &Value) -> Vec<Published> {
    let mut out: Vec<Published> = vec![];
    for p in ports.as_array().into_iter().flatten() {
        let Some(host) = p["PublicPort"].as_u64().and_then(|v| u16::try_from(v).ok()) else {
            continue;
        };
        let ip = p["IP"].as_str().unwrap_or("");
        let exposed = !matches!(ip, "127.0.0.1" | "::1" | "localhost");
        let proto = p["Type"].as_str().unwrap_or("tcp").to_string();
        if let Some(e) = out.iter_mut().find(|e| e.host == host && e.proto == proto) {
            e.exposed |= exposed;
            continue;
        }
        out.push(Published {
            host,
            container: p["PrivatePort"].as_u64().unwrap_or(0) as u16,
            proto,
            exposed,
        });
    }
    out.sort_by_key(|p| (p.host, p.proto.clone()));
    out
}
pub fn parse_list(body: &[u8], engine: &'static str) -> Result<Vec<Container>, String> {
    let list: Value = serde_json::from_slice(body).map_err(|e| e.to_string())?;
    let items = list.as_array().ok_or("Lista de contêineres inválida")?;
    Ok(items
        .iter()
        .filter_map(|c| {
            let id = c["Id"].as_str().filter(|id| valid_id(id))?.to_string();
            let name = c["Names"][0]
                .as_str()
                .map(|n| n.trim_start_matches('/').to_string())
                .unwrap_or_else(|| id[..12].to_string());
            let image = c["Image"].as_str().unwrap_or("");
            let image = match image.strip_prefix("sha256:") {
                Some(hash) => hash.chars().take(12).collect(),
                None => image.to_string(),
            };
            let health = c["Health"]["Status"]
                .as_str()
                .filter(|h| !h.is_empty() && *h != "none")
                .map(String::from);
            Some(Container {
                name,
                image,
                engine,
                state: c["State"].as_str().unwrap_or("unknown").to_string(),
                status: c["Status"].as_str().unwrap_or("").to_string(),
                health,
                project: label(c, "com.docker.compose.project"),
                service: label(c, "com.docker.compose.service"),
                created: c["Created"].as_f64().unwrap_or(0.),
                ports: published(&c["Ports"]),
                cpu: None,
                memory: None,
                memory_limit: None,
                requirepass: c["Command"].as_str().and_then(requirepass),
                id,
            })
        })
        .collect())
}

/// `--requirepass <x>` (or `--requirepass=<x>`) in a container's command line.
pub fn requirepass(command: &str) -> Option<String> {
    let mut words = command.split_whitespace();
    while let Some(w) = words.next() {
        if w == "--requirepass" {
            return words
                .next()
                .map(|p| p.trim_matches(['"', '\'']).to_string());
        }
        if let Some(p) = w.strip_prefix("--requirepass=") {
            return Some(p.trim_matches(['"', '\'']).to_string());
        }
    }
    None
}

/// Keeps at most MAX_CONTAINERS per engine, running ones first so stopped
/// containers can never push a running service out of the list.
pub fn cap(mut list: Vec<Container>) -> Vec<Container> {
    // Stable: the engine's own order (newest first) holds within each group.
    list.sort_by_key(|c| c.state != "running");
    list.truncate(MAX_CONTAINERS);
    list
}

/// Raw counters from one `stats?one-shot=true` read.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stats {
    pub total: u64,
    pub system: u64,
    pub cpus: u64,
    pub memory: Option<f64>,
    pub limit: Option<f64>,
}
pub fn parse_stats(body: &[u8]) -> Option<Stats> {
    let v: Value = serde_json::from_slice(body).ok()?;
    let cpu = &v["cpu_stats"];
    let usage = v["memory_stats"]["usage"].as_f64();
    // Same as `docker stats`: page cache that can be reclaimed is not counted.
    let cache = ["inactive_file", "total_inactive_file"]
        .iter()
        .find_map(|k| v["memory_stats"]["stats"][k].as_f64())
        .unwrap_or(0.);
    Some(Stats {
        total: cpu["cpu_usage"]["total_usage"].as_u64()?,
        system: cpu["system_cpu_usage"].as_u64().unwrap_or(0),
        cpus: cpu["online_cpus"]
            .as_u64()
            .filter(|n| *n > 0)
            .or_else(|| {
                cpu["cpu_usage"]["percpu_usage"]
                    .as_array()
                    .map(|a| a.len() as u64)
            })
            .unwrap_or(1),
        memory: usage.map(|u| (u - cache).max(0.)),
        limit: v["memory_stats"]["limit"].as_f64().filter(|l| *l > 0.),
    })
}
/// Percent of one core between two reads: container time over host time, times online CPUs.
pub fn cpu_percent(old: &Stats, new: &Stats) -> Option<f64> {
    let used = new.total.checked_sub(old.total)?;
    let system = new.system.checked_sub(old.system)?;
    (system > 0).then(|| (used as f64 / system as f64 * new.cpus as f64 * 100.).max(0.))
}

#[derive(Default)]
pub struct Reader {
    previous: HashMap<String, Stats>,
}
impl Reader {
    /// Lists every reachable engine; `with_stats` adds one stats read per running container.
    pub fn read(&mut self, with_stats: bool) -> Report {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        let host = std::env::var("DOCKER_HOST").ok();
        let mut engines = vec![];
        let mut containers = vec![];
        for socket in sockets(&home, host.as_deref()) {
            let text = socket.to_string_lossy().to_string();
            let name = engine_name(&text);
            let result = request(
                &socket,
                "GET",
                "/containers/json?all=1",
                Duration::from_secs(3),
            );
            let state = match result {
                Ok(r) if r.status == 200 => match parse_list(&r.body, name) {
                    Ok(list) => {
                        let list = cap(list);
                        containers.extend(list.into_iter().map(|c| (socket.clone(), c)));
                        "ok"
                    }
                    Err(_) => "error",
                },
                Ok(_) => "error",
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => "permission",
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound
                    ) =>
                {
                    "unreachable"
                }
                Err(_) => "error",
            };
            engines.push(Engine {
                name,
                socket: text,
                state,
            });
        }
        if with_stats {
            self.sample(&mut containers);
        } else {
            self.previous.clear();
        }
        let mut containers: Vec<Container> = containers.into_iter().map(|(_, c)| c).collect();
        // Running first, then by compose project and name: stable while numbers change.
        containers.sort_by(|a, b| {
            (a.state != "running", &a.project, &a.name).cmp(&(
                b.state != "running",
                &b.project,
                &b.name,
            ))
        });
        Report {
            engines,
            containers,
        }
    }
    fn sample(&mut self, containers: &mut [(PathBuf, Container)]) {
        let running: Vec<(usize, PathBuf, String)> = containers
            .iter()
            .enumerate()
            .filter(|(_, (_, c))| c.state == "running")
            .map(|(i, (s, c))| (i, s.clone(), c.id.clone()))
            .collect();
        let chunk = running.len().div_ceil(STATS_WORKERS).max(1);
        let results: Vec<(usize, String, Stats)> = std::thread::scope(|scope| {
            let handles: Vec<_> = running
                .chunks(chunk)
                .map(|part| {
                    scope.spawn(move || {
                        part.iter()
                            .filter_map(|(i, socket, id)| {
                                let path =
                                    format!("/containers/{id}/stats?stream=false&one-shot=true");
                                let r =
                                    request(socket, "GET", &path, Duration::from_secs(3)).ok()?;
                                (r.status == 200)
                                    .then(|| parse_stats(&r.body))
                                    .flatten()
                                    .map(|s| (*i, id.clone(), s))
                            })
                            .collect::<Vec<_>>()
                    })
                })
                .collect();
            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap_or_default())
                .collect()
        });
        let mut next = HashMap::new();
        for (index, id, stats) in results {
            let c = &mut containers[index].1;
            c.cpu = self
                .previous
                .get(&id)
                .and_then(|old| cpu_percent(old, &stats));
            c.memory = stats.memory;
            c.memory_limit = stats.limit;
            next.insert(id, stats);
        }
        self.previous = next;
    }
}

/// One container's memory, for the VM reading.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct ContainerMemory {
    pub name: String,
    pub used: f64,
    /// Its own `mem_limit`; None when it may use the whole VM.
    pub limit: Option<f64>,
}
/// A container that ended killed (exit 137) or hit out-of-memory recently.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Killed {
    pub name: String,
    pub at: f64,
    /// The engine reported an out-of-memory event (not only exit 137, which a plain SIGKILL gives too).
    pub oom: bool,
}
/// The memory of a container engine's Linux VM (OrbStack, Docker Desktop, Colima). It is capped
/// apart from the Mac's: containers run out of it, and get killed, while the Mac has plenty.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct VmMemory {
    pub engine: &'static str,
    /// What the VM has (`/info` MemTotal).
    pub total: f64,
    /// MemAvailable read inside the VM; None when no running container could be asked.
    pub available: Option<f64>,
    /// What running containers use, without reclaimable page cache.
    pub containers_used: f64,
    /// Biggest users first (up to 5).
    pub top: Vec<ContainerMemory>,
    /// At 90% or more of their own limit: the next spike gets them killed.
    pub near_limit: Vec<ContainerMemory>,
    /// Killed in the last 30 minutes.
    pub killed: Vec<Killed>,
}
impl VmMemory {
    /// Free share of the VM, percent: MemAvailable when read, else what containers leave.
    pub fn free_percent(&self) -> f64 {
        let free = self
            .available
            .unwrap_or(self.total - self.containers_used)
            .max(0.);
        (free / self.total * 100.).clamp(0., 100.)
    }
}

/// `MemTotal` and `MemAvailable` of a /proc/meminfo, in bytes.
pub fn parse_meminfo(text: &str) -> Option<(f64, f64)> {
    let field = |name: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(name))
            .and_then(|rest| rest.split_whitespace().next())
            .and_then(|kb| kb.parse::<f64>().ok())
            .map(|kb| kb * 1024.)
    };
    Some((field("MemTotal:")?, field("MemAvailable:")?))
}

/// Containers killed (exit 137) or out of memory, from an `/events` body (one JSON per line).
pub fn parse_kills(body: &[u8]) -> Vec<Killed> {
    let mut out: Vec<Killed> = vec![];
    for v in body
        .split(|b| *b == b'\n')
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
    {
        let attrs = &v["Actor"]["Attributes"];
        let Some(name) = attrs["name"].as_str() else {
            continue;
        };
        let oom = v["Action"] == "oom";
        if !oom && attrs["exitCode"].as_str() != Some("137") {
            continue;
        }
        let at = v["time"].as_f64().unwrap_or(0.);
        match out.iter_mut().find(|k| k.name == name) {
            Some(k) => {
                k.oom |= oom;
                k.at = k.at.max(at);
            }
            None => out.push(Killed {
                name: name.into(),
                at,
                oom,
            }),
        }
    }
    out
}

/// /proc/meminfo of the VM, read through a running container (a container sees the VM's).
/// Tries a few; images without `cat` (distroless, scratch) just fail.
fn vm_meminfo(socket: &Path, running: &[&Container]) -> Option<(f64, f64)> {
    let create =
        r#"{"AttachStdout":true,"AttachStderr":false,"Tty":true,"Cmd":["cat","/proc/meminfo"]}"#;
    for c in running.iter().take(3) {
        let Ok(r) = request_json(
            socket,
            "POST",
            &format!("/containers/{}/exec", c.id),
            create,
            Duration::from_secs(2),
        ) else {
            continue;
        };
        let Some(exec) = serde_json::from_slice::<Value>(&r.body)
            .ok()
            .and_then(|v| v["Id"].as_str().filter(|id| valid_id(id)).map(String::from))
        else {
            continue;
        };
        let Ok(out) = request_json(
            socket,
            "POST",
            &format!("/exec/{exec}/start"),
            r#"{"Detach":false,"Tty":true}"#,
            Duration::from_secs(2),
        ) else {
            continue;
        };
        if let Some(found) = parse_meminfo(&String::from_utf8_lossy(&out.body)) {
            return Some(found);
        }
    }
    None
}

/// Every reachable engine's VM memory, with who uses it and who got killed lately. A few short
/// requests per engine (list, stats, one exec, events): for the capacity gate and on demand.
pub fn vm_memory() -> Vec<VmMemory> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let host = std::env::var("DOCKER_HOST").ok();
    let report = Reader::default().read(true);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut out = vec![];
    for socket in sockets(&home, host.as_deref()) {
        let engine = engine_name(&socket.to_string_lossy());
        let Some(total) = request(&socket, "GET", "/info", Duration::from_secs(2))
            .ok()
            .filter(|r| r.status == 200)
            .and_then(|r| serde_json::from_slice::<Value>(&r.body).ok())
            .and_then(|v| v["MemTotal"].as_f64())
            .filter(|t| *t > 0.)
        else {
            continue;
        };
        let running: Vec<&Container> = report
            .containers
            .iter()
            .filter(|c| c.engine == engine && c.state == "running")
            .collect();
        let mut used: Vec<ContainerMemory> = running
            .iter()
            .filter_map(|c| {
                Some(ContainerMemory {
                    name: c.name.clone(),
                    used: c.memory?,
                    // A limit at (or near) the VM's own is no limit.
                    limit: c.memory_limit.filter(|l| *l < total * 0.95),
                })
            })
            .collect();
        used.sort_by(|a, b| b.used.total_cmp(&a.used));
        let near_limit = used
            .iter()
            .filter(|c| c.limit.is_some_and(|l| c.used >= l * 0.9))
            .cloned()
            .collect();
        let filters = r#"{"type":["container"],"event":["die","oom"]}"#;
        let path = format!(
            "/events?since={}&until={now}&filters={}",
            now.saturating_sub(1800),
            percent_encode(filters)
        );
        let killed = request(&socket, "GET", &path, Duration::from_secs(2))
            .ok()
            .filter(|r| r.status == 200)
            .map(|r| parse_kills(&r.body))
            .unwrap_or_default();
        out.push(VmMemory {
            engine,
            total,
            available: vm_meminfo(&socket, &running).map(|(_, a)| a),
            containers_used: used.iter().map(|c| c.used).sum(),
            top: used.iter().take(5).cloned().collect(),
            near_limit,
            killed,
        });
    }
    out
}

fn percent_encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// A named volume with what `/system/df` reports about it.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct VolumeInfo {
    pub name: String,
    pub engine: &'static str,
    /// Bytes on disk, when the engine measured it.
    pub size: Option<u64>,
    /// Containers using it (stopped ones included); 0 means unused, -1 unknown.
    pub containers: i64,
    pub project: Option<String>,
    /// RFC 3339 creation time from the engine.
    pub created: Option<String>,
    pub driver: Option<String>,
    pub labels: BTreeMap<String, String>,
    /// Made by `docker run` or a Dockerfile `VOLUME` without a name (64-hex name).
    pub anonymous: bool,
    /// Names of the containers (running or stopped) that mount it.
    pub used_by: Vec<String>,
}
/// Slower facts read on demand (a page asks every ~30 s, not every 5 s).
#[derive(Debug, Default, Serialize)]
pub struct Details {
    pub volumes: Vec<VolumeInfo>,
    /// Container id → restart policy name (`no`, `always`, `unless-stopped`, `on-failure`).
    pub restart: HashMap<String, String>,
    /// Image reference (`mysql:8.4`, or the short id) → creation time (seconds since 1970).
    pub images: HashMap<String, f64>,
}
pub fn parse_volumes(body: &Value, engine: &'static str) -> Vec<VolumeInfo> {
    body["Volumes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|v| {
            let name = v["Name"].as_str()?.to_string();
            let labels: BTreeMap<String, String> = v["Labels"]
                .as_object()
                .into_iter()
                .flatten()
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                .collect();
            Some(VolumeInfo {
                engine,
                size: v["UsageData"]["Size"]
                    .as_i64()
                    .filter(|s| *s >= 0)
                    .map(|s| s as u64),
                containers: v["UsageData"]["RefCount"].as_i64().unwrap_or(-1),
                project: labels.get("com.docker.compose.project").cloned(),
                created: v["CreatedAt"].as_str().map(String::from),
                driver: v["Driver"].as_str().map(String::from),
                anonymous: labels.contains_key("com.docker.volume.anonymous")
                    || (name.len() == 64 && name.bytes().all(|b| b.is_ascii_hexdigit())),
                labels,
                used_by: vec![],
                name,
            })
        })
        .collect()
}
/// Container name → volume names it mounts, from a `/containers/json` list.
pub fn volume_users(list: &Value) -> HashMap<String, Vec<String>> {
    let mut out: HashMap<String, Vec<String>> = HashMap::new();
    for c in list.as_array().into_iter().flatten() {
        let name = c["Names"][0]
            .as_str()
            .map(|n| n.trim_start_matches('/').to_string())
            .unwrap_or_default();
        for m in c["Mounts"].as_array().into_iter().flatten() {
            if m["Type"].as_str() == Some("volume")
                && let Some(volume) = m["Name"].as_str()
            {
                let users = out.entry(volume.to_string()).or_default();
                if !users.contains(&name) {
                    users.push(name.clone());
                }
            }
        }
    }
    out
}
/// Reads volumes, image dates and (for containers not seen before) restart policies. Inspect
/// carries the container's environment, so only the policy name is taken from it.
pub fn details(known: &mut HashMap<String, String>) -> Details {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let host = std::env::var("DOCKER_HOST").ok();
    let mut out = Details::default();
    for socket in sockets(&home, host.as_deref()) {
        let engine = engine_name(&socket.to_string_lossy());
        let first_volume = out.volumes.len();
        if let Ok(r) = request(
            &socket,
            "GET",
            "/system/df?type=volume",
            Duration::from_secs(20),
        ) && let Ok(body) = serde_json::from_slice::<Value>(&r.body)
        {
            out.volumes.extend(parse_volumes(&body, engine));
        }
        if let Ok(r) = request(&socket, "GET", "/images/json", Duration::from_secs(5)) {
            for image in serde_json::from_slice::<Value>(&r.body)
                .unwrap_or_default()
                .as_array()
                .into_iter()
                .flatten()
            {
                let created = image["Created"].as_f64().unwrap_or(0.);
                for tag in image["RepoTags"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    out.images.insert(tag.to_string(), created);
                }
                if let Some(id) = image["Id"].as_str().and_then(|i| i.strip_prefix("sha256:")) {
                    out.images.insert(id.chars().take(12).collect(), created);
                }
            }
        }
        let Ok(list) = request(
            &socket,
            "GET",
            "/containers/json?all=1",
            Duration::from_secs(3),
        ) else {
            continue;
        };
        let list = serde_json::from_slice::<Value>(&list.body).unwrap_or_default();
        let users = volume_users(&list);
        for v in &mut out.volumes[first_volume..] {
            v.used_by = users.get(&v.name).cloned().unwrap_or_default();
        }
        for c in list.as_array().into_iter().flatten() {
            let Some(id) = c["Id"].as_str().filter(|i| valid_id(i)) else {
                continue;
            };
            if !known.contains_key(id) {
                let path = format!("/containers/{id}/json");
                let policy = request(&socket, "GET", &path, Duration::from_secs(3))
                    .ok()
                    .and_then(|r| serde_json::from_slice::<Value>(&r.body).ok())
                    .and_then(|v| {
                        v["HostConfig"]["RestartPolicy"]["Name"]
                            .as_str()
                            .map(String::from)
                    })
                    .map(|n| if n.is_empty() { "no".into() } else { n });
                if let Some(policy) = policy {
                    known.insert(id.to_string(), policy);
                }
            }
            if let Some(p) = known.get(id) {
                out.restart.insert(id.to_string(), p.clone());
            }
        }
    }
    out.volumes
        .sort_by_key(|v| std::cmp::Reverse(v.size.unwrap_or(0)));
    out
}

/// List filtered by id prefix; `id` is hex-validated, so it needs no further escaping.
pub fn lookup_path(id: &str) -> String {
    format!("/containers/json?all=1&filters=%7B%22id%22%3A%5B%22{id}%22%5D%7D")
}
/// Start, stop or restart after the user asked for this exact container.
pub fn act(id: &str, action: &str) -> Result<(), String> {
    if !valid_id(id) {
        return Err("Identificador de contêiner inválido".into());
    }
    if !matches!(action, "start" | "stop" | "restart") {
        return Err("Ação de contêiner inválida".into());
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let host = std::env::var("DOCKER_HOST").ok();
    // Find the owner through the filtered list, never `/containers/{id}/json`: inspect carries
    // Config.Env, which may hold secrets. Exactly one container across all engines must match.
    let mut matches: Vec<(PathBuf, String)> = vec![];
    for socket in sockets(&home, host.as_deref()) {
        let Ok(found) = request(&socket, "GET", &lookup_path(id), Duration::from_secs(3)) else {
            continue;
        };
        if found.status != 200 {
            continue;
        }
        let ids: Vec<String> = serde_json::from_slice::<Value>(&found.body)
            .ok()
            .and_then(|v| {
                v.as_array().map(|a| {
                    a.iter()
                        .filter_map(|c| c["Id"].as_str())
                        .filter(|full| valid_id(full) && full.starts_with(id))
                        .map(String::from)
                        .collect()
                })
            })
            .unwrap_or_default();
        matches.extend(ids.into_iter().map(|full| (socket.clone(), full)));
    }
    let (socket, id) = match matches.as_slice() {
        [] => return Err("Contêiner não encontrado".into()),
        [one] => one.clone(),
        _ => return Err("Identificador de contêiner ambíguo".into()),
    };
    // The engine waits up to t seconds for a clean exit before SIGKILL.
    let path = format!("/containers/{id}/{action}?t=10");
    let r = request(&socket, "POST", &path, Duration::from_secs(40))
        .map_err(|_| "O motor de contêineres não respondeu")?;
    match r.status {
        204 | 304 => Ok(()),
        404 => Err("Contêiner não encontrado".into()),
        status => {
            let message = serde_json::from_slice::<Value>(&r.body)
                .ok()
                .and_then(|v| {
                    v["message"]
                        .as_str()
                        .map(|m| m.chars().take(160).collect::<String>())
                })
                .unwrap_or_default();
            Err(format!("{REFUSED} (HTTP {status}) {message}")
                .trim_end()
                .into())
        }
    }
}

/// Why a volume may not be removed, decided from fresh engine data right before the request.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum VolumeRefusal {
    Invalid,
    NotFound,
    /// Present in more than one engine; the caller must name one.
    Ambiguous {
        engines: Vec<String>,
    },
    /// Mounted by these containers (running or stopped); the engine is never asked to force.
    InUse {
        containers: Vec<String>,
    },
    /// The engine did not say whether anything uses it.
    UsageUnknown,
    NoAnswer,
    Refused {
        status: u16,
        message: String,
    },
}
impl VolumeRefusal {
    /// Portuguese, like the other core errors (the app translates by `kind`).
    pub fn pt(&self) -> String {
        match self {
            Self::Invalid => "Nome de volume inválido".into(),
            Self::NotFound => "Volume não encontrado".into(),
            Self::Ambiguous { engines } => {
                format!("Volume existe em mais de um motor: {}", engines.join(", "))
            }
            Self::InUse { containers } => format!("Em uso por {}", containers.join(", ")),
            Self::UsageUnknown => "O motor não informou se o volume está em uso".into(),
            Self::NoAnswer => "O motor de contêineres não respondeu".into(),
            Self::Refused { status, message } => format!("{REFUSED} (HTTP {status}) {message}")
                .trim_end()
                .into(),
        }
    }
    /// English for agents (MCP).
    pub fn en(&self) -> String {
        match self {
            Self::Invalid => "invalid volume name".into(),
            Self::NotFound => "no such volume; list_volumes shows the names".into(),
            Self::Ambiguous { engines } => format!(
                "the volume exists in more than one engine ({}); pass engine",
                engines.join(", ")
            ),
            Self::InUse { containers } => format!(
                "in use by {} (running or stopped); it is never removed while a container references it",
                containers.join(", ")
            ),
            Self::UsageUnknown => "the engine did not report whether the volume is in use".into(),
            Self::NoAnswer => "the container engine did not answer".into(),
            Self::Refused { status, message } => {
                format!("the engine refused (HTTP {status}) {message}")
                    .trim_end()
                    .into()
            }
        }
    }
}

/// Volume names the engine accepts (`[a-zA-Z0-9][a-zA-Z0-9_.-]*`); nothing else reaches a
/// request path, so they need no escaping.
pub fn valid_volume_name(name: &str) -> bool {
    let b = name.as_bytes();
    (1..=255).contains(&b.len())
        && b[0].is_ascii_alphanumeric()
        && b.iter()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'-'))
}
/// Containers (all states) that mount a volume, through the list filter, never inspect.
pub fn volume_users_path(name: &str) -> String {
    format!("/containers/json?all=1&filters=%7B%22volume%22%3A%5B%22{name}%22%5D%7D")
}
/// The removal rule shared by the app and MCP: only a volume no container references.
pub fn removal_refusal(ref_count: i64, users: &[String]) -> Option<VolumeRefusal> {
    if !users.is_empty() {
        Some(VolumeRefusal::InUse {
            containers: users.to_vec(),
        })
    } else if ref_count > 0 {
        Some(VolumeRefusal::InUse { containers: vec![] })
    } else if ref_count < 0 {
        Some(VolumeRefusal::UsageUnknown)
    } else {
        None
    }
}
/// "MySQL", "PostgreSQL" or "Redis" when the name, the compose volume key or the images of the
/// containers using the volume say so (the app's `volumeDatabaseKind` follows the same rule).
pub fn database_kind(
    name: &str,
    labels: &BTreeMap<String, String>,
    images: &[String],
) -> Option<&'static str> {
    let mut text = format!(
        "{name} {}",
        labels
            .get("com.docker.compose.volume")
            .map(String::as_str)
            .unwrap_or("")
    );
    for image in images {
        text.push(' ');
        text.push_str(image);
    }
    let text = text.to_lowercase();
    if text.contains("mysql") || text.contains("mariadb") {
        Some("MySQL")
    } else if text.contains("postgres") || text.contains("pgdata") {
        Some("PostgreSQL")
    } else if text.contains("redis") || text.contains("valkey") {
        Some("Redis")
    } else {
        None
    }
}
/// Every volume of the local engines with what uses it (the same read as the Containers page).
pub fn volumes() -> Vec<VolumeInfo> {
    details(&mut HashMap::new()).volumes
}
/// Removes one volume after the user (or an agent with the user's confirmation) asked for this
/// exact name. Re-checks right before: it must exist in one engine (or the one named) and no
/// container may mount it. `DELETE /volumes/{name}` without `force`, so the engine refuses too.
pub fn remove_volume(name: &str, engine: Option<&str>) -> Result<&'static str, VolumeRefusal> {
    if !valid_volume_name(name) {
        return Err(VolumeRefusal::Invalid);
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let host = std::env::var("DOCKER_HOST").ok();
    let path = format!("/volumes/{name}");
    let mut found: Vec<(PathBuf, &'static str)> = vec![];
    for socket in sockets(&home, host.as_deref()) {
        let label = engine_name(&socket.to_string_lossy());
        if engine.is_some_and(|e| !e.eq_ignore_ascii_case(label)) {
            continue;
        }
        if let Ok(r) = request(&socket, "GET", &path, Duration::from_secs(3))
            && r.status == 200
        {
            found.push((socket, label));
        }
    }
    let (socket, label) = match found.as_slice() {
        [] => return Err(VolumeRefusal::NotFound),
        [one] => one.clone(),
        many => {
            return Err(VolumeRefusal::Ambiguous {
                engines: many.iter().map(|(_, l)| l.to_string()).collect(),
            });
        }
    };
    let users = request(
        &socket,
        "GET",
        &volume_users_path(name),
        Duration::from_secs(3),
    )
    .ok()
    .filter(|r| r.status == 200)
    .and_then(|r| serde_json::from_slice::<Value>(&r.body).ok())
    .ok_or(VolumeRefusal::NoAnswer)?;
    let users: Vec<String> = volume_users(&users).remove(name).unwrap_or_else(|| {
        // The filter matched containers whose mount list was cut: still in use.
        users
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|c| c["Names"][0].as_str())
            .map(|n| n.trim_start_matches('/').to_string())
            .collect()
    });
    if let Some(refusal) = removal_refusal(0, &users) {
        return Err(refusal);
    }
    let r = request(&socket, "DELETE", &path, Duration::from_secs(60))
        .map_err(|_| VolumeRefusal::NoAnswer)?;
    match r.status {
        204 => Ok(label),
        404 => Err(VolumeRefusal::NotFound),
        status => {
            let message = serde_json::from_slice::<Value>(&r.body)
                .ok()
                .and_then(|v| {
                    v["message"]
                        .as_str()
                        .map(|m| m.chars().take(160).collect::<String>())
                })
                .unwrap_or_default();
            Err(VolumeRefusal::Refused { status, message })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn redis_password_from_the_command_line() {
        assert_eq!(
            requirepass("docker-entrypoint.sh redis-server --requirepass s3cret").as_deref(),
            Some("s3cret")
        );
        assert_eq!(
            requirepass("redis-server --requirepass=abc").as_deref(),
            Some("abc")
        );
        assert_eq!(requirepass("redis-server --appendonly yes"), None);
    }

    #[test]
    fn volumes_from_system_df() {
        let body = serde_json::json!({"Volumes": [
            {"Name": "shop_db", "UsageData": {"Size": 2048, "RefCount": 1}, "Labels": {"com.docker.compose.project": "shop"},
             "CreatedAt": "2026-10-01T12:36:01-03:00", "Driver": "local"},
            {"Name": "orphan", "UsageData": {"Size": -1, "RefCount": 0}, "Labels": null},
            {"Name": "32a362dbf144daff3a909400cbdf09fba92b6f86ad4038252e201b676f0df432",
             "UsageData": {"Size": 10, "RefCount": 0}, "Labels": {"com.docker.volume.anonymous": ""}}
        ]});
        let v = parse_volumes(&body, "OrbStack");
        assert_eq!(v[0].project.as_deref(), Some("shop"));
        assert_eq!(v[0].created.as_deref(), Some("2026-10-01T12:36:01-03:00"));
        assert!(!v[0].anonymous && v[2].anonymous);
        assert_eq!((v[1].size, v[1].containers), (None, 0));
        assert!(v[1].labels.is_empty());
    }
    #[test]
    fn volume_users_from_mounts() {
        let list = serde_json::json!([
            {"Names": ["/db"], "Mounts": [{"Type": "volume", "Name": "mysql_data"}, {"Type": "bind"}]},
            {"Names": ["/db-old"], "Mounts": [{"Type": "volume", "Name": "mysql_data"}]},
            {"Names": ["/web"], "Mounts": []}
        ]);
        let users = volume_users(&list);
        assert_eq!(users["mysql_data"], vec!["db", "db-old"]);
        assert_eq!(users.len(), 1);
    }
    #[test]
    fn volume_removal_rules() {
        assert!(valid_volume_name("lei45-mysql-279900a8"));
        assert!(valid_volume_name(&"a".repeat(64)));
        assert!(!valid_volume_name(""));
        assert!(!valid_volume_name("../containers/x"));
        assert!(!valid_volume_name("a b"));
        assert!(!valid_volume_name("_x"));
        assert!(!valid_volume_name("x?force=1"));
        assert_eq!(removal_refusal(0, &[]), None);
        assert_eq!(
            removal_refusal(0, &["db".into()]),
            Some(VolumeRefusal::InUse {
                containers: vec!["db".into()]
            })
        );
        assert!(matches!(
            removal_refusal(2, &[]),
            Some(VolumeRefusal::InUse { .. })
        ));
        assert_eq!(removal_refusal(-1, &[]), Some(VolumeRefusal::UsageUnknown));
        assert!(remove_volume("../x", None) == Err(VolumeRefusal::Invalid));
        let none = BTreeMap::new();
        assert_eq!(
            database_kind("lei45-mysql-279900a8", &none, &[]),
            Some("MySQL")
        );
        assert_eq!(
            database_kind("x", &none, &["library/redis:8.6.2".into()]),
            Some("Redis")
        );
        assert_eq!(database_kind("typesense-data", &none, &[]), None);
        assert!(volume_users_path("v1").ends_with("filters=%7B%22volume%22%3A%5B%22v1%22%5D%7D"));
        assert!(
            VolumeRefusal::InUse {
                containers: vec!["db".into()]
            }
            .en()
            .contains("never removed")
        );
    }
    #[test]
    fn http_plain_and_chunked() {
        let r = parse_response(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n[1]")
            .unwrap();
        assert_eq!((r.status, r.body.as_slice()), (200, b"[1]".as_slice()));
        let r = parse_response(
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\n[1,\r\n2\r\n2]\r\n0\r\n\r\n",
        )
        .unwrap();
        assert_eq!(r.body, b"[1,2]");
        assert_eq!(
            parse_response(b"HTTP/1.1 204 No Content\r\n\r\n")
                .unwrap()
                .status,
            204
        );
        assert!(parse_response(b"HTTP/1.1 200 OK\r\n").is_err());
        assert!(
            parse_response(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nff\r\nab")
                .is_err()
        );
    }
    #[test]
    fn ids_are_validated() {
        assert!(valid_id("bebc2aa52608"));
        assert!(valid_id(&"a".repeat(64)));
        assert!(!valid_id("bebc2aa5260"));
        assert!(!valid_id("../../info?x"));
        assert!(!valid_id("bebc2aa52608/stop"));
    }
    #[test]
    fn engines_from_socket_paths() {
        assert_eq!(
            engine_name("/Users/a/.orbstack/run/docker.sock"),
            "OrbStack"
        );
        assert_eq!(
            engine_name("/Users/a/.docker/run/docker.sock"),
            "Docker Desktop"
        );
        assert_eq!(
            engine_name("/Users/a/.colima/default/docker.sock"),
            "Colima"
        );
        assert_eq!(engine_name("/var/run/docker.sock"), "Docker");
    }
    #[test]
    fn docker_host_only_unix() {
        let dir = std::env::temp_dir().join(format!("cs-sock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("d.sock");
        std::fs::write(&sock, b"").unwrap();
        let unix = format!("unix://{}", sock.display());
        let found = sockets(&dir, Some(&unix));
        assert_eq!(found.first(), std::fs::canonicalize(&sock).ok().as_ref());
        assert!(
            !sockets(&dir, Some("tcp://10.0.0.1:2375"))
                .iter()
                .any(|p| p.starts_with(&dir))
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
    #[test]
    fn list_labels_ports_and_images() {
        let body = br#"[{"Id":"bebc2aa526085fc99f560cde1960b17441954a258e8e6ebfd94ce4c99335bc41",
          "Names":["/web-1"],"Image":"nginx:alpine","State":"running","Status":"Up 2 minutes",
          "Created":1790000000,"Health":{"Status":"healthy"},
          "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"},
          "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8088,"Type":"tcp"},
                   {"IP":"::","PrivatePort":80,"PublicPort":8088,"Type":"tcp"},
                   {"IP":"127.0.0.1","PrivatePort":443,"PublicPort":8443,"Type":"tcp"},
                   {"PrivatePort":9000,"Type":"tcp"}]},
          {"Id":"5bbc411453e187849f116d2977a25b038765fe5bce73dbf3f69dcd30cd991f36","Names":["/db"],
           "Image":"sha256:96aaced979c95f9a9da0df59a1c1ed80","State":"exited","Status":"Exited (0)",
           "Labels":{},"Ports":[],"Health":{"Status":"none"}},
          {"Id":"not-hex","Names":["/x"]}]"#;
        let list = parse_list(body, "OrbStack").unwrap();
        assert_eq!(list.len(), 2);
        let web = &list[0];
        assert_eq!(
            (
                web.name.as_str(),
                web.project.as_deref(),
                web.service.as_deref()
            ),
            ("web-1", Some("shop"), Some("web"))
        );
        assert_eq!(web.health.as_deref(), Some("healthy"));
        assert_eq!(
            web.ports,
            vec![
                Published {
                    host: 8088,
                    container: 80,
                    proto: "tcp".into(),
                    exposed: true
                },
                Published {
                    host: 8443,
                    container: 443,
                    proto: "tcp".into(),
                    exposed: false
                },
            ]
        );
        assert_eq!(list[1].image, "96aaced979c9");
        assert!(list[1].health.is_none() && list[1].project.is_none());
    }
    #[test]
    fn vm_meminfo_and_kills() {
        let info = "MemTotal:        4081492 kB\nMemFree:          964472 kB\nMemAvailable:    1341648 kB\n";
        assert_eq!(
            parse_meminfo(info),
            Some((4081492. * 1024., 1341648. * 1024.))
        );
        assert_eq!(parse_meminfo("MemTotal: 10 kB\n"), None);
        let events = br#"{"Type":"container","Action":"die","Actor":{"Attributes":{"exitCode":"137","name":"db"}},"time":100}
{"Type":"container","Action":"die","Actor":{"Attributes":{"exitCode":"0","name":"web"}},"time":101}
{"Type":"container","Action":"oom","Actor":{"Attributes":{"name":"db"}},"time":99}
{"Type":"container","Action":"oom","Actor":{"Attributes":{"name":"cache"}},"time":102}"#;
        assert_eq!(
            parse_kills(events),
            vec![
                Killed {
                    name: "db".into(),
                    at: 100.,
                    oom: true
                },
                Killed {
                    name: "cache".into(),
                    at: 102.,
                    oom: true
                }
            ]
        );
        let vm = VmMemory {
            engine: "OrbStack",
            total: 4000.,
            available: None,
            containers_used: 3000.,
            top: vec![],
            near_limit: vec![],
            killed: vec![],
        };
        assert_eq!(vm.free_percent(), 25.);
        assert_eq!(
            VmMemory {
                available: Some(400.),
                ..vm
            }
            .free_percent(),
            10.
        );
        assert_eq!(
            percent_encode(r#"{"a":["b c"]}"#),
            "%7B%22a%22%3A%5B%22b%20c%22%5D%7D"
        );
    }

    #[test]
    fn stats_cpu_and_memory() {
        let a = br#"{"cpu_stats":{"cpu_usage":{"total_usage":1000000000},"system_cpu_usage":100000000000,"online_cpus":10},
          "memory_stats":{"usage":174366720,"stats":{"inactive_file":1048576},"limit":4179447808}}"#;
        let b = br#"{"cpu_stats":{"cpu_usage":{"total_usage":1500000000},"system_cpu_usage":110000000000,"online_cpus":10},
          "memory_stats":{"usage":0}}"#;
        let (a, b) = (parse_stats(a).unwrap(), parse_stats(b).unwrap());
        assert_eq!(a.memory, Some(174366720. - 1048576.));
        assert_eq!(a.limit, Some(4179447808.));
        // 0.5 s of container CPU over 10 s of host time across 10 CPUs = half a core.
        assert!((cpu_percent(&a, &b).unwrap() - 50.).abs() < 1e-9);
        assert!(cpu_percent(&b, &a).is_none());
        assert!(parse_stats(b"{}").is_none());
    }
    #[test]
    fn running_containers_survive_the_cap() {
        let item = |i: usize, state: &str| Container {
            id: format!("{i:012x}"),
            name: format!("c{i}"),
            image: String::new(),
            engine: "Docker",
            state: state.into(),
            status: String::new(),
            health: None,
            project: None,
            service: None,
            created: 0.,
            ports: vec![],
            cpu: None,
            memory: None,
            memory_limit: None,
            requirepass: None,
        };
        let mut list: Vec<Container> = (0..MAX_CONTAINERS + 5).map(|i| item(i, "exited")).collect();
        list.push(item(999, "running"));
        let kept = cap(list);
        assert_eq!(kept.len(), MAX_CONTAINERS);
        assert_eq!(kept[0].name, "c999");
        assert_eq!(kept[1].name, "c0");
    }
    #[test]
    fn lookup_uses_the_filtered_list_not_inspect() {
        let path = lookup_path("bebc2aa52608");
        assert!(path.starts_with("/containers/json?"));
        assert!(path.ends_with("filters=%7B%22id%22%3A%5B%22bebc2aa52608%22%5D%7D"));
    }
    #[test]
    fn actions_are_validated_before_any_request() {
        assert!(act("bebc2aa52608", "kill").is_err());
        assert!(act("../info", "stop").is_err());
    }
}
