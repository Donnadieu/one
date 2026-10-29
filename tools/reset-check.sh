#!/bin/bash
# `--reset` ("reset onboarding") must clear only onboarding/setup settings, never helpers, bubbles or the
# shelf: the 0.9.74 incident emptied `helpers` (a finished "Message history" helper vanished) with nothing
# in that release's own diff touching helpers persistence. A copy of the app with its own bundle id runs
# this, so the person's real settings are never touched. See Sources/ResetCheck.swift.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S=$(mktemp -d "${TMPDIR:-/tmp}/one-reset.XXXXXX")
tools/test-copy.sh reset-test "$S" >/dev/null  # own bundle id: never your real One or its settings
mkdir -p "$S/sup"
env -i ONE_SUPPORT_DIR="$S/sup" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" \
  perl -e 'alarm 60; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-reset > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
[ $rc = 0 ] || tail -5 "$S/err.txt"
[ $rc = 142 ] && echo "FAIL timeout"
defaults delete ai.forjado.one.reset-test >/dev/null 2>&1
exit $rc
