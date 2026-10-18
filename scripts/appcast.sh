#!/bin/bash
# Signs the release zip with the update key and writes dist/appcast.xml (itself signed), the feed
# the app's updater reads from the latest release. Run after scripts/package.sh.
# Usage: SPARKLE_ED_PRIVATE_KEY=… scripts/appcast.sh [BASE_URL]
#   BASE_URL defaults to this version's GitHub release download folder.
# The key must match SUPublicEDKey in the built app, or nobody could install the update
# (EXPECTED_PUBLIC_KEY overrides that check for dry runs with a throwaway key).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SPARKLE_ED_PRIVATE_KEY:?set SPARKLE_ED_PRIVATE_KEY (generate_keys -x, or a CI secret)}"
PLIST=build/CoreScope.app/Contents/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
PUBLIC=${EXPECTED_PUBLIC_KEY:-$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$PLIST" 2>/dev/null || true)}
ZIP="CoreScope-$VERSION-macos-universal.zip"
[ -f "dist/$ZIP" ] || ZIP="CoreScope-$VERSION-macos-$(uname -m).zip"
BASE_URL=${1:-https://github.com/${GITHUB_REPOSITORY:-Tiagospem/corescope}/releases/download/v$VERSION}
SIGN="$(./scripts/sparkle.sh)/bin/sign_update"

swiftc -O native/UpdateLogic.swift scripts/appcast.swift -o build/appcast
DERIVED=$(printf %s "$SPARKLE_ED_PRIVATE_KEY" | build/appcast public-key)
if [ "$DERIVED" != "$PUBLIC" ]; then
  echo "SPARKLE_ED_PRIVATE_KEY does not match SUPublicEDKey in $PLIST (UPDATE_PUBLIC_KEY in scripts/build.sh)" >&2
  exit 1
fi
SIGNATURE=$(printf %s "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN" --ed-key-file - -p "dist/$ZIP")
LENGTH=$(stat -f %z "dist/$ZIP")
./scripts/release-notes.sh --changelog "$VERSION" > build/appcast-notes.md
build/appcast item "$VERSION" "$BUILD" "$BASE_URL/$ZIP" "$LENGTH" "$SIGNATURE" build/appcast-notes.md \
  > dist/appcast.xml
# Signs the feed too (SURequireSignedFeed): versions and notes cannot be swapped either.
printf %s "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN" --ed-key-file - --disable-signing-warning dist/appcast.xml
printf %s "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN" --ed-key-file - --verify dist/appcast.xml
printf %s "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN" --ed-key-file - --verify "dist/$ZIP" "$SIGNATURE"
echo "dist/appcast.xml: $VERSION (build $BUILD) → $BASE_URL/$ZIP" >&2
