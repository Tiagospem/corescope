# Independent final interface review

*Português: [FINISH-REVIEW.pt-BR.md](FINISH-REVIEW.pt-BR.md)*

> **Historical (v0.1.0).** This review inspected the first native version (commit `d83bbf0`). The UI has since changed (process tree, Agents page, inline ✕ kill, new floating panel layouts); the screens and line numbers below (such as `native/CoreScope.swift:115`) describe that version, and the `captures/` directory they cite is no longer in the repository.

Date: 2026-10-16. Code inspected: `d83bbf0`. Scope: first functional native version of CoreScope. Read-only review of the product and the code; this document is the only file written by the reviewer.

## 1. Capture validity

The real captures provided, `captures/overview.png` (1080 × 1000) and `captures/sensors.png` (1080 × 760), were opened and inspected. There are no material crops or overlaps in these images. The sensors capture shows its own timestamp, earlier than the overview's; it validates the composition and captured content, not how current the readings were at the time of the review.

The previous menu capture was removed after the fix. No current capture of the menu or panel is available for this review. The old raster does not represent the fixed implementation. The checkpoint `overview-first.png` was not used as final evidence.

There was no UI operation, collection of new captures or interaction during the implementer's resource-usage measurement. The correspondence between the running binary and the commit was not independently verified; code inspection confirmed the HEAD above.

## 2. Adherence to the brief and the contract

The observed direction is consistent with native macOS: system fonts, SF Symbols, sidebar, conventional controls and compact content. The overview presents the diagnosis and caveat before the metrics; total CPU has a 0–100% scale and memory has an explicit definition without being called pressure. Sensors separates thermal state from temperature and shows device identification, source and timestamp of readings, as well as the lack of support for CPU/SoC temperature.

The selection appearance follows the observed system accent color. No aesthetic change was requested on the basis of personal preference. There is no approved mockup; the evaluation uses PRODUCT.md, docs/BRIEF.txt, docs/SURFACE.md and the Impeccable skill's craft floor. Web detectors were not run because the implementation is native.

The process-control code presents separate SIGTERM/SIGKILL confirmation and an explicit list of targets. This interface review does not certify signal execution or the safety of the collector's implementation.

## 3. Material findings and fixes

The two previous findings were addressed in code:

- **Menu with insufficient contrast in the previous raster:** `native/CoreScope.swift:115` now applies `Color(nsColor: .windowBackgroundColor)` as an opaque background for MenuSummary. The fix removes the dependence on the translucent material that prompted the finding. Fix confirmed by code; final rendered contrast not yet measured. The approximate 2.5:1 contrast measured earlier belongs only to the discarded capture and must not be attributed to the fixed build.
- **Stale-data notice dependent on the thermal option:** `native/Panel.swift:119` now keeps “Pausado”/“Ao vivo” (Paused/Live) in the header, outside `thermalInPanel`. The overall 0.65 dimming was removed in `native/Panel.swift:156–159`. A stale reading now has a label independent of the thermal selection. Fix confirmed by code; final state not captured.

No new material defects were found in the two current images. No new polishing round was opened.

## 4. Review limits

Visual approval is limited to the overview and sensors at the captured dimensions and in dark mode. No final visual approval for the menu, panel, processes, storage, settings, light mode, minimum size, keyboard focus, VoiceOver, increased contrast, reduced transparency or error/pause states. Implementation in code is not equivalent to testing those states.

Spaces, full screen, multiple monitors, physical disconnection and physical sleep/wake remain outside this review. Build, signing, resource usage and functional tests belong to the implementer's reports and were not repeated by the reviewer.

## 5. Single disposition

**recapture**

The two fixes are accepted by code inspection, and the current captured surfaces show no material blocker. All that is missing is rendered evidence of the fixed menu and of the paused panel with the thermal option off to close the visual findings. This disposition does not request a redesign, a rebuild or a new polishing hunt. The first functional version can ship with this visual item explicitly declared as pending; it must not be described as visually validated on every surface.
