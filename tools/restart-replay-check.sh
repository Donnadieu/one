#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# What the person sent is never lost when One goes away mid-turn, and never runs twice (Sources/RestartReplayCheck.swift,
# Nov 10-22 replayed against the stand-in engine tools/fake-engine.py: no account, no cost, about two minutes).
# Run 1 leaves the main chat's turn in flight, a message typed during it (Next up), a choice tapped on an asking helper
# (its turn in flight) and an answer sent into a working helper's turn, then One is killed (no clean quit). Run 2 is One
# opening again: each goes again exactly once and is answered. Run 3 opens again: nothing runs again.
# A test copy with its own bundle id and a scratch folder: your One, chat and settings are never touched.
#   tools/restart-replay-check.sh [--no-build]
set -u
cd "$(dirname "$0")/.." || exit 1
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.restart-replay-$$
S=$(mktemp -d "${TMPDIR:-/tmp}/one-restart-replay.XXXXXX")
APP=$(tools/test-copy.sh "${ID#ai.forjado.one.}" "$S") || exit 1
defaults delete "$ID" >/dev/null 2>&1
mkdir -p "$S/support"
cp tools/fake-engine.py "$S/fake-engine.py"; chmod +x "$S/fake-engine.py"
run() {
  local secs=$1 out=$2; shift 2
  env -i GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-en_US.UTF-8}" ONE_SUPPORT_DIR="$S/support" ONE_TEST_ENGINE="$S/fake-engine.py" ONE_FAKE_ENGINE_LOG="$S/engine.jsonl" \
    ONE_UPDATE_NO_REOPEN=1 perl -e "alarm $secs; exec @ARGV" "$APP/Contents/MacOS/One" --test-helpers-stress "$@" > "$out" 2>>"$S/err.txt"
}
gone() { for _ in $(seq 1 40); do pgrep -f "$APP/Contents/MacOS/One --test" >/dev/null || break; sleep 0.5; done; }
rc=0
run 120 "$S/run1.txt" replay
cat "$S/run1.txt"
grep -q '^READY-TO-QUIT$' "$S/run1.txt" || rc=1
gone
run 180 "$S/run2.txt" replay-after
cat "$S/run2.txt"
grep -q '^replay-after ok$' "$S/run2.txt" || rc=1
gone
run 60 "$S/run3.txt" replay-again
cat "$S/run3.txt"
grep -q '^replay-again ok$' "$S/run3.txt" || rc=1
[ -n "${ONE_SHOT_DIR:-}" ] && cp "$S"/run?.txt "$S/engine.jsonl" "$ONE_SHOT_DIR/" 2>/dev/null
for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
if [ $rc = 0 ]; then echo "restart-replay-check ok"; [ -n "${KEEP:-}" ] || rm -rf "$S"; else echo "restart-replay-check FAILED (logs in $S)"; tail -20 "$S/err.txt"; fi
exit $rc
