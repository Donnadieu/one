#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Proves the keeper (`One --keeper`, which macOS runs every minute) really opens One again after a failed start,
# waits longer each time, never opens it after a quit they asked for, and puts the previous version back after a
# just-installed one fails to start three times. Nov 6 2026: an update's relaunch failed with the lid closed and
# nothing brought One (and the phone chat) back for 18 hours.
# Never the real One: the keeper is a test copy's binary with a scratch folder (ONE_SUPPORT_DIR), and "One" is a
# stand-in app built here: a tiny program that writes its version to starts.log and ends at once (a crash at launch)
# or stays up 40 s (a good start). The keeper's clock is moved with ONE_KEEPER_NOW.
#   tools/keeper-check.sh <test copy's One binary> <scratch folder>      prints "keeper ok" when it passes
set -u
BIN="$1"; W="$2"
rm -rf "$W"; mkdir -p "$W/sup/hermes/logs"
LOG="$W/starts.log"; : > "$LOG"
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails+1)); }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# mk <folder> <version> <seconds up> <exit code>
mk() {
  local app="$W/$1/One.app"
  mkdir -p "$app/Contents/MacOS"
  printf '#include <stdio.h>\n#include <unistd.h>\nint main(void){FILE*f=fopen("%s","a");fprintf(f,"%s\\n");fclose(f);sleep(%s);return %s;}\n' \
    "$LOG" "$2" "$3" "$4" > "$W/$1/main.c"
  clang -O0 "$W/$1/main.c" -o "$app/Contents/MacOS/One" || exit 1
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ai.forjado.one.keeper-standin</string>
  <key>CFBundleExecutable</key><string>One</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$2</string>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
  codesign -fs - "$app" >/dev/null 2>&1
}
APPDIR="$W/Applications"; mkdir -p "$APPDIR"
mk new 2.0 0 1        # the just-installed version: ends right after it starts
mk old 1.0 40 0       # the version it replaced: starts fine
mv "$W/new/One.app" "$APPDIR/One.app"
mkdir -p "$W/sup/update-previous"; mv "$W/old/One.app" "$W/sup/update-previous/One.app"
T0=1794000000
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
cat > "$W/sup/keeper.json" <<JSON
{"want": true, "app": "$APPDIR/One.app", "launches": [], "updatedAt": "$(iso $T0)", "updatedTo": "2.0", "badVersions": []}
JSON
keeper() { ONE_SUPPORT_DIR="$W/sup" ONE_KEEPER_NOW="$1" perl -e 'alarm 60; exec @ARGV' "$BIN" --keeper; }
starts() { grep -c . "$LOG"; }
settle() { for _ in $(seq 1 40); do [ "$(starts)" -ge "$1" ] && break; sleep 0.25; done; sleep 1; }

echo "1. One ended without being asked to (the update's relaunch failed)"
keeper $((T0 + 5)); settle 1
expect "the keeper opens it again right away" '[ "$(starts)" = 1 ] && [ "$(tail -1 "$LOG")" = 2.0 ]'
keeper $((T0 + 20)); sleep 2
expect "it failed again at once: no new try within the minute" '[ "$(starts)" = 1 ]'
keeper $((T0 + 70)); settle 2
expect "a minute later it tries again" '[ "$(starts)" = 2 ]'
keeper $((T0 + 200)); sleep 2
expect "then waits 5 minutes" '[ "$(starts)" = 2 ]'
keeper $((T0 + 380)); settle 3
expect "and tries a third time" '[ "$(starts)" = 3 ]'

echo "2. The new version failed to start three times: the previous one is put back"
keeper $((T0 + 400)); settle 4
expect "the previous version is back in place and started" '[ "$(starts)" = 4 ] && [ "$(tail -1 "$LOG")" = 1.0 ]'
expect "the failed one is kept aside, not deleted" '[ -x "$W/sup/update-failed/2.0/One.app/Contents/MacOS/One" ]'
expect "the updater is told never to offer 2.0 again" 'grep -q "\"2.0\"" "$W/sup/keeper.json"'
expect "it's logged in plain words" 'grep -q "failed to start 3 times: put the previous version back" "$W/sup/hermes/logs/one-keeper.log"'

echo "3. One is open: nothing to do"
keeper $((T0 + 5000)); sleep 2
expect "the keeper leaves a running One alone" '[ "$(starts)" = 4 ]'

echo "4. They quit it"
for p in $(pgrep -f "$APPDIR/One.app/Contents/MacOS/One"); do kill "$p"; done; sleep 1  # only the stand-in
/usr/bin/python3 - "$W/sup/keeper.json" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["want"] = False; s["launches"] = []; json.dump(s, open(p, "w"))
EOF
keeper $((T0 + 9000)); sleep 2
expect "never opened against their wish" '[ "$(starts)" = 4 ]'

echo "5. One was moved away"
/usr/bin/python3 - "$W/sup/keeper.json" <<'EOF'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["want"] = True; s["app"] = "/nowhere/One.app"; json.dump(s, open(p, "w"))
EOF
keeper $((T0 + 9100)); sleep 1
expect "nothing to open, said so" '[ "$(starts)" = 4 ] && grep -q "isn.t at /nowhere/One.app" "$W/sup/hermes/logs/one-keeper.log"'

if [ $fails = 0 ]; then echo "keeper ok"; else echo "keeper FAILED ($fails)"; sed 's/^/    /' "$W/sup/hermes/logs/one-keeper.log" 2>/dev/null; fi
[ $fails = 0 ]
