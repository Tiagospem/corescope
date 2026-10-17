# Contributing to CoreScope

Thanks for helping. CoreScope is a small, native, local-only macOS monitor; contributions that keep it fast, honest and private are very welcome.

## Before you start

- **Bugs:** open an issue with the bug report template (macOS version, hardware, steps to reproduce).
- **Features:** open a feature request first for anything bigger than a small fix, so we can agree on the approach before you write code.
- **Security issues:** never in a public issue — follow [SECURITY.md](SECURITY.md).

## Build and test

Requirements: macOS 14 or later, Xcode Command Line Tools (Swift 6) and Rust/Cargo. There is no Xcode project; the scripts call `swiftc` and `cargo` directly.

```bash
./scripts/test.sh     # cargo fmt --check, cargo test, clippy -D warnings, native logic tests
./scripts/build.sh    # release build into build/CoreScope.app
# Before launching or switching modes, quit CoreScope with ⌘Q; closing its window is not enough.
# Demo mode may leave project names and path components visible; inspect and redact captures:
open --env CORESCOPE_DEMO=1 build/CoreScope.app
# For normal use, run this INSTEAD of the demo command (quit CoreScope with ⌘Q first):
# open build/CoreScope.app
```

`./scripts/test.sh` and `./scripts/build.sh` must both pass before you open a pull request. Use demo mode for any screenshot or recording you attach, but note that project names and path components may remain visible. Inspect and redact captures before sharing.

## Where things live

| Directory | Role |
|---|---|
| `core/src/macos.c` | Thin C adapter over public SDK APIs (libproc, Mach, sysctl, IOKit, NVMe SMART) |
| `core/src/lib.rs` | Rust core: sampling, history, diagnostics, process classification, safe signaling, C ABI |
| `native/` | SwiftUI + AppKit app (window, menu bar extra, floating panel, agents, localization) |
| `native/NativeLogic.swift` | Pure Swift logic covered by `tests/native-tests.swift` |
| `docs/` | Architecture, API sources, validation and measurement notes (`*.pt-BR.md` are the Portuguese originals) |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the FFI contract and sampling cadences.

## Principles

These are not negotiable, because they are what CoreScope is:

- **Local only.** No network access, telemetry, accounts or update checks. Don't read credentials or tokens, not even to show a usage limit.
- **Public APIs only.** No private or undocumented frameworks, symbols or entitlements, no root, no privileged helpers, no SIP or security changes. If a value has no public source, show it as unavailable instead of guessing.
- **No process arguments or environment variables.** Working directories and ports are read only for the user's own processes.
- **Never kill automatically.** Every termination is user-initiated, targets only eligible processes, and revalidates identity (PID + start time + executable) right before signaling.
- **Honest metrics.** Missing data stays missing (never a simulated zero), and each value keeps its source and timestamp.
- **Cheap to run.** The monitor must not become the thing slowing the Mac down. Avoid periodic shell commands when an API exists, and keep per-sample work bounded.

## Code style

**Match the surrounding code.** Follow the naming, comment density and idioms of the file you are editing rather than introducing a new style. Keep changes focused; don't reformat unrelated code.

**Rust (`core/`)**

- `cargo fmt` and `cargo clippy -- -D warnings` must be clean (`./scripts/test.sh` checks both).
- Keep dependencies minimal (currently `serde`, `serde_json` and `cc` for the build). Discuss any new crate in an issue first.
- No panics across the C ABI. Strings returned to Swift are freed exactly once with `cs_free`.

**Swift (`native/`)**

- Use `@ViewState` instead of `@State`. It is a typealias for `SwiftUI.State` (see `native/Models.swift`): the Command Line Tools SDK ships a `State` macro without its plugin, so plain `@State` doesn't build.
- **Every user-visible string goes through `L("…")`** with a Portuguese source key, and needs an English and a Spanish translation in `native/Localization.swift` (one `pt ¦ en ¦ es` line per entry). `%@` placeholders take arguments in order.
- Prefer system fonts, SF Symbols and native controls. Never rely on color alone: pair it with a label or symbol.
- Give icon-only buttons an `.accessibilityLabel(…)` (plus `.help(…)` for the tooltip), and charts or meters a label and value VoiceOver can read.
- Rows that render for every process shouldn't observe `Monitor` or `Preferences` (see `KillButton`), so hundreds of rows don't re-render on every snapshot.
- Logic that can be tested without SwiftUI goes in `native/NativeLogic.swift`, with a check in `tests/native-tests.swift`.

## Recording the demo GIF

The GIF at the top of the README is recorded in demo mode, which keeps live metrics and anonymizes some user details. Project names and path components may remain visible, so inspect and redact captures before sharing. Keep it short (about 15 s) and under ~3 MB.

1. Build, and start a throwaway server you can safely terminate on camera:

   ```bash
   ./scripts/build.sh
   mkdir -p /tmp/corescope-demo && cd /tmp/corescope-demo && python3 -m http.server 8765 --bind 127.0.0.1
   ```

2. In another terminal, first quit any running CoreScope instance with ⌘Q (closing its window is not enough), then open CoreScope in demo mode and in English (`-language en` applies to this launch only and is not saved):

   ```bash
   open --env CORESCOPE_DEMO=1 build/CoreScope.app --args -language en
   ```

3. Press ⇧⌘5 → *Record Selected Portion*, frame the CoreScope window and record:
   - **Processes** (⌘2): the tree view; expand one app to show its children and Σ totals.
   - Type `8765` in the search field, click ✕ on the `Python` row, then **Terminate**; wait for the toast.
   - Clear the search and open **Agents** (⌘3) for a couple of seconds.

4. Convert the single recording you want to use to an optimized GIF (requires `ffmpeg`; replace the example path with that recording's exact filename):

   ```bash
   ffmpeg -i "$HOME/Desktop/Screen Recording.mov" -vf "fps=12,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 docs/screenshots/demo.gif
   du -h docs/screenshots/demo.gif   # over ~3 MB? lower fps to 10 or scale to 800
   ```

5. Uncomment the demo GIF block at the top of `README.md`, and check the GIF frame by frame for anything private before committing.

## Pull requests

1. Branch from `main` (it is protected, so all changes land through PRs).
2. Keep each PR to one topic, and describe what changed and how you verified it.
3. Run `./scripts/test.sh` and `./scripts/build.sh`.
4. For UI changes, quit CoreScope with ⌘Q before switching to demo mode, then attach a screenshot and inspect/redact it first—project names and path components may remain visible. Note light/dark mode and VoiceOver if you checked them.
5. Update the docs or README when behavior, data sources or permissions change.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
