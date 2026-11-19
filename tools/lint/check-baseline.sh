#!/bin/bash
# A baseline of old lint debt may only shrink. Compares with origin/main (or $1).
#   tools/lint/check-baseline.sh [ref] [baseline file, default tools/lint/baseline.json]
#   tools/lint/check-baseline.sh --all [ref]    every tools/lint/*baseline.json, so a third one is
#                                               guarded in all three places the day it is added
cd "$(git rev-parse --show-toplevel)" || exit 1
if [ "${1:-}" = --all ]; then
  rc=0
  for f in tools/lint/*baseline.json; do
    tools/lint/check-baseline.sh "${2:-origin/main}" "$f" || rc=1
  done
  exit $rc
fi
REF="${1:-origin/main}"
FILE="${2:-tools/lint/baseline.json}"
# A ref that doesn't resolve and a baseline that is new on that ref both used to `exit 0` with no
# output, so a stale or missing origin/main made the whole ratchet a silent no-op — and so did a typo
# in the file name. They are different things and they say different things now.
if ! git rev-parse --verify --quiet "$REF" >/dev/null; then
  echo "✗ $REF isn't here, so the baseline ratchet could not run (it did not pass: it did not run)."
  echo "    FIX: git fetch origin main"
  exit 1
fi
if [ ! -f "$FILE" ]; then
  echo "✗ $FILE doesn't exist, so there is nothing to compare."
  echo "    FIX: check the path. A linter seeds its baseline with --init."
  exit 1
fi
if ! OLD=$(git show "$REF:$FILE" 2>/dev/null); then
  echo "· $FILE is new on $REF, so there is nothing to compare yet (first commit of this baseline)."
  exit 0
fi
python3 - "$OLD" "$FILE" "$REF" <<'PY'
import json, subprocess, sys
old_all = json.loads(sys.argv[1]); path = sys.argv[2]; new_all = json.load(open(path)); ref = sys.argv[3]


def existed(rid):
    """Did this rule exist at the base ref?

    Not "does it have rows in the old baseline" — a rule with no debt has no rows, so that reading
    handed a fresh seed allowance to every clean rule, which is the whole hole: add a file with
    seven pieces of jargon, write one `ui-jargon|…` line, and both the lint and this check go quiet.
    A rule's one-time seed belongs to a rule that is genuinely NEW.
    """
    for f in ("tools/lint/one-lint.py", "tools/lint/repo_rules.py", "tools/lint/ext-lint.py"):
        out = subprocess.run(["git", "show", f"{ref}:{f}"], capture_output=True, text=True)
        if out.returncode == 0 and f'"{rid}"' in out.stdout:
            return True
    return False


def rule(key):
    return key.split("|", 1)[0]


# A key starting with "_" is metadata. "_allow-growth" is the one and only way past the per-rule
# check below:
#
#   {"_allow-growth": {"<rule>": {"to": <the exact new total>, "why": "<in words>"}}}
#
# It exists because a rule can get MORE ACCURATE — reading the file set from docs/ARCHITECTURE.md
# instead of a hand-typed list stopped exempting a file that had six real violations in it — and a
# total going up for that reason is not the same as somebody adding debt.
#
# The CEILING is what makes it an allowance and not a blank cheque. With a reason alone, an entry
# excused that rule's growth without limit for as long as it sat there, so the first entry turned the
# per-rule check off for its rule — including after this branch merged and the growth it described
# was already in main. `to` has to equal the new total exactly, so the entry stops applying the
# moment anything else grows under that rule, and an entry whose number no longer matches is a
# failure rather than a quiet pass.
ALLOW = {}
for _rid, _spec in new_all.get("_allow-growth", {}).items():
    if isinstance(_spec, dict) and str(_spec.get("why", "")).strip() and isinstance(_spec.get("to"), int):
        ALLOW[_rid] = _spec
old = {k: v for k, v in old_all.items() if not k.startswith("_")}
new = {k: v for k, v in new_all.items() if not k.startswith("_")}


# An EXISTING key may never grow: that is the ratchet.
bad = [f"{k}: {old.get(k, 0)} -> {v}" for k, v in new.items() if k in old and v > old[k]]

# A key absent from the old baseline used to be free, on the grounds that a newly-introduced rule
# gets grandfathered once. But the key is "rule|file", so that also exempted every NEW file and
# every RENAME: add Sources/New.swift with 7 pieces of jargon, write one line in the baseline, and
# both the lint and this check went quiet while the debt went up. So the seed allowance belongs to
# the RULE, and only to a rule that did not exist at the base ref; after that its total may only fall.
seeded = {rule(k) for k in new if existed(rule(k))} | {rule(k) for k in old}
for rid in sorted({rule(k) for k in new} - seeded):
    print(f"· {rid} is a new rule here, so its rows are its one-time seed ({sum(v for k, v in new.items() if rule(k) == rid)} findings).")
for rid in sorted(seeded):
    was = sum(v for k, v in old.items() if rule(k) == rid)
    now = sum(v for k, v in new.items() if rule(k) == rid)
    if now <= was:
        continue
    if rid in ALLOW and ALLOW[rid]["to"] == now:
        print(f"· {rid} in total: {was} -> {now}, allowed by _allow-growth in {path}:")
        print(f"    {ALLOW[rid]['why']}")
        print("    This is the only way past the ratchet. Delete the entry when the debt is paid.")
        continue
    if rid in ALLOW:
        bad.append(f"{rid} in total: {was} -> {now}, but _allow-growth allows exactly "
                   f"{ALLOW[rid]['to']}. An allowance is for ONE known change, not a standing "
                   f"exemption. FIX: fix the new finding; don't raise the number.")
        continue
    bad.append(f"{rid} in total: {was} -> {now} (a new file or a rename doesn't get a fresh allowance)")
# An allowance that isn't excusing anything should go, because it would pre-authorise the NEXT bit
# of growth under that rule. A notice and not a failure, though: these entries stop being needed the
# moment this branch merges (the growth they excuse is then part of main), and failing would turn the
# next, unrelated pull request red for something it didn't do.
for rid in sorted(set(ALLOW) - {r for r in seeded if sum(v for k, v in new.items() if rule(k) == r)
                                > sum(v for k, v in old.items() if rule(k) == r)}):
    print(f"· _allow-growth names {rid}, but {rid} didn't grow against {ref}.")
    print(f"    FIX: delete that entry from {path}. While it is there it would excuse the next bit of "
          f"growth under {rid} without anyone reviewing it.")

if bad:
    print(f"✗ {path} grew. The baseline may only shrink:")
    for b in bad: print("   ", b)
    print("    FIX: fix the new problem instead of adding it to the baseline.")
    sys.exit(1)
PY
