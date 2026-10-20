//! The `git` command line, run with an argument array (never a shell) so the user's hooks,
//! commit signing and configuration apply as in their terminal. Read-only calls skip optional
//! locks so they never block the user's own git; every call has a time limit.
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const GIT: &str = "/usr/bin/git";

#[derive(Debug, Clone, PartialEq)]
pub struct Output {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}
impl Output {
    pub fn ok(&self) -> bool {
        self.code == 0
    }
    /// What to show the user when the command failed: stderr, else stdout.
    pub fn message(&self) -> String {
        let text = if self.stderr.trim().is_empty() {
            &self.stdout
        } else {
            &self.stderr
        };
        text.trim().chars().take(2000).collect()
    }
}

/// Runs `git -C dir args…`. `read_only` adds `GIT_OPTIONAL_LOCKS=0` and disables fsmonitor
/// hooks; writes run exactly as the user's git would.
pub fn run(
    dir: &Path,
    args: &[&str],
    read_only: bool,
    timeout: Duration,
) -> Result<Output, String> {
    let mut cmd = Command::new(GIT);
    cmd.arg("-C").arg(dir);
    if read_only {
        cmd.args(["-c", "core.fsmonitor=false"]);
        cmd.env("GIT_OPTIONAL_LOCKS", "0");
    }
    let mut child = cmd
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("git: {e}"))?;
    // Read both pipes on threads so a large status never fills a pipe and stalls git.
    let mut out_pipe = child.stdout.take().ok_or("git: no stdout")?;
    let mut err_pipe = child.stderr.take().ok_or("git: no stderr")?;
    let out_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        std::io::Read::read_to_end(&mut out_pipe, &mut buf).ok();
        buf
    });
    let err_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        std::io::Read::read_to_end(&mut err_pipe, &mut buf).ok();
        buf
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(10))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "git {} took longer than {} s",
                    args.first().unwrap_or(&""),
                    timeout.as_secs()
                ));
            }
        }
    };
    Ok(Output {
        code: status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&out_reader.join().unwrap_or_default()).into_owned(),
        stderr: String::from_utf8_lossy(&err_reader.join().unwrap_or_default()).into_owned(),
    })
}
/// Read-only call returning stdout on success.
pub fn read(dir: &Path, args: &[&str]) -> Option<String> {
    run(dir, args, true, Duration::from_secs(10))
        .ok()
        .filter(Output::ok)
        .map(|o| o.stdout)
}

#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct RepoInfo {
    pub is_repo: bool,
    /// The working tree's top folder.
    pub root: Option<String>,
    /// For a linked worktree, the main repository's working tree.
    pub main_repo: Option<String>,
    pub is_worktree: bool,
    pub branch: Option<String>,
    /// Short commit id; None in a repository with no commits yet.
    pub head: Option<String>,
    pub detached: bool,
    /// The folder is inside the repository but not at its root (a monorepo package).
    pub subfolder: Option<String>,
    /// Remotes, with any credentials stripped from their URLs.
    pub remotes: Vec<Remote>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct Remote {
    pub name: String,
    /// The fetch URL without user or password.
    pub url: String,
    /// A browser link for the usual hosts' URL shapes (https, scp-like ssh, ssh://).
    pub web_url: Option<String>,
}

/// `https://user:token@host/x` → `https://host/x`; scp-like and ssh URLs keep their user
/// (it is never a secret there: `git@`).
pub fn sanitize_remote_url(url: &str) -> String {
    for scheme in ["https://", "http://"] {
        if let Some(rest) = url.strip_prefix(scheme) {
            let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
            let host = authority.rsplit('@').next().unwrap_or(authority);
            return format!("{scheme}{host}/{path}")
                .trim_end_matches('/')
                .to_string();
        }
    }
    url.to_string()
}

/// The repository's page in a browser, for remote URLs in the usual shapes: `https://host/owner/repo(.git)`,
/// `git@host:owner/repo(.git)` and `ssh://git@host[:port]/owner/repo(.git)`. None for local paths.
pub fn remote_web_url(url: &str) -> Option<String> {
    let clean = sanitize_remote_url(url);
    let (host, path) = if let Some(rest) = clean
        .strip_prefix("https://")
        .or_else(|| clean.strip_prefix("http://"))
    {
        rest.split_once('/')?
    } else if let Some(rest) = clean.strip_prefix("ssh://") {
        let rest = rest.rsplit_once('@').map(|(_, r)| r).unwrap_or(rest);
        let (authority, path) = rest.split_once('/')?;
        (authority.split(':').next()?, path)
    } else if !clean.contains("://") && clean.contains(':') && !clean.starts_with('/') {
        let rest = clean.rsplit_once('@').map(|(_, r)| r).unwrap_or(&clean);
        rest.split_once(':')?
    } else {
        return None;
    };
    let path = path.trim_end_matches('/').trim_end_matches(".git");
    (!host.is_empty() && path.contains('/')).then(|| format!("https://{host}/{path}"))
}

/// `git remote -v` → fetch remotes in order.
pub fn parse_remotes(text: &str) -> Vec<Remote> {
    let mut out: Vec<Remote> = vec![];
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let (Some(name), Some(url), Some(kind)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        if kind != "(fetch)" || out.iter().any(|r| r.name == name) {
            continue;
        }
        out.push(Remote {
            name: name.to_string(),
            url: sanitize_remote_url(url),
            web_url: remote_web_url(url),
        });
    }
    out
}

/// What git says about a folder: repository root, linked worktree and its main repository,
/// current branch or detached head.
pub fn inspect(folder: &Path) -> RepoInfo {
    let Some(text) = read(
        folder,
        &[
            "rev-parse",
            "--show-toplevel",
            "--absolute-git-dir",
            "--git-common-dir",
        ],
    ) else {
        return RepoInfo::default();
    };
    let mut lines = text.lines();
    let root = lines.next().map(str::to_string);
    let git_dir = lines.next().map(PathBuf::from);
    let common = lines.next().map(|c| {
        let p = PathBuf::from(c);
        if p.is_absolute() { p } else { folder.join(p) }
    });
    let is_worktree = match (&git_dir, &common) {
        (Some(g), Some(c)) => {
            let canon = |p: &Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
            canon(g) != canon(c)
        }
        _ => false,
    };
    let main_repo = if is_worktree {
        common
            .as_ref()
            .and_then(|c| c.canonicalize().ok())
            .and_then(|c| c.parent().map(|p| p.to_string_lossy().into_owned()))
    } else {
        None
    };
    let branch = read(folder, &["symbolic-ref", "--short", "-q", "HEAD"])
        .map(|b| b.trim().to_string())
        .filter(|b| !b.is_empty());
    let head = read(folder, &["rev-parse", "--short", "-q", "--verify", "HEAD"])
        .map(|h| h.trim().to_string())
        .filter(|h| !h.is_empty());
    let subfolder = root.as_ref().and_then(|r| {
        let canon_folder = folder.canonicalize().ok()?;
        let canon_root = Path::new(r).canonicalize().ok()?;
        let rel = canon_folder.strip_prefix(&canon_root).ok()?;
        (!rel.as_os_str().is_empty()).then(|| rel.to_string_lossy().into_owned())
    });
    let remotes = read(folder, &["remote", "-v"])
        .map(|t| parse_remotes(&t))
        .unwrap_or_default();
    RepoInfo {
        remotes,
        is_repo: true,
        root,
        main_repo,
        is_worktree,
        detached: branch.is_none() && head.is_some(),
        branch,
        head,
        subfolder,
    }
}

/// `git init` in an existing folder (the user confirmed); the user's `init.defaultBranch` applies.
pub fn init(folder: &Path) -> Result<RepoInfo, String> {
    if !folder.is_dir() {
        return Err("folder must be an existing directory".into());
    }
    if inspect(folder).is_repo {
        return Err("already inside a git repository".into());
    }
    let out = run(folder, &["init"], false, Duration::from_secs(20))?;
    if !out.ok() {
        return Err(out.message());
    }
    Ok(inspect(folder))
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A scratch repository with one commit, for tests here and in other modules.
    pub fn scratch(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("corescope-git-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let repo = root.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let git = |args: &[&str]| {
            let out = run(
                &repo,
                &[
                    &[
                        "-c",
                        "user.name=t",
                        "-c",
                        "user.email=t@t",
                        "-c",
                        "commit.gpgsign=false",
                    ],
                    args,
                ]
                .concat(),
                false,
                Duration::from_secs(20),
            )
            .unwrap();
            assert!(out.ok(), "{args:?}: {}", out.message());
        };
        git(&["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("a.txt"), "a\n").unwrap();
        git(&["add", "."]);
        git(&["commit", "-qm", "first"]);
        repo
    }

    #[test]
    fn remotes_are_sanitized_and_linked() {
        let text = "origin\thttps://ghp_secret@github.com/Tiagospem/corescope.git (fetch)\n\
                    origin\thttps://ghp_secret@github.com/Tiagospem/corescope.git (push)\n\
                    gl\tgit@gitlab.com:team/sub/app.git (fetch)\n\
                    own\tssh://git@git.example.com:2222/a/b.git (fetch)\n\
                    local\t/Users/me/bare.git (fetch)\n";
        let r = parse_remotes(text);
        assert_eq!(r.len(), 4, "one row per remote");
        assert_eq!(
            r[0].url, "https://github.com/Tiagospem/corescope.git",
            "no token"
        );
        assert!(!format!("{r:?}").contains("ghp_secret"));
        assert_eq!(
            r[0].web_url.as_deref(),
            Some("https://github.com/Tiagospem/corescope")
        );
        assert_eq!(
            r[1].web_url.as_deref(),
            Some("https://gitlab.com/team/sub/app")
        );
        assert_eq!(r[2].web_url.as_deref(), Some("https://git.example.com/a/b"));
        assert_eq!(r[3].web_url, None, "a local path has no page");
        assert_eq!(
            sanitize_remote_url("https://u:p@h.com/x/y"),
            "https://h.com/x/y"
        );
    }

    #[test]
    fn inspect_repo_worktree_subfolder_and_init() {
        let repo = scratch("inspect");
        let info = inspect(&repo);
        assert!(info.is_repo && !info.is_worktree && !info.detached);
        assert_eq!(info.branch.as_deref(), Some("main"));
        assert!(info.head.is_some());
        std::fs::create_dir_all(repo.join("pkg/web")).unwrap();
        assert_eq!(
            inspect(&repo.join("pkg/web")).subfolder.as_deref(),
            Some("pkg/web")
        );
        let wt = repo.parent().unwrap().join("wt");
        let out = run(
            &repo,
            &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()],
            false,
            Duration::from_secs(20),
        )
        .unwrap();
        assert!(out.ok(), "{}", out.message());
        let w = inspect(&wt);
        assert!(w.is_worktree);
        assert_eq!(w.branch.as_deref(), Some("feat"));
        assert_eq!(
            w.main_repo.map(|p| Path::new(&p).canonicalize().unwrap()),
            Some(repo.canonicalize().unwrap())
        );
        let plain = repo.parent().unwrap().join("plain");
        std::fs::create_dir_all(&plain).unwrap();
        assert!(!inspect(&plain).is_repo);
        let fresh = init(&plain).unwrap();
        assert!(fresh.is_repo && fresh.head.is_none(), "no commits yet");
        assert!(init(&plain).unwrap_err().contains("already"));
        let failed = run(
            &repo,
            &["checkout", "no-such-branch"],
            false,
            Duration::from_secs(10),
        )
        .unwrap();
        assert!(!failed.ok() && failed.message().contains("no-such-branch"));
        std::fs::remove_dir_all(repo.parent().unwrap()).unwrap();
    }
}
