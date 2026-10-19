//! Reading a local database that the plain wire probe cannot: one that runs in a container
//! without a published port, or one that wants a password.
//!
//! - In a container, the queries run inside it (`docker exec`) with the container's own
//!   credentials from its environment (`MYSQL_ROOT_PASSWORD`, `POSTGRES_USER`, `REDIS_PASSWORD`,
//!   Redis' `--requirepass`): the password stays in the container and never reaches CoreScope.
//! - On the Mac, with a user and password the user saved in CoreScope (the app keeps them in the
//!   Keychain and hands them over for this read only), the installed client runs with the
//!   password in its environment (`MYSQL_PWD`, `PGPASSWORD`, `REDISCLI_AUTH`), never in argv.
//!
//! Both paths send the same read-only queries and parse the same output.
use crate::databases::{Database, Endpoint, LongQuery, Schema};
use serde::Deserialize;
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const TIMEOUT: Duration = Duration::from_secs(10);

/// A user and password for one server on this Mac, keyed "kind:port" ("mysql:3306").
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Credential {
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub password: String,
}
pub type Credentials = HashMap<String, Credential>;
pub fn key(kind: &str, port: u16) -> String {
    format!("{kind}:{port}")
}

/// Tagged rows, one per line: `version`, `uptime`, `connections`, `slow`, `size <db> <bytes>`,
/// `long <id> <user> <db> <seconds> <query>` (tab-separated).
pub const MYSQL_SQL: &str = "SELECT 'version', VERSION(); \
    SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_connected','Slow_queries'); \
    SELECT 'size', table_schema, IFNULL(SUM(data_length + index_length), 0) FROM information_schema.tables \
      WHERE table_schema NOT IN ('information_schema','performance_schema','sys','mysql') GROUP BY table_schema; \
    SELECT 'long', id, user, IFNULL(db, ''), time, LEFT(REPLACE(REPLACE(IFNULL(info, ''), '\\n', ' '), '\\t', ' '), 200) \
      FROM information_schema.processlist WHERE command NOT IN ('Sleep', 'Daemon', 'Binlog Dump') AND time >= 5 AND id <> CONNECTION_ID();";

pub const POSTGRES_SQL: [&str; 5] = [
    "select 'version', current_setting('server_version')",
    "select 'uptime', extract(epoch from now() - pg_postmaster_start_time())::bigint",
    "select 'connections', count(*) from pg_stat_activity where backend_type = 'client backend'",
    "select 'size', datname, pg_database_size(datname) from pg_database where not datistemplate",
    "select 'long', pid, usename, datname, extract(epoch from now() - query_start)::bigint, \
     left(replace(replace(query, E'\\n', ' '), E'\\t', ' '), 200) from pg_stat_activity \
     where state = 'active' and now() - query_start > interval '5 seconds' and pid <> pg_backend_pid()",
];

/// MySQL client output (`-N -B`): tagged rows and `SHOW GLOBAL STATUS` rows.
pub fn parse_mysql(out: &str, d: &mut Database) {
    for line in out.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f.as_slice() {
            ["version", v] => d.version = Some(v.to_string()),
            ["status", name, value] | [name, value] if !name.is_empty() => {
                match name.to_ascii_uppercase().as_str() {
                    "UPTIME" => d.uptime = value.parse().ok(),
                    "THREADS_CONNECTED" => d.connections = value.parse().ok(),
                    "SLOW_QUERIES" => d.slow_queries = value.parse().ok(),
                    _ => {}
                }
            }
            ["size", db, bytes] => d.databases.push(Schema {
                name: db.to_string(),
                bytes: bytes.parse().ok(),
                keys: None,
            }),
            ["long", id, user, db, seconds, query] => d.long_queries.push(LongQuery {
                id: id.to_string(),
                user: user.to_string(),
                database: db.to_string(),
                seconds: seconds.parse().unwrap_or(0),
                query: query.to_string(),
            }),
            _ => {}
        }
    }
    finish(d);
}
/// psql output (`-At -F <tab>`), one tagged row per line.
pub fn parse_postgres(out: &str, d: &mut Database) {
    for line in out.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f.as_slice() {
            ["version", v] => d.version = Some(v.to_string()),
            ["uptime", v] => d.uptime = v.parse().ok(),
            ["connections", v] => d.connections = v.parse().ok(),
            ["size", db, bytes] => d.databases.push(Schema {
                name: db.to_string(),
                bytes: bytes.parse().ok(),
                keys: None,
            }),
            ["long", id, user, db, seconds, query] => d.long_queries.push(LongQuery {
                id: id.to_string(),
                user: user.to_string(),
                database: db.to_string(),
                seconds: seconds.parse().unwrap_or(0),
                query: query.to_string(),
            }),
            _ => {}
        }
    }
    finish(d);
}
/// `redis-cli INFO`, a `---` line, then `SLOWLOG LEN`.
pub fn parse_redis(out: &str, d: &mut Database) {
    let (info, rest) = out.split_once("\n---").unwrap_or((out, ""));
    crate::databases::redis::parse_info(info, d);
    d.databases.sort_by_key(|s| std::cmp::Reverse(s.keys));
    d.slow_queries = rest
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .and_then(|l| l.trim_start_matches("(integer) ").parse().ok());
}
fn finish(d: &mut Database) {
    d.databases.sort_by_key(|s| std::cmp::Reverse(s.bytes));
    if d.size.is_none() && !d.databases.is_empty() {
        d.size = Some(d.databases.iter().filter_map(|s| s.bytes).sum());
    }
}

/// A command with a time limit; stdout on success, a short message otherwise.
fn run(mut cmd: Command, timeout: Duration, input: Option<&str>) -> Result<String, String> {
    cmd.stdin(if input.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    })
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
        use std::io::Write;
        let _ = stdin.write_all(text.as_bytes());
    }
    let mut out_pipe = child.stdout.take().ok_or("no stdout")?;
    let mut err_pipe = child.stderr.take().ok_or("no stderr")?;
    let out = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = out_pipe.read_to_string(&mut s);
        s
    });
    let err = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = err_pipe.read_to_string(&mut s);
        s
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(20))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("Sem resposta".into());
            }
        }
    };
    let stdout = out.join().unwrap_or_default();
    let stderr = err.join().unwrap_or_default();
    if status.success() {
        Ok(stdout)
    } else {
        let message = stderr
            .lines()
            .map(str::trim)
            .rfind(|l| !l.is_empty() && !l.contains("Using a password on the command line"))
            .unwrap_or("falhou")
            .chars()
            .take(200)
            .collect();
        Err(message)
    }
}

/// Shell run inside the container. `$1` is the SQL for MySQL; psql takes one `-c` per query.
fn container_script(kind: &str) -> String {
    match kind {
        "mysql" => format!(
            "{}M=$(command -v mysql || command -v mariadb); [ -n \"$M\" ] || {{ echo 'no mysql client in the container' >&2; exit 2; }}; \
             \"$M\" -u\"$U\" -N -B -e \"$1\"",
            crate::dbsnapshot::MYSQL_ENV
        ),
        "postgres" => {
            let mut s = String::from(
                "export PGPASSWORD=\"${POSTGRES_PASSWORD:-}\"; psql -U \"${POSTGRES_USER:-postgres}\" -d postgres -At -F '\t' -v ON_ERROR_STOP=0",
            );
            for i in 1..=POSTGRES_SQL.len() {
                s.push_str(&format!(" -c \"${i}\""));
            }
            s
        }
        _ => "P=\"${REDIS_PASSWORD:-}\"; [ -n \"$P\" ] || read -r P || true; \
              C=$(command -v redis-cli || command -v valkey-cli); [ -n \"$C\" ] || { echo 'no redis-cli in the container' >&2; exit 2; }; \
              export REDISCLI_AUTH=\"$P\"; \"$C\" --no-auth-warning INFO && echo --- && \"$C\" --no-auth-warning SLOWLOG LEN"
            .into(),
    }
}

/// Reads a database inside its container with the container's own credentials.
pub fn inspect_in_container(
    e: &Endpoint,
    container: &str,
    home: &Path,
) -> Result<Database, String> {
    if !crate::dbsnapshot::valid_container(container) {
        return Err("invalid container name".into());
    }
    let docker = crate::dbsnapshot::docker_cli(home).ok_or("docker CLI not found")?;
    let mut cmd = Command::new(docker);
    // A password from the container's command line goes in on stdin, never in argv.
    let input = e.secret.as_ref().map(|s| format!("{s}\n"));
    cmd.arg("exec");
    if input.is_some() {
        cmd.arg("-i");
    }
    cmd.args([container, "sh", "-c", &container_script(e.kind), "sh"]);
    match e.kind {
        "mysql" => {
            cmd.arg(MYSQL_SQL);
        }
        "postgres" => {
            cmd.args(POSTGRES_SQL);
        }
        _ => {}
    }
    let out = run(cmd, TIMEOUT, input.as_deref())?;
    let mut d = Database::from_endpoint(e.clone());
    parse(e.kind, &out, &mut d)?;
    d.via = Some("container");
    Ok(d)
}

/// Clients installed on this Mac (Homebrew, Herd, DBngin, Postgres.app, MySQL installer).
fn client(names: &[&str], home: &Path) -> Option<PathBuf> {
    let dirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/homebrew/opt/mysql-client/bin",
        "/usr/local/opt/mysql-client/bin",
        "/opt/homebrew/opt/libpq/bin",
        "/usr/local/opt/libpq/bin",
        "/usr/local/mysql/bin",
        "/Applications/Postgres.app/Contents/Versions/latest/bin",
    ];
    let herd = home.join("Library/Application Support/Herd/bin");
    names.iter().find_map(|name| {
        dirs.iter()
            .map(PathBuf::from)
            .chain(std::iter::once(herd.clone()))
            .map(|d| d.join(name))
            .find(|p| p.is_file())
    })
}

/// Reads a server on this Mac with the user's saved credentials, through its installed client.
pub fn inspect_with_password(
    e: &Endpoint,
    c: &Credential,
    home: &Path,
) -> Result<Database, String> {
    let port = e.port.to_string();
    let mut cmd = match e.kind {
        "mysql" => {
            let bin = client(&["mysql", "mariadb"], home)
                .ok_or("no mysql client on this Mac (brew install mysql-client)")?;
            let mut cmd = Command::new(bin);
            let user = if c.user.is_empty() {
                "root"
            } else {
                c.user.as_str()
            };
            cmd.args([
                "--protocol=TCP",
                "-h",
                "127.0.0.1",
                "-P",
                &port,
                "-u",
                user,
                "--connect-timeout=4",
                "-N",
                "-B",
                "-e",
                MYSQL_SQL,
            ]);
            cmd.env("MYSQL_PWD", &c.password);
            cmd
        }
        "postgres" => {
            let bin = client(&["psql"], home).ok_or("no psql on this Mac (brew install libpq)")?;
            let mut cmd = Command::new(bin);
            let user = if c.user.is_empty() {
                "postgres"
            } else {
                c.user.as_str()
            };
            cmd.args([
                "-h",
                "127.0.0.1",
                "-p",
                &port,
                "-U",
                user,
                "-d",
                "postgres",
                "-At",
                "-F",
                "\t",
                "-w",
            ]);
            for q in POSTGRES_SQL {
                cmd.args(["-c", q]);
            }
            cmd.env("PGPASSWORD", &c.password)
                .env("PGCONNECT_TIMEOUT", "4");
            cmd
        }
        _ => {
            let bin = client(&["redis-cli", "valkey-cli"], home)
                .ok_or("no redis-cli on this Mac (brew install redis)")?;
            let mut cmd = Command::new("/bin/sh");
            cmd.args([
                "-c",
                "\"$0\" --no-auth-warning -h 127.0.0.1 -p \"$1\" ${2:+--user \"$2\"} INFO && echo --- && \"$0\" --no-auth-warning -h 127.0.0.1 -p \"$1\" ${2:+--user \"$2\"} SLOWLOG LEN",
            ]);
            cmd.arg(bin).arg(&port).arg(&c.user);
            cmd.env("REDISCLI_AUTH", &c.password);
            cmd
        }
    };
    cmd.env_remove("MYSQL_HOST");
    let out = run(cmd, TIMEOUT, None)?;
    let mut d = Database::from_endpoint(e.clone());
    parse(e.kind, &out, &mut d)?;
    d.via = Some("password");
    Ok(d)
}

fn parse(kind: &str, out: &str, d: &mut Database) -> Result<(), String> {
    match kind {
        "mysql" => parse_mysql(out, d),
        "postgres" => parse_postgres(out, d),
        _ => {
            if out.contains("NOAUTH") || out.contains("WRONGPASS") {
                return Err("the password was not accepted".into());
            }
            parse_redis(out, d);
        }
    }
    if d.version.is_none() {
        return Err("no answer from the database".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Database {
        Database::from_endpoint(Endpoint::default())
    }

    #[test]
    fn mysql_output_both_status_shapes() {
        let mut d = db();
        parse_mysql(
            "version\t8.4.3\nstatus\tUPTIME\t1200\nstatus\tTHREADS_CONNECTED\t4\nstatus\tSLOW_QUERIES\t2\n\
             size\tshop\t2048\nsize\tcrm\t8192\nlong\t17\tapp\tshop\t9\tSELECT SLEEP(10)\n",
            &mut d,
        );
        assert_eq!(
            (
                d.version.as_deref(),
                d.uptime,
                d.connections,
                d.slow_queries
            ),
            (Some("8.4.3"), Some(1200), Some(4), Some(2))
        );
        assert_eq!(d.databases[0].name, "crm", "largest first");
        assert_eq!(d.size, Some(10240));
        assert_eq!(d.long_queries[0].seconds, 9);
        let mut old = db();
        parse_mysql(
            "version\t5.7.44\nUptime\t60\nThreads_connected\t1\nSlow_queries\t0\n",
            &mut old,
        );
        assert_eq!(
            (old.uptime, old.connections, old.slow_queries),
            (Some(60), Some(1), Some(0))
        );
    }

    #[test]
    fn postgres_and_redis_output() {
        let mut d = db();
        parse_postgres(
            "version\t17.2\nuptime\t300\nconnections\t3\nsize\tpostgres\t7000\nsize\tapp\t90000\n",
            &mut d,
        );
        assert_eq!(
            (d.version.as_deref(), d.uptime, d.connections),
            (Some("17.2"), Some(300), Some(3))
        );
        assert_eq!((d.databases[0].name.as_str(), d.size), ("app", Some(97000)));
        let mut r = db();
        parse_redis(
            "# Server\r\nredis_version:7.4.1\r\nuptime_in_seconds:50\r\nconnected_clients:2\r\nused_memory:1048576\r\n# Keyspace\r\ndb0:keys=10,expires=0\r\ndb1:keys=99,expires=1\r\n---\n3\n",
            &mut r,
        );
        assert_eq!(
            (r.version.as_deref(), r.size, r.slow_queries),
            (Some("7.4.1"), Some(1048576), Some(3))
        );
        assert_eq!(r.databases[0].name, "db1");
        let mut bad = db();
        assert!(parse("redis", "NOAUTH Authentication required.", &mut bad).is_err());
    }

    #[test]
    fn container_scripts_keep_secrets_out_of_argv() {
        // Passwords come from the container's environment (or stdin), read inside it.
        for kind in ["mysql", "postgres", "redis"] {
            let s = container_script(kind);
            assert!(
                !s.contains("-p\"$") && !s.contains("--password"),
                "{kind}: {s}"
            );
        }
        assert!(container_script("redis").contains("REDISCLI_AUTH"));
        assert!(container_script("postgres").contains("${POSTGRES_USER:-postgres}"));
    }
}
