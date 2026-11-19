#!/bin/bash
# runs: owner-only (make followups) — One's real engine on the owner's own Claude subscription; no CI runner has it
# Sending while busy, end to end, with One's real engine in a throwaway home (a short turn or two on the Claude
# subscription One already uses). A copy of the app with its own bundle id runs it, so the person's chat, settings
# and running One are never touched. See Sources/FollowUpCheck.swift.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" --mode --test-followups --timeout 480 \
  --name followups-test --engine-link "$@"
