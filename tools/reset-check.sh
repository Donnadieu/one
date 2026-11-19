#!/bin/bash
# `--reset` ("reset onboarding") must clear only onboarding/setup settings, never helpers, bubbles or the shelf:
# the 0.9.74 incident emptied `helpers` (a finished "Message history" helper vanished) with nothing in that
# release's own diff touching helpers persistence. A copy of the app with its own bundle id runs this, so the
# person's real settings are never touched. No engine and no money: it runs in CI on every pull request.
# See Sources/ResetCheck.swift.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" --mode --test-reset --timeout 60 --name reset-test "$@"
