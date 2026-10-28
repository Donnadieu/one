#!/bin/bash
# One preflight: must pass before every release.
#   tools/preflight.sh           quick checks (about 1 minute, no login, no network except the updater check)
#   tools/preflight.sh --full    also a fresh engine install into an empty folder (about 2 minutes)
#   tools/preflight.sh --ci      skip checks that need a Mac with One's engine (GitHub runners)
set -u
cd "$(dirname "$0")/.."
FULL=0; CI=0
for a in "$@"; do [ "$a" = --full ] && FULL=1; [ "$a" = --ci ] && CI=1; done
# .noindex: Spotlight never lists the test copies as apps
T="${TMPDIR:-/tmp}/one-preflight-$$.noindex"; mkdir -p "$T"
trap 'rm -rf "$T"; defaults delete ai.forjado.one.preflight >/dev/null 2>&1; defaults delete ai.forjado.one.preflight-old >/dev/null 2>&1' EXIT
APP=build/app.noindex/One.app; BIN="$APP/Contents/MacOS/One"
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@" >"$T/last.log" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/      /' "$T/last.log" | tail -5; fi; }

# The person's live One must survive this run: note its engine helper now, compare at the end.
REAL_PID_FILE="$HOME/Library/Application Support/One/hermes/gateway.pid"
gw_id() { local p; p=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$REAL_PID_FILE" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p $(ps -o lstart= -p "$p")"; }
GW_BEFORE=$(gw_id)

echo "Build"
check "app builds" ./build.sh
[ -x "$BIN" ] || { echo "No app binary, stopping."; exit 1; }
# Your files and settings are production. Every test below runs from a test copy with its own bundle id
# (own settings) and a scratch One folder; the real build only runs to prove it refuses. See TestWorld.swift.
TAPP=$(tools/test-copy.sh preflight "$T/app"); TBIN="$TAPP/Contents/MacOS/One"
defaults delete ai.forjado.one.preflight >/dev/null 2>&1
made_list() { ls -1 "$HOME/Documents"/Made\ by*/ 2>/dev/null | sort; }
shelf_list() { defaults export ai.forjado.one - 2>/dev/null | plutil -extract shelf raw -o - - 2>/dev/null | base64 -D 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys; [print(x["path"]) for x in json.load(sys.stdin)]' 2>/dev/null | sort; }
made_list > "$T/made.before"; shelf_list > "$T/shelf.before"

echo "Bundle"
check "version matches VERSION" bash -c "[ \"\$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)\" = \"\$(tr -d '[:space:]' < VERSION)\" ]"
check "Hermes version pinned" test -s "$APP/Contents/Resources/hermes-commit.txt"
check "KeePass backend bundled" test -f "$APP/Contents/Resources/keepass.py"
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

echo "Guards (enforced in code)"
mkdir -p "$T/g/support" "$T/g/cloud"
check "shared rooms, experimental connections, friction log" bash -c "ONE_SUPPORT_DIR=$T/g/support ONE_CLOUD_DIR=$T/g/cloud $TBIN --test-guards | tee $T/g/out.txt | grep -q '^guards ok'"
grep "✗" "$T/g/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Tell me when I learn (decisions on a made-up skill log)"
mkdir -p "$T/lrn"
check "new skill told once, fixes silent, the remember question once and never after a no; shared rooms left out" bash -c "ONE_SUPPORT_DIR=$T/lrn $TBIN --test-learning | tee $T/lrn/out.txt | grep -q '^learning ok'"
grep "✗" "$T/lrn/out.txt" 2>/dev/null | sed 's/^/    /'

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

echo "Restart by itself after a new folder is allowed"
mkdir -p "$T/rs"
check "a changed folder list restarts once with the new folder, an unchanged one never" bash -c "ONE_SUPPORT_DIR=$T/rs $TBIN --test-restart | tee $T/rs/out.txt | grep -q '^restart ok'"
grep "✗" "$T/rs/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Helpers a restart cut off pick up where they left off"
mkdir -p "$T/hl"  # the test never reads or writes your saved helpers: they go through in-memory data
check "trail saved, picked up once at launch with it; finished, stopped-with-Stop and a third cut-off never" bash -c "ONE_SUPPORT_DIR=$T/hl $TBIN --test-helpers | tee $T/hl/out.txt | grep -q '^helpers ok'"
grep "✗" "$T/hl/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Stop talking just this once"
mkdir -p "$T/vc"; VM_BEFORE=$(defaults read ai.forjado.one voiceMuted 2>/dev/null)  # stand-in voice, its own settings
check "hush drops the rest of that reply, never mutes, the next reply speaks" bash -c "ONE_SUPPORT_DIR=$T/vc $TBIN --test-voice | tee $T/vc/out.txt | grep -q '^voice ok'"
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
check "a new version is announced once; same, older or zip-less never" bash -c "ONE_SUPPORT_DIR='$T/upd/t' $TBIN --test-updates | tee $T/upd/t/out.txt | grep -q '^updates ok'"
grep "✗" "$T/upd/t/out.txt" 2>/dev/null | sed 's/^/    /'
check "the test left your real settings alone" test "$RD_BEFORE" = "$(defaults read ai.forjado.one updateAnnounced 2>/dev/null)"

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
