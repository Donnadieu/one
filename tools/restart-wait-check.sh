#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# A helper waiting for One to restart (Sources/RestartWaitCheck.swift): the Nov 17 "Free Docker memory" helper replayed
# against the stand-in engine (tools/fake-engine.py, no account, no cost, under a minute). It gets a folder (a real
# `One --grant-folder` from inside its turn) or asks One to restart, and ends its turn before the restart: it waits,
# can't be cleared (Got it, the done-helper line), Stop still works, and after the restart it picks back up in the same
# conversation and finishes. Also one an older One showed done, or took off the screen, before the restart.
# A test copy with its own bundle id and a scratch folder: your One, chat and settings are never touched.
#   tools/restart-wait-check.sh [--no-build]
set -u
cd "$(dirname "$0")/.." || exit 1
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.restart-wait-$$
S=$(mktemp -d "${TMPDIR:-/tmp}/one-restart-wait.XXXXXX")
APP=$(tools/test-copy.sh "${ID#ai.forjado.one.}" "$S") || exit 1
defaults delete "$ID" >/dev/null 2>&1
mkdir -p "$S/support"
cp tools/fake-engine.py "$S/fake-engine.py"; chmod +x "$S/fake-engine.py"
run() {
  local secs=$1 out=$2; shift 2
  env -i GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-en_US.UTF-8}" ONE_SUPPORT_DIR="$S/support" ONE_TEST_ENGINE="$S/fake-engine.py" ONE_FAKE_ENGINE_LOG="$S/engine.jsonl" \
    ONE_TEST_ONE_BIN="$APP/Contents/MacOS/One" ONE_UPDATE_NO_REOPEN=1 ONE_SHOT_DIR="${ONE_SHOT_DIR:-$S/shots}" \
    perl -e "alarm $secs; exec @ARGV" "$APP/Contents/MacOS/One" --test-helpers-stress "$@" > "$out" 2>>"$S/err.txt"
}
# 1. The helpers wait for One to restart; a folder restart and a quit-and-open inside the run; then a real restart (One quits).
run 200 "$S/out.txt" restartwait
rc=0
cat "$S/out.txt"
grep -q '^RESTART-QUIT fails=0$' "$S/out.txt" || rc=1
# 2. One opens again after the real restart: the helper that was waiting picks back up and finishes.
for _ in $(seq 1 40); do pgrep -f "$APP/Contents/MacOS/One --test" >/dev/null || break; sleep 0.5; done
run 120 "$S/after.txt" restartwait-after
cat "$S/after.txt"
grep -q '^restart-wait ok' "$S/after.txt" || rc=1
[ -n "${ONE_SHOT_DIR:-}" ] && cp "$S/out.txt" "$ONE_SHOT_DIR/restart-wait-run1.txt" 2>/dev/null && cp "$S/after.txt" "$ONE_SHOT_DIR/restart-wait-run2.txt" 2>/dev/null
for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
if [ $rc = 0 ]; then echo "restart-wait-check ok"; [ -n "${KEEP:-}" ] || rm -rf "$S"; else echo "restart-wait-check FAILED (logs in $S)"; tail -20 "$S/err.txt"; fi
exit $rc
