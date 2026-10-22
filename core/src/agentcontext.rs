//! What an agent should know about a project from its `.corescope.yml`, as a short text: the
//! capacity rule before heavy commands, preferred ports, profiles, services and logs, or the
//! file's error with its line. Delivered at session start by a hook (`corescope context --hook`,
//! Claude Code and Codex), on request (MCP `agent_context`), or written as a marked section of
//! `CLAUDE.md` / `AGENTS.md` for agents without hooks.
use crate::projectconfig::{self, Found};
use serde::Serialize;
use std::path::{Path, PathBuf};

pub const BEGIN: &str =
    "<!-- corescope:begin (generated from .corescope.yml; CoreScope rewrites this section) -->";
pub const END: &str = "<!-- corescope:end -->";
/// Files the instructions section can go in.
pub const INSTRUCTION_FILES: [&str; 2] = ["CLAUDE.md", "AGENTS.md"];

/// The nearest `.corescope.yml` at or above `folder`.
pub fn find(folder: &Path) -> Option<Found> {
    folder
        .ancestors()
        .take(16)
        .find(|a| projectconfig::file_in(a).is_some())
        .and_then(projectconfig::load)
}

/// The context text for a loaded project file.
pub fn render(found: &Found) -> String {
    let mut out = vec![
        "This project is set up for CoreScope, the Mac's local dev monitor, through its .corescope.yml. Follow it:"
            .to_string(),
    ];
    let Some(config) = &found.config else {
        let error = found.error.as_deref().unwrap_or("unreadable");
        let text = std::fs::read_to_string(&found.file).unwrap_or_default();
        let line = crate::projects::error_line(&text, error)
            .map(|l| format!(" (line {l})"))
            .unwrap_or_default();
        out.push(format!(
            "- The .corescope.yml has an error{line}: {error}. CoreScope ignores it until it is fixed; tell the user, or fix it if you are working on it (MCP read_project_config / write_project_config validate it)."
        ));
        return out.join("\n");
    };
    if let Some(name) = &config.name {
        out[0] = format!(
            "This project ({name}) is set up for CoreScope, the Mac's local dev monitor, through its .corescope.yml. Follow it:"
        );
    }
    if let Some(c) = config
        .agents
        .as_ref()
        .and_then(|a| a.wait_for_capacity.as_ref())
    {
        let heavy: Vec<String> = crate::capacity::heavy_list(c)
            .iter()
            .map(|h| {
                if h.uses().containers {
                    format!("`{}` (also the container VM)", h.command())
                } else {
                    format!("`{}`", h.command())
                }
            })
            .collect();
        out.push(format!(
            "- The Mac is shared; heavy commands go through CoreScope's admission queue: {}. Before one, call the MCP tool system_capacity (or reserve_capacity to hold a place). If it is deferred: when the reason is transient (CPU, memory pressure, a queue), call wait_for_capacity (up to 55 s per call) and try again — the wait budget is {}; when it is structural (the container VM is full), waiting won't help: do what it says or ask the user. With CoreScope's gate hook on, a deferred command is refused at once with the reason. Don't run heavy commands in parallel or in the background to get around the queue, and prefer CI when the check can run there. Limits: CPU below {:.0}%, memory pressure {} or better, {:.0}% of the container VM free.",
            heavy.join(", "),
            if c.max_wait_minutes < 1. {
                format!("{:.0} s", c.max_wait_minutes * 60.)
            } else {
                format!("{:.0} min", c.max_wait_minutes)
            },
            c.cpu_below,
            c.memory,
            c.container_memory_free
        ));
    }
    if !config.ports.is_empty() {
        let ports: Vec<String> = config
            .ports
            .iter()
            .map(|(role, port)| format!("{role} {port}"))
            .collect();
        out.push(format!(
            "- Preferred ports: {}. Use them for dev servers; if one is taken, ask CoreScope for a free one (MCP find_free_port, list_ports) instead of killing what holds it.",
            ports.join(", ")
        ));
    }
    if !config.profiles.is_empty() {
        let names: Vec<String> = config.profiles.keys().map(|n| format!("`{n}`")).collect();
        out.push(format!(
            "- Environments are profiles: {}. Start and stop them with MCP start_profile / stop_profile (profile_logs for output) rather than launching their commands by hand.",
            names.join(", ")
        ));
    }
    if !config.services.is_empty() {
        let services: Vec<String> = config
            .services
            .iter()
            .map(|s| match &s.name {
                Some(n) => format!("{n} ({})", s.target),
                None => s.target.clone(),
            })
            .collect();
        out.push(format!(
            "- It depends on: {}. If something fails to connect, check them with MCP check_services first.",
            services.join(", ")
        ));
    }
    if let Some(env) = &config.environment {
        if env.status.is_some() {
            out.push("- An environment controller reports its real state: read it with MCP environment_status (apps selected, components, modes) before assuming something is up or down.".into());
        }
        let apps: Vec<String> = env
            .apps
            .iter()
            .filter(|(_, a)| !a.modes.is_empty())
            .map(|(k, a)| {
                format!(
                    "`{k}` ({})",
                    a.modes.keys().cloned().collect::<Vec<_>>().join(", ")
                )
            })
            .collect();
        if !apps.is_empty() {
            out.push(format!(
                "- Apps and their modes: {}. Bring one up or down with MCP start_profile / stop_profile (list_profiles names each app mode) instead of running the controller by hand.",
                apps.join("; ")
            ));
        }
        let count = env.actions.len() + env.apps.values().map(|a| a.actions.len()).sum::<usize>();
        if count > 0 {
            out.push(format!(
                "- {count} one-off actions (setup, diagnostics, backups…): list them with MCP list_actions and run them with run_action, not by hand; ask the user first."
            ));
        }
    }
    if !config.logs.is_empty() {
        out.push(format!(
            "- Its logs ({}) are followed by CoreScope: to debug, use MCP recent_errors / search_logs instead of asking the user for logs.",
            config.logs.join(", ")
        ));
    }
    out.push("- Before migrate:fresh, db:wipe or anything that drops data, take a snapshot with MCP db_snapshot. Stop only processes your own session started.".into());
    out.join("\n")
}

/// The text for `folder`, or None when no `.corescope.yml` covers it.
pub fn for_folder(folder: &Path) -> Option<String> {
    find(folder).map(|f| render(&f))
}

/// SessionStart hook output (Claude Code and Codex): the text as additional context.
pub fn hook_output(text: &str) -> String {
    serde_json::json!({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}})
        .to_string()
}

/// `existing` with the CoreScope section replaced (or appended), or with it removed when `text`
/// is None. Everything outside the markers is kept byte for byte.
pub fn with_section(existing: &str, text: Option<&str>) -> String {
    let block = text.map(|t| format!("{BEGIN}\n## CoreScope\n\n{t}\n{END}"));
    if let (Some(start), Some(end)) = (existing.find(BEGIN), existing.find(END))
        && end > start
    {
        let after = &existing[end + END.len()..];
        return match block {
            Some(b) => format!("{}{b}{after}", &existing[..start]),
            None => {
                let before = existing[..start].trim_end_matches('\n');
                let after = after.trim_start_matches('\n');
                match (before.is_empty(), after.is_empty()) {
                    (true, _) => after.to_string(),
                    (false, true) => format!("{before}\n"),
                    (false, false) => format!("{before}\n\n{after}"),
                }
            }
        };
    }
    match block {
        None => existing.to_string(),
        Some(b) if existing.trim().is_empty() => format!("{b}\n"),
        Some(b) => format!("{}\n\n{b}\n", existing.trim_end_matches('\n')),
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct InstructionFile {
    pub file: String,
    pub exists: bool,
    /// "missing" (no section), "current" or "outdated".
    pub state: &'static str,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Instructions {
    pub folder: String,
    pub text: Option<String>,
    pub files: Vec<InstructionFile>,
}

fn section_state(existing: &str, text: &str) -> &'static str {
    if !existing.contains(BEGIN) {
        "missing"
    } else if with_section(existing, Some(text)) == existing {
        "current"
    } else {
        "outdated"
    }
}

/// The section and where it stands in `CLAUDE.md` / `AGENTS.md` at the project's root.
pub fn instructions(folder: &Path) -> Result<Instructions, String> {
    let found = find(folder).ok_or("no .corescope.yml in this folder or above it")?;
    let root = PathBuf::from(&found.folder);
    let text = render(&found);
    let files = INSTRUCTION_FILES
        .iter()
        .map(|name| {
            let path = root.join(name);
            let existing = std::fs::read_to_string(&path).ok();
            InstructionFile {
                file: path.to_string_lossy().into(),
                exists: existing.is_some(),
                state: section_state(existing.as_deref().unwrap_or(""), &text),
            }
        })
        .collect();
    Ok(Instructions {
        folder: found.folder,
        text: Some(text),
        files,
    })
}

/// Writes (or with `remove`, takes out) the section in the named files at the project's root;
/// a missing file is created only when writing. Returns the new state.
pub fn write_instructions(
    folder: &Path,
    names: &[String],
    remove: bool,
) -> Result<Instructions, String> {
    let found = find(folder).ok_or("no .corescope.yml in this folder or above it")?;
    let root = PathBuf::from(&found.folder);
    let text = render(&found);
    for name in names {
        if !INSTRUCTION_FILES.contains(&name.as_str()) {
            return Err(format!(
                "only {} can be written",
                INSTRUCTION_FILES.join(" and ")
            ));
        }
        let path = root.join(name);
        // Never write through a symlink pointing somewhere else.
        if std::fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(format!("{name} is a symbolic link; edit it by hand"));
        }
        let existing = std::fs::read_to_string(&path).unwrap_or_default();
        if remove && !existing.contains(BEGIN) {
            continue;
        }
        let next = with_section(&existing, (!remove).then_some(text.as_str()));
        if remove && next.trim().is_empty() {
            // Only the section was there: the file was CoreScope's.
            std::fs::remove_file(&path).map_err(|e| format!("{name}: {e}"))?;
        } else if next != existing {
            std::fs::write(&path, next).map_err(|e| format!("{name}: {e}"))?;
        }
    }
    instructions(folder)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(yaml: &str) -> (PathBuf, Found) {
        let dir = std::env::temp_dir().join(format!(
            "corescope-ctx-{}-{}",
            std::process::id(),
            yaml.len()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("app/src")).unwrap();
        std::fs::write(dir.join(".corescope.yml"), yaml).unwrap();
        let f = find(&dir.join("app/src")).expect("found from a subfolder");
        (dir, f)
    }

    #[test]
    fn context_follows_the_project_file() {
        let (dir, f) = found(
            "name: shop\nports:\n  web: 8000\nprofiles:\n  dev:\n    commands:\n      - run: npm run dev\nservices:\n  - name: mysql\n    target: 3306\nlogs:\n  - storage/logs/*.log\nagents:\n  wait_for_capacity:\n    cpu_below: 60\n    heavy_commands: [php artisan test]\n",
        );
        let text = render(&f);
        assert!(text.contains("(shop)"));
        assert!(text.contains("`php artisan test`") && text.contains("below 60%"));
        assert!(
            !text.contains("cargo build"),
            "the project's own list replaces the defaults"
        );
        assert!(
            text.contains("web 8000") && text.contains("`dev`") && text.contains("mysql (3306)")
        );
        assert!(text.contains("storage/logs/*.log"));
        let hook: serde_json::Value = serde_json::from_str(&hook_output(&text)).unwrap();
        assert_eq!(hook["hookSpecificOutput"]["hookEventName"], "SessionStart");
        assert_eq!(
            hook["hookSpecificOutput"]["additionalContext"],
            text.as_str()
        );
        std::fs::remove_dir_all(dir).unwrap();

        let (dir, f) = found("name: x\nagents:\n  wait_for_capacity:\n    cpu_below: 70\n");
        assert!(
            render(&f).contains("`cargo build`"),
            "defaults when no list"
        );
        std::fs::remove_dir_all(dir).unwrap();

        let (dir, f) = found("name: x\nprofiles:\n  dev:\n    command:\n      - run: x\n");
        let text = render(&f);
        assert!(text.contains("has an error (line 4)"), "{text}");
        std::fs::remove_dir_all(dir).unwrap();
        assert!(for_folder(Path::new("/")).is_none());
    }

    #[test]
    fn section_is_added_replaced_and_removed_in_place() {
        let mine = "# Rules\n\nUse tabs.\n";
        let added = with_section(mine, Some("A"));
        assert!(added.starts_with("# Rules\n\nUse tabs.\n\n<!-- corescope:begin"));
        assert!(added.ends_with(&format!("A\n{END}\n")));
        let replaced = with_section(&added, Some("B"));
        assert!(replaced.contains("\nB\n") && !replaced.contains("\nA\n"));
        assert_eq!(with_section(&replaced, None), mine);
        let middle = format!("top\n\n{BEGIN}\nold\n{END}\n\nbottom\n");
        assert_eq!(with_section(&middle, None), "top\n\nbottom\n");
        assert_eq!(
            with_section("", Some("A")),
            format!("{BEGIN}\n## CoreScope\n\nA\n{END}\n")
        );
        assert_eq!(with_section(&with_section("", Some("A")), None), "");
        assert_eq!(section_state(&added, "A"), "current");
        assert_eq!(section_state(&added, "B"), "outdated");
        assert_eq!(section_state(mine, "A"), "missing");
    }

    #[test]
    fn instruction_files_are_written_only_where_asked() {
        let (dir, _) = found("name: files\nports:\n  web: 3000\n");
        std::fs::write(dir.join("CLAUDE.md"), "# Mine\n").unwrap();
        let before = instructions(&dir).unwrap();
        assert_eq!(before.files[0].state, "missing");
        assert!(!before.files[1].exists);
        let after = write_instructions(&dir, &["CLAUDE.md".into()], false).unwrap();
        assert_eq!(after.files[0].state, "current");
        assert!(!after.files[1].exists, "AGENTS.md not asked for");
        assert!(
            std::fs::read_to_string(dir.join("CLAUDE.md"))
                .unwrap()
                .starts_with("# Mine\n\n")
        );
        assert!(write_instructions(&dir, &["../x.md".into()], false).is_err());
        assert!(
            !std::fs::read_to_string(dir.join("CLAUDE.md"))
                .unwrap()
                .contains(&dir.to_string_lossy().to_string()),
            "no machine paths in a committed file"
        );
        write_instructions(&dir, &["AGENTS.md".into()], false).unwrap();
        write_instructions(&dir, &["AGENTS.md".into()], true).unwrap();
        assert!(
            !dir.join("AGENTS.md").exists(),
            "a file that only held the section goes away"
        );
        write_instructions(&dir, &["CLAUDE.md".into()], true).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join("CLAUDE.md")).unwrap(),
            "# Mine\n"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }
}
