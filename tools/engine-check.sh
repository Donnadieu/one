#!/bin/bash
# The one wrapper every live check that drives One's real engine goes through (enforced: engine-check-wrapper).
#
# Ten scripts used to carry their own copy of this and had already drifted on the setting that isolates the
# test world: only 4 of 10 set ONE_SUPPORT_DIR, only 3 linked the installed engine, only 2 set ONE_TEST_ENGINE,
# and only some printed stderr when a run failed. The copies that forgot ONE_SUPPORT_DIR leaned on
# TestWorld.enter() making a scratch folder instead, so the isolation held but was invisible. Here it is one
# named option per real difference, in one place, and a test's One folder is always "$S/sup" — never the
# person's.
#
# As a command (the simple case: one run, one verdict):
#   tools/engine-check.sh --mode --test-helper-done --timeout 840 [options] [-- extra args for One]
#
#   --mode <--test-x>     the test mode to run (required)
#   --timeout <seconds>   wall clock before it is a failure (required)
#   --name <id>           bundle-id suffix for the test copy (default: the mode without --test-)
#   --expect <regex>      a line that must appear in the output (default: just the exit code)
#   --engine-link         link the installed engine into the test One folder (checks that need Hermes itself)
#   --test-engine         point ONE_TEST_ENGINE at the installed Hermes binary
#   --env K=V             one more variable for the clean environment (repeatable)
#   --keep                keep the scratch folder and say where it is
#   --no-build            don't build first (the caller already did)
#
# Sourced as a library (a check that needs several runs, its own server, a version swap):
#   . "$(dirname "$0")/engine-check.sh" --lib
#   engine_world helperstop-test      # builds, makes the test copy, sets $S / $ID / "$S/sup"
#   engine_run 900 --test-helper-stop # one run in the clean environment; output on stdout
#   engine_cleanup                    # kill strays, forget the copy's settings
set -u
. "$(dirname "${BASH_SOURCE[0]}")/ci-only.sh"  # CI, or a live check the owner asked for (ONE_LIVE_CHECK=1)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ENGINE_LINK=0        # 1 = link the installed engine into the test One folder
ENGINE_TEST_ENGINE=0 # 1 = set ONE_TEST_ENGINE to the installed Hermes binary
ENGINE_EXTRA_ENV=()  # extra K=V for the clean environment
ENGINE_REAL="$HOME/Library/Application Support/One"

# Build, make the test copy, and set $S (scratch), $ID (its bundle id) and "$S/sup" (its One folder).
engine_world() {
  local name="$1" build="${2:-build}"
  [ "$build" = build ] && { ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; }; }
  ID="ai.forjado.one.$name"
  S=$(mktemp -d "${TMPDIR:-/tmp}/one-$name.XXXXXX")
  tools/test-copy.sh "$name" "$S" >/dev/null   # own bundle id: never the person's real One or its settings
  defaults delete "$ID" >/dev/null 2>&1
  mkdir -p "$S/sup"
  # The installed engine program only — the throwaway home, brain and settings all stay in $S.
  [ "$ENGINE_LINK" = 1 ] && ln -s "$ENGINE_REAL/engine" "$S/sup/engine"
  return 0
}

# One run of the test copy in a clean environment, like opening One from the Finder: Hermes variables from
# whatever launched this script (an agent's own gateway, say) would otherwise steer One's engine elsewhere.
engine_run() {
  local timeout="$1"; shift
  local e=(
    GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" ONE_LIVE_CHECK="${ONE_LIVE_CHECK:-}"
    ONE_SUPPORT_DIR="$S/sup" HOME="$HOME" USER="$USER" LOGNAME="${LOGNAME:-$USER}"
    PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}"
    HERMES_RUNTIME_DIR="$ENGINE_REAL/hermes/tools"
  )
  [ "$ENGINE_TEST_ENGINE" = 1 ] && e+=(ONE_TEST_ENGINE="$ENGINE_REAL/engine/.hermes/bin/hermes")
  [ ${#ENGINE_EXTRA_ENV[@]} -gt 0 ] && e+=("${ENGINE_EXTRA_ENV[@]}")
  env -i "${e[@]}" perl -e 'alarm shift; exec @ARGV' "$timeout" "$S/One.app/Contents/MacOS/One" "$@"
}

# Kill anything the engine left running in the throwaway home, and forget the copy's settings.
engine_cleanup() {
  for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done
  defaults delete "$ID" >/dev/null 2>&1
  return 0
}

case " $* " in *" --lib "*) return 0 ;; esac

MODE="" ; TIMEOUT="" ; NAME="" ; EXPECT="" ; KEEP=0 ; BUILD=build ; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --expect) EXPECT="$2"; shift 2 ;;
    --engine-link) ENGINE_LINK=1; shift ;;
    --test-engine) ENGINE_TEST_ENGINE=1; shift ;;
    --env) ENGINE_EXTRA_ENV+=("$2"); shift 2 ;;
    --keep) KEEP=1; shift ;;
    --no-build) BUILD=no; shift ;;
    --) shift; ARGS=("$@"); break ;;
    *) echo "engine-check: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] && [ -n "$TIMEOUT" ] || { echo "engine-check: --mode and --timeout are required" >&2; exit 2; }
[ -n "$NAME" ] || NAME=$(printf '%s' "${MODE#--test-}" | tr -cd 'a-z0-9-')

engine_world "$NAME" "$BUILD"
[ "$KEEP" = 1 ] && echo "scratch: $S (kept for reading)"
engine_run "$TIMEOUT" "$MODE" ${ARGS[@]+"${ARGS[@]}"} > "$S/out.txt" 2>"$S/err.txt"
rc=$?
cat "$S/out.txt"
[ $rc = 0 ] || tail -5 "$S/err.txt"
[ $rc = 142 ] && echo "FAIL timeout: no result after $TIMEOUT seconds"
if [ -n "$EXPECT" ] && ! grep -qE "$EXPECT" "$S/out.txt"; then
  echo "FAIL: nothing matching '$EXPECT' in the output"
  rc=1
fi
engine_cleanup
[ "$KEEP" = 1 ] || rm -rf "$S"
exit $rc
