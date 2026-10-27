#!/bin/bash
# Sending while busy, end to end, with One's real engine in a throwaway home (a short turn or two on the
# Claude subscription One already uses). A copy of the app with its own bundle id runs it, so the person's
# chat, settings and running One are never touched. See Sources/FollowUpCheck.swift.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S=$(mktemp -d "${TMPDIR:-/tmp}/one-followups.XXXXXX")
tools/test-copy.sh followups-test "$S" >/dev/null  # own bundle id: never your real One or its settings
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" \
  perl -e 'alarm 480; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-followups > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
[ $rc = 142 ] && echo "FAIL timeout"
for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
defaults delete ai.forjado.one.followups-test >/dev/null 2>&1
exit $rc
