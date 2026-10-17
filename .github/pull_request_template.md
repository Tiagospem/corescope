## What changed

<!-- One topic per PR. What does this change, and why? Link the issue if there is one. -->

## How I verified it

- [ ] `./scripts/test.sh` passes
- [ ] `./scripts/build.sh` passes and I ran the app
- [ ] UI change: screenshot in demo mode (`open --env CORESCOPE_DEMO=1 build/CoreScope.app`) attached, light and dark checked
- [ ] VoiceOver / keyboard checked for new controls (icon-only buttons have an accessibility label)

## Checklist

- [ ] New user-visible strings use `L("…")` with English and Spanish entries in `native/Localization.swift`
- [ ] Still local-only: no network access, telemetry, credentials, process arguments or environment variables
- [ ] Only public macOS APIs; no root, helpers or new entitlements
- [ ] Docs/README updated if behavior, data sources or permissions changed
