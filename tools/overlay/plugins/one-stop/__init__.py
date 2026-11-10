"""One: Stop means stop.

Nov 9 2026: Omar stopped the helper "Finish NotArc". The engine ended its turn and interrupted its sub-helpers, but
its background test runs kept going, and one second later the first one to finish was injected as a new message
("[IMPORTANT: Background process ... completed]") that started a fresh turn on the stopped conversation. That turn
sent out 5 new sub-helpers. The orb said "Stopped" for 26 minutes while it worked.

One (outside the folder lock) writes ``guard/stopped/<session>.json`` when a helper is stopped. The engine can read
that folder but never write it, so a helper can't unstop itself. For a stopped conversation (and every conversation
under it: sub-helpers, and the ones it continues into after a context squeeze) this plugin:

- drops every wake-up (background process finished, watch pattern, async sub-helper results) instead of starting
  a turn (``GatewayRunner._inject_watch_notification``);
- blocks every tool call, with a message telling the model it was stopped (a sub-helper still finishing a step, or
  a turn that slipped in before the mark, does nothing more);
- in the gateway, every 2 s: kills the background processes the engine started for it (its own and its
  sub-helpers'), interrupts and refuses its async sub-helpers, and writes what is still alive to
  ``<hermes home>/one-stop/<session>.json`` for One's "Stopping… N programs left".

The person's own message in that thread (One lifts the mark) lets it go again. Logged to ``logs/one-stop.log``.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import threading
import time
from pathlib import Path
from typing import Any, Iterable, Optional

SWEEP_EVERY = 2.0
SWEEP_FOR = 15 * 60  # a mark older than this is only read, no longer swept (its helper is long stopped)
STOPPED_MESSAGE = (
    "One stopped this helper: they pressed Stop. Do nothing more: no commands, no new helpers, no retries. "
    "End your turn now with one short line saying you stopped."
)

_parents_cache: dict[str, tuple[float, list[str]]] = {}
_lock = threading.Lock()
_started = False


def hermes_home() -> Path:
    h = os.environ.get("HERMES_HOME")
    if not h:
        try:
            from hermes_constants import get_hermes_home

            h = str(get_hermes_home())
        except Exception:
            h = os.path.expanduser("~/.hermes")
    return Path(h)


def guard_dir() -> Path:
    return Path(os.environ.get("ONE_GUARD_DIR") or (hermes_home().parent / "guard"))


def stopped_dir() -> Path:
    return guard_dir() / "stopped"


def status_dir() -> Path:
    return hermes_home() / "one-stop"


def log(line: str) -> None:
    try:
        f = hermes_home() / "logs" / "one-stop.log"
        f.parent.mkdir(parents=True, exist_ok=True)
        with f.open("a", encoding="utf-8") as h:
            h.write(time.strftime("%Y-%m-%dT%H:%M:%S%z ") + line.replace("\n", " ")[:600] + "\n")
    except Exception:
        pass


def safe(sid: str) -> str:
    return "".join(c if (c.isalnum() or c in "-_") else "_" for c in sid)


def marks() -> dict[str, dict]:
    """Every stopped conversation One marked: {session id: its mark}."""
    out: dict[str, dict] = {}
    d = stopped_dir()
    try:
        if not d.is_dir():
            return out
        for f in d.iterdir():
            if f.suffix != ".json":
                continue
            try:
                j = json.loads(f.read_text())
            except Exception:
                j = {}
            sid = str(j.get("session") or f.stem)
            j.setdefault("at", f.stat().st_mtime)
            out[sid] = j
    except Exception:
        pass
    return out


def parents(session_id: str) -> list[str]:
    """The conversations above this one: the helper that sent this sub-helper, the one it continues."""
    now = time.monotonic()
    with _lock:
        hit = _parents_cache.get(session_id)
        if hit and now - hit[0] < 30:
            return hit[1]
    out: list[str] = []
    try:
        db = hermes_home() / "state.db"
        if db.exists():
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
            try:
                cur = session_id
                for _ in range(12):
                    row = con.execute("select parent_session_id from sessions where id = ?", (cur,)).fetchone()
                    if not row or not row[0]:
                        break
                    cur = str(row[0])
                    out.append(cur)
            finally:
                con.close()
    except Exception:
        pass
    with _lock:
        _parents_cache[session_id] = (now, out)
    return out


def children(session_id: str) -> list[str]:
    """Every conversation under this one (sub-helpers and theirs), from state.db."""
    out: list[str] = []
    try:
        db = hermes_home() / "state.db"
        if not db.exists():
            return out
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            rows = con.execute(
                "with recursive t(id) as (select id from sessions where parent_session_id = ? "
                "union all select s.id from sessions s join t on s.parent_session_id = t.id) select id from t limit 500",
                (session_id,),
            ).fetchall()
            out = [str(r[0]) for r in rows]
        finally:
            con.close()
    except Exception:
        pass
    return out


def stopped_root(ids: Iterable[str], have: Optional[dict] = None) -> Optional[str]:
    """The stopped conversation any of these ids belongs to (itself or one above it), or None."""
    have = marks() if have is None else have
    if not have:
        return None
    for sid in ids:
        if not sid:
            continue
        sid = str(sid)
        if sid in have:
            return sid
        tail = sid.rsplit(":", 1)[-1]  # a gateway session key ends with the chat id
        if tail in have:
            return tail
        for p in parents(sid):
            if p in have:
                return p
    return None


def event_ids(evt: dict) -> list[str]:
    """Every conversation id a wake-up event names (who started the process, where it reports)."""
    keys = ("parent_session_id", "proven_session_id", "origin_session_id", "session_key", "chat_id",
            "watcher_chat_id", "origin_chat_id", "owner_session_id", "task_id", "owner_task_id")
    ids = [str(evt.get(k) or "") for k in keys]
    origin = evt.get("origin")
    if isinstance(origin, dict):
        ids += [str(origin.get(k) or "") for k in ("chat_id", "session_id", "session_key")]
    return [i for i in ids if i]


# --- tool calls ---------------------------------------------------------------------------------------------------


def on_pre_tool_call(tool_name: str = "", args: Optional[dict[str, Any]] = None, session_id: str = "", task_id: str = "", **_: Any):
    try:
        have = marks()
        if not have:
            return None
        root = stopped_root([session_id, task_id], have)
        if root:
            log(f"blocked {tool_name} (session {session_id}, stopped {root})")
            return {"action": "block", "message": STOPPED_MESSAGE}
    except Exception as e:  # never break a tool call because the check itself failed
        log(f"check error on {tool_name}: {e}")
    return None


# --- wake-ups -------------------------------------------------------------------------------------------------------


def wake_root(evt: dict, chat_id: str = "") -> Optional[str]:
    return stopped_root(event_ids(evt) + ([chat_id] if chat_id else []))


def patch_wakeups() -> bool:
    try:
        from gateway import run_notifications as rn
    except Exception:
        return False
    cls = getattr(rn, "GatewayNotificationsMixin", None)
    if cls is None or getattr(cls, "_one_stop", False):
        return cls is not None
    orig = cls._inject_watch_notification

    async def _inject_watch_notification(self, synth_text, evt, *args, **kwargs):
        try:
            root = wake_root(evt if isinstance(evt, dict) else {})
            if root is None and marks():
                import asyncio

                source = await asyncio.to_thread(self._build_process_event_source, evt)
                root = wake_root({}, str(getattr(source, "chat_id", "") or "")) if source else None
            if root:
                log(f"dropped wake-up for stopped {root}: {str(synth_text)[:160]}")
                return None  # terminal: never retried
        except Exception as e:
            log(f"wake-up check error: {e}")
        return await orig(self, synth_text, evt, *args, **kwargs)

    cls._inject_watch_notification = _inject_watch_notification
    cls._one_stop = True
    return True


# --- the sweep (gateway only: that's where the engine's processes and sub-helpers live) ------------------------------


def owned(proc: Any, roots: dict[str, list[str]]) -> Optional[str]:
    """The stopped conversation a background process belongs to, or None."""
    ids = [str(getattr(proc, k, "") or "") for k in ("watcher_chat_id", "session_key", "task_id", "owner_task_id")]
    for root, kids in roots.items():
        tree = {root, *kids}
        for i in ids:
            if i and (i in tree or i.rsplit(":", 1)[-1] in tree):
                return root
    return None


def sweep_once(registry: Any = None, delegation: Any = None, now: Optional[float] = None) -> dict[str, dict]:
    now = time.time() if now is None else now
    have = {k: v for k, v in marks().items() if now - float(v.get("at") or now) < SWEEP_FOR}
    if not have:
        return {}
    roots = {r: children(r) for r in have}
    if registry is None:
        try:
            from tools.process_registry import process_registry as registry
        except Exception:
            registry = None
    if delegation is None:
        delegation = sys.modules.get("tools.async_delegation")
    report: dict[str, dict] = {r: {"session": r, "killed": 0, "pids": [], "commands": [], "delegations": 0, "at": now}
                               for r in roots}
    running = list(getattr(registry, "_running", {}).values()) if registry is not None else []
    for p in running:
        root = owned(p, roots)
        if not root or getattr(p, "exited", False):
            continue
        try:
            r = registry.kill_process(p.id, source="one-stop", consume_output=True)
            st = r.get("status") if isinstance(r, dict) else None
            if st in ("killed", "already_exited"):
                report[root]["killed"] += 1
                log(f"stopped {root}: killed {p.id} pid {getattr(p, 'pid', None)}: {str(getattr(p, 'command', ''))[:160]}")
                continue
        except Exception as e:
            log(f"stopped {root}: couldn't kill {getattr(p, 'id', '?')}: {e}")
        if getattr(p, "pid", None):
            report[root]["pids"].append(int(p.pid))
            report[root]["commands"].append(str(getattr(p, "command", ""))[:200])
    for root, kids in roots.items():
        if delegation is None:
            continue
        for sid in [root, *kids]:
            try:
                if hasattr(delegation, "refuse_for_session"):
                    delegation.refuse_for_session(("one-stop", sid), parent_session_ids=(sid,))
                n = delegation.interrupt_for_session(parent_session_id=sid, reason="one_stop")
                if n:
                    report[root]["delegations"] += int(n)
                    log(f"stopped {root}: interrupted {n} sub-helper(s) of {sid}")
            except Exception as e:
                log(f"stopped {root}: couldn't stop sub-helpers of {sid}: {e}")
    return report


def write_status(report: dict[str, dict]) -> None:
    d = status_dir()
    try:
        d.mkdir(parents=True, exist_ok=True)
        for root, r in report.items():
            f = d / (safe(root) + ".json")
            tmp = f.with_suffix(".tmp")
            tmp.write_text(json.dumps(r))
            tmp.replace(f)
    except Exception as e:
        log(f"status write error: {e}")


def lifted(delegation: Any = None) -> None:
    """A mark One lifted (the person wrote in that thread): its sub-helpers may start again."""
    delegation = delegation or sys.modules.get("tools.async_delegation")
    have = marks()
    d = status_dir()
    try:
        for f in d.glob("*.json") if d.is_dir() else []:
            if f.name == "live.json":
                continue
            sid = json.loads(f.read_text()).get("session") or f.stem
            if sid not in have:
                f.unlink(missing_ok=True)
                if delegation is not None and hasattr(delegation, "allow_for_session"):
                    for s in [sid, *children(sid)]:
                        delegation.allow_for_session(("one-stop", s))
                log(f"lifted {sid}")
    except Exception as e:
        log(f"lift error: {e}")


def chat_of(proc: Any) -> str:
    """The conversation a background process reports to (a sub-helper's programs report to its helper's chat)."""
    for k in ("watcher_chat_id", "session_key"):
        v = str(getattr(proc, k, "") or "")
        if v:
            return v.rsplit(":", 1)[-1]
    return ""


_last_live = ""


def write_live(registry: Any = None) -> dict[str, list[dict]]:
    """Every live background program the engine started, by conversation (``one-stop/live.json``): One keeps each
    helper's record from it while the helper works, so what runs under those programs is known to be the helper's."""
    global _last_live
    if registry is None:
        try:
            from tools.process_registry import process_registry as registry
        except Exception:
            return {}
    live: dict[str, list[dict]] = {}
    for p in list(getattr(registry, "_running", {}).values()):
        chat, pid = chat_of(p), getattr(p, "pid", None)
        if chat and pid and not getattr(p, "exited", False):
            live.setdefault(chat, []).append({"pid": int(pid), "command": str(getattr(p, "command", ""))[:200]})
    text = json.dumps(live, sort_keys=True)
    if text != _last_live:
        try:
            d = status_dir()
            d.mkdir(parents=True, exist_ok=True)
            tmp = d / "live.tmp"
            tmp.write_text(text)
            tmp.replace(d / "live.json")
            _last_live = text
        except Exception as e:
            log(f"live write error: {e}")
    return live


def in_gateway() -> bool:
    return "gateway" in " ".join(sys.argv)


def loop() -> None:
    while True:
        try:
            write_status(sweep_once())
            lifted()
            write_live()
        except Exception as e:
            log(f"sweep error: {e}")
        time.sleep(SWEEP_EVERY)


def register(ctx) -> None:
    global _started
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    patched = patch_wakeups()
    if in_gateway() and not _started:
        _started = True
        threading.Thread(target=loop, name="one-stop", daemon=True).start()
    log(f"loaded (wake-ups {'fenced' if patched else 'not patched'}, sweep {'on' if _started else 'off'}, argv {' '.join(sys.argv[:4])[:120]})")
