#!/usr/bin/python3
"""One's restart-replay engine plugin on stand-in engine modules (no engine needed; every pull request, in preflight).

A person's turn the engine's restart cut is never told it "will not be run again": the plugin swaps the engine's words for
One's line, keeps a phone-chat message on disk and sends it again exactly once when Telegram is back (a second cut once
more, a third: one plain line), leaves stale or moved-on ones alone, and turns the shutdown notices into plain words.
The same plugin against the REAL engine: tools/restart-replay-engine-check.sh (fresh-install workflow).
"""

import asyncio
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import time
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


home = tempfile.mkdtemp(prefix="restart-replay-")
os.environ["HERMES_HOME"] = home
SHUT = ("Gateway shutting down: this turn was interrupted and will not be run again. "
        "Send your message again once Hermes is back.")
REST = ("Gateway restarting: this turn was interrupted and will not be run again. "
        "Send your message again once Hermes reconnects.")


# --- stand-ins for the engine modules the plugin touches (same names and shapes as engine v0.22.5) ---
def module(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    sys.modules[name] = m
    return m


def owner_stop_notice(captured, outcome, row=None):  # gateway/session_settlement_recovery.py, cut down
    cause = ((captured or {}).get("result") or {}).get("interrupt_message") if outcome == "interrupted" else None
    notice = {"Gateway restarting": REST, "Gateway shutting down": SHUT}.get(cause)
    if notice and row and (row.get("principal_id") == "cron-owner"):
        return "An automated delivery was interrupted and was not run again."
    return notice


class Mixin:  # gateway/run_shutdown.py GatewayShutdownMixin, cut down
    async def _send_shutdown_notice(self, adapter, chat_id, msg, kind, platform_str, **kw):
        await adapter.send(chat_id, msg)
        return True

    async def _notify_active_sessions_of_shutdown(self):
        return None


class MessageEvent:
    def __init__(self, text="", message_type=None, source=None, **_):
        self.text, self.message_type, self.source = text, message_type, source


class SessionSource:
    def __init__(self, **kw):
        self.__dict__.update(kw)

    @classmethod
    def from_dict(cls, d):
        return cls(**d)


module("gateway")
module("gateway.session_settlement_recovery", owner_stop_notice=owner_stop_notice, RESTART_INTERRUPT_NOTICE=REST,
       SHUTDOWN_INTERRUPT_NOTICE=SHUT)
module("gateway.run_shutdown", GatewayShutdownMixin=Mixin)
module("gateway.platforms")
module("gateway.platforms.event", MessageEvent=MessageEvent, MessageType=types.SimpleNamespace(TEXT="text"))
module("gateway.session", SessionSource=SessionSource)
import gateway.session_settlement_recovery as ssr  # noqa: E402

spec = importlib.util.spec_from_file_location("one_restart_replay", HERE / "overlay/plugins/one-restart-replay/__init__.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class Ctx:
    hooks, telegram = {}, []

    def register_hook(self, name, fn):
        self.hooks[name] = fn

    def register_telegram_handler(self, fn):
        self.telegram.append(fn)


ctx = Ctx()
mod.register(ctx)
KEPT = Path(home) / "one-replay"
CUT = {"result": {"interrupt_message": "Gateway shutting down"}}


def row(text, aid, platform="telegram", principal="messaging:[null,\"telegram\",\"42\",null,\"42\"]"):
    src = {"chat_id": "42", "chat_type": "dm", "message_id": "1123", "platform": platform, "thread_id": None,
           "user_id": "42", "user_name": "Omar"}
    return {"admission_id": aid, "target_session_id": "tg-42", "principal_id": principal,
            "payload": {"text": text, "native_text_v1": {"source": src, "route": "agent:main:telegram:dm:42"}}}


def kept():
    return sorted(p.name for p in KEPT.glob("*.json")) if KEPT.is_dir() else []


class Bot:
    def __init__(self):
        self.got, self.sent = [], []

    async def handle_message(self, ev):
        self.got.append(ev)

    async def send(self, chat_id, content, **_):
        self.sent.append((chat_id, content))


print("1. The engine's words for a turn its restart cut")
check("the plugin wraps the engine's notice and wires Telegram", getattr(ssr.owner_stop_notice, "_one_restart_replay", False)
      and ctx.telegram == [mod.wire] and "transform_llm_output" in ctx.hooks)
said = ssr.owner_stop_notice(CUT, "interrupted", row("Yes go ahead", "a1"))
ssr.owner_stop_notice(CUT, "interrupted", row("Yes go ahead", "a1"))  # both callers ask
check(f"One's line, never 'will not be run again' ({said!r})", said == "One restarted; picking this back up.")
check("a restart's words too", ssr.owner_stop_notice({"result": {"interrupt_message": "Gateway restarting"}}, "interrupted",
                                                     row("x", "a2")) == mod.LINE)
check("the phone message kept once per turn", kept() == ["a1.json", "a2.json"])
(KEPT / "a2.json").unlink()
check("One's own chat: the line, not kept (One's app picks it up)",
      ssr.owner_stop_notice(CUT, "interrupted", row("Fix it", "a3", platform="local")) == mod.LINE and "a3.json" not in kept())
check("a routine: the engine's own automation words, not kept",
      "automated" in ssr.owner_stop_notice(CUT, "interrupted", row("r", "a4", principal="cron-owner")) and "a4.json" not in kept())
check("a finished turn: untouched", ssr.owner_stop_notice({"result": {}}, "completed", row("y", "a5")) is None)
mode = oct(os.stat(KEPT / "a1.json").st_mode & 0o777)
check(f"written whole (no temp file left behind; {mode})", not list(KEPT.glob("*.tmp")))


async def main():
    print("2. Telegram is back")
    b = Bot()
    out = await mod.replay(b, "telegram", settle=0)
    check(f"sent again once ({out})", out == [("send", "Yes go ahead")] and len(b.got) == 1)
    check("from that chat, with its words first and the pick-up note", b.got and b.got[0].source.chat_id == "42"
          and b.got[0].source.message_id is None and b.got[0].text.startswith("Yes go ahead\n\n(One app note")
          and "[restart pick-up 1]" in b.got[0].text)
    b2 = Bot()
    check("the next start sends nothing (exactly once)", await mod.replay(b2, "telegram", settle=0) == [] and not b2.got)
    print("3. Cut again, and again")
    ssr.owner_stop_notice(CUT, "interrupted", row(b.got[0].text, "b1"))
    check("kept with its own words, one pick-up so far",
          json.loads((KEPT / "b1.json").read_text())["text"] == "Yes go ahead" and json.loads((KEPT / "b1.json").read_text())["tries"] == 1)
    b3 = Bot()
    await mod.replay(b3, "telegram", settle=0)
    check("sent once more", len(b3.got) == 1 and "[restart pick-up 2]" in b3.got[0].text and b3.got[0].text.count("(One app note") == 1)
    ssr.owner_stop_notice(CUT, "interrupted", row(b3.got[0].text, "b2"))
    b4 = Bot()
    out = await mod.replay(b4, "telegram", settle=0)
    check("a third cut: one plain line, not sent", out == [("gave-up", "Yes go ahead")] and not b4.got and len(b4.sent) == 1
          and "go on" in b4.sent[0][1])
    print("4. Stale, or the chat moved on")
    ssr.owner_stop_notice(CUT, "interrupted", row("What's on today?", "c1"))
    e = json.loads((KEPT / "c1.json").read_text())
    e["at"] = time.time() - 3 * 3600
    (KEPT / "c1.json").write_text(json.dumps(e))
    check("older than 2 hours: left alone", await mod.replay(Bot(), "telegram", settle=0) == [("stale", "What's on today?")])
    db = sqlite3.connect(os.path.join(home, "state.db"))
    db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, timestamp REAL)")
    ssr.owner_stop_notice(CUT, "interrupted", row("Draft it", "c2"))
    db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES ('tg-42','user','[IMPORTANT: done]',?)",
               (time.time() + 5,))
    db.commit()
    check("an engine wake-up isn't moving on", await mod.replay(Bot(), "telegram", settle=0) == [("send", "Draft it")])
    ssr.owner_stop_notice(CUT, "interrupted", row("Draft it", "c3"))
    db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES ('tg-42','user','skip it',?)",
               (time.time() + 5,))
    db.commit()
    check("they wrote again: left alone", await mod.replay(Bot(), "telegram", settle=0) == [("moved", "Draft it")])
    print("5. What the phone hears")
    r, b5 = mod.install_shutdown_notices() and Mixin(), Bot()
    await r._send_shutdown_notice(b5, "42", "⚠️ Hermes is shutting down — send any message", "active chat", "telegram")
    check("the cut chat: plain words", b5.sent == [("42", mod.ACTIVE_NOTICE)])
    check("the home channel: nothing", await r._send_shutdown_notice(b5, "42", "x", "home channel", "telegram") is True
          and len(b5.sent) == 1)
    op = "Operation interrupted: waiting for model response (2.2s elapsed)."
    check("a Stop's interrupt words left alone", mod.transform_llm_output(op, platform="telegram") is None)
    await r._notify_active_sessions_of_shutdown()
    check("the restart's: One's line on the phone", mod.transform_llm_output(op, platform="telegram") == mod.LINE)
    check("One's own chat keeps them", mod.transform_llm_output(op, platform="local") is None)


asyncio.run(main())
print("restart-replay plugin ok" if fails == 0 else f"restart-replay plugin: {fails} failed")
sys.exit(1 if fails else 0)
