#!/bin/bash
# Owner's hard rule (Omar, Nov 4 2026): tests never run on the person's Mac BY ACCIDENT. They open windows, take
# the focus and stop him working. Every test script sources this first. There are exactly two ways in:
#
#   1. CI (GitHub Actions) — where every check on a pull request runs.
#   2. ONE_LIVE_CHECK=1 — a live check the owner asked for by name, because it needs One's installed engine and
#      his own Claude subscription, so no runner can ever have it. The `make` target sets it (make jobs,
#      make learning, make helperdone, …) and nothing else does. Until this existed those checks refused on the
#      Mac and no workflow ran them either, so they tested nothing anywhere: a check reachable from nowhere is
#      a check that silently passes (enforced since: no-orphan-check in tools/lint/one-lint.py).
#
# What ONE_LIVE_CHECK does not relax: TestWorld still refuses to run as the real One (bundle id ai.forjado.one)
# and still refuses the person's real One folder. A live check runs from a test copy (tools/test-copy.sh) with
# its own bundle id, in a throwaway home.
if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "${ONE_LIVE_CHECK:-}" != "1" ]; then
  echo "refusing: $(basename "$0") runs tests, and tests run in CI (GitHub), never on this Mac."
  echo "FIX: push the branch and read the check on the pull request. A live check that can only run here"
  echo "     (One's installed engine, the owner's own subscription) is started by its make target, which sets"
  echo "     ONE_LIVE_CHECK=1: see the 'runs:' line at the top of this script's caller."
  exit 2
fi
