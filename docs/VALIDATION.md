# Validation — CoreScope 0.1.0

*Português: [VALIDATION.pt-BR.md](VALIDATION.pt-BR.md)*

> **Historical (v0.1.0).** This document records validation of the first native version (commit `d83bbf0`). The UI has since changed (process tree, Agents page, inline ✕ kill, new floating panel layouts); the screens, paths and observations below describe that version, and the `captures/` directory they cite is no longer in the repository. Current resource numbers are in the [README](../README.md#resource-usage).

Date: 2026-10-16. Observed host: macOS 27.0.1 arm64, 16 GiB physical, 10 logical cores. Rust 1.98.1 and Swift 6.4. Deployment target 14, with no physical validation on macOS 14 or Intel.

## Automated tests

`./scripts/test.sh`: **15 Rust tests + 6 native checks passed**. `cargo fmt --check` and Clippy with `-D warnings` passed.

Coverage: CPU ticks/normalization; Mach conversion with a real disposable load; reset counters; interval after sleep; hysteresis; history limits by count/age; valid, invalid, unavailable and denied NVMe Celsius; no false candidates from PPID/age alone; combined criteria for candidates; rejection of invalid/own PID; mismatched start time/executable; SIGTERM and SIGKILL on children created by the test; real sample; reset; FFI JSON/ownership; exact descendant set, order and cycles; off-screen panel and a screen with a negative origin.

No test signaled real work processes. The test load uses `/usr/bin/yes` spawned by the test, for 500 ms, with stdout discarded; terminations use `/bin/sleep` spawned by the test. killall/pkill/process groups are never called.

## Observed metrics

- CPU, RAM, compressor, swap and roughly 430–530 processes available during the work, with real system variation.
- Per-process CPU corrected/validated for Mach absolute time on Apple Silicon; 100% equals one core.
- Physical devices identified as APPLE SSD AP0256Z Media and KINGSTON SNV3S1000G Media. APFS volumes listed separately.
- NVMe read without root at 09:55:31: Apple **50.85 °C**, Kingston **47.85 °C**, converted from 324 K and 321 K. Point-in-time temperatures, not a thermal benchmark; original resolution 1 K.
- Memory pressure remained “waiting for event” during the session: no event was forced through artificial RAM consumption.
- Thermal state “Moderate” observed; it is not a temperature value.

## Feature status

| Feature | Implementation / validation | Limitation |
|---|---|---|
| Core and FFI | Built and exercised; Rust tests | Contract pointers must be valid; catch_unwind does not turn UB into an error |
| CPU/memory/processes | Real data and scale test | Some protected processes have no metrics/no permission |
| Diagnostics and hysteresis | Window and recovery tests | Explainable heuristics, not causal proof of slowness |
| Memory pressure | Dispatch with explicit availability | No real critical event provoked |
| Configurable menu | Native MenuBarExtra, shared data | Menu bar space depends on macOS and other apps |
| Window, filters, tree and details | Native SwiftUI; searching for CoreScope returned one result, details opened and termination of itself disabled | Tree observed; not every filter combination was exercised |
| SIGTERM/SIGKILL | Revalidation and confirmation, tests with disposable processes | Residual race between revalidation and kill; no privileged helper |
| Tree termination | Fixed list, per-target revalidation, descendant test | New children spawned after confirmation are not included |
| Abandonment candidates | Observed parent change + additional signals | No history from before launch; does not prove abandonment |
| Tracked history | Up to 12 identities; up to 120 points/10 min | Does not persist history or follow a reused PID |
| I/O and volumes | Real APIs; names of both devices checked | No latency/saturation diagnostics; inventory cached for 30 s |
| NVMe temperature | **Real read of both SSDs, without root** | SATA, incompatible bridges and adapter temperature not implemented |
| Sensor selection | Supported sensor selectable for menu/panel | IOKit ID changes after reconnection; reselection may be needed |
| Floating panel | Non-activating NSPanel, size/opacity/lock, screen UUID | Physical monitor swaps/Spaces/full screen still require a manual matrix |
| Sleep/wake | Notifications and delta reset; reset tests | We did not put the machine to sleep with the user's work active |
| Themes/accessibility | System colors/controls, keyboard, reduced transparency, no custom animations | Full VoiceOver and all contrast combinations not yet certified |
| Launch at login | Optional SMAppService, off by default | Not enabled, to avoid changing the user's session; ad hoc signing may be rejected |
| Energy | Limitation made explicit | No reliable watts/joules/Energy Impact via an integrated API |

## Remaining physical acceptance checklist

1. Drag the panel between two monitors, lock it, disconnect/reconnect a monitor, verify recovery and per-UUID preferences.
2. Switch Spaces and full-screen apps with the panel enabled; confirm it does not take focus. The flags were configured; that is not equivalent to this test.
3. Sleep and wake with the monitor on; check the gap/first sample without a delta.
4. Disconnect/reconnect an idle external disk that is safe to remove; we did not disconnect the volume holding the user's work.
5. Verify VoiceOver/Full Keyboard Access, launch at login and the minimum system on a test machine.

The limitations above are validation boundaries, not simulations or invented results.

## Exercised interface

Packaged app opened from the path `build/CoreScope.app`. Real captures in `captures/`: overview with updating histories, sensors with both NVMe drives, and CoreScope's own details. Searching for “CoreScope” narrowed the list to one result; double-clicking opened the details with origin, start time, memory and blocked termination actions. Navigation shortcuts to Processes, Settings, Overview and Sensors were exercised.

The visual review found insufficient contrast in the menu and a pause indicator that depended on the panel's thermal option. Both were fixed, rebuilt and reviewed in code; a specific recapture of those two states is still pending. See `FINISH-REVIEW.md`. Do not equate this with full visual approval of every preference.

Resource usage measured externally, with libproc deltas and a monotonic clock: methodology and results in `CONSUMPTION.md`. Accessibility queries against the full table produced visible additional cost; there were no new UI calls during the meter's windows, but a later stack sample still found accessibility requests against the table. These windows therefore do not prove a baseline free of external observers.
