# Observed resource usage

*Português: [CONSUMPTION.pt-BR.md](CONSUMPTION.pt-BR.md)*

> **Historical (v0.1.0).** These measurements are from commit `d83bbf0`, the first native version. The UI has since changed (process tree, Agents page, new floating panel layouts), and the numbers below do not describe the current version. The current summary is the “Resource usage” table in the [README](../README.md#resource-usage).

2026-10-16, arm64 Mac, macOS 27.0.1, 10 logical cores, 16 GiB. Release build with Swift `-O` and Rust release, ad hoc signing. Final code `d83bbf0`. Local bundle: **2.9 MiB** (does not include toolchains/build cache).

## Method and limits

`scripts/measure.c` observes only the chosen PID via `proc_pid_rusage(RUSAGE_INFO_V4)`, once per second. It revalidates the process start time, uses a monotonic clock and converts Mach ticks to nanoseconds before dividing by the elapsed time. `100%` CPU means **one core**; on ten cores, 10% in this column is roughly 1% of total logical capacity, with no correction for performance differences between cores.

Memory is `ri_phys_footprint`, the arithmetic mean of the samples and the largest value in the window; it is neither the historical peak since launch nor just RSS. The JSON files also store the final RSS and package wakeups. **Every test had 0 attributed package wakeups per second**, but this does not mean there were no timers: interrupt wakeups are reported separately.

The machine kept running development tools and agents. It was not isolated or restarted, and work processes were not interrupted. The windows did not include new automation calls on our part, but there was interaction and selection/tree changes between observations. In addition, `sample` after the table window found calls to `mshMIGPerform`, `_AXXMIGCopyMultipleAttributeValues`, `NSTableViewCellMockElement` and cell creation. The observed cost therefore includes accessibility work and does not establish how much was caused solely by the collector or by normal UI updates. Resetting the automation session does not guarantee removal of all external observers.

The attempt to minimize/close via automation kept returning the Settings window. **We do not consider that window a proven measurement of hidden mode**, despite the historical name of the intent. No number was discarded for being unfavorable.

## Results

| Observed scenario | Duration | CPU of one core | Mean / largest footprint | Interrupt wakeups | Raw data |
|---|---:|---:|---:|---:|---|
| Final overview | 40.1 s | 2.79% | 78.4 / 112.8 MiB | 3.06/s | [consumption-final-overview.json](consumption-final-overview.json) |
| Minimize attempt; hidden state not confirmed | 40.1 s | 3.98% | 114.4 / 121.3 MiB | 2.14/s | [consumption-minimize-attempt.json](consumption-minimize-attempt.json) |
| Final full table, interactive session | 40.3 s | 33.72% | 143.9 / 151.4 MiB | 2.83/s | [consumption-final-processes.json](consumption-final-processes.json) |
| Table after automation reset, interactive session | 35.1 s | 13.94% | 160.4 / 166.2 MiB | 2.31/s | [consumption-processes-after-ui-reset.json](consumption-processes-after-ui-reset.json) |
| Initial exploration before the tree adjustment | 45.2 s | 5.20% | 110.7 / 173.7 MiB | 6.15/s | [consumption-visible.json](consumption-visible.json) |
| Table before the tree adjustment | 35.1 s | 9.43% | 153.3 / 204.0 MiB | 10.25/s | [consumption-processes-quiet.json](consumption-processes-quiet.json) |

The files named “quiet”/“final” keep the names from the collection; “quiet” means no new explicit calls on our part during the window, not certification of an idle environment. No percentage improvement should be inferred between runs with different loads, surfaces and interactions.

## Persistent history: on vs off

16/10/2026, same Mac, release build of the history branch. Each run: fresh app launch, main window on **Overview** (including the new per-core CPU and memory breakdown cards), sampling every 3 s, 20–25 s warm-up, then `scripts/measure.c` for 120 s. History was turned on only from the command line (`-historyEnabled YES`, argument domain), without changing the saved preference. The machine was loaded by builds and agents from other sessions (E cores near 100%), so the baseline sits above the 2.8% in the table above; compare these rows with each other, not with older runs.

| History | CPU (one core) | Mean / max footprint | Interrupt wakeups |
|---|---:|---:|---:|
| Off | 4.55% | 88.7 / 125.7 MiB | 3.40/s |
| On (7 days) | 4.78% | 95.0 / 135.0 MiB | 3.24/s |

Observed difference: **+0.2 CPU points** (within run-to-run variation: another run with history on measured 4.48%) and **~+6 MiB footprint** (the minute accumulator and SQLite's page cache). Writes: a single commit per minute to the WAL (the `-wal` file's mtime changes only at the minute boundary); 20 top rows per minute, deduplicated process identities (28 after 13 minutes), ~366 KB after 14 minutes with the WAL not yet recycled. Measured with the window visible; the window-closed cost (10 s cadence) was not measured in this round.

## Engineering targets and status

Targets proposed for acceptance, not previously measured requirements nor a promise of universal performance:

- Overview without interaction: mean CPU up to 5% of one core; mean footprint up to 128 MiB. The observed window was below this, but needs an isolated repeat to characterize a baseline.
- Full table without interaction: mean CPU up to 10% of one core; mean footprint up to 200 MiB and window peak up to 256 MiB. **CPU target not met in the latest windows of this session**; memory was below target. The profile requires separating AX observation from normal updates before deciding on further optimization. Do not declare every surface as approved for lightness.
- Menu bar only, window/panel hidden: mean CPU up to 1% of one core; still **not validated**. The code reduces the cadence to at least 10 s, but implementation is not evidence of the result.
- Bundle smaller than 10 MiB: observed 2.9 MiB.
- History bounded by count/time: tests pass; they do not replace a prolonged memory-stability run.
- Energy in watts/joules or Energy Impact: **unavailable**. Raw energy fields were not interpreted without a reliable unit/contract. No conclusion about battery life.

## Agent token usage (2026-10-16)

MacBook Air M4 under heavy load (load average ~70, several agent sessions compiling). Agents page open; the same renamed copy (`local.corescope.tokenstest`) for the baseline (`a854cec`) and the new build, one instance at a time.

| Measure | Baseline | With tokens |
|---|---|---|
| Mean footprint, window open (120 s / 60 s) | 72.8 MiB and 81.0 MiB in two runs | 82.3 MiB and 83.0 MiB |
| Live heap (`heap`, all zones) | 54.7 MB | 57.2 MB (+2.5 MB) |
| CPU of one core, window open | 3.4 % | 4.6–4.8 % |

- Footprint noise between runs of the same build (~8 MiB) is larger than the difference; the live heap is the more reliable comparison. The token data itself is ~30 KB (per-day buckets of ~180 files); the rest is the SwiftUI views of the new card and per-session lines.
- First pass (only once the Agents page is opened): 315–330 transcripts, 2.7 GB, ~4.5–4.8 s of CPU once; the standalone reader peaked at 7 MB footprint (one reusable buffer; long lines that cannot carry usage, like Codex's 23 MB `compacted` entries, are skipped without buffering).
- Incremental pass every 20 s: ~12 ms CPU (stat of ~315 files + only the new bytes, ~80 KB in the test) ≈ 0.06 % of one core.
- The CPU difference with the window open was not separated from the machine's noise; the incremental pass measured on its own is negligible.

## Reproduce

```sh
cd corescope
clang -O2 scripts/measure.c -o build/measure
pgrep -x CoreScope
# Replace PID with the verified value; the meter sends no signals.
./build/measure PID 60
```

For a controlled comparison: use the same build, 3 s interval, a similar number of processes, no interaction or AX capture during the window; run overview, table, menu-bar-only and panel separately. Visually confirm the state before and after. Run for a few minutes instead of extrapolating from these short windows. Do not alter the user's services to get artificially low numbers.

## Containers (ADR 003)

2026-10-16, same Mac, OrbStack with 6 running containers (5 of the user's plus a test `nginx:alpine`). `scripts/measure.c`, 60 s per window after a 20 s warm-up, alternating the previous build (`a854cec`) and the new one; with the app hidden (`NSRunningApplication.hide`) no container read happens. Other sessions were building and running CoreScope at the same time: the spread between identical windows is larger than the measured difference.

| Scenario | Build | CPU of one core | Footprint mean / peak |
|---|---|---:|---:|
| Overview visible (with the Containers card) | previous | 4.78% · 4.72% | 99.8 / 134.7 · 89.9 / 124.0 MiB |
| Overview visible (with the Containers card) | new | 5.14% · 4.35% | 93.7 / 130.8 · 92.8 / 128.7 MiB |
| App hidden | previous | 1.31% | 75.3 / 115.6 MiB |
| App hidden | new | 1.53% | 85.8 / 128.8 MiB |

A full read (list + 6 one-shot stats) takes ~70 ms of wall time, almost all of it waiting on the engine, every 5 s. Conclusion: cost not distinguishable from noise on this machine; a single hidden window is not enough to claim a memory difference.
