#!/bin/bash
# The git hooks are on, and the three places the rules run haven't drifted apart.
#
# .githooks/ is tracked, but a tracked hook does nothing until someone runs `make hooks` to point
# core.hooksPath at it. A fresh clone therefore had no pre-commit guard and nothing said so: the
# first commit from it could be unsigned, carry the Andela identity, or break a lint rule, and the
# only thing that would notice is CI, after the push. This runs in `make check`, so the gate itself
# tells you the gate isn't armed.
#
#   tools/hooks-check.sh        on the Mac: hooks installed, identity pinned, the three venues agree
#   tools/hooks-check.sh --ci   in CI: there are no hooks to install, so only the drift half runs
#
# Adding a gate means adding a row to REQUIRED with the venues that must run it. A venue a gate
# skips needs a reason there, because a gate left out of one place on purpose is a decision.
#
# The drift half reads all THREE venues and checks them BOTH WAYS against the REQUIRED table below:
# every gate must run in the venues that table names, and a gate found in a venue the table doesn't
# name is a finding too. It used to grep two of the three for three hardcoded names — so `ext-lint.py`
# and `--prove` could be deleted from the hook, and any step at all from rules.yml, while this script
# said "clean" and five documents said it had proved they agree. Comparing the venues only against
# each other wasn't enough either: that can't see a gate deleted from all three, because the sets
# stay equal. The gates themselves come out of the files; REQUIRED is the contract they're held to.
#
# Exit 0 = fine. Exit 1 = a finding, with the fix.
set -u
cd "$(dirname "$0")/.." || exit 1
CI=0
[ "${1:-}" = --ci ] && CI=1
fail=0
bad() { echo "✗ $1"; fail=1; }
ok() { echo "✓ $1"; }

if [ "$CI" = 0 ]; then
  HP=$(git config core.hooksPath || true)
  if [ "$HP" = .githooks ]; then
    ok "git hooks are on (core.hooksPath = .githooks)"
  else
    bad "git hooks are NOT on (core.hooksPath is '${HP:-unset}'), so nothing checks a commit before it is made. FIX: run 'make hooks'."
  fi
  for f in .githooks/pre-commit .githooks/pre-push; do
    if [ -x "$f" ]; then ok "$f is executable"; else bad "$f is missing or not executable. FIX: chmod +x $f"; fi
  done
  # Who the next commit would be is check-identity.sh's own question, and it answers it better: it
  # reads the EFFECTIVE identity (git var, so an env override or an include counts) and checks
  # gpg.format too. This used to re-check four of those keys from raw local config with the constants
  # typed again here, so the two could disagree inside one `make check`.
  if tools/check-identity.sh; then
    ok "this clone commits as Donnadieu, signed (tools/check-identity.sh)"
  else
    bad "the commit identity isn't pinned to Donnadieu. FIX: run 'make hooks' (and see the FIX above)."
  fi
fi

# The drift half, which CI can run too: the pre-commit hook, `make check` and rules.yml must agree
# on which gates run, or a commit passes one and another disagrees about what the rules are.
echo
echo "The pre-commit hook, 'make check' and rules.yml agree on the rules"
python3 - <<'PY' || fail=1
import re
import subprocess
import sys

# A gate is the script that runs plus the flags that change what it does, so `one-lint.py` and
# `one-lint.py --prove` are two gates and the same call written three ways is one.
GATE = re.compile(r'(?:^|[\s"\'(])(?:\./)?((?:tools/)[\w./-]*?([\w.-]+\.(?:sh|py)))')
FLAG = re.compile(r'\s(--[\w-]+)')
# Only --ci is a dialect difference: CI has no copy of the GPG key, so it checks the same range
# without the signature. --all and --range change WHAT IS CHECKED (every baseline, not one; the whole
# commit range, not just the config), so they stay in the signature — dropping them meant deleting
# `--all` from the hook, or `--range` from the Makefile, left the three sets still matching.
DIALECT = {"--ci"}


def shell_gates(text):
    """Gates in a shell script or a Makefile: every non-comment line is a command."""
    out = set()
    for line in text.split("\n"):
        line = re.sub(r'(?:^|(?<=\s))#.*$', "", line)
        for _whole, base in GATE.findall(line):
            out.add(" ".join([base] + sorted(set(FLAG.findall(line)) - DIALECT)))
    if re.search(r'swift-format\s+lint', text):
        out.add("swift-format lint")
    return out


def workflow_gates(text):
    """Gates in a workflow: `run:` bodies only.

    A step's `name:` is prose. Reading it as an invocation meant rules.yml could have every `run:`
    line replaced with `echo` and this check still reported the three venues in agreement — the same
    mention-read-as-wiring defect the orphan rule had.
    """
    out, run_at = set(), None
    for line in text.split("\n"):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        m = re.match(r'(?:-\s+)?run:\s*(.*)$', stripped)
        if m:
            indent += 2 if stripped.startswith("-") else 0
            run_at, body = indent, m.group(1)
        elif run_at is not None and (not stripped or indent > run_at):
            body = stripped
        else:
            run_at = None
            continue
        body = re.sub(r'(?:^|(?<=\s))#.*$', "", body)
        for _whole, base in GATE.findall(body):
            out.add(" ".join([base] + sorted(set(FLAG.findall(" " + body)) - DIALECT)))
        if re.search(r'swift-format\s+lint', body):
            out.add("swift-format lint")
    return out


def run(*cmd):
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        print(f"✗ `{' '.join(cmd)}` failed, so the venues could not be compared: {out.stderr.strip()[:200]}")
        sys.exit(1)
    return out.stdout


hook = shell_gates(open(".githooks/pre-commit", encoding="utf-8").read())
# `make -n check` prints the commands every target `check:` depends on would run, so the closure is
# make's answer, not a list of target names typed here.
gate = shell_gates(run("make", "-n", "check"))
ci = workflow_gates(open(".github/workflows/rules.yml", encoding="utf-8").read())

# Differences that are on purpose. Each needs a reason, because each is a rule that does NOT run
# before a commit.
found = {"the hook": hook, "make check": gate, "rules.yml": ci}

# The contract, declared once: every gate this repo enforces, and which of the three venues has to
# run it. Comparing the venues only against EACH OTHER could not see a gate deleted from all three
# (the sets stayed equal), and a hardcoded list of bare names couldn't see a gate that was added.
# This is both directions: a gate missing from a venue that needs it is a finding, and a gate found
# in a venue but absent from this table is a finding too, so adding one means saying where it runs.
#
# A venue a gate skips needs a reason. A rule deliberately left out of one place is a decision, and
# a decision with nothing written down is how a list like this rots.
REQUIRED = {
    "check-identity.sh": ({"the hook", "make check", "rules.yml"}, {}),
    "check-identity.sh --range": ({"make check"}, {
        "the hook": "the hook checks the config; a range needs a fetch, which a commit-time hook shouldn't do",
        "rules.yml": "runs there as --ci: author and committer, but not the signature (CI has no copy of the key)",
    }),
    "swift-format lint": ({"the hook", "make check"}, {
        "rules.yml": "needs macOS (xcrun), so it runs in preflight.yml part 1 instead",
    }),
    "one-lint.py": ({"the hook", "make check", "rules.yml"}, {}),
    "one-lint.py --prove": ({"the hook", "make check", "rules.yml"}, {}),
    "ext-lint.py": ({"the hook", "make check", "rules.yml"}, {}),
    "check-baseline.sh --all": ({"the hook", "make check", "rules.yml"}, {}),
    "doc-drift-check.py": ({"make check", "rules.yml"}, {
        "the hook": "needs a diff against origin/main, which a commit-time hook shouldn't fetch",
    }),
    "knowledge-base-check.sh": ({"make check", "rules.yml"}, {
        "the hook": "reads every doc; too slow for every commit",
    }),
    "brain-starter-bundle.py": ({"the hook", "make check", "rules.yml"}, {}),
    "hooks-check.sh": ({"make check", "rules.yml"}, {
        "the hook": "it would be checking itself, and `make check` already runs it",
    }),
}

problems = []
for g, (venues, why_not) in REQUIRED.items():
    for v in sorted(venues):
        if g not in found[v]:
            problems.append(f"{g} should run in {v} and doesn't. FIX: put it back, or move {v} into "
                            f"that gate's reasons in REQUIRED (tools/hooks-check.sh) and say where it runs instead.")
    for v in sorted(set(found) - venues):
        if g in found[v]:
            problems.append(f"{g} runs in {v}, which REQUIRED says it doesn't "
                            f"({why_not.get(v, 'no reason recorded')}). FIX: add {v} to its venues in "
                            f"tools/hooks-check.sh, or take the call out.")
        elif v not in why_not:
            problems.append(f"REQUIRED says {g} doesn't run in {v}, with no reason. FIX: write one in "
                            f"tools/hooks-check.sh — a gate that skips a venue on purpose is a decision.")
for v, gs in sorted(found.items()):
    for g in sorted(gs - set(REQUIRED)):
        problems.append(f"{v} runs {g}, which isn't in REQUIRED in tools/hooks-check.sh. FIX: add it "
                        f"there with the venues that must run it, so the next reader — and the other "
                        f"two venues — know it exists.")

for p in problems:
    print(f"✗ {p}")
if not problems:
    print(f"✓ all {len(REQUIRED)} gates run in the venues REQUIRED names, and nowhere unaccounted for")
    for g, (venues, why_not) in sorted(REQUIRED.items()):
        for v, why in sorted(why_not.items()):
            print(f"    · {g} is not in {v}: {why}")
sys.exit(1 if problems else 0)
PY

echo
if [ "$fail" = 0 ]; then
  echo "hooks-check: clean"
else
  echo "hooks-check: FAILED"
fi
exit $fail
