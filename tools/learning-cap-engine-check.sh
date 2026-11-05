#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Proves the REAL engine loads One's learning cap and holds the after-job review's edits, in a scratch home.
# The engine to use: ONE_SUPPORT_DIR's (the fresh-install workflow installs one there).
#   ONE_SUPPORT_DIR=<folder with engine/> tools/learning-cap-engine-check.sh    prints "engine cap ok" when it passes
set -u
cd "$(dirname "$0")/.."
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
E="$SUP/engine"
[ -d "$E/hermes_cli" ] || { echo "no engine in $SUP; skipped"; exit 0; }
PY=""
for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
  (cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import hermes_cli.plugins" >/dev/null 2>&1) && { PY="$p"; break; }
done
[ -n "$PY" ] || { echo "engine python not found"; exit 1; }
W="$SUP/hermes/cache/scratch/cap-check-$$"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/plugins/one-learning-cap" "$W/home/skills"
cp tools/overlay/plugins/one-learning-cap/__init__.py tools/overlay/plugins/one-learning-cap/plugin.yaml "$W/home/plugins/one-learning-cap/"
printf 'plugins:\n  enabled:\n    - one-learning-cap\n' > "$W/home/config.yaml"
cat > "$W/check.py" <<'EOF'
import datetime as dt, json, os, sys
sys.path.insert(0, '.')
from hermes_cli import plugins as P
from tools.skill_provenance import set_current_write_origin, reset_current_write_origin, BACKGROUND_REVIEW
P.discover_plugins(force=True)
fails = 0
def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1
ledger = os.path.join(os.environ["HERMES_HOME"], "skills", ".curator_ledger.jsonl")
def edits(n):
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    with open(ledger, "w") as f:
        for i in range(n):
            f.write(json.dumps({"ts": now, "actor": "curator", "action": "patch", "skill": f"s{i}"}) + "\n")
args = {"operations": [{"name": "fresh", "action": "patch", "old_string": "a", "new_string": "b"}]}
block = lambda: P.get_pre_tool_call_block_message("skill_manage", args, session_id="cap-check")
edits(9)
check("the person's own recipe edit is never held (9 review edits today)", block() is None)
t = set_current_write_origin(BACKGROUND_REVIEW)
edits(0)
check("the after-job review's first edit of the day passes", block() is None)
edits(5)
m = block()
check("its 6th edit of the day is held", bool(m))
check("and it's told not to retry", bool(m) and "Don't retry" in m)
reset_current_write_origin(t)
log = os.path.join(os.environ["HERMES_HOME"], "logs", "one-learning-cap.log")
check("the held edit is logged", os.path.exists(log) and "held patch fresh" in open(log).read())
print("engine cap ok" if fails == 0 else f"engine cap: {fails} failed")
sys.exit(1 if fails else 0)
EOF
cd "$E" && HERMES_HOME="$W/home" HERMES_RUNTIME_DIR="$SUP/hermes/tools" "$PY" -I "$W/check.py" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
