"""One: messages sent while One was off are never thrown away, and never acted on when they're stale.

Nov 6-7 2026: One was down for 18 hours with the lid closed, and the phone chat skipped everything sent meanwhile
(the engine's `drop_pending_on_cold_boot`). One now keeps those messages queued (Messenger.sync turns that setting
off) and this plugin sorts them as they come in, before the assistant sees them:

- sent in the last 2 hours: answered as usual;
- older: not acted on. After the burst, ONE short note goes to that chat listing them ("While I was offline you
  sent: …. Want me to do any of these?"), and the next new message from that chat carries the list as context, so
  "do the second one" works. Anything that sends, posts, spends or deletes still needs a fresh yes.

Only people the gateway lets in are handled here (others go through untouched, so its own checks refuse them).
Logged to `hermes/logs/one-missed-messages.log`.
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import json
import os
from pathlib import Path
from typing import Any, Optional

RECENT = _dt.timedelta(hours=2)  # older than this = sent while One was off, too old to act on
LIVE = _dt.timedelta(minutes=5)  # a message this fresh is a new one, written after the note
CONTEXT_FOR = _dt.timedelta(hours=12)  # how long the list rides along with the next new message
SETTLE = 3.0  # seconds without another old message before the note goes out
MAX_LISTED = 10
PHONE = {"telegram", "whatsapp", "signal", "imessage", "sms"}

_pending: dict[str, list[dict[str, Any]]] = {}
_timers: dict[str, asyncio.Task] = {}


def _home() -> Path:
    h = os.environ.get("HERMES_HOME")
    return Path(h) if h else Path.home() / ".hermes"


def _log(line: str) -> None:
    try:
        d = _home() / "logs"
        d.mkdir(parents=True, exist_ok=True)
        with (d / "one-missed-messages.log").open("a") as f:
            f.write(f"{_dt.datetime.now().isoformat(timespec='seconds')} {line}\n")
    except Exception:
        pass


def _now() -> _dt.datetime:
    fake = os.environ.get("ONE_MISSED_NOW")  # checks only
    if fake:
        return _dt.datetime.fromtimestamp(float(fake), _dt.timezone.utc)
    return _dt.datetime.now(_dt.timezone.utc)


def _aware(t: Any) -> Optional[_dt.datetime]:
    if not isinstance(t, _dt.datetime):
        return None
    return t if t.tzinfo else t.astimezone()  # a naive time is this Mac's local time


def _platform(event: Any) -> str:
    p = getattr(getattr(event, "source", None), "platform", None)
    return str(getattr(p, "value", p) or "")


def _chat(event: Any) -> str:
    return str(getattr(getattr(event, "source", None), "chat_id", "") or "")


def _key(platform: str, chat: str) -> str:
    return f"{platform}-{chat}".replace("/", "_")


def _state_file(key: str) -> Path:
    return _home() / "one-missed" / f"{key}.json"


def summary(event: Any) -> str:
    """One line for the list: the words, or what kind of message it was."""
    text = " ".join(str(getattr(event, "text", "") or "").split())
    kind = str(getattr(getattr(event, "message_type", None), "value", "") or "")
    what = {"photo": "a photo", "video": "a video", "voice": "a voice message", "audio": "a recording",
            "document": "a file", "sticker": "a sticker", "location": "a location"}.get(kind)
    if len(text) > 100:
        text = text[:97].rstrip() + "…"
    if what and text:
        return f"{what}: \u201c{text}\u201d"
    if what:
        return what
    return f"\u201c{text}\u201d" if text else "a message"


def when(t: _dt.datetime, now: _dt.datetime) -> str:
    local = t.astimezone()
    hm = local.strftime("%I:%M %p").lstrip("0")
    return hm if local.date() == now.astimezone().date() else f"{local.strftime('%a')} {hm}"


def note_text(items: list[dict[str, Any]], now: _dt.datetime) -> str:
    shown = items[:MAX_LISTED]
    lines = [f"\u2022 {when(_dt.datetime.fromisoformat(i['at']), now)}: {i['what']}" for i in shown]
    if len(items) > len(shown):
        lines.append(f"\u2022 and {len(items) - len(shown)} more")
    return ("While I was offline you sent:\n" + "\n".join(lines)
            + "\n\nI haven't acted on them since they're a few hours old. Want me to do any of these?")


def context_text(items: list[dict[str, Any]], now: _dt.datetime) -> str:
    listed = "\n".join(f"{n}. {when(_dt.datetime.fromisoformat(i['at']), now)}: {i['what']}"
                       for n, i in enumerate(items[:MAX_LISTED], 1))
    return ("(One app note, not from the user: while One was offline they sent the messages below, more than 2 hours "
            "before it came back. You did not act on them; you already sent one note listing them and asking which "
            "they still want done. If the message after this note picks one, do it now as a fresh request. Anything "
            "that sends, posts, spends money or deletes still needs their clear yes first, as always.\n"
            f"{listed})\n\n")


async def _send_note(key: str, gateway: Any, platform_obj: Any, chat: str) -> None:
    try:
        await asyncio.sleep(SETTLE)
    except asyncio.CancelledError:
        return
    items = sorted(_pending.pop(key, []), key=lambda i: i["at"])
    _timers.pop(key, None)
    if not items:
        return
    now = _now()
    text = note_text(items, now)
    sent = False
    try:
        adapter = (getattr(gateway, "adapters", None) or {}).get(platform_obj)
        if adapter is not None:
            await adapter.send(chat, text)
            sent = True
    except Exception as e:  # never break the chat over the note
        _log(f"{key}: couldn't send the note: {e}")
    try:
        f = _state_file(key)
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps({"sent_at": now.isoformat(), "items": items}))
    except Exception as e:
        _log(f"{key}: couldn't keep the list: {e}")
    _log(f"{key}: {len(items)} message(s) older than 2 hours not acted on; note {'sent' if sent else 'NOT sent'}")


def _authorized(gateway: Any, event: Any) -> bool:
    check = getattr(gateway, "_is_user_authorized", None)
    if check is None:
        return False
    try:
        return bool(check(event.source))
    except Exception:
        return False


async def pre_gateway_dispatch(event: Any = None, gateway: Any = None, session_store: Any = None, **_: Any) -> Optional[dict]:
    if event is None or getattr(event, "internal", False):
        return None
    platform = _platform(event)
    chat = _chat(event)
    sent = _aware(getattr(event, "timestamp", None))
    if platform not in PHONE or not chat or sent is None or not _authorized(gateway, event):
        return None
    now = _now()
    age = now - sent
    key = _key(platform, chat)
    if age > RECENT:
        _pending.setdefault(key, []).append({"at": sent.isoformat(), "what": summary(event)})
        old = _timers.get(key)
        if old is not None:
            old.cancel()
        _timers[key] = asyncio.ensure_future(_send_note(key, gateway, event.source.platform, chat))
        return {"action": "skip", "reason": f"sent {int(age.total_seconds() // 60)} min ago while One was offline; listed instead"}
    f = _state_file(key)
    if age <= LIVE and f.exists():
        try:
            st = json.loads(f.read_text())
            sent_at = _dt.datetime.fromisoformat(st["sent_at"])
            text = str(getattr(event, "text", "") or "")
            if sent <= sent_at or text.lstrip().startswith("/"):
                return None  # written before the note, or a command: keep the list for their next message
            f.unlink()
            if now - sent_at < CONTEXT_FOR:
                _log(f"{key}: the next message carries the list of {len(st['items'])} old message(s)")
                return {"action": "rewrite", "text": context_text(st["items"], now) + text}
        except Exception as e:
            _log(f"{key}: couldn't read the list: {e}")
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_gateway_dispatch", pre_gateway_dispatch)
