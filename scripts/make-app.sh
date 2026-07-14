#!/bin/bash
# Builds a distributable GitBrowser.app (universal binary) and zips it into
# dist/. Usage: scripts/make-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"

if [ -d "/Applications/Xcode.app" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "Building release (universal)…"
swift build -c release --arch arm64 --arch x86_64
BIN=.build/apple/Products/Release/GitBrowser

APP=dist/GitBrowser.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitBrowser"

echo "Generating icon…"
"$BIN" --dump-icon dist/icon-1024.png > /dev/null
mkdir -p dist/AppIcon.iconset
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" dist/icon-1024.png --out "dist/AppIcon.iconset/icon_${s}x${s}.png" > /dev/null
    d=$((s * 2))
    sips -z "$d" "$d" dist/icon-1024.png --out "dist/AppIcon.iconset/icon_${s}x${s}@2x.png" > /dev/null
done
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf dist/AppIcon.iconset dist/icon-1024.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>GitBrowser</string>
    <key>CFBundleDisplayName</key>       <string>GitBrowser</string>
    <key>CFBundleIdentifier</key>        <string>com.lorenzgit.GitBrowser</string>
    <key>CFBundleExecutable</key>        <string>GitBrowser</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP"

ZIP="dist/GitBrowser-${VERSION}-macos.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done: $ZIP"
