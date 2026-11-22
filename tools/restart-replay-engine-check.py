"""The real engine, with One's restart-replay plugin: a person's turn cut by a restart is never "will not be run again".

Run by tools/restart-replay-engine-check.sh with the engine's own python, cwd = the engine, HERMES_HOME = a scratch
home with the plugin installed and turned on the way RestartReplayPlugin.sync does it. Uses the engine's real pieces:
``owner_stop_notice`` and the interrupt reasons its shutdown records, ``_publish_completion`` (the live stream) and the
call-time lookup ``finish_result`` makes (the conversation), plugin discovery and the Telegram handler wiring, the
shutdown notices, MessageEvent / SessionSource. Only the bot is a stand-in (it records what it would send).

First the engine alone, the way it was Nov 10-22: the cut turn's words say "will not be run again" and nothing is kept.
Then with the plugin: One's line, the phone message kept on disk and sent again exactly once when Telegram is back.
"""

import asyncio
import inspect
import json
import os
import sqlite3
import sys
import time
import types

sys.path.insert(0, ".")
from hermes_cli import plugins as P  # noqa: E402
import gateway.session_settlement_recovery as ssr  # noqa: E402
import gateway.session_results as sres  # noqa: E402
from gateway.run import _INTERRUPT_REASON_GATEWAY_SHUTDOWN, _INTERRUPT_REASON_GATEWAY_RESTART  # noqa: E402
from gateway.run_shutdown import GatewayShutdownMixin  # noqa: E402

fails = 0
HOME = os.environ["HERMES_HOME"]
KEPT = os.path.join(HOME, "one-replay")


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


def row(text, aid, chat="42", platform="telegram", principal=None):
    """A person's admission the way the engine stores it (session_admissions.payload_json, Nov 11 19:04)."""
    src = {"chat_id": chat, "chat_name": "Omar", "chat_type": "dm", "is_bot": False, "message_id": "1123",
           "platform": platform, "thread_id": None, "user_id": chat, "user_name": "Omar"}
    return {"admission_id": aid, "target_session_id": "20261111_tg_" + chat, "principal_id": principal or
            f"messaging:[null,\"{platform}\",\"{chat}\",null,\"{chat}\"]", "generation": 1,
            "payload": {"text": text, "native_text_v1": {"event": {"message_id": "1123"}, "route":
                        f"agent:main:{platform}:dm:{chat}", "source": src, "timestamp": "2026-11-12T00:04:11+00:00"}}}


CUT = {"result": {"interrupt_message": _INTERRUPT_REASON_GATEWAY_SHUTDOWN, "final_response": ""}}
RESTARTING = {"result": {"interrupt_message": _INTERRUPT_REASON_GATEWAY_RESTART, "final_response": ""}}


def kept():
    return sorted(f for f in os.listdir(KEPT) if f.endswith(".json")) if os.path.isdir(KEPT) else []


print("1. The engine alone (how it was Nov 10-22)")
before = ssr.owner_stop_notice(CUT, "interrupted", row("Yes go ahead", "a1"))
print("   the engine says: " + str(before))
check("a person's turn cut by the shutdown says it 'will not be run again'", "will not be run again" in (before or ""))
check("and nothing keeps it for later", kept() == [])
check("both callers look the notice up on its module at call time (so the plugin's words reach both)",
      "from gateway.session_settlement_recovery import gateway_refusal_boundary, owner_stop_notice"
      in inspect.getsource(sres.finish_result) and "owner_stop_notice(" in inspect.getsource(ssr._publish_completion))

print("2. With One's plugin")
P.discover_plugins(force=True)
check("the engine loads the plugin", P.has_hook("transform_llm_output") and getattr(
    ssr.owner_stop_notice, "_one_restart_replay", False))
factories = P.get_plugin_manager().get_platform_handler_factories("telegram")
check("and its Telegram wiring", any(name == "one-restart-replay" for _f, name in factories))
mod = next(m for k, m in sys.modules.items() if k.endswith("one_restart_replay") or k.endswith("one-restart-replay"))

said = ssr.owner_stop_notice(CUT, "interrupted", row("Yes go ahead", "a2"))
again = ssr.owner_stop_notice(CUT, "interrupted", row("Yes go ahead", "a2"))  # finish_result and the stream both ask
check(f"the cut turn says One's line ({said!r})", said == mod.LINE == again)
check("never 'will not be run again' or 'send your message again'",
      "will not be run again" not in said and "send" not in said.lower())
check("a restart (not a shutdown) too", ssr.owner_stop_notice(RESTARTING, "interrupted", row("Book it", "a3")) == mod.LINE)
check("the phone message is on disk once per turn", kept() == ["a2.json", "a3.json"])
os.unlink(os.path.join(KEPT, "a3.json"))
e = json.load(open(os.path.join(KEPT, "a2.json")))
check("with the chat, the words and the conversation", e["chat"] == "42" and e["text"] == "Yes go ahead"
      and e["session"] == "20261111_tg_42" and e["tries"] == 0)
local = row("Fix the build", "a4", platform="local")
check("One's own chat (ACP) gets the line too, and isn't kept here (One's app picks it up)",
      ssr.owner_stop_notice(CUT, "interrupted", local) == mod.LINE and "a4.json" not in kept())
from hermes_state_keys import CRON_PRINCIPAL_ID  # noqa: E402
cron = row("Nightly room router", "a5", principal=CRON_PRINCIPAL_ID)
check("a routine keeps the engine's own automation words",
      ssr.owner_stop_notice(CUT, "interrupted", cron) != mod.LINE and "a5.json" not in kept())
check("a turn that finished is untouched", ssr.owner_stop_notice({"result": {}}, "completed", row("x", "a6")) is None)


class Live:  # what _publish_completion is handed: the session's controls and its event stream
    def __init__(self):
        self.controls = types.SimpleNamespace(snapshot=lambda *a: None)
        self.published = []
        self.event_stream = types.SimpleNamespace(publish=lambda sid, frame, **k: self.published.append(frame))


live = Live()
try:
    ssr._publish_completion(None, live, types.SimpleNamespace(session_id="20261111_tg_42"), row("Yes go ahead", "a2"),
                            {"outcome": "interrupted", "status": "terminal"}, "", CUT)
    frame = json.dumps(live.published)
    check("the live stream's warning is One's line", mod.LINE in frame and "will not be run again" not in frame)
except Exception as ex:  # the frame's shape changed: say so instead of passing
    check(f"the live stream's warning is One's line ({ex!r})", False)


class Bot:
    def __init__(self):
        self.got, self.sent = [], []

    async def handle_message(self, ev):
        self.got.append(ev)

    async def send(self, chat_id, content, **_):
        self.sent.append((chat_id, content))
        return types.SimpleNamespace(success=True)


async def main():
    print("3. Telegram is back after the restart")
    bot = Bot()
    out = await mod.replay(bot, "telegram", settle=0)
    check(f"the cut message goes again ({out})", out == [("send", "Yes go ahead")] and len(bot.got) == 1)
    ev = bot.got[0] if bot.got else None
    check("as the person's message from that chat", ev is not None and ev.source.chat_id == "42"
          and ev.source.user_id == "42" and str(getattr(ev.source.platform, "value", ev.source.platform)) == "telegram")
    check("with its own words first and a note that it's a pick-up",
          ev is not None and ev.text.startswith("Yes go ahead\n\n(One app note") and "[restart pick-up 1]" in ev.text
          and "don't ask them to send it again" in ev.text)
    check("its file is gone", kept() == [])
    bot2 = Bot()
    check("the next start sends nothing again (exactly once)", await mod.replay(bot2, "telegram", settle=0) == []
          and bot2.got == [])

    print("4. The pick-up is cut again, and again")
    ssr.owner_stop_notice(CUT, "interrupted", row(bot.got[0].text, "b1"))
    e1 = json.load(open(os.path.join(KEPT, "b1.json")))
    check("kept with its own words and one pick-up so far", e1["text"] == "Yes go ahead" and e1["tries"] == 1)
    bot3 = Bot()
    await mod.replay(bot3, "telegram", settle=0)
    check("sent once more (pick-up 2)", len(bot3.got) == 1 and "[restart pick-up 2]" in bot3.got[0].text
          and bot3.got[0].text.count("(One app note") == 1)
    ssr.owner_stop_notice(CUT, "interrupted", row(bot3.got[0].text, "b2"))
    bot4 = Bot()
    out = await mod.replay(bot4, "telegram", settle=0)
    check("a third cut: not sent again, one plain line instead", out == [("gave-up", "Yes go ahead")] and bot4.got == []
          and len(bot4.sent) == 1 and "go on" in bot4.sent[0][1] and "will not be run" not in bot4.sent[0][1])

    print("5. Not sent again when it's stale or the chat moved on")
    ssr.owner_stop_notice(CUT, "interrupted", row("What's on today?", "c1"))
    p = os.path.join(KEPT, "c1.json")
    e = json.load(open(p))
    e["at"] = time.time() - 3 * 3600
    json.dump(e, open(p, "w"))
    bot5 = Bot()
    check("older than 2 hours: left alone", await mod.replay(bot5, "telegram", settle=0) == [("stale", "What's on today?")]
          and bot5.got == [])
    ssr.owner_stop_notice(CUT, "interrupted", row("Draft the reply", "c2"))
    db = sqlite3.connect(os.path.join(HOME, "state.db"))
    db.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, "
               "timestamp REAL)")
    db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
               ("20261111_tg_42", "user", "[IMPORTANT: Background process proc_1 completed]", time.time() + 5))
    db.commit()
    bot6 = Bot()
    out = await mod.replay(bot6, "telegram", settle=0)
    check("an engine wake-up after the cut doesn't count as moving on", out == [("send", "Draft the reply")])
    ssr.owner_stop_notice(CUT, "interrupted", row("Draft the reply", "c3"))
    db.execute("INSERT INTO messages (session_id, role, content, timestamp) VALUES (?,?,?,?)",
               ("20261111_tg_42", "user", "Actually, skip it", time.time() + 5))
    db.commit()
    bot7 = Bot()
    check("they wrote again after the cut: left alone", await mod.replay(bot7, "telegram", settle=0) ==
          [("moved", "Draft the reply")] and bot7.got == [])

    print("6. What the phone hears while One restarts")

    class Runner(GatewayShutdownMixin):
        pass

    r = object.__new__(Runner)
    bot8 = Bot()
    await r._send_shutdown_notice(bot8, "42", "⚠️ Hermes is shutting down — send any message", "active chat", "telegram")
    check(f"the chat that was cut: plain words ({bot8.sent})", len(bot8.sent) == 1 and bot8.sent[0][1] == mod.ACTIVE_NOTICE)
    ok = await r._send_shutdown_notice(bot8, "42", "⚠️ Hermes is shutting down", "home channel", "telegram")
    check("the home channel: nothing (nothing of theirs was cut there)", ok is True and len(bot8.sent) == 1)
    check("a Stop's 'Operation interrupted' is left alone",
          mod.transform_llm_output("Operation interrupted: waiting for model response (2.2s elapsed).", platform="telegram")
          is None)
    mod._stopping = True
    check("the restart's becomes One's line on the phone",
          mod.transform_llm_output("Operation interrupted: waiting for model response (2.2s elapsed).", platform="telegram")
          == mod.LINE)
    check("and One's own chat keeps it (One's app reads it as a cut-off)",
          mod.transform_llm_output("Operation interrupted: waiting for model response.", platform="local") is None)


asyncio.run(main())
print("engine restart-replay ok" if fails == 0 else f"engine restart-replay: {fails} failed")
sys.exit(1 if fails else 0)
