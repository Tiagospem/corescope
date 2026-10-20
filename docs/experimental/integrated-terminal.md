# Integrated terminal: prototype report (2026-10-20)

**Recommendation: don't ship.** Park it. "Open in terminal" covers the need without adding any cost.

## Where the work is

- The worktree `.claude/worktrees/wonderful-lalande-7eb0b9`, on top of `95dbb36` (feat/editor-sync-databases). Nothing is committed, pushed or released.
- The full diff is in `integrated-terminal-prototype.patch` next to this file. Apply it with `git apply` on 95dbb36.
- `./scripts/build.sh` builds it. Turn it on in Settings › Editor and terminal › "Integrated terminal in projects (experimental)". It's off by default. MCP: `set_setting projects_integrated_terminal true`.

## What was built

- **Vendoring, option (b):** `scripts/swiftterm.sh` downloads SwiftTerm **v1.20.0** (MIT), checks its sha256, and builds the macOS sources into `libSwiftTerm.a` plus the module under `build/vendor/`, once per architecture, the way Sparkle is handled. `build.sh` links the library and ships `Resources/Licenses/SwiftTerm.txt`. The Metal renderer is compiled but stays off, and no shader bundle ships.
- **Pane:** a header button in the project changes view, next to "Open in terminal". It opens a bottom split (`VSplitView`) with one login shell (`-zsh -l`, argv[0] `-zsh`) in the project folder.
  - The environment is CoreScope's own, plus `TERM=xterm-256color` and `TERM_PROGRAM=CoreScope`.
  - The pane bar has hide (the shell keeps running) and close (ends the shell).
  - ⌘C, ⌘V, ⌘A and ⌘F are handled in the view, so they work whether or not the app menu routes them.
  - Colors follow light and dark: the system text and background colors, plus two 16-color ANSI palettes (a darker one for light mode).
- **Lifecycle:**
  - Closing the pane, or the project's own window, ends the shell with SIGHUP (SIGKILL after 2 s). It asks first only while a command is running (`proc_listchildpids`), like Terminal.
  - Quitting CoreScope asks the same way (`applicationShouldTerminate`), then hangs up every shell.
  - Hiding the pane or going back to the project list keeps the shell running, with nothing drawn.
- **Rendering stops when hidden:** the view leaves the window, and it is set hidden while the window is occluded or minimized.
- **Process origin:** core `host()` now knows `CoreScope.app/Contents/MacOS/CoreScope` (kind terminal). Shells and everything they start show origin "CoreScope" in Processes. A new test checks this and checks that they are never orphan evidence.
- **Own cost (app.cost):**
  - Shells are left out of the "children" part of CoreScope's cost.
  - When SwiftTerm reaps a shell, the RUSAGE_CHILDREN jump is excluded. Without this, everything the user ran in the terminal would be billed to CoreScope.
  - A new "Integrated terminal" feature row shows the parse CPU. It is left out of the "too much" verdict.
- **MCP:** `list_terminals` (read-only: folder, PID, shell, title, directory, shown, running commands), plus `projects_integrated_terminal` in get_settings and set_setting.
- **Localization:** 12 pt ¦ en ¦ es rows.
- **Checks:** `scripts/test.sh` passes (fmt, 115 Rust tests, clippy, native assertions). `./scripts/build.sh` passes.

## Build impact

| | (b) chosen: `swiftterm.sh` → static lib | (a) sources under `native/vendor/SwiftTerm` |
|---|---|---|
| First build on a fresh checkout | +36 s per arch (download + compile, ~1 GB compiler RSS), ×2 for UNIVERSAL | — |
| Every later build | +0 (cached). App Swift step 142–239 s vs 149–176 s baseline: noise on a loaded Mac | +~37 s per arch every build |
| Repo | +53-line script | +~36 k lines of Swift (macOS subset) + LICENSE |
| Other | — | Same module as the app: SwiftTerm's `Color`, `Terminal`, `Buffer`… collide with SwiftUI and app types, so it needs its own module step anyway |
| Binary (arm64) | 19.19 → 21.58 MB (**+2.4 MB, +12 %**, __TEXT +1.2 MB); universal ≈ +4.8 MB | same |

## Measured cost

Setup: side-by-side copies with their own bundle ids. MCP socket, history and settings backup were off, so the user's running CoreScope was untouched. Each copy had its main window open on the CoreScope project, with 60 s of warm-up and 120 s windows. CPU is the process's own CPU time.

| Scenario | CPU (% of a core) | Footprint |
|---|---|---|
| Baseline 95dbb36, project view open, idle | 1.80 / 1.70 | ~164 MB |
| Prototype, flag on, no shell | 1.54 / 2.04 | 105–123 MB |
| Prototype, pane shown, idle shell | 1.68 / 1.70 | 100–105 MB |
| Prototype, pane hidden, idle shell | 1.64 | 125 MB |

**Idle cost is within noise.** Nothing ticks: SwiftTerm has no timers, and the shell is blocked on read.

`yes | head -n 2000000` (6 MB through the pty, about 1.5 M reads of ~4 bytes):

- **Mac at low load: 2.0 s wall, 5.2 s CPU** (~260 % of a core: pty reader thread plus main-thread parsing). That's the same with the pane shown, hidden, or the window minimized, so **parsing is the cost, not drawing**.
- **Mac under load** (load average 80–90 from php84 and OrbStack): 6.3–14.7 s wall, 10–13 s CPU.
- For reference: a bare SwiftTerm window does the same run in 2.3 s, and the headless parser in 0.95 s.
- **Memory:** peak RSS is 320–420 MB during a run. Before the fix, footprint stayed at 250–380 MB afterwards: freed small buffers held by the allocator, not a leak (heap shows no SwiftTerm objects left). With relief after a burst (`malloc_zone_pressure_relief`, 3 s after output stops, and on shell exit), it's back to **103 MB within 8 s**.
- **app.cost after two runs:** "Integrated terminal" shows 1.3–2 % (5-minute average). Before it was excluded, the 5-minute average put CoreScope into "too much".
- WindowServer also composites the scrolling. That CPU isn't counted in CoreScope's own cost.

## Bugs found on the way (fixed in the prototype)

1. **Mine:** I billed every read to CostMeter, whose per-feature list is pruned linearly on each record. With 1.5 M reads that's quadratic, and the main thread was saturated for minutes. One measurement copy disappeared mid-run with no crash report, most likely force-quit as a hung app. Fixed by summing locally and recording once a second.
2. **Upstream SwiftTerm 1.20.0:** `LocalProcess.drainReceivedData` runs `removeFirst(32)` on its chunk backlog every 32 chunks. With tiny chunks and a backlog of up to 4 MB (about 1 M chunks), that's an 8 MB memmove per 128 bytes. It's quadratic as soon as the main thread falls behind, which is exactly what happens inside CoreScope (busier main thread) and not in a bare window. `swiftterm.sh` carries a one-line patch: compact only once at least half the backlog is consumed. The script checks the patch applied. v1.99.0 (11 days old) rewrote the whole I/O pipeline, so the bug may be gone there, but it's a big, very fresh change. This is worth reporting upstream.
3. **Close path:** `close()` dropped the last reference right after SIGHUP, which could leave the shell unreaped (a zombie). Closing shells are now kept until SwiftTerm reaps them. Checked: no children left after close, and nothing left (shell, `yes`, `head`) after CoreScope is killed.

## Not verified

- **No hands-on UI pass.** UI control of the test copies was declined, so the pane was driven by a signal hook compiled only into the measurement binary (never in the repo). Not tried by hand:
  - ⌘C, ⌘V, ⌘A and ⌘F (find bar);
  - light and dark colors;
  - split resizing;
  - the close and quit confirmation alerts.
- `list_terminals` was run through the same `describe()` code, but not end to end via `corescope mcp`.
- The quit prompt path (`applicationShouldTerminate` with a busy shell). The SIGTERM path is verified.
- UNIVERSAL build.
- VoiceOver.

## Risks

- **It moves the user's work into CoreScope's process.**
  - Parsing runs on CoreScope's main thread: a chatty dev server or build log in the pane costs CPU there and competes with the UI.
  - Activity Monitor and macOS energy attribute that CPU to CoreScope, so it can become the top energy process again. That's exactly what the user worked to undo.
  - Leaving it out of app.cost's verdict doesn't change what the OS shows.
- **Shells die with CoreScope.** A crash, a Sparkle update relaunch (it asks first) or a quit takes down the dev servers started in the pane.
- **Memory spikes:** 300–400 MB during big bursts, against CoreScope's own 500 MB "too much" line. Relief brings it back in seconds.
- **Maintenance:** SwiftTerm moves fast (1.20 → 1.99 in two months, with an I/O rewrite). We'd carry a patch, and users will ask for tabs, splits, fonts and profiles.
- **Edge case:** the same project shown in the main window and in its own window shares one shell. Closing the project window ends it in both.

## Recommendation

**Don't ship.** The prototype works and costs nothing at idle. But the cost appears exactly when the terminal gets used: CoreScope's CPU, energy and memory, and the session's lifetime is tied to the monitor app. "Open in terminal" already covers the need at zero cost.

If it's wanted later, ship it only as experimental after three things:

1. The SwiftTerm fix is upstream, or we're on a release with the new pipeline.
2. A hands-on UI pass.
3. Ideally, parsing moved off the main thread (SwiftTerm's `LocalProcess` takes a `dispatchQueue`; the view would then need thread-safe feeding).
