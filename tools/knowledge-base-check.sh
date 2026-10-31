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
cd "$(dirname "$0")/.."
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
