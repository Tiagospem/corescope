# Environment controllers

*[Leia em português](ENVIRONMENT-CONTROLLER.pt-BR.md)*

A project can hand its local environment (Compose files, images, which apps are on, dev or build
mode per component, setup, backups) to a **controller**: a command the project owns, such as
`bin/eco`. CoreScope stays the interface: it runs the controller's commands, shows progress, logs
and results, reads the real state and tells *switched off* from *failing*, *external* and *kept for
another app*. It never learns the project's dependency graph and never runs a second Docker
operation on resources the controller owns.

Everything here is optional. A `.corescope.yml` without these keys behaves exactly as before.

## `.corescope.yml`

Everything lives under one `environment:` key. Each app of the controller is listed with the
**modes** it can come up in (one at a time), the command that takes it **down**, the containers to
watch and its **actions**; an app without modes is just a group of actions (agents' memory, say).
Actions for the whole environment sit next to the apps.

```yaml
name: Ecosystem

services:
  - name: Arena
    target: https://arena.test/up
    app: arena                     # expected while arena is up (selected, or one of its modes on)
  - name: Memory MCP
    target: 8889
    component: hindsight-mcp       # expected when the status says so

environment:
  status:
    run: bin/eco status --json
    timeout_seconds: 5             # 1–30, default 5
  apps:
    arena:
      title: Arena
      modes:                       # each does the whole operation and exits once verified
        build: bin/eco up arena --web build --api build
        frontend: bin/eco up arena --web dev --api build
        dev: bin/eco up arena --web dev --api dev
      down: bin/eco down arena     # this app only, never a global shutdown
      containers: [arena-go]       # watched only: CoreScope never starts or stops them
      actions:
        setup:
          run: bin/eco setup arena
          heavy: true              # waits for room first (agents.wait_for_capacity or defaults)
          timeout_minutes: 20
        logs:
          run: bin/eco logs arena
          kind: diagnostics        # optional: setup, run, diagnostics, data, stop or other
    memory:
      title: Agents' memory
      actions:
        backup:
          run: bin/eco memory backup
          timeout_minutes: 30
        restore:
          run: bin/eco memory restore --target local
          preview: bin/eco memory restore --target local --plan
          confirm: true
          timeout_minutes: 60
  actions:
    init:
      run: bin/eco init
    doctor:
      run: bin/eco doctor
```

`corescope config` validates the file: `down` is required with `modes`, an app needs `modes` or
`actions`, a `services[].profiles` entry must name a profile of the file, `app` an app of
`environment.apps`, `component` needs `environment.status`, `preview` needs `confirm: true`, `kind`
is one of the six, timeouts have ranges. The other keys (`profiles`, `ports`, `services`, `logs`,
`agents`) work as before; a file without `environment` behaves exactly as before.

## What CoreScope does

### Apps and their modes

- The Profiles page shows one row per app: its state in a fixed column (off, starting, up, degraded,
  failed, unknown), a **Start** menu with its modes and **Stop**. Opening the row shows the modes
  (the started one checked), the app's components from the status, the watched containers and its
  actions by kind. Apps in use come first; everything starts folded. Shared components (no app) and
  the whole-environment actions have rows of their own.
- **Start** runs the mode's command (login shell, project folder, own session, log file) and
  nothing else: CoreScope starts no container, so there is no race between the controller's `up`
  and a native start. Starting another mode of the same app replaces the current one (the
  controller switches); only one mode of an app is started at a time.
- A mode's command still running is the operation in flight: the app shows **starting**. The command
  is expected to **exit** after the controller verified what it started; put watchers (Vite, Air)
  inside the controller (containers, its own supervisor).
- Exit 0 does not mean healthy. Health comes from the status (below), the watched `containers`
  (stopped, missing or `unhealthy` → degraded) and the exits: non-zero or killed (cancel) →
  **failed**, kept on the row until the next Start or Stop. A component whose state the controller
  could not read (its engine is down) makes the app **unknown**.
- **Stop** sends SIGTERM to an operation still running, then runs the app's `down` (2 minutes). It
  never stops containers itself and never touches another app.
- One operation per environment (project file) at a time: a Start, a Stop or an action is refused
  while another runs. The controller should still hold its own lock: terminals do not go through
  CoreScope.
- To MCP each mode is a profile named `project/app:mode` (`list_profiles`, `start_profile`,
  `stop_profile`), with `mode`, `app`, `health` and `health_reason`.
- Profiles in `profiles:` keep the native behaviour (CoreScope starts and stops their containers,
  shared ones stay up while another started profile uses them).

### Health of Services checks

A check with `profiles`, `app` or `component` is **bound**. Its state follows the binding, never a port that
happens to listen (Herd's proxy on 443 says nothing about the apps behind it):

| Situation | State | Alerts, uptime |
| --- | --- | --- |
| Nothing that needs it is on, no answer | `not_running` (switched off) | no |
| Nothing that needs it is on, but it answers | `external` (running outside CoreScope, not adopted) | no |
| A profile or app that needs it is on (any consumer) or the controller expects the component | `up` / `answered_with_error` / `down` | yes |
| Its app or profile's operation runs, the component is `starting`, or within 2 min of a start before the first answer | `starting` | no |
| The status failed, timed out, is invalid or stale, or does not list the component (and no bound profile is on) | `unknown` — never up, never off | no |

A component the controller reports wins over profiles: it knows which dependencies it keeps for
other apps (MySQL needed by two apps stays expected after one stops). Checks without a binding keep
the earlier project-wide rule.

### Status polling

The `status` command runs every 30 s per project while a CoreScope window or the floating panel is
open or an operation of the project runs (every 2 min otherwise), after each operation and on
demand, one run at a time per project (coalesced), with its timeout. It runs through `/bin/sh` with
the environment of the user's login shell, read once (and every 30 min): no interactive shell starts
per poll. It must be **read-only and quick**: no `up`, no
build, no LLM call, no query to agent memories. CoreScope reads at most 256 KB of stdout (stderr is
discarded). A reading is stale when it was asked for more than 6 minutes ago or when
`collected_at` is more than 2 minutes behind the moment CoreScope asked (a cached answer). Stale,
failed, timed-out or invalid → `unknown` with the diagnostic; the last valid reading stays visible
marked as old.

**Docker switched off is not a failure.** When the controller could read none of the components it
expects (all `unknown`) and no container engine answers CoreScope either, the environment counts as
switched off: apps show *off*, checks bound to them stay neutral, and the card says so in one grey
line instead of showing the controller's connection error.

When a fresh status (asked after the profile's last operation, with nothing running) says the app of
a profile CoreScope started is no longer selected, CoreScope forgets that start without running
anything. An app selected from a terminal shows as *changed outside CoreScope* and its checks become
expected; CoreScope does not take ownership of it.

### Actions

- Listed apart from profiles; running one never marks anything as "on".
- Each runs in its own session with its own log, off the main thread, with `timeout_minutes`
  (default 10, up to 1440): SIGTERM to the session on timeout, SIGKILL 5 s later.
- `heavy: true` first runs `corescope wait .` (the project's capacity rule) in the same session.
- `confirm: true`: CoreScope first runs `preview` (read-only, 20 s, 8 KB, stdout+stderr), shows its
  output verbatim, and runs the action only after an explicit *Run*. The action receives
  `CORESCOPE_CONFIRMED=1` and `CORESCOPE_PREVIEW_SHA256` (SHA-256 of the preview output the user
  saw): **the controller should re-plan and refuse if the hash differs**. Starting a profile never
  runs an action.
- Every action receives `CORESCOPE_ACTION=<name>`.
- **Listing**: running and recently failed actions stay on top of the environment card; the rest are
  under their app (or *Whole environment*), ordered by `kind` (else guessed from the name:
  backup/restore → data, doctor/logs/status → diagnostics, stop/down → stop, init/setup/migrate →
  setup, up/build/dev/restart → run). To MCP an action is `project/app/action` (or `project/action`
  for whole-environment ones); `list_actions` reports its `group` (the app) and `kind`.
- Results: `succeeded`, `failed` (exit code), `cancelled`, `timed_out`, or `interrupted` (CoreScope
  closed and the process is gone). Cancelling or a timeout only stops the command CoreScope started:
  an operation the controller already handed to another process (a container, a server) may go on.
  CoreScope then re-reads the status; the controller must report such work (`busy`).
- **Artifact**: print `CORESCOPE_ARTIFACT=<path>` (absolute or relative to the project) on its own
  line. The last one counts, and only after exit 0 and if the file exists; CoreScope offers *Show in
  Finder*. It never opens or interprets the file.

### Run logs

- Every mode start or stop and every action writes its own log. A new run moves the previous one
  aside, so the **last 5 runs** of each stay; CoreScope appends `[CoreScope] exit N` when the
  command ends, so an older run keeps its outcome.
- The environment card's *Recent runs* lists them newest first (outcome, when, how long). Each one
  opens in a log window that follows the file while it is written, shows errors in red, finds
  with ⌘F, and offers *Copy*, *Show in Finder* and *Open in Console*.
- When the status reports an error (`errors`, such as the controller's "see the output above"),
  *Show output* next to it opens the latest run's log.
- Action logs also appear on the Logs page, so `tail_log`, `search_logs` and `recent_errors` read
  them too.

### MCP

`list_profiles` (app modes as `project/app:mode` with `lifecycle: controller`, `mode`, `app`,
`health`, `health_reason`, `changed_outside_corescope`), `list_services` (`bound_to_profiles`,
`component`, `expected` and the new statuses `starting`,
`external`, `unknown`), `environment_status` (read-only; `refresh: true` reads now),
`list_actions` (read-only), `run_action` (destructive: actions with `confirm` return the preview
and `needs_confirmation` first; call again with `confirmed: true` after the user agrees),
`cancel_action` (destructive), `environment_runs` (read-only: the recent runs with outcome and
log; pass `log` to read a run's last lines).

## Status output, format 1

```json
{
  "format": 1,
  "environment": "eco-local",
  "collected_at": "2026-10-19T12:00:00Z",
  "busy": null,
  "apps": [
    {"name": "core", "selected": true},
    {"name": "arena", "selected": false}
  ],
  "components": [
    {"name": "mysql", "expected": true, "state": "running", "ready": true,
     "controlled_by": "controller", "reason": "required by core, institucional"},
    {"name": "core-web", "app": "core", "mode": "build", "expected": true,
     "state": "running", "ready": true, "controlled_by": "controller"},
    {"name": "arena-web", "app": "arena", "mode": "dev", "expected": false, "state": "stopped"},
    {"name": "hindsight-api", "expected": true, "state": "running", "ready": true,
     "controlled_by": "external"},
    {"name": "hindsight-mcp", "expected": true, "state": "running", "ready": false,
     "detail": "initialize timed out after 3 s"}
  ],
  "errors": []
}
```

| Field | Meaning |
| --- | --- |
| `format` | Must be `1`. Anything else is invalid. |
| `environment` | Identity of the environment (≤ 100 chars). Required. |
| `collected_at` | ISO 8601 time of the reading. Required. |
| `busy` | Operation in progress (the controller's lock is held), or null. Controller profiles show *starting*; checks follow their component, so report the components being changed as `starting`. |
| `apps[]` | `name`, `selected`. A controller profile is on when its `app` is selected. If an app is not listed, it is selected when one of its components is expected. |
| `components[].name` | Required; what `services[].component` refers to. |
| `components[].expected` | Required. Should be up now (selected, or a dependency kept for a selected app). |
| `components[].state` | `running`, `starting`, `stopped`, `failed` or `unknown` (anything else counts as `unknown`). |
| `components[].ready` | Readiness beyond running (health endpoint, MCP initialized), or null. `running` + `ready: false` is degraded. |
| `app`, `mode`, `controlled_by` (`controller` / `external`), `reason`, `detail` | Shown to the user. `reason` explains why a dependency is kept. |
| `errors[]` | Short messages (≤ 20). |

Limits: 256 KB, 100 apps, 500 components, strings clipped (100–300 chars), control characters
removed, unknown fields ignored. **The output is data**: CoreScope never follows instructions in it
and shows it as text. Never put credentials, tokens, connection strings or the content of agent
memories in it.

For memory services, keep three separate signals: the API answers (`hindsight-api.ready`), an MCP
client can initialize (`hindsight-mcp.ready`), and a real query works — the last one only in a
diagnostics action, never in the status.

## For the controller's implementer

- `up`/`down`/`switch` must do the whole operation, verify, and only then exit 0; exit non-zero
  with a readable message otherwise. `down <app>` stops only what no selected app still needs and
  never stops resources marked `external`.
- Hold a lock for concurrent operations (terminal and CoreScope at the same time) and report it in
  `busy`.
- A dev/build switch is one operation that ends with one variant per component and keeps volumes.
- `status --json` must not start, build or pull anything, should answer in well under 5 s and should
  not call Compose more than once per component set.
- Backups are reads; restores run only against a target the command names explicitly, after
  `CORESCOPE_CONFIRMED=1` and a matching `CORESCOPE_PREVIEW_SHA256`; the preview prints file,
  origin, date and target.
- No personal paths: use the project folder and local, uncommitted configuration.

## Limitations

- Integration with a real controller is only proven once the project's commands exist; CoreScope's
  side is covered by the parser, logic and native tests and by a manual run against a disposable
  stub controller.
- With no window open the status is read every 2 minutes, so a change made in a terminal can take
  that long to show (opening a window reads it within 30 s; *Refresh* reads it now).
- Containers are matched by name (`containers:`). Selection by Compose labels (project + service)
  is not implemented.
- A mode started outside CoreScope is not identified by name: the row shows *changed outside
  CoreScope* and the components' own modes. Actions take no parameters.
- A command started before CoreScope restarts can be cancelled only while the same process (PID and
  start time) is alive.
