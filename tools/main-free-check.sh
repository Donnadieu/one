#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# The main chat is always free to talk (Sources/MainFreeCheck.swift): Omar's Nov 11 evening replayed against the
# stand-in engine (tools/fake-engine.py, no account, no cost, about 2 minutes). A turn doing long tool work is cut
# short and handed to a helper, a message sent meanwhile is answered at once, job files a cut-off turn wrote still go
# out (or, after Stop, are asked about plainly), and a quick look or a long spoken reply is never cut.
# A test copy with its own bundle id and a scratch folder: your One, chat and settings are never touched.
#   tools/main-free-check.sh [--no-build]
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.main-free-$$
S=$(mktemp -d "${TMPDIR:-/tmp}/one-main-free.XXXXXX")
APP=$(tools/test-copy.sh "${ID#ai.forjado.one.}" "$S") || exit 1
defaults delete "$ID" >/dev/null 2>&1
mkdir -p "$S/support"
cp tools/fake-engine.py "$S/fake-engine.py"; chmod +x "$S/fake-engine.py"
env -i GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" ONE_SUPPORT_DIR="$S/support" ONE_TEST_ENGINE="$S/fake-engine.py" ONE_FAKE_ENGINE_LOG="$S/engine.jsonl" \
  perl -e "alarm 300; exec @ARGV" "$APP/Contents/MacOS/One" --test-helpers-stress mainfree > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
grep -q '^main-free ok' "$S/out.txt" || rc=1
for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
if [ $rc = 0 ]; then echo "main-free-check ok"; [ -n "${KEEP:-}" ] || rm -rf "$S"; else echo "main-free-check FAILED (logs in $S)"; tail -20 "$S/err.txt"; fi
exit $rc
