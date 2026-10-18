//! Reclaimable developer space: build outputs inside projects (`node_modules`, Rust `target/`),
//! Xcode data, package-manager caches and unused Docker data. This module only finds and
//! measures; deleting is the app's job (to the Trash, after the user confirms), and `verify`
//! re-classifies each path and re-checks that nothing uses it right before that.
use crate::{Process, containers};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Item {
    /// The path, or `docker:<socket>:<kind>` for engine data.
    pub id: String,
    pub kind: &'static str,
    pub group: &'static str,
    pub name: String,
    pub path: String,
    pub bytes: u64,
    /// Last modification of the item itself (seconds since 1970); 0 when unknown.
    pub modified: i64,
    /// Process using it right now ("node (PID 4242)"): deleting is refused while set.
    pub busy: Option<String>,
    /// Engine socket for Docker data, which the engine removes (not recoverable from the Trash).
    pub engine: Option<String>,
    /// Extra facts shown with the item (a worktree's branch, agent, merged state).
    pub detail: Option<String>,
    /// For a worktree, its main repository (pruned after the folder goes to the Trash).
    pub repo: Option<String>,
}

#[derive(Serialize)]
pub struct Report {
    pub items: Vec<Item>,
    pub roots: Vec<String>,
    pub seconds: f64,
    pub docker_error: Option<String>,
}

/// Package-manager caches: (name, path under the home folder, processes that use it).
const CACHES: &[(&str, &str, &[&str])] = &[
    ("Homebrew", "Library/Caches/Homebrew", &["brew"]),
    ("npm", ".npm/_cacache", &["npm"]),
    ("Yarn", "Library/Caches/Yarn", &["yarn"]),
    ("Yarn Berry", ".yarn/berry/cache", &["yarn"]),
    ("pnpm", "Library/pnpm/store", &["pnpm"]),
    ("Bun", ".bun/install/cache", &["bun"]),
    ("Cargo · downloads", ".cargo/registry/cache", &["cargo"]),
    (
        "Cargo · sources",
        ".cargo/registry/src",
        &["cargo", "rustc", "rust-analyzer"],
    ),
    ("pip", "Library/Caches/pip", &["pip", "pip3"]),
    ("uv", ".cache/uv", &["uv"]),
    ("Go build", "Library/Caches/go-build", &["go"]),
    ("Gradle", ".gradle/caches", &["gradle"]),
    ("Composer", "Library/Caches/composer", &["composer"]),
    ("Composer", ".composer/cache", &["composer"]),
    ("Composer", ".cache/composer", &["composer"]),
    ("CocoaPods", "Library/Caches/CocoaPods", &["pod"]),
];
const XCODE: &[&str] = &["Xcode", "xcodebuild", "XCBBuildService", "SWBBuildService"];
const SIMULATOR: &[&str] = &["Simulator"];
/// A shell sitting in a project folder does not use its build output.
const SHELLS: &[&str] = &[
    "zsh", "-zsh", "bash", "-bash", "sh", "fish", "dash", "tcsh", "csh", "nu", "login", "tmux",
    "screen",
];
/// Folders never descended into while looking for projects.
const PRUNE: &[&str] = &[
    "Library",
    "Applications",
    "Pictures",
    "Movies",
    "Music",
    "vendor",
    "Pods",
    "DerivedData",
    "build",
    "dist",
    "venv",
    "site-packages",
    "__pycache__",
];
const BUNDLES: &[&str] = &[
    ".app",
    ".photoslibrary",
    ".musiclibrary",
    ".fcpbundle",
    ".imovielibrary",
    ".logicx",
    ".xcarchive",
    ".framework",
    ".bundle",
];
const MAX_DEPTH: usize = 7;
const MAX_FOLDERS: usize = 400_000;
/// Smaller items are not worth a row (pnpm workspace packages hold only links).
const MIN_BYTES: u64 = 1 << 20;

/// What a path is, and what would be using it.
#[derive(Debug, PartialEq)]
pub struct Class {
    pub kind: &'static str,
    pub group: &'static str,
    pub name: String,
    guard: Guard,
}
#[derive(Debug, PartialEq)]
enum Guard {
    /// Processes working inside this project folder (shells aside).
    Project(PathBuf),
    /// Processes with one of these names.
    Names(&'static [&'static str]),
    /// Any process working inside (shells too: a terminal open in a worktree is in use).
    Inside(PathBuf),
}

fn last(path: &Path) -> &str {
    path.file_name().and_then(|n| n.to_str()).unwrap_or("")
}
fn is_rust_target(path: &Path) -> bool {
    path.join("CACHEDIR.TAG").is_file()
        || (path
            .parent()
            .is_some_and(|p| p.join("Cargo.toml").is_file())
            && (path.join("debug").is_dir() || path.join("release").is_dir()))
}
/// `MyApp-abcdefghijklmnopqrstuvwxyzab` → `MyApp`.
fn derived_name(folder: &str) -> String {
    match folder.rsplit_once('-') {
        Some((name, hash)) if hash.len() >= 20 && hash.bytes().all(|b| b.is_ascii_lowercase()) => {
            name.to_string()
        }
        _ => folder.to_string(),
    }
}

/// `repo/web` for a package inside a repository, else the folder name.
fn project_name(folder: &Path) -> String {
    folder
        .ancestors()
        .skip(1)
        .take(3)
        .find(|a| a.join(".git").exists())
        .and_then(|repo| folder.strip_prefix(repo.parent()?).ok())
        .map(|rel| rel.to_string_lossy().into_owned())
        .unwrap_or_else(|| last(folder).to_string())
}
/// The single rule for what may be cleaned: used by the scan and again right before deletion.
pub fn classify(path: &Path, home: &Path) -> Option<Class> {
    // A linked git worktree (its `.git` is a file pointing into the main repository).
    if let Some(repo) = crate::worktrees::main_repo(path)
        && repo != path
    {
        return Some(Class {
            kind: "worktree",
            group: "worktrees",
            name: format!("{} · {}", last(&repo), last(path)),
            guard: Guard::Inside(path.to_path_buf()),
        });
    }
    let parent = path.parent()?;
    let project = |kind, label: &str| Class {
        kind,
        group: "projects",
        name: format!("{} · {label}", project_name(parent)),
        guard: Guard::Project(parent.to_path_buf()),
    };
    match last(path) {
        "node_modules" if parent.join("package.json").is_file() => {
            return Some(project("node_modules", "node_modules"));
        }
        "target" if is_rust_target(path) => return Some(project("rust_target", "target")),
        _ => {}
    }
    let xcode = home.join("Library/Developer/Xcode");
    if parent == xcode.join("DerivedData") {
        return Some(Class {
            kind: "derived_data",
            group: "xcode",
            name: derived_name(last(path)),
            guard: Guard::Names(XCODE),
        });
    }
    if parent.parent() == Some(xcode.as_path()) && last(parent).ends_with(" DeviceSupport") {
        let platform = last(parent).trim_end_matches(" DeviceSupport");
        return Some(Class {
            kind: "device_support",
            group: "xcode",
            name: format!("{platform} {}", last(path)),
            guard: Guard::Names(XCODE),
        });
    }
    if path == home.join("Library/Developer/CoreSimulator/Caches") {
        return Some(Class {
            kind: "simulator_caches",
            group: "xcode",
            name: "Simulator caches".into(),
            guard: Guard::Names(SIMULATOR),
        });
    }
    CACHES
        .iter()
        .find(|(_, rel, _)| path == home.join(rel))
        .map(|(name, _, users)| Class {
            kind: "cache",
            group: "caches",
            name: (*name).into(),
            guard: Guard::Names(users),
        })
}

fn inside(path: &str, folder: &Path) -> bool {
    let path = Path::new(path);
    !path.as_os_str().is_empty() && path.starts_with(folder)
}
/// The first process using the item, as "name (PID n)".
fn busy(class: &Class, item: &Path, processes: &[Process]) -> Option<String> {
    let me = std::process::id() as i32;
    processes
        .iter()
        .filter(|p| p.pid != me)
        .find(|p| match &class.guard {
            Guard::Names(names) => names.contains(&p.name.as_str()),
            Guard::Inside(folder) => inside(&p.cwd, folder) || inside(&p.path, folder),
            Guard::Project(folder) => {
                (inside(&p.cwd, folder) && !SHELLS.contains(&p.name.as_str()))
                    || inside(&p.path, item)
            }
        })
        .map(|p| format!("{} (PID {})", p.name, p.pid))
}

/// Right before deleting: the path must still be a real folder (no symlink anywhere in it), still
/// qualify, and be unused.
pub fn verify(path: &str, home: &Path, processes: &[Process]) -> Result<(), String> {
    let p = Path::new(path);
    let meta = std::fs::symlink_metadata(p).map_err(|_| "Item não existe mais")?;
    if !meta.is_dir() || std::fs::canonicalize(p).ok().as_deref() != Some(p) {
        return Err("Caminho não é uma pasta real".into());
    }
    let class = classify(p, home).ok_or("Caminho não reconhecido para limpeza")?;
    if class.kind == "worktree"
        && let Some(reason) = worktree_block(p)
    {
        return Err(reason);
    }
    match busy(&class, p, processes) {
        Some(user) => Err(format!("Em uso por {user}")),
        None => Ok(()),
    }
}

/// Why a worktree must stay: uncommitted work, a git lock, or git unable to tell.
fn worktree_block(path: &Path) -> Option<String> {
    let repo = crate::worktrees::main_repo(path)?;
    let listed = crate::worktrees::list(&repo);
    if listed
        .iter()
        .any(|w| Path::new(&w.path) == path && w.locked)
    {
        return Some("Bloqueado no git (git worktree lock)".into());
    }
    match crate::worktrees::dirty(path) {
        Some(0) => None,
        Some(n) => Some(format!("{n} alterações não commitadas")),
        None => Some("O git não conseguiu ler este worktree".into()),
    }
}
/// Linked worktrees of the repositories under the roots and of the projects agents work in.
pub fn worktree_paths(roots: &[PathBuf], processes: &[Process]) -> Vec<PathBuf> {
    let mut repos = crate::worktrees::repos_under(roots);
    for p in processes
        .iter()
        .filter(|p| !p.cwd.is_empty() && (p.host.is_some() || p.origin.is_some()))
    {
        if let Some(top) = crate::worktrees::toplevel(Path::new(&p.cwd)) {
            let repo = crate::worktrees::main_repo(&top).unwrap_or(top);
            if !repos.contains(&repo) {
                repos.push(repo);
            }
        }
    }
    let mut out = vec![];
    for repo in repos {
        for wt in crate::worktrees::list(&repo) {
            let path = PathBuf::from(&wt.path);
            if !wt.prunable && path.is_dir() && !out.contains(&path) {
                out.push(path);
            }
        }
    }
    out
}
/// Branch, agent, merged state and lock reason of a worktree item.
fn worktree_facts(path: &Path) -> (Option<String>, Option<String>, Option<String>, i64) {
    let Some(repo) = crate::worktrees::main_repo(path) else {
        return (None, None, None, 0);
    };
    let info = crate::worktrees::list(&repo)
        .into_iter()
        .find(|w| Path::new(&w.path) == path);
    let mut facts = vec![];
    if let Some(agent) = info.as_ref().and_then(|w| w.agent) {
        facts.push(agent.to_string());
    }
    match info.as_ref().and_then(|w| w.branch.clone()) {
        Some(branch) => {
            facts.push(branch.clone());
            match crate::worktrees::merged(&repo, &branch) {
                Some(true) => facts.push("merged".into()),
                Some(false) => facts.push("not merged".into()),
                None => {}
            }
        }
        None => facts.push(format!(
            "detached {}",
            info.as_ref().map(|w| w.head.as_str()).unwrap_or("")
        )),
    }
    let block = worktree_block(path);
    let modified = crate::worktrees::last_commit(path).unwrap_or(0);
    (
        Some(facts.join(" · ")),
        Some(repo.to_string_lossy().into()),
        block,
        modified,
    )
}

/// Allocated bytes (hard links once) and the item's own modification time.
pub(crate) fn measure(path: &Path) -> (u64, i64) {
    let modified = std::fs::symlink_metadata(path)
        .map(|m| m.mtime())
        .unwrap_or(0);
    let mut seen = HashSet::new();
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
            bytes += meta.blocks() * 512;
            if meta.is_dir() {
                stack.push(entry.path());
            }
        }
    }
    (bytes, modified)
}

/// `node_modules` and Rust `target/` folders under the roots. Never follows symlinks, never
/// descends into what it found, hidden folders, bundles or the folders in `PRUNE`.
pub fn find_projects(roots: &[PathBuf], home: &Path) -> Vec<PathBuf> {
    let mut found = vec![];
    let mut visited = 0usize;
    let mut stack: Vec<(PathBuf, usize)> = roots.iter().map(|r| (r.clone(), 0)).collect();
    let mut seen = HashSet::new();
    while let Some((dir, depth)) = stack.pop() {
        if !seen.insert(dir.clone()) || visited >= MAX_FOLDERS {
            continue;
        }
        visited += 1;
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if !kind.is_dir() {
                continue;
            }
            let path = entry.path();
            let name = last(&path);
            if name.starts_with('.') || BUNDLES.iter().any(|b| name.ends_with(b)) {
                continue;
            }
            if name == "node_modules" || name == "target" {
                if classify(&path, home).is_some() {
                    found.push(path);
                }
                continue;
            }
            if depth + 1 < MAX_DEPTH && !PRUNE.contains(&name) {
                stack.push((path, depth + 1));
            }
        }
    }
    found.sort();
    found
}

/// Xcode folders and caches that exist.
fn fixed(home: &Path) -> Vec<PathBuf> {
    let xcode = home.join("Library/Developer/Xcode");
    let mut out = vec![];
    let children = |dir: PathBuf| -> Vec<PathBuf> {
        std::fs::read_dir(dir)
            .map(|e| {
                e.flatten()
                    .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
                    .map(|e| e.path())
                    .collect()
            })
            .unwrap_or_default()
    };
    out.extend(children(xcode.join("DerivedData")));
    for platform in children(xcode.clone()) {
        if last(&platform).ends_with(" DeviceSupport") {
            out.extend(children(platform));
        }
    }
    out.push(home.join("Library/Developer/CoreSimulator/Caches"));
    out.extend(CACHES.iter().map(|(_, rel, _)| home.join(rel)));
    out.into_iter()
        .filter(|p| {
            std::fs::symlink_metadata(p).is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink())
        })
        .collect()
}

/// Folders worth scanning: common project folders in the home, plus the folder holding each
/// project that agents, editors or terminals are working in right now.
pub fn auto_roots(home: &Path, processes: &[Process]) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = [
        "Developer",
        "Projects",
        "projects",
        "Code",
        "code",
        "src",
        "dev",
        "Dev",
        "workspace",
        "Workspace",
        "Sites",
        "Herd",
        "repos",
        "git",
        "GitHub",
        "Documents/GitHub",
    ]
    .iter()
    .map(|rel| home.join(rel))
    .filter(|p| p.is_dir())
    .collect();
    let broad = |p: &Path| {
        p == home
            || p.parent().is_none()
            || p.parent() == Some(Path::new("/"))
            || p.parent() == Some(Path::new("/Volumes"))
            || p.starts_with(home.join("Library"))
    };
    for p in processes {
        if p.cwd.is_empty() || (p.host.is_none() && p.origin.is_none()) {
            continue;
        }
        let cwd = Path::new(&p.cwd);
        let hidden = cwd.components().any(|c| {
            let c = c.as_os_str().to_string_lossy();
            c.starts_with('.') || BUNDLES.iter().any(|b| c.ends_with(b))
        });
        if broad(cwd) || hidden {
            continue;
        }
        // The repository (outermost of the nearest levels), else the nearest manifest. Folders
        // that are not inside a project never become roots.
        let candidates: Vec<&Path> = cwd.ancestors().take(5).take_while(|a| !broad(a)).collect();
        let has = |a: &Path, marker: &str| a.join(marker).exists();
        let Some(project) = candidates
            .iter()
            .rev()
            .find(|a| has(a, ".git"))
            .or_else(|| {
                candidates
                    .iter()
                    .find(|a| has(a, "package.json") || has(a, "Cargo.toml"))
            })
        else {
            continue;
        };
        let root = project
            .parent()
            .filter(|parent| !broad(parent))
            .unwrap_or(project);
        roots.push(root.to_path_buf());
    }
    normalize(roots)
}
/// Canonical, existing and not nested in another root.
pub fn normalize(roots: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = roots
        .into_iter()
        .filter_map(|r| std::fs::canonicalize(r).ok())
        .filter(|r| r.is_dir() && r != Path::new("/"))
        .collect();
    roots.sort_by_key(|r| r.as_os_str().len());
    let mut out: Vec<PathBuf> = vec![];
    for r in roots {
        if !out.iter().any(|o| r.starts_with(o)) {
            out.push(r);
        }
    }
    out.sort();
    out
}

/// Unused Docker images (dangling and tagged) and build cache from `/system/df`.
pub fn parse_df(body: &Value) -> [u64; 3] {
    let mut out = [0u64; 3];
    for image in body["Images"].as_array().into_iter().flatten() {
        if image["Containers"].as_i64().unwrap_or(1) != 0 {
            continue;
        }
        let tags: Vec<&str> = image["RepoTags"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .filter(|t| *t != "<none>:<none>")
            .collect();
        out[usize::from(!tags.is_empty())] += image["Size"].as_u64().unwrap_or(0);
    }
    out[2] = body["BuildCache"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|c| !c["InUse"].as_bool().unwrap_or(true))
        .filter_map(|c| c["Size"].as_u64())
        .sum();
    out
}
const DOCKER_KINDS: [&str; 3] = ["docker_dangling", "docker_unused", "docker_build_cache"];
pub fn docker(home: &Path) -> (Vec<Item>, Option<String>) {
    let host = std::env::var("DOCKER_HOST").ok();
    let mut items = vec![];
    let mut error = None;
    for socket in containers::sockets(home, host.as_deref()) {
        let path = socket.to_string_lossy().to_string();
        let r = containers::request(
            &socket,
            "GET",
            "/system/df?type=image&type=build-cache",
            Duration::from_secs(30),
        );
        let body = match r {
            Ok(r) if r.status == 200 => serde_json::from_slice::<Value>(&r.body).ok(),
            Ok(r) => {
                error = Some(format!(
                    "{} (HTTP {})",
                    containers::engine_name(&path),
                    r.status
                ));
                None
            }
            Err(_) => None,
        };
        let Some(body) = body else { continue };
        for (kind, bytes) in DOCKER_KINDS.into_iter().zip(parse_df(&body)) {
            if bytes == 0 {
                continue;
            }
            items.push(Item {
                id: format!("docker:{path}:{kind}"),
                kind,
                group: "docker",
                name: containers::engine_name(&path).into(),
                path: path.clone(),
                bytes,
                modified: 0,
                busy: None,
                engine: Some(path.clone()),
                detail: None,
                repo: None,
            });
        }
    }
    (items, error)
}

/// Removes unused Docker data through the engine, after the user confirmed. Returns bytes freed.
pub fn docker_prune(socket: &str, kind: &str, home: &Path) -> Result<u64, String> {
    let host = std::env::var("DOCKER_HOST").ok();
    let socket = containers::sockets(home, host.as_deref())
        .into_iter()
        .find(|s| s.to_string_lossy() == socket)
        .ok_or("Motor de contêineres não encontrado")?;
    let path = match kind {
        "docker_dangling" => "/images/prune?filters=%7B%22dangling%22%3A%5B%22true%22%5D%7D",
        "docker_unused" => "/images/prune?filters=%7B%22dangling%22%3A%5B%22false%22%5D%7D",
        "docker_build_cache" => "/build/prune?all=1",
        _ => return Err("Ação de contêiner inválida".into()),
    };
    let r = containers::request(&socket, "POST", path, Duration::from_secs(300))
        .map_err(|_| "O motor de contêineres não respondeu")?;
    let body = serde_json::from_slice::<Value>(&r.body).unwrap_or_default();
    if r.status != 200 {
        let message = body["message"].as_str().unwrap_or("").chars().take(160);
        return Err(format!(
            "O motor recusou a ação (HTTP {}) {}",
            r.status,
            message.collect::<String>()
        )
        .trim_end()
        .into());
    }
    Ok(body["SpaceReclaimed"].as_u64().unwrap_or(0))
}

/// Finds, classifies and measures everything (folders in parallel), biggest first.
pub fn scan(roots: &[PathBuf], home: &Path, processes: &[Process], with_docker: bool) -> Report {
    let started = Instant::now();
    let mut paths = fixed(home);
    paths.extend(find_projects(roots, home));
    paths.extend(worktree_paths(roots, processes));
    let next = AtomicUsize::new(0);
    let results = Mutex::new(Vec::with_capacity(paths.len()));
    let workers = std::thread::available_parallelism().map_or(4, |n| n.get().min(8));
    let docker = std::thread::scope(|s| {
        let docker = s.spawn(|| with_docker.then(|| docker(home)));
        for _ in 0..workers {
            s.spawn(|| {
                loop {
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(path) = paths.get(i) else { break };
                    let Some(class) = classify(path, home) else {
                        continue;
                    };
                    let (bytes, mut modified) = measure(path);
                    if bytes < MIN_BYTES {
                        continue;
                    }
                    let (mut detail, mut repo, mut block) = (None, None, None);
                    if class.kind == "worktree" {
                        let (d, r, b, m) = worktree_facts(path);
                        (detail, repo, block) = (d, r, b);
                        if m > 0 {
                            modified = m;
                        }
                    }
                    let item = Item {
                        id: path.to_string_lossy().into(),
                        busy: busy(&class, path, processes).or(block),
                        detail,
                        repo,
                        kind: class.kind,
                        group: class.group,
                        name: class.name,
                        path: path.to_string_lossy().into(),
                        bytes,
                        modified,
                        engine: None,
                    };
                    results.lock().unwrap_or_else(|e| e.into_inner()).push(item);
                }
            });
        }
        // Scoped workers are joined when the scope ends; only the engine call returns a value.
        docker.join().ok().flatten().unwrap_or_default()
    });
    let (docker_items, docker_error) = docker;
    let mut items = results.into_inner().unwrap_or_else(|e| e.into_inner());
    items.extend(docker_items);
    items.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.id.cmp(&b.id)));
    Report {
        items,
        roots: roots.iter().map(|r| r.to_string_lossy().into()).collect(),
        seconds: started.elapsed().as_secs_f64(),
        docker_error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("corescope-devspace-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::canonicalize(dir).unwrap()
    }
    fn process(name: &str, cwd: &str, path: &str) -> Process {
        let mut p = crate::process_fixture();
        p.name = name.into();
        p.cwd = cwd.into();
        p.path = path.into();
        p
    }

    #[test]
    fn finds_build_outputs_only_in_real_projects() {
        let root = temp("find");
        let home = root.join("home");
        for dir in [
            "web/node_modules/left-pad/node_modules",
            "loose/node_modules",
            "api/target/debug",
            "maven/target/classes",
            ".hidden/node_modules",
            "deep/a/b/c/d/e/f/g/node_modules",
        ] {
            fs::create_dir_all(root.join(dir)).unwrap();
        }
        fs::write(root.join("web/package.json"), "{}").unwrap();
        fs::write(root.join("web/node_modules/left-pad/package.json"), "{}").unwrap();
        fs::write(root.join("api/Cargo.toml"), "").unwrap();
        fs::write(root.join("api/target/CACHEDIR.TAG"), "").unwrap();
        fs::write(root.join(".hidden/package.json"), "{}").unwrap();
        fs::write(root.join("deep/a/b/c/d/e/f/g/package.json"), "{}").unwrap();
        let found = find_projects(std::slice::from_ref(&root), &home);
        assert_eq!(
            found,
            vec![root.join("api/target"), root.join("web/node_modules")],
            "no nested node_modules, no folder without a manifest, no Maven target, nothing hidden or too deep"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn measures_hard_links_once_and_ignores_symlinks() {
        let root = temp("measure");
        let item = root.join("node_modules");
        fs::create_dir_all(item.join("a")).unwrap();
        fs::write(item.join("a/file"), vec![1u8; 64 * 1024]).unwrap();
        fs::hard_link(item.join("a/file"), item.join("a/link")).unwrap();
        let outside = root.join("outside");
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("big"), vec![1u8; 512 * 1024]).unwrap();
        std::os::unix::fs::symlink(&outside, item.join("escape")).unwrap();
        let (bytes, modified) = measure(&item);
        assert!((64 * 1024..256 * 1024).contains(&bytes), "{bytes}");
        assert!(modified > 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_known_paths_qualify_and_symlinks_are_refused() {
        let root = temp("verify");
        let home = root.join("home");
        let derived =
            home.join("Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyz");
        let support = home.join("Library/Developer/Xcode/iOS DeviceSupport/18.2 (22C152)");
        let npm = home.join(".npm/_cacache");
        for dir in [&derived, &support, &npm] {
            fs::create_dir_all(dir).unwrap();
        }
        assert_eq!(classify(&derived, &home).unwrap().name, "MyApp");
        assert_eq!(classify(&support, &home).unwrap().kind, "device_support");
        assert_eq!(classify(&npm, &home).unwrap().name, "npm");
        assert!(classify(&home.join(".npm"), &home).is_none());
        assert!(classify(&home.join("Documents"), &home).is_none());
        assert!(verify(&npm.to_string_lossy(), &home, &[]).is_ok());

        let project = root.join("app");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("package.json"), "{}").unwrap();
        std::os::unix::fs::symlink(&home, project.join("node_modules")).unwrap();
        assert!(verify(&project.join("node_modules").to_string_lossy(), &home, &[]).is_err());
        assert!(
            verify(
                &root.join("missing/node_modules").to_string_lossy(),
                &home,
                &[]
            )
            .is_err()
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_dev_server_in_the_project_blocks_it_but_a_shell_does_not() {
        let root = temp("busy");
        let home = root.join("home");
        let modules = root.join("web/node_modules");
        fs::create_dir_all(&modules).unwrap();
        fs::write(root.join("web/package.json"), "{}").unwrap();
        let web = root.join("web").to_string_lossy().to_string();
        let path = modules.to_string_lossy().to_string();
        let shell = process("zsh", &web, "/bin/zsh");
        assert!(verify(&path, &home, &[shell]).is_ok());
        let server = process("node", &format!("{web}/src"), "/opt/homebrew/bin/node");
        assert_eq!(
            verify(&path, &home, std::slice::from_ref(&server)).unwrap_err(),
            format!("Em uso por node (PID {})", server.pid)
        );
        let tool = process("esbuild", "/", &format!("{path}/.bin/esbuild"));
        assert!(verify(&path, &home, &[tool]).is_err());
        let xcode = home.join("Library/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyz");
        fs::create_dir_all(&xcode).unwrap();
        let ide = process("Xcode", "/", "/Applications/Xcode.app/Contents/MacOS/Xcode");
        assert!(verify(&xcode.to_string_lossy(), &home, &[ide]).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn roots_come_from_where_dev_tools_work() {
        let root = temp("roots");
        let home = root.join("home");
        let project = root.join("work/site");
        fs::create_dir_all(project.join(".git")).unwrap();
        fs::create_dir_all(project.join("src")).unwrap();
        let top = home.join("solo");
        fs::create_dir_all(top.join(".git")).unwrap();
        let mut agent = process(
            "claude",
            &project.join("src").to_string_lossy(),
            "/x/claude",
        );
        agent.host = Some("Claude Code");
        let mut editor = process("nvim", &top.to_string_lossy(), "/x/nvim");
        editor.host = Some("Neovim");
        let other = process("node", "/tmp", "/x/node");
        let roots = auto_roots(&home, &[agent, editor, other]);
        assert_eq!(
            roots,
            vec![top, root.join("work")],
            "home itself is never a root"
        );
        assert_eq!(
            normalize(vec![root.clone(), root.join("work")]),
            vec![root.clone()]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn docker_df_splits_unused_images_and_cache() {
        let body = serde_json::json!({
            "Images": [
                {"Containers": 0, "Size": 100, "RepoTags": ["<none>:<none>"]},
                {"Containers": 0, "Size": 200, "RepoTags": null},
                {"Containers": 0, "Size": 1000, "RepoTags": ["postgres:16"]},
                {"Containers": 2, "Size": 5000, "RepoTags": ["redis:7"]}
            ],
            "BuildCache": [{"InUse": false, "Size": 30}, {"InUse": true, "Size": 70}]
        });
        assert_eq!(parse_df(&body), [300, 1000, 30]);
        assert_eq!(derived_name("Short-name"), "Short-name");
    }
    #[test]
    fn packages_are_named_after_their_repository() {
        let root = temp("names");
        fs::create_dir_all(root.join("shop/.git")).unwrap();
        fs::create_dir_all(root.join("shop/web")).unwrap();
        assert_eq!(project_name(&root.join("shop/web")), "shop/web");
        assert_eq!(project_name(&root.join("shop")), "shop");
        fs::remove_dir_all(root).unwrap();
    }
}
