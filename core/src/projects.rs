//! Projects the user registered (a folder with a `.corescope.yml`, usually a git repository):
//! the list, kept in `~/Library/Application Support/CoreScope/projects.json` so the app, the CLI
//! and MCP share it, and what a folder holds before it is added.
use crate::{git, projectconfig};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub folder: String,
    #[serde(default)]
    pub show_in_panel: bool,
    /// Minutes between change notifications (1, 5 or 15); None: off.
    #[serde(default)]
    pub notify_minutes: Option<u32>,
    pub added: i64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Default)]
pub struct ConfigSummary {
    pub exists: bool,
    pub file: Option<String>,
    pub name: Option<String>,
    /// The first problem, with its 1-based line when it can be placed.
    pub error: Option<String>,
    pub error_line: Option<usize>,
    pub profiles: Vec<String>,
    pub ports: Vec<String>,
    pub services: usize,
    pub logs: usize,
    pub wait_for_capacity: bool,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Check {
    pub folder: String,
    /// `name:` from `.corescope.yml`, else the folder's name.
    pub default_name: String,
    pub config: ConfigSummary,
    pub git: git::RepoInfo,
    /// Already registered under this id.
    pub registered: Option<String>,
}

/// `~/Library/Application Support/CoreScope/projects.json`.
pub fn default_path(home: &Path) -> PathBuf {
    home.join("Library/Application Support/CoreScope/projects.json")
}
pub fn load(file: &Path) -> Vec<Project> {
    std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
pub fn save(file: &Path, list: &[Project]) -> Result<(), String> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = file.with_extension("json.tmp");
    std::fs::write(
        &tmp,
        serde_json::to_vec_pretty(list).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, file).map_err(|e| e.to_string())
}

/// The 1-based line a validation message is about: the key it names (`unknown field `foo``,
/// `profile web: …`, `agents.wait_for_capacity.cpu_below: …`), or the line a syntax error states.
pub fn error_line(text: &str, message: &str) -> Option<usize> {
    if let Some(rest) = message.strip_prefix("line ") {
        return rest
            .split(|c: char| !c.is_ascii_digit())
            .next()?
            .parse()
            .ok();
    }
    let key = if let Some(start) = message.find('`') {
        let rest = &message[start + 1..];
        rest[..rest.find('`')?].to_string()
    } else if let Some(name) = message.strip_prefix("profile ") {
        name.split(':').next()?.trim().to_string()
    } else {
        let head = message.split(':').next()?.trim();
        head.rsplit('.').next()?.to_string()
    };
    if key.is_empty() {
        return None;
    }
    text.lines()
        .position(|l| {
            let t = l.trim_start().trim_start_matches("- ");
            t.strip_prefix(key.as_str())
                .is_some_and(|r| r.starts_with(':'))
        })
        .map(|i| i + 1)
}

pub fn summarize(folder: &Path) -> ConfigSummary {
    let Some(file) = projectconfig::file_in(folder) else {
        return ConfigSummary::default();
    };
    let text = std::fs::read_to_string(&file).unwrap_or_default();
    let mut s = ConfigSummary {
        exists: true,
        file: Some(file.to_string_lossy().into_owned()),
        ..Default::default()
    };
    match projectconfig::parse(&text) {
        Ok(c) => {
            s.name = c.name.clone();
            s.profiles = c.profiles.keys().cloned().collect();
            s.ports = c.ports.iter().map(|(k, v)| format!("{k}: {v}")).collect();
            s.services = c.services.len();
            s.logs = c.logs.len();
            s.wait_for_capacity = c
                .agents
                .as_ref()
                .is_some_and(|a| a.wait_for_capacity.is_some());
        }
        Err(e) => {
            s.error_line = error_line(&text, &e);
            s.error = Some(e);
        }
    }
    s
}

pub fn default_name(folder: &Path, config: &ConfigSummary) -> String {
    config
        .name
        .clone()
        .filter(|n| !n.trim().is_empty())
        .unwrap_or_else(|| {
            folder
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| folder.to_string_lossy().into_owned())
        })
}

fn canonical(folder: &Path) -> String {
    folder
        .canonicalize()
        .unwrap_or_else(|_| folder.to_path_buf())
        .to_string_lossy()
        .into_owned()
}

pub fn check(folder: &Path, list: &[Project]) -> Check {
    let config = summarize(folder);
    let key = canonical(folder);
    Check {
        folder: key.clone(),
        default_name: default_name(folder, &config),
        git: git::inspect(folder),
        registered: list.iter().find(|p| p.folder == key).map(|p| p.id.clone()),
        config,
    }
}

/// Writes a minimal `.corescope.yml` (just the name) with the existing writer.
pub fn create_template(folder: &Path, name: &str) -> Result<PathBuf, String> {
    if projectconfig::file_in(folder).is_some() {
        return Err(".corescope.yml already exists".into());
    }
    let config = projectconfig::ProjectConfig {
        name: Some(name.trim().to_string()),
        ..Default::default()
    };
    projectconfig::write(folder, &config)
}

/// Adds a folder: it must hold a `.corescope.yml` (create it first with `create_template`, or
/// pass `template` to create one). A folder already in the list keeps its entry.
pub fn add(
    file: &Path,
    folder: &Path,
    name: &str,
    template: bool,
    now: i64,
) -> Result<Project, String> {
    if !folder.is_dir() {
        return Err("folder must be an existing directory".into());
    }
    let name = name.trim();
    if name.is_empty() {
        return Err("a name is required".into());
    }
    if projectconfig::file_in(folder).is_none() {
        if !template {
            return Err("this folder has no .corescope.yml".into());
        }
        create_template(folder, name)?;
    }
    let mut list = load(file);
    let key = canonical(folder);
    if let Some(p) = list.iter().find(|p| p.folder == key) {
        return Ok(p.clone());
    }
    let project = Project {
        id: format!("{:x}", fnv(&format!("{key}{now}"))),
        name: name.to_string(),
        folder: key,
        show_in_panel: false,
        notify_minutes: None,
        added: now,
    };
    list.push(project.clone());
    save(file, &list)?;
    Ok(project)
}
pub fn update(file: &Path, id: &str, change: impl FnOnce(&mut Project)) -> Result<Project, String> {
    let mut list = load(file);
    let p = list
        .iter_mut()
        .find(|p| p.id == id)
        .ok_or("no such project")?;
    change(p);
    if p.name.trim().is_empty() {
        return Err("a name is required".into());
    }
    if let Some(m) = p.notify_minutes
        && ![1, 5, 15].contains(&m)
    {
        return Err("notify_minutes takes 1, 5 or 15".into());
    }
    let updated = p.clone();
    save(file, &list)?;
    Ok(updated)
}
/// Removes the entry; files are never touched.
pub fn remove(file: &Path, id: &str) -> Result<(), String> {
    let mut list = load(file);
    let before = list.len();
    list.retain(|p| p.id != id);
    if list.len() == before {
        return Err("no such project".into());
    }
    save(file, &list)
}
fn fnv(s: &str) -> u64 {
    s.bytes().fold(0xcbf29ce484222325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x100000001b3)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_lines_point_at_the_key() {
        let text = "name: shop\nprofiles:\n  web:\n    containers: []\nagents:\n  wait_for_capacity:\n    cpu_below: 200\n";
        assert_eq!(error_line(text, "line 4: unexpected indentation"), Some(4));
        assert_eq!(
            error_line(
                text,
                "invalid .corescope.yml: unknown field `profiles`, expected …"
            ),
            Some(2)
        );
        assert_eq!(
            error_line(text, "profile web: needs commands or containers"),
            Some(3)
        );
        assert_eq!(
            error_line(
                text,
                "agents.wait_for_capacity.cpu_below: between 1 and 100"
            ),
            Some(7)
        );
        assert_eq!(error_line(text, "something else entirely"), None);
    }

    #[test]
    fn default_names_add_template_and_registry() {
        let root = std::env::temp_dir().join(format!("corescope-projects-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let shop = root.join("shop-app");
        std::fs::create_dir_all(&shop).unwrap();
        let file = root.join("projects.json");
        let c = check(&shop, &[]);
        assert!(!c.config.exists && !c.git.is_repo);
        assert_eq!(
            c.default_name, "shop-app",
            "folder name without a .corescope.yml"
        );
        assert!(
            add(&file, &shop, "Shop", false, 1)
                .unwrap_err()
                .contains("no .corescope.yml")
        );
        assert!(
            load(&file).is_empty(),
            "declining the template adds nothing"
        );
        let p = add(&file, &shop, "Shop", true, 1).unwrap();
        let c = check(&shop, &load(&file));
        assert!(c.config.exists && c.config.error.is_none());
        assert_eq!(
            (c.default_name.as_str(), c.registered.as_deref()),
            ("Shop", Some(p.id.as_str()))
        );
        assert_eq!(
            add(&file, &shop, "Other", false, 2).unwrap().id,
            p.id,
            "same folder, same entry"
        );
        let renamed = update(&file, &p.id, |p| p.name = "Shop API".into()).unwrap();
        assert_eq!(renamed.name, "Shop API");
        assert!(update(&file, &p.id, |p| p.notify_minutes = Some(7)).is_err());
        remove(&file, &p.id).unwrap();
        assert!(
            load(&file).is_empty() && shop.join(".corescope.yml").exists(),
            "removing keeps the files"
        );
        std::fs::write(
            shop.join(".corescope.yml"),
            "name: shop\nprofiles:\n  web:\n    containers: []\n",
        )
        .unwrap();
        let bad = summarize(&shop);
        assert_eq!(bad.error_line, Some(3), "{:?}", bad.error);
        std::fs::remove_dir_all(root).unwrap();
    }
}
