"""One: helper lines in a phone-chat reply do what they do in One's own chat.

Nov 15 2026, 8:45 PM: in the Telegram chat the assistant answered "I'm sending a helper to build it now" with a
[helper: Science explainer channel | …] line, and later passed on a change with [tell-helper: …]. Nothing started.
Those lines are read only by the Mac app (Helpers.read, Sources/HelperLines.swift), and a phone-chat reply never goes
through the app: the engine's background helper (the gateway) sends it straight to the phone. Omar thought the job
ran all night.

This plugin sits on that road. For a reply in a phone chat (Telegram, WhatsApp, Signal, iMessage, SMS):

- ``transform_llm_output``: when it holds a [helper: …], [tell-helper: …], [stop-helper: …], [done-helper: …] or
  [close-helper: …] line, the whole reply goes to ``<hermes home>/one-phone/inbox/<id>.json`` for One, which acts on
  it with the same code as its own chat (Sources/PhoneTags.swift: starts the helper, shows it on the Mac, messages
  the result to that chat when it's done). The person gets the reply without those lines (nor [job-kind: …] or
  [learned: …]), cut the same way One cuts them (a tag ends at the "]" that balances its own "["; one that never
  closes hides the rest), or one short plain line when nothing else is left. The same reply again in the same
  conversation (a re-run turn) is written once.
- ``pre_llm_call``: every phone-chat turn tells the assistant that those lines work there and how its helpers are
  doing (``one-phone/news.md``, kept by One), so it can answer "is it still running?" and pass on an answer.

Nov 9 2026: a reply ending in a choices line ([choices: Yes, go ahead | Not now]), which One's own chat turns into
buttons, reached Telegram as that raw line. So in the Telegram chat only:

- ``transform_llm_output`` takes a last-line [choices: a | b | c] off the reply (cut like Choices.split in
  Sources/Model.swift: at most 4) and ties a button message to this turn's delivery (the adapter's post-delivery
  callback, for the turn's own run, so it lands right under the reply). When that can't be set up, the reply is
  left as it was.
- The buttons are Telegram inline buttons with this plugin's own ``oc:`` taps (``ctx.register_telegram_handler``),
  never the engine's shared picker. A tap is what typing that answer does: it goes to the gateway as the person's
  message from that chat. Each set works once and only while it's the newest: a newer set, or the person typing
  something else (``pre_gateway_dispatch``), takes the older buttons away, and a tap on old buttons says so.

Anything else (One's own chat, helpers, routines, other phone chats' choices) is never touched. Logged to
``logs/one-phone-tags.log``. Checked by tools/phone-tags-check.py and tools/phone-choices-check.py (plain python),
and tools/phone-choices-engine-check.sh (the real engine's Telegram adapter).
"""

from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import datetime as _dt
import hashlib
import json
import os
import secrets
import time
from pathlib import Path
from typing import Any, Optional

PHONE = {"telegram", "whatsapp", "signal", "imessage", "sms"}
# Kept in step with TagLines.acted / TagLines.hidden (Sources/TagLines.swift); tests/fixtures/phone-tags/shown.json
# is checked against both.
ACTED = ["helper", "tell-helper", "stop-helper", "done-helper", "close-helper"]
HIDDEN = ACTED + ["job-kind", "learned"]
NEWS_FOR = 7 * 24 * 3600  # a status note older than this is One gone quiet: not passed on
NEWS_MAX = 3000

RULE = (
    "(One app note, not from the user: this is their phone chat. Helper lines work here exactly as in One's own chat: "
    "write [helper: …], [tell-helper: …], [stop-helper: …] and [done-helper: …] lines as usual. One takes them out of "
    "this chat, starts or tells the helper on the Mac (it shows there too) and sends the result to this chat by itself "
    "when it's done. So send helpers as usual, never paste a helper line for them to read, never say they must be at "
    "the Mac for it, and don't do the job here yourself.)"
)


def _home() -> Path:
    h = os.environ.get("HERMES_HOME")
    return Path(h) if h else Path.home() / ".hermes"


def _dir() -> Path:
    return _home() / "one-phone"


def _log(line: str) -> None:
    try:
        d = _home() / "logs"
        d.mkdir(parents=True, exist_ok=True)
        with (d / "one-phone-tags.log").open("a") as f:
            f.write(f"{_dt.datetime.now().isoformat(timespec='seconds')} {line}\n")
    except Exception:
        pass


def _session(name: str) -> str:
    try:
        from gateway.session_context import get_session_env

        return str(get_session_env(name, "") or "")
    except Exception:
        return os.environ.get(name, "")


def _platform(platform: Any) -> str:
    p = str(getattr(platform, "value", platform) or "").lower()
    return p or _session("HERMES_SESSION_PLATFORM").lower()


# ---------------------------------------------------------------------------
# Tags, cut exactly like Sources/TagLines.swift


def _opens(c: str, i: int, open_: str) -> bool:
    return c[i:i + len(open_)].lower() == open_


def _closing(c: str, i: int) -> Optional[int]:
    """The "]" balancing the "[" at i."""
    depth = 0
    for j in range(i, len(c)):
        if c[j] == "[":
            depth += 1
        elif c[j] == "]":
            depth -= 1
            if depth == 0:
                return j
    return None


def _stray(c: str, k: int, opens: list[str]) -> int:
    """A "]" later on that closes nothing there still ends this tag; looks no further than the next tag."""
    end, depth, low = k + 1, 0, 0
    m = k + 1
    while m < len(c):
        if c[m] == "[":
            if any(_opens(c, m, o) for o in opens):
                break
            depth += 1
        elif c[m] == "]":
            depth -= 1
            if depth < low:
                low = depth
                end = m + 1
        m += 1
    return end


def _next_line_start(c: str, frm: int, open_: str) -> Optional[int]:
    m = frm
    while m < len(c):
        if c[m] == "\n":
            s = m + 1
            while s < len(c) and c[s] in " \t":
                s += 1
            if _opens(c, s, open_):
                return s
        m += 1
    return None


def hits(c: str, tags: list[str]) -> list[dict]:
    """Every outermost tag of these kinds, in reading order (a finished reply)."""
    opens = [(t.lower(), "[" + t.lower() + ":") for t in tags]
    out: list[dict] = []
    i = 0
    while i < len(c):
        o = next((x for x in opens if _opens(c, i, x[1])), None) if c[i] == "[" else None
        if o is None:
            i += 1
            continue
        frm = i + len(o[1])
        k = _closing(c, i)
        if k is not None:
            end = _stray(c, k, [x[1] for x in opens])
            out.append({"start": i, "end": end, "body": c[frm:end - 1], "tag": o[0], "open": False})
            i = end
        else:
            nxt = _next_line_start(c, frm, o[1])
            nxt = len(c) if nxt is None else nxt
            out.append({"start": i, "end": nxt, "body": c[frm:nxt].strip(), "tag": o[0], "open": True})
            i = nxt
    return out


def cut(c: str, hs: list[dict]) -> str:
    out = ""
    at = 0
    n = len(c)
    for h in hs:
        s = h["start"]
        while s > at and c[s - 1] in " \t":
            s -= 1
        if h["open"]:
            out += c[at:s]
            at = n
            break
        e = h["end"]
        while e < n and c[e] in " \t":
            e += 1
        if (s == 0 or c[s - 1] == "\n") and e < n and c[e] == "\n":
            e += 1  # a tag on lines of its own: no blank line left
        out += c[at:s]
        after = c[e] if e < n else "\n"
        if out and out[-1] != "\n" and after != "\n":
            out += "\n"
        at = e
    if at < n:
        out += c[at:]
    lines = out.split("\n")
    while lines and not lines[-1].strip(" \t"):
        lines.pop()
    while lines and not lines[0].strip(" \t"):
        lines.pop(0)
    t = "\n".join(lines)
    while "\n\n\n" in t:
        t = t.replace("\n\n\n", "\n\n")
    return t


def shown(text: str) -> str:
    """What the person sees: One's own chat shows Helpers.strip(Helpers.read(reply).said)."""
    hs = hits(text, ACTED)
    said = cut(text, hs) if hs else text
    hs = hits(said, HIDDEN)
    t = cut(said, hs) if hs else said
    k = t.rfind("[")
    if k >= 0:
        tail = t[k:].lower()
        if any(("[" + tag + ":").startswith(tail) for tag in HIDDEN):
            t = t[:k].strip(" \t")
    keep = [ln for ln in t.split("\n") if not any(ln.strip(" \t").lower().startswith("[" + tag) for tag in HIDDEN)]
    return "\n".join(keep)


def _title(body: str) -> str:
    return " ".join(body.split("|", 1)[0].split())[:60]


def plain_line(text: str) -> str:
    """One short line for a reply that was only tags."""
    hs = hits(text, ACTED)
    jobs = [_title(h["body"]) for h in hs if h["tag"] == "helper" and "|" in h["body"]]
    tells = [_title(h["body"]) for h in hs if h["tag"] == "tell-helper"]
    stops = [_title(h["body"]) for h in hs if h["tag"] == "stop-helper"]
    clears = [_title(h["body"]) for h in hs if h["tag"] in ("done-helper", "close-helper")]
    parts = []
    if jobs:
        parts.append("On it: I sent a helper for " + ", ".join(jobs) + ". I'll message you here when it's done.")
    if stops:
        parts.append("Stopped " + ", ".join(stops) + ".")
    if clears:
        parts.append("Cleared " + ", ".join(clears) + ".")
    if tells:
        parts.append("Passed that on to " + ", ".join(tells) + ".")
    return " ".join(parts) or "Done."


# ---------------------------------------------------------------------------
# Hooks


def reply_id(session_id: str, text: str) -> str:
    return hashlib.sha256(f"{session_id}\n{text}".encode()).hexdigest()[:24]


def _hand_over(text: str, platform: str, session_id: str, turn_id: str) -> None:
    rid = reply_id(session_id, text)
    inbox = _dir() / "inbox"
    f = inbox / f"{rid}.json"
    if f.exists():
        return  # the same reply again (a re-run turn): One acts on it once
    inbox.mkdir(parents=True, exist_ok=True)
    rec = {
        "id": rid, "platform": platform, "chat": _session("HERMES_SESSION_CHAT_ID"), "session": session_id,
        "turn": str(turn_id or ""), "at": time.time(), "reply": text,
    }
    tmp = inbox / f".{rid}.tmp"
    tmp.write_text(json.dumps(rec))
    os.replace(tmp, f)
    _log(f"{platform} {session_id}: reply with helper lines handed to One ({rid})")


def transform_llm_output(response_text: Any = None, session_id: str = "", platform: Any = None, turn_id: Any = None,
                         **_: Any) -> Optional[str]:
    try:
        p = _platform(platform)
        text = response_text if isinstance(response_text, str) else ""
        if p not in PHONE or "[" not in text:
            return None
        out = text
        if hits(text, HIDDEN):
            if hits(text, ACTED):
                _hand_over(text, p, str(session_id or ""), str(turn_id or ""))
            out = shown(text).strip()
            if not out:
                out = plain_line(text)
        if p == "telegram":
            out = with_buttons(out)
        return out if out != text else None
    except Exception as e:  # never break the reply over this
        _log(f"couldn't read a phone reply: {e}")
        return None


def news() -> str:
    f = _dir() / "news.md"
    try:
        if time.time() - f.stat().st_mtime > NEWS_FOR:
            return ""
        t = f.read_text().strip()
    except OSError:
        return ""
    return t[:NEWS_MAX]


def pre_llm_call(platform: Any = None, **_: Any) -> Optional[dict]:
    try:
        p = _platform(platform)
        if p not in PHONE:
            return None
        n = news()
        ck = _chat_key(_session("HERMES_SESSION_CHAT_ID"), _session("HERMES_SESSION_THREAD_ID"))
        offered = _offered.pop(ck, None) if p == "telegram" else None
        if offered:
            n = (n + "\n" if n else "") + OFFERED.format(" | ".join(offered))
        return {"context": RULE + ("\n" + n if n else "")}
    except Exception as e:
        _log(f"couldn't add the phone note: {e}")
        return None


# ---------------------------------------------------------------------------
# [choices: …] as tap buttons in the Telegram chat

MAX_CHOICES = 4  # Choices.split keeps 4
LABEL_MAX = 60
PROMPT = "Tap one, or type your own answer."
OLD = "These buttons are old. Just type your answer."
KEEP = 24 * 3600  # a set of buttons older than this is gone
_adapters: list = []  # (adapter, loop) for each live Telegram connection
_sets: dict[str, dict] = {}  # button set id -> what it offers and where
_newest: dict[str, str] = {}  # chat key -> its newest live set
_sources: dict[str, Any] = {}  # chat key -> the person's last message there (where a tap comes from)
_offered: dict[str, list[str]] = {}  # chat key -> the buttons last sent there, told to the assistant once
# The saved reply has no choices line (the person never saw it), so the next turn is told what the buttons were.
OFFERED = "(One app note: your last reply here ended with [choices: {}], shown to them as tap buttons.)"


def split_choices(text: str) -> tuple[str, list[str]]:
    """Choices.split (Sources/Model.swift): a last line [choices: a | b] comes off, its options (at most 4) out."""
    lines = text.split("\n")
    while lines and not lines[-1].strip(" \t"):
        lines.pop()
    last = lines[-1].strip(" \t") if lines else ""
    if not last.lower().startswith("[choice"):
        return text, []
    lines.pop()
    body = "\n".join(lines)
    inner = last.split(":", 1)[1] if ":" in last else ""
    if not inner.endswith("]"):
        return body, []
    opts = [o.strip(" \t") for o in inner[:-1].split("|")]
    return body, [o for o in opts if o][:MAX_CHOICES]


def _chat_key(chat: Any, thread: Any) -> str:
    return f"{chat}:{thread or ''}"


def with_buttons(text: str) -> str:
    """The reply for the Telegram chat: its choices line becomes buttons under it, or it stays as it was."""
    body, offered = split_choices(text)
    choices: list[str] = []
    for c in offered:
        if c.lower() not in (x.lower() for x in choices):
            choices.append(c)  # the same answer twice is one button
    if not choices or not _arm(choices):
        return text
    return body.strip() or PROMPT


def _arm(choices: list[str]) -> bool:
    """Ties the buttons to this turn's delivery. False (the line stays as text) when that can't be done safely."""
    key = _session("HERMES_SESSION_KEY")
    chat = _session("HERMES_SESSION_CHAT_ID")
    if not key or not chat:
        return False
    thread = _session("HERMES_SESSION_THREAD_ID")
    for adapter, loop in list(_adapters):
        active = (getattr(adapter, "_active_sessions", None) or {}).get(key)
        if active is None:
            continue
        gen = getattr(active, "_hermes_run_generation", None)
        slot = (getattr(adapter, "_post_delivery_callbacks", None) or {}).get(key)
        if gen is None and isinstance(slot, tuple):
            _log(f"telegram {key}: choices left as text (no run to tie the buttons to)")
            return False  # an untied callback would push the engine's own one for this run out of its slot
        offer = {"chat": str(chat), "thread": thread or None, "choices": choices, "key": key, "at": time.time(),
                 "env": {n: _session("HERMES_SESSION_" + n) for n in ("CHAT_TYPE", "CHAT_NAME", "USER_ID", "USER_NAME")}}

        def tie(adapter=adapter, gen=gen, offer=offer) -> None:
            adapter.register_post_delivery_callback(key, lambda: send_buttons(adapter, offer), generation=gen)

        try:
            if loop is None or loop.is_closed():
                continue
            loop.call_soon_threadsafe(tie)
        except Exception as e:
            _log(f"telegram {key}: couldn't tie the buttons: {e}")
            return False
        return True
    _log(f"telegram {key}: choices left as text (no live Telegram turn for it)")
    return False


def _keyboard(rows: list[list[tuple[str, str]]]) -> Any:
    try:
        from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    except ImportError:  # plain-python checks
        return {"inline_keyboard": [[{"text": t, "callback_data": d} for t, d in r] for r in rows]}
    return InlineKeyboardMarkup([[InlineKeyboardButton(t, callback_data=d) for t, d in r] for r in rows])


def _label(c: str) -> str:
    return c if len(c) <= LABEL_MAX else c[:LABEL_MAX - 1].rstrip() + "…"


async def _take_away(adapter: Any, sid: str, text: Optional[str] = None) -> None:
    """Takes a set's buttons off its message (and says what was picked); it can't be tapped any more."""
    st = _sets.pop(sid, None)
    if st is None or st.get("msg") is None:
        return
    if _newest.get(st["ck"]) == sid:
        _newest.pop(st["ck"], None)
    bot = getattr(adapter, "_bot", None)
    try:
        if text is not None:
            await bot.edit_message_text(chat_id=st["chat"], message_id=st["msg"], text=text, reply_markup=None)
        else:
            await bot.edit_message_reply_markup(chat_id=st["chat"], message_id=st["msg"], reply_markup=None)
    except Exception as e:
        _log(f"telegram {st['chat']}: couldn't take old buttons away: {e}")


async def send_buttons(adapter: Any, offer: dict) -> None:
    """After the reply landed: one message with the buttons; the older set in that chat goes."""
    now = time.time()
    for sid in [s for s, st in _sets.items() if now - st["at"] > KEEP]:
        _sets.pop(sid, None)
    ck = _chat_key(offer["chat"], offer["thread"])
    old = _newest.get(ck)
    if old:
        await _take_away(adapter, old)
    sid = secrets.token_hex(5)
    rows = [[(_label(c), f"oc:{sid}:{i}") for i, c in enumerate(offer["choices"][j:j + 2], start=j)]
            for j in range(0, len(offer["choices"]), 2)]
    meta = {"thread_id": offer["thread"]} if offer["thread"] else None
    try:
        send = getattr(adapter, "_send_control_message", None)
        if send is not None:
            msg = await send(offer["chat"], PROMPT, parse_mode=None, thread_id=offer["thread"], metadata=meta,
                             reply_markup=_keyboard(rows))
        else:
            msg = await adapter._bot.send_message(chat_id=offer["chat"], text=PROMPT, reply_markup=_keyboard(rows))
    except Exception as e:
        _log(f"telegram {offer['chat']}: buttons not sent ({e}); sending the choices as text")
        with contextlib.suppress(Exception):
            await adapter.send(offer["chat"], " / ".join(offer["choices"]), metadata=meta)
        return
    _sets[sid] = dict(offer, msg=getattr(msg, "message_id", None), ck=ck, at=now)
    _newest[ck] = sid
    _offered[ck] = list(offer["choices"])
    _log(f"telegram {offer['chat']}: {len(offer['choices'])} buttons sent ({sid})")


def _source(adapter: Any, st: dict, user: Any) -> Any:
    """Where the tap comes from: the person's last message in that chat, else the chat this turn ran in."""
    src = _sources.get(st["ck"])
    uid = str(getattr(user, "id", "") or "")
    name = getattr(user, "first_name", None)
    if src is not None:
        return dataclasses.replace(src, message_id=None, user_id=uid or src.user_id, user_name=name or src.user_name)
    env = st.get("env") or {}
    return adapter.build_source(chat_id=st["chat"], chat_name=env.get("CHAT_NAME") or None,
                                chat_type=env.get("CHAT_TYPE") or "dm", user_id=uid or env.get("USER_ID") or None,
                                user_name=name or env.get("USER_NAME") or None, thread_id=st["thread"])


async def _authorized_tap(adapter: Any, query: Any) -> bool:
    gate = getattr(adapter, "_callback_authorized", None)
    ctx = getattr(adapter, "_callback_ctx", None)
    if gate is None or ctx is None:
        await query.answer(text="Not allowed.")
        return False  # no way to check who tapped: never act on it
    return await gate(query, ctx(query), "Not allowed.")


def on_tap(adapter: Any) -> Any:
    async def tap(update: Any, context: Any = None) -> None:
        query = getattr(update, "callback_query", None)
        data = str(getattr(query, "data", "") or "")
        if query is None or not data.startswith("oc:"):
            return
        if not await _authorized_tap(adapter, query):
            return
        _, sid, idx = (data.split(":") + ["", ""])[:3]
        st = _sets.get(sid)
        if st is None or _newest.get(st["ck"]) != sid or not idx.isdigit() or int(idx) >= len(st["choices"]):
            await query.answer(text=OLD)
            with contextlib.suppress(Exception):
                await query.edit_message_reply_markup(reply_markup=None)
            return
        choice = st["choices"][int(idx)]
        src = _source(adapter, st, getattr(query, "from_user", None))
        await _take_away(adapter, sid, f"✓ {choice}")  # gone before anything else: a second tap finds nothing
        with contextlib.suppress(Exception):
            await query.answer()
        from gateway.platforms.event import MessageEvent, MessageType

        ev = MessageEvent(text=choice, message_type=MessageType.TEXT, source=src, metadata={"one_choice": sid})
        _log(f"telegram {st['chat']}: tapped {int(idx) + 1} of {len(st['choices'])} ({sid}); sent as their message")
        await adapter.handle_message(ev)

    return tap


def wire(native: Any, adapter: Any) -> None:
    """Telegram connected: this plugin's own button taps, and the adapter to send them with."""
    from telegram.ext import CallbackQueryHandler

    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = getattr(adapter, "_loop", None)
    _adapters[:] = [(a, lp) for a, lp in _adapters if a is not adapter] + [(adapter, loop)]
    native.add_handler(CallbackQueryHandler(on_tap(adapter), pattern=r"^oc:"))
    _log("telegram connected: choices become buttons")


async def pre_gateway_dispatch(event: Any = None, gateway: Any = None, **_: Any) -> None:
    """The person wrote in the Telegram chat: remember where from; buttons still up there are now old."""
    try:
        src = getattr(event, "source", None)
        if src is None or getattr(event, "internal", False) or _platform(getattr(src, "platform", "")) != "telegram":
            return None
        check = getattr(gateway, "_is_user_authorized", None)
        if check is None or not check(src):
            return None
        ck = _chat_key(src.chat_id, src.thread_id)
        _sources[ck] = src
        sid = _newest.get(ck)
        if sid and (getattr(event, "metadata", None) or {}).get("one_choice") != sid:
            for adapter, _lp in list(_adapters):
                if (getattr(adapter, "_bot", None)) is not None:
                    await _take_away(adapter, sid)
                    break
    except Exception as e:
        _log(f"couldn't note a Telegram message: {e}")
    return None


def register(ctx) -> None:
    ctx.register_hook("transform_llm_output", transform_llm_output)
    ctx.register_hook("pre_llm_call", pre_llm_call)
    ctx.register_hook("pre_gateway_dispatch", pre_gateway_dispatch)
    if hasattr(ctx, "register_telegram_handler"):
        ctx.register_telegram_handler(wire)
