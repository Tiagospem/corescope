#!/bin/bash
# Regenerates the README screenshots and demo GIF from the running app in demo mode
# (anonymized users, paths, projects and session titles). Takes about 2 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
# Temporary folder without spaces: `open --env` values are passed through LaunchServices.
OUT=$(mktemp -d /tmp/corescope-tour.XXXXXX)
osascript -e 'tell application id "local.corescope.app" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -f "CoreScope.app/Contents/MacOS/CoreScope" >/dev/null || break
  sleep 1
done
open -n --env CORESCOPE_DEMO=1 --env CORESCOPE_TOUR="$OUT" --env CORESCOPE_TOUR_WARMUP="${WARMUP:-75}" build/CoreScope.app
# The tour quits the app after capturing every page; give up after 6 minutes.
for _ in $(seq 1 120); do
  sleep 3
  [ -f "$OUT/overview-2.png" ] && break
done
sleep 2
pkill -f "CoreScope.app/Contents/MacOS/CoreScope" 2>/dev/null || true
[ -f "$OUT/history.png" ] || { echo "Tour did not finish; frames in $OUT"; exit 1; }
D=docs/screenshots
for page in overview processes agents containers history; do
  sips -s format jpeg -s formatOptions 85 --resampleWidth 1600 "$OUT/$page.png" --out "$D/$page.jpg" >/dev/null
done
swiftc -O scripts/make-gif.swift -o build/make-gif
./build/make-gif "$D/demo.gif" 960 2.2 "$OUT/overview.png" "$OUT/processes.png" "$OUT/agents.png" \
  "$OUT/containers.png" "$OUT/history.png"
ls -lh "$D"
rm -rf "$OUT"
