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

Anything else (One's own chat, helpers, routines) is never touched. Logged to ``logs/one-phone-tags.log``.
Checked by tools/phone-tags-check.py.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
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
        if not hits(text, HIDDEN):
            return None
        if hits(text, ACTED):
            _hand_over(text, p, str(session_id or ""), str(turn_id or ""))
        out = shown(text).strip()
        if not out:
            out = plain_line(text)
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
        if _platform(platform) not in PHONE:
            return None
        n = news()
        return {"context": RULE + ("\n" + n if n else "")}
    except Exception as e:
        _log(f"couldn't add the phone note: {e}")
        return None


def register(ctx) -> None:
    ctx.register_hook("transform_llm_output", transform_llm_output)
    ctx.register_hook("pre_llm_call", pre_llm_call)
