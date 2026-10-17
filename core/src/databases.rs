//! Local databases at a glance: MySQL/MariaDB, PostgreSQL and Redis found among listening
//! processes and containers, queried over their own wire protocols on 127.0.0.1. CoreScope never
//! asks for, stores or reads passwords: it connects only where the server allows passwordless
//! local access (MySQL `root` with no password, PostgreSQL trust for the current user, Redis
//! without AUTH) and otherwise reports that a password is required. Read-only queries only.
use crate::{Process, containers};
use serde::Serialize;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(3);
const LONG_QUERY_SECONDS: u64 = 5;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Endpoint {
    /// "mysql", "postgres" or "redis".
    pub kind: &'static str,
    pub port: u16,
    pub label: String,
    pub container: Option<String>,
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
}
#[derive(Debug, Serialize)]
pub struct Schema {
    pub name: String,
    pub bytes: Option<u64>,
    pub keys: Option<u64>,
}

impl Database {
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
    let push = |e: Endpoint, out: &mut Vec<Endpoint>| {
        if !out.iter().any(|o| o.port == e.port) {
            out.push(e);
        }
    };
    for c in containers.iter().filter(|c| c.state == "running") {
        let Some(kind) = kind_of(&c.image) else {
            continue;
        };
        let tcp: Vec<_> = c.ports.iter().filter(|p| p.proto == "tcp").collect();
        let port = tcp
            .iter()
            .find(|p| p.container == default_port(kind))
            .or_else(|| tcp.first().filter(|_| tcp.len() == 1));
        if let Some(p) = port {
            push(
                Endpoint {
                    kind,
                    port: p.host,
                    label: c.name.clone(),
                    container: Some(c.name.clone()),
                },
                &mut out,
            );
        }
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
                    container: None,
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
                    container: None,
                },
                &mut out,
            );
        }
    }
    out.sort_by_key(|e| e.port);
    out
}

fn connect(port: u16) -> Result<TcpStream, Failure> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let stream = TcpStream::connect_timeout(&addr, TIMEOUT)?;
    stream.set_read_timeout(Some(TIMEOUT))?;
    stream.set_write_timeout(Some(TIMEOUT))?;
    Ok(stream)
}

/// Every endpoint in parallel; each gives up after a few seconds.
pub fn probe(endpoints: Vec<Endpoint>) -> Vec<Database> {
    std::thread::scope(|s| {
        let handles: Vec<_> = endpoints
            .into_iter()
            .map(|e| {
                s.spawn(move || {
                    let result = match e.kind {
                        "mysql" => mysql::inspect(e.port),
                        "postgres" => postgres::inspect(e.port),
                        _ => redis::inspect(e.port),
                    };
                    match result {
                        Ok(mut d) => {
                            d.endpoint = e;
                            d
                        }
                        Err(f) => Database::failed(e, f),
                    }
                })
            })
            .collect();
        handles.into_iter().filter_map(|h| h.join().ok()).collect()
    })
}

fn placeholder() -> Endpoint {
    Endpoint {
        kind: "",
        port: 0,
        label: String::new(),
        container: None,
    }
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

    pub fn inspect(port: u16) -> Result<Database, Failure> {
        let mut stream = connect(port)?;
        stream.write_all(b"INFO\r\n")?;
        let info = reply(&mut stream)?;
        let mut d = Database::new(placeholder());
        parse_info(&info, &mut d);
        if d.version.is_none() {
            return Err(other("Não é Redis"));
        }
        d.databases.sort_by(|a, b| b.keys.cmp(&a.keys));
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
