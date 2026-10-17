# Changelog

All notable changes to CoreScope are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

Pull requests add their user-visible changes under **Unreleased**. When a version is
tagged, those entries move under its heading; the release workflow publishes that
section as the GitHub release notes.

## [Unreleased]

## [0.5.1] - 2026-10-17

### Added
- The sidebar shows the version (build on hover); About reads it from the bundle too.

### Fixed
- macOS 27: ⌥⌘K and `corescope://palette` opened the menu bar popover only when CoreScope was
  already active — activation closed it at once, and the field lost focus; a popover hidden
  without closing was reused instead of replaced.
- Running a quick action now closes the menu bar popover, and closing it keeps SwiftUI's
  open/closed state in step, so the next click or link opens it instead of "closing" it.

## [0.5.0] - 2026-10-17

### Added
- **Profiles as code**: a committed `.corescope.yml` (profiles with commands, stop commands and
  containers; preferred ports; Services checks; log globs; agent capacity rules) is found
  automatically and shown read-only in Profiles and Services. `corescope config` validates it;
  MCP `read_project_config` / `write_project_config` let agents read and write it.
- **Logs page**: project log files (conventional folders, `*.log`, `.corescope.yml` globs),
  profile command output and container logs, by project; live tail, search, and recent errors by
  declared level or generic markers, with stack traces and repeats counted. `corescope logs` and
  MCP `recent_errors`, `search_logs`, `tail_log`, `list_log_sources`.
- **Containers**: grouped by compose project with start-all/stop-all, start for stopped
  containers, restart policy, image age and a Volumes card (size, use, unused flagged).
  `corescope containers` and MCP `list_containers`, `container_logs`, `container_action`
  (stopping one a started profile uses needs `force`).
- **Agents wait for capacity**: projects opt in with `agents.wait_for_capacity` in
  `.corescope.yml`; an optional Claude Code hook (`corescope gate`) holds heavy commands until CPU
  and memory pressure settle, other agents get MCP `wait_for_capacity` / `system_capacity` and
  server instructions, the Agents page shows who is waiting, and `corescope wait` does it for
  scripts. **Economy mode**: on battery, busy agent-started processes run at background priority.
- **Worktrees and agent conflicts**: Cleanup lists git worktrees agents left (Claude Code, Codex,
  Conductor, Cursor or any) with agent, branch and merged state; clean, unused ones go to the Trash
  and are pruned from git (branches stay), dirty or occupied ones are locked. The Agents page
  flags sessions sharing one working tree. `corescope worktrees` and MCP `list_worktrees`;
  conflicts in `corescope agents` / `list_agent_sessions`.
- **Ports page**: what listens beyond localhost (processes and published container ports) ranked
  by risk with how to bind it to 127.0.0.1; projects' preferred ports from `.corescope.yml`
  (free, ours or taken, with a free alternative); free port finder; every listening server.
  `corescope exposure`, `corescope ports --check`, MCP `exposure_report` and `port_conflicts`.
- **Machines**: distribution, swap, every disk, top processes by memory, failed systemd units and
  the container list; alerts (disk over 90%, sustained load, failed units, stopped or unhealthy
  containers) with optional notifications; recipes — read-only commands run on demand, built-in
  or your own — also over MCP (`list_recipes`, `run_recipe`, by name only).
- **Services history**: a week of 5-minute buckets per check with uptime over 24 h / 7 days,
  incidents and the day's latency; included in MCP `list_services`.
- **CoreScope's own cost**: footer readout of the app's CPU and memory with a breakdown in
  Settings — app, helpers (MCP servers, gate hook, status line), processes it started, and each
  background feature with cadence and the CPU it measured in its own threads (5-minute average,
  startup excluded), with switches; a warning past 2 % of a core (6 % with the window open) or
  500 MB. MCP `corescope_cost`;
  `set_setting` also takes `collector_interval_seconds` and `floating_panel`.

- **What happened at 2:05 pm?**: History card, ⌥⌘K, `corescope://happened?at=…`, `corescope happened`
  and MCP `what_happened` — CPU and process power around a moment against the hour before,
  memory, swap growth, pressure, thermal state, disk writes and who dominated CPU, memory and
  power. History now records total process power and a top 10 by power (schema 2, migrated in
  place).
- **What grew today**: Storage card measuring the usual space-hungry folders (caches, Xcode,
  simulators, container VMs, package stores, models, Downloads, Trash, agent data) at most every
  6 hours and on demand, with today's growth and free space; `corescope disk-growth`, MCP
  `disk_growth`.
- **Quick actions in ⌥⌘K**: start/stop profiles, check services, open projects and pages, pause
  sampling, jump to a moment in History. **Menu bar** profile switcher and Services status dots.
- **`corescope://` links** for Shortcuts, Raycast and scripts: open a page, start/stop/toggle a
  profile (file profiles ask first), port lookup, check services, what happened, palette.
- **Universal build**: releases run natively on Apple Silicon and Intel Macs
  (`CoreScope-<version>-macos-universal.dmg`); `UNIVERSAL=1 ./scripts/build.sh` builds both
  slices of the app and the bundled `corescope`, and packaging refuses a release missing one.
### Changed
- `.corescope.yml` discovery walks folders every 10 minutes (and when roots change) and only
  re-reads known files in between, instead of a full walk plus process list every minute.
- Settings no longer rebuilds its whole form on every sample (about 12 % → 4.5 % of a core
  while it is open).
- The collector no longer allocates strings to match app bundles and runtimes for every process
  on every sample.

## [0.4.0] - 2026-10-17

### Added
- **`corescope` command-line tool** bundled in the app (*Settings › Command line* links it into
  `~/.local/bin`): `ports`, `free-port`, `kill-port`, `agents`, `orphans`, `top`, `kill
  [--tree]`, all with `--json`. Same safe termination as the app; refuses without `--yes` when
  there is no terminal to confirm in, and never signals its own ancestors.
- **Local MCP server (opt-in)**: `corescope mcp`, registered with Claude Code and/or Codex from
  *Settings › MCP server for agents*. Tools for ports, a free port, top processes, a system
  summary, agent sessions, orphans and the session's own processes; `stop_port`/`stop_process`
  stop only what the calling agent session started (children, or servers it detached inside its
  folder when no other session could claim them).
- **Cleanup page**: reclaimable `node_modules`, Rust `target/`, Xcode DerivedData/device
  support/Simulator caches, package-manager caches and unused Docker images/build cache, with
  sizes and age. Folders go to the Trash after confirmation; items in use by a process are locked
  and every folder is re-verified right before it moves. Scans run only on demand; the last
  result is cached and flagged when it may be out of date. Also `corescope space` and the MCP tool
  `list_dev_space` (read-only).
- **Stuck agent detection**: busy Claude Code sessions and Codex threads with no transcript
  writes for N minutes (default 10) show *Looks stuck* (idle command, possibly waiting for input,
  or nothing running) or *Long command* (a command of this turn using CPU) on the Agents page;
  optional notification that opens the session in Claude or Codex.
- **Services page**: HTTP and TCP health checks for local or remote endpoints every 30 s, with
  latency history, an Overview card, one-click suggestions from open ports and optional
  down/recovered notifications.
- **Profiles page**: per-project environments — commands run in the project folder through the
  login shell (logged to ~/Library/Application Support/CoreScope/logs) plus containers to start;
  Stop ends only the process trees CoreScope started and stops only containers a profile started
  that no other started profile still uses (shared databases stay up until the last one stops).
  Commands run in their own session, so what they leave running (detached servers) stays tracked
  across shell exits and app restarts; setup commands that exit count as done on exit 0, and an
  optional *on stop* command undoes them.
- **Databases page**: local MySQL/MariaDB, PostgreSQL and Redis (processes and containers) with
  version, uptime, size per database, connections, slow-query counters and queries running over
  5 s, over each wire protocol, read-only and time-capped. Never uses or reads passwords; servers
  that need one are shown as such. Also `corescope db` and the MCP tool `list_databases`.
- **Machines page**: remote servers over the user's own ssh (BatchMode, no prompts, unknown host
  keys fail): OS, uptime, load per core, memory, disk, top processes and containers, from a fixed
  read-only script; aliases suggested from ~/.ssh/config.
- **Energy page**: battery state, watts per process (rusage v6 energy) and per agent session
  with what it started; optional alert when an agent drains the battery. Also `corescope power`,
  `top --energy` and the MCP tool `power_usage`.
- **MCP drives the app**: through a private local socket (0600, same user, can be turned off),
  agents can list/create/start/stop profiles and read their logs, manage Services checks and SSH
  machines, scan and clean dev space, read and change notification settings and see stuck
  sessions. Destructive tools carry MCP annotations so hosts ask first.

### Changed
- The Rust core also builds on Linux, with stubs in place of the macOS adapter, for the image
  Anthropic's OSS Scanner audits (`.oss-scanner/`, with a threat model).

## [0.3.2] - 2026-10-17

### Added
- **Codex desktop threads** on the Agents page while the Codex app is open: title, project,
  working / idle and last activity, with **Open in Codex** (`codex://threads/<id>`), Finder and
  Terminal. Read-only from Codex's local databases; the desktop runs all threads in one backend
  process, so they have no ✕ of their own.

## [0.3.1] - 2026-10-17

### Added
- **Current Codex limits through Codex's own app-server** (opt-in): *Settings › Agents ›
  Read the current limit through Codex*, or the button on the limits card, asks the installed
  `codex app-server` for `account/rateLimits/read` every 5 minutes (usage, reset, plan,
  credits, free resets). Codex makes the request with its own login; CoreScope reads no
  credentials. Needed because recent Codex versions stopped writing `rate_limits` to logs.

### Fixed
- The Codex desktop app (inside ChatGPT.app) is recognized as **Codex Desktop**: its helper
  processes and bundled backend no longer appear as dozens of "Codex CLI" sessions.
- "Show in <app>" brings the terminal or editor forward reliably (LaunchServices instead of
  `NSRunningApplication.activate()`, which recent macOS ignores from another app).
- The limits card says whether the Codex value came from Codex (live) or an older local log.

## [0.3.0] - 2026-10-17

### Added
- **Containers** page for Docker, OrbStack, Docker Desktop and Colima (local engine socket
  only): status, health, image, compose project, published ports, CPU and memory, with
  stop / restart using the same click-to-arm ✕ as processes; an Overview card; and listening
  servers that name the container instead of the VM helper.
- **Opt-in notifications** (new orphan, process above a memory or CPU threshold, memory
  pressure) and a **port lookup** in the menu bar popover ("who is on :3000?") with a
  global shortcut (⌥⌘K by default).
- **Token usage chart**: totals with an input / output / cache split, tokens per day for the
  last 7 days stacked by agent, and proportional bars per agent and per project.
- English documentation, contributing guide, issue and PR templates; VoiceOver labels for
  icon-only buttons.
- `scripts/readme-media.sh` regenerates the README screenshots and demo GIF from the app
  itself (demo mode, no Screen Recording permission).
- **Claude Code 5-hour and weekly limits** (opt-in, off by default) in the limits card,
  menu bar, popover and floating panel, read from the `rate_limits` data Claude Code
  passes to its status line. Turning it on adds a `statusLine` command to
  `~/.claude/settings.json` only when none exists (backed up first; an existing one is
  chained only on request); turning it off restores the previous value. No Keychain,
  credentials or network.
- **Opt-in persistent history** (off by default; Settings › History, keep 1, 7 or 30 days):
  one-minute rollups of CPU, memory, swap, disk/network rates, thermal state, memory pressure
  and the top 10 processes by CPU and memory (name, executable, folder, origin — never
  arguments or environment) in a local SQLite file, written once per minute. New **History**
  page with 1 h / 24 h / 7 d views; click a chart to see what dominated that moment.
  *Delete history* removes the file.
- **CPU per core** grouped into performance (P) and efficiency (E) cores.
- **Memory breakdown** like Activity Monitor (app memory, wired, compressed, cached files,
  swap) and memory pressure % next to the macOS pressure events.
- **Token usage** on the Agents page, counted from the agents' local transcripts
  (`~/.claude/projects`, `~/.codex/sessions`): input, output and prompt-cache tokens and
  the model on each session card, plus today / last-7-days totals per agent and project.
  Tokens only, no dollar estimates; message content is never retained.

### Changed
- Containers moved out of the Agents page into their own sidebar tab.
- Filtered process trees (Watched, Dev, Agents, search…) keep each match's children,
  collapsed and expandable, instead of hiding them.
- Agent session cards switch their buttons to icons when the window is narrow instead of
  overflowing the card.
- An expired Codex limit window now says it was reset and is waiting for new usage,
  instead of "resets in 0 s".

### Fixed
- Only one CoreScope runs at a time: launching another copy brings the running one
  forward instead of adding a second menu bar item.
- Reading mounted volumes no longer risks a crash when two samples run at once
  (`getmntinfo` shares one buffer per process; now `getmntinfo_r_np`).

## [0.2.1] - 2026-10-16

### Added
- **Open in Claude** for Claude Desktop agent sessions, which resumes the session in the
  desktop app; CLI and Codex sessions get **Show in ‹terminal/editor›**, which brings
  the hosting app to the front.
- Continuous integration (format, tests, clippy, native tests and app build on Apple
  Silicon) and a tag-triggered release workflow that builds the DMG, zip and checksums.

### Changed
- Agent sessions are listed newest first by start time, and orphans and each session's
  child processes oldest first, so rows no longer swap places on every sample.
- Session cards put their actions on a separate row so titles show in full, and use
  native bordered buttons (Open in Claude, Finder, Terminal).
- Terminating an agent session uses the same inline ✕ as killing a process (click to
  arm, click to confirm), always confirmed because it signals the whole tree.
- Inline confirmations use the native prominent red button instead of a custom pill.

## [0.2.0] - 2026-10-16

First public release.

### Added
- Process tree by default, with project (cwd), origin (agent / editor / terminal),
  listening ports and Σ CPU/memory per subtree.
- Kill without opening windows: inline ✕ (click to arm, click to confirm), terminate a
  whole tree, force quit when SIGTERM is ignored.
- Agents page: Claude Code (desktop and CLI) and Codex sessions with title,
  working/idle status, project and resources; terminate a whole session at once.
- Codex weekly limit, read from Codex's own local logs (no network, no credentials).
- Possible orphans: dev runtimes still running after their terminal, editor or agent
  went away.
- Menu bar popover with CPU, memory, disk and network charts, and a floating panel with
  compact / standard / detailed layouts and in-panel controls.
- English, Portuguese and Spanish; offline-only.

[Unreleased]: https://github.com/Tiagospem/corescope/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/Tiagospem/corescope/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/Tiagospem/corescope/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Tiagospem/corescope/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/Tiagospem/corescope/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Tiagospem/corescope/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Tiagospem/corescope/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Tiagospem/corescope/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Tiagospem/corescope/releases/tag/v0.2.0
