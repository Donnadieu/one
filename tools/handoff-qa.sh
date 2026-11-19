#!/bin/bash
# runs: owner-only (make handoffqa) — a real site, a real Chrome window, the owner watching
# Live QA of a hand-off on a real site (Sources/HandoffQA.swift): One's half from a test copy (own bundle id, scratch
# One folder) with its own throwaway hidden Chrome on QA_PORT (default 9346) and a scratch profile. The engine half
# (the site's steps and hand_off) runs separately against the same port and handoff folder. Opens windows and a
# real Chrome window, so it's only for a live test the owner asked for. The copy starts through Launch Services, so
# it runs outside the folder lock like the real One. Stop it with: touch "$QA/support/quit".
#   make handoffqa        (QA=<scratch dir> to choose the folder)
set -eu
# The same gate as every other check, rather than a credential this script writes for itself: it
# claimed GITHUB_ACTIONS=true at first, then set ONE_LIVE_CHECK=1 by hand, and both were the same
# bypass with nothing naming it. engine-check.sh brings ci-only.sh (which unlocks this script by
# name, off the header above) and engine_launch_env.
. "$(dirname "$0")/engine-check.sh" --lib
QA="${QA:?set QA to a scratch folder}"
PORT="${QA_PORT:-9346}"
# shellcheck disable=SC2194  # constant word, variable pattern: "is this port one of the shared ones?"
case " 9223 9224 9333 " in *" $PORT "*) echo "refusing: $PORT is a shared browser"; exit 2 ;; esac
mkdir -p "$QA/support/handoff" "$QA/chrome"
tools/test-copy.sh handoff-qa "$QA" >/dev/null
# One helper, shared with tools/human-window-check.sh, which had the identical copy of this.
# ONE_LIVE_CHECK carries this script's own name through to the copy, so TestWorld lets the mode run.
engine_launch_env "$QA/One.app/Contents/Info.plist" \
  "ONE_TEST_MODE=--qa-handoff" "ONE_LIVE_CHECK=handoff-qa.sh" "ONE_SUPPORT_DIR=$QA/support" \
  "ONE_QA_PORT=$PORT" "ONE_QA_PROFILE=$QA/chrome" "ONE_CHECK_LOG=$QA/one.txt"
codesign --force -s - "$QA/One.app" >/dev/null 2>&1
: > "$QA/one.txt"
/usr/bin/open -n "$QA/One.app"
echo "started: $QA/one.txt"
