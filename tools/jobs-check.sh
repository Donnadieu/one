#!/bin/bash
# Three core jobs, end to end, with One's real engine in a throwaway home (costs a little OpenRouter money):
#   1. sort my files   2. handle my inbox (draft only)   3. watch a price, buy only with an OK
# Usage: tools/jobs-check.sh [--no-build] [--helpers]   (ONE_JOBS_PROVIDER=openrouter to use the OpenRouter key instead)
#   --helpers: instead of the three jobs, ask for five helpers at once (all must start, at most 3 at a time)
# Needs One's engine installed (~/Library/Application Support/One/engine) and OPENROUTER_API_KEY
# (from the environment, or the OPENROUTER_API_KEY line of ~/.hermes/.env). Nothing real is touched:
# files, inbox and shop are fakes in a scratch folder under $TMPDIR, the brain and Hermes home are the selftest ones.
set -u
cd "$(dirname "$0")/.."
ONLY=""
case " $* " in *" --helpers "*) ONLY=helpers ;; esac
case " $* " in *" --no-build "*) ;; *) false ;; esac || { ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; }; }
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$HOME/.hermes/.env" ]; then
  OPENROUTER_API_KEY=$(grep -E '^OPENROUTER_API_KEY=' "$HOME/.hermes/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'"' \r')
fi
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
PROVIDER="${ONE_JOBS_PROVIDER:-claude}"  # claude = the subscription One already uses (no extra cost)

S=$(mktemp -d "${TMPDIR:-/tmp}/one-jobs.XXXXXX")
# The engine runs inside the folder lock, which closes the home folder, so it can't open an app in
# ~/Repos: run a copy from the scratch folder (the engine calls it for email).
tools/test-copy.sh jobs-test "$S" >/dev/null  # own bundle id: never your real One or its settings
echo "scratch: $S (kept for reading: transcripts, steps, routines)"
# A clean environment, like opening One from the Finder: Hermes variables from whatever launched
# this script (e.g. an agent's own gateway) would steer One's engine.
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" OPENROUTER_API_KEY="$OPENROUTER_API_KEY" ONE_JOBS_PROVIDER="$PROVIDER" HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" ONE_JOBS_ONLY="$ONLY" ONE_JOBS_DIR="$S" ONE_FAKE_MAIL="$S/inbox.json" \
  perl -e 'alarm 900; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-jobs > "$S/out.txt" 2>"$S/err.txt"
rc=$?
defaults delete ai.forjado.one.jobs-test >/dev/null 2>&1
grep -E '^(PASS|FAIL|INFO|TOTAL|model:|permission|restored)' "$S/out.txt"
[ $rc = 142 ] && echo "FAIL timeout: no result after 15 minutes"
grep -q '^TOTAL' "$S/out.txt" || { echo "FAIL no result (exit $rc)"; tail -5 "$S/out.txt" "$S/err.txt"; }
# The engine may have left its helper running in the throwaway home.
for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
exit $rc
