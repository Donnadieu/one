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
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/install-home"
PY="" WHY=""
find_python() {
  for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
    WHY=$(cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import anthropic, cron.scheduler, run_agent" 2>&1) && { PY="$p"; return 0; }
  done
  return 1
}
# A fresh engine has no Anthropic SDK: it is an optional extra the engine adds the first time a Claude call needs it
# (agent/anthropic_adapter.py -> pm.ensure_import("anthropic"), from the engine's own launcher). This check speaks
# Anthropic's API and runs the engine's python directly, where only an explicit install may add an extra, so on a
# fresh install (the fresh-install runner; 0.9.148 and 0.9.149 failed here with "engine python not found") it adds
# that extra with the command the engine itself names, `hermes pm install --extra anthropic`, then runs with lazy
# installs off so nothing installs in the middle of a timed stall.
if ! find_python; then
  H="$E/.hermes/bin/hermes"
  [ -x "$H" ] || { echo "no engine launcher at $H"; exit 1; }
  (cd "$E" && HERMES_HOME="$W/install-home" perl -e 'alarm 900; exec @ARGV' "$H" pm install --extra anthropic 2>&1 | tail -3)
  find_python || { echo "engine python not found"; printf '%s\n' "$WHY" | tail -3; exit 1; }
fi
cd "$E" && HERMES_DISABLE_LAZY_INSTALLS=1 HERMES_RUNTIME_DIR="$SUP/hermes/tools" \
  perl -e 'alarm 300; exec @ARGV' "$PY" -I "$REPO/tools/routine-stall-check.py" "$E" "$W" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
