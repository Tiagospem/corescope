//! Docker Engine API over local Unix sockets only (OrbStack, Docker Desktop, Colima).
//! No TCP, no credentials: DOCKER_HOST is honored only when it names a `unix://` socket.
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
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
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: docker\r\nUser-Agent: CoreScope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
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
                id,
            })
        })
        .collect())
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

/// A named volume with what `/system/df` reports about it.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct VolumeInfo {
    pub name: String,
    pub engine: &'static str,
    /// Bytes on disk, when the engine measured it.
    pub size: Option<u64>,
    /// Containers using it (stopped ones included); 0 means unused.
    pub containers: i64,
    pub project: Option<String>,
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
            Some(VolumeInfo {
                name: v["Name"].as_str()?.to_string(),
                engine,
                size: v["UsageData"]["Size"]
                    .as_i64()
                    .filter(|s| *s >= 0)
                    .map(|s| s as u64),
                containers: v["UsageData"]["RefCount"].as_i64().unwrap_or(-1),
                project: v["Labels"]["com.docker.compose.project"]
                    .as_str()
                    .map(String::from),
            })
        })
        .collect()
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
        for c in serde_json::from_slice::<Value>(&list.body)
            .unwrap_or_default()
            .as_array()
            .into_iter()
            .flatten()
        {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn volumes_from_system_df() {
        let body = serde_json::json!({"Volumes": [
            {"Name": "shop_db", "UsageData": {"Size": 2048, "RefCount": 1}, "Labels": {"com.docker.compose.project": "shop"}},
            {"Name": "orphan", "UsageData": {"Size": -1, "RefCount": 0}, "Labels": null}
        ]});
        let v = parse_volumes(&body, "OrbStack");
        assert_eq!(v[0].project.as_deref(), Some("shop"));
        assert_eq!((v[1].size, v[1].containers), (None, 0));
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
