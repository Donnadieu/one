#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Proves the REAL engine, with One's restart-replay plugin, never tells a person their turn "will not be run again"
# (tools/restart-replay-engine-check.py): first the engine alone (the Nov 10-22 words, nothing kept), then with the
# plugin: One's line in the conversation and on the stream, a phone message the restart cut kept on disk and sent
# again exactly once when Telegram is back (twice cut: one plain line), stale or moved-on ones left alone, plain
# shutdown words on the phone. The engine to use: ONE_SUPPORT_DIR's (the fresh-install workflow installs one there).
#   ONE_SUPPORT_DIR=<folder with engine/> tools/restart-replay-engine-check.sh    prints "engine restart-replay ok" when it passes
set -u
cd "$(dirname "$0")/.." || exit 1
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
E="$SUP/engine"
[ -d "$E/hermes_cli" ] || { echo "no engine in $SUP; skipped"; exit 0; }
PY=""
for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
  (cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import hermes_cli.plugins, gateway.session_settlement_recovery" >/dev/null 2>&1) && { PY="$p"; break; }
done
[ -n "$PY" ] || { echo "engine python not found"; exit 1; }
W="$SUP/hermes/cache/scratch/restart-replay-check-$$"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/plugins/one-restart-replay"
cp tools/overlay/plugins/one-restart-replay/__init__.py tools/overlay/plugins/one-restart-replay/plugin.yaml "$W/home/plugins/one-restart-replay/"
cp tools/restart-replay-engine-check.py "$W/check.py"
# What RestartReplayPlugin.sync turns on (Sources/TurnJournal.swift).
printf 'plugins:\n  enabled:\n    - one-restart-replay\n' > "$W/home/config.yaml"
printf 'TELEGRAM_BOT_TOKEN=123:stand-in\nTELEGRAM_ALLOWED_USERS=42\n' > "$W/home/.env"
cd "$E" && HERMES_DISABLE_LAZY_INSTALLS=1 HERMES_HOME="$W/home" HERMES_RUNTIME_DIR="$SUP/hermes/tools" "$PY" -I "$W/check.py" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
