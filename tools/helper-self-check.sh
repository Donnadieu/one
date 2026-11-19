#!/bin/bash
# runs: owner-only (make helperself) — One's real engine on the owner's own Claude subscription; no CI runner has it
# A helper someone opens and talks to does the work itself and never shows a "[helper: …]" line, with One's real
# engine in a throwaway home (two short turns on the Claude subscription One already uses). A copy of the app with
# its own bundle id runs it, so the person's chat, settings and running One are never touched.
# See Sources/HelperSelfCheck.swift.
exec "$(dirname "$0")/engine-check.sh" --mode --test-helper-self --timeout 420 \
  --name helperself-test "$@"
