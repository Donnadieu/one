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

Nov 17 2026: four replies that morning said "It's starting now…:" or "I'm sending a helper…:" and ended at the colon;
nothing started. The model never wrote the line (no hand-over logged, and each turn's output tokens leave no room for
one). The saved reply is the cut one, so every earlier success in the replayed chat read as a promise ending at "now:"
with nothing after it, and the model copied that shape. So now:

- the cut lines leave a receipt at the end of the reply ("↳ Helper sent: <title>", "↳ Passed on to …"): the person
  sees what went to One, and the saved reply shows that a line was there;
- a reply with no helper line that says a job is starting (``missing_line``) is logged loudly, the next turn in that
  chat is told nothing started (``one-phone/missing.json``, survives a restart), and when the reply plainly hangs (says
  it's sending a helper, ends at the colon, or writes a receipt itself) the person is told too;
- the phone rule says saved replies are cut and that only the line itself starts a job.

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

Nov 18 2026: a tap was refused by the engine ("⚠️ Hermes refused this message (invalid_params) … Ask the operator to
check gateway.log."): it carried metadata, which the engine's admission refuses outside WhatsApp. A tap carries none
now, any phone message still carrying some has it dropped before admission (``install_admission``, ``admissible``), and
the engine's own refusal and pause notices reach the phone in plain words (``plain_notice``): no "Hermes", no operator,
no log.

Nov 28 2026: five or more replies in one long Telegram chat said "I'm sending a helper to set up Cal.com:" or ended in
a hand-written "↳ Passed on to Cal.com booking setup", with no line; Omar got "Nothing started… Say go" each time,
twice right after he complained. The cause was this plugin: the cut reply, with its receipts, was what the engine
SAVED (``apply_llm_output_transform`` writes the transformed text into the stored assistant row), so the replayed
chat showed only receipts and never a real line, and the model copied the receipt. So now:

- what's saved is the reply as written, with its real lines (only the [choices: …] line still comes off, see below),
  and never a receipt: a "↳ …" line the assistant wrote itself is taken off before it's saved;
- the cut and the receipts happen on the way out only (``deliver``, run inside the gateway's own last step before a
  reply is sent, ``gateway.run._sanitize_gateway_final_response``, wrapped once by ``install_delivery``);
- a reply that says a helper is being sent or told with no line (``missing_line``) gets one silent correction turn
  (``_correct``: the same model, with this chat's recent messages) that must answer with only the missing line(s);
  they're added to the reply, handed to One and get their receipts, so the person sees only the fixed reply. Only when
  that fails too (no line, an error, a timeout) does the person get the short ``MISSING_SHOWN`` note.

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
import logging
import os
import re
import secrets
import sys
import time
from pathlib import Path
from typing import Any, Optional

# The tags, cut exactly like Sources/TagLines.swift (ACTED/HIDDEN kept in step with TagLines.acted/hidden).
from .tags import ACTED, HIDDEN, RECEIPT, _title, hits, plain_line, receipts, shown  # noqa: F401

PHONE = {"telegram", "whatsapp", "signal", "imessage", "sms"}
NEWS_FOR = 7 * 24 * 3600  # a status note older than this is One gone quiet: not passed on
NEWS_MAX = 3000

RULE = (
    "(One app note, not from the user: this is their phone chat. Helper lines work here exactly as in One's own chat: "
    "write [helper: …], [tell-helper: …], [stop-helper: …] and [done-helper: …] lines as usual. One takes them out of "
    "this chat, starts or tells the helper on the Mac (it shows there too) and sends the result to this chat by itself "
    "when it's done. So send helpers as usual, never paste a helper line for them to read, never say they must be at "
    "the Mac for it, and don't do the job here yourself. A job starts only when THIS reply holds its own "
    "[helper: Title | job] line (a message for a helper: its own [tell-helper: Title | message] line); saying "
    "\"I'm sending a helper\" or \"I'm telling the helper\" starts nothing. A \"↳ …\" line in an older reply is a "
    "receipt only One writes: never write one yourself.)"
)
# A reply that says a job is starting but holds no helper line (Nov 16-17 2026: "It's starting now, together with the
# fix that makes One updates wait for running routines:" and nothing after it; One got nothing, Omar saw a dangling
# colon). Matched per sentence; questions and "if …" sentences don't count.
PROMISE = re.compile(
    r"\b(sending|starting|kicking off|spinning up|launching|firing off)\b[^.!?\n]{0,60}\bhelpers?\b"
    r"|\b(starting|sending|going|rerunning|kicking (it|them) off)\b[^.!?\n]{0,30}\bnow\b"
    r"|\bnow,? for real\b"
    r"|\bi(?:'ve|’ve| have) (just |now )?(started|kicked off) (it|them|both|all|the|a|an|two|three)\b",
    re.IGNORECASE,
)
SAYS_HELPER = re.compile(r"\b(sending|starting|kicking off|spinning up|launching|firing off)\b[^.!?\n]{0,60}\bhelpers?\b",
                         re.IGNORECASE)
# Nov 28 2026: "I'm telling the helper to read the code from your inbox…", "I've corrected the helper: it keeps the
# work step…" (a message for a helper at work, promised with no [tell-helper: …] line).
TELLS = re.compile(
    r"\bi(?:'m|’m| am|'ve|’ve| have|'ll|’ll| will)\s+(?:just\s+|now\s+|also\s+)?"
    r"(?:tell|telling|told|pass|passing|passed|correct|correcting|corrected|update|updating|updated|let|letting)\b"
    r"[^.!?\n]{0,40}\bhelpers?\b"
    r"|\bpass(?:ing|ed)? (?:it|that|this|them) (?:on|along) to\b",
    re.IGNORECASE,
)
NOT_A_CLAIM = re.compile(r"^\W*(if|when|once|after|should|shall|want|do you|would you|could|can i|or)\b", re.IGNORECASE)
MISSING_SHOWN = "(That didn't go through, so nothing started. Say \"go\" and I'll send it.)"
# A receipt line the assistant typed itself: only One writes those (``receipts``), and only on the way out.
FAKE_RECEIPT = re.compile(r"^\s*(?:↳|helper sent:|passed on to:)", re.IGNORECASE)
CORRECT_TIMEOUT = 90.0
CORRECT_CONTEXT = 12  # recent messages of the chat the correction turn sees
CORRECT = (
    "(One app note, not from the user: your reply just now said {what} (\"{said}\") but held no {need} line, so One "
    "started NOTHING from it, and the person hasn't seen that reply yet. Write the missing line(s) now. Reply with ONLY "
    "the line(s), nothing else: a new job is [helper: Title | the whole job with every detail, since the helper can't "
    "see this chat]; a message for a helper already at work is [tell-helper: Title | the message], with that helper's "
    "exact title.{titles} Never write a \"↳ …\" receipt: only One writes those. If that reply didn't mean to start or "
    "pass on anything, reply NONE.)\n\nYour reply was:\n{reply}"
)
MISSING_NOTE = (
    "(One app note: your last reply in this chat said a job was starting (\"{said}\") but held no [helper: …] line, "
    "so One started NOTHING from it{shown}. If that job is still wanted, write its [helper: Title | job] line in this "
    "reply. If it was already running or you did it another way, ignore this note.)"
)
MISSING_FOR = 24 * 3600


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
# Hooks


def reply_id(session_id: str, text: str) -> str:
    return hashlib.sha256(f"{session_id}\n{text}".encode()).hexdigest()[:24]


def _loud(line: str) -> None:
    """A miss Omar would otherwise only find on his phone: in this plugin's log and the engine's warnings too."""
    _log(line)
    with contextlib.suppress(Exception):
        logging.getLogger("one-phone-tags").warning(line)


def _hand_over(text: str, platform: str, session_id: str, turn_id: str, rid: str = "") -> None:
    rid = rid or reply_id(session_id, text)
    inbox = _dir() / "inbox"
    f = inbox / f"{rid}.json"
    if f.exists():
        _log(f"{platform} {session_id}: the same reply again, already waiting for One ({rid})")
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


def _before_choices(body: str, extra: list[str]) -> str:
    """Adds lines at the end of a reply, above a last [choices: …] line (that one must stay last)."""
    if not extra:
        return body
    lines = body.split("\n")
    while lines and not lines[-1].strip(" \t"):
        lines.pop()
    tail = []
    if lines and lines[-1].strip(" \t").lower().startswith("[choice"):
        tail = ["", lines.pop()]
        while lines and not lines[-1].strip(" \t"):
            lines.pop()
    head = "\n".join(lines)
    choice = tail[1] if tail else ""
    return (head + "\n\n" if head else "") + "\n".join(extra) + ("\n\n" + choice if choice else "")


def _claims(text: str) -> list[str]:
    """The sentences of a reply (not its choices line, quotes or questions) that say a job is starting."""
    body, _ = split_choices(text)
    out = []
    for line in body.split("\n"):
        if line.lstrip().startswith(">"):
            continue
        for s in re.split(r"(?<=[.!?:])\s+", line.strip()):
            s = s.strip(" \t*_")
            if s and not s.endswith("?") and not NOT_A_CLAIM.search(s) and (PROMISE.search(s) or TELLS.search(s)):
                out.append(s)
    return out


def missing_line(text: str) -> Optional[dict]:
    """A reply with no helper line that says a job is starting or a helper is being told. ``loud``: it plainly hangs
    (says it is sending or telling a helper, ends at a colon after such words, or carries a receipt it wrote itself),
    so the person is told nothing started when the correction turn can't fix it."""
    if hits(text, ACTED):
        return None
    claims = _claims(text)
    fakes = [ln.strip() for ln in text.split("\n") if FAKE_RECEIPT.match(ln)]
    if not (claims or fakes):
        return None
    body, _ = split_choices(text)
    hangs = body.rstrip(" \t\n*_").endswith(":")
    loud = bool(fakes) or hangs or any(SAYS_HELPER.search(s) or TELLS.search(s) for s in claims)
    said = " ".join((claims[-1] if claims else fakes[0]).split())
    return {"said": said if len(said) <= 160 else said[:159] + "…", "loud": loud,
            "tell": bool(any(TELLS.search(s) for s in claims) or any("passed on" in f.lower() for f in fakes)),
            "titles": [t for t in (_receipt_title(f) for f in fakes) if t]}


def _receipt_title(line: str) -> str:
    """The helper a hand-written receipt names ("↳ Passed on to Cal.com booking setup" -> "Cal.com booking setup")."""
    m = re.match(r"^\s*↳?\s*(?:helper sent:|passed on to:?|stopping|clearing)\s*(.+)$", line, re.IGNORECASE)
    return " ".join(m.group(1).split())[:60] if m else ""


def no_fake_receipts(text: str) -> str:
    """The reply without receipt lines the assistant typed itself (only One writes receipts, on the way out)."""
    if not any(FAKE_RECEIPT.match(ln) for ln in text.split("\n")):
        return text
    kept = "\n".join(ln for ln in text.split("\n") if not FAKE_RECEIPT.match(ln))
    while "\n\n\n" in kept:
        kept = kept.replace("\n\n\n", "\n\n")
    return kept.strip()


def _text_of(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(p.get("text") or "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return ""


def _history(session_id: str) -> list[dict]:
    """This chat's recent user and assistant messages, from the engine's own store (the turn's own question is in it
    already; its reply isn't yet). Empty when it can't be read."""
    if not session_id:
        return []
    try:
        from hermes_state import SessionDB

        rows = SessionDB(read_only=True).get_messages(session_id, limit=CORRECT_CONTEXT * 3, latest=True)
    except Exception as e:
        _log(f"correction turn: couldn't read the chat ({e}); asking with the reply alone")
        return []
    out: list[dict] = []
    for r in rows:
        role, t = r.get("role"), _text_of(r.get("content")).strip()
        if role not in ("user", "assistant") or not t or r.get("tool_calls"):
            continue
        t = t if len(t) <= 4000 else t[:4000] + "…"
        if out and out[-1]["role"] == role:
            out[-1]["content"] += "\n\n" + t
        else:
            out.append({"role": role, "content": t})
    out = out[-CORRECT_CONTEXT:]
    while out and out[0]["role"] != "user":
        out.pop(0)
    return out


def _ask(messages: list[dict]) -> str:
    """One turn of the same model this chat runs on (the engine's main runtime for this turn), no tools."""
    from agent.auxiliary_client import call_llm

    resp = call_llm(messages=messages, max_tokens=2000, temperature=0, timeout=CORRECT_TIMEOUT)
    return _text_of(resp.choices[0].message.content) or ""


_fixed: dict[str, str] = {}  # reply id -> the lines its correction turn brought back (a re-run turn asks once)


def _correct(reply: str, miss: dict, session_id: str, rid: str) -> Optional[str]:
    """The silent correction turn: the missing [helper: …]/[tell-helper: …] line(s), "NONE" when the assistant says it
    meant nothing, or None when it couldn't be fixed."""
    if rid in _fixed:
        return _fixed[rid]
    titles = miss.get("titles") or []
    n = news()
    prompt = CORRECT.format(
        what="a message was being passed on to a helper" if miss.get("tell") else "a helper job was starting",
        said=miss.get("said", ""), need="[tell-helper: …]" if miss.get("tell") else "[helper: …]",
        titles=(" It named: " + ", ".join(titles) + ".") if titles else "", reply=reply)
    if n:
        prompt += "\n\n" + n
    msgs = _history(session_id)
    if msgs and msgs[-1]["role"] == "user":
        msgs.append({"role": "assistant", "content": reply})
    msgs.append({"role": "user", "content": prompt})
    try:
        answer = _ask(msgs) or ""
    except Exception as e:
        _loud(f"correction turn failed: {e}")
        return None
    lines = [answer[h["start"]:h["end"]].strip() for h in hits(answer, ACTED)
             if h["body"].strip() and (h["tag"] not in ("helper", "tell-helper") or "|" in h["body"])]
    if lines:
        _fixed[rid] = "\n".join(lines)
        return _fixed[rid]
    if answer.strip().strip(".").upper() == "NONE":
        _fixed[rid] = "NONE"
        return "NONE"
    _loud(f"correction turn brought back no line: {answer[:200]!r}")
    return None


def _missing_file() -> Path:
    return _dir() / "missing.json"


def _missing_all() -> dict:
    try:
        d = json.loads(_missing_file().read_text())
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _missing_save(d: dict) -> None:
    f = _missing_file()
    f.parent.mkdir(parents=True, exist_ok=True)
    tmp = f.with_name(".missing.tmp")
    tmp.write_text(json.dumps(d))
    os.replace(tmp, f)


def _note_missing(ck: str, miss: Optional[dict]) -> None:
    """Remembers (on disk: a gateway restart in between must not lose it) that this chat's last reply promised a job
    with no line, for the next turn there; a reply that does hand lines over clears it."""
    d = {k: v for k, v in _missing_all().items() if time.time() - float(v.get("at", 0)) < MISSING_FOR}
    if miss:
        d[ck] = dict(miss, at=time.time())
    elif ck not in d:
        return
    else:
        d.pop(ck, None)
    _missing_save(d)


def take_missing(ck: str) -> Optional[dict]:
    d = _missing_all()
    m = d.pop(ck, None)
    if m is None:
        return None
    with contextlib.suppress(OSError):
        _missing_save(d)
    return m if time.time() - float(m.get("at", 0)) < MISSING_FOR else None


def transform_llm_output(response_text: Any = None, session_id: str = "", platform: Any = None, turn_id: Any = None,
                         **_: Any) -> Optional[str]:
    """What the engine SAVES for a phone-chat reply (and replays next turn): the reply as written, with its real helper
    lines, never a receipt. The person's copy is cut on the way out (``deliver``)."""
    try:
        p = _platform(platform)
        text = response_text if isinstance(response_text, str) else ""
        if p not in PHONE or not text.strip():
            return None
        cut_here = not install_delivery()  # no way to cut it on the way out: cut (and save) it here, as before
        ck = _chat_key(_session("HERMES_SESSION_CHAT_ID"), _session("HERMES_SESSION_THREAD_ID"))
        sid = str(session_id or "")
        rid = reply_id(sid, text)  # of the reply as the model wrote it: a re-run turn is the same reply
        out = no_fake_receipts(text)
        miss = missing_line(text)
        if miss:
            fixed = _correct(out, miss, sid, rid)
            if fixed == "NONE":
                _log(f"{p} {sid}: \"{miss['said']}\" read like a promise; the correction turn says it meant none")
                miss = None
            elif fixed:
                out = _before_choices(out, [fixed])
                _log(f"{p} {sid}: the reply promised a job with no line (\"{miss['said']}\"); the correction turn "
                     f"wrote it, the person sees only the fixed reply")
                miss = None
        if "[" in out and hits(out, ACTED):
            _hand_over(out, p, sid, str(turn_id or ""), rid)
            _note_missing(ck, None)
        if miss:
            _note_missing(ck, miss)
            _loud(f"{p} {session_id}: MISSING HELPER LINE: the reply says a job is starting (\"{miss['said']}\") but "
                  f"holds no [helper: …] line, and the correction turn brought none, so nothing went to One; the "
                  f"assistant is told next turn" + (" and the person now" if miss["loud"] else ""))
            if miss["loud"]:
                out = _before_choices(out.strip(), [MISSING_SHOWN])
        if cut_here:
            _loud(f"{p} {sid}: the gateway's send step couldn't be wrapped; this reply is saved cut, with receipts")
            out = deliver(out, p)
        if p == "telegram":
            out = with_buttons(out)
        return out if out != text else None
    except Exception as e:  # never break the reply over this
        _loud(f"couldn't read a phone reply: {e}")
        return None


def deliver(text: Any, platform: Any) -> Any:
    """The person's copy of a saved phone-chat reply: its helper lines (and [job-kind: …]/[learned: …]) cut the way
    One's own chat cuts them, One's receipts in their place, or one plain line when nothing else is left. A reply
    with no such lines (one already cut, too) goes as it is."""
    if not isinstance(text, str) or "[" not in text or _platform(platform) not in PHONE or not hits(text, HIDDEN):
        return text
    out = shown(text).strip()
    return _before_choices(out, receipts(text)) if out else plain_line(text)


_DELIVER_MARK = "_one_phone_delivery"


def install_delivery() -> bool:
    """Wraps the gateway's last step before a reply is sent (gateway/run.py, imported by name at each call) once, so
    the cut and the receipts reach the phone but never the saved chat. Only the gateway that is already running: never
    imported here (that starts a whole runtime; anywhere else the reply is cut and saved as before)."""
    gr = sys.modules.get("gateway.run")
    cur = getattr(gr, "_sanitize_gateway_final_response", None) if gr is not None else None
    if cur is None:
        return False
    if getattr(cur, _DELIVER_MARK, False):
        return True

    def _sanitize_gateway_final_response(platform: Any, text: Any) -> Any:
        try:
            text = deliver(text, platform)
        except Exception as e:
            _loud(f"couldn't cut a phone reply on its way out: {e}")
        return cur(platform, text)

    setattr(_sanitize_gateway_final_response, _DELIVER_MARK, True)
    _sanitize_gateway_final_response.__wrapped__ = cur
    gr._sanitize_gateway_final_response = _sanitize_gateway_final_response
    _log("phone chat: helper lines are cut on the way out, saved as written")
    return True


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
        miss = take_missing(ck)
        if miss:
            told = " (they were told nothing started)" if miss.get("loud") else ""
            n = (n + "\n" if n else "") + MISSING_NOTE.format(said=miss.get("said", ""), shown=told)
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

        # No metadata: the engine refuses any on a message outside WhatsApp (see ADMISSION below). The set is
        # already gone (_take_away), so nothing needs to tell this tap apart from typing.
        ev = MessageEvent(text=choice, message_type=MessageType.TEXT, source=src)
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
    install_admission()
    install_delivery()
    _log("telegram connected: choices become buttons")


# ---------------------------------------------------------------------------
# A phone message is answered, never refused for how it was made (ADMISSION)
#
# Nov 17 2026 4:16 PM and Nov 18 2:19 AM: Omar tapped a choice button in the Telegram chat and got "⚠️ Hermes refused
# this message (invalid_params), so it was not saved or answered. Ask the operator to check gateway.log." gateway.log:
# "Native admission refused: invalid_params (metadata) … message=None", the same second as this plugin's "tapped 1 of
# 3 … sent as their message". The tap carried metadata={"one_choice": …}, and the engine's admission
# (gateway/session_envelope.py, _native_metadata) refuses ANY metadata on a message outside WhatsApp. The tap carries
# none now; and as a net for anything else that puts metadata on a phone message, it is dropped before admission
# (the engine keeps none of it for these chats anyway). The engine's notices name it ("Hermes"), an operator and a
# log; Omar is the only person here and is on his phone, so the phone gets plain words (the engine's wording and
# clause stay in gateway.log and one-phone-tags.log).

REFUSED = "⚠️ I couldn't take that message in, so I didn't answer it. Please send it again."
RESTARTING = "⏳ I'm restarting. Your message is saved and I'll answer it when I'm back."
CUT_OFF = ("⏸️ This chat is paused: a restart cut off my last answer. Your message is saved. Send {discard} to drop "
           "that answer and carry on, or /reset to start a fresh chat.")
UNCHECKED = ("⏸️ This chat is paused: a waiting message couldn't be checked again, so I can't answer here. "
             "Send /reset to start a fresh chat.")
_NOTICES = (("⚠️ Hermes refused this message", REFUSED), ("⏳ Hermes is restarting", RESTARTING),
            ("⏸️ This conversation is paused: a previous turn did not finish", CUT_OFF),
            ("⏸️ This conversation is paused: a queued message could not be re-authorized", UNCHECKED))
_ADMIT_MARK = "_one_phone_admission"


def _phone_event(event: Any) -> str:
    """The phone chat an incoming message is from ('' when it's none, or internal)."""
    src = getattr(event, "source", None)
    if src is None or getattr(event, "internal", False):
        return ""
    p = str(getattr(getattr(src, "platform", None), "value", getattr(src, "platform", "")) or "").lower()
    return p if p in PHONE else ""


def admissible(event: Any) -> Any:
    """The same event, with metadata the engine's admission would refuse the whole message for taken off. WhatsApp's
    adapter stamps its own allowed keys, so it's left alone. In place: the gateway's turn markers ride on it."""
    p = _phone_event(event)
    meta = getattr(event, "metadata", None)
    if p and p != "whatsapp" and meta:
        keys = sorted(map(str, meta)) if isinstance(meta, dict) else [type(meta).__name__]
        try:
            event.metadata = {}
            _log(f"{p} {getattr(event.source, 'chat_id', '')}: dropped metadata {keys} so the message is answered, not refused")
        except Exception as e:
            _log(f"{p}: couldn't drop metadata {keys}: {e}")
    return event


def plain_notice(text: Any) -> Any:
    """The engine's own notice for a phone chat in plain words: no "Hermes", no operator, no log."""
    if not isinstance(text, str):
        return text
    for start, said in _NOTICES:
        if text.startswith(start):
            m = re.search(r"Send (/hermes discard|/\w+) to drop", text)
            out = said.format(discard=m.group(1) if m else "/discard")
            _log(f"phone notice in plain words: {text[:120]!r}")
            return out
    return text


def install_admission() -> bool:
    """Wraps the engine's admit_message (read off its module at each call, gateway/run_inbound.py) once per gateway."""
    try:
        import gateway.session_ingress as si
    except Exception:
        return False
    cur = getattr(si, "admit_message", None)
    if cur is None or getattr(cur, _ADMIT_MARK, False):
        return cur is not None

    async def admit_message(authority: Any, event: Any) -> Any:
        phone = bool(_phone_event(event))
        out = await cur(authority, admissible(event) if phone else event)
        return plain_notice(out) if phone else out

    setattr(admit_message, _ADMIT_MARK, True)
    admit_message.__wrapped__ = cur
    si.admit_message = admit_message
    _log("phone chat: messages are let in, notices in plain words")
    return True


async def pre_gateway_dispatch(event: Any = None, gateway: Any = None, **_: Any) -> None:
    """The person wrote in the Telegram chat: remember where from; buttons still up there are now old."""
    try:
        install_admission()
        install_delivery()
        admissible(event)
    except Exception as e:
        _log(f"couldn't check a phone message: {e}")
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
        if sid:  # a tap already took its own set away (_take_away), so this is only ever an older one
            for adapter, _lp in list(_adapters):
                if (getattr(adapter, "_bot", None)) is not None:
                    await _take_away(adapter, sid)
                    break
    except Exception as e:
        _log(f"couldn't note a Telegram message: {e}")
    return None


def register(ctx) -> None:
    with contextlib.suppress(Exception):
        install_delivery()  # the gateway itself (never One's own chat): wrap its send step now
    ctx.register_hook("transform_llm_output", transform_llm_output)
    ctx.register_hook("pre_llm_call", pre_llm_call)
    ctx.register_hook("pre_gateway_dispatch", pre_gateway_dispatch)
    if hasattr(ctx, "register_telegram_handler"):
        ctx.register_telegram_handler(wire)
