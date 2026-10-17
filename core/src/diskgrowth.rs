//! Which folders grew today: the usual places a developer's disk fills up (caches, Xcode,
//! simulators, container VMs, package stores, model files, Downloads, Trash, agent data),
//! measured now and then and compared with the last measurement before today.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Snapshots older than this are dropped; recent ones are thinned to one per hour.
const KEEP_DAYS: i64 = 30;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Measurement {
    pub at: i64,
    /// Free space on the volume holding the home folder.
    pub free: Option<u64>,
    /// Path → allocated bytes.
    pub sizes: BTreeMap<String, u64>,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Growth {
    pub label: String,
    pub path: String,
    pub bytes: u64,
    /// Since the baseline; negative when it shrank. None: not measured then.
    pub change: Option<i64>,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Report {
    pub measured_at: Option<i64>,
    /// The measurement compared against: the last one before today, or today's first.
    pub baseline_at: Option<i64>,
    pub free: Option<u64>,
    pub free_change: Option<i64>,
    /// Largest growth first.
    pub folders: Vec<Growth>,
}

/// `~/Library/Application Support/CoreScope/disk-growth.json`.
pub fn default_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/CoreScope/disk-growth.json")
}

/// The places watched, with a label; only those that exist.
pub fn spots(home: &Path) -> Vec<(&'static str, PathBuf)> {
    [
        ("Caches", "Library/Caches"),
        ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
        ("Xcode archives", "Library/Developer/Xcode/Archives"),
        (
            "iOS device support",
            "Library/Developer/Xcode/iOS DeviceSupport",
        ),
        ("Simulators", "Library/Developer/CoreSimulator"),
        ("Docker Desktop", "Library/Containers/com.docker.docker"),
        (
            "OrbStack",
            "Library/Group Containers/HUAQ24HBR6.dev.orbstack",
        ),
        ("Colima", ".colima"),
        ("Logs", "Library/Logs"),
        ("npm", ".npm"),
        ("pnpm", "Library/pnpm"),
        ("Yarn", ".yarn"),
        ("Bun", ".bun"),
        ("Cargo", ".cargo"),
        ("Rustup", ".rustup"),
        ("Go modules", "go/pkg"),
        ("Gradle", ".gradle"),
        ("Maven", ".m2"),
        ("Composer", ".composer"),
        ("~/.cache", ".cache"),
        ("Ollama models", ".ollama"),
        ("LM Studio", ".lmstudio"),
        ("Hugging Face", ".cache/huggingface"),
        ("Claude Desktop", "Library/Application Support/Claude"),
        ("Claude Code", ".claude"),
        ("Codex", ".codex"),
        ("Downloads", "Downloads"),
        ("Trash", ".Trash"),
    ]
    .into_iter()
    .map(|(label, rel)| (label, home.join(rel)))
    // Follows a symlinked spot (Downloads or ~/.cache moved to another drive still grows).
    .filter(|(_, p)| std::fs::metadata(p).is_ok_and(|m| m.is_dir()))
    // A watched folder inside another is reported on its own and left out of its parent's
    // growth only by reading: sizes overlap (Hugging Face is inside .cache).
    .collect()
}

pub fn load(file: &Path) -> Vec<Measurement> {
    std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
/// Adds a measurement, thins and saves (atomically).
pub fn save(file: &Path, mut list: Vec<Measurement>, m: Measurement) -> Result<(), String> {
    list.push(m);
    let list = thin(list);
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = file.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(&list).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, file).map_err(|e| e.to_string())
}
/// Keeps 30 days; older than a day, one per hour.
pub fn thin(mut list: Vec<Measurement>) -> Vec<Measurement> {
    list.sort_by_key(|m| m.at);
    let Some(last) = list.last().map(|m| m.at) else {
        return list;
    };
    let mut out: Vec<Measurement> = vec![];
    for m in list {
        if last - m.at > KEEP_DAYS * 86400 {
            continue;
        }
        if last - m.at > 86400
            && let Some(prev) = out.last()
            && prev.at / 3600 == m.at / 3600
        {
            *out.last_mut().expect("checked") = m;
            continue;
        }
        out.push(m);
    }
    out
}

/// Measures every spot (seconds on a large home; run off the main thread).
pub fn measure(home: &Path, now: i64) -> Measurement {
    let sizes = spots(home)
        .into_iter()
        .map(|(_, p)| {
            let bytes = crate::devspace::measure(&p).0;
            (p.to_string_lossy().into_owned(), bytes)
        })
        .collect();
    Measurement {
        at: now,
        free: crate::volume_free(home),
        sizes,
    }
}

/// Today's growth: the latest measurement against the last one before `day_start` (local
/// midnight), or against today's first when there is none before.
pub fn report(list: &[Measurement], home: &Path, day_start: i64) -> Report {
    let Some(latest) = list.last() else {
        return Report {
            measured_at: None,
            baseline_at: None,
            free: None,
            free_change: None,
            folders: vec![],
        };
    };
    let baseline = list
        .iter()
        .rev()
        .find(|m| m.at < day_start)
        .or_else(|| list.iter().find(|m| m.at >= day_start && m.at < latest.at));
    let labels: BTreeMap<String, &str> = spots(home)
        .into_iter()
        .map(|(l, p)| (p.to_string_lossy().into_owned(), l))
        .collect();
    let mut folders: Vec<Growth> = latest
        .sizes
        .iter()
        .map(|(path, bytes)| Growth {
            label: labels.get(path).copied().unwrap_or("").to_string(),
            path: path.clone(),
            bytes: *bytes,
            change: baseline
                .and_then(|b| b.sizes.get(path))
                .map(|before| *bytes as i64 - *before as i64),
        })
        .collect();
    // Changes under 1 MB are noise (a log line, a cache entry): those sort by size.
    folders.sort_by_key(|g| {
        let change = g.change.filter(|c| c.abs() >= 1 << 20).unwrap_or(0);
        std::cmp::Reverse((change, g.bytes as i64))
    });
    Report {
        measured_at: Some(latest.at),
        baseline_at: baseline.map(|b| b.at),
        free: latest.free,
        free_change: match (baseline.and_then(|b| b.free), latest.free) {
            (Some(a), Some(b)) => Some(b as i64 - a as i64),
            _ => None,
        },
        folders,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(at: i64, free: u64, sizes: &[(&str, u64)]) -> Measurement {
        Measurement {
            at,
            free: Some(free),
            // In MB, so changes are above the 1 MB noise floor.
            sizes: sizes
                .iter()
                .map(|(p, b)| (p.to_string(), *b << 20))
                .collect(),
        }
    }

    #[test]
    fn today_against_the_last_measurement_before_it() {
        let day = 1_800_000_000;
        let list = vec![
            m(day - 7200, 100, &[("/h/a", 10), ("/h/b", 50)]),
            m(day - 3600, 90, &[("/h/a", 20), ("/h/b", 50)]),
            m(day + 600, 80, &[("/h/a", 25), ("/h/b", 40)]),
            m(day + 3600, 60, &[("/h/a", 60), ("/h/b", 40), ("/h/c", 5)]),
        ];
        let r = report(&list, Path::new("/nowhere"), day);
        assert_eq!(r.baseline_at, Some(day - 3600));
        assert_eq!(r.free_change, Some(-30));
        let changes: Vec<_> = r
            .folders
            .iter()
            .map(|g| (g.path.as_str(), g.change))
            .collect();
        assert_eq!(
            changes,
            [
                ("/h/a", Some(40 << 20)),
                ("/h/c", None),
                ("/h/b", Some(-10 << 20))
            ]
        );
        // Without anything before today, today's first measurement is the baseline.
        let r = report(&list[2..], Path::new("/nowhere"), day);
        assert_eq!(
            (r.baseline_at, r.folders[0].change),
            (Some(day + 600), Some(35 << 20))
        );
        assert_eq!(report(&[], Path::new("/x"), day).measured_at, None);
    }

    #[test]
    fn keeps_a_month_and_thins_older_days_to_hours() {
        let now = 1_800_000_000;
        let mut list = vec![m(now - 40 * 86400, 1, &[])];
        for i in 0..6 {
            list.push(m(now - 2 * 86400 + i * 600, 1, &[]));
        }
        list.push(m(now - 600, 1, &[]));
        list.push(m(now, 1, &[]));
        let kept = thin(list);
        assert_eq!(kept.len(), 3, "{kept:?}");
        assert_eq!(
            kept[0].at,
            now - 2 * 86400 + 5 * 600,
            "the hour's last one stays"
        );
    }

    #[test]
    fn measures_real_folders_and_saves() {
        let home = std::env::temp_dir().join(format!("corescope-growth-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join(".npm/_cacache")).unwrap();
        std::fs::write(home.join(".npm/_cacache/x"), vec![7u8; 64 * 1024]).unwrap();
        let spots = spots(&home);
        assert_eq!(spots.len(), 1);
        let first = measure(&home, 100);
        assert!(first.sizes[&home.join(".npm").to_string_lossy().into_owned()] >= 64 * 1024);
        let file = default_path(&home);
        save(&file, load(&file), first.clone()).unwrap();
        std::fs::write(home.join(".npm/_cacache/y"), vec![7u8; 128 * 1024]).unwrap();
        save(&file, load(&file), measure(&home, 200)).unwrap();
        let list = load(&file);
        assert_eq!(list.len(), 2);
        let r = report(&list, &home, 150);
        assert_eq!(r.folders[0].label, "npm");
        assert!(r.folders[0].change.unwrap() >= 128 * 1024);
        std::fs::remove_dir_all(home).unwrap();
    }
}
