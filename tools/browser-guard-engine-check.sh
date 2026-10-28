#!/bin/bash
# Proves the REAL engine loads One's browser guard and blocks a visible browser launch, in a scratch home.
# Nothing is started: the guard reads the command and answers; the person's own One home is never changed.
#   tools/browser-guard-engine-check.sh     prints "engine guard ok" when it passes
set -u
cd "$(dirname "$0")/.."
SUP="$HOME/Library/Application Support/One"
E="$SUP/engine"
[ -d "$E/hermes_cli" ] || { echo "no engine on this Mac; skipped"; exit 0; }
PY=""
for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
  (cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import hermes_cli.plugins" >/dev/null 2>&1) && { PY="$p"; break; }
done
[ -n "$PY" ] || { echo "engine python not found"; exit 1; }
# Scratch inside One's folder (the folder lock lets the engine read it); removed at the end.
W="$SUP/hermes/cache/scratch/guard-check-$$"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/plugins/one-browser-guard" "$W/guard"
cp tools/overlay/plugins/one-browser-guard/__init__.py tools/overlay/plugins/one-browser-guard/plugin.yaml "$W/home/plugins/one-browser-guard/"
printf 'plugins:\n  enabled:\n    - one-browser-guard\nbrowser:\n  headed: false\n' > "$W/home/config.yaml"
cat > "$W/check.py" <<'EOF'
import os, sys
sys.path.insert(0, '.')
from hermes_cli import plugins as P
P.discover_plugins(force=True)
fails = 0
def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1
def block(tool, args):
    return P.get_pre_tool_call_block_message(tool, args, session_id="engine-check")
m = block("terminal", {"command": 'open -g -n -a "Google Chrome" --args --headless=new https://x.com/home'})
check("the engine blocks `open -a Chrome` (what popped up windows)", bool(m))
check("and asks in plain words", bool(m) and "Can I?" in m)
check("the engine blocks AppleScript driving Arc", bool(block("terminal", {"command": "osascript -e 'tell application \"Arc\" to activate'"})))
check("the engine blocks webbrowser.open", bool(block("execute_code", {"code": "import webbrowser\nwebbrowser.open('https://x.com')"})))
check("the hidden browser over its port still works", block("terminal", {"command": "curl -s localhost:9223/json/version"}) is None)
log = os.path.join(os.environ["HERMES_HOME"], "logs", "one-browser-guard.log")
check("each block is logged", os.path.exists(log) and "blocked terminal" in open(log).read())
print("engine guard ok" if fails == 0 else f"engine guard: {fails} failed")
sys.exit(1 if fails else 0)
EOF
cd "$E" && HERMES_HOME="$W/home" HERMES_RUNTIME_DIR="$SUP/hermes/tools" ONE_GUARD_DIR="$W/guard" "$PY" -I "$W/check.py" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
