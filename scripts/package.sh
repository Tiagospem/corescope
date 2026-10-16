#!/bin/bash
# Builds CoreScope and packages it for a GitHub release: a drag-to-Applications DMG,
# a zip, and SHA-256 checksums in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
APP=build/CoreScope.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/CoreScope" | tr ' ' '-')
NAME="CoreScope-$VERSION-macos-$ARCH"
rm -rf dist && mkdir -p dist/stage
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
ditto "$APP" dist/stage/CoreScope.app
ln -s /Applications dist/stage/Applications
hdiutil create -quiet -volname "CoreScope $VERSION" -srcfolder dist/stage -fs HFS+ \
  -format UDZO -ov "dist/$NAME.dmg"
rm -rf dist/stage
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
ls -lh dist
cat dist/SHA256SUMS.txt
