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
open build/CoreScope.app                          # normal use
open --env CORESCOPE_DEMO=1 build/CoreScope.app   # or: demo mode, for screenshots
```

`open` reuses a running instance and its environment, so quit CoreScope with ⌘Q (closing the window is not enough) before switching between normal and demo mode.

Demo mode replaces your user name and agent session titles, and maps every working directory and executable outside system locations (home subfolders and `/Volumes/…` alike) to `/Users/dev/code/<fake project>`, so `~/code/client-x` shows up as something like `acme-api`. System paths (`/System`, `/usr`, `/Applications`, `/Library`…) stay readable. Process names come straight from macOS, so a binary named after a project still shows that name; inspect every capture before sharing.

`./scripts/test.sh` and `./scripts/build.sh` must both pass before you open a pull request. Use demo mode for any screenshot or recording you attach.

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

- **Local only.** No network access, telemetry or accounts. The only requests are opt-in and off by default: Services checks the user points outside the Mac, and the daily update check (Settings › Updates), which contacts only the release feed. Don't read credentials or tokens, not even to show a usage limit.
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

`./scripts/readme-media.sh` regenerates the README screenshots (`docs/screenshots/*.jpg`) and the
GIF (`docs/screenshots/demo.gif`). It quits any running CoreScope, opens the built app in demo mode
with `CORESCOPE_TOUR` set, waits for charts, tokens and containers to load, visits Overview,
Processes, Agents, Containers and History, and writes each page from the app's own window at 2×
(no Screen Recording permission). The sidebar is hidden in these captures because its translucent
material cannot be rendered offscreen.

Demo mode replaces your user name, folders, project names and session titles, but process and
container names stay real: inspect the images before committing them. Set `WARMUP=<seconds>`
(default 75) for a longer warm-up.

## Releases and updates

Pushing a tag `v<version>` runs `.github/workflows/release.yml`: it builds the universal app, the
DMG, the zip and `SHA256SUMS.txt`, then `scripts/appcast.sh` signs the zip and writes
`appcast.xml` (itself signed), published with the release. The app's updater (Sparkle, pinned and
checksum-verified by `scripts/sparkle.sh`) reads that appcast from the latest release. Bump both
`CFBundleShortVersionString` and `CFBundleVersion` in `scripts/build.sh` for every release: Sparkle
compares the build number.

**The update key.** An ad hoc signed app cannot rely on Apple code signing to trust an update, so
every update must be signed with the project's EdDSA key:

1. Once, on the maintainer's Mac: `build/vendor/Sparkle-*/bin/generate_keys` (after any build) —
   the private key goes to the login Keychain and the public key is printed. (Done: the key in
   `scripts/build.sh` was generated this way; keep that Keychain item backed up.)
2. Put the public key in `UPDATE_PUBLIC_KEY` in `scripts/build.sh` (it becomes `SUPublicEDKey`).
3. Export the private key with `generate_keys -x private-key.txt`, store its contents as the
   repository secret `SPARKLE_ED_PRIVATE_KEY` (`gh secret set SPARKLE_ED_PRIVATE_KEY < private-key.txt`),
   and delete the file. Never commit it. Tag builds fail without the secret, and `appcast.sh`
   refuses a key that does not match `UPDATE_PUBLIC_KEY`. Losing the key means shipped apps can no
   longer update (users would download the next DMG by hand), so keep the Keychain item backed up.

Pull requests that touch the release tooling run the same packaging with a throwaway key.

**Testing an update locally**, without publishing anything: build two copies with different
`CFBundleVersion`s, give both a test key and bundle identifier, serve the newer one's zip and appcast
from `localhost`, and point the older one at it:

```bash
build/appcast keygen                                   # after scripts/appcast.sh has run once
SPARKLE_ED_PRIVATE_KEY=… EXPECTED_PUBLIC_KEY=… ./scripts/appcast.sh http://127.0.0.1:8000
defaults write <bundle id> updateFeedURL http://127.0.0.1:8000/appcast.xml
```

`updateFeedURL` only changes where the feed is read; whatever it serves must still verify
against the app's public key. Use a different bundle identifier for test copies: CoreScope keeps a
single instance per identifier, and quit them before deleting.

## Pull requests

1. Branch from `main` (it is protected, so all changes land through PRs).
2. Keep each PR to one topic, and describe what changed and how you verified it.
3. Run `./scripts/test.sh` and `./scripts/build.sh`.
4. For UI changes, quit CoreScope with ⌘Q before switching to demo mode, then attach a screenshot and inspect it first—process names stay real. Note light/dark mode and VoiceOver if you checked them.
5. Update the docs or README when behavior, data sources or permissions change.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
