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
# Those are the whole contract, for the thin wrappers too: each one `exec`s this with its own options
# and forwards "$@", so `tools/reset-check.sh --no-build` works and anything else is an error. The ten
# scripts this replaced ignored an argument they didn't know, which is how a typo ran the wrong check.
#
# Sourced as a library (a check that needs several runs, its own server, a version swap):
#   . "$(dirname "$0")/engine-check.sh" --lib
#   engine_world helperstop-test      # builds, makes the test copy, sets $S / $ID / "$S/sup"
#   engine_run 900 --test-helper-stop # one run in the clean environment; output on stdout
#   engine_cleanup                    # kill strays, forget the copy's settings
set -u
. "$(dirname "${BASH_SOURCE[0]}")/ci-only.sh"  # CI, or the check named in ONE_LIVE_CHECK (ONE_CALLER says who asked)
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ENGINE_LINK=0        # 1 = copy the installed engine into the test One folder
ENGINE_TEST_ENGINE=0 # 1 = set ONE_TEST_ENGINE to the installed Hermes binary
ENGINE_EXTRA_ENV=()  # extra K=V for the clean environment
# The person's real One folder. Never written: the engine PROGRAM is read from here, and everything a
# test writes goes to "$S/sup".
ENGINE_REAL="$HOME/Library/Application Support/One"

# Bake settings into a test copy's Info.plist, for a check that has to start One through Launch
# Services (inside One's folder lock a child's `open` loses its arguments, so the window would be a
# bare Chrome). tools/handoff-qa.sh and tools/human-window-check.sh each carried their own copy of
# this, and both copies had to be edited to add the same variable — the drift that engine-check.sh
# exists to end, in a family engine-check-wrapper can't see (no `env -i`).
#   engine_launch_env <Info.plist> KEY=VALUE [KEY=VALUE …]
engine_launch_env() {
  local pl="$1"; shift
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$pl" 2>/dev/null || true
  local kv
  for kv in "$@"; do
    [ -n "$kv" ] || continue
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${kv%%=*} string ${kv#*=}" "$pl"
  done
}

engine_world() {
  local name="$1" build="${2:-build}"
  case "$name" in *[!a-z0-9-]* | "") echo "engine-check: --name takes a-z, 0-9 and - only" >&2; exit 2 ;; esac
  [ "$build" = build ] && { ./build.sh >/dev/null 2>&1 || { echo "FAIL build (run ./build.sh)"; exit 1; }; }
  ID="ai.forjado.one.$name"
  S=$(mktemp -d "${TMPDIR:-/tmp}/one-$name.XXXXXX")
  # Every failure here is fatal. Without the status check a failed copy left $S/One.app absent and
  # the script went on to exec a binary that isn't there, reporting an opaque exit code instead.
  tools/test-copy.sh "$name" "$S" >/dev/null ||
    { echo "FAIL test copy (tools/test-copy.sh $name)"; exit 1; }   # own bundle id: never the person's real One
  # Kill strays and forget the copy's settings however this ends — a Ctrl-C or a CI timeout used to
  # leave the engine running in the throwaway home, the defaults domain written and a full One.app
  # in TMPDIR. Set here, so it covers the library callers too.
  trap 'engine_cleanup; [ "${KEEP:-0}" = 1 ] || rm -rf "$S"' EXIT INT TERM
  defaults delete "$ID" >/dev/null 2>&1
  mkdir -p "$S/sup"
  # The installed engine program only — the throwaway home, brain and settings all stay in $S.
  # COPIED, not symlinked: a symlink made "$S/sup/engine" a door into the person's real One folder,
  # and TestWorld.isProduction() can't see through it (it resolves "$S/sup", which really is scratch),
  # so anything the engine wrote under its own engine dir landed in their real folder and the
  # refusal never fired. `cp -c` clones on APFS, so this costs almost nothing and no byte of it can
  # travel back. A failure here is fatal: a check that silently ran without the engine proves nothing.
  if [ "$ENGINE_LINK" = 1 ]; then
    cp -Rc "$ENGINE_REAL/engine" "$S/sup/engine" 2>/dev/null ||
      cp -R "$ENGINE_REAL/engine" "$S/sup/engine" ||
      { echo "FAIL no installed engine at $ENGINE_REAL/engine (open One once to install it)"; exit 1; }
  fi
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
    *) echo "engine-check: unknown option $1 (a wrapper forwards its arguments here; see the usage at the top)" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] && [ -n "$TIMEOUT" ] || { echo "engine-check: --mode and --timeout are required" >&2; exit 2; }
# `perl -e 'alarm shift'` turns a non-numeric argument into alarm 0, which is NO timeout at all, so
# `--timeout 15m` would hang forever instead of failing after 15 minutes.
case "$TIMEOUT" in *[!0-9]* | "") echo "engine-check: --timeout takes whole seconds, not '$TIMEOUT'" >&2; exit 2 ;; esac
case "$MODE" in --test-*) ;; *) echo "engine-check: --mode takes a --test-… mode, not '$MODE'" >&2; exit 2 ;; esac
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
# A failed run keeps its scratch folder and says where it is: out.txt, err.txt and the test copy are
# the whole post-mortem, and all ten scripts this replaced used to leave them behind.
if [ $rc != 0 ] && [ "$KEEP" != 1 ]; then
  KEEP=1
  echo "scratch kept for reading: $S (out.txt, err.txt, One.app)"
fi
exit $rc   # the EXIT trap from engine_world does the cleanup
