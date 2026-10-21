# Changelog

All notable changes to CoreScope are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

Pull requests add their user-visible changes under **Unreleased**. When a version is
tagged, those entries move under its heading; the release workflow publishes that
section as the GitHub release notes.

## [Unreleased]

### Fixed
- **Heavy actions waiting for a busy Mac that was not busy**: the kernel's memory-pressure
  "warning" lingers while half the memory is free; it now counts only with 35% or less available
  ("critical" always counts). A waiting action says so on its chip and row (*waiting for room:*
  and why) and *Run now* skips the wait.
- **An environment stuck on a busy port**: when a status error names a port ("Port 19091 in use"),
  the card shows who listens on it (marked when orphaned) with Terminate, so a process left by an
  earlier start no longer blocks the environment until it is found by hand.

## [0.12.0] - 2026-10-21

### Added
- **Databases › watch changes**: a window per database that lists, while you use the app, rows
  created (all values), updated (before/after, changed columns) and deleted, per table and
  moment; ignore noisy tables (defaults from `.corescope.yml`, togglable in the window), clear,
  snapshot and compare. No triggers or binlog: kept rows compared when the server says a table
  was written (MySQL/MariaDB information_schema, PostgreSQL pg_stat). MCP `db_watch_*`.
- **`.corescope.yml` `databases:`** — per database: `server`, `ignore_changes`, `skip_data`,
  `before_restore` / `after_restore` commands (any stack).
- **Restore a dump, safer**: other sessions on a replaced database are closed (or waited for
  30 s), `before_restore` / `after_restore` run around it, the tables without data default to
  the project's list and the last choice, a marker table flags an incomplete restore (*incomplete*
  on the card), progress is read from the server, and each server has a restore history.
- **Databases › restore a dump**: a mysqldump / mariadb-dump / pg_dump (plain) dump, `.sql` or
  `.sql.gz`, into an existing database (replaced after a snapshot) or a new one. It is analysed first
  — tables with exact row counts and sizes, views, triggers, routines, definers; truncated,
  multi-database or cross-database dumps are refused — and you choose which tables come without
  data (or *No data above N rows*), and whether to leave out triggers / owners. Streamed into the
  server's client inside the container with its credentials, in batched transactions; the dump's
  USE / CREATE DATABASE / \connect, SET GLOBAL and grants are left out, missing DEFINER accounts
  become CURRENT_USER, max_allowed_packet is raised when needed. Progress, cancel and a log that
  names the dump line of an error. CLI `db analyze` / `db import`; MCP `analyze_dump`,
  `restore_dump`, `restore_status`, `cancel_restore`.
- **Environment › recent runs**: every mode start/stop and action keeps its last 5 logs (with the
  exit code appended). The environment card lists them, *Show output* next to a status error opens
  the latest one, and logs open in a window that follows the run, marks errors and finds with ⌘F.
  Action logs are on the Logs page too. MCP `environment_runs`.
- **Reorder by dragging** the ≡ handle (or *Move up* / *Move down*): projects on the Projects page
  (saved in `projects.json`, so the floating panel and menu bar follow; MCP `reorder_projects`)
  and project sections on the Profiles page (MCP `set_setting profiles_order`).

### Changed
- **Profiles page, more compact**: each project section folds to one line that says what is in
  use, and an app's actions are chips grouped by kind instead of one row each — the chip is the
  button (▶ and the name), with the last result as a dot and output, artifact, cancel and the
  command in its context menu. Action and run rows highlight end to end under the pointer.

## [0.11.0] - 2026-10-20

### Added
- **Projects › choose the editor**: *Settings › Editor and terminal* sets what *Open* uses (the
  file's default app until chosen, CoreScope's editor, or an installed IDE/editor among VS Code,
  Cursor, Windsurf, Zed, PhpStorm and the JetBrains family, Sublime, Nova, Xcode…); IDEs open the
  file inside its project folder.
- **Open in terminal** on the project card, the changes header and each worktree, with the
  terminal chosen in Settings (Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty, WezTerm…); the
  terminal buttons on Processes and Agents use it too. MCP `open_terminal`, and `projects_editor` /
  `projects_terminal` in `get_settings` / `set_setting`.
- **Projects › quick editor**: edit a file from its changes in CoreScope's own editor — line
  numbers, syntax colors, find, ⌘S, external-change warning, unsaved-changes prompt.
- **Projects › fetch, pull, push and publish** in the changes header, with git's output, and the
  **remote** with a link to open it in the browser (credentials stripped from URLs), also on the
  project card. Core `gitchanges::sync`, MCP `project_git_sync`.
- **Databases in containers without a published port** (only inside their compose network) now
  appear, grouped by compose project, matched by image, compose service or name.
- **Databases with a password**: containers are read inside them with their own credentials
  (`MYSQL_ROOT_PASSWORD`/`MARIADB_*`, `POSTGRES_USER`, `REDIS_PASSWORD`, Redis `--requirepass`
  on stdin), so the password never leaves the container; servers on the Mac take a user and
  password saved in the Keychain, handed to the installed client through its environment.

### Fixed
- **Projects › diff**: long lines scroll sideways again (the lazy diff list now gets the widest
  line's width), and each file's header (counts, edit, *Open*) stays in view while scrolled.
- **Projects** no longer flashes "No projects yet" while the list is first read.

## [0.10.0] - 2026-10-19

### Added
- **Environment controllers** (all optional in `.corescope.yml` under `environment:`, older files
  unchanged; see [docs/ENVIRONMENT-CONTROLLER.md](docs/ENVIRONMENT-CONTROLLER.md)): each app of a
  project's own controller is listed with the modes it can come up in (`modes`, one at a time), the
  command that takes it down, containers to watch and its actions; mode commands do the whole
  operation while CoreScope only watches (no second Docker operation, no race with
  `docker compose up -d`, Stop runs only that app's `down`). Services checks follow the profiles,
  app or status component that need them (`profiles:`, `app:`, `component:`), so an app that is
  switched off raises no alert even when a proxy keeps its port open, with the new states
  `starting`, `external` and `unknown` (never up, never off). A `status` command's versioned JSON
  is read every 30 s with a short timeout and reconciled with what CoreScope started (selection
  changed in a terminal, CoreScope restarted, stale readings). One-off actions (setup, backup,
  restore) have their own timeout, log, artifact, cancel and, for restores, a preview the user
  confirms. MCP: `environment_status`, `list_actions`, `run_action`, `cancel_action`; each app mode
  is a profile `project/app:mode` for `start_profile` / `stop_profile`.

### Changed
- **Profiles** is grouped by project: each project's environment card shows a summary (apps
  selected, expected components ready, problems) and one folded row per app, with its state in a
  fixed column, a Start menu with its modes and Stop, and inside it the app's components and
  actions by kind (`kind:`, otherwise guessed from the names); profile cards fold their commands and containers while stopped, show
  the profile's own name with its state in a fixed column, and stopped profiles of a project fold
  into one line when there are more than three. Components whose state the controller could not
  read are summed up in one line and make the app *unknown*, not *starting*; when no container
  engine answers at all (Docker switched off) the environment simply shows as off, without errors
  or alerts. What is open is remembered.
- **Menu bar**: every value has its own SF Symbol (cpu, memory chip, disk I/O arrows, network,
  thermometer, internal drive for the SSD, terminal for Codex, sparkle for Claude) next to it,
  also in the compact format, and the item's tooltip explains each one; the same icons are in
  Settings. Settings › Menu bar is a single list (on/off, what it shows, order) instead of the
  toggles followed by an unexplained copy of the same items.
- **Lower cost**: environment status reads use `/bin/sh` with the login environment read once
  instead of an interactive login shell every 30 s, and slow to every 2 min with no window open;
  the floating panel is released when turned off and the menu bar window stops rendering while
  closed (both kept updating on every sample); freed memory is returned to macOS after the window
  closes and every 5 min while closed.

### Fixed
- An ejected volume leaves Storage at once instead of up to 30 s later.
- *Language: System* followed the language last chosen in CoreScope instead of macOS's.

## [0.9.0] - 2026-10-18

### Added
- **Performance audit**: MCP `performance_audit` sweeps what CoreScope already knows and ranks
  what the user could stop, remove or turn off — orphans, heavy apps and processes, stuck or
  power-hungry agent sessions, started profiles, idle and stopped containers, reclaimable space from the
  cached Cleanup scan and plan, folders Disk growth saw grow, Services checks that are always down,
  and CoreScope's own costliest switches (collector interval, floating panel, Codex and Claude live
  limits). Each finding carries what it would give back (CPU, memory, disk, watts), how sure
  CoreScope is, and the tool and arguments that act on it; the audit never acts, never scans the
  disk, and lists stale sources with the tool that refreshes them. Ranking weighs whatever is tight
  right now (memory pressure, a nearly full disk, battery). The top findings also show on the
  Overview as *To lighten the Mac*, each row opening the page where to act.
- **Remove unused Docker volumes** from the Containers page: a trash button per volume and
  *Remove unused…* for all of them, each behind a confirmation that names the volumes, their sizes
  and that the data is deleted for good. Only volumes no container references (running or
  stopped) can be removed; volumes in use say by which containers, and the core re-checks right
  before `DELETE /volumes/{name}` (never forced) over the same local socket. Per-volume results,
  then the list refreshes. Rows show when each volume was created, anonymous (64-hex) volumes and
  what the labels say made them (compose project and volume), and database-like volumes
  (MySQL/PostgreSQL/Redis) warn that no snapshot is possible without a container. MCP
  `list_volumes` and `remove_volumes` (a dry run unless `confirm: true`; in-use volumes are
  always refused).
- **Projects › Remove unused worktrees and branches**: *Remove unused…* on each repository's card
  (Branches and Worktrees sections, card menu) opens a confirmation listing exactly what goes —
  linked worktrees whose branch is merged into the default branch, whose upstream is gone or whose
  folder is gone, and local branches merged into the default branch — with path, branch, size, why
  each qualifies and a checkbox per item. Never the main or current working tree, a worktree a
  process works in, a locked one, or a branch checked out in a worktree that stays; a worktree
  with uncommitted changes is shown and skipped unless a separate option (off by default) allows
  `--force`. A merged branch can go together with its worktree. Uses `git worktree remove` and
  `git branch -d` (never `-D`); the core checks every item again against fresh state before
  removing and reports each result (removed, refused with the rule, or git's error). MCP
  `project_unused` (dry run with reasons) and `project_remove_unused` (same rules, never forced or
  dirty).

### Changed
- **Services tell "not running" apart from "down"**: checks are grouped by project (checks added
  in the app in their own group) with a per-group summary. A check from a project's
  `.corescope.yml` whose profile is not running and whose port nobody listens on is gray "not
  running", with a Start button for the profile; while the app is off it is not probed at all
  (checking resumes when the profile starts or the port opens), no longer counts against uptime
  and sends no down notifications; red is kept for what should be up (profile running, port listening but
  failing, checks added by hand). The tooltip explains each state. Checks and whole groups can be
  paused. MCP `list_services` / `check_services` report `status` (`up`, `answered_with_error`,
  `down`, `not_running`, `paused`, `not_checked_yet`), `group`, `monitored` and `explanation`; new MCP
  `pause_service`.
- The Worktrees and Local branches sections group their rows into *In use*, *Removable* and
  *Other*, show the removable count and size next to the title, collapse long groups, and share
  badges (merged, upstream gone, in use) in the same order and colors.

## [0.8.1] - 2026-10-18

### Added
- **Current Claude limits** (opt-in): *Settings › Agents › Read the current limit through Claude
  Code* (or the button on the limits card) runs Claude Code's own `/usage` (`claude -p /usage`, no
  model turn, no tokens, no session saved, hooks off) every 5 minutes while a Claude session is
  working and every 30 minutes otherwise, so the panel, menu bar and overview show the same 5-hour
  and weekly numbers, with reset times, as Claude Code and Claude Desktop — instead of a Claude
  Desktop sample that can be hours old. Claude Code asks Anthropic with its own login; CoreScope
  reads no credentials. MCP `usage_limits` adds `age_seconds` and `live_read` for Claude and Codex.

### Changed
- The Claude limit shown is now the newest of Claude Code's `/usage`, the status line and Claude
  Desktop's samples (one with reset times wins within 5 minutes); an old status-line reading no
  longer hides a newer Claude Desktop sample.

## [0.8.0] - 2026-10-18

### Added
- **Projects page** (phase 1 of the Projects epic): register local repositories by folder, with a
  default name from `.corescope.yml` (or the folder) that stays editable; the file is validated
  with errors placed on their line and summarized (profiles, ports, Services, logs, capacity), a
  minimal one is offered when missing (decline and nothing is added); git root, linked worktree
  and main repository, subfolder, branch or detached HEAD; `git init` after a confirmation;
  rename and remove (files are never touched). `corescope://open/projects`, `corescope projects`,
  MCP `list_projects`. The list lives in `Application Support/CoreScope/projects.json` and is part
  of the settings backup.
- **Projects › Changes and commit** (phase 2): a commit panel per repository — branch, upstream
  and ahead/behind, last commit; files grouped into Conflicts, Staged, Modified, New and Removed
  with status and +/− lines (`git status --porcelain=v2` plus `git diff --numstat`); checkbox
  stage/unstage, multi-select, *Stage all* / *Unstage all*; unified diff; open in an installed
  editor or Finder; *Discard changes…* after a confirmation (tracked files back to HEAD, new files
  to the Trash); commit with ⌘↩, disabled without a message, staged files or with conflicts, hooks
  and signing as configured and a failing hook's output shown. `index.lock` and conflicts are
  explained, never a crash. The diff reads like Zed's uncommitted-changes view: all changes
  stacked by file (or the selected files) under pinned headers with a stage checkbox and *Open*,
  green/red/yellow gutter bars, line numbers, syntax colors, folded unchanged stretches and
  ↑/↓ between changes. Each card shows the change counts and ahead/behind without opening it,
  live while the page is open. FSEvents refreshes the panel only while it is open (`.git` reduced to
  HEAD/index/refs, `.gitignore`d paths dropped, at most two reloads a second), measured as
  *Projects (git)* in CoreScope's own cost. `corescope status`, `corescope://project/NAME`, MCP
  `project_git_status`, `project_git_diff`, `project_git_stage`, `project_git_commit`,
  `project_git_discard`.
- **Projects › Branches and worktrees** (phase 3, view only): collapsible sections on each
  repository's card, closed by default and read only when opened. Local branches (`git branch
  --format`): current first, last commit, ahead/behind or upstream gone, checked out in another
  worktree. Worktrees (`git worktree list --porcelain`, main included): branch, agent, merged,
  uncommitted changes, process working in it, lock, folder gone, last commit and a size measured
  in the background and cached for 10 minutes, without counting nested worktrees twice. Removal
  stays on the Cleanup page, linked from the section. `corescope branches`, `corescope worktrees`
  accepts a project name, MCP `project_branches` / `project_worktrees`.
- Demo mode also anonymizes project names and branch names on the Projects page.
- **Projects in the floating panel and the menu bar** (phase 4): *Show in panel* per project (card
  menu, the panel's menu, MCP `set_project`) adds a row with name, branch and change counts to
  every panel layout and to the menu bar popover, read when they appear and kept live by file
  watchers only while visible; a click opens the project's changes in a window of their own.
- **Change notifications per project** (phase 5, opt-in, off by default): every 1, 5 or 15 min
  (card menu, Settings › Notifications, MCP `set_project`). Watchers only mark a project as
  touched; at its interval it is read once and compared with the last notification (core
  `delta`, tested), so it says what moved — new/modified/staged/deleted/conflict counts, a new
  commit or a branch switch — and never fires for a save that changes nothing. Clicking opens the
  changes.
- **AI commit message** (phase 6, opt-in, off by default): *Generate message* in the changes
  panel writes the message from the staged diff only (core `commit_context`: lockfiles and
  binaries left out, cut at a configurable size, tested) with the provider set in *Settings › AI*:
  Claude Code `claude -p` or Codex `codex exec` already signed in (no tools, no MCP, outside any
  project), the Anthropic / OpenAI (Responses) / Gemini API with the key in the Keychain only, or
  Ollama / LM Studio. Editable instructions (Conventional Commits, title up to 72 characters),
  message language, model as free text with suggestions, *Test connection*, and a one-time
  consent per provider showing exactly what is sent. The message is editable and nothing commits
  on its own. MCP `generate_commit_message`. CONTRIBUTING and Privacy document the exception to
  local-only.
- **Agents follow the project's `.corescope.yml` on their own**: *Settings › MCP server › Agent
  hooks* installs, per agent (Claude Code `~/.claude/settings.json`, Codex `~/.codex/hooks.json`,
  each backed up first), a SessionStart hook (`corescope context --hook`) that gives each new
  session a summary of the nearest `.corescope.yml` — capacity rule and heavy commands, ports,
  profiles, services, logs, a snapshot before wiping a database, or the file's error with its
  line — and the capacity gate (`corescope gate`), which now also covers Codex (same payload). The
  settings show whether Codex trusts the hooks (it runs user hooks only after `/hooks`). For
  agents without hooks: MCP `agent_context`, and a marked section in the project's `CLAUDE.md` /
  `AGENTS.md` (*Agent instructions…* on the project card, `corescope context --write`, MCP
  `write_agent_instructions`), leaving the rest of the file alone. MCP `agent_hooks` reports and
  changes the hooks; the MCP instructions ask agents to read `agent_context` when no session
  context came.

### Fixed
- The Navigate menu gives ⌘1–⌘9 to the first nine pages only; more pages would have crashed it.

## [0.7.0] - 2026-10-18

### Added
- **Machines › why a systemd unit failed**: the units in a *Failed systemd units* alert are
  clickable. CoreScope runs `systemctl status <unit> --no-pager -n 0` and the unit's journal over
  your BatchMode ssh (read-only, no sudo, unit name validated), groups the last run's
  `error`/`failed` lines with counts and shows a hint for well-known causes — logrotate
  `unknown user` (a config left for a deleted site user, e.g. Laravel Forge's
  `/etc/logrotate.d/forge-*`), logrotate `duplicate log entry`, postrotate failures and `nginx -t`
  errors. Says when journald hides system logs from the ssh user (not in `adm`/`systemd-journal`).
  Hints only explain; CoreScope never changes the server.
- MCP `explain_failed_unit {host, unit}`: the same status, grouped errors and hints for agents.
- **Storage**: processes using the disk now; SSD health from NVMe SMART (wear, spare, data written
  and read, power-on hours, cycles, unsafe shutdowns, media errors, verdict); *What grew today*
  opens each folder to the subfolders that grew and links to the cleanup plan; a **safe cleanup
  plan** for caches tools re-create, with estimates, the exact command or folders and busy-tool
  checks; **large files** in the home folder and its linked drives (one filesystem per root,
  cloud storage and `node_modules` skipped, app-managed files only shown); **Eject…** shows the
  processes holding a volume and runs `diskutil eject`. CLI `top --disk`, `disk-health`,
  `space --plan`, `large-files`, `eject-check`; MCP `disk_health`, `cleanup_plan`,
  `run_cleanup_plan`, `large_files`, `volume_holders`, `eject_volume`.
- **Databases**: *Open in* TablePlus, Redis Insight, Sequel Ace, Postico or DBeaver and *Copy DSN*;
  Redis keys by prefix (sampled, adaptive depth) with keys without TTL and `FLUSHDB` after a
  confirmation; **snapshots** of MySQL/MariaDB and PostgreSQL databases (inside a container with
  its own credentials, never seen by CoreScope) and restore. CLI `db snapshot|snapshots|restore|
  redis`; MCP `db_snapshot`, `db_snapshots`, `db_restore`, `redis_keyspace`, `redis_flush`; the MCP
  instructions ask agents to snapshot before `migrate:fresh` or `db:wipe`.
- **Claude limits without the status line**: from Claude Desktop's own samples
  (`plan-usage-history.json`), local and credential-free. **Pace** per limit window (projected at
  the reset, or when it reaches 100%). MCP `usage_limits`.
- **Settings backup** outside `~/Library` (default `~/.corescope/backups`, or a folder you pick),
  written a few seconds after a change; a launch with empty settings offers to restore it. MCP
  `backup_settings`.

### Fixed
- Status line data that carries the reset epoch in `used_percentage` is ignored instead of shown.
- Sizes and rates read "0 KB" instead of "Zero KB".

## [0.6.0] - 2026-10-18

### Added
- Floating panel, opt-in **Agents** section: running Claude Code, Codex and other agent sessions
  with their project and whether each is working, waiting or looks stuck (from the stall
  watcher), plus the usage limits; a click opens the session. Compact layout shows the count.
- Floating panel, opt-in **Remote machines** section: the ssh machines you check in Settings ›
  Floating panel (or "Show in the floating panel" on a Machines card), each with load per core,
  memory, disk and alerts. Checked machines are read every 60 s while the panel is visible,
  sharing one cadence with the Machines page so both open never probe a host more often; the
  extra reads show in CoreScope's own cost.
- MCP `get_settings` / `set_setting`: `panel_agents`, `panel_machines` and
  `panel_machine_hosts`; `list_machines` says which machines the panel shows.
- **Updates (opt-in, off by default)**: *Settings › Updates* checks the latest GitHub release once
  a day, or when you click *Check now*. A new version shows its changelog in Settings, `↑ <version>`
  next to the version in the sidebar and the menu bar popover, and one notification; **Install and
  relaunch** downloads it, verifies its EdDSA signature and replaces the app, bundled `corescope`
  command included. Built on Sparkle 2, trusted through the project's update key because the app is
  signed ad hoc. With the toggle off, CoreScope makes no request. `corescope version [--check]`, MCP
  `update_status` and the `check_for_updates` setting.
- Releases publish a signed `appcast.xml` next to the DMG and zip.
- **Homebrew cask**: `brew install --cask tiagospem/tap/corescope` installs the release zip and
  links the `corescope` command. The cask (`auto_updates`, macOS 14+, `zap` for the app's data) is
  in `packaging/homebrew/`; with a `HOMEBREW_TAP_TOKEN` secret the release workflow bumps its
  version and checksum in the tap after publishing.

### Changed
- **CPU per core**, redesigned: performance and efficiency cores in plain words (what each kind
  runs), a big average per group, and one tile per core that fills up and turns from green to amber
  to orange with load, the percentage written inside; a colour legend replaces the data-source
  line (still on hover).
- Turning on a setting that posts no notifications (the floating panel ones) through MCP no
  longer asks for notification permission.

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

[Unreleased]: https://github.com/Tiagospem/corescope/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/Tiagospem/corescope/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/Tiagospem/corescope/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/Tiagospem/corescope/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/Tiagospem/corescope/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/Tiagospem/corescope/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/Tiagospem/corescope/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/Tiagospem/corescope/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Tiagospem/corescope/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/Tiagospem/corescope/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/Tiagospem/corescope/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Tiagospem/corescope/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/Tiagospem/corescope/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Tiagospem/corescope/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Tiagospem/corescope/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Tiagospem/corescope/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Tiagospem/corescope/releases/tag/v0.2.0
