# Threat model: CoreScope

## What this project does and where untrusted input enters

CoreScope is a menu bar system monitor for developers on macOS 14+ (Apple Silicon). It shows CPU, memory, disks, network and temperatures, the processes that use them, the TCP ports they listen on, Docker-compatible containers, and the sessions of coding agents (Claude Code, Codex). From the UI, after a confirmation, the user can terminate one of their own processes or stop/restart a container.

It is a local, single-user app. It runs as the logged-in user, with no privileged helper, no setuid and no network listener. It sends no telemetry and never reads credentials, process arguments or environment variables. Its only outbound network effect is opt-in and indirect: when "live Codex limits" is on, it starts the user's own `codex app-server` over stdio, and Codex contacts OpenAI with its own login.

There are two parts:

- `core/` (Rust, with a C adapter in `core/src/macos.c`) samples the system and is linked into the app as a static library. The app talks to it only through the `cs_*` functions in `core/src/lib.rs`, which take and return NUL-terminated JSON strings.
- `native/` (SwiftUI/AppKit) is the app: UI, confirmations, notifications, the agent pages and the opt-in integrations.

The user and the app's own code are trusted. Treat the following as attacker-controlled, because other software, other users or downloaded content can shape them:

- **Process metadata of every process on the machine**, including other users' and root's: names (`p_comm`), executable paths, working directories, parent PIDs, start times, and listening sockets. Any program can choose its own name and path, and a PID can be reused between sampling and acting.
- **Responses from Docker-compatible engines** over their Unix sockets (`core/src/containers.rs`): the HTTP framing (status line, headers, chunked encoding) and the JSON of container lists and stats. Container names, labels, images and published ports come from images and compose files pulled from the Internet. `DOCKER_HOST` (only `unix://` is honoured) can point at any socket.
- **Coding-agent files** read by the app: `~/.claude/projects/**/*.jsonl`, `~/.claude/sessions/<pid>.json`, `~/.codex/sessions/**/*.jsonl` and Codex's SQLite thread databases. Their content includes text from web pages, tool output and repositories the agents worked on.
- **The output of `codex app-server`** (JSON-RPC lines on stdout) when live Codex limits are on.
- **The rate-limit file the status line script writes**, and `~/.claude/settings.json`, which CoreScope edits only when the user turns on Claude limits (it keeps every other key, backs the file up first, and restores the previous `statusLine` when turned off).

An attacker who already runs arbitrary code as the logged-in user can do everything CoreScope can, so that is not a meaningful threat (see SECURITY.md). The interesting attacks are the ones where data from the sources above makes CoreScope act on something it should not, corrupt memory, or reveal what it promises not to collect.

## Components that matter most / least

Most important, in this order:

1. **Process termination.** `signal_process` and `blocked` in `core/src/lib.rs`, `cs_signal`, and `os_process`/`os_signal` in `core/src/macos.c`. The rules: never signal PID ≤ 1, another user's process, a process flagged as system, CoreScope itself or any of its ancestors, the named essential services, or anything under `/System/` or `/usr/libexec/`; and revalidate the target (PID, start time, executable path, UID) twice right before `kill(2)`, so a reused PID or a swapped executable is refused. Callers in `native/Models.swift` (`requestKill`, `signal`), `native/Processes.swift`, `native/Design.swift` and the notification action in `native/Notifier.swift` must only reach `cs_signal` after the user confirmed that exact target (SIGKILL always needs a confirmation). Any way to make CoreScope signal a process outside these rules, or the wrong process, is the top concern.
2. **The C adapter**, `core/src/macos.c`/`macos.h`: fixed-size buffers for names (64), paths (4096), volume and disk names, listening ports (`os_ports`, capped by the caller), working directories, per-CPU ticks and device-tree reads. Memory-safety bugs here are reachable from process metadata other programs control.
3. **The container client**, `core/src/containers.rs`: socket discovery (`sockets`), the hand-written HTTP/1.1 client (`request`, `parse_response`, `dechunk`, `MAX_RESPONSE`), JSON parsing of lists and stats, and `act`: an id must be 12–64 hex characters, the action must be `stop` or `restart`, exactly one container across all engines must match, and the lookup deliberately avoids `/containers/{id}/json` because that exposes `Config.Env`.
4. **The FFI boundary**, `cs_snapshot`, `cs_history`, `cs_containers`, `cs_container_action`, `cs_is_same`, `cs_free` in `core/src/lib.rs`: panics must not cross into Swift (`catch_unwind` in `response`), strings returned must be freed exactly once.
5. **The opt-in history**, `core/src/history.rs` and the raw libsqlite3 binding in `core/src/sqlite.rs`: SQL is fixed and parameters are bound, the store keeps process names, executable paths, working directories and origins (never arguments or environment), and `delete` removes exactly the database and its `-wal`/`-shm`/`-journal` files.
6. **Swift code that parses untrusted files or edits the user's settings:** `native/TokenUsage.swift` and `native/Agents.swift` (JSONL parsing, size and line limits), `native/CodexThreads.swift` (read-only SQLite), `native/CodexLimits.swift` (spawning `codex app-server` with API-key variables removed from its environment), `native/ClaudeLimits.swift` and `OrderedJSON`/`ClaudeStatusLine` in `native/NativeLogic.swift` (editing `~/.claude/settings.json`, shell-quoting the script path when chaining the user's own status line command, file modes 0600/0700).

Less important: the rest of `native/` (layout, design, localization, the global hotkey, launch at login, demo mode), `core/examples/`, `scripts/` (build, packaging, release notes), `docs/`, `.github/`, `tests/` and the generated icons and screenshots.

Known issues that are already tracked: `docs/security-audit/ISSUES.md` (in Portuguese) lists findings from an earlier audit, such as the "force quit" button in the survivors banner sending SIGKILL without its own confirmation. Report them again only if you find a new way to reach them or a worse impact.

## How to exercise it

The image is Linux, and CoreScope only runs on macOS. On Linux, `core/build.rs` replaces `core/src/macos.c` with stubs generated from `core/src/macos.h` that report every OS query as unavailable, so the portable Rust builds and runs, and the tests that read the macOS process table are ignored there. The C adapter and the Swift app are source only: review them statically.

- `/src/core` is built in the dev profile (debug assertions and overflow checks on); `cargo test` runs the unit tests in `core/src/lib.rs`, `containers.rs` and `history.rs`. Every crate is fetched and `CARGO_NET_OFFLINE=true` is set.
- Good targets for new tests or fuzzing harnesses: `containers::parse_response`, `dechunk`, `parse_list`, `parse_stats`, `published`, `valid_id`, `lookup_path`; `history::series`/`top`/`info` against a crafted SQLite file; `cs_history` and `cs_snapshot` with arbitrary JSON; `host`, `tags` and `orphan_reason` with hostile names and paths; `blocked` with hand-built `RawProcess` values.
- A fake Docker engine is easy to stand up for `containers::request`: a Unix socket server (for example with `python3` or `socat` if added) that returns crafted HTTP, with `DOCKER_HOST=unix:///path/to.sock`.
- On a Mac, `./scripts/test.sh` runs everything, including the Swift logic tests in `tests/native-tests.swift`.

## How you rate severity

- **Critical:** CoreScope signals a process its rules forbid (another user's, a protected or essential one, its own ancestor) or the wrong process after a PID reuse, without the user confirming that process; code execution or memory corruption in CoreScope from attacker-controlled input (process metadata, engine responses, agent files); CoreScope sending data over the network or reading credentials.
- **High:** a container action reaching a different container or an action other than stop/restart; a memory-safety bug in the C adapter or the `unsafe` FFI code with a plausible trigger but no demonstrated exploit; writing or deleting files outside the paths CoreScope owns (`~/Library/Application Support/CoreScope/`, and `~/.claude/settings.json` while Claude limits are being turned on or off); shell injection through the status line command that CoreScope builds.
- **Medium:** collecting or storing process arguments, environment variables or container `Config.Env`, or other local data the README does not document; a destructive action that skips its confirmation in the UI; crash or hang of the app from crafted local data.
- **Low:** resource use from unbounded parsing (large JSONL, large engine responses) without a crash; information shown in the UI that is only visible to the same user anyway.
- Anything that requires the attacker to already run code as the same user, or to be root, is out of scope unless it crosses into one of the categories above through CoreScope's own actions.

Reports are most useful with a reproducer that runs in this image (a Rust test is ideal), the file and line, and a minimal patch in the style of the surrounding code.

## Anything to leave alone

- The absence of Apple notarization and ad-hoc signing (documented in the README).
- The Linux stubs generated by `core/build.rs`: they exist only so this image can build, and never ship.
- Ignored macOS-only tests failing or being skipped on Linux.
- User-visible strings being in Portuguese with English translations in `native/Localization.swift`.

## Coming next (not on main yet)

A branch in progress adds surfaces that will need the same scrutiny once merged; this section will be expanded then:

- a `corescope` command-line tool and an opt-in MCP server over stdio, through which coding agents can list processes and ports and stop only the processes their own session started;
- an opt-in local control socket (a Unix socket with mode 0600 that accepts only peers of the same user);
- on-demand cleanup that moves selected developer folders (caches, build outputs) to the Trash after validating their paths;
- profiles that run commands the user configured;
- read-only views of local MySQL, PostgreSQL and Redis servers (no stored passwords) and of remote machines through the user's own `ssh` in BatchMode.
