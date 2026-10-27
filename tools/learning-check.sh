#!/bin/bash
# Tell me when I learn, end to end, with One's real engine in a throwaway home (about eight Claude turns on the
# Claude subscription One already uses, ~10 min). A copy of the app with its own bundle id runs it, so the person's
# chat, settings and running One are never touched. See Sources/LearningLiveCheck.swift.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S=$(mktemp -d "${TMPDIR:-/tmp}/one-learning.XXXXXX")
cp -R build/app.noindex/One.app "$S/One.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.forjado.one.learning-test" "$S/One.app/Contents/Info.plist"
codesign --force -s - "$S/One.app" >/dev/null 2>&1
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" ONE_LEARN_WINDOW=20 HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" \
  perl -e 'alarm 1500; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-learning-live > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
[ $rc = 142 ] && echo "FAIL timeout"
for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
defaults delete ai.forjado.one.learning-test >/dev/null 2>&1
exit $rc
