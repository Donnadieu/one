#!/bin/bash
# One preflight: must pass before every release.
#   tools/preflight.sh           quick checks (about 1 minute, no login, no network except the updater check)
#   tools/preflight.sh --full    also a fresh engine install into an empty folder (about 2 minutes)
#   tools/preflight.sh --ci      skip checks that need a Mac with One's engine (GitHub runners)
set -u
cd "$(dirname "$0")/.."
FULL=0; CI=0
for a in "$@"; do [ "$a" = --full ] && FULL=1; [ "$a" = --ci ] && CI=1; done
T="${TMPDIR:-/tmp}/one-preflight-$$"; mkdir -p "$T"
trap 'rm -rf "$T"' EXIT
APP=build/One.app; BIN="$APP/Contents/MacOS/One"
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@" >"$T/last.log" 2>&1; then ok "$name"; else bad "$name"; sed 's/^/      /' "$T/last.log" | tail -5; fi; }

echo "Build"
check "app builds" ./build.sh
[ -x "$BIN" ] || { echo "No app binary, stopping."; exit 1; }

echo "Bundle"
check "version matches VERSION" bash -c "[ \"\$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)\" = \"\$(tr -d '[:space:]' < VERSION)\" ]"
check "Hermes version pinned" test -s "$APP/Contents/Resources/hermes-commit.txt"
check "KeePass backend bundled" test -f "$APP/Contents/Resources/keepass.py"
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
check "shared rooms, experimental connections, friction log" bash -c "ONE_SUPPORT_DIR=$T/g/support ONE_CLOUD_DIR=$T/g/cloud $BIN --test-guards | tee $T/g/out.txt | grep -q '^guards ok'"
grep "✗" "$T/g/out.txt" 2>/dev/null | sed 's/^/    /'

echo "Folder lock"
"$BIN" --print-profile > "$T/one.sb"
SUP="$HOME/Library/Application Support/One"; mkdir -p "$SUP"
check "One's own folder is readable" sandbox-exec -f "$T/one.sb" /bin/ls "$SUP"
PROBE="$HOME/.one-preflight-probe-$$"; mkdir -p "$PROBE"; echo secret > "$PROBE/x"
check "a folder you never approved is blocked" bash -c "! sandbox-exec -f '$T/one.sb' /bin/cat '$PROBE/x' >/dev/null 2>&1"
rm -rf "$PROBE"
check "SSH keys are not writable" bash -c "! sandbox-exec -f '$T/one.sb' /usr/bin/touch '$HOME/.ssh/one-preflight' 2>/dev/null"
check "KeePassXC settings readable" bash -c "grep -q 'Application Support/KeePassXC' '$T/one.sb'"

echo "Updater"
mkdir -p "$T/upd"; cp -R "$APP" "$T/upd/"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString 0.0.1" "$T/upd/One.app/Contents/Info.plist"
codesign -fs - "$T/upd/One.app" >/dev/null 2>&1
check "an old copy sees the latest release" bash -c "'$T/upd/One.app/Contents/MacOS/One' --check-update | grep -q 'available'"

if [ $CI = 0 ]; then
echo "Screens"
mkdir -p "$T/r"; (cd "$T/r" && perl -e 'alarm 150; exec @ARGV' "$OLDPWD/$BIN" --render-world p >/dev/null 2>&1)
for f in p-orb p-cw-all p-cw-other p-me-card p-live-rooms; do check "renders $f" test -s "$T/r/$f.png"; done
fi

if [ $FULL = 1 ] && [ $CI = 0 ]; then
  echo "Fresh install (empty folder, nothing from this Mac)"
  mkdir -p "$T/fresh"
  (cd "$T/fresh" && ONE_SUPPORT_DIR="$T/fresh" perl -e 'alarm 600; exec @ARGV' "$OLDPWD/$BIN" --install-test > "$T/fresh/out.txt" 2>&1)
  check "engine installs" grep -q "^install: ok" "$T/fresh/out.txt"
  check "installed into the empty folder" grep -q "hermes: $T/fresh" "$T/fresh/out.txt"
  check "fresh engine is the pinned version" bash -c "[ \"$(cd $T/fresh/engine && git rev-parse HEAD)\" = \"$(cat $APP/Contents/Resources/hermes-commit.txt)\" ]"
  check "KeePass in the fresh engine" grep -q KeePassLoginBackend "$T/fresh/engine/agent/vault_backends/base.py"
  check "tools Python built" test -x "$T/fresh/tools-venv/bin/python"
fi

echo
echo "$pass passed, $fail failed"
[ $fail = 0 ]
