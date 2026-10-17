# Changelog

All notable changes to CoreScope are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

Pull requests add their user-visible changes under **Unreleased**. When a version is
tagged, those entries move under its heading; the release workflow publishes that
section as the GitHub release notes.

## [Unreleased]

### Added
- **Claude Code 5-hour and weekly limits** (opt-in, off by default) in the limits card,
  menu bar, popover and floating panel, read from the `rate_limits` data Claude Code
  passes to its status line. Turning it on adds a `statusLine` command to
  `~/.claude/settings.json` only when none exists (backed up first; an existing one is
  chained only on request); turning it off restores the previous value. No Keychain,
  credentials or network.

### Fixed
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
