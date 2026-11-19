#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Helper lines from the phone chat act like in One's own chat (Sources/PhoneTagsCheck.swift): the Nov 15 phone replies
# replayed against the stand-in engine (tools/fake-engine.py, no account, no cost, under a minute), through the files
# the engine plugin one-phone-tags writes. One helper per reply, never twice; a tell reaches it; its result and its
# question go back to that chat once (a stand-in chat: nothing is ever sent).
# A test copy with its own bundle id and a scratch folder: your One, chat and settings are never touched.
#   tools/phone-tags-check.sh [--no-build]
set -u
cd "$(dirname "$0")/.." || exit 1
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.phone-tags-$$
S=$(mktemp -d "${TMPDIR:-/tmp}/one-phone-tags.XXXXXX")
APP=$(tools/test-copy.sh "${ID#ai.forjado.one.}" "$S") || exit 1
defaults delete "$ID" >/dev/null 2>&1
mkdir -p "$S/support"
cp tools/fake-engine.py "$S/fake-engine.py"; chmod +x "$S/fake-engine.py"
env -i GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" ONE_SUPPORT_DIR="$S/support" ONE_TEST_ENGINE="$S/fake-engine.py" ONE_FAKE_ENGINE_LOG="$S/engine.jsonl" \
  perl -e "alarm 200; exec @ARGV" "$APP/Contents/MacOS/One" --test-helpers-stress phone > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
grep -q '^phone-tags ok' "$S/out.txt" || rc=1
for p in $(pgrep -f "$S/"); do kill "$p" 2>/dev/null; done
defaults delete "$ID" >/dev/null 2>&1
if [ $rc = 0 ]; then echo "phone-tags-check ok"; [ -n "${KEEP:-}" ] || rm -rf "$S"; else echo "phone-tags-check FAILED (logs in $S)"; tail -20 "$S/err.txt"; fi
exit $rc
