//! Database snapshots for development: dump one MySQL/MariaDB or PostgreSQL database to a
//! gzipped SQL file, list them, restore one (the database goes back to exactly that state).
//! For a container the dump runs inside it (`docker exec`) with the container's own
//! credentials from its environment (MYSQL_ROOT_PASSWORD, POSTGRES_USER…): CoreScope never
//! reads, stores or passes a password. A database on the host works only where local access
//! needs no password, like the rest of the Databases page.
use crate::databases::Endpoint;
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Snapshot {
    pub id: String,
    /// "mysql" or "postgres".
    pub kind: String,
    pub label: String,
    pub container: Option<String>,
    pub port: u16,
    pub database: String,
    /// Seconds since 1970.
    pub created: i64,
    /// Compressed size.
    pub bytes: u64,
    pub file: String,
}

/// `~/Library/Application Support/CoreScope/db-snapshots`.
pub fn default_dir(home: &Path) -> PathBuf {
    home.join("Library/Application Support/CoreScope/db-snapshots")
}

/// Database names are passed as a positional argument, never interpolated; this only keeps out
/// what no development database is called.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '$'))
}
/// Container names as Docker allows them.
fn valid_container(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

pub fn docker_cli(home: &Path) -> Option<PathBuf> {
    [
        PathBuf::from("/usr/local/bin/docker"),
        PathBuf::from("/opt/homebrew/bin/docker"),
        home.join(".orbstack/bin/docker"),
        PathBuf::from("/Applications/Docker.app/Contents/Resources/bin/docker"),
        PathBuf::from("/Applications/OrbStack.app/Contents/MacOS/xbin/docker"),
    ]
    .into_iter()
    .find(|p| p.is_file())
}
fn host_tool(names: &[&str]) -> Option<PathBuf> {
    let dirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/homebrew/opt/mysql-client/bin",
        "/opt/homebrew/opt/libpq/bin",
        "/Applications/Postgres.app/Contents/Versions/latest/bin",
    ];
    names
        .iter()
        .flat_map(|n| dirs.iter().map(move |d| Path::new(d).join(n)))
        .find(|p| p.is_file())
}

/// Credentials inside a MySQL/MariaDB container, from its own environment.
const MYSQL_ENV: &str = r#"if [ -n "$MYSQL_ROOT_PASSWORD$MARIADB_ROOT_PASSWORD" ] || [ -n "$MYSQL_ALLOW_EMPTY_PASSWORD$MARIADB_ALLOW_EMPTY_ROOT_PASSWORD" ]; then U=root; export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}"; else U="${MYSQL_USER:-${MARIADB_USER:-root}}"; export MYSQL_PWD="${MYSQL_PASSWORD:-$MARIADB_PASSWORD}"; fi; "#;

/// (program, args) that dumps `database` to stdout.
fn dump_command(
    e: &Endpoint,
    database: &str,
    home: &Path,
) -> Result<(PathBuf, Vec<String>), String> {
    match (&e.container, e.kind) {
        (Some(c), "mysql") => Ok((
            docker_cli(home).ok_or("docker CLI not found")?,
            vec![
                "exec".into(),
                c.clone(),
                "sh".into(),
                "-c".into(),
                format!(
                    r#"{MYSQL_ENV}exec "$(command -v mariadb-dump || command -v mysqldump)" -u"$U" --single-transaction --routines --triggers --events --add-drop-database --databases "$1""#
                ),
                "sh".into(),
                database.into(),
            ],
        )),
        (Some(c), "postgres") => Ok((
            docker_cli(home).ok_or("docker CLI not found")?,
            vec![
                "exec".into(),
                c.clone(),
                "sh".into(),
                "-c".into(),
                r#"exec pg_dump -U "${POSTGRES_USER:-postgres}" --clean --if-exists --create -d "$1""#.into(),
                "sh".into(),
                database.into(),
            ],
        )),
        (None, "mysql") => Ok((
            host_tool(&["mariadb-dump", "mysqldump"]).ok_or("mysqldump not found on this Mac")?,
            vec![
                "-h127.0.0.1".into(),
                format!("-P{}", e.port),
                "-uroot".into(),
                "--single-transaction".into(),
                "--routines".into(),
                "--triggers".into(),
                "--add-drop-database".into(),
                "--databases".into(),
                database.into(),
            ],
        )),
        (None, "postgres") => Ok((
            host_tool(&["pg_dump"]).ok_or("pg_dump not found on this Mac")?,
            vec![
                "-h".into(),
                "127.0.0.1".into(),
                "-p".into(),
                e.port.to_string(),
                "-w".into(),
                "--clean".into(),
                "--if-exists".into(),
                "--create".into(),
                "-d".into(),
                database.into(),
            ],
        )),
        _ => Err("snapshots support MySQL/MariaDB and PostgreSQL".into()),
    }
}
/// (program, args) that reads a dump on stdin and applies it.
fn restore_command(s: &Snapshot, home: &Path) -> Result<(PathBuf, Vec<String>), String> {
    match (&s.container, s.kind.as_str()) {
        (Some(c), "mysql") => Ok((
            docker_cli(home).ok_or("docker CLI not found")?,
            vec![
                "exec".into(),
                "-i".into(),
                c.clone(),
                "sh".into(),
                "-c".into(),
                format!(r#"{MYSQL_ENV}exec "$(command -v mariadb || command -v mysql)" -u"$U""#),
            ],
        )),
        (Some(c), "postgres") => Ok((
            docker_cli(home).ok_or("docker CLI not found")?,
            vec![
                "exec".into(),
                "-i".into(),
                c.clone(),
                "sh".into(),
                "-c".into(),
                r#"exec psql -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d postgres"#
                    .into(),
            ],
        )),
        (None, "mysql") => Ok((
            host_tool(&["mariadb", "mysql"]).ok_or("mysql client not found on this Mac")?,
            vec![
                "-h127.0.0.1".into(),
                format!("-P{}", s.port),
                "-uroot".into(),
            ],
        )),
        (None, "postgres") => Ok((
            host_tool(&["psql"]).ok_or("psql not found on this Mac")?,
            vec![
                "-h".into(),
                "127.0.0.1".into(),
                "-p".into(),
                s.port.to_string(),
                "-w".into(),
                "-q".into(),
                "-v".into(),
                "ON_ERROR_STOP=1".into(),
                "-d".into(),
                "postgres".into(),
            ],
        )),
        _ => Err("unknown snapshot kind".into()),
    }
}

/// User databases on an endpoint (system schemas left out), asked the same way a dump runs.
pub fn databases(e: &Endpoint, home: &Path) -> Result<Vec<String>, String> {
    let (program, args) = match (&e.container, e.kind) {
        (Some(c), "mysql") if valid_container(c) => (
            docker_cli(home).ok_or("docker CLI not found")?,
            vec![
                "exec".into(),
                c.clone(),
                "sh".into(),
                "-c".into(),
                format!(r#"{MYSQL_ENV}exec "$(command -v mariadb || command -v mysql)" -u"$U" -N -e 'SHOW DATABASES'"#),
            ],
        ),
        (Some(c), "postgres") if valid_container(c) => (
            docker_cli(home).ok_or("docker CLI not found")?,
            vec![
                "exec".into(),
                c.clone(),
                "sh".into(),
                "-c".into(),
                r#"exec psql -At -U "${POSTGRES_USER:-postgres}" -d postgres -c 'select datname from pg_database where not datistemplate'"#.into(),
            ],
        ),
        _ => return Err("list the databases from the Databases page".into()),
    };
    let out = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr)
            .trim()
            .chars()
            .take(300)
            .collect());
    }
    const SYSTEM: [&str; 5] = [
        "information_schema",
        "performance_schema",
        "mysql",
        "sys",
        "postgres",
    ];
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|d| !d.is_empty() && !SYSTEM.contains(d))
        .map(str::to_string)
        .collect())
}

fn meta_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.json"))
}

/// Dumps `database` and gzips it into `dir`; blocks until done.
pub fn create(
    e: &Endpoint,
    database: &str,
    dir: &Path,
    home: &Path,
    now: i64,
) -> Result<Snapshot, String> {
    if !valid_name(database) {
        return Err(format!("invalid database name: {database:?}"));
    }
    if let Some(c) = &e.container
        && !valid_container(c)
    {
        return Err("invalid container name".into());
    }
    let (program, args) = dump_command(e, database, home)?;
    std::fs::create_dir_all(dir).map_err(|err| err.to_string())?;
    let id = format!(
        "{}-{}-{}",
        e.container.as_deref().unwrap_or(e.kind),
        database,
        crate::local_format(now).replace([' ', ':'], "-"),
    );
    // Seconds too: two snapshots in the same minute must not overwrite each other.
    let id = format!("{id}-{:02}", now.rem_euclid(60));
    let file = dir.join(format!("{id}.sql.gz"));
    let out = std::fs::File::create(&file).map_err(|err| err.to_string())?;
    let mut gzip = Command::new("/usr/bin/gzip")
        .arg("-c")
        .stdin(Stdio::piped())
        .stdout(out)
        .spawn()
        .map_err(|err| err.to_string())?;
    let mut dump = Command::new(&program)
        .args(&args)
        .env("PGCONNECT_TIMEOUT", "5")
        .stdin(Stdio::null())
        .stdout(gzip.stdin.take().ok_or("gzip pipe")?)
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| err.to_string())?;
    let mut stderr = String::new();
    if let Some(mut pipe) = dump.stderr.take() {
        use std::io::Read;
        let _ = pipe.read_to_string(&mut stderr);
    }
    let dumped = dump.wait().map_err(|err| err.to_string())?;
    let zipped = gzip.wait().map_err(|err| err.to_string())?;
    if !dumped.success() || !zipped.success() {
        let _ = std::fs::remove_file(&file);
        let reason: String = stderr
            .lines()
            .filter(|l| !l.contains("Using a password"))
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(400)
            .collect();
        return Err(if reason.is_empty() {
            "dump failed".into()
        } else {
            reason
        });
    }
    let snapshot = Snapshot {
        id: id.clone(),
        kind: e.kind.into(),
        label: e.label.clone(),
        container: e.container.clone(),
        port: e.port,
        database: database.into(),
        created: now,
        bytes: std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0),
        file: file.to_string_lossy().into_owned(),
    };
    let json = serde_json::to_vec_pretty(&snapshot).map_err(|err| err.to_string())?;
    std::fs::write(meta_path(dir, &id), json).map_err(|err| err.to_string())?;
    Ok(snapshot)
}

/// Saved snapshots, newest first.
pub fn list(dir: &Path) -> Vec<Snapshot> {
    let mut all: Vec<Snapshot> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
        .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
        .filter(|s: &Snapshot| Path::new(&s.file).is_file())
        .collect();
    all.sort_by_key(|s| std::cmp::Reverse(s.created));
    all
}
pub fn find(dir: &Path, id: &str) -> Option<Snapshot> {
    list(dir).into_iter().find(|s| s.id == id)
}

/// Puts the database back to the snapshot: the dump drops and recreates it.
pub fn restore(s: &Snapshot, home: &Path) -> Result<(), String> {
    if !valid_name(&s.database) || s.container.as_deref().is_some_and(|c| !valid_container(c)) {
        return Err("invalid snapshot".into());
    }
    let (program, args) = restore_command(s, home)?;
    let mut unzip = Command::new("/usr/bin/gzip")
        .args(["-dc", &s.file])
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| e.to_string())?;
    let out = Command::new(program)
        .args(args)
        .stdin(unzip.stdout.take().ok_or("gzip pipe")?)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| e.to_string())?;
    let _ = unzip.wait();
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .filter(|l| !l.contains("Using a password"))
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(400)
            .collect())
    }
}

/// Removes a snapshot's dump and its record.
pub fn delete(dir: &Path, id: &str) -> Result<(), String> {
    let s = find(dir, id).ok_or("no such snapshot")?;
    std::fs::remove_file(&s.file).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(meta_path(dir, id));
    Ok(())
}

/// Writes a snapshot record for tests and imports.
pub fn record(dir: &Path, s: &Snapshot) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    std::fs::File::create(meta_path(dir, &s.id))?
        .write_all(&serde_json::to_vec(s).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn endpoint(kind: &'static str, container: Option<&str>) -> Endpoint {
        Endpoint {
            kind,
            port: 3306,
            label: "db".into(),
            container: container.map(str::to_string),
        }
    }

    #[test]
    fn names_are_checked_and_passed_as_arguments() {
        assert!(valid_name("shop_dev") && valid_name("app-test"));
        assert!(!valid_name("x; DROP") && !valid_name("") && !valid_name("a b"));
        let home = Path::new("/nonexistent-home");
        let e = endpoint("mysql", Some("shop-mysql-1"));
        if let Ok((_, args)) = dump_command(&e, "shop_dev", home) {
            assert_eq!(
                args.last().unwrap(),
                "shop_dev",
                "the name is $1, not part of the script"
            );
            assert!(!args[4].contains("shop_dev"));
            assert!(args[4].contains("--add-drop-database"));
            assert!(
                args[4].contains("MYSQL_PWD"),
                "password only through the environment"
            );
        }
        let err = create(&e, "x; DROP DATABASE y", Path::new("/tmp"), home, 0).unwrap_err();
        assert!(err.contains("invalid database name"));
        assert!(create(&endpoint("redis", None), "db", Path::new("/tmp"), home, 0).is_err());
    }

    #[test]
    fn list_skips_records_without_their_dump() {
        let dir = std::env::temp_dir().join(format!("corescope-snap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dump = dir.join("a.sql.gz");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&dump, b"x").unwrap();
        let mk = |id: &str, created, file: &Path| Snapshot {
            id: id.into(),
            kind: "mysql".into(),
            label: "db".into(),
            container: Some("c".into()),
            port: 3306,
            database: "shop".into(),
            created,
            bytes: 1,
            file: file.to_string_lossy().into_owned(),
        };
        record(&dir, &mk("old", 1, &dump)).unwrap();
        record(&dir, &mk("new", 2, &dump)).unwrap();
        record(&dir, &mk("gone", 3, &dir.join("missing.sql.gz"))).unwrap();
        let ids: Vec<_> = list(&dir).into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["new", "old"]);
        delete(&dir, "old").unwrap();
        assert!(!dump.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
