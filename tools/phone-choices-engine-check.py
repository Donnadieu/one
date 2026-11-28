"""The real engine turns a Telegram reply's [choices: …] line into tap buttons through One's phone-tags plugin.

Run by tools/phone-choices-engine-check.sh with the engine's own python, cwd = the engine, HERMES_HOME = a scratch
home with the plugin installed and turned on the way Messenger.sync does it. Uses the engine's real pieces: plugin
discovery, `register_telegram_handler` wiring, the Telegram adapter's post-delivery callback slot and its
`_send_control_message`, `apply_llm_output_transform`, the session context a gateway turn runs in, PTB's
CallbackQueryHandler and inline keyboard. Only the network is a stand-in (a bot that records what it would send).
"""

import asyncio
import logging
import os
import sys
import types

sys.path.insert(0, ".")
from hermes_cli import plugins as P  # noqa: E402
from gateway.session_context import set_session_vars, clear_session_vars  # noqa: E402
from gateway.session import SessionSource  # noqa: E402
from gateway.config import Platform  # noqa: E402
from agent.turn_finalizer import apply_llm_output_transform  # noqa: E402
from plugins.platforms.telegram.adapter import TelegramAdapter  # noqa: E402
from gateway.session_envelope import _event_clause  # noqa: E402

RUNNER = types.SimpleNamespace(config=types.SimpleNamespace(multiplex_profiles=False))  # one profile, like One's

try:
    import telegram.ext  # noqa: F401
    REAL_PTB = True
except ImportError:
    # A fresh install gets the Telegram library only once Telegram is set up; installing it, or touching imports before
    # the engine's own, makes the engine re-sync this data root at launch. Minimal stand-ins for the two classes
    # the plugin uses; with the library present (any install with Telegram on) the real ones are used.
    import re as _re

    REAL_PTB = False
    _tg, _ext = types.ModuleType("telegram"), types.ModuleType("telegram.ext")

    class InlineKeyboardButton:
        def __init__(self, text, callback_data=None):
            self.text, self.callback_data = text, callback_data

    class InlineKeyboardMarkup:
        def __init__(self, inline_keyboard):
            self.inline_keyboard = inline_keyboard

    class CallbackQueryHandler:
        def __init__(self, callback, pattern=None):
            self.callback, self.pattern, self.check_update = callback, _re.compile(pattern), True

    _tg.InlineKeyboardButton, _tg.InlineKeyboardMarkup, _ext.CallbackQueryHandler = (
        InlineKeyboardButton, InlineKeyboardMarkup, CallbackQueryHandler)
    _tg.ext = _ext
    sys.modules["telegram"], sys.modules["telegram.ext"] = _tg, _ext

fails = 0
# The engine's default logger lives in agent.conversation_loop, whose import starts a whole agent runtime (in a
# throwaway home: a dependency sync and a relaunch); the transform takes any logger.
LOG = logging.getLogger("one.phone-choices-check")


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


print("  (Telegram library: " + ("the engine's own" if REAL_PTB else "not installed here, stand-in buttons") + ")")
P.discover_plugins(force=True)
check("the engine loads the plugin's reply, turn and message hooks",
      P.has_hook("transform_llm_output") and P.has_hook("pre_llm_call") and P.has_hook("pre_gateway_dispatch"))
factories = P.get_plugin_manager().get_platform_handler_factories("telegram")
check("and its Telegram button wiring", any(name == "one-phone-tags" for _f, name in factories))
mod = next(m for k, m in sys.modules.items() if k.endswith("one_phone_tags") or k.endswith("one-phone-tags"))


class Msg:
    def __init__(self, mid):
        self.message_id = mid


class Bot:
    def __init__(self):
        self.sent, self.edits, self.n = [], [], 100

    async def send_message(self, **kw):
        self.n += 1
        self.sent.append(kw)
        return Msg(self.n)

    async def edit_message_text(self, **kw):
        self.edits.append(("text", kw))

    async def edit_message_reply_markup(self, **kw):
        self.edits.append(("markup", kw))


class Native:
    def __init__(self):
        self.handlers = []

    def add_handler(self, h, group=0):
        self.handlers.append(h)


ad = TelegramAdapter.__new__(TelegramAdapter)  # no network: the parts a send and a tap use
ad._bot = Bot()
ad._post_delivery_callbacks = {}
ad._active_sessions = {}
ad.platform = Platform.TELEGRAM
for attr, val in (("_disable_link_previews", False), ("_reply_to_mode", "first")):
    setattr(ad, attr, val)
dispatched = []


async def handle_message(ev):
    dispatched.append(ev)


ad.handle_message = handle_message


async def authorized(query, cb, denial):
    ok = str(query.from_user.id) == "42"
    if not ok:
        await query.answer(text=denial)
    return ok


ad._callback_authorized = authorized  # the runner's allowlist (TELEGRAM_ALLOWED_USERS=42)
KEY = "agent:main:telegram:dm:42"
src = SessionSource(platform=Platform.TELEGRAM, chat_id="42", user_id="42", user_name="Omar", message_id="7")


class Query:
    def __init__(self, data, uid="42"):
        self.data, self.from_user = data, types.SimpleNamespace(id=uid, first_name="Omar")
        self.answers, self.markup_off = [], False

    async def answer(self, text=None, **_):
        self.answers.append(text)

    async def edit_message_reply_markup(self, reply_markup=None):
        self.markup_off = True


class Agent:
    session_id, model, platform = "tg-sess", "m", "telegram"


def turn(text, turn_id):
    """One gateway turn's last step in the agent's thread: the reply as the engine finishes it."""
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", user_id="42", user_name="Omar",
                              session_key=KEY, session_id="tg-sess")
    try:
        return apply_llm_output_transform(Agent(), text, turn_id=turn_id, logger=LOG)[0]
    finally:
        clear_session_vars(tokens)


saves = []  # what the engine saved for each turn (replayed next turn)


async def deliver(text, turn_id, gen):
    ev = asyncio.Event()
    ev._hermes_run_generation = gen
    ad._active_sessions[KEY] = ev
    core = []
    ad.register_post_delivery_callback(KEY, lambda: core.append("engine's own"), generation=gen)
    saved = await asyncio.get_running_loop().run_in_executor(None, turn, text, turn_id)
    saves.append(saved)
    # The engine's own last step before a reply goes to the chat (gateway/run_turn_persistence.py imports it by name
    # from gateway.run at each turn): the plugin's cut and receipts happen there, never in what's saved.
    import gateway.run as gr
    out = gr._sanitize_gateway_final_response(Platform.TELEGRAM, saved)
    await asyncio.sleep(0.05)
    await ad._fire_post_delivery_callback(KEY, ev)  # after the reply went out
    ad._active_sessions.pop(KEY, None)
    return out, core


def buttons(kw):
    rm = kw.get("reply_markup")
    return [[(b.text, b.callback_data) for b in row] for row in getattr(rm, "inline_keyboard", [])]


async def main():
    native = Native()
    for f, name in factories:
        if name == "one-phone-tags":
            f(native, ad)
    h = native.handlers[0] if native.handlers else None
    check("its tap handler takes only its own buttons (oc:), never the engine's pickers",
          h is not None and h.check_update is not None and h.pattern.match("oc:ab12:0") and not h.pattern.match("cp:0"))
    await mod.pre_gateway_dispatch(event=types.SimpleNamespace(source=src, internal=False, metadata={}),
                                   gateway=types.SimpleNamespace(_is_user_authorized=lambda s: s.user_id == "42"))

    print("1. a reply ending in a choices line, through the engine's own turn end and delivery")
    out, core = await deliver("Want me to book it?\n[choices: Yes, go ahead | Not now]", "t1", 5)
    check("the reply goes without the line", out == "Want me to book it?")
    sent = ad._bot.sent
    check("then one message with two tap buttons, under the reply", len(sent) == 1 and [t for r in buttons(sent[0]) for t, _ in r] == ["Yes, go ahead", "Not now"])
    check("sent to that chat", len(sent) == 1 and str(sent[0].get("chat_id")) == "42")
    check("the engine's own after-reply step for that run still runs", core == ["engine's own"])
    data = buttons(sent[0])[0][1][1] if sent else ""

    print("2. tapping Not now is the same as typing it")
    q = Query(data)
    await h.callback(types.SimpleNamespace(callback_query=q), None)
    ev = dispatched[-1] if dispatched else None
    check("the gateway gets 'Not now' as their message from that chat",
          ev is not None and ev.text == "Not now" and ev.source.chat_id == "42" and ev.source.user_id == "42")
    check("not as a reply to their old message", ev is not None and ev.source.message_id is None)
    # Nov 17-18 2026: the tap reached the phone as "⚠️ Hermes refused this message (invalid_params)": the engine's own
    # admission check said "metadata". This one is the engine's, unchanged.
    check("the engine's own admission takes the tap (Nov 17-18 it refused it: metadata)",
          ev is not None and _event_clause(RUNNER, ev, None, False) is None)
    check("the buttons go and the message says what was picked",
          any(k == "text" and kw.get("text") == "✓ Not now" and kw.get("reply_markup") is None for k, kw in ad._bot.edits))
    await h.callback(types.SimpleNamespace(callback_query=Query(data)), None)
    check("a second tap does nothing", len(dispatched) == 1)
    tokens = set_session_vars(platform="telegram", chat_id="42", session_key=KEY)
    try:
        note = (mod.pre_llm_call(platform="telegram") or {}).get("context", "")
    finally:
        clear_session_vars(tokens)
    check("the next turn is told what the buttons were", "[choices: Yes, go ahead | Not now]" in note)

    print("3. a newer set takes the older one's place; someone else's tap is refused")
    await deliver("Which day?\n[choices: Monday | Tuesday]", "t2", 6)
    first = buttons(ad._bot.sent[-1])
    await deliver("And the time?\n[choices: 7 PM | 8 PM | 9 PM]", "t3", 7)
    check("the older buttons are taken away", any(k == "markup" for k, _ in ad._bot.edits))
    old = Query(first[0][0][1])
    await h.callback(types.SimpleNamespace(callback_query=old), None)
    check("a tap on them is told they're old, nothing sent", len(dispatched) == 1 and old.answers[-1] == mod.OLD)
    stranger = Query(buttons(ad._bot.sent[-1])[0][0][1], uid="666")
    await h.callback(types.SimpleNamespace(callback_query=stranger), None)
    check("someone not allowed in can't tap them", len(dispatched) == 1)

    print("4. the person types instead")
    newest = buttons(ad._bot.sent[-1])[0][1][1]
    await mod.pre_gateway_dispatch(event=types.SimpleNamespace(source=src, internal=False, metadata={}),
                                   gateway=types.SimpleNamespace(_is_user_authorized=lambda s: s.user_id == "42"))
    late = Query(newest)
    await h.callback(types.SimpleNamespace(callback_query=late), None)
    check("the buttons stop working", len(dispatched) == 1 and late.answers[-1] == mod.OLD)

    print("5. no live turn to tie the buttons to (a routine's message, One's own chat)")
    tokens = set_session_vars(platform="telegram", chat_id="42", session_key="agent:main:telegram:dm:other")
    try:
        same = apply_llm_output_transform(Agent(), "Done.\n[choices: OK | Undo]", turn_id="t9", logger=LOG)[0]
    finally:
        clear_session_vars(tokens)
    check("the reply is left exactly as it was", same == "Done.\n[choices: OK | Undo]")
    tokens = set_session_vars(platform="acp", session_key="acp-1")
    try:
        acp = apply_llm_output_transform(types.SimpleNamespace(session_id="a", model="m", platform="acp"),
                                         "Sure?\n[choices: Yes | No]", turn_id="t10", logger=LOG)[0]
    finally:
        clear_session_vars(tokens)
    check("One's own chat keeps its line (its own buttons)", acp == "Sure?\n[choices: Yes | No]")

    print("6. Nov 17/28: a reply that says a helper is starting but holds no line, through the engine's own turn end")
    hung = "I'm sending a helper to find the cause, fix it, and ship it. It won't install while a routine is running:"
    mod._ask = lambda messages: (_ for _ in ()).throw(RuntimeError("no account here"))  # the correction turn fails
    out, _ = await deliver(hung, "t11", 12)
    check("the correction turn failed too: the person is told nothing started", out.startswith(hung)
          and out.endswith(mod.MISSING_SHOWN))
    log = os.path.join(os.environ["HERMES_HOME"], "logs", "one-phone-tags.log")
    check("and it's logged loudly", "MISSING HELPER LINE" in open(log).read())
    tokens = set_session_vars(platform="telegram", chat_id="42", chat_type="dm", user_id="42", session_key=KEY)
    try:
        note = mod.pre_llm_call(platform="telegram")
    finally:
        clear_session_vars(tokens)
    check("the next turn in that chat is told", note is not None and "started NOTHING" in note["context"])
    out, _ = await deliver("Sending it now:\n[helper: Fix it | find the cause and fix it]", "t12", 13)
    check("a reply with the line gets a receipt instead", out == "Sending it now:\n\n↳ Helper sent: Fix it")
    check("and the engine saves it with its real line, no receipt",
          saves[-1] == "Sending it now:\n[helper: Fix it | find the cause and fix it]")
    asked = []
    mod._ask = lambda messages: asked.append(messages) or "[tell-helper: Cal.com booking setup | Keep the work step.]"
    out, _ = await deliver("Got it, the work step stays.\n\n↳ Passed on to Cal.com booking setup", "t13", 14)
    check("Nov 28: a hand-written receipt with no line gets one correction turn", len(asked) == 1)
    check("the person sees only the fixed reply, with One's receipt",
          out == "Got it, the work step stays.\n\n↳ Passed on to Cal.com booking setup")
    check("and the engine saves the real line, not the receipt", "[tell-helper: Cal.com booking setup | Keep the work step.]"
          in saves[-1] and "↳" not in saves[-1])

    print("7. Nov 18: the engine's own admission and notices, with the plugin on")
    import gateway.session_ingress as si
    from gateway.session_envelope import _refuse
    from gateway.platforms.event import MessageEvent, MessageType
    from hermes_state_runtime import RuntimeStoreError

    class Authority:
        """Stands in only for the durable store: the check itself is the engine's (_event_clause, _refuse)."""

        async def admit_native(self, event):
            clause = _event_clause(RUNNER, event, None, False)
            if clause is not None:
                _refuse(event, "invalid_params", clause)
            raise RuntimeStoreError("stale_generation", field="route")  # past the check: the engine answers None

    check("Telegram connecting wrapped the engine's admit_message", getattr(si.admit_message, mod._ADMIT_MARK, False))
    link = "https://x.com/ephraim888sun/status/2122911791126614166?a=oEhpfol6Ao-9P1djTKE&s=19"

    def stray():
        return MessageEvent(text=link, message_type=MessageType.TEXT, source=src, metadata={"one_choice": "07a4dade77"})

    before = await si.admit_message.__wrapped__(Authority(), stray())
    check("the replay: the engine alone refuses a phone message carrying metadata, and says 'ask the operator'",
          isinstance(before, str) and "operator" in before)
    after = await si.admit_message(Authority(), stray())
    check("with the plugin it's let in (answered), not refused", after is None)
    said = await si.admit_message(Authority(), MessageEvent(text="/nope", message_type=MessageType.TEXT, allow_gateway_control=True, source=src))
    check("a refusal that still happens reaches the phone in plain words", said == mod.REFUSED)
    check("no operator, no log, no Hermes in it", not any(w in said.lower() for w in ("operator", "log", "hermes")))
    acp = SessionSource(platform=Platform.LOCAL, chat_id="local-1", user_id="me")
    mine = await si.admit_message(Authority(), MessageEvent(text="/nope", message_type=MessageType.TEXT, allow_gateway_control=True, source=acp))
    check("One's own chat keeps the engine's text", isinstance(mine, str) and mine.startswith("⚠️ Hermes refused"))


asyncio.run(main())
print("engine choices ok" if fails == 0 else f"engine choices FAILED ({fails})")
sys.exit(1 if fails else 0)
