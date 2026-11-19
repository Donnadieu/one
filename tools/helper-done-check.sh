#!/bin/bash
# runs: owner-only (make helperdone) — One's real engine on the owner's own Claude subscription; no CI runner has it
# Finished helpers, end to end, with One's real engine in a throwaway home (a few short turns on the Claude
# subscription One already uses): orange until opened, one "by the way" line after the reply in progress, never the
# result again; a good morning gets one combined report. A copy of the app with its own bundle id runs it, so the
# person's chat, settings and running One are never touched. See Sources/HelperDoneCheck.swift.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" --mode --test-helper-done --timeout 840 \
  --name helperdone-test --engine-link "$@"
