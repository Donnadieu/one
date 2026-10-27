#!/bin/bash
# Makes a test copy of the built One and prints its path. The copy has its own bundle id, so it has its
# own settings and can never be the person's real One (TestWorld.swift refuses every test mode under the
# real id). Every check that runs One goes through this script.
#   APP=$(tools/test-copy.sh [name] [folder])   name: ai.forjado.one.<name> (default: test)
#   "$APP/Contents/MacOS/One" --test-…          folder: where the copy goes (default: a scratch folder)
set -eu
cd "$(dirname "$0")/.."
NAME="${1:-test}"
DEST="${2:-${TMPDIR:-/tmp}/one-test-app-$NAME.noindex}"
case "$NAME" in *[!a-z0-9-]* | "") echo "test-copy: name must be lowercase letters, digits or -" >&2; exit 2 ;; esac
case "$DEST" in
  "$HOME/Documents"* | "$HOME/Desktop"* | "$HOME/Downloads"* | /Applications* | "$HOME/Applications"*)
    echo "test-copy: refusing to put a test copy in $DEST (that's your own stuff)" >&2; exit 2 ;;
esac
SRC=build/app.noindex/One.app; [ -d "$SRC" ] || SRC=build/One.app
[ -d "$SRC" ] || { echo "test-copy: no built app, run ./build.sh" >&2; exit 1; }
mkdir -p "$DEST"
rm -rf "$DEST/One.app"
ditto "$SRC" "$DEST/One.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.forjado.one.$NAME" "$DEST/One.app/Contents/Info.plist"
codesign --force -s - "$DEST/One.app" >/dev/null 2>&1
echo "$DEST/One.app"
