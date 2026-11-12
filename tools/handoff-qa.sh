#!/bin/bash
# Live QA of a hand-off on a real site (Sources/HandoffQA.swift): One's half from a test copy (own bundle id, scratch
# One folder) with its own throwaway hidden Chrome on QA_PORT (default 9346) and a scratch profile. The engine half
# (the site's steps and hand_off) runs separately against the same port and handoff folder. Opens windows and a
# real Chrome window, so it's only for a live test the owner asked for. The copy starts through Launch Services, so
# it runs outside the folder lock like the real One. Stop it with: touch "$QA/support/quit".
#   QA=<scratch dir> tools/handoff-qa.sh
set -eu
cd "$(dirname "$0")/.."
QA="${QA:?set QA to a scratch folder}"
PORT="${QA_PORT:-9346}"
case " 9223 9224 9333 " in *" $PORT "*) echo "refusing: $PORT is a shared browser"; exit 2 ;; esac
mkdir -p "$QA/support/handoff" "$QA/chrome"
tools/test-copy.sh handoff-qa "$QA" >/dev/null
PL="$QA/One.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PL" 2>/dev/null || true
for kv in "ONE_TEST_MODE=--qa-handoff" "GITHUB_ACTIONS=true" "ONE_SUPPORT_DIR=$QA/support" "ONE_QA_PORT=$PORT" \
  "ONE_QA_PROFILE=$QA/chrome" "ONE_CHECK_LOG=$QA/one.txt"; do
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${kv%%=*} string ${kv#*=}" "$PL"
done
codesign --force -s - "$QA/One.app" >/dev/null 2>&1
: > "$QA/one.txt"
/usr/bin/open -n "$QA/One.app"
echo "started: $QA/one.txt"
