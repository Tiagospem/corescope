//! A safe cleanup plan: caches and stores that tools re-create on demand, each with an estimate,
//! the exact command or folders it touches, and whether the tool that owns it is running now.
//! Nothing here deletes: the app runs a chosen action (folders go to the Trash, commands run in
//! the user's login shell, Docker data through the engine) after the user picked it.
use crate::{Process, devspace};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Action {
    pub id: &'static str,
    pub title: &'static str,
    /// "trash" (folders to the Trash, recoverable), "command" (run in the login shell) or
    /// "docker" (removed by the engine, not recoverable).
    pub kind: &'static str,
    /// What runs, as shown to the user.
    pub command: String,
    /// For "command": the program and its arguments (run through the login shell, quoted).
    pub argv: Vec<String>,
    /// Folders moved to the Trash ("trash"), or the engine socket ("docker").
    pub paths: Vec<String>,
    /// Docker data kind for `devspace::docker_prune`.
    pub docker_kind: Option<&'static str>,
    /// Bytes it frees (an upper bound for "command" actions).
    pub estimate: u64,
    /// True when the estimate is an upper bound (a prune keeps what is still referenced).
    pub up_to: bool,
    /// The owning tool running right now ("npm (PID 4242)"): run it later.
    pub busy: Option<String>,
    pub note: &'static str,
}

/// First existing executable among the usual install locations.
fn tool(home: &Path, name: &str) -> Option<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/usr/bin"),
        home.join(".volta/bin"),
        home.join(".bun/bin"),
        home.join(".cargo/bin"),
        home.join("go/bin"),
        PathBuf::from("/usr/local/go/bin"),
        home.join("Library/pnpm"),
    ];
    // nvm installs: newest version last in sort order.
    if let Ok(entries) = std::fs::read_dir(home.join(".nvm/versions/node")) {
        let mut v: Vec<PathBuf> = entries.flatten().map(|e| e.path().join("bin")).collect();
        v.sort();
        dirs.extend(v.into_iter().rev());
    }
    dirs.into_iter().map(|d| d.join(name)).find(|p| p.is_file())
}

fn size(paths: &[PathBuf]) -> u64 {
    paths
        .iter()
        .filter(|p| p.exists())
        .map(|p| devspace::measure(p).0)
        .sum()
}

/// Which of these process names is running (first match), for the busy check.
fn running(processes: &[Process], names: &[&str]) -> Option<String> {
    processes
        .iter()
        .find(|p| names.iter().any(|n| p.name.eq_ignore_ascii_case(n)))
        .map(|p| format!("{} (PID {})", p.name, p.pid))
}

fn show(home: &Path, p: &Path) -> String {
    let s = p.to_string_lossy();
    match s.strip_prefix(&*home.to_string_lossy()) {
        Some(rest) => format!("~{rest}"),
        None => s.into_owned(),
    }
}

/// Unavailable simulator devices (`xcrun simctl list devices unavailable -j`) → their folders.
fn unavailable_simulators(home: &Path) -> Vec<PathBuf> {
    let Ok(out) = std::process::Command::new("/usr/bin/xcrun")
        .args(["simctl", "list", "devices", "unavailable", "-j"])
        .stderr(std::process::Stdio::null())
        .output()
    else {
        return vec![];
    };
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&out.stdout) else {
        return vec![];
    };
    let root = home.join("Library/Developer/CoreSimulator/Devices");
    v["devices"]
        .as_object()
        .into_iter()
        .flat_map(|m| m.values())
        .flat_map(|list| list.as_array().into_iter().flatten())
        .filter_map(|d| d["udid"].as_str())
        .filter(|u| u.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
        .map(|u| root.join(u))
        .filter(|p| p.is_dir())
        .collect()
}

/// Every action that applies on this Mac, largest estimate first; actions with nothing to free
/// are left out.
pub fn plan(home: &Path, processes: &[Process], with_docker: bool) -> Vec<Action> {
    let mut out = vec![];
    let mut trash = |id, title, folders: Vec<PathBuf>, busy: &[&str], note| {
        let existing: Vec<PathBuf> = folders.into_iter().filter(|p| p.exists()).collect();
        let estimate = size(&existing);
        if estimate == 0 {
            return;
        }
        out.push(Action {
            id,
            title,
            kind: "trash",
            command: format!(
                "Move to the Trash: {}",
                existing
                    .iter()
                    .map(|p| show(home, p))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            paths: existing
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect(),
            argv: vec![],
            docker_kind: None,
            estimate,
            up_to: false,
            busy: running(processes, busy),
            note,
        });
    };
    let derived = home.join("Library/Developer/Xcode/DerivedData");
    let derived_items: Vec<PathBuf> = std::fs::read_dir(&derived)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .collect();
    trash(
        "xcode-derived-data",
        "Xcode DerivedData",
        derived_items,
        &["Xcode", "xcodebuild", "swift-frontend"],
        "Build products and indexes; Xcode rebuilds them on the next build.",
    );
    trash(
        "simulators-unavailable",
        "Unavailable simulators",
        unavailable_simulators(home),
        &["Simulator", "simctl"],
        "Simulators whose runtime is no longer installed (what `xcrun simctl delete unavailable` removes).",
    );
    trash(
        "npm-cache",
        "npm cache",
        vec![home.join(".npm/_cacache")],
        &["npm", "npx"],
        "Same as `npm cache clean --force`; packages download again when needed.",
    );
    trash(
        "yarn-cache",
        "Yarn cache",
        vec![home.join("Library/Caches/Yarn")],
        &["yarn"],
        "Same as `yarn cache clean`.",
    );
    trash(
        "cargo-registry",
        "Cargo downloads",
        vec![
            home.join(".cargo/registry/cache"),
            home.join(".cargo/registry/src"),
            home.join(".cargo/git/checkouts"),
        ],
        &["cargo", "rustc", "rust-analyzer"],
        "Downloaded crate archives and sources; the index stays and crates download again when needed.",
    );
    trash(
        "gradle-caches",
        "Gradle caches",
        vec![home.join(".gradle/caches")],
        &["java", "gradle"],
        "Dependencies and build caches; Gradle downloads them again.",
    );
    trash(
        "composer-cache",
        "Composer cache",
        vec![
            home.join("Library/Caches/composer"),
            home.join(".composer/cache"),
        ],
        &["composer"],
        "Same as `composer clear-cache`.",
    );
    trash(
        "pip-cache",
        "pip cache",
        vec![home.join("Library/Caches/pip")],
        &["pip", "pip3"],
        "Same as `pip cache purge`.",
    );
    if let Some(brew) = tool(home, "brew") {
        let cache = home.join("Library/Caches/Homebrew");
        let estimate = size(std::slice::from_ref(&cache));
        if estimate > 0 {
            out.push(Action {
                id: "brew-cleanup",
                title: "Homebrew cleanup",
                kind: "command",
                command: format!("{} cleanup -s --prune=all", brew.display()),
                argv: vec![
                    brew.display().to_string(),
                    "cleanup".into(),
                    "-s".into(),
                    "--prune=all".into(),
                ],
                paths: vec![],
                docker_kind: None,
                estimate,
                up_to: true,
                busy: running(processes, &["brew", "ruby"]),
                note: "Old versions and downloads Homebrew keeps; installed formulae stay.",
            });
        }
    }
    if let Some(pnpm) = tool(home, "pnpm") {
        let store = home.join("Library/pnpm/store");
        let estimate = size(std::slice::from_ref(&store));
        if estimate > 0 {
            out.push(Action {
                id: "pnpm-store",
                title: "pnpm store prune",
                kind: "command",
                command: format!("{} store prune", pnpm.display()),
                argv: vec![pnpm.display().to_string(), "store".into(), "prune".into()],
                paths: vec![],
                docker_kind: None,
                estimate,
                up_to: true,
                busy: running(processes, &["pnpm"]),
                note: "Removes packages no project references; the rest stays linked.",
            });
        }
    }
    if let Some(go) = tool(home, "go") {
        let modcache = home.join("go/pkg/mod");
        let estimate = size(std::slice::from_ref(&modcache));
        if estimate > 0 {
            out.push(Action {
                id: "go-modcache",
                title: "Go module cache",
                kind: "command",
                command: format!("{} clean -modcache", go.display()),
                argv: vec![go.display().to_string(), "clean".into(), "-modcache".into()],
                paths: vec![],
                docker_kind: None,
                estimate,
                up_to: false,
                busy: running(processes, &["go", "gopls"]),
                note: "Modules download again on the next build.",
            });
        }
    }
    let (docker, _) = if with_docker {
        devspace::docker(home)
    } else {
        (vec![], None)
    };
    for item in docker {
        let (id, title, note) = match item.kind {
            "docker_build_cache" => (
                "docker-build-cache",
                "Docker build cache",
                "BuildKit layers no image uses; the next build is slower once.",
            ),
            "docker_dangling" => (
                "docker-dangling",
                "Docker untagged images",
                "Image layers left by rebuilds, with no tag and no container.",
            ),
            _ => continue,
        };
        out.push(Action {
            id,
            title,
            kind: "docker",
            command: format!(
                "Docker Engine API: prune {} ({})",
                item.kind.trim_start_matches("docker_").replace('_', " "),
                item.name
            ),
            paths: vec![item.path.clone()],
            argv: vec![],
            docker_kind: Some(item.kind),
            estimate: item.bytes,
            up_to: false,
            busy: None,
            note,
        });
    }
    out.sort_by_key(|a| std::cmp::Reverse(a.estimate));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_lists_caches_with_estimates_and_busy_tools() {
        let home = std::env::temp_dir().join(format!("corescope-plan-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join(".npm/_cacache/x")).unwrap();
        std::fs::write(home.join(".npm/_cacache/x/blob"), vec![1u8; 256 * 1024]).unwrap();
        std::fs::create_dir_all(home.join(".cargo/registry/cache")).unwrap();
        std::fs::write(
            home.join(".cargo/registry/cache/a.crate"),
            vec![1u8; 64 * 1024],
        )
        .unwrap();
        std::fs::create_dir_all(home.join(".cargo/registry/index")).unwrap();
        let mut npm = crate::process_fixture();
        npm.name = "npm".into();
        let actions = plan(&home, &[npm], false);
        let npm_action = actions.iter().find(|a| a.id == "npm-cache").unwrap();
        assert!(npm_action.estimate >= 256 * 1024);
        assert_eq!(npm_action.kind, "trash");
        assert!(npm_action.busy.as_deref().unwrap().starts_with("npm (PID"));
        assert!(npm_action.command.contains("~/.npm/_cacache"));
        let cargo = actions.iter().find(|a| a.id == "cargo-registry").unwrap();
        assert_eq!(
            cargo.paths.len(),
            1,
            "only folders that exist; the index is never touched"
        );
        assert!(cargo.busy.is_none());
        assert!(
            actions.iter().all(|a| a.id != "gradle-caches"),
            "nothing to free, not listed"
        );
        assert!(actions[0].estimate >= actions[actions.len() - 1].estimate);
        std::fs::remove_dir_all(home).unwrap();
    }
}
