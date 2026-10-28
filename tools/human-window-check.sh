#!/bin/bash
# The human-check window, end to end, on a real robot-check page (Sources/HumanCheckLive.swift).
# VISIBLE: it opens a real Chrome window. Only run it after the person said yes to that window.
# Never the shared browser: a throwaway hidden Chrome on its own port, on a copy of the saved profile
# (sign-ins included, caches left out), deleted at the end.
#   tools/human-window-check.sh [url]      default https://claude.ai/design
# Touch "$S/support/done" to tap Done on One's card; or tick the check in the window.
set -u
cd "$(dirname "$0")/.."
SUP="$HOME/Library/Application Support/One"
URL="${1:-https://claude.ai/design}"
PORT=${CHECK_PORT:-9346}
[ "$PORT" = 9223 ] && { echo "refusing: 9223 is the shared browser"; exit 2; }
SRCP=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("profile",""))' "$SUP/browser/keeper.json" 2>/dev/null)
[ -n "$SRCP" ] || SRCP="$SUP/browser/chrome-profile"
S="${CHECK_DIR:-$SUP/hermes/cache/scratch/human-window.$$}"
mkdir -p "$S/support" "$S/profile"
rsync -a --exclude 'Cache' --exclude 'Code Cache' --exclude 'GPUCache' --exclude 'Service Worker/CacheStorage' \
  --exclude 'Singleton*' --exclude 'DevToolsActivePort' --exclude '*.pma' "$SRCP/" "$S/profile/"
tools/test-copy.sh human-window "$S" >/dev/null
echo "dir: $S"
# Started through Launch Services with its settings in Info.plist (LSEnvironment), never as a child of this
# shell: inside One's folder lock a child's `open` loses its arguments, so the window would be a bare Chrome.
PL="$S/One.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PL"
EXTRA=""; [ -n "${FLUSH_ONLY:-}" ] && EXTRA="ONE_CHECK_FLUSH=1"
for kv in $EXTRA "ONE_TEST_MODE=--test-human-window" "ONE_SUPPORT_DIR=$S/support" "ONE_CHECK_PORT=$PORT" "ONE_CHECK_PROFILE=$S/profile" \
  "ONE_CHECK_URL=$URL" "ONE_CHECK_LOG=$S/one.txt" ${SHOTS:+"ONE_CHECK_SHOTS=$SHOTS"}; do
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${kv%%=*} string ${kv#*=}" "$PL"
done
codesign --force -s - "$S/One.app" >/dev/null 2>&1
: > "$S/one.txt"
/usr/bin/open -n "$S/One.app"
end=$(( $(date +%s) + 900 ))
while [ "$(date +%s)" -lt $end ] && ! grep -q "^human window \|^refusing" "$S/one.txt"; do sleep 2; done
cat "$S/one.txt"
grep -q "^human window ok" "$S/one.txt"; rc=$?
P=$(/usr/sbin/lsof -nP -t -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | head -1)
[ -n "$P" ] && kill "$P" 2>/dev/null
defaults delete ai.forjado.one.human-window >/dev/null 2>&1
[ -n "${KEEP:-}" ] || { sleep 2; rm -rf "$S"; }
exit $rc
