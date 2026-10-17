//! Opt-in persistent history: one-minute rollups in a local SQLite file, one transaction per
//! minute. Stores system aggregates and, per minute, the 10 processes with most CPU and most
//! memory (name, executable, working directory, origin). Never arguments or environment.
use crate::sqlite::{Db, Value};
use serde::Serialize;
use std::collections::HashMap;

pub const TOP: usize = 10;
const SCHEMA: &str = "PRAGMA auto_vacuum=INCREMENTAL;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS minutes(at INTEGER PRIMARY KEY, samples INTEGER NOT NULL,
 cpu REAL, cpu_max REAL, memory REAL, swap REAL, disk_read REAL, disk_write REAL,
 net_in REAL, net_out REAL, thermal INTEGER, pressure INTEGER, pressure_pct REAL);
CREATE TABLE IF NOT EXISTS procs(id INTEGER PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL,
 cwd TEXT NOT NULL, origin TEXT NOT NULL, UNIQUE(name, path, cwd, origin));
CREATE TABLE IF NOT EXISTS top(at INTEGER NOT NULL, kind INTEGER NOT NULL, rank INTEGER NOT NULL,
 proc INTEGER NOT NULL, cpu REAL, memory REAL, PRIMARY KEY(at, kind, rank)) WITHOUT ROWID;
PRAGMA user_version=1;";

/// `~/Library/Application Support/CoreScope/history.sqlite`.
pub fn default_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    format!("{home}/Library/Application Support/CoreScope/history.sqlite")
}
fn files(path: &str) -> [String; 4] {
    [
        path.to_string(),
        format!("{path}-wal"),
        format!("{path}-shm"),
        format!("{path}-journal"),
    ]
}

/// One live system sample, as already computed by the collector.
#[derive(Clone, Copy, Default)]
pub struct System {
    pub cpu: Option<f64>,
    pub memory: Option<f64>,
    pub swap: Option<f64>,
    pub disk_read: Option<f64>,
    pub disk_write: Option<f64>,
    pub net_in: Option<f64>,
    pub net_out: Option<f64>,
    /// ProcessInfo.thermalState 0–3.
    pub thermal: Option<i64>,
    /// Last Dispatch memory-pressure event 0–2.
    pub pressure: Option<i64>,
    pub pressure_pct: Option<f64>,
}
/// One live process; borrowed from the snapshot, copied only the first time it is seen.
pub struct Proc<'a> {
    pub key: (i32, u64),
    pub name: &'a str,
    pub path: &'a str,
    pub cwd: &'a str,
    pub origin: &'a str,
    pub cpu: Option<f64>,
    pub memory: Option<f64>,
}
#[derive(Default)]
struct Mean {
    sum: f64,
    n: u32,
}
impl Mean {
    fn add(&mut self, v: Option<f64>) {
        if let Some(v) = v {
            self.sum += v;
            self.n += 1;
        }
    }
    fn get(&self) -> Option<f64> {
        (self.n > 0).then(|| self.sum / self.n as f64)
    }
}
fn max<T: PartialOrd + Copy>(a: Option<T>, b: Option<T>) -> Option<T> {
    match (a, b) {
        (Some(x), Some(y)) => Some(if y > x { y } else { x }),
        (x, None) => x,
        (None, y) => y,
    }
}
struct ProcAcc {
    name: String,
    path: String,
    cwd: String,
    origin: String,
    cpu: f64,
    memory: f64,
}
#[derive(Default)]
struct Minute {
    at: i64,
    samples: u32,
    cpu: Mean,
    cpu_max: Option<f64>,
    memory: Mean,
    swap: Option<f64>,
    disk_read: Mean,
    disk_write: Mean,
    net_in: Mean,
    net_out: Mean,
    thermal: Option<i64>,
    pressure: Option<i64>,
    pressure_pct: Option<f64>,
    procs: HashMap<(i32, u64), ProcAcc>,
}
impl Minute {
    fn add<'a>(&mut self, s: System, procs: impl Iterator<Item = Proc<'a>>) {
        self.samples += 1;
        self.cpu.add(s.cpu);
        self.cpu_max = max(self.cpu_max, s.cpu);
        self.memory.add(s.memory);
        self.swap = max(self.swap, s.swap);
        self.disk_read.add(s.disk_read);
        self.disk_write.add(s.disk_write);
        self.net_in.add(s.net_in);
        self.net_out.add(s.net_out);
        self.thermal = max(self.thermal, s.thermal.filter(|v| *v >= 0));
        self.pressure = max(self.pressure, s.pressure.filter(|v| *v >= 0));
        self.pressure_pct = max(self.pressure_pct, s.pressure_pct);
        for p in procs {
            if p.cpu.is_none() && p.memory.is_none() {
                continue;
            }
            let acc = self.procs.entry(p.key).or_insert_with(|| ProcAcc {
                name: p.name.into(),
                path: p.path.into(),
                cwd: p.cwd.into(),
                origin: p.origin.into(),
                cpu: 0.,
                memory: 0.,
            });
            acc.cpu += p.cpu.unwrap_or(0.);
            acc.memory = acc.memory.max(p.memory.unwrap_or(0.));
        }
    }
    /// Top processes for the minute: CPU averaged over every sample of the minute (a process
    /// seen in one sample out of six weighs one sixth), memory as the peak footprint.
    fn ranked(&self, memory: bool) -> Vec<(&ProcAcc, f64)> {
        let n = self.samples.max(1) as f64;
        let mut all: Vec<(&ProcAcc, f64)> = self
            .procs
            .values()
            .map(|p| (p, if memory { p.memory } else { p.cpu / n }))
            .filter(|(_, v)| *v > 0.)
            .collect();
        all.sort_by(|a, b| b.1.total_cmp(&a.1));
        all.truncate(TOP);
        all
    }
}

/// Owns the write connection and the minute being accumulated.
#[derive(Default)]
pub struct Recorder {
    path: String,
    db: Option<Db>,
    minute: Option<Minute>,
    /// (minute of last purge, retention used), so a retention change purges at once.
    purged: Option<(i64, u32)>,
    cleaned: i64,
    pub error: Option<String>,
}
impl Recorder {
    pub fn new(path: &str) -> Self {
        Self {
            path: path.into(),
            ..Default::default()
        }
    }
    pub fn path(&self) -> &str {
        &self.path
    }
    pub fn set_path(&mut self, path: &str) {
        if self.path != path {
            self.db = None;
            self.minute = None;
            self.path = path.into();
        }
    }
    /// Adds a sample; when it belongs to a new minute the previous one is written first.
    pub fn add<'a>(
        &mut self,
        at: f64,
        days: u32,
        system: System,
        procs: impl Iterator<Item = Proc<'a>>,
    ) {
        let minute = (at / 60.).floor() as i64 * 60;
        if self.minute.as_ref().is_some_and(|m| m.at != minute) {
            self.flush(days);
        }
        self.minute
            .get_or_insert_with(|| Minute {
                at: minute,
                ..Default::default()
            })
            .add(system, procs);
    }
    /// Stops recording: the partial minute is discarded and the file is closed.
    pub fn disable(&mut self) {
        self.minute = None;
        self.db = None;
        self.purged = None;
        self.error = None;
    }
    pub fn delete(&mut self) -> Result<(), String> {
        self.disable();
        for f in files(&self.path) {
            match std::fs::remove_file(&f) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.to_string()),
                _ => {}
            }
        }
        Ok(())
    }
    /// Writes the pending minute (if any) in a single transaction.
    pub fn flush(&mut self, days: u32) {
        let Some(minute) = self.minute.take() else {
            return;
        };
        if let Err(e) = self.write(&minute, days) {
            self.error = Some(e);
            // Reopen on the next minute instead of reusing a connection in an unknown state.
            self.db = None;
        } else {
            self.error = None;
        }
    }
    fn open(&mut self) -> Result<&Db, String> {
        if self.db.is_none() {
            if let Some(dir) = std::path::Path::new(&self.path).parent() {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            }
            let db = Db::open(&self.path, false)?;
            db.exec(SCHEMA)?;
            self.db = Some(db);
        }
        Ok(self.db.as_ref().expect("opened above"))
    }
    fn write(&mut self, m: &Minute, days: u32) -> Result<(), String> {
        let purge = days > 0
            && self
                .purged
                .is_none_or(|(at, d)| d != days || m.at - at >= 3600);
        let clean = purge && m.at - self.cleaned >= 86400;
        let db = self.open()?;
        db.exec("BEGIN IMMEDIATE")?;
        let result = (|| {
            let old_samples = {
                let mut s = db.prepare("SELECT samples FROM minutes WHERE at=?")?;
                s.bind(&[Value::Int(m.at)])?;
                if s.step()? { s.int(0).unwrap_or(0) } else { 0 }
            };
            db.prepare(
                "INSERT INTO minutes VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                 ON CONFLICT(at) DO UPDATE SET
                 samples=minutes.samples+excluded.samples,
                 cpu=CASE WHEN minutes.cpu IS NULL THEN excluded.cpu
                   WHEN excluded.cpu IS NULL THEN minutes.cpu
                   ELSE (minutes.cpu*minutes.samples+excluded.cpu*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
                 cpu_max=CASE WHEN minutes.cpu_max IS NULL THEN excluded.cpu_max
                   WHEN excluded.cpu_max IS NULL THEN minutes.cpu_max
                   ELSE MAX(minutes.cpu_max,excluded.cpu_max) END,
                 memory=CASE WHEN minutes.memory IS NULL THEN excluded.memory
                   WHEN excluded.memory IS NULL THEN minutes.memory
                   ELSE (minutes.memory*minutes.samples+excluded.memory*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
                 swap=CASE WHEN minutes.swap IS NULL THEN excluded.swap
                   WHEN excluded.swap IS NULL THEN minutes.swap
                   ELSE MAX(minutes.swap,excluded.swap) END,
                 disk_read=CASE WHEN minutes.disk_read IS NULL THEN excluded.disk_read
                   WHEN excluded.disk_read IS NULL THEN minutes.disk_read
                   ELSE (minutes.disk_read*minutes.samples+excluded.disk_read*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
                 disk_write=CASE WHEN minutes.disk_write IS NULL THEN excluded.disk_write
                   WHEN excluded.disk_write IS NULL THEN minutes.disk_write
                   ELSE (minutes.disk_write*minutes.samples+excluded.disk_write*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
                 net_in=CASE WHEN minutes.net_in IS NULL THEN excluded.net_in
                   WHEN excluded.net_in IS NULL THEN minutes.net_in
                   ELSE (minutes.net_in*minutes.samples+excluded.net_in*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
                 net_out=CASE WHEN minutes.net_out IS NULL THEN excluded.net_out
                   WHEN excluded.net_out IS NULL THEN minutes.net_out
                   ELSE (minutes.net_out*minutes.samples+excluded.net_out*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
                 thermal=CASE WHEN minutes.thermal IS NULL THEN excluded.thermal
                   WHEN excluded.thermal IS NULL THEN minutes.thermal
                   ELSE MAX(minutes.thermal,excluded.thermal) END,
                 pressure=CASE WHEN minutes.pressure IS NULL THEN excluded.pressure
                   WHEN excluded.pressure IS NULL THEN minutes.pressure
                   ELSE MAX(minutes.pressure,excluded.pressure) END,
                 pressure_pct=CASE WHEN minutes.pressure_pct IS NULL THEN excluded.pressure_pct
                   WHEN excluded.pressure_pct IS NULL THEN minutes.pressure_pct
                   ELSE MAX(minutes.pressure_pct,excluded.pressure_pct) END",
            )?
            .run(&[
                Value::Int(m.at),
                Value::Int(m.samples as i64),
                Value::Real(m.cpu.get()),
                Value::Real(m.cpu_max),
                Value::Real(m.memory.get()),
                Value::Real(m.swap),
                Value::Real(m.disk_read.get()),
                Value::Real(m.disk_write.get()),
                Value::Real(m.net_in.get()),
                Value::Real(m.net_out.get()),
                m.thermal.map_or(Value::Real(None), Value::Int),
                m.pressure.map_or(Value::Real(None), Value::Int),
                Value::Real(m.pressure_pct),
            ])?;
            let mut insert =
                db.prepare("INSERT OR IGNORE INTO procs(name,path,cwd,origin) VALUES(?,?,?,?)")?;
            let mut find =
                db.prepare("SELECT id FROM procs WHERE name=? AND path=? AND cwd=? AND origin=?")?;
            let total_samples = (old_samples + m.samples as i64).max(1) as f64;
            let mut ranked = [Vec::new(), Vec::new()];
            for kind in [0, 1] {
                let mut entries: HashMap<i64, (f64, f64)> = HashMap::new();
                if old_samples > 0 {
                    let mut previous =
                        db.prepare("SELECT proc,cpu,memory FROM top WHERE at=? AND kind=?")?;
                    previous.bind(&[Value::Int(m.at), Value::Int(kind)])?;
                    while previous.step()? {
                        let id = previous.int(0).ok_or("Processo sem identificador")?;
                        entries.insert(
                            id,
                            (
                                previous.real(1).unwrap_or(0.) * old_samples as f64 / total_samples,
                                previous.real(2).unwrap_or(0.),
                            ),
                        );
                    }
                }
                for (p, _) in m.ranked(kind == 1) {
                    let key = [
                        Value::Text(&p.name),
                        Value::Text(&p.path),
                        Value::Text(&p.cwd),
                        Value::Text(&p.origin),
                    ];
                    insert.run(&key)?;
                    find.bind(&key)?;
                    let id = if find.step()? { find.int(0) } else { None }
                        .ok_or("Processo não registrado")?;
                    let entry = entries.entry(id).or_default();
                    entry.0 += p.cpu / total_samples;
                    entry.1 = entry.1.max(p.memory);
                }
                let mut list: Vec<_> = entries.into_iter().collect();
                list.sort_by(|a, b| {
                    let av = if kind == 0 { a.1.0 } else { a.1.1 };
                    let bv = if kind == 0 { b.1.0 } else { b.1.1 };
                    bv.total_cmp(&av)
                });
                list.retain(|(_, (cpu, memory))| if kind == 0 { *cpu > 0. } else { *memory > 0. });
                list.truncate(TOP);
                ranked[kind as usize] = list
                    .into_iter()
                    .map(|(id, (cpu, memory))| (id, cpu, memory))
                    .collect();
            }
            db.prepare("DELETE FROM top WHERE at=?")?
                .run(&[Value::Int(m.at)])?;
            let mut top = db.prepare("INSERT INTO top VALUES(?,?,?,?,?,?)")?;
            for (kind, list) in ranked.into_iter().enumerate() {
                for (rank, (id, cpu, memory)) in list.into_iter().enumerate() {
                    top.run(&[
                        Value::Int(m.at),
                        Value::Int(kind as i64),
                        Value::Int(rank as i64),
                        Value::Int(id),
                        Value::Real(Some(cpu)),
                        Value::Real(Some(memory)),
                    ])?;
                }
            }
            if purge {
                let cutoff = Value::Int(m.at - days as i64 * 86400);
                db.prepare("DELETE FROM minutes WHERE at<?")?
                    .run(&[cutoff])?;
                let cutoff = Value::Int(m.at - days as i64 * 86400);
                db.prepare("DELETE FROM top WHERE at<?")?.run(&[cutoff])?;
                if clean {
                    db.exec("DELETE FROM procs WHERE id NOT IN (SELECT proc FROM top)")?;
                }
            }
            Ok::<(), String>(())
        })();
        match result {
            Ok(()) => db.exec("COMMIT")?,
            Err(e) => {
                let _ = db.exec("ROLLBACK");
                return Err(e);
            }
        }
        if purge {
            // Returns freed pages to the file system; outside the minute's transaction.
            db.exec("PRAGMA incremental_vacuum")?;
            self.purged = Some((m.at, days));
            if clean {
                self.cleaned = m.at;
            }
        }
        Ok(())
    }
}

#[derive(Serialize, Default)]
pub struct Info {
    pub bytes: u64,
    pub oldest: Option<i64>,
    pub newest: Option<i64>,
    pub minutes: i64,
}
#[derive(Serialize, Default, Clone)]
pub struct Bucket {
    pub at: i64,
    pub samples: i64,
    pub cpu: Option<f64>,
    pub cpu_minutes: i64,
    pub cpu_max: Option<f64>,
    pub memory: Option<f64>,
    pub memory_minutes: i64,
    pub swap: Option<f64>,
    pub disk_read: Option<f64>,
    pub disk_read_minutes: i64,
    pub disk_write: Option<f64>,
    pub disk_write_minutes: i64,
    pub net_in: Option<f64>,
    pub net_in_minutes: i64,
    pub net_out: Option<f64>,
    pub net_out_minutes: i64,
    pub thermal: Option<i64>,
    pub pressure: Option<i64>,
    pub pressure_pct: Option<f64>,
}
#[derive(Serialize)]
pub struct Series {
    pub from: i64,
    pub to: i64,
    pub bucket: i64,
    /// One entry per bucket in [from, to); buckets without recorded minutes stay empty (gaps).
    pub points: Vec<Bucket>,
    pub info: Info,
}
#[derive(Serialize)]
pub struct TopEntry {
    pub name: String,
    pub path: String,
    pub cwd: String,
    pub origin: String,
    /// Mean % of one core over every recorded minute of the range (minutes outside the top 10
    /// count as zero, so this is a lower bound).
    pub cpu: f64,
    pub cpu_peak: f64,
    pub memory: f64,
    /// Recorded minutes in which it ranked in this list.
    pub minutes: i64,
}
#[derive(Serialize)]
pub struct Top {
    pub from: i64,
    pub to: i64,
    pub minutes: i64,
    pub cpu: Vec<TopEntry>,
    pub memory: Vec<TopEntry>,
}

fn reader(path: &str) -> Result<Option<Db>, String> {
    if !std::path::Path::new(path).exists() {
        return Ok(None);
    }
    Db::open(path, true).map(Some)
}
pub fn info(path: &str) -> Result<Info, String> {
    let bytes = files(path)
        .iter()
        .filter_map(|f| std::fs::metadata(f).ok())
        .map(|m| m.len())
        .sum();
    let Some(db) = reader(path)? else {
        return Ok(Info::default());
    };
    let mut s = db.prepare("SELECT min(at), max(at), count(*) FROM minutes")?;
    s.step()?;
    Ok(Info {
        bytes,
        oldest: s.int(0),
        newest: s.int(1),
        minutes: s.int(2).unwrap_or(0),
    })
}
pub fn series(path: &str, from: i64, to: i64, bucket: i64) -> Result<Series, String> {
    let bucket = bucket.clamp(60, 86400);
    let from = from.div_euclid(bucket) * bucket;
    let count = ((to - from + bucket - 1) / bucket).clamp(0, 2000);
    let mut points: Vec<Bucket> = (0..count)
        .map(|i| Bucket {
            at: from + i * bucket,
            ..Default::default()
        })
        .collect();
    let info = info(path)?;
    if let Some(db) = reader(path)? {
        let mut s = db.prepare(
            "SELECT (at-?1)/?2, sum(samples), avg(cpu), max(cpu_max), avg(memory), max(swap),
             avg(disk_read), avg(disk_write), avg(net_in), avg(net_out), max(thermal),
             max(pressure), max(pressure_pct), count(cpu), count(memory), count(disk_read),
             count(disk_write), count(net_in), count(net_out)
             FROM minutes WHERE at>=?1 AND at<?3 GROUP BY 1",
        )?;
        s.bind(&[Value::Int(from), Value::Int(bucket), Value::Int(to)])?;
        while s.step()? {
            let Some(p) = s.int(0).and_then(|i| points.get_mut(i as usize)) else {
                continue;
            };
            p.samples = s.int(1).unwrap_or(0);
            p.cpu = s.real(2);
            p.cpu_max = s.real(3);
            p.memory = s.real(4);
            p.swap = s.real(5);
            p.disk_read = s.real(6);
            p.disk_write = s.real(7);
            p.net_in = s.real(8);
            p.net_out = s.real(9);
            p.thermal = s.int(10);
            p.pressure = s.int(11);
            p.pressure_pct = s.real(12);
            p.cpu_minutes = s.int(13).unwrap_or(0);
            p.memory_minutes = s.int(14).unwrap_or(0);
            p.disk_read_minutes = s.int(15).unwrap_or(0);
            p.disk_write_minutes = s.int(16).unwrap_or(0);
            p.net_in_minutes = s.int(17).unwrap_or(0);
            p.net_out_minutes = s.int(18).unwrap_or(0);
        }
    }
    Ok(Series {
        from,
        to,
        bucket,
        points,
        info,
    })
}
pub fn top(path: &str, from: i64, to: i64) -> Result<Top, String> {
    let mut out = Top {
        from,
        to,
        minutes: 0,
        cpu: vec![],
        memory: vec![],
    };
    let Some(db) = reader(path)? else {
        return Ok(out);
    };
    out.minutes = {
        let mut s = db.prepare("SELECT count(*) FROM minutes WHERE at>=? AND at<?")?;
        s.bind(&[Value::Int(from), Value::Int(to)])?;
        if s.step()? { s.int(0).unwrap_or(0) } else { 0 }
    };
    let total = out.minutes.max(1) as f64;
    for kind in [0, 1] {
        let order = if kind == 0 {
            "sum(t.cpu)"
        } else {
            "max(t.memory)"
        };
        let mut s = db.prepare(&format!(
            "SELECT p.name, p.path, p.cwd, p.origin, sum(t.cpu), max(t.cpu), max(t.memory),
             count(*) FROM (SELECT at, proc, sum(cpu) AS cpu, max(memory) AS memory
             FROM top WHERE at>=? AND at<? AND kind=? GROUP BY at, proc) t
             JOIN procs p ON p.id=t.proc
             GROUP BY t.proc ORDER BY {order} DESC LIMIT {TOP}"
        ))?;
        s.bind(&[Value::Int(from), Value::Int(to), Value::Int(kind)])?;
        let mut list = vec![];
        while s.step()? {
            list.push(TopEntry {
                name: s.text(0),
                path: s.text(1),
                cwd: s.text(2),
                origin: s.text(3),
                cpu: s.real(4).unwrap_or(0.) / total,
                cpu_peak: s.real(5).unwrap_or(0.),
                memory: s.real(6).unwrap_or(0.),
                minutes: s.int(7).unwrap_or(0),
            });
        }
        if kind == 0 {
            out.cpu = list;
        } else {
            out.memory = list;
        }
    }
    Ok(out)
}
