#!/bin/bash
# One is a personal project: every commit is Donnadieu <donnadieu.86@gmail.com>, signed with GPG key ABAFD67086BDA7E0.
# The Andela work account (donnadieu-andela) must never show up here.
#
#   tools/check-identity.sh               config check: who the next commit would be (pre-commit, make check)
#   tools/check-identity.sh --push        pre-push: reads git's "<local ref> <sha> <remote ref> <sha>" lines on stdin
#   tools/check-identity.sh --range A..B  every commit in A..B: author, committer, signature
#   tools/check-identity.sh --ci A..B     same, without the signature check (CI has no copy of the key)
set -u
NAME="Donnadieu"
EMAIL="donnadieu.86@gmail.com"
KEY="ABAFD67086BDA7E0"
fail=0
say() {
  echo "identity: $1" >&2
  fail=1
}

check_config() {
  local a c sk fmt gs
  a=$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed -E 's/ [0-9]+ [-+][0-9]{4}$//')
  c=$(git var GIT_COMMITTER_IDENT 2>/dev/null | sed -E 's/ [0-9]+ [-+][0-9]{4}$//')
  [ "$a" = "$NAME <$EMAIL>" ] || say "author would be '$a', must be '$NAME <$EMAIL>'"
  [ "$c" = "$NAME <$EMAIL>" ] || say "committer would be '$c', must be '$NAME <$EMAIL>'"
  sk=$(git config --get user.signingkey || true)
  fmt=$(git config --get gpg.format || echo openpgp)
  gs=$(git config --get --type=bool commit.gpgsign || echo false)
  [ "$sk" = "$KEY" ] || say "user.signingkey is '$sk', must be $KEY"
  [ "$fmt" = "openpgp" ] || say "gpg.format is '$fmt', must be openpgp"
  [ "$gs" = "true" ] || say "commit.gpgsign is '$gs', must be true"
}

check_range() { # $1 = range, $2 = 1 to check signatures
  local line h an ae cn ce g k
  while IFS='|' read -r h an ae cn ce g k; do
    [ -n "$h" ] || continue
    if printf '%s %s %s %s' "$an" "$ae" "$cn" "$ce" | grep -qi 'andela'; then
      say "${h:0:9} carries the Andela identity ($an <$ae> / $cn <$ce>)"
      continue
    fi
    # Squash merges made on GitHub: author = the Donnadieu account, committer = GitHub, signed by GitHub.
    if [ "$cn <$ce>" = "GitHub <noreply@github.com>" ] && [ "$ae" = "$EMAIL" ]; then continue; fi
    [ "$an <$ae>" = "$NAME <$EMAIL>" ] || say "${h:0:9} author is '$an <$ae>'"
    [ "$cn <$ce>" = "$NAME <$EMAIL>" ] || say "${h:0:9} committer is '$cn <$ce>'"
    if [ "$2" = 1 ]; then
      [ "$g" = "G" ] && [ "${k: -16}" = "$KEY" ] || say "${h:0:9} is not signed by $KEY (status '$g', key '$k')"
    fi
  done < <(git log --format='%H|%an|%ae|%cn|%ce|%G?|%GK' "$1" --)
}

case "${1:-}" in
  "") check_config ;;
  --push)
    check_config
    z=0000000000000000000000000000000000000000
    while read -r _lref lsha rref rsha; do
      [ "$lsha" = "$z" ] && continue # deleting a branch
      if [ "${rref#refs/tags/}" != "$rref" ] && [ "$(git cat-file -t "$lsha")" = tag ]; then
        t=$(git cat-file -p "$lsha" | sed -n 's/^tagger \(.*>\).*/\1/p')
        [ "$t" = "$NAME <$EMAIL>" ] || say "tag ${rref#refs/tags/} tagger is '$t'"
        git verify-tag --raw "$lsha" 2>&1 | grep -q "VALIDSIG [0-9A-F]*$KEY" || say "tag ${rref#refs/tags/} is not signed by $KEY"
      fi
      if [ "$rsha" = "$z" ]; then
        # new branch: check what it adds on top of main
        base=$(git merge-base "$lsha" origin/main 2>/dev/null || true)
        if [ -n "$base" ]; then check_range "$base..$lsha" 1; else check_range "$lsha" 1; fi
      else
        check_range "$rsha..$lsha" 1
      fi
    done
    ;;
  --range) check_range "$2" 1 ;;
  --ci) check_range "$2" 0 ;;
  *)
    echo "usage: $0 [--push | --range A..B | --ci A..B]" >&2
    exit 2
    ;;
esac

if [ "$fail" = 1 ]; then
  echo "FIX: One commits only as $NAME <$EMAIL>, signed with $KEY (never donnadieu-andela)." >&2
  echo "     git config --local user.name $NAME; git config --local user.email $EMAIL" >&2
  echo "     git config --local user.signingkey $KEY; git config --local gpg.format openpgp; git config --local commit.gpgsign true" >&2
  echo "     Never pass -c user.*, --author or --no-gpg-sign. Rewrite a bad commit: git commit --amend --no-edit -S --reset-author" >&2
  exit 1
fi
exit 0
