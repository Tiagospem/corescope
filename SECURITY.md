# Security Policy

CoreScope can send signals (SIGTERM/SIGKILL) to processes owned by the current user and reads local process metadata, so security reports are taken seriously.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead:
**[Report a vulnerability](https://github.com/Tiagospem/corescope/security/advisories/new)** (Security tab → *Report a vulnerability*).

Include the CoreScope version, macOS version, steps to reproduce and the impact you observed. You can expect an initial reply within 7 days.

## Scope

In scope, for example:

- Terminating a process that CoreScope should refuse to signal (another user's process, a protected system service, CoreScope's own ancestors) or the wrong process after PID reuse.
- Any network access, telemetry or credential access by the app (CoreScope is designed to be offline and credential-free).
- Collection of process arguments or environment variables, or exposure of local data beyond what the README documents.
- Memory-safety issues in the Rust core or its C adapter.

Out of scope: the absence of Apple notarization (documented), and issues that require an attacker who already runs code as your user.
