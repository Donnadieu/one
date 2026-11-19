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
# The drift half reads all THREE venues and compares them as sets. It used to grep two of them for
# three hardcoded names — so `ext-lint.py` and `--prove` could be deleted from the hook, and any step
# at all from rules.yml, while this script said "clean" and five documents said it had proved they
# agree. Nothing is enumerated here now: the gates come out of the files, and the only hand-written
# list is HOOK_SKIPS, the differences that are on purpose.
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


def gates(text, drop=()):
    out = set()
    for line in text.split("\n"):
        line = re.sub(r'(?:^|(?<=\s))#.*$', "", line)
        for whole, base in GATE.findall(line):
            if base in drop:
                continue
            # --ci and --range are the same gate asked in each venue's own dialect (CI has no copy
            # of the GPG key, so it checks the range without the signature); --all likewise.
            flags = sorted(set(FLAG.findall(line)) - {"--ci", "--range", "--all"})
            out.add(" ".join([base] + flags))
    if re.search(r'swift-format\s+lint', text):
        out.add("swift-format lint")
    return out


def run(*cmd):
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        print(f"✗ `{' '.join(cmd)}` failed, so the venues could not be compared: {out.stderr.strip()[:200]}")
        sys.exit(1)
    return out.stdout


hook = gates(open(".githooks/pre-commit", encoding="utf-8").read())
# `make -n check` prints the commands every target `check:` depends on would run, so the closure is
# make's answer, not a list of target names typed here.
gate = gates(run("make", "-n", "check"))
ci = gates(open(".github/workflows/rules.yml", encoding="utf-8").read())

# Differences that are on purpose. Each needs a reason, because each is a rule that does NOT run
# before a commit.
HOOK_SKIPS = {
    "doc-drift-check.py": "needs a diff against origin/main, which a commit-time hook shouldn't fetch",
    "knowledge-base-check.sh": "reads every doc; too slow for every commit",
    "hooks-check.sh": "it would be checking itself, and `make check` already runs it",
}
# The same, for a gate that runs locally but not in rules.yml. Only one belongs here: rules.yml runs
# on a cheap Linux runner, and swift-format comes from xcrun.
CI_SKIPS = {
    "swift-format lint": "needs macOS (xcrun), so it runs in preflight.yml instead — see its matrix",
}

problems = []
for g in sorted(gate - hook):
    if g.split(" ")[0] in HOOK_SKIPS or g in HOOK_SKIPS:
        continue
    problems.append(f"{g} is in 'make check' but not in .githooks/pre-commit. "
                    f"FIX: add it to the hook, or add it to HOOK_SKIPS in tools/hooks-check.sh with the reason.")
for g in sorted(hook - gate):
    problems.append(f"{g} is in .githooks/pre-commit but 'make check' doesn't reach it. "
                    f"FIX: add it to a target 'make check' depends on.")
# rules.yml is the one that actually blocks a pull request, so every gate the hook runs has to be
# there. It may do more (it builds nothing locally can, and it checks the commit range).
for g in sorted(hook - ci):
    if g in CI_SKIPS:
        continue
    problems.append(f"{g} runs in .githooks/pre-commit but no step of .github/workflows/rules.yml runs it, "
                    f"so a commit made with --no-verify is never checked. FIX: add a step to rules.yml, "
                    f"or add it to CI_SKIPS in tools/hooks-check.sh with the reason and where it does run.")
# rules.yml must also carry every gate `make check` has that isn't in the hook, or a docs-only pull
# request (which skips preflight.yml entirely) is checked by nothing.
for g in sorted(gate - ci - set(CI_SKIPS)):
    problems.append(f"{g} runs in 'make check' but no step of .github/workflows/rules.yml runs it, so "
                    f"nothing checks it on a pull request. FIX: add a step to rules.yml, or add it to "
                    f"CI_SKIPS in tools/hooks-check.sh with the reason and where it does run.")

for p in problems:
    print(f"✗ {p}")
if not problems:
    print(f"✓ the same {len(hook)} gates run in all three places "
          f"({len(gate - hook)} more in 'make check' and rules.yml, on purpose)")
    for g, why in sorted(HOOK_SKIPS.items()):
        print(f"    · not in the hook: {g} — {why}")
    for g, why in sorted(CI_SKIPS.items()):
        print(f"    · not in rules.yml: {g} — {why}")
sys.exit(1 if problems else 0)
PY

echo
if [ "$fail" = 0 ]; then
  echo "hooks-check: clean"
else
  echo "hooks-check: FAILED"
fi
exit $fail
