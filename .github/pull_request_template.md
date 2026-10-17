## What changed

<!-- One topic per PR. What does this change, and why? Link the issue if there is one. -->

## How I verified it

- [ ] `./scripts/test.sh` passes
- [ ] `./scripts/build.sh` passes and I ran the app
- [ ] UI change: quit CoreScope with ⌘Q before switching to demo mode (`open --env CORESCOPE_DEMO=1 build/CoreScope.app`), inspect/redact the screenshot before attaching (project names and path components may remain visible), and check light and dark
- [ ] VoiceOver / keyboard checked for new controls (icon-only buttons have an accessibility label)

## Checklist

- [ ] New user-visible strings use `L("…")` with English and Spanish entries in `native/Localization.swift`
- [ ] Still local-only: no network access, telemetry, credentials, process arguments or environment variables
- [ ] Only public macOS APIs; no root, helpers or new entitlements
- [ ] Docs/README updated if behavior, data sources or permissions changed
