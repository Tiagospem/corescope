//! Git worktrees that agents leave behind (Claude Code's `.claude/worktrees`, Codex's
//! `~/.codex/worktrees`, Conductor, Cursor, or any `git worktree add`), with what decides whether
//! one can go: its branch, merged or not, uncommitted changes and age. Also which repository and
//! working tree a folder belongs to, so sessions sharing one can be flagged.
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Worktree {
    pub path: String,
    /// The repository's main working tree.
    pub repo: String,
    pub branch: Option<String>,
    pub head: String,
    /// Which tool made it, from where it lives.
    pub agent: Option<&'static str>,
    pub locked: bool,
    /// The folder is gone; git still lists it until `git worktree prune`.
    pub prunable: bool,
}

/// The working tree a path is in: the nearest folder with a `.git` (directory or file).
pub fn toplevel(path: &Path) -> Option<PathBuf> {
    path.ancestors()
        .take(12)
        .find(|a| a.join(".git").exists())
        .map(Path::to_path_buf)
}
/// For a linked worktree, the main repository folder (from its `.git` file); None otherwise.
pub fn main_repo(worktree: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(worktree.join(".git")).ok()?;
    let gitdir = PathBuf::from(text.trim().strip_prefix("gitdir:")?.trim());
    // <repo>/.git/worktrees/<name>
    let dotgit = gitdir.parent()?.parent()?;
    (dotgit.file_name()? == ".git").then(|| dotgit.parent().map(Path::to_path_buf))?
}
/// The tool that keeps worktrees in this path's style of location.
pub fn agent_of(path: &str) -> Option<&'static str> {
    if path.contains("/.claude/worktrees/") {
        Some("Claude Code")
    } else if path.contains("/.codex/worktrees/") || path.contains("/.codex/") {
        Some("Codex")
    } else if path.contains("/conductor/") {
        Some("Conductor")
    } else if path.contains("/.cursor/") || path.contains("/cursor-worktrees/") {
        Some("Cursor")
    } else {
        None
    }
}

/// Runs git read-only (no optional locks, no fsmonitor) with a time limit; stdout on success.
pub fn git(repo: &Path, args: &[&str], timeout: Duration) -> Option<String> {
    crate::git::run(repo, args, true, timeout)
        .ok()
        .filter(crate::git::Output::ok)
        .map(|o| o.stdout)
}

/// `git worktree list --porcelain` → linked worktrees (the main one excluded).
pub fn parse_list(text: &str, repo: &Path) -> Vec<Worktree> {
    let mut out = vec![];
    // git lists the main working tree first; the rest are linked worktrees.
    for block in text.split("\n\n").skip(1) {
        let mut wt = Worktree {
            path: String::new(),
            repo: repo.to_string_lossy().into(),
            branch: None,
            head: String::new(),
            agent: None,
            locked: false,
            prunable: false,
        };
        for line in block.lines() {
            if let Some(p) = line.strip_prefix("worktree ") {
                wt.path = p.to_string();
            } else if let Some(h) = line.strip_prefix("HEAD ") {
                wt.head = h.chars().take(12).collect();
            } else if let Some(b) = line.strip_prefix("branch ") {
                wt.branch = Some(b.trim_start_matches("refs/heads/").to_string());
            } else if line.starts_with("locked") {
                wt.locked = true;
            } else if line.starts_with("prunable") {
                wt.prunable = true;
            }
        }
        if wt.path.is_empty() {
            continue;
        }
        wt.agent = agent_of(&wt.path);
        out.push(wt);
    }
    out
}
pub fn list(repo: &Path) -> Vec<Worktree> {
    git(
        repo,
        &["worktree", "list", "--porcelain"],
        Duration::from_secs(5),
    )
    .map(|t| parse_list(&t, repo))
    .unwrap_or_default()
}

/// Uncommitted changes (tracked and untracked) in a working tree; None if git failed.
pub fn dirty(worktree: &Path) -> Option<usize> {
    git(
        worktree,
        &["status", "--porcelain"],
        Duration::from_secs(10),
    )
    .map(|t| t.lines().count())
}
/// Time of the last commit on the worktree's HEAD.
pub fn last_commit(worktree: &Path) -> Option<i64> {
    git(
        worktree,
        &["log", "-1", "--format=%ct"],
        Duration::from_secs(5),
    )?
    .trim()
    .parse()
    .ok()
}
/// Whether `branch` is fully merged into the repository's default branch (origin/HEAD, main or
/// master).
pub fn merged(repo: &Path, branch: &str) -> Option<bool> {
    let default = git(
        repo,
        &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        Duration::from_secs(3),
    )
    .map(|s| s.trim().to_string())
    .or_else(|| {
        ["main", "master"]
            .iter()
            .find(|b| {
                git(
                    repo,
                    &["rev-parse", "--verify", "--quiet", b],
                    Duration::from_secs(3),
                )
                .is_some()
            })
            .map(|b| b.to_string())
    })?;
    if default.ends_with(&format!("/{branch}")) || default == branch {
        return Some(false);
    }
    let out = git(
        repo,
        &["branch", "--merged", &default, "--format=%(refname:short)"],
        Duration::from_secs(5),
    )?;
    Some(out.lines().any(|l| l.trim() == branch))
}

/// Main repositories under the roots (folders whose `.git` is a directory), a few levels deep.
pub fn repos_under(roots: &[PathBuf]) -> Vec<PathBuf> {
    const SKIP: [&str; 6] = [
        "node_modules",
        "vendor",
        "target",
        "build",
        "dist",
        "Library",
    ];
    let mut found = vec![];
    let mut stack: Vec<(PathBuf, usize)> = roots.iter().map(|r| (r.clone(), 0)).collect();
    let mut visited = 0;
    while let Some((dir, depth)) = stack.pop() {
        visited += 1;
        if visited > 20_000 {
            break;
        }
        if dir.join(".git").is_dir() {
            if !found.contains(&dir) {
                found.push(dir.clone());
            }
            continue;
        }
        if depth >= 4 {
            continue;
        }
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if e.file_type().is_ok_and(|t| t.is_dir())
                && !name.starts_with('.')
                && !SKIP.contains(&name.as_str())
            {
                stack.push((e.path(), depth + 1));
            }
        }
    }
    found.sort();
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    #[test]
    fn porcelain_list_and_agents() {
        let text = "worktree /r\nHEAD aaaaaaaaaaaaaaaa\nbranch refs/heads/main\n\n\
                    worktree /r/.claude/worktrees/x\nHEAD bbbbbbbbbbbbbbbb\nbranch refs/heads/fix/a\nlocked\n\n\
                    worktree /Users/u/.codex/worktrees/1/r\nHEAD cccccccccccccccc\ndetached\nprunable gitdir file points to non-existent location\n";
        let list = parse_list(text, Path::new("/r"));
        assert_eq!(list.len(), 2, "the main worktree is not listed");
        assert_eq!(
            (list[0].branch.as_deref(), list[0].agent, list[0].locked),
            (Some("fix/a"), Some("Claude Code"), true)
        );
        assert_eq!(
            (list[1].branch.as_deref(), list[1].agent, list[1].prunable),
            (None, Some("Codex"), true)
        );
    }

    #[test]
    fn real_worktree_round_trip() {
        let root = std::env::temp_dir().join(format!("corescope-wt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let repo = root.join("repo");
        let run = |dir: &Path, args: &[&str]| {
            let ok = Command::new("/usr/bin/git")
                .arg("-C")
                .arg(dir)
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            assert!(ok, "{args:?}");
        };
        std::fs::create_dir_all(&repo).unwrap();
        run(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("a.txt"), "a").unwrap();
        run(&repo, &["add", "."]);
        run(
            &repo,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-qm",
                "a",
            ],
        );
        let wt = repo.join(".claude/worktrees/feat");
        run(
            &repo,
            &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()],
        );
        let list = list(&repo);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].agent, Some("Claude Code"));
        let wt = PathBuf::from(&list[0].path);
        assert_eq!(
            main_repo(&wt).map(|p| p.canonicalize().unwrap()),
            Some(repo.canonicalize().unwrap())
        );
        assert_eq!(dirty(&wt), Some(0));
        assert_eq!(merged(&repo, "feat"), Some(true), "no new commits: merged");
        std::fs::write(wt.join("b.txt"), "b").unwrap();
        assert_eq!(dirty(&wt), Some(1));
        assert_eq!(toplevel(&wt.join("x/y")).as_deref(), Some(wt.as_path()));
        assert_eq!(
            repos_under(std::slice::from_ref(&root)),
            std::slice::from_ref(&repo)
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
