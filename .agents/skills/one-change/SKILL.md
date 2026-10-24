---
name: one-change
description: Use before any change to One's code. The checklist and the loop that keeps the repo clean.
---

# Making a change to One

1. Read AGENTS.md and the ARCHITECTURE.md row for the file you'll touch.
2. Put new code in the right area file; a new area gets a new file (under 600 lines).
3. Visual change? Render it (`build/One.app/Contents/MacOS/One --render-world <prefix>`), show it, wait for a yes.
4. `make format`, then `make check`. Every failure prints a `FIX:`; follow it, never silence it.
5. Never add to `tools/lint/baseline.json`. If you paid debt down, run `tools/lint/one-lint.py --update`.
6. Release: `make full`, bump VERSION, package, signed commit, `gh release create` with One.zip.

## The compound loop
- A lesson that would help next time: add it here or to the matching skill.
- The same mistake twice: add a rule to `tools/lint/one-lint.py` (id, why, FIX) and a line in
  docs/design-docs/golden-principles.md.
