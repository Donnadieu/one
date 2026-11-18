"""Checks the Telegram buttons in One's phone-tags plugin (tools/overlay/plugins/one-phone-tags): a reply's last-line
[choices: …] becomes tap buttons there, and a tap is the same as typing that answer.

Plain python, no engine: stand-ins for the Telegram library, the gateway's message type and the Telegram adapter
(its post-delivery slot, active turns, sends and button-tap gate), driven the way the engine drives them (the turn
ends in a worker thread, the reply is delivered on the gateway's loop, then the slot fires). Proves: the cut is One's
own (tests/fixtures/phone-tags/choices.json, also checked against Choices.split in `One --test-helpers`); the line
comes off and up to 4 buttons land under the reply; a tap sends that answer from that chat once; old buttons stop
working when newer ones come or the person types; nobody else can tap; other chats and One's own chat are untouched;
when the buttons can't be tied to the turn or sent, the choices still reach the person as text.
The real engine's own pieces are checked by tools/phone-choices-engine-check.sh (fresh-install workflow).
"""

import asyncio
import dataclasses
import importlib.util
import json
import os
import sys
import tempfile
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "tools" / "overlay" / "plugins" / "one-phone-tags" / "__init__.py"
FIX = ROOT / "tests" / "fixtures" / "phone-tags"
os.environ["HERMES_HOME"] = tempfile.mkdtemp(prefix="one-phone-choices-")
for k in [k for k in os.environ if k.startswith("HERMES_SESSION_")]:
    del os.environ[k]


# Stand-ins: the Telegram library and the gateway's message type.
class CallbackQueryHandler:
    def __init__(self, callback, pattern=None):
        import re

        self.callback, self.pattern = callback, re.compile(pattern)


class MessageEvent:
    def __init__(self, text, message_type=None, source=None, metadata=None):
        self.text, self.source, self.metadata, self.internal = text, source, metadata or {}, False


sys.modules["telegram"] = types.ModuleType("telegram")  # no keyboard classes here: the plugin sends plain rows
ext = types.ModuleType("telegram.ext")
ext.CallbackQueryHandler = CallbackQueryHandler
sys.modules["telegram.ext"] = ext
ev_mod = types.ModuleType("gateway.platforms.event")
ev_mod.MessageEvent = MessageEvent
ev_mod.MessageType = types.SimpleNamespace(TEXT="text")
for name in ("gateway", "gateway.platforms"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["gateway.platforms.event"] = ev_mod

spec = importlib.util.spec_from_file_location("one_phone_tags", HERE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

fails = 0


def check(name, ok):
    global fails
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        fails += 1


print("1. the cut is One's own (Choices.split)")
for c in json.loads((FIX / "choices.json").read_text()):
    got = m.split_choices(c["reply"])
    check(f"{c['name']}", got == (c["body"], c["choices"]))


@dataclasses.dataclass
class Source:
    """Like the engine's SessionSource (a dataclass: the plugin copies it with dataclasses.replace)."""
    chat_id: str = "42"
    user_id: str = "42"
    thread_id: object = None
    platform: str = "telegram"
    user_name: str = "Omar"
    message_id: object = "7"


class Msg:
    def __init__(self, mid):
        self.message_id = mid


class Bot:
    def __init__(self):
        self.edits = []

    async def edit_message_text(self, **kw):
        self.edits.append(("text", kw))

    async def edit_message_reply_markup(self, **kw):
        self.edits.append(("markup", kw))


class Adapter:
    """The parts of the engine's Telegram adapter the plugin uses."""

    def __init__(self):
        self._bot, self._active_sessions, self._post_delivery_callbacks = Bot(), {}, {}
        self.sent, self.texts, self.dispatched, self.fail_send, self.n = [], [], [], False, 100

    def register_post_delivery_callback(self, key, cb, *, generation=None):
        self._post_delivery_callbacks[key] = cb if generation is None else (generation, cb)

    async def fire(self, key):
        entry = self._post_delivery_callbacks.pop(key, None)
        cb = entry[1] if isinstance(entry, tuple) else entry
        if cb:
            r = cb()
            if asyncio.iscoroutine(r):
                await r

    async def _send_control_message(self, chat_id, text, *, parse_mode, thread_id, metadata, reply_markup=None):
        if self.fail_send:
            raise RuntimeError("Telegram said no")
        self.n += 1
        self.sent.append({"chat": chat_id, "text": text, "markup": reply_markup, "thread": thread_id})
        return Msg(self.n)

    async def send(self, chat_id, content, metadata=None):
        self.texts.append(content)

    async def handle_message(self, ev):
        self.dispatched.append(ev)

    def _callback_ctx(self, q):
        return {}

    async def _callback_authorized(self, q, cb, denial):
        if str(q.from_user.id) == "42":
            return True
        await q.answer(text=denial)
        return False

    def build_source(self, **kw):
        return Source(chat_id=kw["chat_id"], user_id=kw.get("user_id"), thread_id=kw.get("thread_id"))


class Query:
    def __init__(self, data, uid="42"):
        self.data, self.from_user = data, types.SimpleNamespace(id=uid, first_name="Omar")
        self.answers, self.off = [], False

    async def answer(self, text=None):
        self.answers.append(text)

    async def edit_message_reply_markup(self, reply_markup=None):
        self.off = True


KEY = "agent:main:telegram:dm:42"
SESSION = {"HERMES_SESSION_KEY": KEY, "HERMES_SESSION_CHAT_ID": "42", "HERMES_SESSION_CHAT_TYPE": "dm",
           "HERMES_SESSION_USER_ID": "42", "HERMES_SESSION_USER_NAME": "Omar"}


def in_turn(fn, env=SESSION):
    """The turn's last step runs in the agent's worker thread with the turn's chat set."""
    os.environ.update(env)
    try:
        return fn()
    finally:
        for k in env:
            os.environ.pop(k, None)


def labels(sent):
    rows = sent["markup"]["inline_keyboard"]
    return [b["text"] for r in rows for b in r], [b["callback_data"] for r in rows for b in r]


async def deliver(ad, text, gen, platform="telegram", tid="t"):
    ad._active_sessions[KEY] = types.SimpleNamespace(_hermes_run_generation=gen)
    loop = asyncio.get_running_loop()
    out = await loop.run_in_executor(None, in_turn, lambda: m.transform_llm_output(
        response_text=text, session_id="tg-1", platform=platform, turn_id=tid))
    await asyncio.sleep(0.01)  # the gateway sends the reply...
    await ad.fire(KEY)  # ...then its after-reply slot fires
    ad._active_sessions.pop(KEY, None)
    return out


async def tap(handler, data, uid="42"):
    q = Query(data, uid)
    await handler.callback(types.SimpleNamespace(callback_query=q), None)
    return q


GW = types.SimpleNamespace(_is_user_authorized=lambda s: s.user_id == "42")


async def main():
    ad = Adapter()
    print("2. before Telegram connects, or in any other chat: nothing changes")
    q = "Want me to book it?\n[choices: Yes, go ahead | Not now]"
    check("Telegram not connected yet: the line stays as text", in_turn(lambda: m.transform_llm_output(
        response_text=q, session_id="s", platform="telegram")) is None)
    native = types.SimpleNamespace(handlers=[])
    native.add_handler = native.handlers.append
    m.wire(native, ad)
    h = native.handlers[0]
    check("its taps are its own (oc:), never the engine's picker (cp:)",
          bool(h.pattern.match("oc:abc:0")) and not h.pattern.match("cp:0"))
    for p in ("whatsapp", "signal", "acp", ""):
        check(f"{p or 'One own chat'}: left as it was", await deliver(ad, q, 1, platform=p) is None and not ad.sent)

    print("3. a Telegram reply ending in a choices line")
    await m.pre_gateway_dispatch(event=types.SimpleNamespace(source=Source(), internal=False, metadata={}), gateway=GW)
    out = await deliver(ad, q, 5)
    check("the person gets the reply without the line", out == "Want me to book it?")
    check("then one message with the buttons, in that chat", len(ad.sent) == 1 and ad.sent[0]["chat"] == "42")
    names, datas = labels(ad.sent[0])
    check("one button per choice, in order", names == ["Yes, go ahead", "Not now"])
    check("small enough for Telegram (64 bytes a button)", all(len(d.encode()) <= 64 for d in datas))

    print("4. tapping Not now is typing Not now")
    t = await tap(h, datas[1])
    ev = ad.dispatched[-1] if ad.dispatched else None
    check("the gateway gets 'Not now' from that chat, as their message",
          ev is not None and ev.text == "Not now" and ev.source.chat_id == "42" and ev.source.user_id == "42")
    check("not quoting their older message", ev is not None and ev.source.message_id is None)
    check("with no metadata (Nov 17-18: the engine refused the tap for it)", ev is not None and not ev.metadata)
    check("the buttons go; the message shows what was picked",
          ("text", {"chat_id": "42", "message_id": 101, "text": "✓ Not now", "reply_markup": None}) in ad._bot.edits)
    check("the tap is answered", t.answers == [None])
    await tap(h, datas[1])
    await tap(h, datas[0])
    check("tapping again (or the other one) sends nothing more", len(ad.dispatched) == 1)
    os.environ.update(SESSION)
    note = (m.pre_llm_call(platform="telegram") or {}).get("context", "")
    again = (m.pre_llm_call(platform="telegram") or {}).get("context", "")
    for k in SESSION:
        os.environ.pop(k, None)
    check("the next turn is told what the buttons were, once",
          "[choices: Yes, go ahead | Not now]" in note and "[choices:" not in again)

    print("5. several turns")
    await deliver(ad, "Which day?\n[choices: Monday | Tuesday]", 6)
    older = labels(ad.sent[-1])[1]
    await deliver(ad, "What time?\n[choices: 7 PM | 8 PM | 7 pm | 9 PM | 10 PM]", 7)
    names, newer = labels(ad.sent[-1])
    check("the same answer twice is one button; at most 4", names == ["7 PM", "8 PM", "9 PM"])
    check("newer buttons take the older ones away",
          ("markup", {"chat_id": "42", "message_id": 102, "reply_markup": None}) in ad._bot.edits)
    old = await tap(h, older[0])
    check("a tap on old buttons says so and sends nothing", len(ad.dispatched) == 1 and old.answers == [m.OLD])
    other = await tap(h, newer[0], uid="666")
    check("someone not allowed in can't tap", len(ad.dispatched) == 1 and other.answers == ["Not allowed."])
    await m.pre_gateway_dispatch(event=types.SimpleNamespace(source=Source(), internal=False, metadata={}), gateway=GW)
    late = await tap(h, newer[1])
    check("the person typed instead: the buttons stop working", len(ad.dispatched) == 1 and late.answers == [m.OLD])
    stranger = Source(user_id="666")
    await deliver(ad, "Sure?\n[choices: Yes | No]", 8)
    fresh = labels(ad.sent[-1])[1]
    await m.pre_gateway_dispatch(event=types.SimpleNamespace(source=stranger, internal=False, metadata={}), gateway=GW)
    await tap(h, fresh[0])
    check("a stranger's message in the chat doesn't take them away", len(ad.dispatched) == 2 and ad.dispatched[-1].text == "Yes")
    await tap(h, "oc:nothing:0")
    check("buttons from before a restart send nothing", len(ad.dispatched) == 2)

    print("6. with helper lines in the same reply")
    out = await deliver(ad, "On it.\n[helper: Hotels | find a hotel in Lisbon]\nWhich nights?\n[choices: This weekend | Next weekend]", 9)
    check("the helper line and the choices line both come off (a receipt in the line's place)",
          out == "On it.\nWhich nights?\n\n↳ Helper sent: Hotels")
    inbox = list((Path(os.environ["HERMES_HOME"]) / "one-phone" / "inbox").glob("*.json"))
    check("the helper still goes to One", len(inbox) == 1)
    check("and the buttons come", labels(ad.sent[-1])[0] == ["This weekend", "Next weekend"])

    print("7. when buttons can't be done, the choices still reach them")
    ad._post_delivery_callbacks[KEY] = (3, lambda: None)  # the engine's own slot, for a run we can't name
    ad._active_sessions[KEY] = types.SimpleNamespace()
    same = await asyncio.get_running_loop().run_in_executor(None, in_turn, lambda: m.transform_llm_output(
        response_text=q, session_id="tg-1", platform="telegram", turn_id="tx"))
    check("no run to tie them to: the line stays (the engine's own slot untouched)",
          same is None and ad._post_delivery_callbacks[KEY][0] == 3)
    ad._post_delivery_callbacks.clear()
    ad._active_sessions.clear()
    alone = await asyncio.get_running_loop().run_in_executor(None, in_turn, lambda: m.transform_llm_output(
        response_text=q, session_id="tg-1", platform="telegram", turn_id="ty"))
    check("not a live turn (a routine's message): the line stays", alone is None)
    ad.fail_send = True
    await deliver(ad, q, 10)
    check("Telegram refuses the buttons: the choices go as text", ad.texts[-1:] == ["Yes, go ahead / Not now"])
    ad.fail_send = False
    only = await deliver(ad, "[choices: Yes | No]", 11)
    check("a reply that was only the line still says something", only == m.PROMPT and labels(ad.sent[-1])[0] == ["Yes", "No"])

    print("8. Nov 18: a phone message is answered, never refused for how it was made; notices in plain words")
    si = types.ModuleType("gateway.session_ingress")
    admitted = []

    async def engine_admit(authority, event):
        """Like the engine's: any metadata outside WhatsApp is refused (session_envelope._native_metadata)."""
        if event.metadata and str(event.source.platform) != "whatsapp":
            return ("⚠️ Hermes refused this message (invalid_params), so it was not saved "
                    "or answered. Ask the operator to check gateway.log.")
        admitted.append(event)
        return authority

    si.admit_message = engine_admit
    sys.modules["gateway.session_ingress"] = si
    sys.modules["gateway"].session_ingress = si
    check("the gateway's admission gets wrapped once", m.install_admission() and m.install_admission()
          and si.admit_message.__wrapped__ is engine_admit)
    stray = MessageEvent("https://x.com/a/status/1", source=Source(), metadata={"one_choice": "abc"})
    out = await si.admit_message("answered", stray)
    check("a Telegram message with stray metadata is let in and answered", out == "answered" and admitted[-1] is stray
          and stray.metadata == {})
    wa = MessageEvent("hi", source=Source(platform="whatsapp"), metadata={"whatsapp_native_type": "audio"})
    check("WhatsApp's own metadata is left alone", m.admissible(wa).metadata == {"whatsapp_native_type": "audio"})
    mine = MessageEvent("hi", source=Source(platform="acp"), metadata={"x": 1})
    check("One's own chat is never touched", m.admissible(mine).metadata == {"x": 1})
    notices = {
        "⚠️ Hermes refused this message (invalid_params), so it was not saved or answered. Ask the operator to check "
        "gateway.log.": m.REFUSED,
        "⏳ Hermes is restarting — your message is saved and will be answered when it is back.": m.RESTARTING,
        "⏸️ This conversation is paused: a previous turn did not finish when Hermes restarted, and only you know "
        "whether to send it again. Your message is saved. Send /discard to drop the lost turn and continue (it is not "
        "re-run), or /reset to start a fresh conversation.": m.CUT_OFF.format(discard="/discard"),
        "⏸️ This conversation is paused: a queued message could not be re-authorized (permission_denied). Your message "
        "is saved but will not be answered here. Send /reset to start a fresh conversation, or ask the operator to "
        "resume this one.": m.UNCHECKED,
    }
    for engine, plain in notices.items():
        got = m.plain_notice(engine)
        check(f"plain words for {engine[:34]!r}…", got == plain)
        check("  no operator, no log, no Hermes", not any(w in got.lower() for w in ("operator", "log", "hermes")))
    check("the way out of a cut-off turn keeps its command", "/discard" in m.plain_notice(list(notices)[2]))

    async def refusing(authority, event):
        return list(notices)[0]

    si.admit_message = refusing
    m.install_admission()
    said = await si.admit_message(None, MessageEvent("x", source=Source()))
    check("a refusal that still happens reaches the phone in plain words", said == m.REFUSED)
    other = await si.admit_message(None, MessageEvent("x", source=Source(platform="acp")))
    check("other chats keep the engine's own text", other == list(notices)[0])
    check("a reply that isn't a notice is left alone", m.plain_notice("Sure, drafting it now.") == "Sure, drafting it now.")


asyncio.run(main())
print("phone-choices ok" if fails == 0 else f"phone-choices FAILED ({fails})")
sys.exit(1 if fails else 0)
