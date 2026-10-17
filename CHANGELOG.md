# Changelog

All notable changes to CoreScope are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

Pull requests add their user-visible changes under **Unreleased**. When a version is
tagged, those entries move under its heading; the release workflow publishes that
section as the GitHub release notes.

## [Unreleased]

### Added
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

[Unreleased]: https://github.com/Tiagospem/corescope/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/Tiagospem/corescope/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Tiagospem/corescope/releases/tag/v0.2.0
