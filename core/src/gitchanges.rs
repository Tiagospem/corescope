//! A repository's changes and what can be done with them by hand: status grouped like an IDE's
//! commit panel (staged, modified, new, removed/renamed, conflicts) with added/removed lines,
//! the branch against its upstream, the last commit, a unified diff, stage/unstage, discarding
//! tracked changes, and commit. Everything goes through the `git` CLI so hooks, signing and the
//! user's config apply.
use crate::git::{self, Output};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

/// Status entries beyond this are counted but not listed (an un-ignored build folder).
pub const MAX_FILES: usize = 2000;
/// Diffs are cut at this size.
pub const MAX_DIFF: usize = 512 * 1024;

#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct FileChange {
    pub path: String,
    /// The old path of a rename or copy.
    pub orig_path: Option<String>,
    /// Index (staged) and worktree status letters as git prints them ('.' = unchanged).
    pub index: char,
    pub worktree: char,
    pub conflict: bool,
    pub untracked: bool,
    /// Lines added/removed in the staged part and in the unstaged part.
    pub staged_added: Option<u64>,
    pub staged_removed: Option<u64>,
    pub added: Option<u64>,
    pub removed: Option<u64>,
    pub binary: bool,
}
impl FileChange {
    pub fn staged(&self) -> bool {
        !self.conflict && self.index != '.' && self.index != '?'
    }
    /// Unstaged part, or untracked.
    pub fn unstaged(&self) -> bool {
        self.untracked || (!self.conflict && self.worktree != '.')
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct Branch {
    pub head: Option<String>,
    pub oid: Option<String>,
    pub upstream: Option<String>,
    pub ahead: Option<u64>,
    pub behind: Option<u64>,
}
#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct LastCommit {
    pub short: String,
    pub subject: String,
    pub author: String,
    pub time: i64,
}
#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct Status {
    /// The working tree's top folder (paths below are relative to it).
    pub root: String,
    pub branch: Branch,
    pub last_commit: Option<LastCommit>,
    pub files: Vec<FileChange>,
    /// Entries left out past MAX_FILES.
    pub truncated: usize,
    pub staged: usize,
    pub modified: usize,
    pub untracked: usize,
    /// Deleted in the working tree (renames only exist once staged, under staged).
    pub removed_renamed: usize,
    pub conflicts: usize,
    /// Another git process holds `.git/index.lock`.
    pub locked: bool,
}

/// `git status --porcelain=v2 -z --branch` → branch and entries.
pub fn parse_status(raw: &str) -> (Branch, Vec<FileChange>) {
    let mut branch = Branch::default();
    let mut files = vec![];
    let mut fields = raw.split('\0').filter(|f| !f.is_empty());
    while let Some(entry) = fields.next() {
        if let Some(h) = entry.strip_prefix("# ") {
            let (key, value) = h.split_once(' ').unwrap_or((h, ""));
            match key {
                "branch.oid" if value != "(initial)" => {
                    branch.oid = Some(value.chars().take(12).collect())
                }
                "branch.head" if value != "(detached)" => branch.head = Some(value.into()),
                "branch.upstream" => branch.upstream = Some(value.into()),
                "branch.ab" => {
                    let mut parts = value.split(' ');
                    branch.ahead = parts
                        .next()
                        .and_then(|a| a.trim_start_matches('+').parse().ok());
                    branch.behind = parts
                        .next()
                        .and_then(|b| b.trim_start_matches('-').parse().ok());
                }
                _ => {}
            }
            continue;
        }
        let kind = entry.chars().next().unwrap_or(' ');
        let xy = |e: &str| {
            let mut c = e.get(2..4).unwrap_or("..").chars();
            (c.next().unwrap_or('.'), c.next().unwrap_or('.'))
        };
        match kind {
            '1' => {
                let (index, worktree) = xy(entry);
                // 1 XY sub mH mI mW hH hI path
                let path = entry.splitn(9, ' ').nth(8).unwrap_or("").to_string();
                files.push(FileChange {
                    path,
                    index,
                    worktree,
                    ..Default::default()
                });
            }
            '2' => {
                let (index, worktree) = xy(entry);
                // 2 XY sub mH mI mW hH hI Xscore path, then the original path as its own field.
                let path = entry.splitn(10, ' ').nth(9).unwrap_or("").to_string();
                let orig = fields.next().map(str::to_string);
                files.push(FileChange {
                    path,
                    orig_path: orig,
                    index,
                    worktree,
                    ..Default::default()
                });
            }
            'u' => {
                let (index, worktree) = xy(entry);
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let path = entry.splitn(11, ' ').nth(10).unwrap_or("").to_string();
                files.push(FileChange {
                    path,
                    index,
                    worktree,
                    conflict: true,
                    ..Default::default()
                });
            }
            '?' => files.push(FileChange {
                path: entry[2..].to_string(),
                index: '?',
                worktree: '?',
                untracked: true,
                ..Default::default()
            }),
            _ => {}
        }
    }
    (branch, files)
}

/// `git diff --numstat -z` → path → (added, removed); binary files are None.
pub fn parse_numstat(raw: &str) -> HashMap<String, Option<(u64, u64)>> {
    let mut out = HashMap::new();
    let mut fields = raw.split('\0');
    while let Some(entry) = fields.next() {
        if entry.is_empty() {
            continue;
        }
        let mut parts = entry.splitn(3, '\t');
        let (Some(a), Some(r), Some(path)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        // A rename prints an empty path followed by the old and new paths as fields.
        let path = if path.is_empty() {
            let _old = fields.next();
            fields.next().unwrap_or("").to_string()
        } else {
            path.to_string()
        };
        let lines = match (a.parse(), r.parse()) {
            (Ok(a), Ok(r)) => Some((a, r)),
            _ => None,
        };
        out.insert(path, lines);
    }
    out
}

fn read(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = git::run(dir, args, true, Duration::from_secs(20))?;
    if out.ok() {
        Ok(out.stdout)
    } else {
        Err(out.message())
    }
}

/// Lines of a new file for its +count (text files up to 2 MB).
fn count_lines(path: &Path) -> Option<u64> {
    let meta = std::fs::metadata(path).ok()?;
    if !meta.is_file() || meta.len() > 2 << 20 {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if bytes.iter().take(8000).any(|b| *b == 0) {
        return None;
    }
    Some(bytecount(&bytes))
}
fn bytecount(bytes: &[u8]) -> u64 {
    let n = bytes.iter().filter(|b| **b == b'\n').count() as u64;
    if bytes.last().is_some_and(|b| *b != b'\n') {
        n + 1
    } else {
        n
    }
}

pub fn status(folder: &Path) -> Result<Status, String> {
    let root = git::read(folder, &["rev-parse", "--show-toplevel"])
        .map(|r| r.trim().to_string())
        .ok_or("not a git repository")?;
    let root = Path::new(&root);
    let raw = read(
        root,
        &[
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "--untracked-files=all",
        ],
    )?;
    let (branch, mut files) = parse_status(&raw);
    let truncated = files.len().saturating_sub(MAX_FILES);
    files.truncate(MAX_FILES);
    let unstaged = parse_numstat(&read(root, &["diff", "--numstat", "-z"]).unwrap_or_default());
    let staged = if branch.oid.is_some() {
        parse_numstat(&read(root, &["diff", "--cached", "--numstat", "-z"]).unwrap_or_default())
    } else {
        HashMap::new()
    };
    for f in &mut files {
        if let Some(lines) = staged.get(&f.path) {
            f.binary |= lines.is_none();
            (f.staged_added, f.staged_removed) = (lines.map(|l| l.0), lines.map(|l| l.1));
        }
        if let Some(lines) = unstaged.get(&f.path) {
            f.binary |= lines.is_none();
            (f.added, f.removed) = (lines.map(|l| l.0), lines.map(|l| l.1));
        }
        if f.untracked {
            f.added = count_lines(&root.join(&f.path));
            f.binary = f.added.is_none();
            f.removed = Some(0);
        }
    }
    let last_commit =
        git::read(root, &["log", "-1", "--format=%h%x00%s%x00%an%x00%ct"]).and_then(|t| {
            let mut p = t.trim_end().split('\0');
            Some(LastCommit {
                short: p.next()?.into(),
                subject: p.next()?.into(),
                author: p.next()?.into(),
                time: p.next()?.parse().ok()?,
            })
        });
    let count = |f: &dyn Fn(&FileChange) -> bool| files.iter().filter(|x| f(x)).count();
    Ok(Status {
        root: root.to_string_lossy().into_owned(),
        staged: count(&|f| f.staged()),
        modified: count(&|f| !f.conflict && !f.untracked && matches!(f.worktree, 'M' | 'T')),
        untracked: count(&|f| f.untracked),
        removed_renamed: count(&|f| !f.conflict && f.worktree == 'D'),
        conflicts: count(&|f| f.conflict),
        locked: Path::new(
            &git::read(root, &["rev-parse", "--absolute-git-dir"])
                .unwrap_or_default()
                .trim(),
        )
        .join("index.lock")
        .exists(),
        branch,
        last_commit,
        files,
        truncated,
    })
}

/// What a compact row needs (floating panel, menu bar): branch and counts, from one
/// `git status` (no line counts).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
#[serde(default)]
pub struct Summary {
    pub branch: Branch,
    pub staged: usize,
    pub modified: usize,
    pub untracked: usize,
    pub removed: usize,
    pub conflicts: usize,
}
pub fn summarize(branch: Branch, files: &[FileChange]) -> Summary {
    let count = |f: &dyn Fn(&FileChange) -> bool| files.iter().filter(|x| f(x)).count();
    Summary {
        staged: count(&|f| f.staged()),
        modified: count(&|f| !f.conflict && !f.untracked && matches!(f.worktree, 'M' | 'T')),
        untracked: count(&|f| f.untracked),
        removed: count(&|f| !f.conflict && f.worktree == 'D'),
        conflicts: count(&|f| f.conflict),
        branch,
    }
}
pub fn summary(folder: &Path) -> Result<Summary, String> {
    let root = root_of(folder)?;
    let raw = read(
        &root,
        &[
            "status",
            "--porcelain=v2",
            "-z",
            "--branch",
            "--untracked-files=all",
        ],
    )?;
    let (branch, files) = parse_status(&raw);
    Ok(summarize(branch, &files))
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct CountChange {
    /// "staged", "modified", "untracked", "removed" or "conflicts".
    pub kind: &'static str,
    pub before: usize,
    pub after: usize,
}
/// What changed in a project between two notifications.
#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct Delta {
    pub changes: Vec<CountChange>,
    /// The branch changed (checkout, switch).
    pub branch_from: Option<String>,
    pub branch_to: Option<String>,
    /// A commit was made (or pulled) on the same branch: HEAD moved.
    pub new_head: bool,
    /// Uncommitted changes in total, now.
    pub total: usize,
}
/// The difference worth a notification, or None when nothing that counts moved. Saving a file
/// that was already modified changes nothing here, so it never notifies on its own.
pub fn delta(before: &Summary, after: &Summary) -> Option<Delta> {
    let pairs = [
        ("conflicts", before.conflicts, after.conflicts),
        ("staged", before.staged, after.staged),
        ("modified", before.modified, after.modified),
        ("untracked", before.untracked, after.untracked),
        ("removed", before.removed, after.removed),
    ];
    let changes: Vec<CountChange> = pairs
        .into_iter()
        .filter(|(_, b, a)| b != a)
        .map(|(kind, before, after)| CountChange {
            kind,
            before,
            after,
        })
        .collect();
    let (branch_from, branch_to) = if before.branch.head != after.branch.head {
        (before.branch.head.clone(), after.branch.head.clone())
    } else {
        (None, None)
    };
    let new_head =
        branch_to.is_none() && before.branch.oid.is_some() && before.branch.oid != after.branch.oid;
    if changes.is_empty() && branch_to.is_none() && branch_from.is_none() && !new_head {
        return None;
    }
    Some(Delta {
        changes,
        branch_from,
        branch_to,
        new_head,
        total: after.staged + after.modified + after.untracked + after.removed + after.conflicts,
    })
}

/// Paths given to git: relative to the repository, never escaping it.
pub fn valid_paths(paths: &[String]) -> Result<Vec<&str>, String> {
    if paths.is_empty() {
        return Err("no files given".into());
    }
    paths
        .iter()
        .map(|p| {
            let path = Path::new(p);
            if p.is_empty()
                || path.is_absolute()
                || path
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir))
            {
                Err(format!("invalid path: {p}"))
            } else {
                Ok(p.as_str())
            }
        })
        .collect()
}
fn root_of(folder: &Path) -> Result<std::path::PathBuf, String> {
    git::read(folder, &["rev-parse", "--show-toplevel"])
        .map(|r| std::path::PathBuf::from(r.trim()))
        .ok_or_else(|| "not a git repository".to_string())
}
/// Explains the usual failures in plain words, keeping git's own text.
fn explain(out: &Output) -> String {
    let msg = out.message();
    if msg.contains("index.lock") {
        format!(
            "Another git process is working in this repository (index.lock). Wait for it or remove the stale lock.\n{msg}"
        )
    } else {
        msg
    }
}
fn write(root: &Path, args: &[&str], timeout: u64) -> Result<Output, String> {
    let out = git::run(root, args, false, Duration::from_secs(timeout))?;
    if out.ok() {
        Ok(out)
    } else {
        Err(explain(&out))
    }
}

/// Unified diff of one file: staged (index vs HEAD), or the working tree (vs index); a new file
/// is shown whole.
pub fn diff(folder: &Path, path: &str, staged: bool) -> Result<String, String> {
    let root = root_of(folder)?;
    valid_paths(&[path.to_string()])?;
    let tracked = git::read(&root, &["ls-files", "--error-unmatch", "--", path]).is_some();
    let out = if !staged && !tracked {
        // Exit status 1 means "differences found" here.
        git::run(
            &root,
            &[
                "diff",
                "--no-color",
                "--no-ext-diff",
                "--no-index",
                "--",
                "/dev/null",
                path,
            ],
            true,
            Duration::from_secs(20),
        )?
    } else {
        let mut args = vec!["diff", "--no-color", "--no-ext-diff"];
        if staged {
            args.push("--cached");
        }
        args.extend(["--", path]);
        git::run(&root, &args, true, Duration::from_secs(20))?
    };
    if out.code > 1 {
        return Err(out.message());
    }
    let mut text = out.stdout;
    if text.len() > MAX_DIFF {
        let cut = (0..=MAX_DIFF)
            .rev()
            .find(|i| text.is_char_boundary(*i))
            .unwrap_or(0);
        text.truncate(cut);
        text.push_str("\n… (diff cut at 512 KB)\n");
    }
    Ok(text)
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct DiffLine {
    /// '+', '-' or ' ' (context).
    pub kind: char,
    pub old: Option<u32>,
    pub new: Option<u32>,
    pub text: String,
}
#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct Hunk {
    pub old_start: u32,
    pub old_len: u32,
    pub new_start: u32,
    pub new_len: u32,
    /// The function or section git names after `@@` (may be empty).
    pub section: String,
    pub lines: Vec<DiffLine>,
}
#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct FileDiff {
    pub path: String,
    pub orig_path: Option<String>,
    pub new_file: bool,
    pub deleted: bool,
    pub binary: bool,
    pub added: u32,
    pub removed: u32,
    pub hunks: Vec<Hunk>,
    /// Lines past MAX_FILE_LINES were left out.
    pub truncated: bool,
}
/// Lines kept per file in a structured diff.
pub const MAX_FILE_LINES: usize = 4000;

fn diff_path(raw: &str) -> Option<String> {
    let raw = raw.trim_end_matches('\t');
    if raw == "/dev/null" {
        return None;
    }
    let raw = raw.trim_matches('"');
    Some(
        raw.strip_prefix("a/")
            .or_else(|| raw.strip_prefix("b/"))
            .unwrap_or(raw)
            .to_string(),
    )
}
/// "@@ -12,3 +12,4 @@ fn x" → (12, 3, 12, 4, "fn x"); a missing length is 1.
fn hunk_header(line: &str) -> Option<(u32, u32, u32, u32, String)> {
    let rest = line.strip_prefix("@@ -")?;
    let (ranges, section) = rest.split_once(" @@").unwrap_or((rest, ""));
    let (old, new) = ranges.split_once(" +")?;
    let range = |r: &str| -> Option<(u32, u32)> {
        match r.split_once(',') {
            Some((a, b)) => Some((a.parse().ok()?, b.parse().ok()?)),
            None => Some((r.parse().ok()?, 1)),
        }
    };
    let (os, ol) = range(old)?;
    let (ns, nl) = range(new)?;
    Some((os, ol, ns, nl, section.trim().to_string()))
}

/// Unified diff text (`git diff`, any number of files) → files, hunks and numbered lines.
pub fn parse_unified(text: &str) -> Vec<FileDiff> {
    let mut files: Vec<FileDiff> = vec![];
    let mut old_no = 0u32;
    let mut new_no = 0u32;
    let mut kept = 0usize;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            // "a/P b/P": the halves are the same path unless renamed (then ---/+++ say).
            let half = rest.len().saturating_sub(5) / 2;
            let guess = rest
                .get(2..2 + half)
                .map(str::to_string)
                .filter(|p| rest == format!("a/{p} b/{p}"));
            files.push(FileDiff {
                path: guess.unwrap_or_default(),
                ..Default::default()
            });
            kept = 0;
            continue;
        }
        let Some(file) = files.last_mut() else {
            continue;
        };
        if file.hunks.is_empty() {
            if line.starts_with("new file mode") {
                file.new_file = true;
            } else if line.starts_with("deleted file mode") {
                file.deleted = true;
            } else if let Some(p) = line.strip_prefix("rename from ") {
                file.orig_path = Some(p.to_string());
            } else if let Some(p) = line.strip_prefix("rename to ") {
                file.path = p.to_string();
            } else if line.starts_with("Binary files ") {
                file.binary = true;
            } else if let Some(p) = line.strip_prefix("--- ").and_then(diff_path) {
                if file.path.is_empty() {
                    file.path = p;
                }
            } else if let Some(p) = line.strip_prefix("+++ ").and_then(diff_path) {
                file.path = p;
            }
        }
        if line.starts_with("@@ ") {
            if let Some((os, ol, ns, nl, section)) = hunk_header(line) {
                old_no = os;
                new_no = ns;
                file.hunks.push(Hunk {
                    old_start: os,
                    old_len: ol,
                    new_start: ns,
                    new_len: nl,
                    section,
                    lines: vec![],
                });
            }
            continue;
        }
        let Some(hunk) = file.hunks.last_mut() else {
            continue;
        };
        let (kind, text) = match line.chars().next() {
            Some('+') => ('+', &line[1..]),
            Some('-') => ('-', &line[1..]),
            Some(' ') => (' ', &line[1..]),
            Some('\\') => continue, // "\ No newline at end of file"
            None => (' ', ""),
            _ => continue,
        };
        match kind {
            '+' => file.added += 1,
            '-' => file.removed += 1,
            _ => {}
        }
        if kept >= MAX_FILE_LINES {
            file.truncated = true;
            continue;
        }
        kept += 1;
        let (old, new) = match kind {
            '+' => {
                new_no += 1;
                (None, Some(new_no - 1))
            }
            '-' => {
                old_no += 1;
                (Some(old_no - 1), None)
            }
            _ => {
                old_no += 1;
                new_no += 1;
                (Some(old_no - 1), Some(new_no - 1))
            }
        };
        hunk.lines.push(DiffLine {
            kind,
            old,
            new,
            text: text.to_string(),
        });
    }
    files
}

/// Structured diffs of several files. `mode`: "worktree" (index → working tree), "staged"
/// (HEAD → index) or "head" (HEAD → working tree, what Zed calls uncommitted changes). New
/// files are shown whole. `context` lines around each change (a large number shows the whole
/// file). An empty `paths` means every changed file.
pub fn file_diffs(
    folder: &Path,
    paths: &[String],
    mode: &str,
    context: u32,
) -> Result<Vec<FileDiff>, String> {
    let root = root_of(folder)?;
    let valid: Vec<&str> = if paths.is_empty() {
        vec![]
    } else {
        valid_paths(paths)?
    };
    let has_head = git::read(&root, &["rev-parse", "-q", "--verify", "HEAD"]).is_some();
    // An empty tree stands in for HEAD before the first commit.
    let base = if has_head {
        "HEAD"
    } else {
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    };
    let unified = format!("-U{}", context.min(1_000_000));
    let mut args = vec![
        "-c",
        "core.quotepath=false",
        "diff",
        "--no-color",
        "--no-ext-diff",
        "-M",
        unified.as_str(),
    ];
    match mode {
        "worktree" => {}
        "staged" => args.extend(["--cached", base]),
        "head" => args.push(base),
        _ => return Err("mode must be worktree, staged or head".into()),
    }
    args.push("--");
    args.extend(valid.iter().copied());
    let out = git::run(&root, &args, true, Duration::from_secs(30))?;
    if !out.ok() {
        return Err(out.message());
    }
    let mut text = out.stdout;
    if text.len() > MAX_DIFF * 4 {
        let cut = (0..=MAX_DIFF * 4)
            .rev()
            .find(|i| text.is_char_boundary(*i))
            .unwrap_or(0);
        text.truncate(cut);
    }
    let mut files = parse_unified(&text);
    // Untracked files: whole, as additions (not in "staged").
    if mode != "staged" {
        let mut untracked_args = vec!["ls-files", "--others", "--exclude-standard", "-z", "--"];
        untracked_args.extend(valid.iter().copied());
        let listed = read(&root, &untracked_args).unwrap_or_default();
        for path in listed.split('\0').filter(|p| !p.is_empty()).take(200) {
            let out = git::run(
                &root,
                &[
                    "-c",
                    "core.quotepath=false",
                    "diff",
                    "--no-color",
                    "--no-ext-diff",
                    "--no-index",
                    "--",
                    "/dev/null",
                    path,
                ],
                true,
                Duration::from_secs(20),
            )?;
            if out.code > 1 {
                continue;
            }
            for mut f in parse_unified(&out.stdout) {
                f.path = path.to_string();
                f.new_file = true;
                files.push(f);
            }
        }
    }
    Ok(files)
}

pub fn stage(folder: &Path, paths: &[String]) -> Result<(), String> {
    let root = root_of(folder)?;
    let mut args = vec!["add", "-A", "--"];
    args.extend(valid_paths(paths)?);
    write(&root, &args, 60).map(|_| ())
}
pub fn unstage(folder: &Path, paths: &[String]) -> Result<(), String> {
    let root = root_of(folder)?;
    let has_head = git::read(&root, &["rev-parse", "-q", "--verify", "HEAD"]).is_some();
    let mut args: Vec<&str> = if has_head {
        vec!["restore", "--staged", "--"]
    } else {
        // No commit yet: nothing to restore from, so drop the entries from the index.
        vec!["rm", "--cached", "-r", "-q", "--"]
    };
    args.extend(valid_paths(paths)?);
    write(&root, &args, 60).map(|_| ())
}
/// Puts tracked files back to the last commit (staged and unstaged changes). New files are not
/// touched here: the app moves them to the Trash.
pub fn discard(folder: &Path, paths: &[String]) -> Result<(), String> {
    let root = root_of(folder)?;
    let mut args = vec!["restore", "--source=HEAD", "--staged", "--worktree", "--"];
    args.extend(valid_paths(paths)?);
    write(&root, &args, 60).map(|_| ())
}
/// Commits what is staged with the message; hooks and signing run as configured. Returns git's
/// output (hook output included).
pub fn commit(folder: &Path, message: &str) -> Result<String, String> {
    let root = root_of(folder)?;
    if message.trim().is_empty() {
        return Err("the commit message is empty".into());
    }
    let out = git::run(
        &root,
        &["commit", "-m", message],
        false,
        Duration::from_secs(300),
    )?;
    if out.ok() {
        Ok(format!("{}{}", out.stdout, out.stderr).trim().to_string())
    } else {
        Err(explain(&out))
    }
}
/// Which of these paths (relative to the repository) git ignores, for the file watcher.
pub fn ignored(folder: &Path, paths: &[String]) -> Result<Vec<String>, String> {
    let root = root_of(folder)?;
    let valid = valid_paths(paths)?;
    let mut args = vec!["check-ignore", "--"];
    args.extend(valid);
    let out = git::run(&root, &args, true, Duration::from_secs(10))?;
    // 1 = none ignored.
    if out.code > 1 {
        return Err(out.message());
    }
    Ok(out.stdout.lines().map(str::to_string).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn porcelain_v2_entries_and_branch() {
        let raw = "# branch.oid 1234567890abcdef\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0\
                   1 M. N... 100644 100644 100644 aaa bbb src/a.rs\0\
                   1 .M N... 100644 100644 100644 aaa bbb docs/b c.md\0\
                   2 R. N... 100644 100644 100644 aaa bbb R100 new.rs\0old.rs\0\
                   u UU N... 100644 100644 100644 100644 a b c conflict.txt\0\
                   ? untracked file.txt\0";
        let (b, files) = parse_status(raw);
        assert_eq!(
            (b.head.as_deref(), b.upstream.as_deref(), b.ahead, b.behind),
            (Some("main"), Some("origin/main"), Some(2), Some(1))
        );
        assert_eq!(files.len(), 5);
        assert!(files[0].staged() && !files[0].unstaged());
        assert_eq!(files[1].path, "docs/b c.md", "spaces in paths survive");
        assert!(!files[1].staged() && files[1].unstaged());
        assert_eq!(
            (files[2].path.as_str(), files[2].orig_path.as_deref()),
            ("new.rs", Some("old.rs"))
        );
        assert!(files[3].conflict && !files[3].staged());
        assert!(files[4].untracked && files[4].path == "untracked file.txt");
        let sum = summarize(b.clone(), &files);
        assert_eq!(
            (sum.staged, sum.modified, sum.untracked, sum.conflicts),
            (2, 1, 1, 1),
            "the rename counts as staged"
        );
        let (initial, _) = parse_status("# branch.oid (initial)\0# branch.head main\0");
        assert!(initial.oid.is_none() && initial.ahead.is_none());
    }

    #[test]
    fn numstat_with_renames_and_binaries() {
        let raw = "3\t1\tsrc/a.rs\0-\t-\timage.png\0\
                   2\t0\t\0old name.rs\0new name.rs\0";
        let n = parse_numstat(raw);
        assert_eq!(n["src/a.rs"], Some((3, 1)));
        assert_eq!(n["image.png"], None);
        assert_eq!(n["new name.rs"], Some((2, 0)));
        assert!(
            valid_paths(&["../x".into()]).is_err() && valid_paths(&["/etc/passwd".into()]).is_err()
        );
        assert!(valid_paths(&["a/b.rs".into()]).is_ok());
        assert_eq!(bytecount(b"a\nb\nc"), 3);
    }

    #[test]
    fn notification_delta_counts_only_what_moved() {
        let base = Summary {
            branch: Branch {
                head: Some("main".into()),
                oid: Some("aaa".into()),
                ..Default::default()
            },
            modified: 2,
            untracked: 1,
            ..Default::default()
        };
        assert_eq!(
            delta(&base, &base.clone()),
            None,
            "saving an already modified file"
        );
        let mut more = base.clone();
        more.untracked = 4;
        more.modified = 5;
        let d = delta(&base, &more).unwrap();
        let kinds: Vec<(&str, usize, usize)> = d
            .changes
            .iter()
            .map(|c| (c.kind, c.before, c.after))
            .collect();
        assert_eq!(kinds, [("modified", 2, 5), ("untracked", 1, 4)]);
        assert_eq!(d.total, 9);
        assert!(!d.new_head && d.branch_to.is_none());
        let mut committed = base.clone();
        committed.modified = 0;
        committed.untracked = 0;
        committed.branch.oid = Some("bbb".into());
        let d = delta(&base, &committed).unwrap();
        assert!(d.new_head && d.total == 0);
        let mut switched = base.clone();
        switched.branch.head = Some("feature".into());
        switched.branch.oid = Some("ccc".into());
        let d = delta(&base, &switched).unwrap();
        assert_eq!(
            (d.branch_from.as_deref(), d.branch_to.as_deref(), d.new_head),
            (Some("main"), Some("feature"), false),
            "a checkout is a branch change, not a new commit"
        );
        let back: Summary = serde_json::from_value(serde_json::to_value(&more).unwrap()).unwrap();
        assert_eq!(back, more, "the app hands the last summary back as JSON");
    }

    #[test]
    fn unified_diff_becomes_numbered_hunks() {
        let text = "diff --git a/a b.txt b/a b.txt\nindex 1..2 100644\n--- a/a b.txt\t\n+++ b/a b.txt\t\n@@ -1,3 +1,3 @@ fn top\n a\n-b\n+c\n d\n@@ -10 +10,2 @@\n x\n+y\n\\ No newline at end of file\n\
                    diff --git a/old.rs b/new.rs\nsimilarity index 90%\nrename from old.rs\nrename to new.rs\n\
                    diff --git a/bin.dat b/bin.dat\nnew file mode 100644\nBinary files /dev/null and b/bin.dat differ\n\
                    diff --git a/gone.md b/gone.md\ndeleted file mode 100644\n--- a/gone.md\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n";
        let files = parse_unified(text);
        assert_eq!(files.len(), 4);
        let a = &files[0];
        assert_eq!((a.path.as_str(), a.added, a.removed), ("a b.txt", 2, 1));
        assert_eq!(a.hunks[0].section, "fn top");
        let lines: Vec<(char, Option<u32>, Option<u32>)> = a.hunks[0]
            .lines
            .iter()
            .map(|l| (l.kind, l.old, l.new))
            .collect();
        assert_eq!(
            lines,
            [
                (' ', Some(1), Some(1)),
                ('-', Some(2), None),
                ('+', None, Some(2)),
                (' ', Some(3), Some(3))
            ]
        );
        assert_eq!((a.hunks[1].old_len, a.hunks[1].new_start), (1, 10));
        assert_eq!(
            a.hunks[1].lines.len(),
            2,
            "the no-newline marker is not a line"
        );
        assert_eq!(
            (files[1].path.as_str(), files[1].orig_path.as_deref()),
            ("new.rs", Some("old.rs"))
        );
        assert!(files[2].binary && files[2].new_file && files[2].path == "bin.dat");
        assert!(files[3].deleted && files[3].path == "gone.md" && files[3].removed == 1);
    }

    #[test]
    fn stage_unstage_diff_discard_commit_on_a_real_repository() {
        let repo = crate::git::tests::scratch("changes");
        std::fs::write(repo.join("a.txt"), "a\nb\n").unwrap();
        std::fs::write(repo.join("new.txt"), "one\ntwo\nthree\n").unwrap();
        let s = status(&repo).unwrap();
        assert_eq!((s.modified, s.untracked, s.staged), (1, 1, 0));
        let a = s.files.iter().find(|f| f.path == "a.txt").unwrap();
        assert_eq!((a.added, a.removed), (Some(1), Some(0)));
        assert_eq!(
            s.files.iter().find(|f| f.path == "new.txt").unwrap().added,
            Some(3)
        );
        assert_eq!(
            s.last_commit.as_ref().map(|c| c.subject.as_str()),
            Some("first")
        );
        assert!(diff(&repo, "a.txt", false).unwrap().contains("+b"));
        assert!(diff(&repo, "new.txt", false).unwrap().contains("+three"));
        let all = file_diffs(&repo, &[], "head", 3).unwrap();
        assert_eq!(all.len(), 2, "tracked change and the new file");
        let new = all.iter().find(|f| f.path == "new.txt").unwrap();
        assert!(new.new_file && new.added == 3);
        assert_eq!(new.hunks[0].lines[2].new, Some(3));
        let one = file_diffs(&repo, &["a.txt".into()], "worktree", 3).unwrap();
        assert_eq!((one.len(), one[0].added), (1, 1));
        assert!(file_diffs(&repo, &[], "staged", 3).unwrap().is_empty());
        stage(&repo, &["a.txt".into(), "new.txt".into()]).unwrap();
        let s = status(&repo).unwrap();
        assert_eq!((s.staged, s.modified, s.untracked), (2, 0, 0));
        assert!(diff(&repo, "a.txt", true).unwrap().contains("+b"));
        unstage(&repo, &["new.txt".into()]).unwrap();
        assert_eq!(status(&repo).unwrap().untracked, 1);
        assert!(commit(&repo, "  ").is_err());
        let git_identity = crate::git::run(
            &repo,
            &["config", "user.name", "t"],
            false,
            Duration::from_secs(5),
        )
        .unwrap();
        assert!(git_identity.ok());
        crate::git::run(
            &repo,
            &["config", "user.email", "t@t"],
            false,
            Duration::from_secs(5),
        )
        .unwrap();
        crate::git::run(
            &repo,
            &["config", "commit.gpgsign", "false"],
            false,
            Duration::from_secs(5),
        )
        .unwrap();
        let out = commit(&repo, "change a\n\nwith a body").unwrap();
        assert!(out.contains("change a"), "{out}");
        let s = status(&repo).unwrap();
        assert_eq!((s.staged, s.untracked), (0, 1));
        assert_eq!(s.last_commit.unwrap().subject, "change a");
        std::fs::write(repo.join("a.txt"), "changed again\n").unwrap();
        discard(&repo, &["a.txt".into()]).unwrap();
        assert_eq!(
            std::fs::read_to_string(repo.join("a.txt")).unwrap(),
            "a\nb\n"
        );
        std::fs::write(repo.join(".gitignore"), "build/\n").unwrap();
        let ig = ignored(
            &repo,
            &["build/".into(), "build/out.o".into(), "src/main.rs".into()],
        )
        .unwrap();
        assert_eq!(
            ig,
            ["build/", "build/out.o"],
            "folders are asked with a trailing slash"
        );
        std::fs::write(repo.join(".git/index.lock"), "").unwrap();
        assert!(status(&repo).unwrap().locked);
        assert!(
            stage(&repo, &["new.txt".into()])
                .unwrap_err()
                .contains("index.lock")
        );
        std::fs::remove_dir_all(repo.parent().unwrap()).unwrap();
    }
}
