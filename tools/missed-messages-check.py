"""Checks One's missed-messages plugin (tools/overlay/plugins/one-missed-messages) on made-up phone messages.

Plain python, no engine: the hook is called the way the gateway calls it (`pre_gateway_dispatch(event=…, gateway=…)`)
with stand-in events, a stand-in gateway (who's allowed, a chat adapter that records what it sends) and a scratch
HERMES_HOME. Proves: a message from the last 2 hours goes through as usual; older ones are skipped and listed in ONE
note ("While I was offline you sent: … Want me to do any of these?"); the next new message carries that list; a
stranger's old message is left to the gateway's own checks; nothing fires for the Mac app's own turns.
"""

import asyncio
import datetime as dt
import importlib.util
import os
import sys
import tempfile
import time
from enum import Enum
from pathlib import Path
from types import SimpleNamespace

os.environ["TZ"] = "America/New_York"  # the times in the note are the Mac's local time; pin it for CI runners (UTC)
time.tzset()
HERE = Path(__file__).resolve().parent / "overlay" / "plugins" / "one-missed-messages" / "__init__.py"
home = tempfile.mkdtemp(prefix="one-missed-")
os.environ["HERMES_HOME"] = home
spec = importlib.util.spec_from_file_location("one_missed", HERE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.SETTLE = 0.2

fails = 0


def check(name, ok):
    global fails
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        fails += 1


class Platform(Enum):
    TELEGRAM = "telegram"
    LOCAL = "local"


class Adapter:
    def __init__(self):
        self.sent = []

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append((chat_id, content))


NOW = dt.datetime(2026, 11, 7, 16, 1, tzinfo=dt.timezone.utc)  # 11:01 AM in New York, when the bot came back
os.environ["ONE_MISSED_NOW"] = str(NOW.timestamp())
tg = Adapter()
gateway = SimpleNamespace(adapters={Platform.TELEGRAM: tg}, _is_user_authorized=lambda src: src.user_id == "omar")


class Kind(Enum):
    TEXT = "text"
    VOICE = "voice"


def msg(text, ago, user="omar", chat="8628960251", platform=Platform.TELEGRAM, kind=Kind.TEXT, internal=False):
    return SimpleNamespace(
        text=text, message_type=kind, internal=internal, timestamp=NOW - ago,
        source=SimpleNamespace(platform=platform, chat_id=chat, user_id=user))


async def call(e):
    return await m.pre_gateway_dispatch(event=e, gateway=gateway, session_store=None)


async def main():
    print("1. back after 18 hours: what was sent while off")
    old1 = await call(msg("Book the 7pm table at Nonna's for Saturday", dt.timedelta(hours=20, minutes=50)))
    old2 = await call(msg("", dt.timedelta(hours=9), kind=Kind.VOICE))
    old3 = await call(msg("Post the new photo to X", dt.timedelta(hours=3)))
    recent = await call(msg("What's on my calendar today?", dt.timedelta(minutes=50)))
    check("a message from 50 minutes ago is answered as usual (passes through untouched)", recent is None)
    check("messages 3, 9 and 21 hours old are not acted on (skipped)", all(r and r.get("action") == "skip" for r in (old1, old2, old3)))
    check("nothing is sent before the burst settles", tg.sent == [])
    await asyncio.sleep(0.6)
    check("exactly ONE note goes to that chat", len(tg.sent) == 1 and tg.sent[0][0] == "8628960251")
    note = tg.sent[0][1] if tg.sent else ""
    check("it starts \"While I was offline you sent:\" and asks which are still wanted",
          note.startswith("While I was offline you sent:") and "Want me to do any of these?" in note)
    check("it lists all three, oldest first, with their times",
          note.find("Nonna") < note.find("a voice message") < note.find("Post the new photo") and note.count("\u2022") == 3
          and "Fri 2:11 PM" in note)
    check("it says nothing was done", "haven't acted on them" in note)
    print(note.replace("\n", "\n      "))

    print("2. their next message")
    global NOW  # they read the note and answer three minutes later
    NOW = NOW + dt.timedelta(minutes=3)
    os.environ["ONE_MISSED_NOW"] = str(NOW.timestamp())
    before = await call(msg("thanks", dt.timedelta(minutes=33)))
    check("a message written before the note isn't given the list", before is None)
    cmd = await call(msg("/status", dt.timedelta(seconds=5)))
    check("a command isn't rewritten and the list waits", cmd is None and (Path(home) / "one-missed").exists())
    nxt = await call(msg("Yes, book the table", dt.timedelta(seconds=10)))
    t = (nxt or {}).get("text", "")
    check("the next new message carries the list as context, then their words",
          (nxt or {}).get("action") == "rewrite" and "Nonna" in t and t.endswith("Yes, book the table"))
    check("and the context says sends, posts, spends and deletes still need a clear yes",
          "sends, posts, spends money or deletes still needs their clear yes" in t)
    again = await call(msg("and one more thing", dt.timedelta(seconds=3)))
    check("only once: the message after that is untouched", again is None)

    print("3. what it leaves alone")
    tg.sent.clear()
    stranger = await call(msg("hello?", dt.timedelta(hours=5), user="someone-else"))
    check("a stranger's old message is left to the gateway's own checks", stranger is None)
    app_turn = await call(msg("old local turn", dt.timedelta(hours=5), platform=Platform.LOCAL))
    check("the Mac app's own turns are never touched", app_turn is None)
    internal = await call(msg("internal", dt.timedelta(hours=5), internal=True))
    check("the engine's own internal events are never touched", internal is None)
    edge = await call(msg("just under two hours", dt.timedelta(hours=1, minutes=59)))
    check("1 h 59 min old still counts as recent", edge is None)
    await asyncio.sleep(0.5)
    check("no note for any of those", tg.sent == [])

    print("4. many at once")
    for k in range(14):
        await call(msg(f"old {k}", dt.timedelta(hours=4, minutes=k)))
    await asyncio.sleep(0.6)
    n = tg.sent[-1][1] if tg.sent else ""
    check("14 old messages: one note, 10 listed and \"and 4 more\"", len(tg.sent) == 1 and n.count("\u2022") == 11 and "and 4 more" in n)
    log = (Path(home) / "logs" / "one-missed-messages.log").read_text()
    check("each note is logged", log.count("not acted on") == 2)

    print("5. a code a helper waits on, sent back from the phone")
    import json as _json
    hd = Path(home) / "handoff"  # its own folder: never a stale answer from an earlier run
    os.environ["ONE_HANDOFF_DIR"] = str(hd)
    hd.mkdir(parents=True, exist_ok=True)
    (hd / "ab12.request.json").write_text(_json.dumps({"id": "ab12", "site": "docusign.com", "kind": "code"}))
    tg.sent.clear()
    chat_words = await call(msg("What's the weather?", dt.timedelta(seconds=4)))
    check("before One asks, a code-looking reply is just a message", await call(msg("482913", dt.timedelta(seconds=3))) is None
          and chat_words is None)
    (hd / "ab12.phone.json").write_text(_json.dumps({"id": "ab12", "chat": "8628960251", "at": NOW.timestamp()}))
    words = await call(msg("What's the weather?", dt.timedelta(seconds=4)))
    said = _json.loads((hd / "ab12.answer.json").read_text()) if (hd / "ab12.answer.json").exists() else {}
    check("while a helper waits on a code, any other reply goes to that helper as their message (Nov 11 2026)",
          (words or {}).get("action") == "skip" and said.get("answer") == "message" and said.get("text") == "What's the weather?")
    (hd / "ab12.answer.json").unlink(missing_ok=True)  # One asks again (a new code step)
    tg.sent.clear()
    other = await call(msg("482 913", dt.timedelta(seconds=3), chat="999"))
    check("a code from another chat is not taken", other is None and not (hd / "ab12.answer.json").exists())
    got = await call(msg("482 913", dt.timedelta(seconds=3)))
    ans = _json.loads((hd / "ab12.answer.json").read_text()) if (hd / "ab12.answer.json").exists() else {}
    check("their reply is the code: it goes to the step's answer, never to the assistant",
          (got or {}).get("action") == "skip" and ans.get("answer") == "code" and ans.get("code") == "482913" and ans.get("by") == "phone")
    check("they're told it's going in", tg.sent and tg.sent[-1][1] == "Got it. Typing it into docusign.com now.")
    log = (Path(home) / "logs" / "one-missed-messages.log").read_text()
    check("the log never holds the code", "482913" not in log and "482 913" not in log)
    late = await call(msg("123456", dt.timedelta(seconds=2)))
    check("once answered, the next code-looking message is just a message", late is None)
    check("\"code is 77-31-90\" and \"G-123456\" read right (Google's G- is shown beside its box, never typed)", m.clean_code("code is 77-31-90") == "773190" and m.clean_code("G-123456") == "123456"
          and m.clean_code("call me at 5pm please") == "")


asyncio.run(main())
print("missed messages ok" if fails == 0 else f"missed messages FAILED ({fails})")
sys.exit(1 if fails else 0)
