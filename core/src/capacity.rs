//! Whether the Mac has room for heavy work right now, and which commands count as heavy. Agents
//! wait on this (a Claude Code hook running `corescope gate`, or the MCP tool `wait_for_capacity`)
//! before builds and test suites, so a busy machine is not pushed into hours-long sessions.
use crate::projectconfig::CapacitySpec;
use serde::Serialize;

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Reading {
    /// Busy CPU across all cores, percent.
    pub cpu: f64,
    /// "normal", "warning" or "critical"; None when unknown (treated as normal).
    pub memory: Option<String>,
}

fn rank(level: &str) -> u8 {
    match level {
        "normal" => 0,
        "warning" => 1,
        _ => 2,
    }
}

/// Empty when there is room; otherwise why not, in plain words.
pub fn blockers(spec: &CapacitySpec, r: &Reading) -> Vec<String> {
    let mut out = vec![];
    if r.cpu >= spec.cpu_below {
        out.push(format!(
            "CPU at {:.0}% (limit {:.0}%)",
            r.cpu, spec.cpu_below
        ));
    }
    if let Some(m) = &r.memory
        && rank(m) > rank(&spec.memory)
    {
        out.push(format!("memory pressure {m} (limit {})", spec.memory));
    }
    out
}

/// CPU from a snapshot (sampled twice, so it is a real average) and the kernel's memory pressure.
pub fn reading(snapshot: &crate::Snapshot) -> Reading {
    Reading {
        cpu: snapshot.cpu.value.unwrap_or(0.),
        memory: crate::os::pressure_level().map(String::from),
    }
}

/// Each step of a shell command line (`a && b; c | d`), without leading `VAR=value` assignments.
pub fn steps(command: &str) -> Vec<String> {
    let mut out = vec![];
    for part in command.split(['\n', ';', '|', '&']) {
        let mut words = part.split_whitespace().peekable();
        while words
            .peek()
            .is_some_and(|w| w.contains('=') && !w.starts_with('=') && !w.starts_with('-'))
        {
            words.next();
        }
        let step = words.collect::<Vec<_>>().join(" ");
        if !step.is_empty() {
            out.push(step);
        }
    }
    out
}

/// The heavy prefix a command runs, if any (`npm run build` matches `npm run build -- --watch`;
/// `cd web && npm test` matches `npm test`).
pub fn heavy<'a>(command: &str, prefixes: &'a [String]) -> Option<&'a str> {
    let steps = steps(command);
    prefixes.iter().map(String::as_str).find(|p| {
        let p = p.trim();
        !p.is_empty()
            && steps
                .iter()
                .any(|s| s == p || s.starts_with(&format!("{p} ")))
    })
}

/// Prefixes used when a project enables waiting but lists no commands: common builds, test
/// suites and container builds across stacks.
pub const DEFAULT_HEAVY: [&str; 22] = [
    "npm run build",
    "npm test",
    "npm run test",
    "pnpm build",
    "pnpm test",
    "yarn build",
    "yarn test",
    "npx playwright test",
    "cargo build",
    "cargo test",
    "go build",
    "go test",
    "php artisan test",
    "vendor/bin/phpunit",
    "vendor/bin/pest",
    "./vendor/bin/pest",
    "composer install",
    "pytest",
    "docker build",
    "docker compose build",
    "xcodebuild",
    "swift build",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heavy_commands_are_found_in_chains() {
        let p: Vec<String> = ["npm run build", "php artisan test"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(
            heavy("cd web && npm run build -- --mode qa", &p),
            Some("npm run build")
        );
        assert_eq!(
            heavy("APP_ENV=testing php artisan test --parallel", &p),
            Some("php artisan test")
        );
        assert_eq!(
            heavy("npm run build-storybook", &p),
            None,
            "a longer script name is another command"
        );
        assert_eq!(heavy("git status; ls -la | grep x", &p), None);
        assert_eq!(
            steps("A=1 B=2 make test && echo ok"),
            ["make test", "echo ok"]
        );
    }

    #[test]
    fn blocks_on_cpu_and_memory() {
        let spec = CapacitySpec {
            cpu_below: 70.,
            memory: "normal".into(),
            ..Default::default()
        };
        assert!(
            blockers(
                &spec,
                &Reading {
                    cpu: 40.,
                    memory: Some("normal".into())
                }
            )
            .is_empty()
        );
        assert_eq!(
            blockers(
                &spec,
                &Reading {
                    cpu: 85.,
                    memory: None
                }
            )
            .len(),
            1
        );
        let both = blockers(
            &spec,
            &Reading {
                cpu: 90.,
                memory: Some("warning".into()),
            },
        );
        assert_eq!(both.len(), 2, "{both:?}");
        let relaxed = CapacitySpec {
            memory: "warning".into(),
            ..spec
        };
        assert!(
            blockers(
                &relaxed,
                &Reading {
                    cpu: 10.,
                    memory: Some("warning".into())
                }
            )
            .is_empty()
        );
        assert!(
            !blockers(
                &relaxed,
                &Reading {
                    cpu: 10.,
                    memory: Some("critical".into())
                }
            )
            .is_empty()
        );
    }
}
