#!/bin/bash
# Prints GitHub release notes for a version: its CHANGELOG.md section, the commits since
# the previous tag, install / first-launch steps and the checksums from dist/.
# Usage: scripts/release-notes.sh <version> [ref]   (ref defaults to v<version>, else HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: release-notes.sh <version> [ref]}
REF=${2:-v$VERSION}
git rev-parse -q --verify "$REF^{commit}" >/dev/null || REF=HEAD
PREV=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$REF^" 2>/dev/null || true)
DMG="CoreScope-$VERSION-macos-universal.dmg"

# Lines under "## [<version>]" up to the next version heading or the link references.
SECTION=$(awk -v v="## [$VERSION]" '
  index($0, v) == 1 { on = 1; next }
  on && (/^## \[/ || /^\[[^]]*\]: /) { exit }
  on { print }' CHANGELOG.md | sed -e '/./,$!d')
if [ -z "$SECTION" ]; then
  echo "CHANGELOG.md has no entries under ## [$VERSION]" >&2
  exit 1
fi

echo "$SECTION"
echo
if [ -n "$PREV" ]; then
  echo "### Commits since $PREV"
  echo
  git log --no-merges --reverse --format='- %s (%h)' "$PREV..$REF"
  echo
  echo "**Full diff:** https://github.com/Tiagospem/corescope/compare/$PREV...v$VERSION"
  echo
fi
cat <<EOF
### Install
1. Download **$DMG** below (Apple Silicon, macOS 14+).
2. Open the DMG and drag **CoreScope** to **Applications**.
3. The app is open source and signed ad hoc, **not notarized by Apple**, so macOS blocks it the first time. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Alternatively, in Terminal:
   \`\`\`bash
   xattr -dr com.apple.quarantine /Applications/CoreScope.app
   \`\`\`

Intel Macs are not supported by this binary; build from source with \`./scripts/build.sh\` (untested on Intel).
EOF
if [ -f dist/SHA256SUMS.txt ]; then
  echo
  echo "### Checksums (SHA-256)"
  echo '```'
  cat dist/SHA256SUMS.txt
  echo '```'
  echo "Verify with \`shasum -a 256 -c SHA256SUMS.txt\` in the download folder."
fi
