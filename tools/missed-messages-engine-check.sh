#!/bin/bash
. "$(dirname "$0")/ci-only.sh"  # tests run in CI only, never on the person's Mac
# Proves the REAL engine loads One's missed-messages plugin and runs it through the gateway's own
# `pre_gateway_dispatch` step (GatewayInboundHooksMixin._hm_pre_gateway_dispatch_hook) on real MessageEvents,
# and that the Telegram setting One writes keeps queued messages (drop_pending_on_cold_boot: false), in a scratch home.
# The engine to use: ONE_SUPPORT_DIR's (the fresh-install workflow installs one there).
#   ONE_SUPPORT_DIR=<folder with engine/> tools/missed-messages-engine-check.sh    prints "engine missed ok" when it passes
set -u
cd "$(dirname "$0")/.."
SUP="${ONE_SUPPORT_DIR:-$HOME/Library/Application Support/One}"
E="$SUP/engine"
[ -d "$E/hermes_cli" ] || { echo "no engine in $SUP; skipped"; exit 0; }
PY=""
for p in "$SUP"/hermes/installs/*/environments/*/venv/bin/python; do
  (cd "$E" && "$p" -I -c "import sys; sys.path.insert(0,'.'); import hermes_cli.plugins, gateway.run_inbound_hooks" >/dev/null 2>&1) && { PY="$p"; break; }
done
[ -n "$PY" ] || { echo "engine python not found"; exit 1; }
W="$SUP/hermes/cache/scratch/missed-check-$$"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/plugins/one-missed-messages"
cp tools/overlay/plugins/one-missed-messages/__init__.py tools/overlay/plugins/one-missed-messages/plugin.yaml "$W/home/plugins/one-missed-messages/"
# What Messenger.missedFixes writes (Sources/Messenger.swift).
printf 'plugins:\n  enabled:\n    - one-missed-messages\nplatforms:\n  telegram:\n    extra:\n      drop_pending_on_cold_boot: false\n' > "$W/home/config.yaml"
printf 'TELEGRAM_BOT_TOKEN=123:stand-in\nTELEGRAM_ALLOWED_USERS=42\n' > "$W/home/.env"
cat > "$W/check.py" <<'EOF'
import asyncio, datetime as dt, sys
sys.path.insert(0, '.')
from hermes_cli import plugins as P
from gateway.config import load_gateway_config, Platform
from gateway.session import SessionSource
from gateway.platforms.event import MessageEvent
from gateway.run_inbound_hooks import GatewayInboundHooksMixin
P.discover_plugins(force=True)
fails = 0
def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1
tg = load_gateway_config().platforms.get(Platform.TELEGRAM)
check("Telegram stays on and keeps what was sent while One was off", bool(tg and tg.enabled) and tg.extra.get("drop_pending_on_cold_boot") is False)
check("the engine loads the plugin's hook", P.has_hook("pre_gateway_dispatch"))
class Adapter:
    sent = []
    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append(content)
class Runner(GatewayInboundHooksMixin):
    adapters = {Platform.TELEGRAM: Adapter()}
    def _is_user_authorized(self, source, **_):
        return source.user_id == "42"
r = Runner()
src = SessionSource(platform=Platform.TELEGRAM, chat_id="42", user_id="42")
now = dt.datetime.now(dt.timezone.utc)
async def main():
    fresh = await r._hm_pre_gateway_dispatch_hook(MessageEvent(text="what's on today?", source=src, timestamp=now - dt.timedelta(minutes=40)), src)
    check("a message from 40 minutes ago goes on to the assistant", fresh is not None and fresh.text == "what's on today?")
    old = await r._hm_pre_gateway_dispatch_hook(MessageEvent(text="book the table", source=src, timestamp=now - dt.timedelta(hours=6)), src)
    check("one from 6 hours ago is not acted on", old is None)
    await asyncio.sleep(4)
    sent = Adapter.sent
    check("one note lists it and asks", len(sent) == 1 and "While I was offline you sent:" in sent[0] and "book the table" in sent[0])
    nxt = await r._hm_pre_gateway_dispatch_hook(MessageEvent(text="yes do it", source=src, timestamp=dt.datetime.now(dt.timezone.utc)), src)
    check("their next message carries the list", nxt is not None and "book the table" in nxt.text and nxt.text.endswith("yes do it"))
asyncio.run(main())
print("engine missed ok" if fails == 0 else f"engine missed: {fails} failed")
sys.exit(1 if fails else 0)
EOF
cd "$E" && HERMES_HOME="$W/home" HERMES_RUNTIME_DIR="$SUP/hermes/tools" "$PY" -I "$W/check.py" 2>&1 | grep -v -E "^(→|  ✓ Installing)"
exit "${PIPESTATUS[0]}"
