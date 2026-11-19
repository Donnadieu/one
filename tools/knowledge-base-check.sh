#!/bin/bash
# Knowledge-base integrity test (Forge harness-engineering skill, artifact 8),
# right-sized for this repo: a shell check wired into `make check`/CI rather than
# a Swift test target (One has no test target; its own CLI --test-* modes and
# tools/preflight.sh are the test infrastructure here).
#
# Asserts:
#   1. Every doc the harness-engineering skill mandates actually exists.
#   2. docs/INDEX.md has no broken or orphaned entries (delegates to
#      tools/doc-gardening.py --check, which already does this fully --
#      never reimplement link/orphan checking here).
#   3. AGENTS.md stays a table of contents, not an encyclopedia (line cap).
#
# Usage: tools/knowledge-base-check.sh
# Exit 0 = clean. Exit 1 = a hard finding (prints what and the fix).
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
bad() { echo "✗ $1"; fail=1; }
ok()  { echo "✓ $1"; }

echo "Mandated docs exist"
MANDATED=(
  AGENTS.md
  CLAUDE.md
  docs/ARCHITECTURE.md
  docs/DESIGN.md
  docs/PRODUCT_SENSE.md
  docs/QUALITY_SCORE.md
  docs/SECURITY.md
  docs/RELIABILITY.md
  docs/design-docs/core-beliefs.md
  docs/design-docs/golden-principles.md
  docs/INDEX.md
  docs/exec-plans/README.md
  docs/exec-plans/tech-debt-tracker.md
)
for f in "${MANDATED[@]}"; do
  if [ -s "$f" ]; then
    ok "$f exists"
  else
    bad "$f is missing or empty. FIX: create it (see .agents/skills/harness-engineering or docs/exec-plans/active/hardening.md section D2) and link it from docs/INDEX.md."
  fi
done

echo
echo "docs/INDEX.md: no broken links, no orphaned docs (tools/doc-gardening.py --check)"
if python3 tools/doc-gardening.py --check; then
  ok "doc-gardening --check is clean"
else
  bad "doc-gardening --check found a hard finding above. FIX: run 'python3 tools/doc-gardening.py --fix' for mechanical repairs, then fix any orphan/stale-mapping finding it leaves for a human (usually: add a one-line link from docs/INDEX.md or docs/exec-plans/README.md)."
fi

echo
echo "Every rule named as an enforcer in the docs exists, and every rule is named"
# golden-principles.md's own first line is "Each rule names what enforces it. A rule without an
# enforcer is a gap." Nothing checked that the names on either side matched, so the table could
# point at a rule that doesn't exist (it pointed at `--prove`, which is a flag) and a rule could be
# deleted from the lint with the doc still claiming it. This is the same trick the architecture
# table already gets: make the doc load-bearing, so it can't rot quietly.
if python3 - <<'PY'
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join("tools", "lint"))
out = subprocess.run([sys.executable, "tools/lint/one-lint.py", "--list"], capture_output=True, text=True)
if out.returncode != 0:
    print(f"    one-lint.py --list failed: {out.stderr.strip()[:200]}")
    sys.exit(1)
rules = {line.split(":", 1)[0] for line in out.stdout.split("\n") if line and not line.startswith(" ")}

DOCS = ["docs/design-docs/golden-principles.md", "docs/ARCHITECTURE.md", "docs/SECURITY.md", "AGENTS.md"]
named = {}
for doc in DOCS:
    try:
        text = open(doc, encoding="utf-8").read()
    except FileNotFoundError:
        continue
    for rid in re.findall(r'one-lint:\s*`?([\w-]+)`?', text):
        named.setdefault(rid, doc)

bad = False
for rid, doc in sorted(named.items()):
    if rid not in rules:
        print(f"    {doc} says `one-lint: {rid}` enforces a rule, but one-lint.py has no such rule.")
        print("    FIX: name a real rule (tools/lint/one-lint.py --list), or add the rule.")
        bad = True
for rid in sorted(rules - set(named)):
    print(f"    one-lint rule `{rid}` is named by none of {', '.join(DOCS)}.")
    print(f"    FIX: add it to the table in docs/design-docs/golden-principles.md as `one-lint: {rid}`, "
          f"so the rule and the doc that claims it can't drift apart.")
    bad = True
sys.exit(1 if bad else 0)
PY
then
  ok "the docs and one-lint.py name the same rules"
else
  bad "the docs and one-lint.py disagree about which rules exist (above)."
fi

echo
echo "AGENTS.md stays a table of contents, not an encyclopedia"
MAX_LINES=200
LINES=$(wc -l < AGENTS.md | tr -d ' ')
if [ "$LINES" -le "$MAX_LINES" ]; then
  ok "AGENTS.md is $LINES lines (<= $MAX_LINES)"
else
  bad "AGENTS.md is $LINES lines (> $MAX_LINES). FIX: move the detail into docs/ (ARCHITECTURE.md, a repo skill under .agents/skills/, or exec-plans) and leave only a pointer in AGENTS.md."
fi

echo
if [ "$fail" = 0 ]; then
  echo "knowledge-base-check: clean"
else
  echo "knowledge-base-check: FAILED"
fi
exit $fail
