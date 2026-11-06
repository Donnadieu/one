#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Standing goals through One's connection to the REAL engine (its own goal loop, One's overlay applied by the install)
# with a stand-in model: goal set, judged done, the turn budget, Stop, pause/resume, a helper's goal, a send waiting
# for a yes. The engine to use: ONE_SUPPORT_DIR's (the fresh-install workflow installs and patches one there).
#   ONE_SUPPORT_DIR=<folder with engine/> tools/goal-engine-check.sh    prints "goal engine ok" when it passes
set -u
cd "$(dirname "$0")/.."
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
H="$SUP/engine/.hermes/bin/hermes"
[ -x "$H" ] || { echo "no engine in $SUP; skipped"; exit 0; }
grep -q "_one_goals_install" "$SUP/engine/acp_adapter/gateway_server.py" || { echo "the goals overlay isn't in this engine"; exit 1; }
W="$SUP/hermes/cache/scratch/goal-check-$$"
trap 'rm -rf "$W"' EXIT
ONE_RUNTIME_DIR="$SUP/hermes/tools" perl -e 'alarm 600; exec @ARGV' /usr/bin/python3 tools/goal-engine-check.py "$H" "$W"
