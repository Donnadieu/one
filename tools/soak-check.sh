#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# `make soak`: the whole app under load for minutes (`One --test-soak`): home screen live off screen, the stand-in
# engine streaming replies and helpers, every reply read aloud on the real audio line (volume 0), the line rebuilt.
#   tools/soak-check.sh [minutes, default 10] [guard|thread|address]
# guard (default): an optimized build run with Apple's sampling guard at full rate (every small allocation on its own
#   guarded slot), so a write to freed memory crashes AT the write and the crash report names the code that did it.
# thread / address: the same soak under the thread or address sanitizer (debug build, slower).
# Test copy only: own bundle id, own scratch folder, the stand-in engine (no account, no cost), no window on screen.
# ONE_SOAK_ROUTE=1 switches the Mac speakers' format: EVERY app hears that device change, a running One included
# (Nov 3 23:07 a live 0.9.85 crashed during such a run). Only with no real One open.
set -u
cd "$(dirname "$0")/.."
MIN="${1:-10}"
MODE="${2:-guard}"
W=$(mktemp -d "${TMPDIR:-/tmp}/one-soak.XXXXXX")
APP="$W/One.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$W/support"
case "$MODE" in
  guard) FLAGS=(-O) ;;
  thread | address) FLAGS=(-Onone -g "-sanitize=$MODE") ;;
  *) echo "mode: guard, thread or address"; exit 2 ;;
esac
if ! swiftc "${FLAGS[@]}" -parse-as-library -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -framework Speech -framework Carbon -framework EventKit -framework UserNotifications \
  -framework IOKit -swift-version 5 Sources/*.swift -o "$APP/Contents/MacOS/One" > "$W/build.txt" 2>&1; then
  echo "  ✗ build failed (see $W/build.txt)"; exit 1
fi
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ai.forjado.one.soak-$MODE" -c "Add :CFBundleExecutable string One" \
  "$APP/Contents/Info.plist" > /dev/null
cp voice/*.mp3 sounds/chime-done.mp3 sounds/chime-yes.mp3 "$APP/Contents/Resources/"
codesign --force -s - "$APP" > /dev/null 2>&1
cp tools/fake-engine.py "$W/fake-engine.py"; chmod +x "$W/fake-engine.py"
GUARD=()
[ "$MODE" = guard ] && GUARD=(MallocProbGuard=1 MallocProbGuardSampleRate=1 MallocProbGuardAllocations=400000 MallocProbGuardMemoryBudgetInKB=8000000)
start=$(date +%s)
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="$W/support" LANG="${LANG:-en_US.UTF-8}" \
  ONE_SUPPORT_DIR="$W/support" ONE_TEST_ENGINE="$W/fake-engine.py" ONE_FAKE_ENGINE_LOG="$W/engine.jsonl" ONE_FAKE_LOAD_SECS=0.5 ONE_SOAK_ROUTE="${ONE_SOAK_ROUTE:-0}" \
  TSAN_OPTIONS="halt_on_error=0:abort_on_error=0:exitcode=0:history_size=4" ASAN_OPTIONS="halt_on_error=1:detect_leaks=0" ${GUARD[@]+"${GUARD[@]}"} \
  perl -e "alarm $((MIN * 60 + 180)); exec @ARGV" "$APP/Contents/MacOS/One" --test-soak "$MIN" > "$W/out.txt" 2>&1
code=$?
n=$(grep -c -e "WARNING: ThreadSanitizer" -e "ERROR: AddressSanitizer" "$W/out.txt")
echo "  $MODE soak: exit $code after $(($(date +%s) - start)) s, $n sanitizer report(s)"
grep -e '^soak ok' -e SUMMARY "$W/out.txt" | sort | uniq -c
if [ "$code" = 0 ] && [ "$n" = 0 ] && grep -q '^soak ok' "$W/out.txt"; then echo "soak ok"; rm -rf "$W"; exit 0; fi
echo "soak FAILED (logs in $W; a crash report is in ~/Library/Logs/DiagnosticReports/One-*.ips)"
exit 1
