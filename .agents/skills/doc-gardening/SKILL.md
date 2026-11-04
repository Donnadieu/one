---
name: doc-gardening
description: Use when docs/ links feel stale, before a doc-heavy PR, or when the weekly doc-gardening PR needs a look. Keeps docs/ links and index honest.
---

# Doc gardening

A recurring, mostly-automated pass that keeps this repo's hand-written docs
from quietly drifting: broken relative links, a doc nobody can find from
docs/INDEX.md, and a stale entry in `tools/doc-drift-check.py`'s own
code-area -> doc mapping.

## Run it yourself

```
python3 tools/doc-gardening.py --check   # report; exits non-zero on a hard finding
python3 tools/doc-gardening.py --fix     # rewrite what's mechanically safe, report the rest
```

Run `--check` before any PR that moves or renames a doc, or when a link
feels stale. `--fix` only rewrites a broken link when its basename matches
EXACTLY ONE other file in the repo — one candidate means a rename, not a
guess. Everything else (an orphaned doc, a stale mapping entry, prose that's
gone stale) is a judgment call: it gets reported, never guessed at.

## Wait for the cron instead when...

`.github/workflows/doc-gardening.yml` already runs `--fix` every Monday
morning (plus `workflow_dispatch` for an on-demand run) and opens a small PR
titled "doc-gardening: automated fixes" when the tree actually changed. It
never auto-merges — review it like any other PR. If you're not mid-change
and nothing feels urgently broken, let the weekly run catch it rather than
running this by hand.

## Run it yourself instead when...

- You just moved/renamed/deleted a doc and want to catch what you broke
  before pushing.
- A PR review flags a dead link and you want to confirm scope before fixing
  by hand.
- You're extending `tools/doc-drift-check.py`'s `SENSITIVE_AREAS` mapping
  and want to make sure every doc it points at still exists.

## Extending the checks

Both `--check` and `--fix` live in `tools/doc-gardening.py`. Add a new hard
finding as its own `find_*` function returning a list, wired into both
`do_check` and `do_fix`, so a new rule never silently becomes --fix-only or
--check-only by accident.
