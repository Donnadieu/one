#!/bin/bash
# `make helpers-check` (and part of preflight): 100 helpers at once, then the engine is killed, One is killed and an
# update restarts it, all mid-run; then the one line everything the assistant says goes through (QueueCheck.swift). Proves every helper stays listed and on screen, none starts or runs twice, none is
# shown done without its real final reply, every cut-off one picks back up and finishes, every result has its file,
# and a finished one stays until dismissed. Uses a stand-in engine (tools/fake-engine.py): no account, no cost,
# about a minute. A test copy with its own bundle id and a scratch folder: your One, chat and settings are never touched.
#   tools/helpers-check.sh [--no-build]
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.helpers-stress
S=$(mktemp -d "${TMPDIR:-/tmp}/one-helpers-stress.XXXXXX")
APP=$(tools/test-copy.sh "${ID#ai.forjado.one.}" "$S") || exit 1
defaults delete "$ID" >/dev/null 2>&1
mkdir -p "$S/support"
cp tools/fake-engine.py "$S/fake-engine.py"; chmod +x "$S/fake-engine.py"
run() {
  local secs=$1; shift
  exec env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-en_US.UTF-8}" ONE_SUPPORT_DIR="${SUP:-$S/support}" ONE_TEST_ENGINE="$S/fake-engine.py" ONE_FAKE_ENGINE_LOG="${ELOG:-$S/engine.jsonl}" \
    ONE_QUEUE_SHOT="${ONE_QUEUE_SHOT:-}" \
    perl -e "alarm $secs; exec @ARGV" "$APP/Contents/MacOS/One" --test-helpers-stress "$@"
}
rc=0
# 1. Start: 100 helpers, the engine killed mid-run. Then One itself is killed (kill -9) while helpers are at work.
run 200 start > "$S/start.txt" 2>"$S/start-err.txt" &
P=$!
for _ in $(seq 1 240); do grep -q -e '^READY-TO-KILL' -e 'FAILED' -e '^refusing' -e '^FAIL' "$S/start.txt" && break; kill -0 $P 2>/dev/null || break; sleep 0.5; done
if grep -q '^READY-TO-KILL' "$S/start.txt"; then kill -9 $P 2>/dev/null; else rc=1; kill $P 2>/dev/null; fi
wait $P 2>/dev/null
pgrep -f "$APP/Contents/MacOS/One" >/dev/null && { echo "  ✗ One is still running after kill -9"; rc=1; }
grep -v '^READY-TO-KILL' "$S/start.txt"
[ $rc = 0 ] && echo "  · One was killed (kill -9) with helpers at work"
sleep 1
# 2. One opens again from what it saved; then an update pauses the helpers at work and One quits for it.
if [ $rc = 0 ]; then
  (run 90 after-kill) > "$S/kill.txt" 2>"$S/kill-err.txt" || rc=1
  grep -v '^UPDATE-QUIT' "$S/kill.txt"
  grep -q '^UPDATE-QUIT' "$S/kill.txt" || rc=1
fi
# 3. One opens again after the update: everything finishes.
if [ $rc = 0 ]; then
  (run 120 after-update) > "$S/update.txt" 2>"$S/update-err.txt" || rc=1
  cat "$S/update.txt"
  grep -q '^helpers-stress ok' "$S/update.txt" || rc=1
fi
# 4. One line for everything the assistant says: a long reply read aloud, three helpers finishing and a message
#    sent during it. The reply ends whole (text and voice), then the notices one at a time in order, then the message.
if [ $rc = 0 ]; then
  for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
  mkdir -p "$S/q"
  (SUP="$S/q" ELOG="$S/q/engine.jsonl" run 120 queue) > "$S/queue.txt" 2>"$S/queue-err.txt" || rc=1
  cat "$S/queue.txt"
fi
for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
if [ $rc = 0 ]; then echo "helpers-check ok"; [ -n "${KEEP:-}" ] || rm -rf "$S"; else echo "helpers-check FAILED (logs in $S)"; fi
exit $rc
