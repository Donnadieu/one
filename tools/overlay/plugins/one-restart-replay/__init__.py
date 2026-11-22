"""One: a turn the engine's restart cut off is picked back up, never "will not be run again".

Nov 10-22 2026 (One's nightly review saw it 12 times): every time One's engine stopped mid-turn (an update install,
a folder restart, One quitting), the engine settled each person's turn in flight as ``interrupted`` and wrote, into the
conversation and onto the live stream:

    "Gateway shutting down: this turn was interrupted and will not be run again. Send your message again once Hermes
    is back."

(``gateway/session_settlement_recovery.py`` ``owner_stop_notice``, written by ``gateway/session_results.py``
``finish_result`` and published by ``_publish_completion``; ``agent.restart_drain_timeout`` is 0, so the drain waits
0 s.) The engine never runs that turn again. One's Mac app picks its own conversations back up (helpers, the main
chat), but the line stayed in the conversation, and in the phone chat nobody picked anything up: Nov 11 19:04, "Yes go
ahead" in Telegram was cut by a One restart and Omar had to write "Are you back" three minutes later. The engine also
told the phone "⚠️ Hermes is shutting down … send any message and I'll try to pick up where we left off".

This plugin, for a turn a person sent (routines and other automation keep the engine's own copy):

- ``owner_stop_notice``: the engine's restart/shutdown copy becomes One's line, ``LINE`` ("One restarted; picking
  this back up."), in the conversation and on the stream. One's app treats that line as a cut-off (HelperFinish.swift,
  EngineWait.swift) and picks the turn back up itself; nobody is asked to send anything again.
- Phone chats: the cut turn's message is written to ``<hermes home>/one-replay/<admission id>.json`` (fsync'd) in the
  same call, before the engine exits. When Telegram connects again, each one is sent again ONCE as the person's
  message from that chat (with a note telling the assistant it's a pick-up, so it answers now and checks any step that
  may already have run). Its file is removed before it goes, so it can never go twice; if the pick-up is cut again,
  that new turn is kept the same way, up to ``MAX_TRIES`` pick-ups, then one plain line instead. Not sent again: one
  older than ``FRESH`` (what one-missed-messages treats as stale), or when the chat moved on since (a newer message in
  that conversation: they already asked again, or something else picked it up).
- The phone's "Operation interrupted: …" reply of a turn cut by the stop, and the engine's shutdown notices ("Hermes
  is shutting down … send any message"), become plain words: the active chat is told it'll be picked back up; the
  home channel, where nothing of theirs was cut, gets nothing.

Logged to ``logs/one-restart-replay.log``. Checked by tools/restart-replay-check.py (plain python) and
tools/restart-replay-engine-check.sh (the real engine's own functions).
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import json
import os
import re
import sqlite3
import time
from pathlib import Path
from typing import Any, Optional

LINE = "One restarted; picking this back up."
ACTIVE_NOTICE = "One is restarting. I'll pick this back up by myself in a moment."
GAVE_UP = ("One restarted twice while I was working on “{text}”, so I stopped there. Say “go on” and I'll pick it "
           "back up.")
NOTE = ("\n\n(One app note, not from the user: One restarted while you were answering this message, so it comes again "
        "[restart pick-up {n}]. Answer it now, once; don't ask them to send it again. Some steps may already have run "
        "before the restart: check before doing any of them twice.)")
NOTE_RE = re.compile(r"\n\n\(One app note, not from the user: One restarted while you were answering this message, "
                     r"so it comes again \[restart pick-up (\d+)\].*\)\s*$", re.S)
PHONE = {"telegram", "whatsapp", "signal", "imessage", "sms"}
FRESH = 2 * 3600  # older than this: not acted on (one-missed-messages' rule for messages sent while One was off)
MAX_TRIES = 2  # pick-ups of one message; a third cut gets GAVE_UP instead
SETTLE = 6.0  # seconds after Telegram connects before picking up (the engine's own boot work goes first)
_MARK = "_one_restart_replay"
# Rows the engine itself adds as "user" (a background step finishing, a squeeze, a routine's report): not the person.
MACHINE = ("[IMPORTANT:", "[CONTEXT COMPACTION", "[Cron delivery", "[ASYNC", "[SYSTEM:", "[STILL IN PROGRESS")
_stopping = False  # the gateway began stopping: an "Operation interrupted" now is the restart's, not a Stop


def _home() -> Path:
    h = os.environ.get("HERMES_HOME")
    return Path(h) if h else Path.home() / ".hermes"


def _dir() -> Path:
    return _home() / "one-replay"


def _log(line: str) -> None:
    try:
        d = _home() / "logs"
        d.mkdir(parents=True, exist_ok=True)
        with (d / "one-restart-replay.log").open("a") as f:
            f.write(f"{_dt.datetime.now().isoformat(timespec='seconds')} {line}\n")
    except Exception:
        pass


def _write(path: Path, data: dict) -> None:
    """On disk for good before this returns: written aside, fsync'd, renamed, the folder fsync'd."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(data, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    fd = os.open(str(path.parent), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def base_text(text: str) -> tuple[str, int]:
    """The person's own words, and how many pick-ups they've had already (the note a pick-up carries)."""
    m = NOTE_RE.search(text or "")
    if not m:
        return text or "", 0
    return (text or "")[: m.start()], int(m.group(1))


def entry_of(row: Any) -> Optional[dict]:
    """What to keep of a cut admission: a person's message in a phone chat, else None."""
    if not isinstance(row, dict):
        return None
    payload = row.get("payload") or {}
    native = payload.get("native_text_v1") or {}
    if not isinstance(native, dict) or "automation" in native or "webhook_delivery" in native:
        return None
    principal = str(row.get("principal_id") or "")
    if principal.startswith("automation:") or principal.startswith("cron"):
        return None
    source = native.get("source") or {}
    platform = str(source.get("platform") or "").lower()
    text = payload.get("text")
    if platform not in PHONE or not isinstance(text, str) or not text.strip() or not source.get("chat_id"):
        return None
    words, tries = base_text(text)
    return {
        "id": str(row.get("admission_id") or ""), "platform": platform, "chat": str(source.get("chat_id")),
        "thread": source.get("thread_id"), "route": native.get("route"), "session": row.get("target_session_id"),
        "source": source, "text": words, "tries": tries, "at": time.time(),
    }


def keep(row: Any) -> bool:
    """A person's phone turn the restart cut: on disk for its pick-up. Once per admission (the engine asks twice)."""
    e = entry_of(row)
    if e is None or not e["id"]:
        return False
    p = _dir() / f"{e['id']}.json"
    if p.exists():
        return True
    _write(p, e)
    _log(f"kept {e['platform']} {e['chat']}: {e['text'][:120]!r} (pick-ups so far {e['tries']})")
    return True


def entries(platform: Optional[str] = None) -> list[dict]:
    out = []
    for p in sorted(_dir().glob("*.json")) if _dir().is_dir() else []:
        try:
            e = json.loads(p.read_text())
        except Exception:
            continue
        if platform is None or e.get("platform") == platform:
            e["_path"] = str(p)
            out.append(e)
    return sorted(out, key=lambda e: e.get("at", 0))


def moved_on(e: dict) -> bool:
    """Something newer happened in that conversation after the cut (they asked again, or it was picked up)."""
    db = _home() / "state.db"
    if not e.get("session") or not db.exists():
        return False
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            rows = con.execute(
                "SELECT substr(content, 1, 40) FROM messages WHERE session_id=? AND role='user' AND timestamp>?",
                (e["session"], float(e.get("at", 0)) + 1.0)).fetchall()
        finally:
            con.close()
        return any(not str(r[0] or "").lstrip().startswith(MACHINE) for r in rows)
    except Exception:
        return False


def decide(e: dict, now: Optional[float] = None) -> str:
    """'send' (pick it up), 'stale', 'moved' or 'gave-up'."""
    now = time.time() if now is None else now
    if now - float(e.get("at", 0)) > FRESH:
        return "stale"
    if moved_on(e):
        return "moved"
    if int(e.get("tries", 0)) >= MAX_TRIES:
        return "gave-up"
    return "send"


def again_text(e: dict) -> str:
    return e["text"] + NOTE.format(n=int(e.get("tries", 0)) + 1)


async def replay(adapter: Any, platform: str = "telegram", settle: float = SETTLE) -> list[tuple[str, str]]:
    """Telegram is back: each kept message goes once, oldest first. Returns (decision, text) per message."""
    if settle:
        await asyncio.sleep(settle)
    done = []
    for e in entries(platform):
        what = decide(e)
        try:
            os.unlink(e["_path"])  # gone before it goes: never twice, whatever happens next
        except OSError:
            continue  # another pick-up took it
        _log(f"{platform} {e['chat']}: {what}: {e['text'][:120]!r}")
        done.append((what, e["text"]))
        try:
            if what == "send":
                from gateway.platforms.event import MessageEvent, MessageType
                from gateway.session import SessionSource

                src = SessionSource.from_dict(dict(e["source"], message_id=None))
                await adapter.handle_message(MessageEvent(text=again_text(e), message_type=MessageType.TEXT, source=src))
            elif what == "gave-up":
                short = e["text"].strip().replace("\n", " ")
                await adapter.send(e["chat"], GAVE_UP.format(text=short[:80] + ("…" if len(short) > 80 else "")))
        except Exception as ex:
            _log(f"{platform} {e['chat']}: couldn't pick it up: {ex!r}")
    return done


# --- the engine's own words, in One's -----------------------------------------------------------------------------


def install_notice() -> bool:
    """Wraps the engine's owner_stop_notice (looked up on its module at each call by both of its callers)."""
    try:
        import gateway.session_settlement_recovery as ssr
    except Exception:
        return False
    cur = getattr(ssr, "owner_stop_notice", None)
    if cur is None or getattr(cur, _MARK, False):
        return cur is not None
    cut = {getattr(ssr, "RESTART_INTERRUPT_NOTICE", None), getattr(ssr, "SHUTDOWN_INTERRUPT_NOTICE", None)} - {None}

    def owner_stop_notice(captured, outcome, row=None):
        notice = cur(captured, outcome, row)
        if notice in cut:
            try:
                keep(row)
            except Exception as ex:
                _log(f"couldn't keep a cut turn: {ex!r}")
            return LINE
        return notice

    setattr(owner_stop_notice, _MARK, True)
    owner_stop_notice.__wrapped__ = cur
    ssr.owner_stop_notice = owner_stop_notice
    return True


def install_shutdown_notices() -> bool:
    """The engine's "Hermes is shutting down … send any message" notices: plain words, or nothing where nothing was cut."""
    try:
        from gateway.run_shutdown import GatewayShutdownMixin as cls
    except Exception:
        return False
    if getattr(cls, _MARK, False):
        return True
    send = cls._send_shutdown_notice
    notify = cls._notify_active_sessions_of_shutdown

    async def _send_shutdown_notice(self, adapter, chat_id, msg, kind, platform_str, **kw):
        if kind == "home channel":
            _log(f"shutdown notice to the home channel {platform_str}:{chat_id} left out")
            return True  # counts as sent: nothing of theirs was cut there
        return await send(self, adapter, chat_id, ACTIVE_NOTICE, kind, platform_str, **kw)

    async def _notify_active_sessions_of_shutdown(self):
        global _stopping
        _stopping = True
        return await notify(self)

    cls._send_shutdown_notice = _send_shutdown_notice
    cls._notify_active_sessions_of_shutdown = _notify_active_sessions_of_shutdown
    setattr(cls, _MARK, True)
    return True


def transform_llm_output(response_text: Any = None, platform: Any = None, **_: Any) -> Optional[str]:
    """A phone turn the stop cut ends on the engine's "Operation interrupted: …": One's line instead."""
    p = str(getattr(platform, "value", platform) or "").lower()
    if _stopping and p in PHONE and isinstance(response_text, str) and response_text.startswith("Operation interrupted:"):
        return LINE
    return None


def wire(native: Any, adapter: Any) -> None:
    """Telegram connected: what the last restart cut goes again, once."""
    if not entries("telegram"):
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = getattr(adapter, "_loop", None)
    if loop is None:
        _log("telegram connected but no loop to pick up on")
        return
    coro = replay(adapter, "telegram")
    try:
        if asyncio.get_running_loop() is loop:
            loop.create_task(coro)
            return
    except RuntimeError:
        pass
    asyncio.run_coroutine_threadsafe(coro, loop)


def register(ctx) -> None:
    ctx.register_hook("transform_llm_output", transform_llm_output)
    if hasattr(ctx, "register_telegram_handler"):
        ctx.register_telegram_handler(wire)
    a, b = install_notice(), install_shutdown_notices()
    _log(f"loaded (cut-off words {'One' if a else 'not patched'}, shutdown notices {'plain' if b else 'not patched'})")
