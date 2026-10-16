#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --locked --manifest-path core/Cargo.toml
APP="$PWD/build/CoreScope.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCH=$(uname -m)
swiftc -O -swift-version 5 -target "$ARCH-apple-macosx14.0" -import-objc-header native/CoreScopeFFI.h native/*.swift core/target/release/libcorescope.a -framework SwiftUI -framework AppKit -framework IOKit -framework CoreFoundation -framework ServiceManagement -o "$APP/Contents/MacOS/CoreScope"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.corescope.app</string>
<key>CFBundleName</key><string>CoreScope</string>
<key>CFBundleDisplayName</key><string>CoreScope</string>
<key>CFBundleExecutable</key><string>CoreScope</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Aplicativo: $APP"
