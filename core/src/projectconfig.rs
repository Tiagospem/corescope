//! `.corescope.yml`: a project's dev environment as code — profiles (commands, stop commands,
//! containers), preferred ports, Services checks, log files and how agents should wait for the
//! machine. Committed with the project, found automatically, read by the app, the CLI and MCP.
//!
//! The parser accepts the YAML this file needs and nothing more: block mappings and sequences by
//! indentation, `[a, b]` flow lists, quoted and plain scalars, numbers, booleans, null and `#`
//! comments. Anchors, tags, multi-line scalars and documents are rejected with a line number
//! rather than guessed at.
use serde::{Deserialize, Serialize};
use serde_json::{Map, Number, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const FILE_NAMES: [&str; 2] = [".corescope.yml", ".corescope.yaml"];

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProjectConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub profiles: BTreeMap<String, ProfileSpec>,
    /// Preferred ports by role (`web: 8000`): conflicts are reported and free ones suggested.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub ports: BTreeMap<String, u16>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub services: Vec<ServiceSpec>,
    /// An environment run by the project's own controller: its status command, its apps (each
    /// with the modes it can be brought up in, its stop command and its actions) and
    /// environment-wide actions. See docs/ENVIRONMENT-CONTROLLER.md.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<EnvironmentSpec>,
    /// Log files or globs relative to the project (`storage/logs/*.log`), added to Logs.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub logs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agents: Option<AgentsSpec>,
    /// The project's databases, by name: what the change monitor hides by default, which tables
    /// a dump restore brings without data, and commands (any stack) run in the project folder
    /// before and after a restore.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub databases: BTreeMap<String, DatabaseSpec>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct DatabaseSpec {
    /// The server: a container name or a host port. Without it, any local server with a
    /// database of this name.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "optional_string_or_number"
    )]
    pub server: Option<String>,
    /// Tables the change monitor hides by default (the app can show them again).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ignore_changes: Vec<String>,
    /// Tables a restore creates empty by default.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skip_data: Vec<String>,
    /// Shell commands run in the project folder before the database is dropped (stop workers…).
    #[serde(
        default,
        skip_serializing_if = "Vec::is_empty",
        deserialize_with = "one_or_many"
    )]
    pub before_restore: Vec<String>,
    /// Shell commands run after a successful restore (migrations, cache, fixtures…).
    #[serde(
        default,
        skip_serializing_if = "Vec::is_empty",
        deserialize_with = "one_or_many"
    )]
    pub after_restore: Vec<String>,
}
fn optional_string_or_number<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> Result<Option<String>, D::Error> {
    string_or_number(d).map(Some)
}
/// A command or a list of commands.
fn one_or_many<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    match Value::deserialize(d)? {
        Value::String(s) => Ok(vec![s]),
        Value::Array(items) => items
            .into_iter()
            .map(|v| match v {
                Value::String(s) => Ok(s),
                other => Err(serde::de::Error::custom(format!(
                    "expected a command, found {other}"
                ))),
            })
            .collect(),
        Value::Null => Ok(vec![]),
        other => Err(serde::de::Error::custom(format!(
            "expected a command or a list of commands, found {other}"
        ))),
    }
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ProfileSpec {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub commands: Vec<CommandSpec>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub containers: Vec<String>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CommandSpec {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub run: String,
    /// Undoes a setup command on Stop (`make env-down` for `make env-up`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop: Option<String>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ServiceSpec {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// A URL, host:port or a bare port (`3306`, written as a number or a string).
    #[serde(deserialize_with = "string_or_number")]
    pub target: String,
    /// Profiles of this file that need it: expected while one of them is on; switched off
    /// (neutral, no alert) otherwise. Without it, the older project-wide rule applies.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub profiles: Vec<String>,
    /// A component of the status output: expected when the status says so.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub component: Option<String>,
    /// An app of `environment.apps`: expected while it is up (selected, or one of its modes on).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<String>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct EnvironmentSpec {
    /// Prints the status JSON (format 1) and exits; read-only and quick.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<StatusSpec>,
    /// Apps of the environment by the name the status uses (`revamp`), or groups of actions
    /// (`memory`), each folded on the Profiles page.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub apps: BTreeMap<String, AppSpec>,
    /// Actions for the whole environment (init, doctor, stop everything).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub actions: BTreeMap<String, ActionSpec>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AppSpec {
    /// Display name (default: the key).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Ways to bring the app up, one at a time (`dev: bin/eco up revamp --web dev`). Each command
    /// does the whole operation and exits once it verified; CoreScope never starts or stops the
    /// app's containers itself.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub modes: BTreeMap<String, String>,
    /// Takes this app down (only what no other selected app needs). Required with `modes`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub down: Option<String>,
    /// Containers to watch while the app is up (never started or stopped by CoreScope).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub containers: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub actions: BTreeMap<String, ActionSpec>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct StatusSpec {
    /// Prints the status JSON and exits; must be read-only and quick.
    pub run: String,
    /// Default 5, at most 30.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_seconds: Option<f64>,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ActionSpec {
    pub run: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Default 10; between 1 and 1440.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_minutes: Option<f64>,
    /// Ask before running (restores, anything that overwrites data).
    #[serde(default, skip_serializing_if = "is_false")]
    pub confirm: bool,
    /// Read-only command whose output is shown in the confirmation (file, origin, date, target).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    /// Waits for the Mac to have room first (the file's `agents.wait_for_capacity`, or defaults).
    #[serde(default, skip_serializing_if = "is_false")]
    pub heavy: bool,
    /// setup, run, diagnostics, data, stop or other; guessed from the name when absent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}
pub const ACTION_KINDS: [&str; 6] = ["setup", "run", "diagnostics", "data", "stop", "other"];
fn is_false(b: &bool) -> bool {
    !*b
}
fn string_or_number<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    match Value::deserialize(d)? {
        Value::String(s) => Ok(s),
        Value::Number(n) => Ok(n.to_string()),
        other => Err(serde::de::Error::custom(format!(
            "expected a string or a number, found {other}"
        ))),
    }
}
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AgentsSpec {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait_for_capacity: Option<CapacitySpec>,
}
/// Agents working in this project wait before heavy commands until the Mac has room.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct CapacitySpec {
    /// Total CPU (percent of all cores) that must be below this to start. Default 70.
    #[serde(default = "default_cpu")]
    pub cpu_below: f64,
    /// Highest acceptable memory pressure: `normal` (default) or `warning`.
    #[serde(default = "default_memory")]
    pub memory: String,
    /// Give up waiting after this long and run anyway. Default 30.
    #[serde(default = "default_wait")]
    pub max_wait_minutes: f64,
    /// Commands that count as heavy (builds, test suites, `docker compose up`): a prefix, or
    /// `{command, uses, weight}` saying what it draws on.
    #[serde(default)]
    pub heavy_commands: Vec<HeavyCommand>,
    /// Share of the container engine's VM memory (OrbStack, Docker Desktop, Colima) that must
    /// be free, percent. Default 15; 0 turns the check off.
    #[serde(default = "default_container_free")]
    pub container_memory_free: f64,
    /// Heavy commands running at once on the Mac, as a sum of weights (default 2). One always
    /// runs when there is room, whatever its weight.
    #[serde(default = "default_parallel")]
    pub max_parallel: f64,
}
fn default_parallel() -> f64 {
    2.
}
fn default_container_free() -> f64 {
    15.
}

/// A heavy command: a plain prefix (it uses the Mac's CPU and memory) or one that says what it
/// uses — `containers` adds the container VM's memory — and how heavy it is for the queue.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
pub enum HeavyCommand {
    Prefix(String),
    Detailed(HeavySpec),
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct HeavySpec {
    pub command: String,
    /// `cpu`, `memory`, `containers`. Default: cpu and memory.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uses: Option<Vec<String>>,
    /// Rough weight for the admission queue (default 1): a heavier command waits longer before
    /// the next one is admitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weight: Option<f64>,
    /// The containers it loads (name, compose service or `project-service`): each must be
    /// running and below 90% of its own memory limit. Implies `containers` in `uses`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub containers: Vec<String>,
}
impl HeavyCommand {
    pub fn with_uses(command: &str, uses: crate::capacity::Uses) -> HeavyCommand {
        HeavyCommand::Detailed(HeavySpec {
            command: command.into(),
            uses: Some(uses.names().into_iter().map(String::from).collect()),
            weight: None,
            containers: vec![],
        })
    }
    pub fn command(&self) -> &str {
        match self {
            HeavyCommand::Prefix(c) => c,
            HeavyCommand::Detailed(d) => &d.command,
        }
    }
    pub fn uses(&self) -> crate::capacity::Uses {
        let base = match self {
            HeavyCommand::Detailed(HeavySpec {
                uses: Some(list), ..
            }) => crate::capacity::Uses::parse(list).unwrap_or(crate::capacity::Uses::MAC),
            _ => crate::capacity::Uses::MAC,
        };
        if self.containers().is_empty() {
            base
        } else {
            crate::capacity::Uses {
                containers: true,
                ..base
            }
        }
    }
    pub fn containers(&self) -> &[String] {
        match self {
            HeavyCommand::Detailed(d) => &d.containers,
            _ => &[],
        }
    }
    pub fn weight(&self) -> f64 {
        match self {
            HeavyCommand::Detailed(HeavySpec {
                weight: Some(w), ..
            }) => w.clamp(0.1, 10.),
            _ => 1.,
        }
    }
}
impl PartialEq<&str> for HeavyCommand {
    fn eq(&self, other: &&str) -> bool {
        matches!(self, HeavyCommand::Prefix(c) if c == other)
    }
}
fn default_cpu() -> f64 {
    70.
}
fn default_memory() -> String {
    "normal".into()
}
fn default_wait() -> f64 {
    30.
}
impl Default for CapacitySpec {
    fn default() -> Self {
        CapacitySpec {
            cpu_below: default_cpu(),
            memory: default_memory(),
            max_wait_minutes: default_wait(),
            heavy_commands: vec![],
            container_memory_free: default_container_free(),
            max_parallel: default_parallel(),
        }
    }
}

impl EnvironmentSpec {
    fn problems(&self, out: &mut Vec<String>) {
        if let Some(st) = &self.status {
            if st.run.trim().is_empty() {
                out.push("environment.status: empty `run`".into());
            }
            if st
                .timeout_seconds
                .is_some_and(|t| !(1.0..=30.0).contains(&t))
            {
                out.push("environment.status.timeout_seconds: between 1 and 30".into());
            }
        }
        let mut actions: Vec<(String, &ActionSpec)> = self
            .actions
            .iter()
            .map(|(n, a)| (format!("environment.actions.{n}"), a))
            .collect();
        for (key, app) in &self.apps {
            for (mode, run) in &app.modes {
                if run.trim().is_empty() {
                    out.push(format!(
                        "environment.apps.{key}.modes.{mode}: empty command"
                    ));
                }
            }
            let down = app.down.as_deref().map(str::trim).unwrap_or("");
            if !app.modes.is_empty() && down.is_empty() {
                out.push(format!(
                    "environment.apps.{key}: `down` is required with `modes` (Stop runs it)"
                ));
            }
            if app.modes.is_empty() && app.down.is_some() {
                out.push(format!("environment.apps.{key}: `down` without `modes`"));
            }
            if app.modes.is_empty() && app.actions.is_empty() {
                out.push(format!(
                    "environment.apps.{key}: needs `modes` or `actions`"
                ));
            }
            actions.extend(
                app.actions
                    .iter()
                    .map(|(n, a)| (format!("environment.apps.{key}.actions.{n}"), a)),
            );
        }
        for (name, a) in actions {
            if a.run.trim().is_empty() {
                out.push(format!("{name}: empty `run`"));
            }
            if a.timeout_minutes
                .is_some_and(|t| !(1.0..=1440.0).contains(&t))
            {
                out.push(format!("{name}: timeout_minutes between 1 and 1440"));
            }
            if a.preview.is_some() && !a.confirm {
                out.push(format!(
                    "{name}: `preview` is shown in the confirmation; add `confirm: true`"
                ));
            }
            if a.preview.as_deref().is_some_and(|p| p.trim().is_empty()) {
                out.push(format!("{name}: empty `preview`"));
            }
            if let Some(k) = a.kind.as_deref().filter(|k| !ACTION_KINDS.contains(k)) {
                out.push(format!(
                    "{name}: kind `{k}` is not one of {}",
                    ACTION_KINDS.join(", ")
                ));
            }
        }
    }
}

impl ProjectConfig {
    /// Structural checks serde cannot express. Returns the problems, empty when valid.
    pub fn problems(&self) -> Vec<String> {
        let mut out = vec![];
        for (name, db) in &self.databases {
            let ok = |n: &str| {
                !n.is_empty()
                    && n.len() <= 64
                    && n.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.')
            };
            if !ok(name) {
                out.push(format!(
                    "databases.{name}: a database name has letters, digits and _"
                ));
            }
            for t in db.ignore_changes.iter().chain(&db.skip_data) {
                if !ok(t) {
                    out.push(format!("databases.{name}: invalid table name {t:?}"));
                }
            }
            for c in db.before_restore.iter().chain(&db.after_restore) {
                if c.trim().is_empty() {
                    out.push(format!("databases.{name}: an empty command"));
                }
            }
        }
        for (name, p) in &self.profiles {
            if p.commands.is_empty() && p.containers.is_empty() {
                out.push(format!("profile {name}: needs commands or containers"));
            }
            for c in &p.commands {
                if c.run.trim().is_empty() {
                    out.push(format!("profile {name}: a command has an empty `run`"));
                }
            }
        }
        for s in &self.services {
            let label = s.name.as_deref().unwrap_or(&s.target);
            if s.target.trim().is_empty() {
                out.push("services: a check has an empty `target`".into());
            }
            for p in &s.profiles {
                if !self.profiles.contains_key(p) {
                    out.push(format!("services: {label}: no profile `{p}` in this file"));
                }
            }
            let env = self.environment.as_ref();
            if s.component.is_some() && env.and_then(|e| e.status.as_ref()).is_none() {
                out.push(format!(
                    "services: {label}: `component` needs `environment.status`"
                ));
            }
            if let Some(app) = &s.app
                && !env.is_some_and(|e| e.apps.contains_key(app))
            {
                out.push(format!(
                    "services: {label}: no app `{app}` in `environment.apps`"
                ));
            }
        }
        if let Some(env) = &self.environment {
            env.problems(&mut out);
        }
        if let Some(c) = self
            .agents
            .as_ref()
            .and_then(|a| a.wait_for_capacity.as_ref())
        {
            if !(1.0..=100.0).contains(&c.cpu_below) {
                out.push("agents.wait_for_capacity.cpu_below: between 1 and 100".into());
            }
            if !matches!(c.memory.as_str(), "normal" | "warning") {
                out.push("agents.wait_for_capacity.memory: normal or warning".into());
            }
            if !(0.0..=1440.0).contains(&c.max_wait_minutes) {
                out.push("agents.wait_for_capacity.max_wait_minutes: between 0 and 1440".into());
            }
            if !(0.0..=90.0).contains(&c.container_memory_free) {
                out.push("agents.wait_for_capacity.container_memory_free: between 0 and 90".into());
            }
            if !(1.0..=20.0).contains(&c.max_parallel) {
                out.push("agents.wait_for_capacity.max_parallel: between 1 and 20".into());
            }
            for h in &c.heavy_commands {
                if h.command().trim().is_empty() {
                    out.push("agents.wait_for_capacity.heavy_commands: empty command".into());
                }
                if let HeavyCommand::Detailed(d) = h {
                    if let Some(Err(e)) = d.uses.as_ref().map(|u| crate::capacity::Uses::parse(u)) {
                        out.push(format!(
                            "agents.wait_for_capacity.heavy_commands `{}`: uses {e}",
                            d.command
                        ));
                    }
                    if d.weight.is_some_and(|w| !(0.1..=10.).contains(&w)) {
                        out.push(format!(
                            "agents.wait_for_capacity.heavy_commands `{}`: weight between 0.1 and 10",
                            d.command
                        ));
                    }
                }
            }
        }
        out
    }
}

// MARK: parsing

struct Line<'a> {
    number: usize,
    indent: usize,
    text: &'a str,
}

fn strip_comment(line: &str) -> &str {
    let mut quote: Option<char> = None;
    let mut previous = ' ';
    for (i, c) in line.char_indices() {
        match quote {
            Some(q) if c == q => quote = None,
            Some(_) => {}
            None if c == '"' || c == '\'' => quote = Some(c),
            None if c == '#' && (i == 0 || previous.is_whitespace()) => return &line[..i],
            None => {}
        }
        previous = c;
    }
    line
}

/// Parses the YAML subset into JSON. Errors name the line.
pub fn parse_yaml(text: &str) -> Result<Value, String> {
    let mut lines = vec![];
    for (i, raw) in text.lines().enumerate() {
        if raw.contains('\t') && raw.trim_start().len() != raw.trim_start_matches('\t').len() {
            return Err(format!(
                "line {}: tabs are not allowed for indentation",
                i + 1
            ));
        }
        let content = strip_comment(raw).trim_end();
        if content.trim().is_empty() {
            continue;
        }
        if content.trim() == "---" && lines.is_empty() {
            continue;
        }
        let indent = content.len() - content.trim_start().len();
        lines.push(Line {
            number: i + 1,
            indent,
            text: content.trim_start(),
        });
    }
    if lines.is_empty() {
        return Ok(Value::Object(Map::new()));
    }
    let mut pos = 0;
    let value = block(&lines, &mut pos, lines[0].indent)?;
    if pos < lines.len() {
        return Err(format!(
            "line {}: unexpected indentation",
            lines[pos].number
        ));
    }
    Ok(value)
}

fn block(lines: &[Line], pos: &mut usize, indent: usize) -> Result<Value, String> {
    if lines[*pos].text.starts_with("- ") || lines[*pos].text == "-" {
        sequence(lines, pos, indent)
    } else {
        mapping(lines, pos, indent)
    }
}

fn mapping(lines: &[Line], pos: &mut usize, indent: usize) -> Result<Value, String> {
    let mut map = Map::new();
    while *pos < lines.len() && lines[*pos].indent == indent {
        let line = &lines[*pos];
        if line.text.starts_with("- ") {
            return Err(format!(
                "line {}: a list item where a key was expected",
                line.number
            ));
        }
        let (key, rest) =
            split_key(line.text).ok_or(format!("line {}: expected `key: value`", line.number))?;
        if map.contains_key(&key) {
            return Err(format!("line {}: duplicate key `{key}`", line.number));
        }
        *pos += 1;
        let value = if rest.is_empty() {
            match lines.get(*pos) {
                Some(next) if next.indent > indent => block(lines, pos, next.indent)?,
                // A list may sit at the key's own indentation (common YAML style).
                Some(next) if next.indent == indent && next.text.starts_with('-') => {
                    sequence(lines, pos, indent)?
                }
                _ => Value::Null,
            }
        } else {
            scalar(rest, line.number)?
        };
        map.insert(key, value);
    }
    if *pos < lines.len() && lines[*pos].indent > indent {
        return Err(format!(
            "line {}: unexpected indentation",
            lines[*pos].number
        ));
    }
    Ok(Value::Object(map))
}

fn sequence(lines: &[Line], pos: &mut usize, indent: usize) -> Result<Value, String> {
    let mut items = vec![];
    while *pos < lines.len() && lines[*pos].indent == indent && lines[*pos].text.starts_with('-') {
        let line = &lines[*pos];
        let rest = line.text[1..].trim_start();
        *pos += 1;
        if rest.is_empty() {
            match lines.get(*pos) {
                Some(next) if next.indent > indent => items.push(block(lines, pos, next.indent)?),
                _ => items.push(Value::Null),
            }
            continue;
        }
        // `- key: value` starts a mapping whose keys line up after the dash.
        if split_key(rest).is_some()
            && !rest.starts_with('"')
            && !rest.starts_with('\'')
            && !rest.starts_with('[')
        {
            let inner = indent + (line.text.len() - rest.len());
            let mut synthetic = vec![Line {
                number: line.number,
                indent: inner,
                text: rest,
            }];
            while *pos < lines.len() && lines[*pos].indent > indent {
                let l = &lines[*pos];
                synthetic.push(Line {
                    number: l.number,
                    indent: l.indent,
                    text: l.text,
                });
                *pos += 1;
            }
            let mut inner_pos = 0;
            let value = mapping(&synthetic, &mut inner_pos, inner)?;
            if inner_pos < synthetic.len() {
                return Err(format!(
                    "line {}: unexpected indentation",
                    synthetic[inner_pos].number
                ));
            }
            items.push(value);
        } else {
            items.push(scalar(rest, line.number)?);
        }
    }
    Ok(Value::Array(items))
}

/// `key: rest` (rest may be empty). Keys may be quoted.
fn split_key(text: &str) -> Option<(String, &str)> {
    if let Some(q) = text.chars().next().filter(|c| *c == '"' || *c == '\'') {
        let end = text[1..].find(q)? + 1;
        let rest = text[end + 1..].trim_start();
        let rest = rest.strip_prefix(':')?;
        return Some((text[1..end].to_string(), rest.trim()));
    }
    let colon = text
        .find(": ")
        .or_else(|| text.ends_with(':').then(|| text.len() - 1))?;
    let key = text[..colon].trim();
    if key.is_empty() || key.contains(['[', ']', '{', '}']) {
        return None;
    }
    Some((key.to_string(), text[colon + 1..].trim()))
}

fn scalar(text: &str, line: usize) -> Result<Value, String> {
    let t = text.trim();
    if t.starts_with('[') {
        return flow_list(t, line);
    }
    if t.starts_with('{') {
        return Err(format!(
            "line {line}: `{{…}}` maps are not supported; use indented keys"
        ));
    }
    if t.starts_with(['&', '*', '!'])
        || t == "|"
        || t == ">"
        || t.starts_with("|-")
        || t.starts_with(">-")
    {
        return Err(format!(
            "line {line}: anchors, tags and multi-line strings are not supported"
        ));
    }
    if let Some(q) = t.chars().next().filter(|c| *c == '"' || *c == '\'') {
        if t.len() < 2 || !t.ends_with(q) {
            return Err(format!("line {line}: unterminated string"));
        }
        let inner = &t[1..t.len() - 1];
        return Ok(Value::String(if q == '"' {
            inner
                .replace("\\\"", "\"")
                .replace("\\\\", "\\")
                .replace("\\n", "\n")
        } else {
            inner.replace("''", "'")
        }));
    }
    Ok(match t {
        "true" | "True" | "yes" => Value::Bool(true),
        "false" | "False" | "no" => Value::Bool(false),
        "null" | "~" => Value::Null,
        _ => {
            if let Ok(i) = t.parse::<i64>() {
                Value::Number(i.into())
            } else if let Some(n) = t.parse::<f64>().ok().and_then(Number::from_f64) {
                Value::Number(n)
            } else {
                Value::String(t.to_string())
            }
        }
    })
}

fn flow_list(text: &str, line: usize) -> Result<Value, String> {
    let inner = text
        .strip_prefix('[')
        .and_then(|t| t.strip_suffix(']'))
        .ok_or(format!("line {line}: unterminated `[`"))?;
    let mut items = vec![];
    let mut current = String::new();
    let mut quote: Option<char> = None;
    for c in inner.chars() {
        match quote {
            Some(q) if c == q => {
                quote = None;
                current.push(c);
            }
            Some(_) => current.push(c),
            None if c == '"' || c == '\'' => {
                quote = Some(c);
                current.push(c);
            }
            None if c == ',' => {
                if !current.trim().is_empty() {
                    items.push(scalar(&current, line)?);
                }
                current.clear();
            }
            None if c == '[' || c == ']' => {
                return Err(format!("line {line}: nested lists are not supported"));
            }
            None => current.push(c),
        }
    }
    if !current.trim().is_empty() {
        items.push(scalar(&current, line)?);
    }
    Ok(Value::Array(items))
}

/// Parses and validates a config's text.
pub fn parse(text: &str) -> Result<ProjectConfig, String> {
    let value = parse_yaml(text)?;
    let config: ProjectConfig =
        serde_json::from_value(value).map_err(|e| format!("invalid .corescope.yml: {e}"))?;
    let problems = config.problems();
    if problems.is_empty() {
        Ok(config)
    } else {
        Err(problems.join("; "))
    }
}

// MARK: writing

fn quote(s: &str) -> String {
    let plain = !s.is_empty()
        && !s.starts_with([
            ' ', '-', '[', '{', '&', '*', '!', '|', '>', '"', '\'', '#', '@', '`',
        ])
        && !s.ends_with(' ')
        && !s.contains(": ")
        && !s.contains(" #")
        && !s.ends_with(':')
        && parse_yaml(&format!("k: {s}"))
            .ok()
            .and_then(|v| v["k"].as_str().map(|v| v == s))
            == Some(true);
    if plain {
        s.to_string()
    } else {
        format!(
            "\"{}\"",
            s.replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace('\n', "\\n")
        )
    }
}
fn emit(value: &Value, indent: usize, out: &mut String) {
    let pad = " ".repeat(indent);
    match value {
        Value::Object(map) => {
            for (k, v) in map {
                match v {
                    Value::Object(m) if !m.is_empty() => {
                        out.push_str(&format!("{pad}{}:\n", quote(k)));
                        emit(v, indent + 2, out);
                    }
                    Value::Array(a) if !a.is_empty() && a.iter().any(|x| x.is_object()) => {
                        out.push_str(&format!("{pad}{}:\n", quote(k)));
                        emit(v, indent + 2, out);
                    }
                    _ => out.push_str(&format!("{pad}{}: {}\n", quote(k), inline(v))),
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                if let Value::Object(map) = item {
                    let mut first = true;
                    for (k, v) in map {
                        let lead = if first {
                            format!("{pad}- ")
                        } else {
                            format!("{pad}  ")
                        };
                        first = false;
                        match v {
                            Value::Object(_) | Value::Array(_) if !inline_ok(v) => {
                                out.push_str(&format!("{lead}{}:\n", quote(k)));
                                emit(v, indent + 4, out);
                            }
                            _ => out.push_str(&format!("{lead}{}: {}\n", quote(k), inline(v))),
                        }
                    }
                } else {
                    out.push_str(&format!("{pad}- {}\n", inline(item)));
                }
            }
        }
        other => out.push_str(&format!("{pad}{}\n", inline(other))),
    }
}
fn inline_ok(v: &Value) -> bool {
    match v {
        Value::Array(a) => a.iter().all(|x| !x.is_object() && !x.is_array()),
        Value::Object(m) => m.is_empty(),
        _ => true,
    }
}
fn inline(v: &Value) -> String {
    match v {
        Value::String(s) => quote(s),
        Value::Array(a) => format!("[{}]", a.iter().map(inline).collect::<Vec<_>>().join(", ")),
        Value::Object(_) => "{}".into(),
        Value::Null => "null".into(),
        // Whole numbers without ".0": `cpu_below: 80`, not `80.0`.
        Value::Number(n) => match n.as_f64() {
            Some(f) if n.is_f64() && f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
            _ => n.to_string(),
        },
        other => other.to_string(),
    }
}

/// YAML for a config, with a header explaining the file.
pub fn to_yaml(config: &ProjectConfig) -> String {
    let mut out = String::from(
        "# CoreScope project file: profiles, ports, Services checks, logs and agent limits.\n\
         # https://github.com/Tiagospem/corescope#profiles-as-code\n",
    );
    // Top-level sections in reading order (serde_json maps are alphabetical).
    let value = serde_json::to_value(config).unwrap_or_default();
    for key in [
        "name",
        "profiles",
        "ports",
        "services",
        "environment",
        "logs",
        "agents",
    ] {
        if let Some(v) = value.get(key) {
            let mut one = Map::new();
            one.insert(key.to_string(), v.clone());
            if key != "name" {
                out.push('\n');
            }
            emit(&Value::Object(one), 0, &mut out);
        }
    }
    out
}

// MARK: discovery

/// The config file in a folder, if any.
pub fn file_in(folder: &Path) -> Option<PathBuf> {
    FILE_NAMES
        .iter()
        .map(|n| folder.join(n))
        .find(|p| p.is_file())
}

/// Project folders holding a config under the roots (or the roots themselves), at most a few
/// levels deep, skipping hidden folders and dependency/build output.
pub fn discover(roots: &[PathBuf]) -> Vec<PathBuf> {
    const SKIP: [&str; 8] = [
        "node_modules",
        "vendor",
        "target",
        "build",
        "dist",
        "Pods",
        "Library",
        "DerivedData",
    ];
    let mut found = vec![];
    let mut stack: Vec<(PathBuf, usize)> = roots.iter().map(|r| (r.clone(), 0)).collect();
    let mut visited = 0;
    while let Some((dir, depth)) = stack.pop() {
        visited += 1;
        if visited > 20_000 {
            break;
        }
        if file_in(&dir).is_some() && !found.contains(&dir) {
            found.push(dir.clone());
        }
        if depth >= 4 {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for e in entries.flatten() {
            if !e.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || SKIP.contains(&name.as_str()) || name.ends_with(".app") {
                continue;
            }
            stack.push((e.path(), depth + 1));
        }
    }
    found.sort();
    found
}

#[derive(Serialize)]
pub struct Found {
    pub folder: String,
    pub file: String,
    pub config: Option<ProjectConfig>,
    pub error: Option<String>,
}
pub fn load(folder: &Path) -> Option<Found> {
    let file = file_in(folder)?;
    let text = std::fs::read_to_string(&file);
    let (config, error) = match text.map_err(|e| e.to_string()).and_then(|t| parse(&t)) {
        Ok(c) => (Some(c), None),
        Err(e) => (None, Some(e)),
    };
    Some(Found {
        folder: folder.to_string_lossy().into(),
        file: file.to_string_lossy().into(),
        config,
        error,
    })
}

/// Writes (replacing) a project's config after validating it. Returns the file path.
pub fn write(folder: &Path, config: &ProjectConfig) -> Result<PathBuf, String> {
    if !folder.is_dir() {
        return Err("folder must be an existing directory".into());
    }
    let problems = config.problems();
    if !problems.is_empty() {
        return Err(problems.join("; "));
    }
    let text = to_yaml(config);
    // Round trip: what we write must read back as the same config.
    if parse(&text).as_ref() != Ok(config) {
        return Err("could not write this config faithfully".into());
    }
    let file = file_in(folder).unwrap_or_else(|| folder.join(FILE_NAMES[0]));
    std::fs::write(&file, text).map_err(|e| e.to_string())?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
# Revamp
name: Revamp
profiles:
  dev:
    commands:
      - name: web
        run: php artisan serve --port 8000   # comment after a value
      - run: npm run dev
    containers: [mysql, "redis"]
  qa:
    commands:
    - name: env
      run: make test-env-up
      stop: make test-env-down
ports:
  web: 8000
  vite: 5173
services:
  - name: API
    target: "http://localhost:8000/up"
  - target: 3306
logs:
  - storage/logs/*.log
agents:
  wait_for_capacity:
    cpu_below: 65
    heavy_commands: ["php artisan test", 'npm run build']
"#;

    #[test]
    fn heavy_commands_say_what_they_use() {
        let c = parse("agents:\n  wait_for_capacity:\n    heavy_commands:\n      - npm run build\n      - command: php artisan test\n        uses: [cpu, memory, containers]\n        weight: 3\n      - command: go test\n        uses: [cpu, memory]\n").unwrap();
        let w = c.agents.unwrap().wait_for_capacity.unwrap();
        let h = &w.heavy_commands;
        assert_eq!(h[0], "npm run build");
        assert_eq!(h[0].uses(), crate::capacity::Uses::MAC);
        assert_eq!(
            (h[1].command(), h[1].uses(), h[1].weight()),
            ("php artisan test", crate::capacity::Uses::ALL, 3.)
        );
        assert_eq!(
            (h[2].uses(), h[2].weight()),
            (crate::capacity::Uses::MAC, 1.)
        );
        assert!(parse("agents:\n  wait_for_capacity:\n    heavy_commands:\n      - command: x\n        uses: [gpu]\n").unwrap_err().contains("gpu"));
        assert!(parse("agents:\n  wait_for_capacity:\n    heavy_commands:\n      - command: x\n        weight: 50\n").is_err());
        assert!(parse("agents:\n  wait_for_capacity:\n    heavy_commands:\n      - command: x\n        other: 1\n").is_err());
        let c = parse("agents:\n  wait_for_capacity:\n    heavy_commands:\n      - command: php artisan test\n        uses: [cpu, memory]\n        containers: [mysql, redis]\n").unwrap();
        let h = &c.agents.unwrap().wait_for_capacity.unwrap().heavy_commands[0];
        assert_eq!(
            (h.uses(), h.containers()),
            (
                crate::capacity::Uses::ALL,
                &["mysql".to_string(), "redis".to_string()][..]
            )
        );
    }

    #[test]
    fn databases_section() {
        let c = parse("databases:\n  eco_revamp:\n    server: leilotech-mysql-1\n    ignore_changes: [audits, jobs]\n    skip_data: [audits]\n    before_restore: bin/eco optional revamp horizon off\n    after_restore:\n      - bin/eco migrate revamp\n      - bin/eco optional revamp horizon on\n  other:\n    server: 5432\n").unwrap();
        let db = &c.databases["eco_revamp"];
        assert_eq!(db.server.as_deref(), Some("leilotech-mysql-1"));
        assert_eq!(db.ignore_changes, ["audits", "jobs"]);
        assert_eq!(db.before_restore, ["bin/eco optional revamp horizon off"]);
        assert_eq!(db.after_restore.len(), 2);
        assert_eq!(c.databases["other"].server.as_deref(), Some("5432"));
        assert!(parse("databases:\n  bad name:\n    skip_data: [a]\n").is_err());
        assert!(parse("databases:\n  x:\n    unknown: 1\n").is_err());
    }
    #[test]
    fn parses_the_documented_shape() {
        let c = parse(SAMPLE).unwrap();
        assert_eq!(c.name.as_deref(), Some("Revamp"));
        assert_eq!(
            c.profiles["dev"].commands[0].run,
            "php artisan serve --port 8000"
        );
        assert_eq!(c.profiles["dev"].commands[1].name, None);
        assert_eq!(c.profiles["dev"].containers, ["mysql", "redis"]);
        assert_eq!(
            c.profiles["qa"].commands[0].stop.as_deref(),
            Some("make test-env-down")
        );
        assert_eq!(c.ports["vite"], 5173);
        assert_eq!(c.services[1].target, "3306");
        let w = c.agents.unwrap().wait_for_capacity.unwrap();
        assert_eq!(
            (w.cpu_below, w.memory.as_str(), w.max_wait_minutes),
            (65., "normal", 30.)
        );
        assert_eq!(w.heavy_commands, ["php artisan test", "npm run build"]);
    }

    #[test]
    fn rejects_what_it_does_not_understand() {
        assert!(
            parse("profiles:\n  dev:\n    commands:\n      - run: |\n")
                .unwrap_err()
                .contains("line 4")
        );
        assert!(
            parse("name: a\nname: b\n")
                .unwrap_err()
                .contains("duplicate")
        );
        assert!(parse("unknown: 1\n").unwrap_err().contains("unknown field"));
        assert!(parse("profiles:\n  dev: {}\n").is_err());
        assert!(
            parse("profiles:\n  empty:\n    containers: []\n")
                .unwrap_err()
                .contains("needs commands")
        );
        assert!(parse("agents:\n  wait_for_capacity:\n    memory: critical\n").is_err());
        assert!(parse("name: x\n   bad: indent\n").is_err());
    }

    #[test]
    fn writes_what_it_reads() {
        let c = parse(SAMPLE).unwrap();
        let text = to_yaml(&c);
        assert_eq!(parse(&text).unwrap(), c, "{text}");
        let tricky = ProjectConfig {
            profiles: BTreeMap::from([(
                "qa: build".into(),
                ProfileSpec {
                    commands: vec![CommandSpec {
                        name: Some("- dash".into()),
                        run: "echo \"a: b\" # not a comment".into(),
                        stop: Some("true".into()),
                    }],
                    containers: vec![],
                },
            )]),
            ..Default::default()
        };
        assert_eq!(parse(&to_yaml(&tricky)).unwrap(), tricky);
    }

    const ECOSYSTEM: &str = r#"
name: Ecosystem
profiles:
  legacy:
    commands:
      - run: npm run dev
services:
  - name: Arena
    target: https://arena.test/up
    app: arena
  - name: Memory MCP
    target: 8888
    component: hindsight-mcp
  - target: 3306
    profiles: [legacy]
environment:
  status:
    run: bin/eco status --json
    timeout_seconds: 4
  apps:
    arena:
      title: Arena
      modes:
        build: bin/eco up arena --web build
        dev: bin/eco up arena --web dev
      down: bin/eco down arena
      containers: [arena-go]
      actions:
        migrate:
          run: bin/eco migrate arena
          heavy: true
    memory:
      title: Agents' memory
      actions:
        backup:
          run: bin/eco memory backup
          timeout_minutes: 30
          kind: data
        restore:
          run: bin/eco memory restore
          preview: bin/eco memory restore --plan
          confirm: true
  actions:
    init:
      run: bin/eco init
"#;

    #[test]
    fn reads_the_environment() {
        let c = parse(ECOSYSTEM).unwrap();
        let env = c.environment.as_ref().unwrap();
        let st = env.status.as_ref().unwrap();
        assert_eq!(
            (st.run.as_str(), st.timeout_seconds),
            ("bin/eco status --json", Some(4.))
        );
        let arena = &env.apps["arena"];
        assert_eq!(arena.title.as_deref(), Some("Arena"));
        assert_eq!(arena.modes["dev"], "bin/eco up arena --web dev");
        assert_eq!(arena.down.as_deref(), Some("bin/eco down arena"));
        assert_eq!(arena.containers, ["arena-go"]);
        assert!(arena.actions["migrate"].heavy);
        let memory = &env.apps["memory"];
        assert!(memory.modes.is_empty() && memory.actions["restore"].confirm);
        assert_eq!(memory.actions["backup"].kind.as_deref(), Some("data"));
        assert_eq!(env.actions["init"].run, "bin/eco init");
        assert_eq!(c.services[0].app.as_deref(), Some("arena"));
        assert_eq!(c.services[1].component.as_deref(), Some("hindsight-mcp"));
        assert_eq!(c.services[2].profiles, ["legacy"]);
        assert_eq!(parse(&to_yaml(&c)).unwrap(), c, "{}", to_yaml(&c));
        // Files without it read and write as before.
        let old = parse(SAMPLE).unwrap();
        assert!(old.environment.is_none());
        let text = to_yaml(&old);
        for key in ["environment", "component", "app:", "modes"] {
            assert!(!text.contains(key), "{key} in {text}");
        }
    }

    #[test]
    fn rejects_inconsistent_environments() {
        let env = |body: &str| parse(&format!("environment:\n{body}"));
        assert!(
            env("  apps:\n    a:\n      modes:\n        dev: x\n")
                .unwrap_err()
                .contains("`down` is required")
        );
        assert!(
            env("  apps:\n    a:\n      title: A\n")
                .unwrap_err()
                .contains("needs `modes` or `actions`")
        );
        assert!(
            env("  apps:\n    a:\n      down: x\n      actions:\n        b:\n          run: y\n")
                .unwrap_err()
                .contains("`down` without `modes`")
        );
        assert!(
            env("  actions:\n    r:\n      run: x\n      preview: y\n")
                .unwrap_err()
                .contains("confirm: true")
        );
        assert!(
            env("  actions:\n    r:\n      run: x\n      kind: party\n")
                .unwrap_err()
                .contains("environment.actions.r: kind `party`")
        );
        assert!(env("  actions:\n    r:\n      run: x\n      timeout_minutes: 0\n").is_err());
        assert!(env("  status:\n    run: s\n    timeout_seconds: 60\n").is_err());
        assert!(env("  actions:\n    r:\n      run: x\n      group: g\n").is_err());
        assert!(
            parse("services:\n  - target: 80\n    component: db\n")
                .unwrap_err()
                .contains("needs `environment.status`")
        );
        assert!(
            parse("services:\n  - target: 80\n    app: nope\n")
                .unwrap_err()
                .contains("no app `nope`")
        );
        assert!(
            parse("services:\n  - target: 80\n    profiles: [nope]\n")
                .unwrap_err()
                .contains("no profile `nope`")
        );
        // The branch's earlier shapes are gone.
        assert!(parse("status:\n  run: x\n").is_err());
        assert!(
            parse("profiles:\n  x:\n    lifecycle: controller\n    commands:\n      - run: a\n")
                .is_err()
        );
    }

    #[test]
    fn finds_configs_under_roots() {
        let root = std::env::temp_dir().join(format!("corescope-config-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["a", "b/c", "node_modules/x", ".hidden"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
            std::fs::write(root.join(dir).join(".corescope.yml"), "name: x\n").unwrap();
        }
        let found = discover(std::slice::from_ref(&root));
        assert_eq!(found, [root.join("a"), root.join("b/c")]);
        assert!(load(&root.join("a")).unwrap().config.is_some());
        std::fs::remove_dir_all(root).unwrap();
    }
}
