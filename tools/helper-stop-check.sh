#!/bin/bash
# Stopping a helper and updating with helpers at work, end to end, with One's real engine in a throwaway home
# (a few short turns on the Claude subscription One already uses). See Sources/HelperStopCheck.swift.
#   1. --test-helper-stop: Stop button and the [stop-helper: …] line end that helper's turn only; it stays stopped.
#   2. --test-update-helpers: a real update (download, swap, quit) with a helper at work, then the updated copy
#      picks the helper back up by itself. The update zip is served from this Mac; nothing is downloaded.
# A copy of the app with its own bundle id runs it, so the person's chat, settings and running One are never touched.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.helperstop-test
S=$(mktemp -d "${TMPDIR:-/tmp}/one-helperstop.XXXXXX")
tools/test-copy.sh "${ID#ai.forjado.one.}" "$S" >/dev/null  # own bundle id: never your real One or its settings
defaults delete "$ID" >/dev/null 2>&1
run() {
  env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-en_US.UTF-8}" HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" \
    ONE_UPDATE_NO_REOPEN=1 ONE_TEST_UPDATE_ZIP="${ZIPURL:-}" \
    perl -e 'alarm 900; exec @ARGV' "$S/One.app/Contents/MacOS/One" "$@"
}
rc=0
case " $* " in *" --update-only "*) ;; *)
  run --test-helper-stop > "$S/stop.txt" 2>"$S/stop-err.txt" || rc=1
  cat "$S/stop.txt"
  grep -q '^helper-stop ok' "$S/stop.txt" || rc=1
  defaults delete "$ID" >/dev/null 2>&1
;; esac

# The "new version": the same copy, marked 9.9.9, zipped like a release and served on this Mac.
mkdir -p "$S/new" "$S/srv"
cp -R "$S/One.app" "$S/new/One.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" "$S/new/One.app/Contents/Info.plist"
codesign --force -s - "$S/new/One.app" >/dev/null 2>&1
(cd "$S/new" && ditto -c -k --keepParent One.app "$S/srv/One.zip")
PORT=$((20000 + RANDOM % 20000))
/usr/bin/python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$S/srv" >/dev/null 2>&1 &
SRV=$!
sleep 1
ZIPURL="http://127.0.0.1:$PORT/One.zip" run --test-update-helpers > "$S/upd1.txt" 2>"$S/upd1-err.txt"
cat "$S/upd1.txt"
ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$S/One.app/Contents/Info.plist" 2>/dev/null; }
for _ in $(seq 1 60); do [ "$(ver)" = 9.9.9 ] && break; sleep 1; done
kill $SRV 2>/dev/null
v=$(ver)
echo "  copy's version after the update: $v"
[ "$v" = 9.9.9 ] || { echo "  ✗ the update didn't swap the app"; rc=1; }
run --test-update-helpers --after > "$S/upd2.txt" 2>"$S/upd2-err.txt"
cat "$S/upd2.txt"
grep -q '^update-helpers ok' "$S/upd2.txt" || rc=1
for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
echo "(logs in $S)"
exit $rc
