#!/bin/bash
# runs: owner-only (make jobs) — One's real engine, and it costs a little OpenRouter money; no CI runner has either
# Three core jobs, end to end, with One's real engine in a throwaway home:
#   1. sort my files   2. handle my inbox (draft only)   3. watch a price, buy only with an OK
# Usage: tools/jobs-check.sh [--no-build] [--helpers]   (ONE_JOBS_PROVIDER=openrouter to use the OpenRouter key)
#   --helpers: instead of the three jobs, ask for five helpers at once (all must start, at most 3 at a time)
# Needs One's engine installed (~/Library/Application Support/One/engine) and OPENROUTER_API_KEY (from the
# environment, or the OPENROUTER_API_KEY line of ~/.hermes/.env). Nothing real is touched: files, inbox and shop
# are fakes in the scratch folder, and the brain and Hermes home are the throwaway ones.
set -u
. "$(dirname "$0")/engine-check.sh" --lib

ONLY=""
case " $* " in *" --helpers "*) ONLY=helpers ;; esac
BUILD=build
case " $* " in *" --no-build "*) BUILD=no ;; esac
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.hermes/.env" ]; then
  OPENROUTER_API_KEY=$(grep -E '^OPENROUTER_API_KEY=' "$HOME/.hermes/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')
fi

engine_world jobs-test "$BUILD"
echo "scratch: $S (kept for reading: transcripts, steps, routines)"
# shellcheck disable=SC2034  # read by the sourced engine-check.sh library
ENGINE_EXTRA_ENV=(
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
  ONE_JOBS_PROVIDER="${ONE_JOBS_PROVIDER:-claude}"   # claude = the subscription One already uses (no extra cost)
  ONE_JOBS_ONLY="$ONLY" ONE_JOBS_DIR="$S" ONE_FAKE_MAIL="$S/inbox.json"
)
engine_run 900 --test-jobs > "$S/out.txt" 2>"$S/err.txt"
rc=$?
grep -E '^(PASS|FAIL|INFO|TOTAL|model:|permission|restored)' "$S/out.txt"
[ $rc = 142 ] && echo "FAIL timeout: no result after 15 minutes"
grep -q '^TOTAL' "$S/out.txt" || { echo "FAIL no result (exit $rc)"; tail -5 "$S/out.txt" "$S/err.txt"; }
engine_cleanup
exit $rc
