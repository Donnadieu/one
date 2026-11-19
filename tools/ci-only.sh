#!/bin/bash
# Owner's hard rule (Omar, Nov 4 2026): tests never run on the person's Mac BY ACCIDENT. They open windows, take
# the focus and stop him working. Every test script sources this first. There are exactly two ways in:
#
#   1. CI (GitHub Actions) — where every check on a pull request runs.
#   2. ONE_LIVE_CHECK=<this script's name> — a live check the owner asked for BY NAME, because it needs One's
#      installed engine and his own Claude subscription, so no runner can ever have it. Its `make` target sets it
#      (make jobs, make learning, make helperdone, …). Until this existed those checks refused on the Mac and no
#      workflow ran them either, so they tested nothing anywhere: a check reachable from nowhere is a check that
#      silently passes (enforced since: no-orphan-check in tools/lint/one-lint.py).
#
# The name matters. ONE_LIVE_CHECK=1 used to open the door for all twenty scripts that source this file — including
# tools/preflight.sh, which writes inside the person's real One folder, touches ~/.ssh and drives real windows for
# four minutes. One stale `export` in a shell, or an agent setting it once, was the whole hard rule gone. Now the
# variable has to name the script it unlocks, and the script has to declare itself owner-only in its own header
# (the `# runs: owner-only (make <target>) — <why>` line that no-orphan-check already requires), so preflight and
# the nightly soak/sanitizer checks keep refusing no matter what is exported.
#
# What this never relaxes: TestWorld still refuses to run as the real One (bundle id ai.forjado.one) and still
# refuses the person's real One folder, with no opt-in of any kind. A live check runs from a test copy
# (tools/test-copy.sh) with its own bundle id, in a throwaway home.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ME=$(basename "$0")
WANT="${ONE_LIVE_CHECK:-}"
# tools/engine-check.sh is the shared wrapper the thin live checks `exec`, so by the time this runs
# $0 is the wrapper, not the check that asked for it. The wrapper carries no owner-only header of its
# own; the check standing behind it is the one that has to.
#
# ONE_CALLER, not ONE_LIVE_CHECK, is what names that check. Taking the name from the same variable
# the gate is checking made the match vacuous — "is what you asked for what you asked for" — so one
# stale export of any owner-only name let the wrapper run ANY test mode, and unlocked the CI-only
# checks that exec it as well. Each wrapper sets ONE_CALLER to its own basename, which the wrapper
# itself cannot forge, so running engine-check.sh by hand has no caller and is refused.
if [ "$ME" = engine-check.sh ] && [ -n "${ONE_CALLER:-}" ]; then
  ME="$ONE_CALLER"
fi

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  :   # CI: every check on a pull request runs here
elif [ -n "$WANT" ] && [ "$WANT" = "$ME" ] && [ -f "$HERE/$WANT" ] &&
     grep -q '^# runs: owner-only' "$HERE/$WANT"; then
  :   # the owner asked for this one check by name, and that check says it can only run here
else
  echo "refusing: $(basename "$0") runs tests, and tests run in CI (GitHub), never on this Mac."
  if [ -z "$WANT" ]; then
    :
  elif [ "$WANT" != "$ME" ]; then
    echo "         ONE_LIVE_CHECK names '$WANT', which is a different check. It unlocks one script, by"
    echo "         name, so an export left in a shell can't open every other one too — $(basename "$0")"
    echo "         writes this Mac's own One folder and opens real windows."
  elif [ ! -f "$HERE/$WANT" ]; then
    echo "         ONE_LIVE_CHECK names '$WANT', and there is no tools/$WANT."
  else
    echo "         tools/$WANT has no '# runs: owner-only (make <target>) — <why>' header, so nothing says"
    echo "         it can only run here. Add one (no-orphan-check requires it anyway), or run it in CI."
  fi
  echo "FIX: push the branch and read the check on the pull request. A live check that can only run here"
  echo "     (One's installed engine, the owner's own subscription) is started by its make target, which"
  echo "     sets ONE_LIVE_CHECK to that check's own file name: see its 'runs:' line."
  exit 2
fi
