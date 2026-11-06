"""One: a standing goal keeps going while it makes progress, and stops when it stalls.

Added by One (copied into the engine's hermes_cli/ by Installer.applyGoals, hooked at the end of
hermes_cli/goals.py, so it runs wherever the engine's own goal loop runs). The loop stays the engine's
(GoalManager.evaluate_after_turn: the judge, the gates, the turn budget, the waits); this only wraps it:

- The turn limit is a safety net, not a target: when a goal reaches it but has moved toward done in its
  last ``stall_turns`` turns, it gets ``extend_by`` more turns, up to ``max_turns_ceiling`` (config
  ``goals.extend_by`` 20, ``goals.max_turns_ceiling`` 500, ``goals.stall_turns`` 5).
- Progress is a count where one is known: a "Progress: file <path>" line in the goal (ticked ``[x]``
  boxes out of all boxes, or lines matching a pattern), a "Progress: command <cmd>" line (the N/M or the
  last number in its output), or a "Progress: N/M" line the agent writes in its reply. Without any count,
  the judge's own verdict on whether this turn moved the work closer to done is used.
- Stalled = no progress over ``stall_turns`` turns in a row: the goal pauses, and says why, with the count.
- Blocked only because the next step needs the person (a question, a [choices: ...] line, a yes) pauses as
  "waiting for you", not "unachievable"; One's connection resumes it when they answer (one_goals.py).
- A turn that ends only to wait for the goal's own delegated helpers parks the goal on them (the engine's
  wait barrier) instead of ending it as done or blocked; their results wake it.

What One shows (the count, the extension) is kept beside the goal in state_meta ``one-goal:<session>``.
"""
from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import threading
import time

logger = logging.getLogger("hermes_cli.one_goal_progress")

META = "one-goal:"
DEFAULTS = {"extend_by": 20, "max_turns_ceiling": 500, "stall_turns": 5}
BOUNDS = {"extend_by": (1, 500), "max_turns_ceiling": (1, 10000), "stall_turns": (2, 100)}
WAITING = "waiting for you: "
STALLED = "stalled: "
DELEGATION_WAIT_SECONDS = 1800
COMMAND_TIMEOUT = 60

# Added to the judge's instructions: two more fields in the same JSON reply.
JUDGE_EXTRA = (
    "\n\nAlso put these fields in the same JSON object: \"progress\": true when this response shows the work "
    "measurably moved closer to done than before this turn (items finished, more tests passing, a file or "
    "section written, a step completed), false when it only planned, repeated, re-checked, waited or got stuck; "
    "and with a blocked verdict, \"needs_user\": true when the only thing in the way is an answer, a choice or a "
    "yes from the user (the response asks them something), false when the goal itself cannot be done."
)

_local = threading.local()


# ---- settings ---------------------------------------------------------------------------------------------
def settings():
    try:
        from hermes_cli.config import load_config

        cfg = (load_config() or {}).get("goals") or {}
    except Exception:
        cfg = {}
    out = {}
    for k, d in DEFAULTS.items():
        try:
            v = int(cfg.get(k, d) or d)
        except (TypeError, ValueError):
            v = d
        lo, hi = BOUNDS[k]
        out[k] = max(lo, min(hi, v))
    return out


# ---- where a goal's progress is counted -----------------------------------------------------------------
_SPEC = re.compile(r"(?i)\bprogress(?:\s+is\s+counted)?\s*(?::|\s(?:in|by|from)\s)")
_CMD = re.compile(r"(?i)^(?:command|cmd|run|the\s+output\s+of)\s*:?\s*(.+)$")
_FILE = re.compile(r"(?i)^(`[^`]+`|\"[^\"]+\"|'[^']+'|\S+)(?:\s+(?:matching|pattern)\s+(.+))?$")
_PATHLIKE = re.compile(
    r"(?i)^(?:[~/]|\.{1,2}/)[^|;&<>]*$|^[\w.\-]+(?:/[\w.\-]+)*\.(?:md|markdown|txt|csv|todo|json|ya?ml)$|^[\w.\-]+/[^\s|;&<>]*$")
_REPLY = re.compile(r"(?im)^\W*progress\W*?\s*[:\-–]\s*\**\s*(\d[\d,]*)\s*(?:/|of|out\s+of)\s*(\d[\d,]*)")
_REPLY_ONE = re.compile(r"(?im)^\W*progress\W*?\s*[:\-–]\s*\**\s*(\d[\d,]*)\b(?!\s*(?:/|of|out\s+of))")
_FRACTION = re.compile(r"(\d[\d,]*)\s*(?:/|of|out\s+of)\s*(\d[\d,]*)")
_NUMBER = re.compile(r"\d[\d,]*")
_TICKED = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[[xX✓✔]\]")
_BOX = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+\[[ xX✓✔]\]")


def _unquote(s):
    s = s.strip()
    if len(s) > 1 and s[0] == s[-1] and s[0] in "`\"'":
        return s[1:-1].strip()
    return s


def _body(body):
    body = body.strip().rstrip(".;").strip()
    c = _CMD.match(body)
    if c:
        cmd = _unquote(c.group(1).strip().rstrip(".;"))
        return ("command", cmd, None) if cmd else None
    named = re.match(r"(?i)^(?:the\s+)?file\s*:?\s*", body)
    rest = body[named.end():] if named else body
    f = _FILE.match(rest)
    if f:
        first, quoted = _unquote(f.group(1)), f.group(1)[:1] in "`\"'"
        if _PATHLIKE.match(first):
            return ("file", first, _unquote(f.group(2)) if f.group(2) else None)
        if quoted and f.group(1)[0] == "`" and not named and not f.group(2):
            return ("command", first, None)  # a backticked command: `bin/rails test | tail -1`
    if rest[:1] in "/~" and _PATHLIKE.match(rest) and re.search(r"\.\w{1,8}$", rest):
        return ("file", rest, None)  # an unquoted path with spaces in it
    return None


def spec(goal):
    """``("file", path, pattern|None)``, ``("command", cmd, None)`` or None: where the goal says its progress is
    counted, on a line of its own or last on the goal's line: "Progress: file `docs/checklist.md`" (ticked [x]
    boxes out of all boxes), "Progress: file notes.md matching ^DONE" (matching lines), "Progress: command
    `bin/rails test | tail -1`" (the N/M or the last number in its output)."""
    for m in _SPEC.finditer(goal or ""):
        found = _body((goal[m.end():].split("\n", 1) or [""])[0])
        if found:
            return found
    return None


def _num(s):
    try:
        return int(str(s).replace(",", ""))
    except (TypeError, ValueError):
        return None


def _workspace():
    try:
        from hermes_cli.goals import _gate_workspace

        cwd, _ = _gate_workspace()
        return cwd
    except Exception:
        return None


def count_file(path, pattern=None, cwd=None):
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        p = os.path.join(cwd or _workspace() or os.getcwd(), p)
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None, None
    if pattern:
        try:
            rx = re.compile(pattern)
        except re.error:
            rx = re.compile(re.escape(pattern))
        return sum(1 for line in lines if rx.search(line)), None
    boxes = [line for line in lines if _BOX.match(line)]
    return sum(1 for line in boxes if _TICKED.match(line)), (len(boxes) or None)


def count_output(text):
    """N/M (the last one) or the last number in a command's output."""
    text = text or ""
    fr = _FRACTION.findall(text)
    if fr:
        return _num(fr[-1][0]), _num(fr[-1][1])
    nums = _NUMBER.findall(text)
    return (_num(nums[-1]), None) if nums else (None, None)


def count_command(cmd, cwd=None):
    try:
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=COMMAND_TIMEOUT, cwd=cwd or _workspace() or None, check=False)
    except Exception:
        return None, None
    return count_output(proc.stdout or proc.stderr)


def count_reply(text):
    """The agent's own "Progress: 15/282" (or "Progress: 15 of 282", "Progress: 37") line, the last one."""
    m = list(_REPLY.finditer(text or ""))
    if m:
        return _num(m[-1].group(1)), _num(m[-1].group(2))
    m = list(_REPLY_ONE.finditer(text or ""))
    return (_num(m[-1].group(1)), None) if m else (None, None)


def measure(goal, reply):
    """``(done, total, source)``: the goal's own count first (it can't be talked up), then the reply's line."""
    s = spec(goal)
    if s:
        done, total = count_file(s[1], s[2]) if s[0] == "file" else count_command(s[1])
        if done is not None:
            return done, total, s[0]
    done, total = count_reply(reply)
    if done is not None:
        return done, total, "reply"
    return None, None, None


# ---- the judge's two extra answers ------------------------------------------------------------------------
def judge_flags():
    """``(progress, needs_user)`` from the judge's last reply on this thread: True, False or None (not said)."""
    raw = getattr(_local, "raw", None)
    if not raw:
        return None, None
    data = None
    try:
        from hermes_cli.goals import _extract_json_object

        data = _extract_json_object(raw)
    except Exception:
        try:
            data = json.loads(raw)
        except Exception:
            data = None
    if not isinstance(data, dict):
        return None, None

    def flag(k):
        v = data.get(k)
        if isinstance(v, bool):
            return v
        if isinstance(v, str) and v.strip().lower() in ("true", "yes", "1", "false", "no", "0"):
            return v.strip().lower() in ("true", "yes", "1")
        return None

    return flag("progress"), flag("needs_user")


def asks_them(reply):
    """The reply asks the person something One shows as buttons (One's [choices: ...] line)."""
    return "[choices:" in (reply or "").lower()


# ---- what One keeps beside the goal ----------------------------------------------------------------------
def _db(goals):
    try:
        return goals._get_session_db()
    except Exception:
        return None


def load(goals, sid):
    db = _db(goals)
    if db is None:
        return {}
    try:
        raw = db.get_meta(META + sid)
        return json.loads(raw) if raw else {}
    except Exception:
        return {}


def save(goals, sid, rec):
    db = _db(goals)
    if db is not None:
        try:
            db.set_meta(META + sid, json.dumps(rec, ensure_ascii=False))
        except Exception:
            logger.debug("one goal progress: save failed", exc_info=True)


def fresh(state):
    return {"created_at": state.created_at, "seen": 0, "done": None, "total": None, "source": None, "best": None,
            "last_progress": 0, "streak": 0, "extended": 0, "extended_at": None, "extended_to": None,
            "ceiling": False, "stalled": False, "waiting": None}


def words(rec):
    if rec.get("done") is None:
        return ""
    return f"{rec['done']}/{rec['total']} done" if rec.get("total") else f"{rec['done']} done"


# ---- the wrap -------------------------------------------------------------------------------------------
def install(goals):
    """Wrap the engine's goal loop (idempotent). ``goals`` is the hermes_cli.goals module."""
    if getattr(goals, "_one_goal_progress", False):
        return
    mgr_cls = goals.GoalManager
    orig_eval, orig_judge, orig_call = mgr_cls.evaluate_after_turn, goals.judge_goal, goals._call_goal_judge_llm

    def _call_goal_judge_llm(call_llm, system_prompt, user_prompt, timeout):
        if isinstance(system_prompt, str) and system_prompt.startswith("You are a strict judge") and JUDGE_EXTRA not in system_prompt:
            system_prompt = system_prompt + JUDGE_EXTRA
        raw = orig_call(call_llm, system_prompt, user_prompt, timeout)
        _local.raw = raw
        return raw

    def judge_goal(goal, last_response, **kw):
        out = orig_judge(goal, last_response, **kw)
        verdict, reason = out[0], out[1]
        live = int(kw.get("active_delegations") or 0)
        _, needs_user = judge_flags()
        waiting = verdict == "blocked" and (needs_user is True or asks_them(last_response))
        if live > 0 and verdict in ("done", "blocked") and not waiting:
            # Its own helpers are still at work: what it has now is no verdict yet. Park on them (the
            # engine's barrier lifts as soon as one of them returns) instead of ending the goal.
            logger.info("one goal progress: %s with %d delegation(s) still running: parked on them", verdict, live)
            return ("wait", f"waiting on {live} of its own helper{'s' if live != 1 else ''} still at work ({reason})",
                    False, {"seconds": DELEGATION_WAIT_SECONDS}, False)
        return out

    def evaluate_after_turn(self, last_response, **kw):
        state = self._state
        if state is None or state.status != "active":
            return orig_eval(self, last_response, **kw)
        cfg = settings()
        sid = self.session_id
        rec = load(goals, sid)
        if rec.get("created_at") != state.created_at:
            rec = fresh(state)
        before, old_max = state.turns_used, state.max_turns
        bumped = None
        if before + 1 >= old_max and old_max < cfg["max_turns_ceiling"]:
            bumped = min(cfg["max_turns_ceiling"], old_max + cfg["extend_by"])
            state.max_turns = bumped  # tentative: kept only if the goal is still moving (below)
        _local.raw = None
        decision = orig_eval(self, last_response, **kw)
        state = self._state
        counted = state is not None and state.turns_used == before + 1
        if state is None or not counted:
            if bumped and state is not None and state.max_turns == bumped:
                state.max_turns = old_max
                self._save()
            return decision

        # This turn's progress.
        rec["seen"] = int(rec.get("seen") or 0) + 1
        done, total, source = measure(state.goal, last_response)
        flag, _ = judge_flags()
        if done is not None:
            moved = rec.get("best") is None or done > rec["best"]
            rec.update(done=done, total=total, source=source)
            if moved:
                rec["best"] = done
            known = True
        else:
            moved, known = flag is True, flag is not None
            if known and rec.get("done") is None:
                rec["source"] = "judge"  # a turn the judge didn't rate (its last, judged done) keeps what was known
        if moved:
            rec["last_progress"], rec["streak"] = rec["seen"], 0
        elif known and decision.get("verdict") not in ("wait", "waiting"):
            rec["streak"] = int(rec.get("streak") or 0) + 1
        rec["stalled"] = False
        rec["waiting"] = None
        recent = moved or (rec.get("last_progress") and rec["seen"] - rec["last_progress"] < cfg["stall_turns"])

        verdict = decision.get("verdict")
        if verdict == "blocked" and state.status == "paused":
            _, needs_user = judge_flags()
            if needs_user is True or asks_them(last_response):
                state.paused_reason = WAITING + (decision.get("reason") or "the next step needs your answer")
                self._save()
                rec["waiting"], rec["streak"] = time.time(), 0
                decision = dict(decision, message=f"⏸ Waiting for you: {decision.get('reason') or ''}".strip())

        cont = bool(decision.get("should_continue")) and state.status == "active"
        if cont and rec["streak"] >= cfg["stall_turns"]:
            if bumped and state.max_turns == bumped:
                state.max_turns = old_max
            n, count = rec["streak"], words(rec)
            rec.update(stalled=True, streak=0)
            save(goals, sid, rec)
            why = f"no progress in the last {n} turns" + (f" ({count})" if count else "")
            logger.info("one goal progress: %s stalled: %s", sid, why)
            return self._pause_decision(STALLED + why, verdict or "continue", decision.get("reason") or "",
                                        f"⏸ Goal paused — {why}. Use /goal resume to try again.")
        if bumped:
            if cont and recent:
                rec.update(extended=int(rec.get("extended") or 0) + 1, extended_at=rec["seen"], extended_to=bumped,
                           extended_by=bumped - old_max)
                self._save()
                count = words(rec)
                decision = dict(decision, message=f"↻ Goal still moving{' (' + count + ')' if count else ''}: "
                                                  f"{bumped - old_max} more turns, now {bumped}.")
                logger.info("one goal progress: %s extended to %d turns (%s)", sid, bumped, count or source or "judge")
            elif state.max_turns == bumped:
                state.max_turns = old_max
                if cont:
                    save(goals, sid, rec)
                    note = f", nothing moved in the last {cfg['stall_turns']} turns" if known and not recent else ""
                    note += f" ({words(rec)})" if words(rec) else ""
                    return self._budget_pause(state, verdict or "continue", decision.get("reason") or "", note=note)
                self._save()
        elif cont is False and state.status == "paused" and "budget" in (state.paused_reason or "") \
                and state.max_turns >= cfg["max_turns_ceiling"]:
            rec["ceiling"] = True
        save(goals, sid, rec)
        return decision

    mgr_cls.evaluate_after_turn = evaluate_after_turn
    goals.judge_goal = judge_goal
    goals._call_goal_judge_llm = _call_goal_judge_llm
    goals._one_goal_progress = True
