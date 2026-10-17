#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --locked --manifest-path core/Cargo.toml
APP="$PWD/build/CoreScope.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCH=$(uname -m)
# App icon is drawn procedurally; regenerate only when the drawing script changes.
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  swiftc -O scripts/make-icon.swift -o build/make-icon
  ./build/make-icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Declared localizations let AppKit translate its own menus; UI strings live in Localization.swift.
for lang in pt en es; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  echo '"CFBundleDisplayName" = "CoreScope";' > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
swiftc -O -swift-version 5 -target "$ARCH-apple-macosx14.0" -import-objc-header native/CoreScopeFFI.h native/*.swift core/target/release/libcorescope.a -lsqlite3 -framework SwiftUI -framework AppKit -framework IOKit -framework CoreFoundation -framework ServiceManagement -framework UserNotifications -framework Carbon -o "$APP/Contents/MacOS/CoreScope"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.corescope.app</string>
<key>CFBundleName</key><string>CoreScope</string>
<key>CFBundleDisplayName</key><string>CoreScope</string>
<key>CFBundleExecutable</key><string>CoreScope</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>pt</string>
<key>CFBundleLocalizations</key><array><string>pt</string><string>en</string><string>es</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>7</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Tiago Padilha · MIT License</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.corescope.app</string>
<key>CFBundleURLSchemes</key><array><string>corescope</string></array>
</dict></array>
</dict></plist>
PLIST
# Command-line tool (corescope ports, kill-port, agents, mcp…), signed before the app.
mkdir -p "$APP/Contents/Resources/bin"
cp core/target/release/corescope "$APP/Contents/Resources/bin/corescope"
codesign --force --sign - "$APP/Contents/Resources/bin/corescope"
codesign --force --sign - "$APP"
# Refresh LaunchServices so the Dock and Finder pick up the current icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Aplicativo: $APP"
