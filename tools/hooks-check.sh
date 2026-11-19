#!/bin/bash
# The git hooks are on, and the three places the rules run haven't drifted apart.
#
# .githooks/ is tracked, but a tracked hook does nothing until someone runs `make hooks` to point
# core.hooksPath at it. A fresh clone therefore had no pre-commit guard and nothing said so: the
# first commit from it could be unsigned, carry the Andela identity, or break a lint rule, and the
# only thing that would notice is CI, after the push. This runs in `make check`, so the gate itself
# tells you the gate isn't armed.
#
#   tools/hooks-check.sh        on the Mac: hooks installed, identity pinned, hook rules match make check
#   tools/hooks-check.sh --ci   in CI: there are no hooks to install, so only the drift half runs
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
    [ -x "$f" ] && ok "$f is executable" || bad "$f is missing or not executable. FIX: chmod +x $f"
  done
  # make hooks pins this clone to Donnadieu; the Andela work account must leave no trace here.
  pinned() {
    got=$(git config "$1" 2>/dev/null || true)
    if [ "$got" = "$2" ]; then ok "$1 = $2"; else
      bad "$1 is '${got:-unset}', not '$2'. FIX: run 'make hooks'."
    fi
  }
  pinned user.name Donnadieu
  pinned user.email donnadieu.86@gmail.com
  pinned user.signingkey ABAFD67086BDA7E0
  pinned commit.gpgsign true
fi

# The drift half, which CI can run too: every rule the pre-commit hook enforces must also be in
# `make check`, or a commit passes the hook and the gate disagrees about what the rules are.
echo
echo "The pre-commit hook and 'make check' agree on the rules"
CHECK_LINE=$(sed -n 's/^check:[^#]*/&/p' Makefile | head -1)
for rule in check-identity.sh one-lint.py check-baseline.sh; do
  if ! grep -q "$rule" .githooks/pre-commit; then
    bad "$rule is in 'make check' but not in .githooks/pre-commit. FIX: add it to the hook, or say in the hook's header why it is too slow for every commit."
  elif ! grep -q "$rule" Makefile; then
    bad "$rule is in .githooks/pre-commit but no make target runs it. FIX: add it to a target 'make check' depends on."
  else
    ok "$rule runs in both"
  fi
done
# `make check` is the one local command, so it must reach every target the repo says it does.
for target in identity format-check lint docdrift knowledgebase hooks-installed; do
  case " $CHECK_LINE " in
    *" $target "*) ok "make check includes $target" ;;
    *) bad "make check doesn't include $target. FIX: add it to the 'check:' target in the Makefile." ;;
  esac
done

echo
if [ "$fail" = 0 ]; then
  echo "hooks-check: clean"
else
  echo "hooks-check: FAILED"
fi
exit $fail
