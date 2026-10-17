#!/bin/bash
# Builds CoreScope and packages it for a GitHub release: a drag-to-Applications DMG,
# a zip, and SHA-256 checksums in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=1 ./scripts/build.sh
APP=build/CoreScope.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP/Contents/MacOS/CoreScope")
# Both slices in the app and the command-line tool, or the release is not universal.
for bin in "$APP/Contents/MacOS/CoreScope" "$APP/Contents/Resources/bin/corescope"; do
  lipo "$bin" -verify_arch arm64 x86_64
done
ARCH=$([ "$(echo "$ARCHS" | wc -w)" -gt 1 ] && echo universal || echo "$ARCHS")
NAME="CoreScope-$VERSION-macos-$ARCH"
rm -rf dist && mkdir -p dist/stage
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
ditto "$APP" dist/stage/CoreScope.app
ln -s /Applications dist/stage/Applications
# hdiutil occasionally fails with "Resource busy" on CI runners; retry a few times.
for attempt in 1 2 3; do
  hdiutil create -quiet -volname "CoreScope $VERSION" -srcfolder dist/stage -fs HFS+ \
    -format UDZO -ov "dist/$NAME.dmg" && break
  [ "$attempt" = 3 ] && exit 1
  sleep 5
done
rm -rf dist/stage
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -lh dist
cat dist/SHA256SUMS.txt
