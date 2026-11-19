#!/bin/bash
# runs: owner-only (make helperstop) — One's real engine on the owner's own Claude subscription; no CI runner has it
# Stopping a helper and updating with helpers at work, end to end, with One's real engine in a throwaway home
# (a few short turns on the Claude subscription One already uses). See Sources/HelperStopCheck.swift.
#   1. --test-helper-stop: Stop button and the [stop-helper: …] line end that helper's turn only; it stays stopped.
#   2. --test-update-helpers: a real update (download, swap, quit) with a helper at work, then the updated copy
#      picks the helper back up by itself. The update zip is served from this Mac; nothing is downloaded.
# A copy of the app with its own bundle id runs it, so the person's chat, settings and running One are never
# touched. Several runs and its own server, so it uses engine-check.sh as a library rather than as a command.
set -u
. "$(dirname "$0")/engine-check.sh" --lib

BUILD=build
case " $* " in *" --no-build "*) BUILD=no ;; esac
engine_world helperstop-test "$BUILD"
# shellcheck disable=SC2034  # read by the sourced engine-check.sh library
ENGINE_EXTRA_ENV=(ONE_UPDATE_NO_REOPEN=1 ONE_TEST_UPDATE_ZIP="")

rc=0
case " $* " in *" --update-only "*) ;; *)
  engine_run 900 --test-helper-stop > "$S/stop.txt" 2>"$S/stop-err.txt" || rc=1
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
# shellcheck disable=SC2034  # read by the sourced engine-check.sh library
ENGINE_EXTRA_ENV=(ONE_UPDATE_NO_REOPEN=1 ONE_TEST_UPDATE_ZIP="http://127.0.0.1:$PORT/One.zip")
engine_run 900 --test-update-helpers > "$S/upd1.txt" 2>"$S/upd1-err.txt"
cat "$S/upd1.txt"
ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$S/One.app/Contents/Info.plist" 2>/dev/null; }
for _ in $(seq 1 60); do [ "$(ver)" = 9.9.9 ] && break; sleep 1; done
kill $SRV 2>/dev/null
v=$(ver)
echo "  copy's version after the update: $v"
[ "$v" = 9.9.9 ] || { echo "  ✗ the update didn't swap the app"; rc=1; }
engine_run 900 --test-update-helpers --after > "$S/upd2.txt" 2>"$S/upd2-err.txt"
cat "$S/upd2.txt"
grep -q '^update-helpers ok' "$S/upd2.txt" || rc=1
engine_cleanup
echo "(logs in $S)"
exit $rc
