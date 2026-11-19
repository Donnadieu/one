#!/bin/bash
# runs: owner-only (make learning) — One's real engine on the owner's own Claude subscription; no CI runner has it
# Tell me when I learn, end to end, with One's real engine in a throwaway home (about eight Claude turns on the
# Claude subscription One already uses, ~10 min). A copy of the app with its own bundle id runs it, so the person's
# chat, settings and running One are never touched. See Sources/LearningLiveCheck.swift.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" --mode --test-learning-live --timeout 1500 \
  --name learning-test --env ONE_LEARN_WINDOW=20 "$@"
