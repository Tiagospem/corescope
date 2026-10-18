#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
# UNIVERSAL=1 (releases) builds Apple Silicon and Intel and joins them with lipo; otherwise only
# this Mac's architecture, for quick local builds.
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCHS="arm64 x86_64"; else ARCHS=$(uname -m); fi
rust_target() { [ "$1" = arm64 ] && echo aarch64-apple-darwin || echo "$1-apple-darwin"; }
for arch in $ARCHS; do
  cargo build --release --locked --manifest-path core/Cargo.toml --target "$(rust_target "$arch")"
done
APP="$PWD/build/CoreScope.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
# Sparkle installs updates (Settings › Updates, opt-in). Its EdDSA public key: every update
# archive and the appcast itself must be signed by the matching private key (a CI secret).
SPARKLE=$(./scripts/sparkle.sh)
UPDATE_PUBLIC_KEY="bxj8UTY/IIWBqAcQxflL60mwUToQ3Tc3PJPLkI5QluI="
APPS=() CLIS=()
for arch in $ARCHS; do
  lib="core/target/$(rust_target "$arch")/release"
  swiftc -O -swift-version 5 -target "$arch-apple-macosx14.0" -import-objc-header native/CoreScopeFFI.h native/*.swift "$lib/libcorescope.a" -lsqlite3 -framework SwiftUI -framework AppKit -framework IOKit -framework CoreFoundation -framework ServiceManagement -framework UserNotifications -framework Carbon -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "build/CoreScope-$arch"
  APPS+=("build/CoreScope-$arch")
  CLIS+=("$lib/corescope")
done
lipo -create "${APPS[@]}" -output "$APP/Contents/MacOS/CoreScope"
rm -f "${APPS[@]}"
cat > "$APP/Contents/Info.plist" <<PLIST
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
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>11</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Tiago Padilha · MIT License</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>local.corescope.app</string>
<key>CFBundleURLSchemes</key><array><string>corescope</string></array>
</dict></array>
<key>SUFeedURL</key><string>https://github.com/Tiagospem/corescope/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>$UPDATE_PUBLIC_KEY</string>
<key>SURequireSignedFeed</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST
# Sparkle.framework, re-signed ad hoc like the app; its XPC services are only for sandboxed apps.
rm -rf "$APP/Contents/Frameworks" && mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$FW/XPCServices" "$FW/Versions/B/XPCServices"
codesign --force --sign - --options runtime "$FW/Versions/B/Autoupdate"
codesign --force --sign - --options runtime "$FW/Versions/B/Updater.app"
codesign --force --sign - --options runtime "$FW"
# Command-line tool (corescope ports, kill-port, agents, mcp…), signed before the app.
mkdir -p "$APP/Contents/Resources/bin"
lipo -create "${CLIS[@]}" -output "$APP/Contents/Resources/bin/corescope"
codesign --force --sign - "$APP/Contents/Resources/bin/corescope"
codesign --force --sign - "$APP"
# Refresh LaunchServices so the Dock and Finder pick up the current icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Aplicativo: $APP"
