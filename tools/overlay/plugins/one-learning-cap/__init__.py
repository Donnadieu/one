"""One: the engine's after-each-job learning stays under the nightly review's limits.

The engine's background review (the fork that runs after a job and patches skills on its own) used to change
skills about 60 times a day with no limit. Omar (Nov 4 2026) put it under the same limits as One's nightly
review: at most N skill edits a day (default 5) and 1 per skill, read from `<One>/improve/settings.json`
(`max_edits_per_night`, `max_edits_per_skill`). Only edits made by that background review are counted and
capped; the person's own requests, helpers and the nightly review are never blocked here.

A blocked edit is not lost: it is logged to `hermes/logs/one-learning-cap.log` and appended to
`<One>/improve/held-review-edits.jsonl` so the nightly review can weigh it.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
from pathlib import Path
from typing import Any, Optional

WRITE_ACTIONS = {"create", "patch", "edit", "write_file", "remove_file", "delete", "update", "replace"}


def _home() -> Path:
    h = os.environ.get("HERMES_HOME")
    return Path(h) if h else Path.home() / ".hermes"


def _support() -> Path:
    return _home().parent


def _limits() -> tuple[int, int]:
    try:
        s = json.loads((_support() / "improve" / "settings.json").read_text())
        return int(s.get("max_edits_per_night", 5)), int(s.get("max_edits_per_skill", 1))
    except Exception:
        return 5, 1


def _is_review() -> bool:
    try:
        from tools.skill_provenance import is_background_review

        return bool(is_background_review())
    except Exception:
        return False


def _recent_review_edits(hours: int = 24) -> list[dict[str, Any]]:
    """Ledger entries written by the background review (actor 'curator', a write action) in the last day."""
    p = _home() / "skills" / ".curator_ledger.jsonl"
    try:
        with p.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 1_500_000))
            lines = f.read().decode("utf-8", "ignore").splitlines()
    except Exception:
        return []
    since = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(hours=hours)
    out = []
    for line in lines:
        try:
            e = json.loads(line)
            ts = _dt.datetime.fromisoformat(str(e.get("ts", "")).replace("Z", "+00:00"))
        except Exception:
            continue
        if ts >= since and e.get("actor") == "curator" and str(e.get("action", "")) in WRITE_ACTIONS:
            out.append(e)
    return out


def _log(line: str, held: dict[str, Any]) -> None:
    try:
        logs = _home() / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        with (logs / "one-learning-cap.log").open("a") as f:
            f.write(f"{_dt.datetime.now().isoformat(timespec='seconds')} {line}\n")
        imp = _support() / "improve"
        imp.mkdir(parents=True, exist_ok=True)
        with (imp / "held-review-edits.jsonl").open("a") as f:
            f.write(json.dumps(held) + "\n")
    except Exception:
        pass


def decide(tool_name: str, args: Optional[dict[str, Any]], is_review: bool, recent: list[dict[str, Any]],
           limits: tuple[int, int]) -> Optional[str]:
    """Pure decision (tested): a block message, or None to let the call through."""
    if tool_name != "skill_manage" or not is_review:
        return None
    ops = _ops(args)
    writes = [o for o in ops if str(o.get("action", "")).lower() in WRITE_ACTIONS]
    if not writes:
        return None
    max_day, max_skill = limits
    if len(recent) + len(writes) > max_day:
        return (f"One's learning limit: the after-job review may change at most {max_day} skills a day "
                f"({len(recent)} used today). Don't retry; the nightly review will look at this lesson.")
    names = [str(o.get("name") or "") for o in writes]
    for n in set(names):
        if n and sum(1 for e in recent if e.get("skill") == n) + names.count(n) > max_skill:
            return (f"One's learning limit: '{n}' may be changed by an after-job review at most {max_skill} "
                    "time(s) a day. Don't retry; the nightly review will look at this lesson.")
    return None


def _ops(args: Optional[dict[str, Any]]) -> list[dict[str, Any]]:
    a = args or {}
    ops = a.get("operations")
    if isinstance(ops, list):
        return [o for o in ops if isinstance(o, dict)]
    return [a]


def on_pre_tool_call(tool_name: str = "", args: Optional[dict[str, Any]] = None, session_id: str = "", **_: Any):
    if tool_name != "skill_manage":
        return None
    review = _is_review()
    if not review:
        return None
    msg = decide(tool_name, args, review, _recent_review_edits(), _limits())
    if msg is None:
        return None
    ops = _ops(args)
    what = ", ".join(f"{o.get('action')} {o.get('name')}" for o in ops)
    _log(f"held {what} (session {session_id})",
         {"at": _dt.datetime.now().astimezone().isoformat(timespec="seconds"), "session": session_id,
          "operations": [{k: (v[:2000] if isinstance(v, str) else v) for k, v in o.items()} for o in ops]})
    return {"action": "block", "message": msg}


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
