#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Proves the REAL engine, with One's routine stall overlay hooked into its scheduler (cron/one_routine_stall.py),
# cuts off a routine's streamed reply that sends nothing within the routine idle limit and runs the same turn again
# once the AI can be reached, keeping the work done so far (tools/routine-stall-check.py, a stand-in Anthropic model:
# a quiet reply, and the Mac sleeping through one; Nov 25 and 27 2026). The engine to use: ONE_SUPPORT_DIR's
# (the fresh-install workflow installs and patches one there).
#   ONE_SUPPORT_DIR=<folder with engine/> tools/routine-stall-check.sh    prints "routine stall ok" when it passes
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
E="$SUP/engine"
[ -d "$E/cron" ] || { echo "no engine in $SUP; skipped"; exit 0; }
grep -q "_one_routine_stall_install" "$E/cron/scheduler.py" || { echo "the routine stall overlay isn't in this engine"; exit 1; }
W="$SUP/hermes/cache/scratch/routine-stall-check-$$"
SDK=""
trap 'rm -rf "$W" "$W-sdk"' EXIT
# The check boots onto the engine's committed dependency set itself (routine-stall-check.py, as the engine's own
# processes do), which pm scopes by HERMES_HOME: the engine's data root, as One sets it (Env.hermesHome).
export HERMES_HOME="$SUP/hermes"
PY="" WHY=""
find_python() {
  for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
    WHY=$(cd "$E" && ONE_CHECK_SDK="$SDK" "$p" -I "$REPO/tools/routine-stall-check.py" "$E" --probe 2>&1) && { PY="$p"; return 0; }
  done
  return 1
}
# A fresh engine has no Anthropic SDK: it is an optional extra the engine adds the first time a Claude call needs it
# (agent/anthropic_adapter.py -> pm.ensure_import("anthropic")). This check speaks Anthropic's API, so on a fresh
# install (the fresh-install runner; 0.9.148 and 0.9.149 failed here with "engine python not found") it puts the SDK
# the engine pins (its pyproject's `anthropic` extra) in a throwaway folder with the engine's own uv, searched AFTER
# the engine's own packages (the engine's versions always win; the engine itself is never changed), and runs with
# lazy installs off so nothing installs in the middle of a timed stall.
if ! find_python; then
  PIN=$(sed -n 's/^anthropic = \["\(anthropic==[0-9.]*\)"\].*/\1/p' "$E/pyproject.toml" | head -1)
  UV=""
  for u in "$SUP"/hermes/tools/uv-*/uv; do [ -x "$u" ] && UV="$u"; done
  [ -n "$PIN" ] && [ -x "$UV" ] || { echo "can't add the Anthropic SDK: pin '${PIN}', uv '${UV}'"; exit 1; }
  for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
    (cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import hermes_cli.plugins" >/dev/null 2>&1) || continue
    echo "adding $PIN (the engine's anthropic extra) for this check only"
    perl -e 'alarm 600; exec @ARGV' "$UV" pip install -q --python "$p" --target "$W-sdk" "$PIN" 2>&1 | tail -5
    SDK="$W-sdk"
    break
  done
  find_python || { echo "engine python not found"; printf '%s\n' "$WHY" | tail -3; exit 1; }
fi
cd "$E" && ONE_CHECK_SDK="$SDK" HERMES_DISABLE_LAZY_INSTALLS=1 HERMES_RUNTIME_DIR="$SUP/hermes/tools" \
  perl -e 'alarm 300; exec @ARGV' "$PY" -I "$REPO/tools/routine-stall-check.py" "$E" "$W" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
