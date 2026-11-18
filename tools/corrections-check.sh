#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Omar's corrections about One, each replayed as the scenario that broke (Sources/CorrectionsCheck.swift) against the
# stand-in engine (tools/fake-engine.py, no account, no cost, about a minute). The list of corrections and the check
# that guards each one: tests/corrections/README.md (tools/corrections-index-check.py keeps it honest).
# A test copy with its own bundle id and a scratch folder: your One, chat and settings are never touched.
#   tools/corrections-check.sh [--no-build]
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.corrections-$$
S=$(mktemp -d "${TMPDIR:-/tmp}/one-corrections.XXXXXX")
APP=$(tools/test-copy.sh "${ID#ai.forjado.one.}" "$S") || exit 1
defaults delete "$ID" >/dev/null 2>&1
mkdir -p "$S/support"
cp tools/fake-engine.py "$S/fake-engine.py"; chmod +x "$S/fake-engine.py"
env -i GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" ONE_SUPPORT_DIR="$S/support" ONE_TEST_ENGINE="$S/fake-engine.py" ONE_FAKE_ENGINE_LOG="$S/engine.jsonl" \
  perl -e "alarm 180; exec @ARGV" "$APP/Contents/MacOS/One" --test-helpers-stress corrections > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
grep -q '^corrections ok' "$S/out.txt" || rc=1
for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
if [ $rc = 0 ]; then echo "corrections-check ok"; [ -n "${KEEP:-}" ] || rm -rf "$S"; else echo "corrections-check FAILED (logs in $S)"; tail -20 "$S/err.txt"; fi
exit $rc
