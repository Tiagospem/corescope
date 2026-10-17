//! Logs in one place, for any project: its log files (conventional folders and the
//! `.corescope.yml` globs), the output of profile commands and container logs. Reads only the end
//! of each source, flags errors with generic patterns (keeping stack-trace lines that follow) and
//! searches. Read-only; nothing is stored.
use crate::containers;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How much of the end of a source is read.
const TAIL_BYTES: u64 = 2 << 20;
const CONTAINER_LINES: usize = 3000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
pub struct Source {
    /// "file" (a log file or a profile command's output) or "container".
    pub kind: String,
    pub name: String,
    #[serde(default)]
    pub project: Option<String>,
    /// File path, or container name.
    pub target: String,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Entry {
    pub source: String,
    pub project: Option<String>,
    /// "error" or "warning".
    pub level: &'static str,
    pub text: String,
    /// Stack-trace lines that follow, when any.
    pub context: Vec<String>,
    /// How many times this message appeared (timestamps and numbers aside); the newest is kept.
    pub count: usize,
}

// MARK: finding sources

/// Conventional log locations inside a project (Laravel, Rails, Symfony, Node, generic).
const FOLDERS: [&str; 5] = ["storage/logs", "log", "logs", "var/log", "tmp/logs"];

/// Log files of a project: the conventional folders, `*.log` at its root and `globs` (from
/// `.corescope.yml`, relative to the project). Newest first, at most 40.
pub fn project_files(folder: &Path, globs: &[String]) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = vec![];
    let add_dir = |dir: PathBuf, out: &mut Vec<PathBuf>| {
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let p = e.path();
            if e.file_type().is_ok_and(|t| t.is_file()) && is_log(&p) && !out.contains(&p) {
                out.push(p);
            }
        }
    };
    add_dir(folder.to_path_buf(), &mut out);
    for f in FOLDERS {
        add_dir(folder.join(f), &mut out);
    }
    for g in globs {
        for p in glob(folder, g) {
            if !out.contains(&p) {
                out.push(p);
            }
        }
    }
    out.retain(|p| p.starts_with(folder));
    out.sort_by_key(|p| std::cmp::Reverse(modified(p)));
    out.truncate(40);
    out
}
fn is_log(p: &Path) -> bool {
    let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.ends_with(".log")
        || name.ends_with(".log.txt")
        || (name.contains(".log.") && !name.ends_with(".gz"))
}
fn modified(p: &Path) -> std::time::SystemTime {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .unwrap_or(std::time::UNIX_EPOCH)
}

/// `dir/*.log`, `dir/**/*.log` (one level of `**`) or a plain relative path; never escapes `root`.
pub fn glob(root: &Path, pattern: &str) -> Vec<PathBuf> {
    if pattern.starts_with('/') || pattern.split('/').any(|c| c == "..") {
        return vec![];
    }
    let (dir, name) = pattern.rsplit_once('/').unwrap_or(("", pattern));
    let mut dirs = vec![];
    match dir.split_once("**") {
        Some((before, _)) => {
            let base = root.join(before.trim_end_matches('/'));
            dirs.push(base.clone());
            for e in std::fs::read_dir(&base).into_iter().flatten().flatten() {
                if e.file_type().is_ok_and(|t| t.is_dir()) {
                    dirs.push(e.path());
                }
            }
        }
        None => dirs.push(root.join(dir)),
    }
    let mut out = vec![];
    for d in dirs {
        if !name.contains('*') {
            let p = d.join(name);
            if p.is_file() {
                out.push(p);
            }
            continue;
        }
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let file = e.file_name().to_string_lossy().to_string();
            if e.file_type().is_ok_and(|t| t.is_file()) && wildcard(name, &file) {
                out.push(e.path());
            }
        }
    }
    out
}
/// `*` matches any run of characters; everything else literally.
pub fn wildcard(pattern: &str, text: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == text;
    }
    let mut rest = text;
    for (i, part) in parts.iter().enumerate() {
        if i == 0 {
            let Some(r) = rest.strip_prefix(part) else {
                return false;
            };
            rest = r;
        } else if i == parts.len() - 1 {
            return rest.ends_with(part);
        } else if let Some(at) = rest.find(part) {
            rest = &rest[at + part.len()..];
        } else {
            return false;
        }
    }
    true
}

// MARK: reading

/// The last `lines` lines of a source (fewer when the source is short).
pub fn tail(source: &Source, lines: usize) -> Result<Vec<String>, String> {
    let all = match source.kind.as_str() {
        "container" => container_logs(&source.target, lines.max(1))?,
        _ => file_tail(Path::new(&source.target))?,
    };
    let skip = all.len().saturating_sub(lines);
    Ok(all.into_iter().skip(skip).collect())
}
fn file_tail(path: &Path) -> Result<Vec<String>, String> {
    let mut f = std::fs::File::open(path).map_err(|_| "Log não encontrado")?;
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(TAIL_BYTES);
    f.seek(SeekFrom::Start(start)).map_err(|e| e.to_string())?;
    let mut buf = vec![];
    f.take(TAIL_BYTES)
        .read_to_end(&mut buf)
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&buf);
    let mut lines: Vec<String> = text.lines().map(clean).collect();
    if start > 0 && !lines.is_empty() {
        lines.remove(0);
    }
    Ok(lines)
}
/// Drops ANSI colour codes and trims very long lines.
fn clean(line: &str) -> String {
    let mut out = String::with_capacity(line.len().min(2000));
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            for d in chars.by_ref() {
                if d.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        if out.len() >= 2000 {
            out.push('…');
            break;
        }
        out.push(c);
    }
    out
}

fn valid_container_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 128
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
}
/// (socket, full id) of the one container with this exact name across local engines.
pub fn find_container(name: &str) -> Result<(PathBuf, String), String> {
    if !valid_container_name(name) {
        return Err("Nome de contêiner inválido".into());
    }
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let host = std::env::var("DOCKER_HOST").ok();
    // filters={"name":["^/NAME$"]}: the filter is a regex, so anchor it to the exact name.
    let path =
        format!("/containers/json?all=1&filters=%7B%22name%22%3A%5B%22%5E%2F{name}%24%22%5D%7D");
    let mut found = vec![];
    for socket in containers::sockets(&home, host.as_deref()) {
        let Ok(r) = containers::request(&socket, "GET", &path, Duration::from_secs(3)) else {
            continue;
        };
        let list: Value = serde_json::from_slice(&r.body).unwrap_or_default();
        for c in list.as_array().into_iter().flatten() {
            if let Some(id) = c["Id"].as_str().filter(|id| containers::valid_id(id)) {
                found.push((socket.clone(), id.to_string()));
            }
        }
    }
    match found.len() {
        0 => Err("Contêiner não encontrado".into()),
        1 => Ok(found.remove(0)),
        _ => Err("Identificador de contêiner ambíguo".into()),
    }
}
/// Splits Docker's multiplexed log stream (8-byte frame headers); raw text when the container
/// has a TTY.
pub fn demux(body: &[u8]) -> String {
    let framed = body.len() >= 8 && body[0] <= 2 && body[1..4] == [0, 0, 0];
    if !framed {
        return String::from_utf8_lossy(body).into_owned();
    }
    let mut out = Vec::with_capacity(body.len());
    let mut rest = body;
    while rest.len() >= 8 {
        let size = u32::from_be_bytes([rest[4], rest[5], rest[6], rest[7]]) as usize;
        let end = (8 + size).min(rest.len());
        out.extend_from_slice(&rest[8..end]);
        rest = &rest[end..];
    }
    String::from_utf8_lossy(&out).into_owned()
}
fn container_logs(name: &str, lines: usize) -> Result<Vec<String>, String> {
    let (socket, id) = find_container(name)?;
    let path = format!(
        "/containers/{id}/logs?stdout=1&stderr=1&timestamps=1&tail={}",
        lines.min(CONTAINER_LINES)
    );
    let r = containers::request(&socket, "GET", &path, Duration::from_secs(10))
        .map_err(|_| "O motor de contêineres não respondeu")?;
    if r.status != 200 {
        return Err(format!("O motor recusou a ação (HTTP {})", r.status));
    }
    Ok(demux(&r.body).lines().map(clean).collect())
}

// MARK: errors and search

/// The level a line declares itself (`local.ERROR:`, `[warn]`, `"level":"info"`, `level=debug`,
/// a leading `ERROR`), if any: Some(None) means an explicit non-problem level.
fn declared(l: &str) -> Option<Option<&'static str>> {
    const LEVELS: [(&str, Option<&str>); 14] = [
        ("emergency", Some("error")),
        ("emerg", Some("error")),
        ("alert", Some("error")),
        ("critical", Some("error")),
        ("crit", Some("error")),
        ("fatal", Some("error")),
        ("error", Some("error")),
        ("err", Some("error")),
        ("warning", Some("warning")),
        ("warn", Some("warning")),
        ("notice", Some("warning")),
        ("info", None),
        ("debug", None),
        ("trace", None),
    ];
    // Skip a leading timestamp block: `[2026-10-17 10:00:00] `, `2026-10-17T10:00:00Z `.
    let body = l.trim_start();
    let body = if body.starts_with('[')
        && body
            .find(']')
            .is_some_and(|i| body[1..i].starts_with(|c: char| c.is_ascii_digit()))
    {
        body[body.find(']').unwrap() + 1..].trim_start()
    } else if body.starts_with(|c: char| c.is_ascii_digit()) {
        body.split_once(' ')
            .map_or(body, |(_, rest)| rest.trim_start())
    } else {
        body
    };
    for (name, level) in LEVELS {
        let marks = [
            format!(".{name}:"),
            format!("[{name}]"),
            format!("\"level\":\"{name}\""),
            format!("\"severity\":\"{name}\""),
            format!("level={name} "),
            format!("level={name}\""),
        ];
        if marks.iter().any(|m| l.contains(m.as_str()))
            || body.starts_with(&format!("{name}:"))
            || body.starts_with(&format!("{name} "))
            || body.starts_with(&format!("{name}\t"))
        {
            return Some(level);
        }
    }
    None
}

/// "error", "warning" or nothing: the level a line declares, else generic markers that work
/// across stacks.
pub fn level(line: &str) -> Option<&'static str> {
    let l = line.to_ascii_lowercase();
    if let Some(level) = declared(&l) {
        return level;
    }
    const ERRORS: [&str; 16] = [
        "error",
        "fatal",
        "critical",
        "panic",
        "panicked",
        "exception",
        "traceback",
        "unhandled",
        "segmentation fault",
        "eaddrinuse",
        "econnrefused",
        "uncaught",
        "failed",
        "failure",
        "emerg",
        "alert:",
    ];
    const WARNINGS: [&str; 3] = ["warn", "deprecated", "notice:"];
    // Words that look like errors but are usually not (counters, zero failures).
    const BENIGN: [&str; 5] = [
        "0 errors",
        "0 failed",
        "no errors",
        "errors: 0",
        "failed: 0",
    ];
    if BENIGN.iter().any(|b| l.contains(b)) {
        return None;
    }
    let word = |w: &str| {
        l.match_indices(w).any(|(i, _)| {
            let before = l[..i]
                .chars()
                .last()
                .is_none_or(|c| !c.is_ascii_alphabetic());
            let after = l[i + w.len()..]
                .chars()
                .next()
                .is_none_or(|c| !c.is_ascii_alphabetic() || w.ends_with(':'));
            // "errors", "Errored", "ErrorException" still count; "terror" does not.
            before
                && (after
                    || l[i + w.len()..].starts_with('s')
                    || l[i + w.len()..].starts_with("ed")
                    || w == "exception")
        })
    };
    if ERRORS.iter().any(|w| word(w)) {
        return Some("error");
    }
    if WARNINGS.iter().any(|w| word(w)) {
        return Some("warning");
    }
    None
}
fn continuation(line: &str) -> bool {
    // Indented lines (JS/Java/Python frames), PHP's `#0 …` frames and trace headers.
    line.starts_with([' ', '\t'])
        || (line.starts_with('#') && line[1..].starts_with(|c: char| c.is_ascii_digit()))
        || line.starts_with("Stack trace:")
        || line.starts_with("Caused by")
        || line.starts_with("...")
}
/// Error and warning lines of these lines (newest last), each with up to 6 stack-trace lines.
pub fn scan(source: &Source, lines: &[String], warnings: bool) -> Vec<Entry> {
    let mut out: Vec<Entry> = vec![];
    let mut i = 0;
    while i < lines.len() {
        // A trace line belongs to the entry above it, never starts one.
        let level = if continuation(&lines[i]) {
            None
        } else {
            level(&lines[i])
        };
        let Some(level) = level.filter(|l| *l == "error" || warnings) else {
            i += 1;
            while i < lines.len() && continuation(&lines[i]) {
                i += 1;
            }
            continue;
        };
        let mut context = vec![];
        let mut j = i + 1;
        while j < lines.len() && continuation(&lines[j]) {
            if context.len() < 6 {
                context.push(lines[j].clone());
            }
            j += 1;
        }
        out.push(Entry {
            source: source.name.clone(),
            project: source.project.clone(),
            level,
            text: lines[i].clone(),
            context,
            count: 1,
        });
        i = j;
    }
    out
}

/// A message without its timestamps, ids and numbers, so repeats group together.
fn shape(text: &str) -> String {
    // The message, not its context object: `msg {"id":1}` and `msg {"id":2}` are one problem.
    let text = text.find(" {").map_or(text, |i| &text[..i]);
    text.chars()
        .map(|c| if c.is_ascii_digit() { '0' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
/// Newest-first entries with repeats folded into the first (newest) one.
pub fn group(entries: Vec<Entry>) -> Vec<Entry> {
    let mut out: Vec<Entry> = vec![];
    for e in entries {
        let key = shape(&e.text);
        if let Some(first) = out
            .iter_mut()
            .find(|o| o.source == e.source && shape(&o.text) == key)
        {
            first.count += 1;
        } else {
            out.push(e);
        }
    }
    out
}

/// The most recent errors (and warnings when asked) across sources, newest first per source.
pub fn errors(sources: &[Source], limit: usize, warnings: bool) -> (Vec<Entry>, Vec<String>) {
    let mut all = vec![];
    let mut problems = vec![];
    for s in sources {
        match tail(s, CONTAINER_LINES) {
            Ok(lines) => {
                let mut found = scan(s, &lines, warnings);
                found.reverse();
                all.extend(group(found).into_iter().take(limit));
            }
            Err(e) => problems.push(format!("{}: {e}", s.name)),
        }
    }
    all.truncate(limit.max(1) * 4);
    (all, problems)
}

/// Lines containing `query` (case-insensitive), newest first.
pub fn search(sources: &[Source], query: &str, limit: usize) -> Vec<Entry> {
    let q = query.to_lowercase();
    let mut out = vec![];
    for s in sources {
        let Ok(lines) = tail(s, CONTAINER_LINES) else {
            continue;
        };
        for line in lines
            .iter()
            .rev()
            .filter(|l| l.to_lowercase().contains(&q))
            .take(limit)
        {
            out.push(Entry {
                source: s.name.clone(),
                project: s.project.clone(),
                level: level(line).unwrap_or("info"),
                text: line.clone(),
                context: vec![],
                count: 1,
            });
        }
    }
    out.truncate(limit);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_error_markers() {
        for e in [
            "[2026-10-17 10:00:00] local.ERROR: SQLSTATE[HY000] Connection refused",
            "Traceback (most recent call last):",
            "thread 'main' panicked at src/main.rs:1",
            "{\"level\":\"error\",\"msg\":\"boom\"}",
            "Error: listen EADDRINUSE: address already in use :::3000",
            "FAILED tests/unit/test_x.py::test_y",
            "PHP Fatal error:  Uncaught TypeError",
        ] {
            assert_eq!(level(e), Some("error"), "{e}");
        }
        assert_eq!(level("WARN deprecated option"), Some("warning"));
        assert_eq!(
            level("[2026-10-17 12:45:30] testing.WARNING: portal_sync.mark_failed"),
            Some("warning")
        );
        assert_eq!(
            level("{\"level\":\"info\",\"msg\":\"retry failed once\"}"),
            None
        );
        assert_eq!(level("2026-10-17T10:00:00Z INFO error budget ok"), None);
        assert_eq!(
            level("ERROR: relation \"users\" does not exist"),
            Some("error")
        );
        for ok in [
            "Tests: 12 passed, 0 failed",
            "Compiled with 0 errors",
            "no errors found",
            "terrorism",
            "INFO started",
        ] {
            assert_eq!(level(ok), None, "{ok}");
        }
    }

    #[test]
    fn traces_stay_with_their_error() {
        let s = Source {
            kind: "file".into(),
            name: "laravel.log".into(),
            project: None,
            target: String::new(),
        };
        let lines: Vec<String> = [
            "INFO ok",
            "local.ERROR: Undefined variable $x",
            "Stack trace:",
            "#0 /app/Http/Kernel.php(10): foo()",
            "  at Foo.bar (foo.js:1:2)",
            "INFO next",
            "Error: boom",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        let found = scan(&s, &lines, false);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].context.len(), 3);
        assert_eq!(found[1].text, "Error: boom");
        let repeated = scan(
            &s,
            &[
                "[2026-10-17 10:00:01] local.ERROR: Redis down".into(),
                "[2026-10-17 10:00:02] local.ERROR: Redis down".into(),
            ],
            false,
        );
        let grouped = group(repeated);
        assert_eq!((grouped.len(), grouped[0].count), (1, 2));
    }

    #[test]
    fn docker_frames_and_colours() {
        let mut body = vec![1, 0, 0, 0, 0, 0, 0, 6];
        body.extend(b"hello\n");
        body.extend([2, 0, 0, 0, 0, 0, 0, 4]);
        body.extend(b"err\n");
        assert_eq!(demux(&body), "hello\nerr\n");
        assert_eq!(demux(b"plain tty output\n"), "plain tty output\n");
        assert_eq!(clean("\u{1b}[31mred\u{1b}[0m text"), "red text");
    }

    #[test]
    fn finds_project_logs_and_globs() {
        let root = std::env::temp_dir().join(format!("corescope-logs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in ["storage/logs", "custom/a", "node_modules"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        for f in [
            "storage/logs/laravel.log",
            "debug.log",
            "custom/a/app.out",
            "node_modules/x.log",
            "README.md",
        ] {
            std::fs::write(root.join(f), "x\n").unwrap();
        }
        let found = project_files(&root, &["custom/**/*.out".into(), "../etc/passwd".into()]);
        let names: Vec<_> = found
            .iter()
            .map(|p| p.strip_prefix(&root).unwrap().to_string_lossy().to_string())
            .collect();
        let mut sorted = names.clone();
        sorted.sort();
        assert_eq!(
            sorted,
            ["custom/a/app.out", "debug.log", "storage/logs/laravel.log"]
        );
        assert!(wildcard("laravel-*.log", "laravel-2026-10-17.log") && !wildcard("*.log", "a.txt"));
        std::fs::remove_dir_all(root).unwrap();
    }
}
