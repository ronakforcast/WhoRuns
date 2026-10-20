#!/bin/bash
# Builds WhoRuns and assembles a minimal, ad-hoc signed .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> swift build (release)"
swift build -c release

APP="build/WhoRuns.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/WhoRuns "$APP/Contents/MacOS/WhoRuns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WhoRuns</string>
    <key>CFBundleDisplayName</key><string>WhoRuns</string>
    <key>CFBundleIdentifier</key><string>local.whoruns</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WhoRuns</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --sign - "$APP"

echo "==> Built $APP"
echo "Install with:  cp -R $APP /Applications/  (quit any running copy first)"
