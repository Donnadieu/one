#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Steps only the person can do, end to end, on a local test site whose steps exist ONLY as form POST answers
# (tests/handoff/post_server.py: reopening their address lands on a log-in page, like DocuSign's code page). Never a
# real account, never the shared browsers (9223, 9224, 9333). Starts a throwaway headless Chrome on its own port and
# scratch profile, runs the engine half (browser_vault with One's overlay, tests/handoff/e2e_engine.py) and One's half
# (`One --test-human-step`, which plays the person through One's own card and window). See Sources/HumanStepCheck.swift.
# ONE_SUPPORT_DIR: a One folder with an installed engine (CI: the fresh install); default the usual one.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
ENG="$SUP/engine"
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S="$SUP/hermes/cache/scratch/handoff-check.$$"
mkdir -p "$S/support/handoff" "$S/hh" "$S/chrome"
PORT=${HANDOFF_PORT:-9344}
WEBP=${HANDOFF_WEB:-8791}
case " 9223 9224 9333 " in *" $PORT "*) echo "refusing: $PORT is a shared browser"; exit 2 ;; esac
python3 tests/handoff/post_server.py "$WEBP" tests/handoff/pages >"$S/web.txt" 2>&1 &
WEB=$!
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-sandbox --disable-crash-reporter \
  --remote-debugging-port=$PORT --user-data-dir="$S/chrome" --no-first-run --no-default-browser-check --window-size=1000,700 about:blank >/dev/null 2>&1 &
CHR=$!
for _ in $(seq 30); do curl -s -m1 127.0.0.1:$PORT/json/version >/dev/null && break; sleep 0.5; done
# The engine half runs with the engine's own runtime, through a tiny runner placed in the engine (removed after).
printf 'import os, sys, runpy\nsys.stdout.reconfigure(line_buffering=True)\nsys.path.insert(0, os.getcwd())\nrunpy.run_path(os.environ["ONE_TEST_SCRIPT"], run_name="__main__")\n' > "$ENG/one_handoff_run.py"
( cd "$ENG" && HERMES_RUNTIME_DIR="$SUP/hermes/tools" HERMES_HOME="$S/hh" OVERLAY="$REPO/tools/overlay/tools/one_human_step.py" \
  ONE_HANDOFF_DIR="$S/support/handoff" ONE_HANDOFF_CDP=http://127.0.0.1:$PORT ONE_TEST_WEB=$WEBP ONE_HANDOFF_WAIT=150 \
  ONE_TEST_SCRIPT="$REPO/tests/handoff/e2e_engine.py" \
  perl -e 'alarm 300; exec @ARGV' "$ENG/.hermes/bin/hermes" --run-module one_handoff_run > "$S/engine.txt" 2>&1 ) &
EP=$!
tools/test-copy.sh handoff-test "$S" >/dev/null  # own bundle id: never your real One or its settings
ONE_SUPPORT_DIR="$S/support" ONE_HANDOFF_CDP=http://127.0.0.1:$PORT ONE_HANDOFF_PROFILE="$S/chrome" ONE_TEST_WEB=$WEBP \
  perl -e 'alarm 280; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-human-step > "$S/one.txt" 2>"$S/one.err"
rc=$?
wait $EP
erc=$?
# The code hand-off's ways out (Nov 11 2026): its own handoff folder, after the two halves above (they close every tab).
mkdir -p "$S/loop-handoff"
( cd "$ENG" && HERMES_RUNTIME_DIR="$SUP/hermes/tools" HERMES_HOME="$S/hh" OVERLAY="$REPO/tools/overlay/tools/one_human_step.py" \
  ONE_HANDOFF_DIR="$S/loop-handoff" ONE_HANDOFF_CDP=http://127.0.0.1:$PORT ONE_TEST_WEB=$WEBP \
  ONE_TEST_SCRIPT="$REPO/tests/handoff/e2e_code_loop.py" \
  perl -e 'alarm 360; exec @ARGV' "$ENG/.hermes/bin/hermes" --run-module one_handoff_run > "$S/loop.txt" 2>&1 )
lrc=$?
python3 tests/handoff/phone_replies.py > "$S/phone.txt" 2>&1
prc=$?
echo "One's half:"; cat "$S/one.txt"
echo "Engine half:"; grep -v '^hermes:\|Preparing\|Installing' "$S/engine.txt"
echo "Code hand-off ways out:"; grep -v '^hermes:\|Preparing\|Installing' "$S/loop.txt"
echo "Phone replies:"; cat "$S/phone.txt"
grep "human check:\|hidden browser:" "$S/support/selftest-hermes/logs/one-browser-keeper.log" 2>/dev/null | tail -8 | sed 's/^/  keeper: /'
rm -f "$ENG/one_handoff_run.py"
kill $CHR 2>/dev/null
# Any Chrome still on the scratch profile (one a test reopened) goes too.
for p in $(pgrep -f -- "--user-data-dir=$S/chrome" 2>/dev/null); do kill "$p" 2>/dev/null; done
kill $WEB 2>/dev/null
defaults delete ai.forjado.one.handoff-test >/dev/null 2>&1
[ $rc = 0 ] && [ $erc = 0 ] && [ $lrc = 0 ] && [ $prc = 0 ] && grep -q "E2E PASS" "$S/engine.txt" && grep -q "CODE LOOP PASS" "$S/loop.txt" \
  && { echo "PASS handoff"; exit 0; }
echo "FAIL handoff (one=$rc engine=$erc loop=$lrc phone=$prc)"; exit 1
