#!/bin/bash
# The baseline of old lint debt may only shrink. Compares with origin/main (or $1).
cd "$(git rev-parse --show-toplevel)"
REF="${1:-origin/main}"
OLD=$(git show "$REF:tools/lint/baseline.json" 2>/dev/null) || exit 0
python3 - "$OLD" <<'PY'
import json, sys
old = json.loads(sys.argv[1]); new = json.load(open("tools/lint/baseline.json"))
bad = [f"{k}: {old.get(k, 0)} -> {v}" for k, v in new.items() if v > old.get(k, 0)]
if bad:
    print("✗ tools/lint/baseline.json grew. The baseline may only shrink:")
    for b in bad: print("   ", b)
    print("    FIX: fix the new problem instead of adding it to the baseline.")
    sys.exit(1)
PY
