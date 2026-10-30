#!/bin/bash
# Smart routing with One's real engine in a throwaway home (two short helper turns on the Claude subscription One
# already uses): a helper starts with the fitting recipe in hand, a lookup steps down to the balanced brain, and with
# routing off nothing is added. A copy of the app with its own bundle id runs it, so the person's chat, settings and
# running One are never touched. See Sources/RoutingLiveCheck.swift.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
S=$(mktemp -d "${TMPDIR:-/tmp}/one-routing-live.XXXXXX")
tools/test-copy.sh routing-test "$S" >/dev/null  # own bundle id: never your real One or its settings
env -i HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" \
  ONE_TEST_ENGINE="$HOME/Library/Application Support/One/engine/.hermes/bin/hermes" \
  perl -e 'alarm 420; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-routing-live > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
[ $rc = 0 ] || tail -5 "$S/err.txt"
[ $rc = 142 ] && echo "FAIL timeout"
for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
defaults delete ai.forjado.one.routing-test >/dev/null 2>&1
exit $rc
