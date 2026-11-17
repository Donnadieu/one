#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Proves the REAL engine turns a Telegram reply's last-line [choices: …] into tap buttons through One's phone-tags
# plugin (tools/phone-choices-engine-check.py): its own plugin discovery, Telegram handler wiring, turn end
# (apply_llm_output_transform), post-delivery slot and Telegram send, with a stand-in bot. A tap goes to the gateway
# as the person's message; old buttons stop working; One's own chat and turns it can't tie to are left alone.
# The engine to use: ONE_SUPPORT_DIR's (the fresh-install workflow installs one there).
#   ONE_SUPPORT_DIR=<folder with engine/> tools/phone-choices-engine-check.sh    prints "engine choices ok" when it passes
set -u
cd "$(dirname "$0")/.."
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
E="$SUP/engine"
[ -d "$E/hermes_cli" ] || { echo "no engine in $SUP; skipped"; exit 0; }
PY=""
for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
  (cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import hermes_cli.plugins, plugins.platforms.telegram.adapter" >/dev/null 2>&1) && { PY="$p"; break; }
done
[ -n "$PY" ] || { echo "engine python not found"; exit 1; }
W="$SUP/hermes/cache/scratch/choices-check-$$"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/plugins/one-phone-tags"
cp tools/overlay/plugins/one-phone-tags/__init__.py tools/overlay/plugins/one-phone-tags/plugin.yaml "$W/home/plugins/one-phone-tags/"
cp tools/phone-choices-engine-check.py "$W/check.py"
# What Messenger.sync turns on (Sources/Messenger.swift).
printf 'plugins:\n  enabled:\n    - one-phone-tags\n' > "$W/home/config.yaml"
printf 'TELEGRAM_BOT_TOKEN=123:stand-in\nTELEGRAM_ALLOWED_USERS=42\n' > "$W/home/.env"
cd "$E" && HERMES_HOME="$W/home" HERMES_RUNTIME_DIR="$SUP/hermes/tools" "$PY" -I "$W/check.py" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
