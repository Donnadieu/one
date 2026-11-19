#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Keep the Mac awake while One works (KeepAwake.swift), seen from the outside with `pmset -g assertions`:
#   before: no "One is finishing" assertion from the test copy
#   during: a fake helper works → one PreventUserIdleSystemSleep assertion, plain-words name, test copy's pid
#   after:  the helper is done → gone while the process is still alive (the Mac sleeps as usual)
#   crash:  a copy killed with -9 while holding → gone (the OS drops it with the process)
# Usage: tools/keep-awake-check.sh <test copy binary> <scratch dir>   (preflight runs it; never your real One)
set -u
BIN="$1"; T="$2"; mkdir -p "$T"
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails+1)); }
has() { pmset -g assertions | grep -E "pid $1\(One\).*PreventUserIdleSystemSleep named: \"One is finishing" >/dev/null; }
wait_line() { for _ in $(seq 1 100); do grep -q "^$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

ONE_SUPPORT_DIR="$T" ONE_HOLD_SECS=4 "$BIN" --test-keep-awake-hold > "$T/hold.txt" 2>&1 & P=$!
if wait_line holding "$T/hold.txt"; then
  if has $P; then ok "during: pmset shows \"$(sed -n 's/^holding [0-9]* //p' "$T/hold.txt")\" for the test copy"; else bad "during: pmset doesn't show it"; fi
  if pmset -g assertions | grep -E "pid $P\(One\)" | grep -q DisplaySleep; then bad "it keeps the screen on"; else ok "the screen can still sleep"; fi
  if [ "$(pmset -g assertions | grep -cE "pid $P\(One\)")" = 1 ]; then ok "exactly one"; else bad "more than one"; fi
else bad "the test copy never held"; fi
if wait_line released "$T/hold.txt"; then
  if kill -0 $P 2>/dev/null && ! has $P; then ok "after: gone while One is still running"; else bad "after: still held (or One quit early)"; fi
else bad "never let go"; fi
kill $P 2>/dev/null; wait $P 2>/dev/null

ONE_SUPPORT_DIR="$T" ONE_HOLD_SECS=60 "$BIN" --test-keep-awake-hold > "$T/crash.txt" 2>&1 & P=$!
if wait_line holding "$T/crash.txt" && has $P; then
  kill -9 $P; wait $P 2>/dev/null; sleep 1
  if has $P; then bad "crash: still held after the process died"; else ok "crash: gone with the process"; fi
else bad "crash test never held"; kill -9 $P 2>/dev/null; fi
[ $fails = 0 ] && echo "keep awake pmset ok"
[ $fails = 0 ]
