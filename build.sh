#!/bin/bash
# Builds One.app into ./build/app.noindex and (optionally) copies it to ~/Applications.
# The .noindex folder keeps Spotlight from listing every build as another copy of One in the Mac's Apps.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/app.noindex/One.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -framework Speech -framework Carbon -framework EventKit -swift-version 5 \
  Sources/*.swift -o "$APP/Contents/MacOS/One"
VERSION=$(tr -d ' \n' < VERSION)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>One</string>
  <key>CFBundleDisplayName</key><string>One</string>
  <key>CFBundleIdentifier</key><string>ai.forjado.one</string>
  <key>CFBundleExecutable</key><string>One</string>
  <key>CFBundleIconFile</key><string>One</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>So you can hold the orb and talk to your assistant.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>So your assistant can see your days, warn you about clashes and add things you ask for.</string>
  <key>NSAppleEventsUsageDescription</key><string>So your assistant can read your email in Mail and open drafts for you to send.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>So what you say turns into words for your assistant, on this Mac.</string>
</dict></plist>
PLIST
cp voice/*.mp3 "$APP/Contents/Resources/"
cp tools/speak.py tools/install_voice.sh "$APP/Contents/Resources/"
cp tools/overlay/agent/vault_backends/keepass.py "$APP/Contents/Resources/"
# Skills that ship with One (skills/<category>/<name>/SKILL.md); One copies them into the engine (BundledSkills).
cp -R skills "$APP/Contents/Resources/skills"
# Sign in with Google is dropped from releases (email and calendar use the Mac's own accounts). Developer builds only: ONE_GOOGLE=1.
if [ "${ONE_GOOGLE:-0}" = 1 ] && [ -f "$HOME/.hermes/google_client_secret.json" ]; then
  cp tools/google_signin.py "$APP/Contents/Resources/"
  cp "$HOME/.hermes/google_client_secret.json" "$APP/Contents/Resources/google_client_secret.json"
fi
cp assets/One.icns "$APP/Contents/Resources/One.icns"
# Hermes's official installer (MIT, Nous Research), run by One on first launch.
# The Hermes version One is tested with (v0.22.5). Bump only after tools/preflight.sh --full passes on the new one.
HERMES_COMMIT="${HERMES_COMMIT:-bf0203a794a07aac3ff764972ab9087baa4e4f4e}"
echo "$HERMES_COMMIT" > "$APP/Contents/Resources/hermes-commit.txt"
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://raw.githubusercontent.com/NousResearch/hermes-agent/$HERMES_COMMIT/scripts/install.sh}"
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
  STAGE=build/app.noindex/dmg
  rm -rf build/dmg "$STAGE" && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
  rm -f build/One.dmg && hdiutil create -quiet -volname "One" -srcfolder "$STAGE" -ov -format UDZO build/One.dmg && echo "packaged build/One.dmg"
  rm -rf "$STAGE"
  # The in-app updater downloads this zip.
  rm -f build/One.zip && ditto -c -k --keepParent "$APP" build/One.zip && echo "packaged build/One.zip"
fi
