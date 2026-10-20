#!/bin/bash
# Builds a universal (arm64 + x86_64) WhoRuns.app and packages a distributable .dmg.
# Usage: ./make-dmg.sh [version]   (default: 1.0.0)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"

echo "==> Build arm64 (native)"
swift build -c release --scratch-path .build-arm64

echo "==> Cross-compile x86_64"
swift build -c release --triple x86_64-apple-macosx --scratch-path .build-x86

echo "==> Merge into universal binary"
mkdir -p build/universal
lipo -create .build-arm64/release/WhoRuns .build-x86/release/WhoRuns -output build/universal/WhoRuns
lipo -info build/universal/WhoRuns

STAGING="build/dmg-root"
APP="$STAGING/WhoRuns.app"
DMG="build/WhoRuns-${VERSION}.dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$APP/Contents/MacOS"

cp "build/universal/WhoRuns" "$APP/Contents/MacOS/WhoRuns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WhoRuns</string>
    <key>CFBundleDisplayName</key><string>WhoRuns</string>
    <key>CFBundleIdentifier</key><string>local.whoruns</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WhoRuns</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/" "$APP/Contents/Info.plist"

echo "==> Ad-hoc code sign"
codesign --force --sign - "$APP"

# Drag-to-Applications target inside the dmg window
ln -s /Applications "$STAGING/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "WhoRuns" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "==> Verified: $DMG"
