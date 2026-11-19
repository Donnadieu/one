#!/bin/bash
# runs: owner-only (make helpercut) — One's real engine on the owner's own Claude subscription; no CI runner has it
# Helpers cut off by an engine restart are never shown done: they show stopped, pick back up by themselves and are
# done only with their real answer. One's real engine in a throwaway home (two short turns on the Claude
# subscription One already uses). See Sources/HelperCutCheck.swift. A copy with its own bundle id runs it.
exec "$(dirname "$0")/engine-check.sh" --mode --test-helper-stop --timeout 700 \
  --name helpercut-test --engine-link --expect '^helper-cut ok' "$@" -- --cut
