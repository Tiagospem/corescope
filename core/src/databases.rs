//! Local databases at a glance: MySQL/MariaDB, PostgreSQL and Redis found among listening
//! processes and containers (published or not), queried over their own wire protocols on
//! 127.0.0.1 where the server allows passwordless local access. A container that is not
//! published or wants a password is read inside it with its own credentials, and a server on the
//! Mac that wants one with the credentials the user saved in the app (see `dbaccess`).
//! Read-only queries only.
use crate::{Process, containers};
use serde::Serialize;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(3);
const LONG_QUERY_SECONDS: u64 = 5;

#[derive(Clone, Debug, PartialEq, Serialize, Default)]
pub struct Endpoint {
    /// "mysql", "postgres" or "redis".
    pub kind: &'static str,
    /// Host port when `published`; otherwise the port inside the container.
    pub port: u16,
    pub label: String,
    pub container: Option<String>,
    /// Reachable from the Mac on 127.0.0.1:`port`. False for a container that only exposes
    /// the port to its compose network: it is read from inside the container.
    pub published: bool,
    /// Compose project and service of a container.
    pub project: Option<String>,
    pub service: Option<String>,
    /// A Redis password from the container's command line; handed to redis-cli inside the
    /// container on stdin. Never serialized.
    #[serde(skip)]
    pub secret: Option<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct LongQuery {
    pub id: String,
    pub user: String,
    pub database: String,
    pub seconds: u64,
    /// First 200 characters of the statement.
    pub query: String,
}

#[derive(Debug, Serialize)]
pub struct Database {
    #[serde(flatten)]
    pub endpoint: Endpoint,
    /// "ok", "auth" (needs a password) or "error".
    pub status: &'static str,
    pub error: Option<String>,
    pub version: Option<String>,
    pub uptime: Option<u64>,
    pub connections: Option<u64>,
    pub slow_queries: Option<u64>,
    /// Total data size in bytes (memory in use for Redis).
    pub size: Option<u64>,
    /// Per database (schema, or Redis db with key counts in `keys`).
    pub databases: Vec<Schema>,
    pub long_queries: Vec<LongQuery>,
    /// How it was read: None over the wire on 127.0.0.1, "container" inside its container
    /// with the container's own credentials, "password" with credentials saved in CoreScope.
    pub via: Option<&'static str>,
}
#[derive(Debug, Serialize)]
pub struct Schema {
    pub name: String,
    pub bytes: Option<u64>,
    pub keys: Option<u64>,
}

impl Database {
    pub fn from_endpoint(endpoint: Endpoint) -> Self {
        Database::new(endpoint)
    }
    fn new(endpoint: Endpoint) -> Self {
        Database {
            endpoint,
            status: "ok",
            error: None,
            version: None,
            uptime: None,
            connections: None,
            slow_queries: None,
            size: None,
            databases: vec![],
            long_queries: vec![],
            via: None,
        }
    }
    fn failed(endpoint: Endpoint, e: Failure) -> Self {
        let mut d = Database::new(endpoint);
        match e {
            Failure::Auth => {
                d.status = "auth";
                d.error = Some("Pede senha".into());
            }
            Failure::Other(message) => {
                d.status = "error";
                d.error = Some(message);
            }
        }
        d
    }
}

#[derive(Debug, PartialEq)]
pub enum Failure {
    /// The server wants a password; CoreScope does not have or look for one.
    Auth,
    Other(String),
}
impl From<std::io::Error> for Failure {
    fn from(e: std::io::Error) -> Self {
        Failure::Other(match e.kind() {
            std::io::ErrorKind::ConnectionRefused => "Conexão recusada".into(),
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => "Sem resposta".into(),
            _ => e.to_string(),
        })
    }
}
fn other(message: &str) -> Failure {
    Failure::Other(message.into())
}

fn kind_of(name: &str) -> Option<&'static str> {
    let n = name.to_lowercase();
    if ["mysql", "mariadb", "percona"]
        .iter()
        .any(|k| n.contains(k))
    {
        Some("mysql")
    } else if ["postgres", "postgis", "timescale"]
        .iter()
        .any(|k| n.contains(k))
    {
        Some("postgres")
    } else if ["redis", "valkey", "keydb"].iter().any(|k| n.contains(k)) {
        Some("redis")
    } else {
        None
    }
}
fn default_port(kind: &str) -> u16 {
    match kind {
        "mysql" => 3306,
        "postgres" => 5432,
        _ => 6379,
    }
}

/// Containers by image, database processes by name, then the well-known ports nobody claimed.
pub fn detect(processes: &[Process], containers: &[containers::Container]) -> Vec<Endpoint> {
    let mut out: Vec<Endpoint> = vec![];
    // Host ports are unique; a container without a published port is keyed by its name.
    let push = |e: Endpoint, out: &mut Vec<Endpoint>| {
        let taken = if e.published {
            out.iter().any(|o| o.published && o.port == e.port)
        } else {
            out.iter().any(|o| o.container == e.container)
        };
        if !taken {
            out.push(e);
        }
    };
    for c in containers.iter().filter(|c| c.state == "running") {
        // By image first, then the compose service or container name (custom images).
        let Some(kind) = kind_of(&c.image)
            .or_else(|| c.service.as_deref().and_then(kind_of))
            .or_else(|| kind_of(&c.name))
        else {
            continue;
        };
        let tcp: Vec<_> = c.ports.iter().filter(|p| p.proto == "tcp").collect();
        let port = tcp
            .iter()
            .find(|p| p.container == default_port(kind))
            .or_else(|| tcp.first().filter(|_| tcp.len() == 1));
        push(
            Endpoint {
                kind,
                port: port.map(|p| p.host).unwrap_or_else(|| default_port(kind)),
                label: c.name.clone(),
                container: Some(c.name.clone()),
                published: port.is_some(),
                project: c.project.clone(),
                service: c.service.clone(),
                secret: if kind == "redis" {
                    c.requirepass.clone()
                } else {
                    None
                },
            },
            &mut out,
        );
    }
    for p in processes {
        let kind = match p.name.as_str() {
            "mysqld" | "mariadbd" => Some("mysql"),
            "postgres" | "postmaster" => Some("postgres"),
            "redis-server" | "valkey-server" => Some("redis"),
            _ => None,
        };
        let Some(kind) = kind else { continue };
        for port in p.ports.iter().map(|x| x.port).filter(|port| *port != 33060) {
            push(
                Endpoint {
                    kind,
                    port,
                    label: p.name.clone(),
                    published: true,
                    ..Default::default()
                },
                &mut out,
            );
        }
    }
    for p in processes {
        for port in p.ports.iter().map(|x| x.port) {
            let kind = match port {
                3306 => "mysql",
                5432 => "postgres",
                6379 => "redis",
                _ => continue,
            };
            push(
                Endpoint {
                    kind,
                    port,
                    label: p.name.clone(),
                    published: true,
                    ..Default::default()
                },
                &mut out,
            );
        }
    }
    out.sort_by_key(|e| (!e.published, e.port, e.label.clone()));
    out
}

fn connect(port: u16) -> Result<TcpStream, Failure> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let stream = TcpStream::connect_timeout(&addr, TIMEOUT)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    Ok(stream)
}

/// Every endpoint in parallel; each gives up after a few seconds. A published server is read
/// over its wire protocol without a password first. A container that is not published, or that
/// wants a password, is read inside the container with its own credentials; a server on the Mac
/// that wants one is read with the credentials the user saved (`creds`, "kind:port").
pub fn probe(endpoints: Vec<Endpoint>) -> Vec<Database> {
    probe_with(endpoints, &crate::dbaccess::Credentials::new())
}
pub fn probe_with(endpoints: Vec<Endpoint>, creds: &crate::dbaccess::Credentials) -> Vec<Database> {
    let home = crate::home();
    std::thread::scope(|s| {
        let handles: Vec<_> = endpoints
            .into_iter()
            .map(|e| {
                let home = home.clone();
                s.spawn(move || {
                    let wire = if e.published {
                        match e.kind {
                            "mysql" => mysql::inspect(e.port),
                            "postgres" => postgres::inspect(e.port),
                            _ => redis::inspect(e.port),
                        }
                    } else {
                        Err(Failure::Other("Sem porta publicada".into()))
                    };
                    let failure = match wire {
                        Ok(mut d) => {
                            d.endpoint = e;
                            return d;
                        }
                        Err(f) => f,
                    };
                    if let Some(c) = e.container.clone() {
                        return match crate::dbaccess::inspect_in_container(&e, &c, &home) {
                            Ok(d) => d,
                            Err(message) if e.published && failure != Failure::Auth => {
                                Database::failed(
                                    e,
                                    Failure::Other(format!("{}; {message}", other_text(&failure))),
                                )
                            }
                            Err(message) => Database::failed(e, Failure::Other(message)),
                        };
                    }
                    if failure == Failure::Auth
                        && let Some(c) = creds.get(&crate::dbaccess::key(e.kind, e.port))
                    {
                        return match crate::dbaccess::inspect_with_password(&e, c, &home) {
                            Ok(d) => d,
                            Err(message) => {
                                let mut d = Database::failed(e, Failure::Auth);
                                d.error = Some(message);
                                d
                            }
                        };
                    }
                    Database::failed(e, failure)
                })
            })
            .collect();
        handles.into_iter().filter_map(|h| h.join().ok()).collect()
    })
}
fn other_text(f: &Failure) -> String {
    match f {
        Failure::Auth => "Pede senha".into(),
        Failure::Other(m) => m.clone(),
    }
}

fn placeholder() -> Endpoint {
    Endpoint::default()
}
fn clip(s: &str) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    s.chars().take(200).collect()
}

pub mod redis {
    use super::*;

    /// One RESP reply: simple string, error, integer or bulk string.
    pub fn reply(stream: &mut impl Read) -> Result<String, Failure> {
        let line = read_line(stream)?;
        let (kind, rest) = line.split_at(1);
        match kind {
            "+" | ":" => Ok(rest.to_string()),
            "-" => {
                if rest.starts_with("NOAUTH") || rest.contains("WRONGPASS") {
                    Err(Failure::Auth)
                } else {
                    Err(Failure::Other(rest.chars().take(160).collect()))
                }
            }
            "$" => {
                let len: i64 = rest.parse().map_err(|_| other("Resposta inválida"))?;
                if len < 0 {
                    return Ok(String::new());
                }
                if len > 4 << 20 {
                    return Err(other("Resposta grande demais"));
                }
                let mut body = vec![0u8; len as usize + 2];
                stream.read_exact(&mut body)?;
                body.truncate(len as usize);
                Ok(String::from_utf8_lossy(&body).into_owned())
            }
            _ => Err(other("Não é Redis")),
        }
    }
    fn read_line(stream: &mut impl Read) -> Result<String, Failure> {
        let mut line = vec![];
        let mut byte = [0u8; 1];
        while line.len() < 1024 {
            stream.read_exact(&mut byte)?;
            if byte[0] == b'\n' {
                break;
            }
            line.push(byte[0]);
        }
        if line.last() == Some(&b'\r') {
            line.pop();
        }
        if line.is_empty() {
            return Err(other("Não é Redis"));
        }
        Ok(String::from_utf8_lossy(&line).into_owned())
    }

    /// `INFO` fields → version, uptime, clients, memory, keys per db.
    pub fn parse_info(info: &str, d: &mut Database) {
        for line in info.lines() {
            let Some((key, value)) = line.trim().split_once(':') else {
                continue;
            };
            match key {
                "redis_version" | "valkey_version" => d.version = Some(value.to_string()),
                "uptime_in_seconds" => d.uptime = value.parse().ok(),
                "connected_clients" => d.connections = value.parse().ok(),
                "used_memory" => d.size = value.parse().ok(),
                k if k.starts_with("db") && k[2..].chars().all(|c| c.is_ascii_digit()) => {
                    let keys = value
                        .split(',')
                        .find_map(|f| f.strip_prefix("keys="))
                        .and_then(|v| v.parse().ok());
                    d.databases.push(Schema {
                        name: key.to_string(),
                        bytes: None,
                        keys,
                    });
                }
                _ => {}
            }
        }
    }

    /// Any RESP reply, arrays included (SCAN answers `[cursor, [keys…]]`).
    #[derive(Debug, PartialEq)]
    pub enum Resp {
        Str(String),
        Int(i64),
        Nil,
        Arr(Vec<Resp>),
    }
    impl Resp {
        pub fn text(&self) -> Option<&str> {
            match self {
                Resp::Str(s) => Some(s),
                _ => None,
            }
        }
        pub fn int(&self) -> Option<i64> {
            match self {
                Resp::Int(n) => Some(*n),
                Resp::Str(s) => s.parse().ok(),
                _ => None,
            }
        }
    }
    pub fn value(stream: &mut impl Read) -> Result<Resp, Failure> {
        value_at(stream, 0)
    }
    fn value_at(stream: &mut impl Read, depth: u8) -> Result<Resp, Failure> {
        let line = read_line(stream)?;
        let (kind, rest) = line.split_at(1);
        match kind {
            ":" => Ok(Resp::Int(
                rest.parse().map_err(|_| other("Resposta inválida"))?,
            )),
            "*" => {
                let n: i64 = rest.parse().map_err(|_| other("Resposta inválida"))?;
                if n < 0 {
                    return Ok(Resp::Nil);
                }
                if n > 100_000 || depth > 4 {
                    return Err(other("Resposta grande demais"));
                }
                (0..n)
                    .map(|_| value_at(stream, depth + 1))
                    .collect::<Result<Vec<_>, _>>()
                    .map(Resp::Arr)
            }
            "$" if rest == "-1" => Ok(Resp::Nil),
            _ => {
                // Simple strings, errors and bulk strings: reuse `reply` on the line already read.
                let mut chained =
                    std::io::Cursor::new(format!("{line}\r\n").into_bytes()).chain(stream);
                reply(&mut chained).map(Resp::Str)
            }
        }
    }
    /// A command as a RESP array, so keys with spaces or quotes stay one argument.
    pub fn command(args: &[&str]) -> Vec<u8> {
        let mut out = format!("*{}\r\n", args.len()).into_bytes();
        for a in args {
            out.extend(format!("${}\r\n", a.len()).bytes());
            out.extend(a.as_bytes());
            out.extend(b"\r\n");
        }
        out
    }
    /// The namespace of a key at `depth` segments (`go:sessions:` at 2); keys with fewer
    /// segments keep what they have, keys with no `:` are "(no prefix)".
    pub fn prefix_at(key: &str, depth: usize) -> String {
        let parts: Vec<&str> = key.split(':').collect();
        if parts.len() < 2 || parts[0].is_empty() {
            return "(no prefix)".into();
        }
        let take = depth.min(parts.len() - 1);
        format!("{}:", parts[..take].join(":"))
    }
    pub fn prefix_of(key: &str) -> String {
        prefix_at(key, 1)
    }
    /// The shallowest depth (1–4) at which no single prefix holds 80% of the sample, so one
    /// namespace for everything (`go:` / `laravel_database_`) is split into what is inside it.
    pub fn grouping_depth(keys: &[String]) -> usize {
        for depth in 1..4 {
            let mut counts: std::collections::HashMap<String, usize> = Default::default();
            for k in keys {
                *counts.entry(prefix_at(k, depth)).or_default() += 1;
            }
            let top = counts.values().max().copied().unwrap_or(0);
            if keys.is_empty() || top * 5 < keys.len() * 4 {
                return depth;
            }
        }
        4
    }
    #[derive(Debug, Serialize, PartialEq)]
    pub struct Prefix {
        pub prefix: String,
        pub sampled: u64,
        /// Sample scaled to the database's key count.
        pub estimated_keys: u64,
        pub estimated_bytes: u64,
        /// Sampled keys that never expire.
        pub without_ttl: u64,
        pub example: String,
    }
    #[derive(Debug, Serialize)]
    pub struct Keyspace {
        pub db: u32,
        pub keys: u64,
        pub sampled: u64,
        pub prefixes: Vec<Prefix>,
    }
    /// Samples up to `sample` keys of database `db` (SCAN, then MEMORY USAGE and TTL in one
    /// pipelined batch) and groups them by prefix. Read-only.
    pub fn keyspace(port: u16, db: u32, sample: usize) -> Result<Keyspace, Failure> {
        let mut stream = connect(port)?;
        let db_text = db.to_string();
        stream.write_all(&command(&["SELECT", &db_text]))?;
        reply(&mut stream)?;
        stream.write_all(&command(&["DBSIZE"]))?;
        let keys = value(&mut stream)?.int().unwrap_or(0).max(0) as u64;
        let mut cursor = "0".to_string();
        let mut sampled: Vec<String> = vec![];
        loop {
            stream.write_all(&command(&["SCAN", &cursor, "COUNT", "500"]))?;
            let Resp::Arr(parts) = value(&mut stream)? else {
                return Err(other("Resposta inválida"));
            };
            cursor = parts
                .first()
                .and_then(Resp::text)
                .unwrap_or("0")
                .to_string();
            if let Some(Resp::Arr(batch)) = parts.get(1) {
                sampled.extend(batch.iter().filter_map(|k| k.text().map(str::to_string)));
            }
            if cursor == "0" || sampled.len() >= sample {
                break;
            }
        }
        sampled.truncate(sample);
        let mut batch = vec![];
        for k in &sampled {
            batch.extend(command(&["MEMORY", "USAGE", k]));
            batch.extend(command(&["TTL", k]));
        }
        stream.set_read_timeout(Some(Duration::from_secs(15)))?;
        stream.write_all(&batch)?;
        let depth = grouping_depth(&sampled);
        let mut groups: std::collections::BTreeMap<String, Prefix> = Default::default();
        for k in &sampled {
            let bytes = value(&mut stream)?.int().unwrap_or(0).max(0) as u64;
            let ttl = value(&mut stream)?.int().unwrap_or(0);
            let g = groups.entry(prefix_at(k, depth)).or_insert_with(|| Prefix {
                prefix: prefix_at(k, depth),
                sampled: 0,
                estimated_keys: 0,
                estimated_bytes: 0,
                without_ttl: 0,
                example: k.chars().take(120).collect(),
            });
            g.sampled += 1;
            g.estimated_bytes += bytes;
            if ttl == -1 {
                g.without_ttl += 1;
            }
        }
        let total = sampled.len().max(1) as f64;
        let scale = keys as f64 / total;
        let mut prefixes: Vec<Prefix> = groups
            .into_values()
            .map(|mut g| {
                g.estimated_keys = (g.sampled as f64 * scale).round() as u64;
                g.estimated_bytes = (g.estimated_bytes as f64 * scale.max(1.)).round() as u64;
                g
            })
            .collect();
        prefixes.sort_by_key(|p| std::cmp::Reverse(p.estimated_bytes));
        Ok(Keyspace {
            db,
            keys,
            sampled: sampled.len() as u64,
            prefixes,
        })
    }
    /// FLUSHDB on database `db` of a local Redis (the app asks first).
    pub fn flush(port: u16, db: u32) -> Result<(), Failure> {
        let mut stream = connect(port)?;
        stream.write_all(&command(&["SELECT", &db.to_string()]))?;
        reply(&mut stream)?;
        stream.write_all(&command(&["FLUSHDB"]))?;
        match reply(&mut stream)?.as_str() {
            "OK" => Ok(()),
            other_reply => Err(other(other_reply)),
        }
    }

    pub fn inspect(port: u16) -> Result<Database, Failure> {
        let mut stream = connect(port)?;
        stream.write_all(b"INFO\r\n")?;
        let info = reply(&mut stream)?;
        let mut d = Database::new(placeholder());
        parse_info(&info, &mut d);
        if d.version.is_none() {
            return Err(other("Não é Redis"));
        }
        d.databases.sort_by_key(|s| std::cmp::Reverse(s.keys));
        stream.write_all(b"SLOWLOG LEN\r\n")?;
        d.slow_queries = reply(&mut stream).ok().and_then(|n| n.parse().ok());
        Ok(d)
    }
}

pub mod mysql {
    use super::*;

    pub fn read_packet(stream: &mut impl Read) -> Result<(u8, Vec<u8>), Failure> {
        let mut header = [0u8; 4];
        stream.read_exact(&mut header)?;
        let len = u32::from_le_bytes([header[0], header[1], header[2], 0]) as usize;
        if len > 16 << 20 {
            return Err(other("Pacote grande demais"));
        }
        let mut body = vec![0u8; len];
        stream.read_exact(&mut body)?;
        Ok((header[3], body))
    }
    fn write_packet(stream: &mut impl Write, seq: u8, body: &[u8]) -> Result<(), Failure> {
        let len = (body.len() as u32).to_le_bytes();
        stream.write_all(&[len[0], len[1], len[2], seq])?;
        stream.write_all(body)?;
        Ok(())
    }
    fn error(body: &[u8]) -> Failure {
        // 0xFF, code (2), '#', state (5), message.
        let code = body
            .get(1..3)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .unwrap_or(0);
        if code == 1045 {
            return Failure::Auth;
        }
        let message = body
            .get(9..)
            .map(String::from_utf8_lossy)
            .unwrap_or_default();
        Failure::Other(message.chars().take(160).collect())
    }
    /// Length-encoded integer at `pos`; advances it.
    pub fn lenenc(data: &[u8], pos: &mut usize) -> Option<u64> {
        let first = *data.get(*pos)?;
        *pos += 1;
        let width = match first {
            0..=0xfa => return Some(u64::from(first)),
            0xfc => 2,
            0xfd => 3,
            0xfe => 8,
            _ => return None,
        };
        let bytes = data.get(*pos..*pos + width)?;
        *pos += width;
        let mut v = [0u8; 8];
        v[..width].copy_from_slice(bytes);
        Some(u64::from_le_bytes(v))
    }
    /// A text-protocol row: NULL is 0xFB.
    pub fn row(data: &[u8], columns: usize) -> Vec<Option<String>> {
        let mut pos = 0;
        (0..columns)
            .map(|_| {
                if data.get(pos) == Some(&0xfb) {
                    pos += 1;
                    return None;
                }
                let len = lenenc(data, &mut pos)? as usize;
                let value = data.get(pos..pos + len)?;
                pos += len;
                Some(String::from_utf8_lossy(value).into_owned())
            })
            .collect()
    }

    /// Greeting, then `root` with an empty password. Any request for more is a password prompt.
    fn login(stream: &mut TcpStream) -> Result<String, Failure> {
        let (_, greeting) = read_packet(stream)?;
        if greeting.first() == Some(&0xff) {
            return Err(error(&greeting));
        }
        if greeting.first() != Some(&10) {
            return Err(other("Não é MySQL"));
        }
        let end = greeting[1..]
            .iter()
            .position(|b| *b == 0)
            .ok_or_else(|| other("Não é MySQL"))?;
        let version = String::from_utf8_lossy(&greeting[1..1 + end]).into_owned();
        let plugin = greeting
            .rsplit(|b| *b == 0)
            .find(|p| {
                p.starts_with(b"mysql_") || p.starts_with(b"caching_") || p.starts_with(b"sha256_")
            })
            .map(<[u8]>::to_vec)
            .unwrap_or_else(|| b"mysql_native_password".to_vec());
        // LONG_PASSWORD | PROTOCOL_41 | TRANSACTIONS | SECURE_CONNECTION | PLUGIN_AUTH
        let caps: u32 = 0x1 | 0x200 | 0x2000 | 0x8000 | 0x80000;
        let mut response = caps.to_le_bytes().to_vec();
        response.extend((16u32 << 20).to_le_bytes());
        response.push(45);
        response.extend([0u8; 23]);
        response.extend(b"root\0");
        response.push(0);
        response.extend(&plugin);
        response.push(0);
        write_packet(stream, 1, &response)?;
        let mut seq = 3;
        for _ in 0..4 {
            let (s, reply) = read_packet(stream)?;
            seq = s.wrapping_add(1);
            match reply.first() {
                Some(0x00) => return Ok(version),
                Some(0xff) => return Err(error(&reply)),
                // Auth switch: answer with an empty password for the new method.
                Some(0xfe) => write_packet(stream, seq, &[])?,
                // caching_sha2 fast path: 3 = accepted (OK follows), 4 = wants the real password.
                Some(0x01) if reply.get(1) == Some(&3) => continue,
                Some(0x01) => return Err(Failure::Auth),
                _ => return Err(other("Não é MySQL")),
            }
        }
        let _ = seq;
        Err(Failure::Auth)
    }
    fn query(stream: &mut TcpStream, sql: &str) -> Result<Vec<Vec<Option<String>>>, Failure> {
        let mut body = vec![0x03];
        body.extend(sql.as_bytes());
        write_packet(stream, 0, &body)?;
        let (_, first) = read_packet(stream)?;
        match first.first() {
            Some(0xff) => return Err(error(&first)),
            Some(0x00) => return Ok(vec![]),
            _ => {}
        }
        let columns = lenenc(&first, &mut 0).ok_or_else(|| other("Resposta inválida"))? as usize;
        for _ in 0..columns {
            read_packet(stream)?;
        }
        let (_, eof) = read_packet(stream)?;
        if eof.first() != Some(&0xfe) {
            return Err(other("Resposta inválida"));
        }
        let mut rows = vec![];
        loop {
            let (_, packet) = read_packet(stream)?;
            match packet.first() {
                Some(0xfe) if packet.len() < 9 => return Ok(rows),
                Some(0xff) => return Err(error(&packet)),
                _ => rows.push(row(&packet, columns)),
            }
        }
    }
    fn cell(rows: &[Vec<Option<String>>], r: usize, c: usize) -> Option<String> {
        rows.get(r)?.get(c)?.clone()
    }

    pub fn inspect(port: u16) -> Result<Database, Failure> {
        let mut stream = connect(port)?;
        let version = login(&mut stream)?;
        let mut d = Database::new(placeholder());
        d.version = Some(version);
        // Bound every SELECT on the server too (MySQL / MariaDB spelling), so a probe that gives
        // up never leaves a heavy query running there.
        let _ = query(&mut stream, "SET SESSION max_execution_time = 2000");
        let _ = query(&mut stream, "SET SESSION max_statement_time = 2");
        let status = query(
            &mut stream,
            "SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_connected','Slow_queries')",
        )?;
        for r in &status {
            let value = r.get(1).cloned().flatten().and_then(|v| v.parse().ok());
            match r.first().cloned().flatten().as_deref() {
                Some("Uptime") => d.uptime = value,
                Some("Threads_connected") => d.connections = value,
                Some("Slow_queries") => d.slow_queries = value,
                _ => {}
            }
        }
        // InnoDB's own statistics table: instant, unlike information_schema.tables, which
        // can take minutes on servers with many schemas.
        let schemas = query(
            &mut stream,
            "SELECT database_name, SUM(clustered_index_size + sum_of_other_index_sizes) * @@innodb_page_size \
             FROM mysql.innodb_table_stats WHERE database_name NOT IN ('mysql','sys') \
             GROUP BY database_name ORDER BY 2 DESC",
        )
        .unwrap_or_default();
        for (i, _) in schemas.iter().enumerate() {
            d.databases.push(Schema {
                name: cell(&schemas, i, 0).unwrap_or_default(),
                bytes: cell(&schemas, i, 1)
                    .and_then(|v| v.parse::<f64>().ok())
                    .map(|v| v as u64),
                keys: None,
            });
        }
        d.size = Some(d.databases.iter().filter_map(|s| s.bytes).sum());
        let long = query(
            &mut stream,
            &format!(
                "SELECT id, user, IFNULL(db,''), time, LEFT(IFNULL(info,''), 400) FROM information_schema.processlist \
                 WHERE command NOT IN ('Sleep','Daemon','Binlog Dump') AND time >= {LONG_QUERY_SECONDS} \
                 AND id <> CONNECTION_ID() ORDER BY time DESC LIMIT 10"
            ),
        )
        .unwrap_or_default();
        for r in long {
            let get = |i: usize| r.get(i).cloned().flatten().unwrap_or_default();
            d.long_queries.push(LongQuery {
                id: get(0),
                user: get(1),
                database: get(2),
                seconds: get(3).parse().unwrap_or(0),
                query: clip(&get(4)),
            });
        }
        let _ = write_packet(&mut stream, 0, &[0x01]);
        Ok(d)
    }
}

pub mod postgres {
    use super::*;

    fn message(stream: &mut impl Read) -> Result<(u8, Vec<u8>), Failure> {
        let mut header = [0u8; 5];
        stream.read_exact(&mut header)?;
        let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
        if !(4..16 << 20).contains(&len) {
            return Err(other("Não é PostgreSQL"));
        }
        let mut body = vec![0u8; len - 4];
        stream.read_exact(&mut body)?;
        Ok((header[0], body))
    }
    /// The 'M' (message) field of an ErrorResponse; 28P01/28000 mean authentication.
    pub fn error(body: &[u8]) -> Failure {
        let mut code = String::new();
        let mut text = String::new();
        for field in body.split(|b| *b == 0) {
            match field.first() {
                Some(b'C') => code = String::from_utf8_lossy(&field[1..]).into_owned(),
                Some(b'M') => text = String::from_utf8_lossy(&field[1..]).into_owned(),
                _ => {}
            }
        }
        if code.starts_with("28") {
            Failure::Auth
        } else {
            Failure::Other(text.chars().take(160).collect())
        }
    }
    pub fn startup(user: &str) -> Vec<u8> {
        let mut body = 196_608u32.to_be_bytes().to_vec();
        for (k, v) in [
            ("user", user),
            ("database", "postgres"),
            ("application_name", "CoreScope"),
        ] {
            body.extend(k.as_bytes());
            body.push(0);
            body.extend(v.as_bytes());
            body.push(0);
        }
        body.push(0);
        let mut out = ((body.len() + 4) as u32).to_be_bytes().to_vec();
        out.extend(body);
        out
    }
    /// DataRow → columns (None for NULL).
    pub fn data_row(body: &[u8]) -> Vec<Option<String>> {
        let n = body
            .get(0..2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]))
            .unwrap_or(0);
        let mut pos = 2;
        (0..n)
            .map(|_| {
                let len = i32::from_be_bytes(body.get(pos..pos + 4)?.try_into().ok()?);
                pos += 4;
                if len < 0 {
                    return None;
                }
                let value = body.get(pos..pos + len as usize)?;
                pos += len as usize;
                Some(String::from_utf8_lossy(value).into_owned())
            })
            .collect()
    }
    fn query(stream: &mut TcpStream, sql: &str) -> Result<Vec<Vec<Option<String>>>, Failure> {
        let mut out = vec![b'Q'];
        out.extend(((sql.len() + 5) as u32).to_be_bytes());
        out.extend(sql.as_bytes());
        out.push(0);
        stream.write_all(&out)?;
        let mut rows = vec![];
        let mut failure = None;
        loop {
            let (kind, body) = message(stream)?;
            match kind {
                b'D' => rows.push(data_row(&body)),
                b'E' => failure = Some(error(&body)),
                b'Z' => return failure.map_or(Ok(rows), Err),
                _ => {}
            }
        }
    }

    pub fn inspect(port: u16) -> Result<Database, Failure> {
        let mut stream = connect(port)?;
        let user = std::env::var("USER").unwrap_or_else(|_| "postgres".into());
        stream.write_all(&startup(&user))?;
        loop {
            let (kind, body) = message(&mut stream)?;
            match kind {
                b'R' if body.get(0..4) == Some(&[0, 0, 0, 0]) => {}
                // Any other authentication request needs a password.
                b'R' => {
                    let _ = stream.write_all(&[b'X', 0, 0, 0, 4]);
                    return Err(Failure::Auth);
                }
                b'E' => return Err(error(&body)),
                b'Z' => break,
                _ => {}
            }
        }
        let mut d = Database::new(placeholder());
        let first = |rows: Vec<Vec<Option<String>>>| {
            rows.into_iter()
                .next()
                .and_then(|r| r.into_iter().next().flatten())
        };
        d.version = first(query(&mut stream, "SHOW server_version")?);
        d.uptime = first(query(
            &mut stream,
            "SELECT EXTRACT(EPOCH FROM now() - pg_postmaster_start_time())::bigint",
        )?)
        .and_then(|v| v.parse().ok());
        d.connections = first(query(
            &mut stream,
            "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'",
        )?)
        .and_then(|v| v.parse().ok());
        for r in query(
            &mut stream,
            "SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate ORDER BY 2 DESC",
        )? {
            d.databases.push(Schema {
                name: r.first().cloned().flatten().unwrap_or_default(),
                bytes: r.get(1).cloned().flatten().and_then(|v| v.parse().ok()),
                keys: None,
            });
        }
        d.size = Some(d.databases.iter().filter_map(|s| s.bytes).sum());
        let long = query(
            &mut stream,
            &format!(
                "SELECT pid, usename, datname, EXTRACT(EPOCH FROM now() - query_start)::bigint, left(query, 400) \
                 FROM pg_stat_activity WHERE state = 'active' AND pid <> pg_backend_pid() \
                 AND now() - query_start > interval '{LONG_QUERY_SECONDS} seconds' ORDER BY 4 DESC LIMIT 10"
            ),
        )
        .unwrap_or_default();
        for r in long {
            let get = |i: usize| r.get(i).cloned().flatten().unwrap_or_default();
            d.long_queries.push(LongQuery {
                id: get(0),
                user: get(1),
                database: get(2),
                seconds: get(3).parse().unwrap_or(0),
                query: clip(&get(4)),
            });
        }
        let _ = stream.write_all(&[b'X', 0, 0, 0, 4]);
        Ok(d)
    }
}

#[cfg(test)]
mod tests {

    use super::redis::{Resp, command, keyspace, prefix_of, value};

    #[test]
    fn resp_arrays_commands_and_prefixes() {
        let raw = b"*2\r\n$1\r\n0\r\n*2\r\n$6\r\nuser:1\r\n$3\r\nfoo\r\n";
        let v = value(&mut &raw[..]).unwrap();
        assert_eq!(
            v,
            Resp::Arr(vec![
                Resp::Str("0".into()),
                Resp::Arr(vec![Resp::Str("user:1".into()), Resp::Str("foo".into())])
            ])
        );
        assert_eq!(value(&mut &b":42\r\n"[..]).unwrap(), Resp::Int(42));
        assert_eq!(value(&mut &b"$-1\r\n"[..]).unwrap(), Resp::Nil);
        assert_eq!(
            command(&["GET", "a b"]),
            b"*2\r\n$3\r\nGET\r\n$3\r\na b\r\n"
        );
        assert_eq!(prefix_of("laravel_cache:users:1"), "laravel_cache:");
        assert_eq!(prefix_of("plainkey"), "(no prefix)");
        assert_eq!(
            super::redis::prefix_at("go:sessions:abc", 2),
            "go:sessions:"
        );
        assert_eq!(super::redis::prefix_at("go:x", 3), "go:");
        let keys: Vec<String> = (0..10)
            .map(|i| format!("go:{}:{i}", if i < 6 { "sessions" } else { "cache" }))
            .collect();
        assert_eq!(
            super::redis::grouping_depth(&keys),
            2,
            "go: holds everything, so split it"
        );
    }

    #[test]
    fn keyspace_samples_prefixes_from_a_redis() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut c, _) = listener.accept().unwrap();
            let replies: [&[u8]; 4] = [
                b"+OK\r\n",
                b":30\r\n",
                b"*2\r\n$1\r\n0\r\n*3\r\n$8\r\nsession:\r\n$7\r\ncache:a\r\n$7\r\ncache:b\r\n",
                b":100\r\n:-1\r\n:200\r\n:60\r\n:300\r\n:-1\r\n",
            ];
            let mut buf = [0u8; 4096];
            for r in replies {
                let _ = c.read(&mut buf).unwrap();
                c.write_all(r).unwrap();
            }
        });
        let k = keyspace(port, 0, 100).unwrap();
        server.join().unwrap();
        assert_eq!((k.keys, k.sampled), (30, 3));
        let cache = k.prefixes.iter().find(|p| p.prefix == "cache:").unwrap();
        assert_eq!(cache.sampled, 2);
        assert_eq!(
            cache.estimated_keys, 20,
            "2 of 3 sampled, scaled to 30 keys"
        );
        assert_eq!(cache.estimated_bytes, 5000, "(200+300) × 10");
        assert_eq!(cache.without_ttl, 1);
        assert_eq!(k.prefixes[0].prefix, "cache:", "largest first");
    }
    use super::*;

    #[test]
    fn redis_replies_and_info() {
        let mut ok = &b"$11\r\nhello world\r\n"[..];
        assert_eq!(redis::reply(&mut ok).unwrap(), "hello world");
        let mut auth = &b"-NOAUTH Authentication required.\r\n"[..];
        assert_eq!(redis::reply(&mut auth), Err(Failure::Auth));
        let mut d = Database::new(placeholder());
        redis::parse_info(
            "# Server\r\nredis_version:7.2.4\r\nuptime_in_seconds:42\r\nconnected_clients:3\r\nused_memory:1048576\r\n# Keyspace\r\ndb0:keys=12,expires=0\r\ndb3:keys=1,expires=1\r\n",
            &mut d,
        );
        assert_eq!(d.version.as_deref(), Some("7.2.4"));
        assert_eq!(
            (d.uptime, d.connections, d.size),
            (Some(42), Some(3), Some(1_048_576))
        );
        assert_eq!(
            d.databases.iter().map(|s| s.keys).collect::<Vec<_>>(),
            [Some(12), Some(1)]
        );
    }

    #[test]
    fn mysql_length_encoding_and_rows() {
        let mut pos = 0;
        assert_eq!(mysql::lenenc(&[0xfc, 0x10, 0x27], &mut pos), Some(10_000));
        assert_eq!(pos, 3);
        let row = [3, b'a', b'p', b'p', 0xfb, 2, b'4', b'2'];
        assert_eq!(
            mysql::row(&row, 3),
            [Some("app".into()), None, Some("42".into())]
        );
        let mut packet = &[2u8, 0, 0, 5, 0xff, 0x15][..];
        assert_eq!(
            mysql::read_packet(&mut packet).unwrap(),
            (5, vec![0xff, 0x15])
        );
    }

    #[test]
    fn postgres_messages() {
        let startup = postgres::startup("dev");
        assert_eq!(
            u32::from_be_bytes(startup[0..4].try_into().unwrap()) as usize,
            startup.len()
        );
        assert!(startup.ends_with(b"CoreScope\0\0"));
        let row = [0, 2, 0, 0, 0, 3, b'a', b'p', b'p', 0xff, 0xff, 0xff, 0xff];
        assert_eq!(postgres::data_row(&row), [Some("app".into()), None]);
        assert_eq!(
            postgres::error(b"SFATAL\0C28P01\0Mpassword authentication failed\0\0"),
            Failure::Auth
        );
    }

    #[test]
    fn detection_prefers_containers_and_known_names() {
        let mut orb = crate::process_fixture();
        orb.name = "OrbStack Helper".into();
        orb.ports = vec![
            crate::Port {
                port: 3306,
                exposed: true,
            },
            crate::Port {
                port: 6379,
                exposed: true,
            },
        ];
        let mut pg = crate::process_fixture();
        pg.name = "postgres".into();
        pg.ports = vec![crate::Port {
            port: 5433,
            exposed: false,
        }];
        let container = containers::Container {
            id: "a".into(),
            name: "shop-mysql".into(),
            image: "mysql:8.4".into(),
            engine: "OrbStack",
            state: "running".into(),
            status: String::new(),
            health: None,
            project: None,
            service: None,
            created: 0.,
            ports: vec![containers::Published {
                host: 3306,
                container: 3306,
                proto: "tcp".into(),
                exposed: true,
            }],
            cpu: None,
            memory: None,
            memory_limit: None,
            requirepass: None,
        };
        let found = detect(&[orb, pg], &[container]);
        let summary: Vec<_> = found
            .iter()
            .map(|e| (e.kind, e.port, e.label.as_str()))
            .collect();
        assert_eq!(
            summary,
            [
                ("mysql", 3306, "shop-mysql"),
                ("postgres", 5433, "postgres"),
                ("redis", 6379, "OrbStack Helper")
            ]
        );
    }
}
