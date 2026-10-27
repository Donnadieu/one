#!/bin/bash
# Finished helpers, end to end, with One's real engine in a throwaway home (a few short turns on the Claude
# subscription One already uses): orange until opened, one "by the way" line after the reply in progress, never
# the result again; a good morning gets one combined report. A copy of the app with its own bundle id runs it,
# so the person's chat, settings and running One are never touched. See Sources/HelperDoneCheck.swift.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S=$(mktemp -d "${TMPDIR:-/tmp}/one-helperdone.XXXXXX")
cp -R build/app.noindex/One.app "$S/One.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.forjado.one.helperdone-test" "$S/One.app/Contents/Info.plist"
codesign --force -s - "$S/One.app" >/dev/null 2>&1
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" \
  perl -e 'alarm 840; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-helper-done > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
[ $rc = 142 ] && echo "FAIL timeout"
for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
defaults delete ai.forjado.one.helperdone-test >/dev/null 2>&1
exit $rc
