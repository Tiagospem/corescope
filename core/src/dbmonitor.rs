//! Watching a database for changes while you use the app it serves: what a sign-up, a job or a
//! test wrote — created rows with all their values, updated rows with what changed, deleted
//! rows with their key — table by table, without triggers, binlog or any change to the server.
//!
//! - The watched tables' rows are kept in memory by primary key (tables above `max_rows` keep
//!   only their row count and highest integer key: new rows are still shown).
//! - Every tick (1.5 s by default) one cheap query says which tables changed: MySQL/MariaDB
//!   `information_schema.TABLES` (UPDATE_TIME, row estimate; MariaDB without UPDATE_TIME: a
//!   CHECKSUM of the small tables), PostgreSQL `pg_stat_user_tables` (insert/update/delete
//!   counters). Only those tables are read again and compared with what was kept.
//! - Ignored tables (audits, sessions, cache…) are not read at all; the project's
//!   `.corescope.yml` (`databases.<name>.ignore_changes`) gives the default list.
//! - A snapshot saves the kept rows to a file; comparing reads the tables again and lists what
//!   differs from it.
//! - Queries go through the server's own client, inside its container with its credentials
//!   (or with the saved password for a server on the Mac), like the rest of the Databases page.
use crate::databases::Endpoint;
use crate::dumprestore::{Request, query, safe_word};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// One row that changed.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Change {
    pub seq: u64,
    /// Changes found in the same tick share a batch.
    pub batch: u64,
    pub at: i64,
    pub table: String,
    /// created, updated or deleted; "changed" for a large table whose rows are not kept.
    pub op: String,
    /// The primary key's values ("12", "3,7").
    pub key: String,
    pub columns: Vec<String>,
    pub before: Option<Vec<Value>>,
    pub after: Option<Vec<Value>>,
    /// Updated columns.
    pub changed: Vec<String>,
    /// A large table: rows added since (no details for updates or deletes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

/// A table as kept: its columns, key and rows.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Kept {
    pub columns: Vec<String>,
    /// Indexes of the primary key columns (empty: the whole row is the key).
    pub key: Vec<usize>,
    /// key → row values; empty for a large table.
    pub rows: BTreeMap<String, Vec<Value>>,
    /// More rows than kept: only the count and the highest integer key are followed.
    pub large: bool,
    pub count: u64,
    pub max_key: Option<i64>,
}

fn key_of(row: &[Value], key: &[usize]) -> String {
    if key.is_empty() {
        return Value::Array(row.to_vec()).to_string();
    }
    key.iter()
        .map(|&i| match row.get(i) {
            Some(Value::String(s)) => s.clone(),
            Some(v) => v.to_string(),
            None => String::new(),
        })
        .collect::<Vec<_>>()
        .join(",")
}

/// Long values cut, so a change list stays readable (and small).
fn trimmed(row: &[Value]) -> Vec<Value> {
    row.iter()
        .map(|v| match v {
            Value::String(s) if s.chars().count() > 2000 => {
                let head: String = s.chars().take(2000).collect();
                Value::String(format!("{head}… (+{} chars)", s.chars().count() - 2000))
            }
            other => other.clone(),
        })
        .collect()
}

/// What changed in one table between two readings of its rows.
pub fn diff(
    table: &str,
    columns: &[String],
    old: &BTreeMap<String, Vec<Value>>,
    new: &BTreeMap<String, Vec<Value>>,
) -> Vec<Change> {
    let mut out = Vec::new();
    let change = |op: &str,
                  key: &str,
                  before: Option<&Vec<Value>>,
                  after: Option<&Vec<Value>>,
                  changed: Vec<String>| Change {
        seq: 0,
        batch: 0,
        at: 0,
        table: table.into(),
        op: op.into(),
        key: key.into(),
        columns: columns.to_vec(),
        before: before.map(|r| trimmed(r)),
        after: after.map(|r| trimmed(r)),
        changed,
        note: None,
    };
    for (k, row) in new {
        match old.get(k) {
            None => out.push(change("created", k, None, Some(row), vec![])),
            Some(prev) if prev != row => {
                let changed = columns
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| prev.get(*i) != row.get(*i))
                    .map(|(_, c)| c.clone())
                    .collect();
                out.push(change("updated", k, Some(prev), Some(row), changed));
            }
            _ => {}
        }
    }
    for (k, row) in old {
        if !new.contains_key(k) {
            out.push(change("deleted", k, Some(row), None, vec![]));
        }
    }
    out
}

// MARK: reading

fn quote(kind: &str, name: &str) -> String {
    if kind == "mysql" {
        format!("`{}`", name.replace('`', "``"))
    } else {
        // schema.table
        name.split('.')
            .map(|p| format!("\"{}\"", p.replace('"', "\"\"")))
            .collect::<Vec<_>>()
            .join(".")
    }
}
fn lit(s: &str) -> String {
    format!("'{}'", s.replace('\\', "\\\\").replace('\'', "''"))
}

/// Tables: their columns, primary key column indexes and estimated rows.
type Schema = BTreeMap<String, (Vec<String>, Vec<usize>, u64)>;

struct Server<'a> {
    e: &'a Endpoint,
    req: Request,
    database: String,
    home: PathBuf,
    mariadb: bool,
}
impl Server<'_> {
    fn q(&self, sql: &str) -> Result<String, String> {
        let db = if self.e.kind == "mysql" {
            None
        } else {
            Some(self.database.as_str())
        };
        query(self.e, &self.req, db, sql, &self.home)
    }
    /// Tables with their columns, primary key and estimated rows.
    fn tables(&self) -> Result<Schema, String> {
        let mut out: Schema = BTreeMap::new();
        let db = lit(&self.database);
        let (cols, keys, sizes) = if self.e.kind == "mysql" {
            (
                format!(
                    "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_KEY = 'PRI' FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME AND t.TABLE_TYPE = 'BASE TABLE' WHERE c.TABLE_SCHEMA = {db} ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION"
                ),
                String::new(),
                format!(
                    "SELECT TABLE_NAME, IFNULL(TABLE_ROWS, 0) FROM information_schema.TABLES WHERE TABLE_SCHEMA = {db} AND TABLE_TYPE = 'BASE TABLE'"
                ),
            )
        } else {
            (
                "select c.table_schema || '.' || c.table_name, c.column_name, 0 from information_schema.columns c join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE' where c.table_schema not in ('pg_catalog', 'information_schema') order by 1, c.ordinal_position".into(),
                "select tc.table_schema || '.' || tc.table_name, k.column_name from information_schema.table_constraints tc join information_schema.key_column_usage k on k.constraint_schema = tc.constraint_schema and k.constraint_name = tc.constraint_name where tc.constraint_type = 'PRIMARY KEY'".into(),
                "select n.nspname || '.' || c.relname, greatest(c.reltuples, 0)::bigint from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind in ('r', 'p') and n.nspname not in ('pg_catalog', 'information_schema')".into(),
            )
        };
        let sep = if self.e.kind == "mysql" { '\t' } else { '|' };
        let mut pk: HashMap<String, Vec<String>> = HashMap::new();
        for line in self.q(&cols)?.lines() {
            let mut p = line.split(sep);
            let (Some(t), Some(c)) = (p.next(), p.next()) else {
                continue;
            };
            let e = out.entry(t.to_string()).or_default();
            if p.next() == Some("1") {
                pk.entry(t.to_string()).or_default().push(c.to_string());
            }
            e.0.push(c.to_string());
        }
        if !keys.is_empty() {
            for line in self.q(&keys)?.lines() {
                if let Some((t, c)) = line.split_once(sep) {
                    pk.entry(t.to_string()).or_default().push(c.to_string());
                }
            }
        }
        for line in self.q(&sizes)?.lines() {
            if let Some((t, n)) = line.split_once(sep)
                && let Some(e) = out.get_mut(t)
            {
                e.2 = n.trim().parse().unwrap_or(0);
            }
        }
        for (t, e) in out.iter_mut() {
            e.1 = pk
                .get(t)
                .map(|cols| {
                    cols.iter()
                        .filter_map(|c| e.0.iter().position(|x| x == c))
                        .collect()
                })
                .unwrap_or_default();
        }
        Ok(out)
    }
    /// The rows of some tables: table → key → values (at most `limit` + 1 each).
    fn rows(
        &self,
        tables: &[(&str, &[String], &[usize])],
        limit: u64,
    ) -> Result<HashMap<String, BTreeMap<String, Vec<Value>>>, String> {
        let mut out: HashMap<String, BTreeMap<String, Vec<Value>>> = HashMap::new();
        for chunk in tables.chunks(12) {
            let mut sql = String::new();
            for (t, cols, _) in chunk {
                if cols.is_empty() {
                    continue;
                }
                let list = cols
                    .iter()
                    .map(|c| {
                        quote(
                            if self.e.kind == "mysql" {
                                "mysql"
                            } else {
                                "postgres"
                            },
                            c,
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                if self.e.kind == "mysql" {
                    sql.push_str(&format!(
                        "SELECT {}, JSON_ARRAY({list}) FROM {}.{} LIMIT {};\n",
                        lit(t),
                        quote("mysql", &self.database),
                        quote("mysql", t),
                        limit + 1
                    ));
                } else {
                    sql.push_str(&format!(
                        "select {} || chr(9) || json_build_array({list})::text from {} limit {};\n",
                        lit(t),
                        quote("postgres", t),
                        limit + 1
                    ));
                }
            }
            if sql.is_empty() {
                continue;
            }
            for line in self.q(&sql)?.lines() {
                let Some((t, json)) = line.split_once('\t') else {
                    continue;
                };
                let Ok(Value::Array(row)) = serde_json::from_str::<Value>(json) else {
                    continue;
                };
                let key = chunk
                    .iter()
                    .find(|(name, _, _)| *name == t)
                    .map(|c| c.2)
                    .unwrap_or(&[]);
                out.entry(t.to_string())
                    .or_default()
                    .insert(key_of(&row, key), row);
            }
        }
        Ok(out)
    }
    /// Count and highest integer key of a large table.
    fn count(&self, table: &str, key: Option<&str>) -> Result<(u64, Option<i64>), String> {
        let t = if self.e.kind == "mysql" {
            format!(
                "{}.{}",
                quote("mysql", &self.database),
                quote("mysql", table)
            )
        } else {
            quote("postgres", table)
        };
        let max = key
            .map(|k| format!("MAX({})", quote(self.e.kind, k)))
            .unwrap_or_else(|| "NULL".into());
        let out = self.q(&format!("SELECT COUNT(*), {max} FROM {t}"))?;
        let line = out.lines().next().unwrap_or("");
        let mut p = line.split(['\t', '|']);
        let n = p.next().and_then(|v| v.trim().parse().ok()).unwrap_or(0);
        let m = p.next().and_then(|v| v.trim().parse().ok());
        Ok((n, m))
    }
    /// Rows of a large table above an integer key (the new ones).
    fn rows_after(
        &self,
        table: &str,
        cols: &[String],
        key: &[usize],
        after: i64,
        limit: u64,
    ) -> Result<BTreeMap<String, Vec<Value>>, String> {
        let Some(&k) = key.first() else {
            return Ok(BTreeMap::new());
        };
        let list = cols
            .iter()
            .map(|c| quote(self.e.kind, c))
            .collect::<Vec<_>>()
            .join(", ");
        let kc = quote(self.e.kind, &cols[k]);
        let sql = if self.e.kind == "mysql" {
            format!(
                "SELECT 'x', JSON_ARRAY({list}) FROM {}.{} WHERE {kc} > {after} ORDER BY {kc} LIMIT {limit}",
                quote("mysql", &self.database),
                quote("mysql", table)
            )
        } else {
            format!(
                "select 'x' || chr(9) || json_build_array({list})::text from {} where {kc} > {after} order by {kc} limit {limit}",
                quote("postgres", table)
            )
        };
        let mut out = BTreeMap::new();
        for line in self.q(&sql)?.lines() {
            if let Some((_, json)) = line.split_once('\t')
                && let Ok(Value::Array(row)) = serde_json::from_str::<Value>(json)
            {
                out.insert(key_of(&row, key), row);
            }
        }
        Ok(out)
    }
    /// A signature per table that moves when it is written, and the server's clock.
    fn signals(&self, small: &[String]) -> Result<(HashMap<String, String>, i64), String> {
        let mut out = HashMap::new();
        let db = lit(&self.database);
        if self.e.kind == "mysql" {
            let set = if self.mariadb {
                ""
            } else {
                "SET SESSION information_schema_stats_expiry = 0; "
            };
            let text = self.q(&format!(
                "{set}SELECT TABLE_NAME, IFNULL(UNIX_TIMESTAMP(UPDATE_TIME), -1), IFNULL(TABLE_ROWS, 0), UNIX_TIMESTAMP() FROM information_schema.TABLES WHERE TABLE_SCHEMA = {db} AND TABLE_TYPE = 'BASE TABLE'"
            ))?;
            let mut now = 0;
            let mut any_time = false;
            for line in text.lines() {
                let p: Vec<&str> = line.split('\t').collect();
                if p.len() < 4 {
                    continue;
                }
                any_time |= p[1] != "-1";
                now = p[3].trim().parse().unwrap_or(now);
                out.insert(p[0].to_string(), format!("{}:{}", p[1], p[2]));
            }
            // No UPDATE_TIME (MariaDB, some engines): a checksum of the small tables.
            if !any_time && !small.is_empty() {
                for chunk in small.chunks(40) {
                    let list = chunk
                        .iter()
                        .map(|t| {
                            format!("{}.{}", quote("mysql", &self.database), quote("mysql", t))
                        })
                        .collect::<Vec<_>>()
                        .join(", ");
                    for line in self.q(&format!("CHECKSUM TABLE {list}"))?.lines() {
                        if let Some((t, sum)) = line.split_once('\t') {
                            let t = t.rsplit('.').next().unwrap_or(t).to_string();
                            out.entry(t)
                                .and_modify(|v| *v = format!("{v}:{sum}"))
                                .or_insert_with(|| sum.to_string());
                        }
                    }
                }
            }
            Ok((out, now))
        } else {
            let text = self.q("select schemaname || '.' || relname, n_tup_ins || ':' || n_tup_upd || ':' || n_tup_del, extract(epoch from now())::bigint from pg_stat_user_tables")?;
            let mut now = 0;
            for line in text.lines() {
                let p: Vec<&str> = line.split('|').collect();
                if p.len() < 3 {
                    continue;
                }
                now = p[2].trim().parse().unwrap_or(now);
                out.insert(p[0].to_string(), p[1].to_string());
            }
            Ok((out, now))
        }
    }
}

// MARK: watches

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WatchRequest {
    pub database: String,
    /// Tables not read nor shown; missing: the project's `ignore_changes`.
    #[serde(default)]
    pub ignore: Option<Vec<String>>,
    #[serde(default)]
    pub interval_ms: Option<u64>,
    /// Tables with more rows keep only their count and highest key.
    #[serde(default)]
    pub max_rows: Option<u64>,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default, skip_serializing)]
    pub password: Option<String>,
}

#[derive(Clone, Debug, Serialize, Default)]
pub struct WatchStatus {
    pub id: String,
    pub database: String,
    pub server: String,
    /// starting, watching, stopped, failed.
    pub state: String,
    pub error: Option<String>,
    pub started: i64,
    pub tables: usize,
    /// Every table of the database (to choose which to ignore).
    pub table_names: Vec<String>,
    pub large_tables: Vec<String>,
    pub ignored: Vec<String>,
    /// The project's default ignores (from .corescope.yml).
    pub default_ignored: Vec<String>,
    pub last_seq: u64,
    pub changes: Vec<Change>,
}

pub struct Watch {
    status: Mutex<WatchStatus>,
    kept: Mutex<HashMap<String, Kept>>,
    changes: Mutex<Vec<Change>>,
    ignore: Mutex<HashSet<String>>,
    stop: AtomicBool,
    seq: AtomicU64,
    endpoint: Endpoint,
    req: WatchRequest,
    home: PathBuf,
}
fn watches() -> &'static Mutex<Vec<Arc<Watch>>> {
    static W: OnceLock<Mutex<Vec<Arc<Watch>>>> = OnceLock::new();
    W.get_or_init(|| Mutex::new(Vec::new()))
}
fn find(id: &str) -> Option<Arc<Watch>> {
    watches()
        .lock()
        .ok()?
        .iter()
        .find(|w| w.status.lock().map(|s| s.id == id).unwrap_or(false))
        .cloned()
}

impl Watch {
    fn server(&self) -> Server<'_> {
        Server {
            e: &self.endpoint,
            req: Request::credentials(self.req.user.as_deref(), self.req.password.as_deref()),
            database: self.req.database.clone(),
            home: self.home.clone(),
            mariadb: self
                .status
                .lock()
                .map(|s| s.server.contains("MariaDB"))
                .unwrap_or(false),
        }
    }
    fn set(&self, f: impl FnOnce(&mut WatchStatus)) {
        if let Ok(mut s) = self.status.lock() {
            f(&mut s);
        }
    }
    fn push(&self, mut list: Vec<Change>, now: i64) {
        if list.is_empty() {
            return;
        }
        let batch = self.seq.load(Ordering::Relaxed) + 1;
        let mut all = self.changes.lock().unwrap_or_else(|p| p.into_inner());
        for c in list.iter_mut() {
            c.seq = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
            c.batch = batch;
            c.at = now;
        }
        all.extend(list);
        let over = all.len().saturating_sub(5000);
        if over > 0 {
            all.drain(..over);
        }
        let last = self.seq.load(Ordering::Relaxed);
        drop(all);
        self.set(|s| s.last_seq = last);
    }
    /// Reads a table and keeps it (rows, or count and highest key when large).
    fn keep(
        &self,
        srv: &Server,
        name: &str,
        cols: &[String],
        key: &[usize],
        estimate: u64,
        limit: u64,
    ) -> Result<Kept, String> {
        let mut k = Kept {
            columns: cols.to_vec(),
            key: key.to_vec(),
            ..Kept::default()
        };
        if estimate > limit {
            k.large = true;
            let int_key = (key.len() == 1).then(|| cols[key[0]].as_str());
            let (n, m) = srv.count(name, int_key)?;
            k.count = n;
            k.max_key = m;
            return Ok(k);
        }
        let mut rows = srv.rows(&[(name, cols, key)], limit)?;
        k.rows = rows.remove(name).unwrap_or_default();
        if k.rows.len() as u64 > limit {
            return self.keep(srv, name, cols, key, limit + 1, limit);
        }
        k.count = k.rows.len() as u64;
        Ok(k)
    }
    fn run(self: Arc<Self>) {
        let limit = self.req.max_rows.unwrap_or(50_000).clamp(100, 1_000_000);
        let interval =
            Duration::from_millis(self.req.interval_ms.unwrap_or(1500).clamp(500, 60_000));
        let srv = self.server();
        let version = srv.q("SELECT VERSION()").unwrap_or_default();
        self.set(|s| {
            if version.contains("MariaDB") {
                s.server = format!("{} (MariaDB)", s.server);
            }
        });
        let srv = self.server();
        let tables = match srv.tables() {
            Ok(t) => t,
            Err(e) => {
                self.set(|s| {
                    s.state = "failed".into();
                    s.error = Some(e);
                });
                return;
            }
        };
        let ignore = self.ignore.lock().map(|i| i.clone()).unwrap_or_default();
        // The first reading: everything not ignored.
        let small: Vec<(&str, &[String], &[usize])> = tables
            .iter()
            .filter(|(t, e)| !ignore.contains(*t) && e.2 <= limit)
            .map(|(t, e)| (t.as_str(), e.0.as_slice(), e.1.as_slice()))
            .collect();
        let mut kept: HashMap<String, Kept> = HashMap::new();
        match srv.rows(&small, limit) {
            Ok(mut rows) => {
                for (t, cols, key) in &small {
                    let r = rows.remove(*t).unwrap_or_default();
                    if r.len() as u64 > limit {
                        if let Ok(k) = self.keep(&srv, t, cols, key, limit + 1, limit) {
                            kept.insert(t.to_string(), k);
                        }
                        continue;
                    }
                    kept.insert(
                        t.to_string(),
                        Kept {
                            columns: cols.to_vec(),
                            key: key.to_vec(),
                            count: r.len() as u64,
                            rows: r,
                            ..Kept::default()
                        },
                    );
                }
            }
            Err(e) => {
                self.set(|s| {
                    s.state = "failed".into();
                    s.error = Some(e);
                });
                return;
            }
        }
        for (t, e) in tables
            .iter()
            .filter(|(t, e)| !ignore.contains(*t) && e.2 > limit)
        {
            if let Ok(k) = self.keep(&srv, t, &e.0, &e.1, e.2, limit) {
                kept.insert(t.clone(), k);
            }
        }
        let large: Vec<String> = kept
            .iter()
            .filter(|(_, k)| k.large)
            .map(|(t, _)| t.clone())
            .collect();
        if let Ok(mut k) = self.kept.lock() {
            *k = kept;
        }
        self.set(|s| {
            s.state = "watching".into();
            s.tables = tables.len();
            s.table_names = tables.keys().cloned().collect();
            s.large_tables = large;
        });
        let small_names: Vec<String> = tables
            .iter()
            .filter(|(_, e)| e.2 <= limit)
            .map(|(t, _)| t.clone())
            .collect();
        let mut last: HashMap<String, String> = HashMap::new();
        let mut recheck: HashSet<String> = HashSet::new();
        let mut first = true;
        while !self.stop.load(Ordering::Relaxed) {
            let tick = Instant::now();
            let ignore = self.ignore.lock().map(|i| i.clone()).unwrap_or_default();
            match srv.signals(&small_names) {
                Err(e) => self.set(|s| s.error = Some(e)),
                Ok((sig, now)) => {
                    self.set(|s| s.error = None);
                    let mut changed: Vec<String> = Vec::new();
                    for (t, v) in &sig {
                        if ignore.contains(t) {
                            continue;
                        }
                        let moved = last.get(t).is_some_and(|old| old != v);
                        // UPDATE_TIME has one-second steps: a table written in the last two
                        // seconds is read again on the next tick.
                        let recent = self.endpoint.kind == "mysql"
                            && v.split(':')
                                .next()
                                .and_then(|x| x.parse::<i64>().ok())
                                .is_some_and(|u| u >= 0 && now - u <= 2);
                        if !first && (moved || recheck.contains(t)) {
                            changed.push(t.clone());
                        }
                        if recent {
                            recheck.insert(t.clone());
                        } else {
                            recheck.remove(t);
                        }
                    }
                    last = sig;
                    first = false;
                    let found = self.compare(&srv, &changed, &tables, limit);
                    self.push(found, now);
                }
            }
            let rest = interval.saturating_sub(tick.elapsed());
            let until = Instant::now() + rest;
            while Instant::now() < until && !self.stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        self.set(|s| s.state = "stopped".into());
    }
    /// Reads `tables` again and compares them with what was kept (and keeps the new reading).
    fn compare(&self, srv: &Server, tables: &[String], schema: &Schema, limit: u64) -> Vec<Change> {
        let mut out = Vec::new();
        for t in tables {
            let Some((cols, key, _)) = schema.get(t) else {
                continue;
            };
            let prev = self.kept.lock().ok().and_then(|k| k.get(t).cloned());
            let Some(prev) = prev else {
                // A table shown again after being ignored: read it now, report from the next change.
                if let Ok(k) = self.keep(srv, t, cols, key, 0, limit)
                    && let Ok(mut all) = self.kept.lock()
                {
                    all.insert(t.clone(), k);
                }
                continue;
            };
            if prev.large {
                let int_key = (key.len() == 1).then(|| cols[key[0]].as_str());
                let Ok((n, m)) = srv.count(t, int_key) else {
                    continue;
                };
                if let (Some(old), Some(_)) = (prev.max_key, m)
                    && let Ok(rows) = srv.rows_after(t, cols, key, old, 200)
                {
                    for (k, row) in &rows {
                        let mut c = diff(
                            t,
                            cols,
                            &BTreeMap::new(),
                            &BTreeMap::from([(k.clone(), row.clone())]),
                        );
                        out.append(&mut c);
                    }
                }
                if n != prev.count && prev.max_key == m {
                    out.push(Change {
                        seq: 0,
                        batch: 0,
                        at: 0,
                        table: t.clone(),
                        op: "changed".into(),
                        key: String::new(),
                        columns: vec![],
                        before: None,
                        after: None,
                        changed: vec![],
                        note: Some(format!(
                            "{} → {} rows (large table: rows are not kept)",
                            prev.count, n
                        )),
                    });
                }
                if let Ok(mut all) = self.kept.lock()
                    && let Some(k) = all.get_mut(t)
                {
                    k.count = n;
                    k.max_key = m.or(k.max_key);
                }
                continue;
            }
            let Ok(mut rows) = srv.rows(&[(t.as_str(), cols.as_slice(), key.as_slice())], limit)
            else {
                continue;
            };
            let now_rows = rows.remove(t).unwrap_or_default();
            out.extend(diff(t, cols, &prev.rows, &now_rows));
            if let Ok(mut all) = self.kept.lock()
                && let Some(k) = all.get_mut(t)
            {
                k.count = now_rows.len() as u64;
                k.rows = now_rows;
            }
        }
        out
    }
}

/// Starts watching; the project's `ignore_changes` apply when `ignore` is missing.
pub fn start(req: WatchRequest, e: Endpoint, home: PathBuf) -> Result<String, String> {
    if !safe_word(&req.database) {
        return Err("invalid database name".into());
    }
    let defaults = crate::dumprestore::database_spec(&req.database, &e, &home)
        .map(|(_, _, s)| s.ignore_changes)
        .unwrap_or_default();
    let ignore: HashSet<String> = req
        .ignore
        .clone()
        .unwrap_or_else(|| defaults.clone())
        .into_iter()
        .collect();
    static N: AtomicU64 = AtomicU64::new(0);
    let id = format!(
        "watch-{}-{}",
        crate::now() as u64,
        N.fetch_add(1, Ordering::Relaxed)
    );
    let mut ignored: Vec<String> = ignore.iter().cloned().collect();
    ignored.sort();
    let watch = Arc::new(Watch {
        status: Mutex::new(WatchStatus {
            id: id.clone(),
            database: req.database.clone(),
            server: e.label.clone(),
            state: "starting".into(),
            started: crate::now() as i64,
            ignored,
            default_ignored: defaults,
            ..WatchStatus::default()
        }),
        kept: Mutex::new(HashMap::new()),
        changes: Mutex::new(Vec::new()),
        ignore: Mutex::new(ignore),
        stop: AtomicBool::new(false),
        seq: AtomicU64::new(0),
        endpoint: e,
        req,
        home,
    });
    if let Ok(mut list) = watches().lock() {
        // Stopped ones go away (the latest 10 stay for their changes).
        let stopped: Vec<usize> = list
            .iter()
            .enumerate()
            .filter(|(_, w)| {
                w.status
                    .lock()
                    .map(|s| s.state == "stopped" || s.state == "failed")
                    .unwrap_or(true)
            })
            .map(|(i, _)| i)
            .collect();
        if stopped.len() > 10 {
            list.remove(stopped[0]);
        }
        list.push(watch.clone());
    }
    std::thread::spawn(move || watch.run());
    Ok(id)
}
/// The watch's state and the changes after `since` (at most 500).
pub fn status(id: &str, since: u64) -> Option<WatchStatus> {
    let w = find(id)?;
    let mut s = w.status.lock().ok()?.clone();
    if let Ok(all) = w.changes.lock() {
        s.changes = all
            .iter()
            .filter(|c| c.seq > since)
            .take(500)
            .cloned()
            .collect();
    }
    Some(s)
}
pub fn list() -> Vec<WatchStatus> {
    watches()
        .lock()
        .map(|l| {
            l.iter()
                .filter_map(|w| w.status.lock().ok().map(|s| s.clone()))
                .collect()
        })
        .unwrap_or_default()
}
pub fn stop(id: &str) -> bool {
    find(id)
        .map(|w| w.stop.store(true, Ordering::Relaxed))
        .is_some()
}
/// Forgets the changes shown so far (what is kept stays the current state).
pub fn clear(id: &str) -> bool {
    let Some(w) = find(id) else { return false };
    if let Ok(mut c) = w.changes.lock() {
        c.clear();
    }
    true
}
/// Replaces the ignored tables; a table shown again is read on its next change.
pub fn set_ignore(id: &str, tables: Vec<String>) -> Option<Vec<String>> {
    let w = find(id)?;
    let set: HashSet<String> = tables.into_iter().collect();
    if let Ok(mut kept) = w.kept.lock() {
        for t in &set {
            kept.remove(t);
        }
    }
    let mut list: Vec<String> = set.iter().cloned().collect();
    list.sort();
    if let Ok(mut i) = w.ignore.lock() {
        *i = set;
    }
    w.set(|s| s.ignored = list.clone());
    Some(list)
}

#[derive(Serialize, Deserialize)]
struct SnapshotFile {
    database: String,
    server: String,
    taken: i64,
    tables: HashMap<String, Kept>,
}
fn snapshot_dir(home: &Path) -> PathBuf {
    home.join("Library/Application Support/CoreScope/db-watch")
}
/// Saves what is kept (the current state of the watched tables) for a later comparison.
pub fn save(id: &str, name: Option<&str>) -> Result<serde_json::Value, String> {
    let w = find(id).ok_or("no such watch")?;
    let kept = w.kept.lock().map_err(|_| "busy")?.clone();
    let st = w.status.lock().map_err(|_| "busy")?.clone();
    let dir = snapshot_dir(&w.home);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let label: String = name
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
        .take(40)
        .collect();
    let stamp = crate::local_format(crate::now() as i64).replace([' ', ':'], "-");
    let file = dir.join(format!(
        "{}-{stamp}{}.json",
        st.database,
        if label.is_empty() {
            String::new()
        } else {
            format!("-{label}")
        }
    ));
    let body = SnapshotFile {
        database: st.database,
        server: st.server,
        taken: crate::now() as i64,
        tables: kept.into_iter().filter(|(_, k)| !k.large).collect(),
    };
    std::fs::write(&file, serde_json::to_vec(&body).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({"file": file, "tables": body.tables.len()}))
}
/// Saved snapshots of a database, newest first.
pub fn snapshots(home: &Path, database: Option<&str>) -> Vec<serde_json::Value> {
    let mut out: Vec<(i64, serde_json::Value)> = std::fs::read_dir(snapshot_dir(home))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let path = e.path();
            if path.extension().is_none_or(|x| x != "json") {
                return None;
            }
            let name = path.file_name()?.to_string_lossy().into_owned();
            if database.is_some_and(|d| !name.starts_with(&format!("{d}-"))) {
                return None;
            }
            let modified = e.metadata().ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
            Some((modified, serde_json::json!({"file": path, "name": name, "taken": modified, "bytes": e.metadata().ok()?.len()})))
        })
        .collect();
    out.sort_by_key(|(t, _)| std::cmp::Reverse(*t));
    out.into_iter().map(|(_, v)| v).collect()
}
/// What changed since a saved snapshot: its tables read now and compared.
pub fn compare(id: &str, file: &Path) -> Result<Vec<Change>, String> {
    let w = find(id).ok_or("no such watch")?;
    if !file.starts_with(snapshot_dir(&w.home)) {
        return Err("not a saved snapshot".into());
    }
    let snap: SnapshotFile =
        serde_json::from_slice(&std::fs::read(file).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
    if snap.database != w.req.database {
        return Err(format!("this snapshot is of {}", snap.database));
    }
    let srv = w.server();
    let ignore = w.ignore.lock().map(|i| i.clone()).unwrap_or_default();
    let mut names: Vec<&String> = snap
        .tables
        .keys()
        .filter(|t| !ignore.contains(*t))
        .collect();
    names.sort();
    let list: Vec<(&str, &[String], &[usize])> = names
        .iter()
        .map(|t| {
            (
                t.as_str(),
                snap.tables[*t].columns.as_slice(),
                snap.tables[*t].key.as_slice(),
            )
        })
        .collect();
    let mut now = srv.rows(&list, 1_000_000)?;
    let mut out = Vec::new();
    for t in names {
        let k = &snap.tables[t];
        out.extend(diff(
            t,
            &k.columns,
            &k.rows,
            &now.remove(t.as_str()).unwrap_or_default(),
        ));
    }
    for (i, c) in out.iter_mut().enumerate() {
        c.seq = i as u64 + 1;
        c.at = snap.taken;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rows(list: &[(&str, Value)]) -> BTreeMap<String, Vec<Value>> {
        list.iter()
            .map(|(k, v)| (k.to_string(), v.as_array().unwrap().clone()))
            .collect()
    }

    #[test]
    fn diff_finds_created_updated_and_deleted() {
        let cols: Vec<String> = ["id", "name", "email"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let old = rows(&[
            ("1", json!([1, "Ana", "a@x"])),
            ("2", json!([2, "Bia", "b@x"])),
            ("3", json!([3, "Caio", null])),
        ]);
        let new = rows(&[
            ("1", json!([1, "Ana", "a@x"])),
            ("2", json!([2, "Bia S", "b@x"])),
            ("4", json!([4, "Duda", "d@x"])),
        ]);
        let mut d = diff("users", &cols, &old, &new);
        d.sort_by(|a, b| a.key.cmp(&b.key));
        let ops: Vec<(&str, &str)> = d.iter().map(|c| (c.key.as_str(), c.op.as_str())).collect();
        assert_eq!(ops, [("2", "updated"), ("3", "deleted"), ("4", "created")]);
        assert_eq!(d[0].changed, ["name"]);
        assert_eq!(d[0].before.as_ref().unwrap()[1], json!("Bia"));
        assert_eq!(d[2].after.as_ref().unwrap()[2], json!("d@x"));
        assert!(d[1].after.is_none());
    }

    #[test]
    fn keys_and_long_values() {
        assert_eq!(key_of(&[json!(3), json!("x"), json!(7)], &[0, 2]), "3,7");
        assert_eq!(key_of(&[json!("a"), json!(1)], &[]), "[\"a\",1]");
        let long = "é".repeat(2500);
        let t = trimmed(&[json!(long)]);
        assert!(t[0].as_str().unwrap().ends_with("(+500 chars)"));
        assert_eq!(quote("postgres", "public.users"), "\"public\".\"users\"");
        assert_eq!(quote("mysql", "a`b"), "`a``b`");
        assert_eq!(lit("it's \\ ok"), "'it''s \\\\ ok'");
    }
}
