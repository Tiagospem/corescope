<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="CoreScope icon">
</p>

<h1 align="center">CoreScope</h1>

<p align="center">
  <b>A system monitor for developers on macOS.</b><br>
  See which AI agent session, dev server or forgotten process is eating your Mac — and stop it in one click.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-3ddc84">
  <img alt="Rust + SwiftUI" src="https://img.shields.io/badge/Rust%20%2B%20SwiftUI-native-orange">
  <img alt="Offline" src="https://img.shields.io/badge/network-none-blue">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey">
</p>

<p align="center">
  <img src="docs/screenshots/demo.gif" alt="CoreScope tour: overview, process tree, agent sessions with token usage, containers and history" width="900">
</p>

<p align="center">
  <img src="docs/screenshots/overview.jpg" alt="CoreScope overview: CPU, memory, disk and network charts, per-core CPU, memory breakdown, listening servers and possible orphans" width="900">
</p>

---

## Why CoreScope?

Activity Monitor tells you *that* `node` is using 2 GB. It doesn't tell you **which project it belongs to, which agent or terminal started it, which port it's serving, or that its parent died an hour ago**.

If you work with Claude Code, Codex, editors and terminals all day, your Mac fills up with dev servers, MCP servers, language servers, watchers and the leftovers of sessions you already closed. CoreScope organizes all of that around the way you actually work — **projects, agents and ports** — and lets you clean it up without hunting for PIDs.

### Who it's for

- Developers running **AI coding agents** (Claude Code — desktop and CLI — Codex, Gemini CLI, Aider, OpenCode, Cursor Agent…) who want to see what each session spawned.
- Anyone juggling **local dev servers, containers and databases** (Node, Bun, Python, PHP/Herd, Go, Docker/OrbStack, Postgres, Redis…).
- People on **memory-constrained Macs** (8–16 GB) who need to know what to stop *right now*.

## Features

### 🌳 Process tree, built for dev work

<img src="docs/screenshots/processes.jpg" alt="Process tree grouped by app and agent session, with project, origin, ports and summed CPU/memory" width="900">

- **Tree view by default.** Every app or tool heads its own tree; children of `launchd` become roots. Collapsed parents show the child count and **Σ totals** of CPU and memory for the whole subtree.
- **Project & origin columns.** The working directory (`cwd`) of each process and the agent, editor or terminal that started it ("via Claude Code", "via Zed", "via Warp").
- **Listening ports** per process, highlighted when exposed beyond loopback, with a one-click *open `localhost:port`*.
- **Filters:** All · Mine · Dev · Agents · Servers · Orphans · Watched — plus search by name, PID, port, project or agent.
- **Kill without opening windows:** ✕ on any row (click to arm, click to confirm), ⌫ / ⌘⌫ on the selection, *terminate tree* to stop a process and everything it started, and *force quit* (SIGKILL) when SIGTERM is ignored.
- **Live inspector** with origin, directory (open in Finder / Terminal), executable, resources and optional history.

### ✨ Agents

<img src="docs/screenshots/agents.jpg" alt="Agents page: usage limits, token usage per day, agent and project, and Claude Code sessions with title, status, project, processes and resources" width="900">

- Every **Claude Code** session (desktop app and CLI) and **Codex** session, with its title, *working / idle* status, project, how long it has been running, how many processes it started, ports, CPU and memory.
- **Terminate a whole session** — the agent and every server, shell and tool it spawned — in one action.
- **Codex limits**, by default from the last `rate_limits` event in Codex's local session logs. Recent Codex versions (the desktop app inside ChatGPT.app) no longer write those events, so turn on *Settings → Agents → Read the current limit through Codex* (or the button on the limits card) to ask Codex's own app-server — the same `account/rateLimits/read` call the Codex app makes — every 5 minutes: current usage, reset time, plan, credit balance and free resets. Optionally shown in the menu bar and floating panel.
- **Claude Code 5-hour and weekly limits** (opt-in, Pro/Max plans), taken from the [`rate_limits` data Claude Code hands to its status line](https://code.claude.com/docs/en/statusline). Turn on *Settings → Agents → Read the Claude limit from the status line*; see [Privacy](#privacy) for exactly what it changes.
- **Token usage**, counted from the agents' own local transcripts: input, output and prompt-cache tokens plus the model on each session card, and totals for today and the last 7 days per agent and per project. Tokens only — no dollar estimates.
- **Possible orphans:** dev runtimes still running after their terminal, editor or agent went away.

### ⏳ Stuck agents

A busy Claude Code session or Codex thread that has not written to its transcript for a while (10 min by default) gets a badge on the Agents page, and optionally a notification that opens it in Claude or Codex. CoreScope tells the cases apart by what the commands started in the current turn are doing: one using CPU is a **long command** (a build, a test run); one sitting idle is **waiting** — often a prompt asking for input; nothing running at all means the agent itself looks **stuck**. Servers it left listening and processes from earlier turns (MCP servers) are ignored. Only modification times are read, never transcript content.

### 💚 Services

Watch the things your work depends on: a local API's `/health`, a database port, a staging URL. Each check runs every 30 s while CoreScope is open — an HTTP GET (2xx/3xx up, 4xx answered with an error, 5xx or no answer down) or a TCP connect — with latency, a strip of the last 40 results, an Overview summary and optional notifications when a service goes down (two failures in a row) or comes back. Ports you have open right now are offered as one-click suggestions.

### ▶️ Profiles

One click to bring a project's environment up or down. A profile is a folder, the commands you run there every day (`npm run dev`, `php artisan serve`, `cargo watch -x run`…) and the containers it needs. *Start* runs each command in your login shell inside the folder, with output in `~/Library/Application Support/CoreScope/logs`, and starts the containers; the card shows what is running, PIDs and ports. *Stop* (after confirmation) sends SIGTERM only to the process trees CoreScope started for that profile — identity-checked like every other termination — and stops its containers — only the ones a profile started, and never one another started profile still uses: shared containers (one database for several projects) stay up until the last profile using them stops, and the confirmation lists what stops and what stays. *Stop everything* is there when you want it all down.

### 🗄️ Databases

The MySQL/MariaDB, PostgreSQL and Redis servers running on this Mac — as processes or containers — with version, uptime, size per database (keys per db for Redis), connections, slow-query counters and the queries running for more than 5 seconds. CoreScope speaks each database's own protocol on 127.0.0.1 with read-only queries, each capped on the server too. **It never asks for, stores or reads passwords**: it connects only where the server allows passwordless local access (MySQL `root` without a password, PostgreSQL trust for your user, Redis without AUTH) and otherwise just shows that a password is required. Also `corescope db` and the MCP tool `list_databases`.

### 🖥️ Machines

Servers you reach over ssh — add an alias from `~/.ssh/config` (offered as suggestions) or `user@host` — with OS, uptime, load against cores, memory, root disk, the top processes and running containers, refreshed every 60 s while the page is open. CoreScope runs **your own `ssh` in BatchMode** with a fixed, read-only script (`uname`, load, memory, `df`, `ps`, `docker ps`) piped to `sh -s`: keys and agent stay with ssh, nothing prompts for a password, and a host whose key is unknown fails instead of being accepted. Only `Host` names are read from your ssh config.

### 🕒 History (opt-in)

<img src="docs/screenshots/history.jpg" alt="History page: CPU, memory, disk and network over the last hour, thermal and memory pressure, and the processes that dominated" width="900">

- Answers *“what made my Mac slow yesterday at 3 pm?”*: 1 h, 24 h and 7 d views of CPU (mean and peak), memory and swap, disk, network, thermal state and memory pressure, with gaps where nothing was recorded.
- Click any chart to see **the processes that dominated that moment** (top CPU and memory, with project and “via Claude Code”-style origin); step back period by period or jump to a date.

### 🐳 Containers

<img src="docs/screenshots/containers.jpg" alt="Containers page listing OrbStack containers with status, image, published ports, CPU, memory and stop/restart buttons" width="900">

- **Docker and OrbStack containers** (also Docker Desktop and Colima) with status, health, image, compose project, published ports, CPU and memory — on an Overview card and on their own **Containers** page.
- **Listening servers name the container**: ports that OrbStack Helper or `com.docker.backend` hold for a container show up as *container &lt;name&gt;* instead of the VM helper.
- **Stop / Restart** in place with the same click-to-arm, click-to-confirm button used for processes.
- Read from the engine's **local Unix socket** only (`~/.orbstack/run/docker.sock`, `~/.docker/run/docker.sock`, Colima, `/var/run/docker.sock` or a `unix://` `DOCKER_HOST`), at most every 5 s and only while a container view is on screen.

### 🧹 Cleanup

Finds reclaimable developer space and shows what each item is, where it is, its size and when it last changed:

- **Projects:** `node_modules` (next to a `package.json`) and Rust `target/` (with Cargo's `CACHEDIR.TAG`), in the folders you add and in the folders holding the projects your agents, editors and terminals are working in.
- **Xcode:** DerivedData per project, device support files, Simulator caches.
- **Package caches:** Homebrew, npm, Yarn, pnpm, Bun, Cargo, pip, uv, Go, Gradle, Composer, CocoaPods.
- **Docker:** dangling images, images no container uses, unused build cache (through the engine's own API).

Nothing is scanned until you press *Scan*: the last result is kept in `~/Library/Application Support/CoreScope/cleanup-cache.json` (paths, sizes and dates) and the page says when it may be out of date (older than 6 hours, or the folder list changed). Select items (or *Unused 30+ days*) and confirm: folders go to the **Trash**, so they can be recovered until you empty it. Anything a process is using — a dev server in the project, `cargo`, Xcode, an agent working there — is locked, and every folder is re-checked by the core right before it moves: still a real folder (no symlinks), still one of the kinds above, still unused. Docker data is removed by Docker and pulled again when needed.

### 📊 Menu bar and floating panel

<table>
<tr>
<td align="center" valign="top" width="50%">
<img src="docs/screenshots/menubar.jpg" alt="Menu bar popover with CPU, memory, disk and network charts, agent sessions, servers and top CPU" width="330"><br>
<sub><b>Menu bar</b> — CPU, memory, disk and network charts, agent sessions, servers and top CPU, each with a stop button.</sub>
</td>
<td align="center" valign="top" width="50%">
<img src="docs/screenshots/panel.jpg" alt="Floating panel in detailed layout" width="300"><br>
<sub><b>Floating panel</b> — compact, standard or detailed layouts. Pin above windows, lock position, size, opacity and contents right from the panel (⋯ or right-click). Drag it anywhere.</sub>
</td>
</tr>
</table>

### 🔔 Notifications and port lookup

- **Opt-in notifications** (Settings → Notifications, all off by default, delivered locally through macOS UserNotifications):
  - a **new possible orphan** appeared, with its project and port — and a **Terminate** button that sends SIGTERM through the same path as the app (identity revalidated right before the signal);
  - a process **stays above** a memory size (default 2 GB) or CPU (default 150 % of one core) for a while (default 60 s);
  - macOS **memory pressure** reaches *warning* or *critical*, naming the biggest consumer.

  At most one notification per process identity (PID + start time) per hour. Protected processes and other users' processes never notify. Rules run on the snapshots CoreScope already collects — no extra timer or sampling.
- **Port lookup in the menu bar:** type a port (e.g. `3000`) to see which of your processes listens on it — name, project, origin — with *open `localhost:port`* and ✕. An empty result reads *Free*.
- **Global shortcut ⌥⌘K** (configurable in Settings → Port shortcut) opens the menu bar popover with the port field focused. It is registered with Carbon's `RegisterEventHotKey`, so it needs **no Accessibility or Input Monitoring permission**: the app receives only that one key combination, never other keystrokes. (macOS 27 no longer exposes a public way to open a `MenuBarExtra` window, so there the shortcut shows the same menu in a standard popover anchored to the status item.)

### ⌨️ Command line

Install it from *Settings → Command line* (a link in `~/.local/bin`). Every command accepts `--json`, so agents can use it too:

```bash
corescope ports                    # listening ports with process, project and origin
corescope free-port 3000           # first free localhost port from 3000
corescope kill-port 3000           # stop what listens on :3000 (asks first; --yes, --force)
corescope agents                   # agent sessions, what they started, their ports
corescope orphans                  # dev runtimes left running without their parent
corescope top --mem -n 10          # top processes by memory (or CPU)
corescope kill 4242 --tree         # stop a process and everything it started
corescope space                    # reclaimable node_modules, target/, Xcode, caches, Docker
corescope db                       # local MySQL/PostgreSQL/Redis: sizes, connections, slow queries
```

Termination follows the app's rules: only your own processes, never system services or the command's own ancestors (an agent cannot stop its own session), identity revalidated right before each signal, and no signal without `--yes` when there is no terminal to confirm in.

### 🤖 MCP server for agents (opt-in)

Off by default. *Settings → MCP server for agents → Enable* registers `corescope mcp` (a stdio MCP server inside the app) with **Claude Code** (`claude mcp add --scope user`) and/or **Codex** (`codex mcp add`); *Disable* removes it. Agents then get these tools:

| Tool | What it does |
| --- | --- |
| `list_ports` / `find_free_port` | Listening ports with process and project; first free localhost port |
| `top_processes` / `system_summary` | Heaviest processes by CPU or memory; CPU, memory, swap and disk at a glance |
| `list_agent_sessions` / `list_orphans` | Agent sessions and what they started; dev runtimes left without a parent |
| `list_my_processes` | What the calling agent session started, including servers it detached |
| `list_databases` | Local MySQL/PostgreSQL/Redis status (read-only, no passwords) |
| `list_dev_space` | Reclaimable space (read-only; cleaning stays in the app, with your confirmation) |
| `stop_port` / `stop_process` | Stop a process (or a port's owner), **only if this agent session started it** |

The server finds its agent session from its own parent chain. A process counts as the session's when it descends from it, or when it was detached (reparented to `launchd`) after the session started, inside the session's folder, and no other running session could claim it. Anything else — other sessions, other users, system services, apps, Docker — is refused with a message telling the agent to ask you. It runs locally, makes no network requests and reads no credentials. Before Codex rewrites `~/.codex/config.toml`, CoreScope keeps a one-time copy at `config.toml.corescope.bak`.

### And also

- **Storage & I/O:** per-device read/write, volume capacity (without double-counting APFS containers), NVMe temperature via public SMART APIs.
- **Honest metrics:** every value carries its source and timestamp; missing data is labeled, never faked. Memory is *active + wired + compressed*, and is never presented as "pressure".
- **Languages:** English, Portuguese and Spanish — follows your system language or a choice in Settings.
- **Dock behavior:** always, only while the window is open (default — close it and CoreScope lives in the menu bar), or never.
- **Shortcuts:** ⌘1…⌘8 pages · ⌘R refresh · ⇧⌘P floating panel · ⇧⌘Space pause / resume · ⌥⌘K port lookup (global).

## Install

### Download (Apple Silicon)

1. Download `CoreScope-<version>-macos-arm64.dmg` from the [latest release](https://github.com/Tiagospem/corescope/releases/latest).
2. Open the DMG and drag **CoreScope** to **Applications**.
3. First launch: the app is open source and signed ad hoc, **not notarized by Apple**, so macOS blocks it the first time. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Alternatively, in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/CoreScope.app
   ```

Each release lists SHA-256 checksums (`SHA256SUMS.txt`) so you can verify the download with `shasum -a 256 CoreScope-*.dmg`.

### Build from source

**Requirements:** macOS 14 or later · Xcode Command Line Tools (Swift 6) · Rust/Cargo. Developed and validated on Apple Silicon (MacBook Air M4, macOS 27); Intel Macs are untested.

```bash
xcode-select --install                                           # Swift toolchain, if needed
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # Rust, if needed
git clone https://github.com/Tiagospem/corescope.git
cd corescope
./scripts/build.sh
open build/CoreScope.app
```

The build produces `build/CoreScope.app`, signed **ad hoc** for your machine. To keep it, drag it to `/Applications`. The app asks for no special permissions: no root, no Full Disk Access, no helper tools, and *launch at login* stays off until you turn it on in Settings.

## Privacy

CoreScope is **local-only**: no network access, no telemetry, no accounts. The one exception is yours to make: a *Services* check pointing outside this Mac contacts only that URL or host (the app warns when you add one).

- Process names, executables, users, start times, working directories and listening ports are read locally through public macOS APIs (`libproc`, `sysctl`, IOKit). Working directories and ports are read only for **your own** processes.
- **Arguments and environment variables are never collected.**
- Agent data comes from local files: the newest `rate_limits` event in `~/.codex/sessions`, the session metadata in `~/.claude/sessions`, and — for the Codex desktop app, which runs every thread inside one backend process — the thread catalog and in-progress turns in Codex's own databases (`~/.codex/sqlite/codex-dev.db`, `~/.codex/thread_history_1.sqlite`), opened read-only: thread id, title, folder, last activity and whether a turn is running. Never message content. The one exception is opt-in: *Read the current limit through Codex* runs the installed `codex app-server` (the copy bundled with ChatGPT/Codex.app, or Homebrew's) and sends it `account/rateLimits/read`; **Codex** then contacts OpenAI with its own login. CoreScope itself still makes no network requests and never reads credentials.
- **Claude Code limits are opt-in and off by default.** Claude Code does not store its usage limit on disk, and CoreScope never reads the Keychain, credentials or the network to fetch it. When you turn on *Read the Claude limit from the status line*:
  - CoreScope backs up `~/.claude/settings.json` (to `~/Library/Application Support/CoreScope/backups/`) and adds a `statusLine` command — only if you have none. An existing status line is never replaced; you can explicitly chain it (CoreScope's command runs first with `--record` and passes the input through, so your status line prints exactly as before) or edit it by hand. Every other key is preserved as written.
  - After each reply, Claude Code itself pipes the status line JSON to that command (`~/Library/Application Support/CoreScope/claude-statusline.sh`, a readable shell script). It keeps **only** `rate_limits` (percentages and reset times) in `claude-limits.json` next to it; nothing else from the session is stored.
  - The numbers refresh only when Claude Code replies, and only Pro/Max plans report them.
  - Turning the option off restores the previous `statusLine` exactly (or leaves it alone if you edited it since) and deletes the saved limits and the script (the script stays only while a hand-edited status line still calls it).
- Token usage is counted from the agents' transcripts, read-only, and only once you open the Agents page: `~/.claude/projects/<project>/<session>.jsonl` and `~/.claude/projects/<project>/<session>/subagents/*.jsonl` (the `usage` object of assistant entries) and `~/.codex/sessions/YYYY/MM/DD/*.jsonl` (`token_count` events). Only files written in the last 7 days and the transcripts of running sessions are read, each from where the previous pass stopped. **Message content is never retained:** lines are scanned in a small reusable buffer and only token counts, model ids, session ids, working directories and the id of the last message seen in each file are kept, in memory — nothing is written to disk.
- Containers come from the Docker Engine API over its local Unix socket — never TCP, never registry or Docker Hub credentials. Nothing is read while no container view is on screen.
- Notifications are optional and local (UserNotifications); nothing is sent anywhere. The global shortcut uses `RegisterEventHotKey` and sees only its own key combination.
- Live charts (up to 10 minutes) live in memory only. Preferences and watched processes stay in `UserDefaults`.
- **Persistent history is opt-in** (off by default; Settings › History, retention 1, 7 or 30 days). When on, CoreScope writes one-minute rollups — system CPU, memory, swap, disk/network rates, thermal state, memory pressure and, per minute, the top 10 processes by CPU and by memory (name, executable, working directory and agent/editor origin; never arguments or environment) — to `~/Library/Application Support/CoreScope/history.sqlite`, in one SQLite transaction per minute. Older rows are purged automatically and *Delete history* removes the file.
- Cleanup reads folder sizes and modification times only (never file contents) and only when you open the page or press *Scan*. Docker sizes come from the engine's `/system/df`.
- The MCP server (opt-in) answers only on stdio to the agent that launched it; registering it runs the agents' own `mcp add`/`mcp remove` commands, nothing else is changed.
- Nothing is ever killed automatically. Termination only targets your own, eligible processes, revalidates each process identity (PID + start time + executable) right before signaling, and never touches system services or CoreScope's own ancestors.

## Resource usage

A monitor shouldn't be what slows your Mac down. Measured on a MacBook Air M4 with ~450 processes:

| State | Memory (footprint) | CPU |
|---|---|---|
| Window open, sampling every 3 s | ~80 MB | ~2–3 % of one core |
| Window closed (menu bar only, sampling every 10 s) | ~85 MB | < 1 % of one core |

Sampling pauses during sleep and slows down in Low Power Mode.

## How it works

| Directory | Role |
|---|---|
| `core/src/macos.c` | Thin C adapter over public SDK APIs (libproc, Mach, sysctl, IOKit, NVMe SMART) |
| `core/src/containers.rs` | Docker Engine API client over local Unix sockets: container list, one-shot stats, stop/restart |
| `core/src/lib.rs` | Rust core: sampling, deltas, history, diagnostics, process classification (agents, editors, terminals, runtimes), origin and orphan detection, safe signaling, C ABI |
| `native/` | SwiftUI + AppKit app: window, menu bar extra, floating `NSPanel`, agents, localization |
| `scripts/` | Build, tests, procedural app icon, external read-only resource meter |
| `docs/` | Architecture, API sources, validation and measurement notes (English; Portuguese originals in `*.pt-BR.md`) |

The Swift UI calls the Rust core over a small C ABI that returns one JSON snapshot per sample on a serial background queue. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Development

```bash
./scripts/test.sh     # cargo fmt --check, cargo test, clippy -D warnings, native logic tests
./scripts/build.sh    # release build into build/CoreScope.app
./scripts/package.sh  # DMG + zip + SHA-256 checksums into dist/ (release artifacts)
open --env CORESCOPE_DEMO=1 build/CoreScope.app   # demo mode: live metrics, anonymized user, folders, projects and session titles (quit with ⌘Q first)
./scripts/readme-media.sh  # regenerates the README screenshots and demo GIF (demo mode + tour, ~2 min)
```

The screenshots and GIF in this README were generated by `scripts/readme-media.sh`: the app runs in demo mode, visits each page and captures its own window (no Screen Recording permission needed). It replaces every folder outside system locations with a fake project, but process names stay real, so check captures before sharing them (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Roadmap

### In progress (epic `devtools`)

- ✅ `corescope` command-line tool: ports, kill-port, agents, orphans.
- ✅ Optional local MCP server so Claude Code and Codex can ask about ports and resources and stop the processes they started.
- ✅ Dev space cleaner.
- ✅ Stuck-agent detection.
- ✅ Service health checks.
- ✅ Environment profiles.
- ✅ Local databases.
- ✅ SSH machines.
- Battery and energy per process.

### Backlog

- **More agents with titles and status:** Cursor, Gemini CLI and Aider sessions with the same title, working/idle state, project and actions that Claude Code and Codex already have.
- **Windows and Linux versions:** the Rust core is portable in spirit, but process, port and disk readers are macOS-specific (libproc, IOKit) and the app is SwiftUI. A multi-platform build needs per-OS readers (e.g. `/proc` on Linux, Toolhelp/IP Helper on Windows) and a cross-platform UI.
- Notarized releases and a universal (Intel) build.
- Validation on Intel Macs and macOS 14.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for build and test commands, code style and the project principles (local-only, public APIs only).

## License

[MIT](LICENSE) © 2026 Tiago Padilha
