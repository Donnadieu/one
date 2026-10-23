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
  <key>CFBundleShortVersionString</key><string>0.6</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp voice/*.mp3 "$APP/Contents/Resources/"
# Hermes's official installer (MIT, Nous Research), run by One on first launch.
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh}"
curl -fsSL "$HERMES_INSTALL_URL" -o "$APP/Contents/Resources/hermes-install.sh"
# Memory templates (rooms). Point BRAIN_STARTER at a checkout of the brain starter.
BRAIN_STARTER="${BRAIN_STARTER:-$HOME/Repos/brain-starter}"
if [ -d "$BRAIN_STARTER/.git" ]; then
  git -C "$BRAIN_STARTER" archive --prefix=brain-starter/ HEAD | tar -x -C "$APP/Contents/Resources"
else
  echo "note: no brain starter at $BRAIN_STARTER; memory rooms will be unavailable in this build" >&2
fi
codesign --force --deep -s - "$APP"
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications && rm -rf ~/Applications/One.app && cp -R "$APP" ~/Applications/ && echo "installed ~/Applications/One.app"
fi
if [[ "${1:-}" == "--package" ]]; then
  rm -rf build/dmg && mkdir -p build/dmg && cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
  rm -f build/One.dmg && hdiutil create -quiet -volname "One" -srcfolder build/dmg -ov -format UDZO build/One.dmg && echo "packaged build/One.dmg"
fi
