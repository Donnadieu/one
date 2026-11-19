#!/bin/bash
# runs: owner-only (make glass) — measures real compositing on a real screen; a CI runner reports blur -1
# Home glass: only the blur is left under the tint (Claude Design, blur 40 / saturate 1.4), and it stays
# that way after focus, losing focus, a resize and an appearance change. See Sources/GlassCheck.swift.
#
# Why not CI: the check reads the window's live visual-effect layers. On a macOS runner there is no
# compositing window server behind them, so every reading comes back `visible [], blur -1.0,
# saturation -1.0` and the check fails for a reason that has nothing to do with the change. It sat in
# tools/preflight.sh behind `[ $CI = 0 ]` instead, which every venue bypasses with --ci, so it ran
# nowhere at all. Owner-only and runnable by name is the honest version of that.
exec env ONE_CALLER="$(basename "$0")" "$(dirname "$0")/engine-check.sh" \
  --mode --test-glass --timeout 120 --name glass-test --expect '^glass ok' "$@"
