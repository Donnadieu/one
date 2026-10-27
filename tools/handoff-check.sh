#!/bin/bash
# A step only the person can do, end to end, on a local test page (never a real account, never the shared
# browser on 9223). Starts a throwaway headless Chrome and a local page server, runs the engine half
# (browser_vault enter_code with One's overlay, tests/handoff/e2e_engine.py) and One's half
# (`One --test-human-step`, which plays the person through One's own window). See Sources/HumanStepCheck.swift.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
SUP="$HOME/Library/Application Support/One"
ENG="$SUP/engine"
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S="$SUP/hermes/cache/scratch/handoff-check.$$"
mkdir -p "$S/support/handoff" "$S/hh" "$S/chrome"
PORT=${HANDOFF_PORT:-9344}
[ "$PORT" = 9223 ] && { echo "refusing: 9223 is the shared browser"; exit 2; }
/opt/homebrew/bin/python3 -m http.server 8791 --bind 127.0.0.1 --directory tests/handoff/pages >/dev/null 2>&1 &
WEB=$!
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-sandbox --disable-crash-reporter \
  --remote-debugging-port=$PORT --user-data-dir="$S/chrome" --no-first-run --no-default-browser-check --window-size=1000,700 about:blank >/dev/null 2>&1 &
CHR=$!
for _ in $(seq 30); do curl -s -m1 127.0.0.1:$PORT/json/version >/dev/null && break; sleep 0.5; done
for p in decoy code; do curl -s -X PUT "127.0.0.1:$PORT/json/new?http://127.0.0.1:8791/$p.html" >/dev/null; done
sleep 1.5
# The engine half runs with the engine's own runtime, through a tiny runner placed in the engine (removed after).
printf 'import os, sys, runpy\nsys.stdout.reconfigure(line_buffering=True)\nsys.path.insert(0, os.getcwd())\nrunpy.run_path(os.environ["ONE_TEST_SCRIPT"], run_name="__main__")\n' > "$ENG/one_handoff_run.py"
( cd "$ENG" && HERMES_RUNTIME_DIR="$SUP/hermes/tools" HERMES_HOME="$S/hh" OVERLAY="$REPO/tools/overlay/tools/one_human_step.py" \
  ONE_HANDOFF_DIR="$S/support/handoff" ONE_HANDOFF_CDP=http://127.0.0.1:$PORT ONE_TEST_SCRIPT="$REPO/tests/handoff/e2e_engine.py" \
  perl -e 'alarm 240; exec @ARGV' "$ENG/.hermes/bin/hermes" --run-module one_handoff_run > "$S/engine.txt" 2>&1 ) &
EP=$!
cp -R build/app.noindex/One.app "$S/One.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.forjado.one.handoff-test" "$S/One.app/Contents/Info.plist"
codesign --force -s - "$S/One.app" >/dev/null 2>&1
ONE_SUPPORT_DIR="$S/support" ONE_HANDOFF_CDP=http://127.0.0.1:$PORT perl -e 'alarm 200; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-human-step > "$S/one.txt" 2>"$S/one.err"
rc=$?
wait $EP
erc=$?
echo "One's half:"; cat "$S/one.txt"
echo "Engine half:"; grep -v '^hermes:\|Preparing\|Installing' "$S/engine.txt"
rm -f "$ENG/one_handoff_run.py"
curl -s -m2 "127.0.0.1:$PORT/json/version" >/dev/null && kill $CHR 2>/dev/null
kill $WEB 2>/dev/null
defaults delete ai.forjado.one.handoff-test >/dev/null 2>&1
[ $rc = 0 ] && [ $erc = 0 ] && grep -q "E2E PASS" "$S/engine.txt" && { echo "PASS handoff"; exit 0; }
echo "FAIL handoff (one=$rc engine=$erc)"; exit 1
