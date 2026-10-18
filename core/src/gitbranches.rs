//! A project's local branches and worktrees, for viewing: the current branch, each branch's last
//! commit and distance from its upstream, and every working tree of the repository with what the
//! Cleanup page also weighs (branch merged or not, uncommitted changes, a process working in it,
//! git lock) plus its size, measured on request and cached.
use crate::Process;
use crate::git::{self, Output};
use crate::worktrees;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Branches beyond this are counted, not listed (newest first).
pub const MAX_BRANCHES: usize = 300;

#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct LocalBranch {
    pub name: String,
    pub current: bool,
    pub head: String,
    pub subject: String,
    pub author: String,
    pub time: i64,
    pub upstream: Option<String>,
    pub ahead: Option<u64>,
    pub behind: Option<u64>,
    /// The upstream branch was deleted on the remote.
    pub gone: bool,
    /// Checked out in this other working tree.
    pub worktree: Option<String>,
}
#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct Branches {
    pub branches: Vec<LocalBranch>,
    pub truncated: usize,
}

/// Fields of `git branch --format`, separated by NUL (`%00`), one branch per line.
pub const BRANCH_FORMAT: &str = "%(HEAD)%00%(refname:short)%00%(objectname:short)%00%(committerdate:unix)%00%(authorname)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(worktreepath)%00%(subject)";

/// "ahead 2, behind 1", "ahead 3", "gone", "" → (ahead, behind, gone).
pub fn parse_track(track: &str) -> (Option<u64>, Option<u64>, bool) {
    if track.trim() == "gone" {
        return (None, None, true);
    }
    let mut ahead = Some(0);
    let mut behind = Some(0);
    for part in track.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        if let Some(n) = part.strip_prefix("ahead ") {
            ahead = n.parse().ok();
        } else if let Some(n) = part.strip_prefix("behind ") {
            behind = n.parse().ok();
        }
    }
    (ahead, behind, false)
}

/// `git branch --format=BRANCH_FORMAT` → branches, the current one first. `here` is this working
/// tree's root, so only other worktrees are named.
pub fn parse_branches(text: &str, here: &str) -> Vec<LocalBranch> {
    let mut out: Vec<LocalBranch> = text
        .lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.splitn(9, '\0').collect();
            if f.len() < 9 || f[1].is_empty() || f[1].starts_with("(HEAD detached") {
                return None;
            }
            let upstream = (!f[5].is_empty()).then(|| f[5].to_string());
            let (ahead, behind, gone) = if upstream.is_some() {
                parse_track(f[6])
            } else {
                (None, None, false)
            };
            Some(LocalBranch {
                current: f[0] == "*",
                name: f[1].into(),
                head: f[2].into(),
                time: f[3].parse().unwrap_or(0),
                author: f[4].into(),
                upstream,
                ahead,
                behind,
                gone,
                worktree: (!f[7].is_empty() && f[7] != here).then(|| f[7].to_string()),
                subject: f[8].into(),
            })
        })
        .collect();
    out.sort_by_key(|b| (!b.current, -b.time));
    out
}

fn root_of(folder: &Path) -> Result<PathBuf, String> {
    git::read(folder, &["rev-parse", "--show-toplevel"])
        .map(|r| PathBuf::from(r.trim()))
        .ok_or_else(|| "not a git repository".to_string())
}

pub fn branches(folder: &Path) -> Result<Branches, String> {
    let root = root_of(folder)?;
    let format = format!("--format={BRANCH_FORMAT}");
    let out: Output = git::run(
        &root,
        &["branch", "--list", "--sort=-committerdate", &format],
        true,
        Duration::from_secs(15),
    )?;
    if !out.ok() {
        return Err(out.message());
    }
    let mut branches = parse_branches(&out.stdout, &root.to_string_lossy());
    let truncated = branches.len().saturating_sub(MAX_BRANCHES);
    branches.truncate(MAX_BRANCHES);
    Ok(Branches {
        branches,
        truncated,
    })
}

#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct WorktreeView {
    pub path: String,
    pub branch: Option<String>,
    pub head: String,
    /// The repository's main working tree.
    pub main: bool,
    /// The working tree this project points at.
    pub current: bool,
    pub agent: Option<String>,
    pub locked: bool,
    /// The folder is gone; git lists it until `git worktree prune`.
    pub prunable: bool,
    /// Merged into the default branch (None: unknown, detached or the default branch itself).
    pub merged: Option<bool>,
    /// Uncommitted changes (None: git could not read it).
    pub changes: Option<usize>,
    /// A process working inside it, as "name (PID n)".
    pub in_use: Option<String>,
    pub last_commit: Option<i64>,
    /// Bytes from the size cache, when measured in the last 10 minutes.
    pub size: Option<u64>,
}

/// `git worktree list --porcelain` → every working tree, main first.
pub fn parse_all(text: &str, repo: &Path) -> Vec<worktrees::Worktree> {
    let mut all = vec![];
    if let Some(first) = text.split("\n\n").next() {
        // `parse_list` skips the first block (the main tree): give it an empty one to skip.
        all.extend(worktrees::parse_list(&format!("\n\n{first}"), repo));
    }
    all.extend(worktrees::parse_list(text, repo));
    all
}

fn inside(path: &str, folder: &str) -> bool {
    !path.is_empty() && Path::new(path).starts_with(folder)
}

/// The project's worktrees with their state. Sizes come from the cache only.
pub fn worktrees(folder: &Path, processes: &[Process]) -> Result<Vec<WorktreeView>, String> {
    let root = root_of(folder)?;
    let repo = worktrees::main_repo(&root).unwrap_or_else(|| root.clone());
    let text = worktrees::git(
        &repo,
        &["worktree", "list", "--porcelain"],
        Duration::from_secs(5),
    )
    .ok_or("git worktree list failed")?;
    let canon = |p: &str| {
        Path::new(p)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(p))
    };
    let here = canon(&root.to_string_lossy());
    let me = std::process::id() as i32;
    let all = parse_all(&text, &repo);
    let paths: Vec<String> = all.iter().map(|w| w.path.clone()).collect();
    // A process belongs to the deepest working tree holding it (linked worktrees often live
    // inside the main one, as in `.claude/worktrees`).
    let owner = |dir: &str| {
        paths
            .iter()
            .filter(|w| inside(dir, w))
            .max_by_key(|w| w.len())
            .cloned()
    };
    let mut users: HashMap<String, String> = HashMap::new();
    for p in processes.iter().filter(|p| p.pid != me) {
        for dir in [&p.cwd, &p.path] {
            if let Some(w) = owner(dir) {
                users
                    .entry(w)
                    .or_insert_with(|| format!("{} (PID {})", p.name, p.pid));
                break;
            }
        }
    }
    Ok(all
        .into_iter()
        .enumerate()
        .map(|(i, w)| {
            let path = Path::new(&w.path);
            let exists = path.is_dir();
            let in_use = users.get(&w.path).cloned();
            WorktreeView {
                main: i == 0,
                current: canon(&w.path) == here,
                merged: match (&w.branch, i == 0) {
                    (Some(b), false) => worktrees::merged(&repo, b),
                    _ => None,
                },
                changes: if exists && !w.prunable {
                    worktrees::dirty(path)
                } else {
                    None
                },
                last_commit: if exists {
                    worktrees::last_commit(path)
                } else {
                    None
                },
                size: cached_size(&w.path),
                in_use: if exists { in_use } else { None },
                agent: w.agent.map(str::to_string),
                path: w.path,
                branch: w.branch,
                head: w.head.chars().take(8).collect(),
                locked: w.locked,
                prunable: w.prunable,
            }
        })
        .collect())
}

static SIZES: Mutex<Option<HashMap<String, (u64, Instant)>>> = Mutex::new(None);
const SIZE_TTL: Duration = Duration::from_secs(600);

fn cached_size(path: &str) -> Option<u64> {
    let guard = SIZES.lock().ok()?;
    let (bytes, at) = guard.as_ref()?.get(path)?;
    (at.elapsed() < SIZE_TTL).then_some(*bytes)
}
/// Disk used by a working tree (allocated blocks, hard links once), cached for 10 minutes. Only
/// paths git lists as a worktree of the project are measured.
pub fn worktree_size(folder: &Path, path: &str) -> Result<u64, String> {
    if let Some(bytes) = cached_size(path) {
        return Ok(bytes);
    }
    let root = root_of(folder)?;
    let repo = worktrees::main_repo(&root).unwrap_or(root);
    let text = worktrees::git(
        &repo,
        &["worktree", "list", "--porcelain"],
        Duration::from_secs(5),
    )
    .ok_or("git worktree list failed")?;
    let all = parse_all(&text, &repo);
    if !all.iter().any(|w| w.path == path) {
        return Err("not a worktree of this project".into());
    }
    // Worktrees nested inside this one are measured on their own, not twice.
    let nested: Vec<PathBuf> = all
        .iter()
        .filter(|w| w.path != path && inside(&w.path, path))
        .map(|w| PathBuf::from(&w.path))
        .collect();
    let bytes = measure(Path::new(path), &nested);
    if let Ok(mut guard) = SIZES.lock() {
        guard
            .get_or_insert_with(HashMap::new)
            .insert(path.to_string(), (bytes, Instant::now()));
    }
    Ok(bytes)
}

/// Allocated bytes under `path` (hard links once), skipping `skip` and never following symlinks.
fn measure(path: &Path, skip: &[PathBuf]) -> u64 {
    use std::os::unix::fs::MetadataExt;
    let mut seen = std::collections::HashSet::new();
    let mut bytes = 0u64;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if meta.nlink() > 1 && !meta.is_dir() && !seen.insert((meta.dev(), meta.ino())) {
                continue;
            }
            if meta.is_dir() {
                let child = entry.path();
                if skip.contains(&child) {
                    continue;
                }
                stack.push(child);
            }
            bytes += meta.blocks() * 512;
        }
    }
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_format_and_tracking() {
        let line = |fields: &[&str]| fields.join("\0");
        let text = [
            line(&[
                " ",
                "feature/x",
                "abc1234",
                "1700000000",
                "Ana",
                "origin/feature/x",
                "ahead 2, behind 1",
                "/repo-wt",
                "Add x",
            ]),
            line(&[
                "*",
                "main",
                "def5678",
                "1700000500",
                "Bob",
                "origin/main",
                "",
                "/repo",
                "Merge stuff",
            ]),
            line(&[
                " ",
                "old",
                "aaa1111",
                "1600000000",
                "Ana",
                "origin/old",
                "gone",
                "",
                "Old: a subject",
            ]),
            line(&[
                " ",
                "local-only",
                "bbb2222",
                "1650000000",
                "Ana",
                "",
                "",
                "",
                "Local",
            ]),
        ]
        .join("\n");
        let text = text.as_str();
        let b = parse_branches(text, "/repo");
        assert_eq!(b[0].name, "main", "current branch first");
        assert!(
            b[0].current && b[0].worktree.is_none(),
            "its own worktree is not named"
        );
        assert_eq!((b[0].ahead, b[0].behind), (Some(0), Some(0)), "in sync");
        assert_eq!(b[1].name, "feature/x");
        assert_eq!(
            (b[1].ahead, b[1].behind, b[1].worktree.as_deref()),
            (Some(2), Some(1), Some("/repo-wt"))
        );
        let local = b.iter().find(|x| x.name == "local-only").unwrap();
        assert!(local.upstream.is_none() && local.ahead.is_none());
        let old = b.iter().find(|x| x.name == "old").unwrap();
        assert!(old.gone && old.subject == "Old: a subject");
        assert_eq!(parse_track("behind 4"), (Some(0), Some(4), false));
    }

    #[test]
    fn porcelain_worktrees_include_the_main_one() {
        let text = "worktree /repo\nHEAD 1111111111111111\nbranch refs/heads/main\n\n\
                    worktree /repo/.claude/worktrees/a\nHEAD 2222222222222222\nbranch refs/heads/feat\nlocked agent running\n\n\
                    worktree /gone\nHEAD 3333333333333333\ndetached\nprunable gitdir file points to non-existent location\n";
        let all = parse_all(text, Path::new("/repo"));
        assert_eq!(all.len(), 3);
        assert_eq!(
            (all[0].path.as_str(), all[0].branch.as_deref()),
            ("/repo", Some("main"))
        );
        assert!(all[1].locked && all[1].agent == Some("Claude Code"));
        assert!(all[2].prunable && all[2].branch.is_none());
    }

    #[test]
    fn real_branches_and_worktrees() {
        let repo = crate::git::tests::scratch("branches");
        let run = |args: &[&str]| {
            let o = git::run(&repo, args, false, Duration::from_secs(20)).unwrap();
            assert!(o.ok(), "{args:?}: {}", o.message());
        };
        run(&["branch", "topic"]);
        let wt = repo.parent().unwrap().join("wt");
        run(&["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()]);
        std::fs::write(wt.join("x.txt"), "x").unwrap();
        let b = branches(&repo).unwrap();
        assert_eq!(b.branches[0].name, "main");
        assert!(b.branches[0].current);
        let feat = b.branches.iter().find(|x| x.name == "feat").unwrap();
        assert!(feat.worktree.is_some(), "checked out elsewhere");
        let mut me = crate::process_fixture();
        me.pid = 1;
        me.name = "node".into();
        me.cwd = wt.canonicalize().unwrap().to_string_lossy().into();
        let list = worktrees(&repo, &[me]).unwrap();
        assert_eq!(list.len(), 2);
        assert!(list[0].main && list[0].current && list[0].changes == Some(0));
        assert_eq!(list[1].changes, Some(1));
        assert_eq!(list[1].merged, Some(true), "no commits of its own yet");
        assert_eq!(list[1].in_use.as_deref(), Some("node (PID 1)"));
        assert!(list[1].size.is_none(), "not measured yet");
        let bytes = worktree_size(&repo, &list[1].path).unwrap();
        assert!(bytes > 0);
        assert_eq!(
            worktrees(&repo, &[]).unwrap()[1].size,
            Some(bytes),
            "cached"
        );
        assert!(worktree_size(&repo, "/etc").is_err());
        // A worktree nested inside the main one is not counted in the main one's size.
        let nested = repo.join(".claude/worktrees/n");
        run(&[
            "worktree",
            "add",
            "-q",
            "-b",
            "nested",
            nested.to_str().unwrap(),
        ]);
        std::fs::write(nested.join("big.bin"), vec![1u8; 4 << 20]).unwrap();
        let listed = worktrees(&repo, &[]).unwrap();
        let main_size = worktree_size(&repo, &listed[0].path).unwrap();
        let nested_path = listed
            .iter()
            .find(|w| w.branch.as_deref() == Some("nested"))
            .unwrap()
            .path
            .clone();
        assert!(worktree_size(&repo, &nested_path).unwrap() >= 4 << 20);
        assert!(main_size < 4 << 20, "{main_size}");
        std::fs::remove_dir_all(repo.parent().unwrap()).unwrap();
    }
}
