#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# One preflight: must pass before every release.
#   tools/preflight.sh           quick checks (about 1 minute, no login, no network except the updater check)
#   tools/preflight.sh --full    also a fresh engine install into an empty folder (about 2 minutes)
#   tools/preflight.sh --ci      skip checks that need a Mac with One's engine (GitHub runners)
#   tools/preflight.sh --quick   skip the slow helpers stress check (pull request checks; it still runs on main,
#                                every night, on release tags and in every local run, so releases always pass it)
# Every check has a time limit (LIMIT seconds, 180 by default), so a stuck check fails instead of holding a runner for hours.
set -u
cd "$(dirname "$0")/.."
FULL=0; CI=0; QUICK=0
for a in "$@"; do [ "$a" = --full ] && FULL=1; [ "$a" = --ci ] && CI=1; [ "$a" = --quick ] && QUICK=1; done
# .noindex: Spotlight never lists the test copies as apps
T="${TMPDIR:-/tmp}/one-preflight-$$.noindex"; mkdir -p "$T"
trap 'rm -rf "$T"; defaults delete ai.forjado.one.preflight >/dev/null 2>&1; defaults delete ai.forjado.one.preflight-old >/dev/null 2>&1' EXIT
APP=build/app.noindex/One.app; BIN="$APP/Contents/MacOS/One"
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }
check() {
  local name="$1" lim="${LIMIT:-180}" rc; shift
  if perl -e '$t = shift; alarm $t; exec @ARGV or exit 127' "$lim" "$@" >"$T/last.log" 2>&1; then ok "$name"; else
    rc=$?; bad "$name"; [ $rc = 142 ] && echo "      stopped: still running after ${lim}s"; sed 's/^/      /' "$T/last.log" | tail -5
  fi
}

# The person's live One must survive this run: note its engine helper now, compare at the end.
REAL_PID_FILE="$HOME/Library/Application Support/One/hermes/gateway.pid"
gw_id() { local p; p=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$REAL_PID_FILE" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p $(ps -o lstart= -p "$p")"; }
GW_BEFORE=$(gw_id)

echo "Build"
LIMIT=600 check "app builds" ./build.sh
[ -x "$BIN" ] || { echo "No app binary, stopping."; exit 1; }
# Your files and settings are production. Every test below runs from a test copy with its own bundle id
# (own settings) and a scratch One folder; the real build only runs to prove it refuses. See TestWorld.swift.
TAPP=$(tools/test-copy.sh preflight "$T/app"); TBIN="$TAPP/Contents/MacOS/One"
defaults delete ai.forjado.one.preflight >/dev/null 2>&1
made_list() { ls -1 "$HOME/Documents"/Made\ by*/ 2>/dev/null | sort; }
shelf_list() { defaults export ai.forjado.one - 2>/dev/null | plutil -extract shelf raw -o - - 2>/dev/null | base64 -D 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys; [print(x["path"]) for x in json.load(sys.stdin)]' 2>/dev/null | sort; }
made_list > "$T/made.before"; shelf_list > "$T/shelf.before"
# The folder-restart check mostly waits (about 20 s): start it now and read its result in its place below.
# It uses its own scratch folder and its own stand-in helper, so it can't touch the checks running meanwhile.
mkdir -p "$T/rs"
ONE_SUPPORT_DIR="$T/rs" perl -e 'alarm 180; exec @ARGV' "$TBIN" --test-restart > "$T/rs/out.txt" 2>&1 &
RS_PID=$!

echo "Bundle"
check "version matches VERSION" bash -c "[ \"\$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)\" = \"\$(tr -d '[:space:]' < VERSION)\" ]"
check "Hermes version pinned" test -s "$APP/Contents/Resources/hermes-commit.txt"
check "KeePass backend bundled" test -f "$APP/Contents/Resources/keepass.py"
check "the engine's learning cap bundled" test -f "$APP/Contents/Resources/one-learning-cap/__init__.py"
check "the missed-messages plugin bundled" test -f "$APP/Contents/Resources/one-missed-messages/__init__.py"
check "the keeper's launch agent bundled (runs One --keeper every minute)" bash -c "plutil -lint $APP/Contents/Library/LaunchAgents/ai.forjado.one.keeper.plist >/dev/null && grep -q -- '--keeper' $APP/Contents/Library/LaunchAgents/ai.forjado.one.keeper.plist"
check "helper sounds bundled" bash -c "test -s $APP/Contents/Resources/chime-done.mp3 && test -s $APP/Contents/Resources/chime-yes.mp3"
check "shipped skills bundled" bash -c "[ \"\$(cd skills && find . -name SKILL.md | sort)\" = \"\$(cd $APP/Contents/Resources/skills && find . -name SKILL.md | sort)\" ] && [ -n \"\$(find skills -name SKILL.md)\" ]"
check "shipped skill descriptions are short (60 max)" bash -c "for f in \$(find skills -name SKILL.md); do d=\$(sed -n 's/^description: *//p' \$f | head -1); [ -n \"\$d\" ] && [ \${#d} -le 60 ] || { echo \"\$f\"; exit 1; }; done"
check "no Google secret or sign-in in the app" bash -c "! ls $APP/Contents/Resources | grep -q google"
check "no keys or tokens bundled" bash -c "! grep -rlI -E 'BEGIN (RSA |OPENSSH )?PRIVATE KEY|sk-ant-|ghp_[A-Za-z0-9]{20}' $APP/Contents/Resources"

echo "KeePass overlay"
mkdir -p "$T/ovl/engine/agent/vault_backends"
cp tests/fixtures/vault_base_pristine.py "$T/ovl/engine/agent/vault_backends/base.py"
check "applies to a clean engine" bash -c "ONE_SUPPORT_DIR=$T/ovl $BIN --apply-overlay | grep -q 'overlay ok'"
check "registers KeePass" grep -q "KeePassLoginBackend" "$T/ovl/engine/agent/vault_backends/base.py"
cp "$T/ovl/engine/agent/vault_backends/base.py" "$T/once.py"
ONE_SUPPORT_DIR="$T/ovl" "$BIN" --apply-overlay >/dev/null
check "second run changes nothing" cmp "$T/once.py" "$T/ovl/engine/agent/vault_backends/base.py"
printf 'def other():\n    pass\n' > "$T/ovl/engine/agent/vault_backends/base.py"
check "reports failure when Hermes changed" bash -c "ONE_SUPPORT_DIR=$T/ovl $BIN --apply-overlay | grep -q 'overlay failed'"

echo "Standing goals (/goal)"
check "the goals overlay is bundled" test -f "$APP/Contents/Resources/one_goals.py" -a -f "$APP/Contents/Resources/one_goal_progress.py"
mkdir -p "$T/goalovl/engine/acp_adapter" "$T/goalovl/engine/hermes_cli"
cp tests/fixtures/acp_gateway_server_pristine.py "$T/goalovl/engine/acp_adapter/gateway_server.py"
cp tests/fixtures/hermes_goals_pristine.py "$T/goalovl/engine/hermes_cli/goals.py"
: > "$T/goalovl/engine/hermes_cli/__init__.py"
check "hooks into a clean engine's connection (pinned Hermes)" bash -c "ONE_SUPPORT_DIR=$T/goalovl $BIN --apply-overlay | grep -q 'goals overlay ok'"
check "and copies the module next to it" cmp tools/overlay/acp_adapter/one_goals.py "$T/goalovl/engine/acp_adapter/one_goals.py"
check "and hooks the engine's own goal loop (pinned Hermes)" grep -q "_one_goal_progress_install" "$T/goalovl/engine/hermes_cli/goals.py"
check "with the progress module next to it" cmp tools/overlay/hermes_cli/one_goal_progress.py "$T/goalovl/engine/hermes_cli/one_goal_progress.py"
cp "$T/goalovl/engine/acp_adapter/gateway_server.py" "$T/goalovl/once.py"
cp "$T/goalovl/engine/hermes_cli/goals.py" "$T/goalovl/once-goals.py"
ONE_SUPPORT_DIR="$T/goalovl" "$BIN" --apply-overlay >/dev/null
check "second run changes nothing" cmp "$T/goalovl/once.py" "$T/goalovl/engine/acp_adapter/gateway_server.py"
check "second run changes nothing in the goal loop either" cmp "$T/goalovl/once-goals.py" "$T/goalovl/engine/hermes_cli/goals.py"
check "the hooked connection still loads" /usr/bin/python3 -c "import ast,sys; ast.parse(open('$T/goalovl/engine/acp_adapter/gateway_server.py').read())"
check "goals keep going while they make progress: more turns while the count moves, the ceiling, a stall pauses, waiting for you, no count (the judge), its own helpers at work" /usr/bin/python3 tools/goal-progress-check.py "$T/goalovl/engine"
check "notes kept out of the goal, the yes rule added, held only while its goal works, Stop pauses it, mid-goal messages reach it, an answer picks a waiting goal back up, held while its own helpers work" /usr/bin/python3 tools/goal-overlay-check.py
check "typed /goal commands, Goal: helper jobs, the engine's goal row in plain words, the goal line, Stop" bash -c "ONE_SUPPORT_DIR=$T/goals $TBIN --test-goals | tee $T/goals-out.txt | grep -q '^goals ok'"
[ $CI = 0 ] && LIMIT=600 check "the real engine with a stand-in model: done, budget, Stop, pause/resume, a helper's goal, a send waiting for a yes, more turns while moving, ceiling, stall, waiting for you then an answer" tools/goal-engine-check.sh

echo "Skill folders: a link back up never loops the engine"
mkdir -p "$T/sw/engine/agent"
cp tests/fixtures/skill_walk/skill_utils.py tests/fixtures/skill_walk/prompt_builder.py "$T/sw/engine/agent/"
ONE_SUPPORT_DIR="$T/sw" "$BIN" --apply-overlay >/dev/null
cp "$T/sw/engine/agent/skill_utils.py" "$T/sw/once.py"
ONE_SUPPORT_DIR="$T/sw" "$BIN" --apply-overlay >/dev/null
check "the engine's two skill walks (pinned Hermes) skip a folder already walked; flat and learned/ recipes both found" /usr/bin/python3 tools/skill-walk-check.py "$T/sw/engine/agent"
check "second run changes nothing" cmp "$T/sw/once.py" "$T/sw/engine/agent/skill_utils.py"

echo "Guards (enforced in code)"
mkdir -p "$T/g/support" "$T/g/cloud"
check "shared rooms, experimental connections, friction log" bash -c "ONE_SUPPORT_DIR=$T/g/support ONE_CLOUD_DIR=$T/g/cloud $TBIN --test-guards | tee $T/g/out.txt | grep -q '^guards ok'"
grep "✗" "$T/g/out.txt" 2>/dev/null | sed 's/^/    /'
mkdir -p "$T/lg"
check "shortcut guard: a link to itself, to its own folder and a file pointing at itself are removed and logged (3 lines); links elsewhere stay" bash -c "ONE_SUPPORT_DIR=$T/lg $TBIN --test-link-guard | tee $T/lg/out.txt | grep -q '^link guard ok'"
grep "✗" "$T/lg/out.txt" 2>/dev/null | sed 's/^/    /'
mkdir -p "$T/rp/support" "$T/rp/cloud"
check "room.yaml privacy: Nyx and the personal room never offered for sharing or in the global recipe list; room.yaml only where missing; assistant/ never overwritten" bash -c "ONE_SUPPORT_DIR=$T/rp/support ONE_CLOUD_DIR=$T/rp/cloud $TBIN --test-rooms-privacy | tee $T/rp/out.txt | grep -q '^rooms privacy ok'"
grep "✗" "$T/rp/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Instant copies, earlier versions, putting one back, the locked copy in iCloud"
mkdir -p "$T/hist/support" "$T/hist/cloud"
check "copies are clones and skip iCloud-only files, put back saves what was there first, pruning keeps the right ones and never before-move, the locked copy opens with its key" bash -c "ONE_SUPPORT_DIR=$T/hist/support ONE_CLOUD_DIR=$T/hist/cloud $TBIN --test-history | tee $T/hist/out.txt | grep -q '^history ok'"
grep "✗" "$T/hist/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Improve: the look-only score (made-up records)"
mkdir -p "$T/imp"
check "corrections, cut-offs, walls and slow jobs counted; week %, not enough jobs, one incident; history only read; nothing private in moments" bash -c "ONE_SUPPORT_DIR=$T/imp $TBIN --test-improve | tee $T/imp/out.txt | grep -q '^improve ok'"
grep "✗" "$T/imp/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Nightly review: what one night may change, its undo, only when nothing else is working"
mkdir -p "$T/night"
check "suggestions-only nights change nothing, edit nights within limits, undo, the 7-day check, the gate, the morning lines, the routine made once" bash -c "ONE_SUPPORT_DIR=$T/night $TBIN --test-nightly | tee $T/night/out.txt | grep -q '^nightly ok'"
grep "✗" "$T/night/out.txt" 2>/dev/null | sed 's/^/    /'

echo "The engine's own learning stays under the nightly limits"
check "the after-job review is held at 5 recipes a day and 1 per recipe; the person, helpers and the nightly review never are" /usr/bin/python3 tools/learning-cap-check.py
[ $CI = 0 ] && check "the real engine loads the learning cap and holds the review's 6th edit" tools/learning-cap-engine-check.sh

echo "Local models"
mkdir -p "$T/local"
check "local model list, memory choice and warning" bash -c "ONE_SUPPORT_DIR=$T/local $TBIN --test-local-model | grep -q '^local: .* ✓'"

echo "Switch AI: every provider offered, a stuck wait always has a message, the title never duplicates"
mkdir -p "$T/switchai"
check "switch AI decisions, wait message and no duplicate title bubble" bash -c "ONE_SUPPORT_DIR=$T/switchai $TBIN --test-switch-ai | tee $T/switchai/out.txt | grep -q '✓'; ! grep -q '✗' $T/switchai/out.txt"
grep "✗" "$T/switchai/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Accounts: parsing hermes auth list, naming a new account, spotting a pool failover"
mkdir -p "$T/accounts"
check "account parsing, naming and limit-notice checks" bash -c "ONE_SUPPORT_DIR=$T/accounts $TBIN --test-accounts | tee $T/accounts/out.txt | grep -q '✓'; ! grep -q '✗' $T/accounts/out.txt"
grep "✗" "$T/accounts/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Other AIs and thinking levels: the engine's list, a key's check, each brain's level"
mkdir -p "$T/oa"
check "Other AIs keeps plain-key AIs only, groups never drop one, presets set Max/Medium/Low and step down, keys checked as each AI expects" bash -c "ONE_SUPPORT_DIR=$T/oa $TBIN --test-other-ais | tee $T/oa/out.txt | grep -q '^other ais ok'"
grep "✗" "$T/oa/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Blocked on a step only you can do: ask, never substitute"
mkdir -p "$T/bl"
check "rule in SOUL and every helper turn (first, follow-up, picked back up); One spots a robot check, asks Can I show you the window?, turns that helper orange, shows nothing by itself" bash -c "ONE_SUPPORT_DIR=$T/bl $TBIN --test-blocked | tee $T/bl/out.txt | grep -q '^blocked ok'"
grep "✗" "$T/bl/out.txt" 2>/dev/null | sed 's/^/    /'

echo "The Mac stays awake while One works, and sleeps as usual after"
mkdir -p "$T/ka" "$T/ka2"
check "a fake helper holds one plain-words no-idle-sleep assertion (screen can still sleep), more work renames it, 300 flips leak nothing, done lets go; SOUL and every prompt say lid open = keeps going" bash -c "ONE_SUPPORT_DIR=$T/ka $TBIN --test-keep-awake | tee $T/ka/out.txt | grep -q '^keep awake ok'"
grep "✗" "$T/ka/out.txt" 2>/dev/null | sed 's/^/    /'
check "pmset -g assertions: shown while a fake helper works, gone after, gone when One crashes" bash -c "tools/keep-awake-check.sh $TBIN $T/ka2 | tee $T/ka2/out.txt | grep -q '^keep awake pmset ok'"
grep "✗" "$T/ka2/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Asleep, no speaker, a failed start: One never stays down (Nov 6-7 2026: 18 hours offline)"
mkdir -p "$T/ss"
check "audio exceptions caught; launch in a dark wake and with no speaker: no crash, words still show; the line comes back on wake; the keeper's decisions" bash -c "ONE_SUPPORT_DIR=$T/ss $TBIN --test-sleep-safe | tee $T/ss/out.txt | grep -q '^sleep safe ok'"
grep "✗" "$T/ss/out.txt" 2>/dev/null | sed 's/^/    /'
check "the keeper really opens One again after a failed start, waits longer each time, puts the previous version back after 3 failures, never after a quit" bash -c "tools/keeper-check.sh $TBIN $T/keeper | tee $T/keeper.txt | grep -q '^keeper ok'"
grep "✗" "$T/keeper.txt" 2>/dev/null | sed 's/^/    /'
check "phone messages sent while One was off: the last 2 hours answered, older ones listed in one note and never acted on" /usr/bin/python3 tools/missed-messages-check.py
[ $CI = 0 ] && check "the real engine runs the missed-messages plugin on real messages" tools/missed-messages-engine-check.sh

echo "Tell me when I learn (decisions on a made-up skill log)"
mkdir -p "$T/lrn"
check "new skill told once, fixes silent, the remember question once and never after a no; shared rooms left out" bash -c "ONE_SUPPORT_DIR=$T/lrn $TBIN --test-learning | tee $T/lrn/out.txt | grep -q '^learning ok'"
mkdir -p "$T/rt"
check "smart routing: recipes, rooms, the yes gate, the brain, never Nyx" bash -c "ONE_SUPPORT_DIR=$T/rt $TBIN --test-routing | tee $T/rt/out.txt | grep -q '^routing ok'"
grep "✗" "$T/lrn/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Front page and recipe filer (USER.md, MEMORY.md from My Brain/assistant; new recipes into the brain)"
mkdir -p "$T/fp/support" "$T/fp/cloud"
check "USER.md from live connections, MEMORY.md filed then rebuilt, recipes filed into rooms, undo" bash -c "ONE_SUPPORT_DIR=$T/fp/support ONE_CLOUD_DIR=$T/fp/cloud $TBIN --test-front-page | tee $T/fp/out.txt | grep -q '^front page ok'"
grep "✗" "$T/fp/out.txt" 2>/dev/null | sed 's/^/    /'
echo "Brain search (One --search)"
mkdir -p "$T/srch"
check "private rooms and locked drawers never in a search that names no room, named rooms work, edits and deletes picked up, a broken index rebuilt, close spellings, 1,000 notes fast" bash -c "ONE_SUPPORT_DIR=$T/srch $TBIN --test-search | tee $T/srch/out.txt | grep -q '^search ok'"
grep -E "✗|took:" "$T/srch/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Helpers: look only, own repo copies, earlier results, restarts that don't cut work off"
mkdir -p "$T/hw"
check "look-only marks (engine can't write them, only their message lifts one), a worktree for a repo another helper is in (removed after, unsaved work kept), today's related results, long turns kept while active, the chat waited for through a slow restart, restarts between steps" bash -c "ONE_SUPPORT_DIR=$T/hw $TBIN --test-helper-work | tee $T/hw/out.txt | grep -q '^helper work ok'"
grep "✗" "$T/hw/out.txt" 2>/dev/null | sed 's/^/    /'
check "a look-only helper can't commit, push, tag, release, install or post; other helpers and plain reading are untouched" /usr/bin/python3 tools/look-only-check.py

echo "Folder approval ledger (every new grant needs a yes in the conversation first)"
mkdir -p "$T/fa"
check "existing folders never dropped, migration grandfathers them once, chat ask+yes grants and logs, a denied/bare-write path stays unlogged" bash -c "ONE_SUPPORT_DIR=$T/fa $TBIN --test-folder-approval | tee $T/fa/out.txt | grep -q '^PASS folder approval'"
grep "✗" "$T/fa/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Engine helper is never stopped by a second One"
mkdir -p "$T/gw"
check "a second engine start or test copy leaves a healthy one alone" bash -c "ONE_SUPPORT_DIR=$T/gw $TBIN --test-gateway | tee $T/gw/out.txt | grep -q '^gateway ok'"
grep "✗" "$T/gw/out.txt" 2>/dev/null | sed 's/^/    /'
# End to end: a stand-in gateway in a scratch home, then the command-line modes preflight uses.
mkdir -p "$T/gw2/hermes" "$T/gw2/engine/.hermes/bin" "$T/gw2/r"
printf '#!/bin/sh\nexit 0\n' > "$T/gw2/engine/.hermes/bin/hermes"; chmod +x "$T/gw2/engine/.hermes/bin/hermes"
/usr/bin/python3 -c 'import time; time.sleep(300)' gateway run & GWP=$!
echo "{\"pid\": $GWP}" > "$T/gw2/hermes/gateway.pid"
(cd "$T/gw2/r" && ONE_SUPPORT_DIR="$T/gw2" perl -e 'alarm 60; exec @ARGV' "$TBIN" --check-update >/dev/null 2>&1)
(cd "$T/gw2/r" && ONE_SUPPORT_DIR="$T/gw2" perl -e 'alarm 90; exec @ARGV' "$TBIN" --render-world p >/dev/null 2>&1)
check "check-update and renders leave it running" kill -0 $GWP
check "and never start an engine" bash -c "! pgrep -f '$T/gw2/engine' >/dev/null"
kill $GWP 2>/dev/null

echo "The hidden browser comes back with its saved sign-ins"
mkdir -p "$T/br"
check "same profile and port, hidden, never from a test copy; Claude sign-in read from its cookie" bash -c "ONE_SUPPORT_DIR=$T/br $TBIN --test-browser | tee $T/br/out.txt | grep -q '^browser ok'"
grep "FAIL" "$T/br/out.txt" 2>/dev/null | sed 's/^/    /'

echo "A hidden browser never shows in the Dock or Stage Manager and never comes to the front"
mkdir -p "$T/hb"
LIMIT=240 check "started hidden through the Mac, never in front, background-only; still hidden when the Mac opens Chrome; a start request only on an allowed profile" bash -c "ONE_SUPPORT_DIR=$T/hb $TBIN --test-hidden-browser 2>&1 | tee $T/hb/out.txt | grep -q '^hidden browser ok'"
grep -E "✗|macOS sent|…" "$T/hb/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Restart by itself after a new folder is allowed"
wait $RS_PID
check "a changed folder list restarts once with the new folder, an unchanged one never" grep -q '^restart ok' "$T/rs/out.txt"
grep "✗" "$T/rs/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Helpers a restart cut off pick up where they left off"
mkdir -p "$T/hl"  # the test never reads or writes your saved helpers: they go through in-memory data
check "trail saved, picked up once at launch with it; finished, stopped-with-Stop and a third cut-off never" bash -c "ONE_SUPPORT_DIR=$T/hl $TBIN --test-helpers | tee $T/hl/out.txt | grep -q '^helpers ok'"
grep "✗" "$T/hl/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Helpers show their real progress"
mkdir -p "$T/pg"
check "real step words, its time past 30 s, a slow command, no progress after 6 quiet min (never stopped), plan line, a build waiting its turn" bash -c "ONE_SUPPORT_DIR=$T/pg $TBIN --test-progress | tee $T/pg/out.txt | grep -q '^progress ok'"
grep "✗" "$T/pg/out.txt" 2>/dev/null | sed 's/^/    /'

if [ $QUICK = 0 ]; then
  echo "Lots of helpers survive restarts (stand-in engine, no cost)"
  LIMIT=480 check "100 at once; engine killed, One killed and an update mid-run: every one listed, none doubled or falsely done, all finish" \
    bash -c "tools/helpers-check.sh --no-build > '$T/hs.txt' 2>&1"
  grep "✗" "$T/hs.txt" 2>/dev/null | sed 's/^/    /'
  grep -q "helpers-check ok" "$T/hs.txt" 2>/dev/null || grep -q "✗" "$T/hs.txt" 2>/dev/null || tail -12 "$T/hs.txt" 2>/dev/null | sed 's/^/    /'  # cut off with no ✗: show where
else
  echo "Lots of helpers survive restarts: skipped (--quick; runs on main, nightly, on release tags and locally)"
fi

echo "Stop talking just this once"
mkdir -p "$T/vc"; VM_BEFORE=$(defaults read ai.forjado.one voiceMuted 2>/dev/null)  # stand-in voice, its own settings
check "hush drops the rest of that reply, never mutes, the next reply speaks; helper sound rules" bash -c "ONE_SUPPORT_DIR=$T/vc $TBIN --test-voice | tee $T/vc/out.txt | grep -q '^voice ok'"
grep "✗" "$T/vc/out.txt" 2>/dev/null | sed 's/^/    /'
check "the voice test left your mute setting alone" test "$VM_BEFORE" = "$(defaults read ai.forjado.one voiceMuted 2>/dev/null)"

echo "Shipped skills"
mkdir -p "$T/sk"
check "fresh home gets them, edited copies are kept" bash -c "ONE_SUPPORT_DIR=$T/sk $TBIN --test-skills | tee $T/sk/out.txt | grep -q '^skills ok'"
grep "✗" "$T/sk/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Home glass"
if [ $CI = 0 ]; then  # needs a real window on screen
  mkdir -p "$T/gl"
  check "only the blur is left under the tint (design: blur 40, saturate 1.4), also after focus, resize, appearance" bash -c "ONE_SUPPORT_DIR=$T/gl $TBIN --test-glass | tee $T/gl/out.txt | grep -q '^glass ok'"
  grep "FAIL" "$T/gl/out.txt" 2>/dev/null | sed 's/^/    /'
fi

echo "Long messages and pastes"
if true; then  # a real window on the CI runner's own screen
  mkdir -p "$T/lp"
  LIMIT=300 check "long messages fold and stay open once opened; a long paste asks as a file or as text by every road in (⌘V, Caps Lock, Edit › Paste, right-click, a drop, dictation, focus on a message), once (Esc, click outside, Return), the file holds the exact text, short pastes and pictures unchanged" bash -c "ONE_SUPPORT_DIR=$T/lp perl -e 'alarm 280; exec @ARGV' $TBIN --test-long-paste > $T/lp/out.txt 2>&1; grep -q '^long paste: all checks passed' $T/lp/out.txt || { grep -E '✗|refusing|stopped' $T/lp/out.txt; tail -4 $T/lp/out.txt; exit 1; }"
  grep "✗" "$T/lp/out.txt" 2>/dev/null | sed 's/^/    /'
fi

echo "Earlier messages"
mkdir -p "$T/cp"
check "earlier messages load 20 at a time and keep your place, the chat is kept by day all the way back, Find and day jumps land on the message, folded messages lay out only their first lines" bash -c "ONE_SUPPORT_DIR=$T/cp perl -e 'alarm 120; exec @ARGV' $TBIN --test-chat-pages | tee $T/cp/out.txt | grep -q '^chat pages: all checks passed'"
grep "✗" "$T/cp/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Folder lock"
"$BIN" --print-profile > "$T/one.sb"
SUP="$HOME/Library/Application Support/One"; mkdir -p "$SUP"
check "One's own folder is readable" sandbox-exec -f "$T/one.sb" /bin/ls "$SUP"
PROBE="$HOME/.one-preflight-probe-$$"; mkdir -p "$PROBE"; echo secret > "$PROBE/x"
check "a folder you never approved is blocked" bash -c "! sandbox-exec -f '$T/one.sb' /bin/cat '$PROBE/x' >/dev/null 2>&1"
rm -rf "$PROBE"
check "SSH keys are not writable" bash -c "! sandbox-exec -f '$T/one.sb' /usr/bin/touch '$HOME/.ssh/one-preflight' 2>/dev/null"
check "KeePassXC settings readable" bash -c "grep -q 'Application Support/KeePassXC' '$T/one.sb'"
mkdir -p "$SUP/guard/allow"
check "the engine can't write a yes for a browser window (only One can)" bash -c "! sandbox-exec -f '$T/one.sb' /usr/bin/touch '$SUP/guard/allow/preflight-probe.json' 2>/dev/null"
check "the engine can't change the browser guard" bash -c "grep -F '(deny file-write*' '$T/one.sb' | grep -q 'plugins/one-browser-guard'"
rm -f "$SUP/guard/allow/preflight-probe.json"

echo "No browser window without their yes"
check "visible launches blocked (open -a, AppleScript, no --headless), logged, one window per yes" /usr/bin/python3 tools/browser-guard-check.py
[ $CI = 0 ] && check "the real engine loads the guard and blocks a visible browser" tools/browser-guard-engine-check.sh

echo "Updater"
mkdir -p "$T/upd"; tools/test-copy.sh preflight-old "$T/upd" >/dev/null
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString 0.0.1" "$T/upd/One.app/Contents/Info.plist"
codesign -fs - "$T/upd/One.app" >/dev/null 2>&1
mkdir -p "$T/upd/sup"  # its own scratch home: this copy loads the window and must never reach the real One
check "an old copy sees the latest release" bash -c "ONE_SUPPORT_DIR='$T/upd/sup' '$T/upd/One.app/Contents/MacOS/One' --check-update | grep -q 'available'"
mkdir -p "$T/upd/t"; RD_BEFORE=$(defaults read ai.forjado.one updateAnnounced 2>/dev/null)
check "a new version is announced once; same, older or zip-less never; never installed in a dark wake; the old version kept" bash -c "ONE_SUPPORT_DIR='$T/upd/t' $TBIN --test-updates | tee $T/upd/t/out.txt | grep -q '^updates ok'"
grep "✗" "$T/upd/t/out.txt" 2>/dev/null | sed 's/^/    /'
check "the test left your real settings alone" test "$RD_BEFORE" = "$(defaults read ai.forjado.one updateAnnounced 2>/dev/null)"

echo "Routines: only a real failure is orange"
mkdir -p "$T/rtn"
check "a routine that ran all its runs leaves the dial for the quiet Finished list (Run again asks first); paused, missed while the Mac slept, still to come and never run stay calm; only a real failure is orange" bash -c "ONE_SUPPORT_DIR=$T/rtn $TBIN --test-routines | tee $T/rtn/out.txt | grep -q '^routines ok'"
grep "✗" "$T/rtn/out.txt" 2>/dev/null | sed 's/^/    /'

if [ $CI = 0 ]; then
echo "Screens"
mkdir -p "$T/r"; # Renders read the real brain (live-rooms) but get a scratch home, so they can't touch the engine.
mkdir -p "$T/rsup"; (cd "$T/r" && ONE_SUPPORT_DIR="$T/rsup" perl -e 'alarm 150; exec @ARGV' "$TBIN" --render-world p >/dev/null 2>&1)
for f in p-orb p-cw-all p-cw-other p-me-card p-live-rooms; do check "renders $f" test -s "$T/r/$f.png"; done
fi

if [ $FULL = 1 ] && [ $CI = 0 ]; then
  echo "Fresh install (empty folder, nothing from this Mac)"
  mkdir -p "$T/fresh"
  (cd "$T/fresh" && ONE_SUPPORT_DIR="$T/fresh" perl -e 'alarm 600; exec @ARGV' "$TBIN" --install-test > "$T/fresh/out.txt" 2>&1)
  check "engine installs" grep -q "^install: ok" "$T/fresh/out.txt"
  check "installed into the empty folder" grep -q "hermes: $T/fresh" "$T/fresh/out.txt"
  check "fresh engine is the pinned version" bash -c "[ \"$(cd $T/fresh/engine && git rev-parse HEAD)\" = \"$(cat $APP/Contents/Resources/hermes-commit.txt)\" ]"
  check "KeePass in the fresh engine" grep -q KeePassLoginBackend "$T/fresh/engine/agent/vault_backends/base.py"
  check "tools Python built" test -x "$T/fresh/tools-venv/bin/python"
fi

echo "Your files and settings are production"
mkdir -p "$T/prod"
check "a test run as your real One refuses and does nothing" bash -c "ONE_SUPPORT_DIR=$T/prod perl -e 'alarm 30; exec @ARGV' $BIN --test-connections-open 1 | grep -q '^refusing' && [ \${PIPESTATUS[0]} = 2 ]"
# Nov 9, 2026: a render run as the real One wrote assistantName = "Elias" into the person's settings.
defaults export ai.forjado.one "$T/prod/defaults.before" >/dev/null 2>&1 || : > "$T/prod/defaults.before"
for r in --render-routines --render-world --render-switch-ai; do
  check "a render as your real One refuses ($r)" bash -c "ONE_SUPPORT_DIR=$T/prod perl -e 'alarm 30; exec @ARGV' $BIN $r $T/prod/r | grep -q '^refusing' && [ \${PIPESTATUS[0]} = 2 ] && ! ls $T/prod/r* >/dev/null 2>&1"
done
defaults export ai.forjado.one "$T/prod/defaults.after" >/dev/null 2>&1 || : > "$T/prod/defaults.after"
check "renders and tests left your real settings exactly as they were" cmp -s "$T/prod/defaults.before" "$T/prod/defaults.after"
check "a test copy keeps to its own world (with a scratch folder)" bash -c "ONE_SUPPORT_DIR=$T/prod $TBIN --test-production | tee $T/prod/out.txt | grep -q '^production ok'"
grep "✗" "$T/prod/out.txt" 2>/dev/null | sed 's/^/    /'
check "a test copy keeps to its own world (no folder given)" bash -c "env -u ONE_SUPPORT_DIR $TBIN --test-production | grep -q '^production ok'"
made_list > "$T/made.after"; shelf_list > "$T/shelf.after"
check "no file in your Made by folder went missing" bash -c "[ -z \"\$(comm -23 '$T/made.before' '$T/made.after')\" ]"
check "no card on your Ready for you shelf went missing" bash -c "[ -z \"\$(comm -23 '$T/shelf.before' '$T/shelf.after')\" ]"

echo "Your live One"
GW_AFTER=$(gw_id)
if [ -n "$GW_BEFORE" ]; then
  check "its engine helper was not restarted by this run" test "$GW_BEFORE" = "$GW_AFTER"
fi

echo
echo "$pass passed, $fail failed"
[ $fail = 0 ]
