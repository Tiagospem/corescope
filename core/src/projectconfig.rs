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
    /// Log files or globs relative to the project (`storage/logs/*.log`), added to Logs.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub logs: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agents: Option<AgentsSpec>,
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
    /// Command prefixes that count as heavy (builds, test suites, `docker compose up`).
    #[serde(default)]
    pub heavy_commands: Vec<String>,
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
        }
    }
}

impl ProjectConfig {
    /// Structural checks serde cannot express. Returns the problems, empty when valid.
    pub fn problems(&self) -> Vec<String> {
        let mut out = vec![];
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
            if s.target.trim().is_empty() {
                out.push("services: a check has an empty `target`".into());
            }
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
    for key in ["name", "profiles", "ports", "services", "logs", "agents"] {
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
