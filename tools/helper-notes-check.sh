#!/bin/bash
# runs: owner-only (make helpernotes) — One's real engine on the owner's own Claude subscription; no CI runner has it
# A helper someone opens and talks to started on an older One still knows today's screen and what's built
# (Connections › Browser / Passwords, never a Settings screen), with One's real engine in a throwaway home (three
# short turns on the Claude subscription One already uses). A copy of the app with its own bundle id runs it, so the
# person's chat, settings and running One are never touched. See Sources/HelperNotesCheck.swift.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" --mode --test-helper-notes --timeout 420 \
  --name helpernotes-test --test-engine "$@"
