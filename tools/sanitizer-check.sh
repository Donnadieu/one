#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# `make sanitize`: builds One twice with Apple's sanitizers (thread, then address) and drives the real audio line
# under load (`One --test-voice-stress`). Thread finds two threads touching the same memory without a lock (the
# kind of bug that corrupted the heap in 0.9.32 to 0.9.84); address finds use-after-free and overruns at the bad
# write. Test copies only: own bundle id, own scratch folder, the line plays at volume 0, no window. ~10 min.
#   tools/sanitizer-check.sh [seconds per run, default 30]
set -u
cd "$(dirname "$0")/.."
SECS="${1:-30}"
W=$(mktemp -d "${TMPDIR:-/tmp}/one-sanitize.XXXXXX")
rc=0
for SAN in thread address; do
  APP="$W/$SAN/One.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  if ! swiftc -Onone -g -sanitize=$SAN -parse-as-library -target arm64-apple-macosx14.0 \
    -framework SwiftUI -framework AppKit -framework Speech -framework Carbon -framework EventKit -framework UserNotifications \
    -framework IOKit -swift-version 5 Sources/*.swift -o "$APP/Contents/MacOS/One" > "$W/$SAN-build.txt" 2>&1; then
    echo "  ✗ $SAN build failed (see $W/$SAN-build.txt)"; rc=1; continue
  fi
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ai.forjado.one.sanitize-$SAN" -c "Add :CFBundleExecutable string One" \
    "$APP/Contents/Info.plist" > /dev/null
  cp voice/*.mp3 sounds/chime-done.mp3 sounds/chime-yes.mp3 "$APP/Contents/Resources/"
  codesign --force -s - "$APP" > /dev/null 2>&1
  S="$W/$SAN-run"; mkdir -p "$S"
  env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin TMPDIR="$S" ONE_SUPPORT_DIR="$S" \
    TSAN_OPTIONS="halt_on_error=0:abort_on_error=0:exitcode=0" ASAN_OPTIONS="halt_on_error=1:detect_leaks=0" \
    perl -e "alarm $((SECS + 90)); exec @ARGV" "$APP/Contents/MacOS/One" --test-voice-stress "$SECS" > "$S/out.txt" 2>&1
  code=$?
  n=$(grep -c -e "WARNING: ThreadSanitizer" -e "ERROR: AddressSanitizer" "$S/out.txt")
  if [ "$code" = 0 ] && [ "$n" = 0 ] && grep -q '^voice-stress ok' "$S/out.txt"; then
    echo "  ✓ $SAN: $(grep '^voice-stress ok' "$S/out.txt")"
  else
    echo "  ✗ $SAN: exit $code, $n sanitizer report(s)"; grep -e SUMMARY "$S/out.txt" | sort | uniq -c; rc=1
  fi
done
if [ $rc = 0 ]; then echo "sanitize ok"; rm -rf "$W"; else echo "sanitize FAILED (logs in $W)"; fi
exit $rc
