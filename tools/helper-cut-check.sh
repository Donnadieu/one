#!/bin/bash
# Helpers cut off by an engine restart are never shown done: they show stopped, pick back up by themselves and are done
# only with their real answer. One's real engine in a throwaway home (two short turns on the Claude subscription One
# already uses). See Sources/HelperCutCheck.swift. A copy with its own bundle id runs it: never your real One.
set -u
cd "$(dirname "$0")/.."
case " $* " in *" --no-build "*) ;; *) ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; } ;; esac
ID=ai.forjado.one.helpercut-test
S=$(mktemp -d "${TMPDIR:-/tmp}/one-helpercut.XXXXXX")
tools/test-copy.sh "${ID#ai.forjado.one.}" "$S" >/dev/null
defaults delete "$ID" >/dev/null 2>&1
# Its own One folder, borrowing only the installed engine program (Hermes): the throwaway home, brain and settings stay in $S.
mkdir -p "$S/sup"
ln -s "$HOME/Library/Application Support/One/engine" "$S/sup/engine"
env -i ONE_SUPPORT_DIR="$S/sup" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-en_US.UTF-8}" HERMES_RUNTIME_DIR="$HOME/Library/Application Support/One/hermes/tools" \
  perl -e 'alarm 700; exec @ARGV' "$S/One.app/Contents/MacOS/One" --test-helper-stop --cut > "$S/cut.txt" 2>"$S/cut-err.txt"
cat "$S/cut.txt"
defaults delete "$ID" >/dev/null 2>&1
grep -q '^helper-cut ok' "$S/cut.txt"
