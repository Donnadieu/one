#!/bin/bash
# Builds One.app into ./build and (optionally) copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/One.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -swift-version 5 \
  Sources/main.swift -o "$APP/Contents/MacOS/One"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>One</string>
  <key>CFBundleDisplayName</key><string>One</string>
  <key>CFBundleIdentifier</key><string>ai.forjado.one</string>
  <key>CFBundleExecutable</key><string>One</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications && rm -rf ~/Applications/One.app && cp -R "$APP" ~/Applications/ && echo "installed ~/Applications/One.app"
fi
