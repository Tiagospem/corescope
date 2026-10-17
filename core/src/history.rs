//! Opt-in persistent history: one-minute rollups in a local SQLite file, one transaction per
//! minute. Stores system aggregates and, per minute, the 10 processes with most CPU and most
//! memory (name, executable, working directory, origin), and since version 2 total power and the
//! 10 processes drawing the most power. Never arguments or environment.
use crate::sqlite::{Db, Value};
use serde::Serialize;
use std::collections::HashMap;

pub const TOP: usize = 10;
const SCHEMA: &str = "PRAGMA auto_vacuum=INCREMENTAL;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS minutes(at INTEGER PRIMARY KEY, samples INTEGER NOT NULL,
 cpu REAL, cpu_max REAL, memory REAL, swap REAL, disk_read REAL, disk_write REAL,
 net_in REAL, net_out REAL, thermal INTEGER, pressure INTEGER, pressure_pct REAL, power REAL);
CREATE TABLE IF NOT EXISTS procs(id INTEGER PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL,
 cwd TEXT NOT NULL, origin TEXT NOT NULL, UNIQUE(name, path, cwd, origin));
CREATE TABLE IF NOT EXISTS top(at INTEGER NOT NULL, kind INTEGER NOT NULL, rank INTEGER NOT NULL,
 proc INTEGER NOT NULL, cpu REAL, memory REAL, energy REAL, PRIMARY KEY(at, kind, rank)) WITHOUT ROWID;";
/// Version 1 files gain the power columns in place; their earlier minutes keep NULL there.
const MIGRATE: [&str; 2] = [
    "ALTER TABLE minutes ADD COLUMN power REAL",
    "ALTER TABLE top ADD COLUMN energy REAL",
];
/// Ranking kinds in `top`.
const KINDS: [i64; 3] = [0, 1, 2];

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
    /// Sum of the processes' power, watts.
    pub power: Option<f64>,
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
    /// Watts.
    pub energy: Option<f64>,
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
    energy: f64,
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
    power: Mean,
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
        self.power.add(s.power);
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
                energy: 0.,
            });
            acc.cpu += p.cpu.unwrap_or(0.);
            acc.energy += p.energy.unwrap_or(0.);
            acc.memory = acc.memory.max(p.memory.unwrap_or(0.));
        }
    }
    /// Top processes for the minute: CPU averaged over every sample of the minute (a process
    /// seen in one sample out of six weighs one sixth), memory as the peak footprint, power
    /// averaged like CPU. Kinds: 0 CPU, 1 memory, 2 power.
    fn ranked(&self, kind: i64) -> Vec<(&ProcAcc, f64)> {
        let n = self.samples.max(1) as f64;
        let mut all: Vec<(&ProcAcc, f64)> = self
            .procs
            .values()
            .map(|p| {
                let v = match kind {
                    0 => p.cpu / n,
                    1 => p.memory,
                    _ => p.energy / n,
                };
                (p, v)
            })
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
            let version = {
                let mut s = db.prepare("PRAGMA user_version")?;
                if s.step()? { s.int(0).unwrap_or(0) } else { 0 }
            };
            if version < 2 {
                for sql in MIGRATE {
                    // A file created by this version already has the column.
                    if let Err(e) = db.exec(sql)
                        && !e.contains("duplicate column")
                    {
                        return Err(e);
                    }
                }
                db.exec("PRAGMA user_version=2")?;
            }
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
                "INSERT INTO minutes(at,samples,cpu,cpu_max,memory,swap,disk_read,disk_write,
                 net_in,net_out,thermal,pressure,pressure_pct,power) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                 ON CONFLICT(at) DO UPDATE SET
                 power=CASE WHEN minutes.power IS NULL THEN excluded.power
                   WHEN excluded.power IS NULL THEN minutes.power
                   ELSE (minutes.power*minutes.samples+excluded.power*excluded.samples)/
                     (minutes.samples+excluded.samples) END,
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
                Value::Real(m.power.get()),
            ])?;
            let mut insert =
                db.prepare("INSERT OR IGNORE INTO procs(name,path,cwd,origin) VALUES(?,?,?,?)")?;
            let mut find =
                db.prepare("SELECT id FROM procs WHERE name=? AND path=? AND cwd=? AND origin=?")?;
            let total_samples = (old_samples + m.samples as i64).max(1) as f64;
            let mut ranked = [Vec::new(), Vec::new(), Vec::new()];
            for kind in KINDS {
                let mut entries: HashMap<i64, (f64, f64, f64)> = HashMap::new();
                if old_samples > 0 {
                    let mut previous =
                        db.prepare("SELECT proc,cpu,memory,energy FROM top WHERE at=? AND kind=?")?;
                    previous.bind(&[Value::Int(m.at), Value::Int(kind)])?;
                    let weight = old_samples as f64 / total_samples;
                    while previous.step()? {
                        let id = previous.int(0).ok_or("Processo sem identificador")?;
                        entries.insert(
                            id,
                            (
                                previous.real(1).unwrap_or(0.) * weight,
                                previous.real(2).unwrap_or(0.),
                                previous.real(3).unwrap_or(0.) * weight,
                            ),
                        );
                    }
                }
                for (p, _) in m.ranked(kind) {
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
                    entry.2 += p.energy / total_samples;
                }
                let value = |e: &(f64, f64, f64)| match kind {
                    0 => e.0,
                    1 => e.1,
                    _ => e.2,
                };
                let mut list: Vec<_> = entries.into_iter().collect();
                list.sort_by(|a, b| value(&b.1).total_cmp(&value(&a.1)));
                list.retain(|(_, e)| value(e) > 0.);
                list.truncate(TOP);
                ranked[kind as usize] = list
                    .into_iter()
                    .map(|(id, (cpu, memory, energy))| (id, cpu, memory, energy))
                    .collect();
            }
            db.prepare("DELETE FROM top WHERE at=?")?
                .run(&[Value::Int(m.at)])?;
            let mut top = db.prepare(
                "INSERT INTO top(at,kind,rank,proc,cpu,memory,energy) VALUES(?,?,?,?,?,?,?)",
            )?;
            for (kind, list) in ranked.into_iter().enumerate() {
                for (rank, (id, cpu, memory, energy)) in list.into_iter().enumerate() {
                    top.run(&[
                        Value::Int(m.at),
                        Value::Int(kind as i64),
                        Value::Int(rank as i64),
                        Value::Int(id),
                        Value::Real(Some(cpu)),
                        Value::Real(Some(memory)),
                        Value::Real(Some(energy)),
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
    /// Watts; None before version 2 or without readings.
    pub power: Option<f64>,
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
    /// Mean watts over the recorded minutes (a lower bound, like `cpu`).
    pub energy: f64,
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
    pub energy: Vec<TopEntry>,
}

/// Schema version of a file opened read-only (1 has no power columns).
fn version(db: &Db) -> Result<i64, String> {
    let mut s = db.prepare("PRAGMA user_version")?;
    Ok(if s.step()? { s.int(0).unwrap_or(0) } else { 0 })
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
        let power = if version(&db)? >= 2 {
            "avg(power)"
        } else {
            "NULL"
        };
        let mut s = db.prepare(&format!(
            "SELECT (at-?1)/?2, sum(samples), avg(cpu), max(cpu_max), avg(memory), max(swap),
             avg(disk_read), avg(disk_write), avg(net_in), avg(net_out), max(thermal),
             max(pressure), max(pressure_pct), count(cpu), count(memory), count(disk_read),
             count(disk_write), count(net_in), count(net_out), {power}
             FROM minutes WHERE at>=?1 AND at<?3 GROUP BY 1"
        ))?;
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
            p.power = s.real(19);
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
        energy: vec![],
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
    let energy = version(&db)? >= 2;
    for kind in KINDS {
        if kind == 2 && !energy {
            continue;
        }
        let order = match kind {
            0 => "sum(t.cpu)",
            1 => "max(t.memory)",
            _ => "sum(t.energy)",
        };
        let energy_col = if energy { "sum(energy)" } else { "0" };
        let mut s = db.prepare(&format!(
            "SELECT p.name, p.path, p.cwd, p.origin, sum(t.cpu), max(t.cpu), max(t.memory),
             count(*), sum(t.energy) FROM (SELECT at, proc, sum(cpu) AS cpu, max(memory) AS memory,
             {energy_col} AS energy
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
                energy: s.real(8).unwrap_or(0.) / total,
            });
        }
        match kind {
            0 => out.cpu = list,
            1 => out.memory = list,
            _ => out.energy = list,
        }
    }
    Ok(out)
}

/// What the Mac was doing around a moment: system peaks over a window, compared with the hour
/// before it, and who dominated CPU, memory and power.
#[derive(Serialize)]
pub struct Happened {
    pub at: i64,
    pub from: i64,
    pub to: i64,
    /// Recorded minutes in the window (0: the Mac slept, the app was closed or history was off).
    pub minutes: i64,
    pub cpu: Option<f64>,
    pub cpu_max: Option<f64>,
    pub cpu_max_at: Option<i64>,
    /// Mean CPU over the hour before the window, for comparison.
    pub cpu_before: Option<f64>,
    pub memory_max: Option<f64>,
    pub swap_start: Option<f64>,
    pub swap_end: Option<f64>,
    pub power: Option<f64>,
    pub power_max: Option<f64>,
    pub power_max_at: Option<i64>,
    pub power_before: Option<f64>,
    pub disk_write_max: Option<f64>,
    pub net_max: Option<f64>,
    pub thermal_max: Option<i64>,
    pub pressure_max: Option<i64>,
    pub points: Vec<Bucket>,
    pub top: Top,
}
pub fn happened(path: &str, at: i64, minutes: i64) -> Result<Happened, String> {
    let minutes = minutes.clamp(2, 120);
    let at = at.div_euclid(60) * 60;
    let from = at - minutes / 2 * 60;
    let to = from + minutes * 60;
    let s = series(path, from, to, 60)?;
    let before = series(path, from - 3600, from, 3600)?;
    let recorded: Vec<&Bucket> = s.points.iter().filter(|p| p.samples > 0).collect();
    let mean = |f: fn(&Bucket) -> Option<f64>| {
        let v: Vec<f64> = recorded.iter().filter_map(|p| f(p)).collect();
        (!v.is_empty()).then(|| v.iter().sum::<f64>() / v.len() as f64)
    };
    let peak = |f: fn(&Bucket) -> Option<f64>| {
        recorded
            .iter()
            .filter_map(|p| f(p).map(|v| (v, p.at)))
            .max_by(|a, b| a.0.total_cmp(&b.0))
    };
    let cpu_peak = peak(|p| p.cpu_max.or(p.cpu));
    let power_peak = peak(|p| p.power);
    Ok(Happened {
        at,
        from,
        to,
        minutes: recorded.len() as i64,
        cpu: mean(|p| p.cpu),
        cpu_max: cpu_peak.map(|p| p.0),
        cpu_max_at: cpu_peak.map(|p| p.1),
        cpu_before: before.points.first().and_then(|p| p.cpu),
        memory_max: peak(|p| p.memory).map(|p| p.0),
        swap_start: recorded.iter().find_map(|p| p.swap),
        swap_end: recorded.iter().rev().find_map(|p| p.swap),
        power: mean(|p| p.power),
        power_max: power_peak.map(|p| p.0),
        power_max_at: power_peak.map(|p| p.1),
        power_before: before.points.first().and_then(|p| p.power),
        disk_write_max: peak(|p| p.disk_write).map(|p| p.0),
        net_max: peak(|p| match (p.net_in, p.net_out) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or(0.) + b.unwrap_or(0.)),
        })
        .map(|p| p.0),
        thermal_max: recorded.iter().filter_map(|p| p.thermal).max(),
        pressure_max: recorded.iter().filter_map(|p| p.pressure).max(),
        top: top(path, from, to)?,
        points: s.points,
    })
}

/// Plain-English findings for people and agents, most telling first.
pub fn findings(h: &Happened) -> Vec<String> {
    let hm = |t: i64| {
        let s = crate::os::local_format(t);
        s.get(11..).unwrap_or(&s).to_string()
    };
    let window = format!("{} to {}", crate::os::local_format(h.from), hm(h.to));
    if h.minutes == 0 {
        return vec![format!(
            "Nothing was recorded from {window}: the Mac was asleep, CoreScope was closed, or history is off (Settings › History)."
        )];
    }
    let gb = |b: f64| format!("{:.1} GB", b / 1_073_741_824.);
    let who = |e: &TopEntry| {
        let mut parts = vec![e.name.clone()];
        if !e.origin.is_empty() {
            parts.push(format!("via {}", e.origin));
        }
        if !e.cwd.is_empty() && e.cwd != "/" {
            parts.push(e.cwd.clone());
        }
        parts.join(", ")
    };
    let mut out = vec![format!("{} recorded minutes from {window}.", h.minutes)];
    if let (Some(cpu), Some(max), Some(at)) = (h.cpu, h.cpu_max, h.cpu_max_at) {
        let before = h
            .cpu_before
            .map(|b| format!("; the hour before averaged {b:.0}%"))
            .unwrap_or_default();
        out.push(format!(
            "CPU averaged {cpu:.0}% (peak {max:.0}% at {}){before}.",
            hm(at)
        ));
    }
    if let (Some(p), Some(max), Some(at)) = (h.power, h.power_max, h.power_max_at) {
        let before = h
            .power_before
            .map(|b| format!(", against {b:.1} W the hour before"))
            .unwrap_or_default();
        out.push(format!(
            "Process power averaged {p:.1} W (peak {max:.1} W at {}){before}.",
            hm(at)
        ));
    }
    if let (Some(a), Some(b)) = (h.swap_start, h.swap_end)
        && b - a > 268_435_456.
    {
        out.push(format!("Swap grew {} (to {}).", gb(b - a), gb(b)));
    }
    match h.pressure_max {
        Some(2) => out.push("Memory pressure reached critical.".into()),
        Some(1) => out.push("Memory pressure reached warning.".into()),
        _ => {}
    }
    match h.thermal_max {
        Some(3) => out.push("Thermal state reached critical (heavy throttling).".into()),
        Some(2) => out.push("Thermal state reached serious (throttling).".into()),
        _ => {}
    }
    if let Some(w) = h.disk_write_max
        && w > 50. * 1_048_576.
    {
        out.push(format!("Disk writes peaked at {:.0} MB/s.", w / 1_048_576.));
    }
    if let Some(e) = h.top.cpu.first() {
        out.push(format!(
            "Most CPU: {} — {:.0}% of a core on average, peak {:.0}%.",
            who(e),
            e.cpu,
            e.cpu_peak
        ));
    }
    if let Some(e) = h.top.energy.first() {
        out.push(format!(
            "Most power: {} — {:.1} W on average.",
            who(e),
            e.energy
        ));
    }
    if let Some(e) = h.top.memory.first() {
        out.push(format!("Most memory: {} — {}.", who(e), gb(e.memory)));
    }
    out
}
