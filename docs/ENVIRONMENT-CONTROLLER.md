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

```yaml
name: Ecosystem

profiles:
  core:
    lifecycle: controller          # the commands do the whole operation
    commands:
      - name: up
        run: bin/eco up core
        stop: bin/eco down core    # this app only, never a global shutdown
  arena-front:
    lifecycle: controller
    app: arena                     # name in the status `apps` (default: the profile's name)
    commands:
      - run: bin/eco up arena --dev web
        stop: bin/eco down arena
    containers: [arena-go]         # observed only: CoreScope never starts or stops them

services:
  - name: Arena
    target: https://arena.test/up
    profiles: [arena-front]        # expected while one of these profiles is on
  - name: Memory API
    target: http://localhost:8888/health
    component: hindsight-api       # expected when the status says so
  - name: Memory MCP
    target: 8889
    component: hindsight-mcp

status:
  run: bin/eco status --json
  timeout_seconds: 5               # 1–30, default 5

actions:
  setup:
    run: bin/eco setup
    timeout_minutes: 20
    heavy: true                    # waits for room first (agents.wait_for_capacity or defaults)
    group: core                    # optional: where the Profiles page lists it (guessed from the name)
    kind: setup                    # optional: setup, run, diagnostics, data, stop or other
  hindsight-backup:
    run: bin/eco hindsight backup
    description: Backup of the agents' memory
    timeout_minutes: 30
  hindsight-restore:
    run: bin/eco hindsight restore --target local
    preview: bin/eco hindsight restore --target local --plan
    confirm: true
    timeout_minutes: 60
```

`corescope config` validates the file: a `services[].profiles` entry must name a profile of the same
file, `component` needs `status`, `app` is only for `lifecycle: controller`, `preview` needs
`confirm: true`, timeouts have ranges.

## What CoreScope does

### Profiles with `lifecycle: controller`

- **Start** runs the profile's commands (login shell, project folder, own session, log file) and
  nothing else. No container is started by CoreScope, so there is no race between the controller's
  `up` and a native start.
- A command still running is the operation in flight: the profile shows **starting**. Commands of a
  controller profile are expected to **exit**, after the controller verified what it started. Put
  watchers (Vite, Air) inside the controller (containers, its own supervisor), not as profile
  commands.
- Exit 0 does not mean healthy. Health comes from the status (below), the observed `containers`
  (stopped, missing or `unhealthy` → degraded) and the exits: non-zero or killed (cancel) →
  **failed**.
- **Stop** sends SIGTERM to an operation still running, then runs this profile's `stop` commands
  (2 minutes each). It never stops containers itself and never runs another profile's commands.
- One operation per environment (project file) at a time: a controller profile's start or stop, or an
  action, is refused while another runs. The controller should still hold its own lock: other
  tools and terminals do not go through CoreScope.
- Profiles without `lifecycle` keep the native behaviour (CoreScope starts and stops the
  containers, shared ones stay up while another started profile uses them).

### Health of Services checks

A check with `profiles` or `component` is **bound**. Its state follows the binding, never a port that
happens to listen (Herd's proxy on 443 says nothing about the apps behind it):

| Situation | State | Alerts, uptime |
| --- | --- | --- |
| Nothing that needs it is on, no answer | `not_running` (switched off) | no |
| Nothing that needs it is on, but it answers | `external` (running outside CoreScope, not adopted) | no |
| A profile that needs it is on (any consumer) or the controller expects the component | `up` / `answered_with_error` / `down` | yes |
| Its profile's operation runs, the component is `starting`, or within 2 min of a start before the first answer | `starting` | no |
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
- **Listing**: the Profiles page shows running and recently failed actions on top and folds the
  rest by `group` (else an app named in the action, `eco-arena-setup` → arena, else a word several
  actions share after their common prefix, `eco-memory-backup` → memory, else *General*), ordered by
  `kind` (else guessed from the name: backup/restore → data, doctor/logs/status → diagnostics,
  stop/down → stop, init/setup/migrate → setup, up/build/dev/restart → run). `list_actions` reports
  the same `group` and `kind`. Components are listed by app, with apps not selected folded into one
  line.
- Results: `succeeded`, `failed` (exit code), `cancelled`, `timed_out`, or `interrupted` (CoreScope
  closed and the process is gone). Cancelling or a timeout only stops the command CoreScope started:
  an operation the controller already handed to another process (a container, a server) may go on.
  CoreScope then re-reads the status; the controller must report such work (`busy`).
- **Artifact**: print `CORESCOPE_ARTIFACT=<path>` (absolute or relative to the project) on its own
  line. The last one counts, and only after exit 0 and if the file exists; CoreScope offers *Show in
  Finder*. It never opens or interprets the file.

### MCP

`list_profiles` (`lifecycle`, `health`, `health_reason`, `changed_outside_corescope`, `app`),
`list_services` (`bound_to_profiles`, `component`, `expected` and the new statuses `starting`,
`external`, `unknown`), `environment_status` (read-only; `refresh: true` reads now),
`list_actions` (read-only), `run_action` (destructive: actions with `confirm` return the preview
and `needs_confirmation` first; call again with `confirmed: true` after the user agrees),
`cancel_action` (destructive).

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
- The status poll runs a login shell every 30 s per project with `status` (a few hundred
  milliseconds of CPU each); there is no back-off yet when the window is closed.
- Containers are matched by name (`containers:`). Selection by Compose labels (project + service)
  is not implemented.
- Mode and app selection are done by the controller's commands (profiles or actions); CoreScope has
  no dedicated mode switch and no parameterized actions.
- A command started before CoreScope restarts can be cancelled only while the same process (PID and
  start time) is alive.
