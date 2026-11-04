#!/bin/bash
# Owner's hard rule (Omar, Nov 4 2026): tests never run on the person's Mac. They open windows, take the focus
# and stop him working. Every test script sources this first; outside CI (GitHub Actions) it stops right here.
if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "refusing: $(basename "$0") runs tests, and tests run in CI (GitHub), never on this Mac."
  echo "FIX: push the branch and read the check on the pull request."
  exit 2
fi
