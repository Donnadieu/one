"""One: a standing goal (/goal) keeps One's prompt open for all of the goal's turns.

Added by One (copied into the engine's acp_adapter/ by Installer.applyGoals, hooked at the end of
gateway_server.py). The goal loop is the engine's own (hermes_cli/goals.py, run by the gateway after every
turn: the judge, the turn budget, the auto-pause); this file only makes One's connection wait for it, so a
goal looks like one long reply in One and every safety rule One has for a reply still applies:
- a prompt whose conversation has an active goal returns only once the goal stops being active (done,
  blocked, paused, budget used up, cleared) or nothing has happened on it for a while (the goal is waiting);
- each new turn of the goal starts on a new paragraph;
- "/goal <objective>" followed by One's app notes: the notes go with the first turn, never into the goal text;
- a message sent into the conversation while the goal runs reaches the turn that is running (steer);
- One's Stop (session/cancel) pauses the goal and stops the turn running for it, also before the first turn
  ends (an active goal is always paused by Stop, so nothing carries on by itself);
- a goal may carry its own turn limit ("/goal 50 turns: <goal>", "/goal --turns 50 <goal>"), passed to the
  engine's own GoalManager.set(max_turns=...), kept between 1 and 200 (a capped number says so in the reply);
  "/goal turns 50" changes the limit of the goal here, without a turn. No number = the engine's default.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sqlite3
import time

logger = logging.getLogger("acp_adapter.one_goals")

MARK = "\n\n(One app note"
# After a turn the judge runs (30 s time limit by default) and then the next turn starts; quality gates may take
# their own time limit on top. Nothing at all happening for this long means the goal is waiting on something.
IDLE_SECONDS = float(os.environ.get("ONE_GOAL_IDLE", "120"))
POLL_SECONDS = 0.5


def goal_state(home, session_id):
    """The goal row the gateway keeps for this conversation (``state_meta`` ``goal:<id>``), read only; None if none."""
    path = os.path.join(str(home), "state.db")
    if not os.path.exists(path):
        return None
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute("select value from state_meta where key = ?", (f"goal:{session_id}",)).fetchone()
        finally:
            con.close()
        return json.loads(row[0]) if row and row[0] else None
    except Exception:  # never break a reply over a read
        logger.debug("goal state unreadable", exc_info=True)
        return None


def is_active(state):
    return bool(state) and state.get("status") == "active"


def split_notes(text):
    """``(command, notes)``: a /goal command with One's app notes after it, or ``(text, "")``."""
    head, sep, tail = text.partition(MARK)
    first = head.lstrip().split(None, 1)
    if sep and first and first[0].lower() == "/goal":
        return head.rstrip(), sep + tail
    return text, ""


# Added to every goal One sets (the engine's own completion-contract line, read by its judge and by every
# continuation prompt): a step that needs their yes ends the loop instead of being taken by the next turn.
SAFETY = ("stop when: the next step needs their yes (sending, posting, spending money or deleting anything) or a "
          "choice only they can make: ask once in plain words, ending with a [choices: ...] line, and stop there")

RULE = ("\n\n(One app note, not from the user: STANDING GOAL. Sending, posting, spending money and deleting still need "
        "their yes inside a goal: before that step, ask once in plain words ending with a [choices: ...] line, and stop.)")


def with_safety(command):
    """A ``/goal <objective>`` that sets a goal gets the stop-when line (unless it has one); anything else is unchanged."""
    parts = command.strip().split(None, 1)
    if len(parts) < 2 or parts[0].lower() != "/goal":
        return command
    arg = parts[1]
    try:
        from hermes_cli.goal_command import is_goal_control
        control = is_goal_control(arg)
    except Exception:
        control = False
    first = arg.split(None, 1)[0].lower()
    controls = ("status", "show", "pause", "resume", "continue", "unpause", "unwait", "clear", "stop", "done", "draft", "gate", "wait")
    if control or first in controls or "stop when" in arg.lower():
        return command
    return command.rstrip() + "\n" + SAFETY


# ---- a goal's own turn limit --------------------------------------------------------------------------------
MIN_TURNS, MAX_TURNS = 1, 200
# The answer to "/goal turns N": One keeps it off the screen (Goals.isNotice) and answers in its own words.
LIMIT_NOTICE = "⊙ Goal limit"
_SET_LIMIT = re.compile(r"^(?:up\s+to\s+)?(\d{1,12})\s*(?:turns?|tries|try|rounds?)\s*[:,]\s*(\S.*)$", re.I | re.S)
_FLAG_LIMIT = re.compile(r"^--(?:max-)?turns(?:\s*=\s*|\s+)(\d{1,12})\s+(\S.*)$", re.I | re.S)
_CHANGE_LIMIT = re.compile(r"^(?:turns?|max[-_ ]?turns|limit)\s*[:=]?\s*(\d{1,12})(?:\s*turns?)?$|^(\d{1,12})\s*turns?$", re.I)


def clamp(n):
    return max(MIN_TURNS, min(MAX_TURNS, int(n)))


def parse_limit(command):
    """``(kind, command, turns, asked)``. kind "set": a new goal with its own limit (command = the /goal line without
    it); "change": a new limit for the goal here; None: no limit in it (the engine's default applies)."""
    parts = (command or "").strip().split(None, 1)
    if len(parts) < 2 or parts[0].lower() != "/goal":
        return None, command, None, None
    arg = parts[1].strip()
    m = _CHANGE_LIMIT.match(arg)
    if m:
        asked = int(m.group(1) or m.group(2))
        return "change", command, clamp(asked), asked
    m = _SET_LIMIT.match(arg) or _FLAG_LIMIT.match(arg)
    if m:
        asked = int(m.group(1))
        return "set", "/goal " + m.group(2).strip(), clamp(asked), asked
    return None, command, None, None


def capped_words(asked, turns):
    """The plain line a capped number gets at the start of the reply ("" when it wasn't capped)."""
    if asked is None or asked == turns:
        return ""
    if turns == MAX_TURNS:
        return f"A goal can take at most {MAX_TURNS} turns, so this one has {MAX_TURNS}."
    return f"A goal needs at least {MIN_TURNS} turn, so this one has {MIN_TURNS}."


def set_limit(home, session_id, turns, fresh=False):
    """The goal's own turn limit, through the engine's GoalManager: ``fresh`` (the goal was just set) re-sets it with
    ``GoalManager.set(goal, max_turns=..., contract=...)``; otherwise the goal at work (active or paused) keeps
    everything and gets the new limit. Falls back to the row itself if the manager wrote elsewhere. Returns the row."""
    try:
        from hermes_cli import goals as engine_goals
        mgr = engine_goals.GoalManager(session_id=session_id)
        st = mgr.state
        if st is not None and st.status in ("active", "paused"):
            if fresh:
                mgr.set(st.goal, max_turns=turns, contract=st.contract)
            else:
                st.max_turns = turns
                engine_goals.save_goal(session_id, st)
    except Exception:
        logger.debug("one goals: GoalManager limit write failed", exc_info=True)
    state = goal_state(home, session_id)
    if state and state.get("status") in ("active", "paused") and state.get("max_turns") != turns:
        try:
            con = sqlite3.connect(os.path.join(str(home), "state.db"), timeout=5)
            try:
                state["max_turns"] = turns
                con.execute("update state_meta set value = ? where key = ?", (json.dumps(state), f"goal:{session_id}"))
                con.commit()
            finally:
                con.close()
        except Exception:
            logger.warning("one goals: couldn't set the turn limit of %s", session_id, exc_info=True)
        state = goal_state(home, session_id)
    return state


class _Watch:
    """What one conversation's events show: the turns (admissions) seen, which ended, when anything last happened."""

    def __init__(self):
        self.turns, self.ended = [], set()
        self.last = time.monotonic()
        self.holding = 0
        self.cancelled = False
        self.inflight = 0  # One's prompts open on this conversation
        self.writer = None  # the turn that wrote last
        self.verdicts = []
        self.pin = None  # (the goal's created_at, its own turn limit): kept even if a judge's save lands after it

    def running(self):
        return [a for a in self.turns if a not in self.ended]


def install(cls):
    """Patch ``GatewayACPAgent`` (idempotent)."""
    if getattr(cls, "_one_goals", False):
        return
    import acp
    from acp.schema import PromptResponse

    orig_prompt, orig_project, orig_slash, orig_cancel = cls.prompt, cls._project, cls._run_slash, cls.cancel

    def watch(self, sid):
        w = self.__dict__.setdefault("_one_goal_watch", {})
        return w.setdefault(sid, _Watch())

    async def _project(self, event):
        sid, aid, kind = event.get("session_id"), event.get("admission_id"), event.get("type")
        if sid:
            w = watch(self, sid)
            w.last = time.monotonic()
            if aid and kind in ("message.delta", "message.interim", "tool.start", "message.complete") and aid not in w.turns:
                w.turns.append(aid)
                del w.turns[:-64]
            # A new turn writing while One's prompt is open (a goal's next turn): its words start on a new paragraph.
            # Keyed on who wrote last, not on the hold: the next turn can start before the hold begins.
            if aid and kind in ("message.delta", "message.interim") and (event.get("payload") or {}).get("text"):
                if w.inflight and w.writer and w.writer != aid and self._conn:
                    await self._conn.session_update(session_id=self._editor_id(sid),
                                                    update=acp.update_agent_message_text("\n\n"))
                w.writer = aid
            if kind == "message.complete" and aid:
                w.ended.add(aid)
            if kind == "status.update" and (event.get("payload") or {}).get("kind") == "goal":
                w.verdicts.append(str((event.get("payload") or {}).get("text") or ""))
                del w.verdicts[:-8]
        return await orig_project(self, event)

    async def say(self, held_id, words):
        if words and self._conn:
            await self._conn.session_update(session_id=held_id, update=acp.update_agent_message_text(words))

    async def change_limit(self, sid, turns):
        state = await asyncio.to_thread(goal_state, self._home, sid)
        if not state or state.get("status") not in ("active", "paused"):
            return f"{LIMIT_NOTICE}: no goal here\n"
        after = await asyncio.to_thread(set_limit, self._home, sid, turns)
        watch(self, sid).pin = ((after or {}).get("created_at"), turns)
        logger.info("one goals: %s turn limit now %s", sid, turns)
        return f"{LIMIT_NOTICE}: {(after or {}).get('max_turns')} turns\n"

    async def _run_slash(self, held_id, session_id, text):
        command, notes = split_notes(text or "")
        kind, command, turns, asked = parse_limit(command)
        sid = self._aliases.get(session_id, session_id)
        if kind == "change":  # "/goal turns 50": answered here, never a turn, never a new goal
            await say(self, held_id, await change_limit(self, sid, turns))
            self.__dict__.setdefault("_one_answered", set()).add(asyncio.current_task())
            return True, None
        safe = with_safety(command)
        answered, submit = await orig_slash(self, held_id, session_id, safe)
        if not answered and submit is not None and kind == "set":
            after = await asyncio.to_thread(set_limit, self._home, sid, turns, True)
            watch(self, sid).pin = ((after or {}).get("created_at"), turns)
            logger.info("one goals: %s goal set with its own limit of %s turns", sid, turns)
            await say(self, held_id, (capped_words(asked, turns) + "\n\n") if capped_words(asked, turns) else "")
        if not answered and submit is not None:
            if safe != command:
                submit += RULE  # the goal's first turn gets the same rule its judge and later turns get
            submit += notes  # One's notes go with the goal's first turn, never into the goal itself
        if answered:  # a command answered without a turn (/goal status, a steer taken): its prompt is never held
            self.__dict__.setdefault("_one_answered", set()).add(asyncio.current_task())
        return answered, submit

    async def prompt(self, prompt, session_id, **kwargs):
        sid = self._aliases.get(session_id, session_id)
        w = watch(self, sid)
        if not w.holding:
            w.cancelled = False
            w.writer = None
        w.inflight += 1
        try:
            return await held_prompt(self, prompt, session_id, sid, w, **kwargs)
        finally:
            w.inflight -= 1

    async def held_prompt(self, prompt, session_id, sid, w, **kwargs):
        resp = await orig_prompt(self, prompt, session_id, **kwargs)
        answered = self.__dict__.get("_one_answered", set())
        if asyncio.current_task() in answered:
            answered.discard(asyncio.current_task())
            return resp
        if getattr(resp, "stop_reason", None) != "end_turn" or w.cancelled:
            return resp
        if not is_active(await asyncio.to_thread(goal_state, self._home, sid)):
            return resp
        w.holding += 1
        try:
            stop = await hold(self, sid, w)
        finally:
            w.holding -= 1
        return PromptResponse(stop_reason=stop, usage=getattr(resp, "usage", None))

    async def hold(self, sid, w):
        """Wait while the engine's goal loop works on this conversation. "cancelled" when Stop ended it."""
        turns, began = None, time.monotonic()
        w.last = time.monotonic()
        logger.info("one goals: holding %s for its goal", sid)
        while not w.cancelled and getattr(self, "_failure", None) is None:
            state = await asyncio.to_thread(goal_state, self._home, sid)
            if not is_active(state):
                logger.info("one goals: %s goal %s after %.0f s", sid, (state or {}).get("status"), time.monotonic() - began)
                break
            pin = w.pin
            if pin and pin[0] == state.get("created_at") and state.get("max_turns") != pin[1]:
                # A judge that loaded the goal before "/goal turns N" saved its old limit back: the asked one wins.
                await asyncio.to_thread(set_limit, self._home, sid, pin[1])
            if state.get("turns_used") != turns:
                turns = state.get("turns_used")
                w.last = time.monotonic()
            if w.running():
                w.last = time.monotonic()
            idle = IDLE_SECONDS + sum(float(g.get("timeout_seconds") or 0) for g in state.get("gates") or [])
            if time.monotonic() - w.last > idle:
                logger.info("one goals: %s goal still active but idle %.0f s: answering now", sid, idle)
                break
            await asyncio.sleep(POLL_SECONDS)
        return "cancelled" if w.cancelled else "end_turn"

    async def pause_goal(self, sid):
        try:
            client = await self._client()
            await client.rpc("slash.exec", session_id=sid, command="/goal pause")
            logger.info("one goals: %s goal paused by Stop", sid)
        except Exception:
            logger.warning("one goals: couldn't pause the goal of %s", sid, exc_info=True)

    async def cancel(self, session_id, **kwargs):
        sid = self._aliases.get(session_id, session_id)
        w = watch(self, sid)
        active = is_active(await asyncio.to_thread(goal_state, self._home, sid))
        if active:
            w.cancelled = True
            await pause_goal(self, sid)  # first, so no next turn is chained after the one stopped below
        try:
            await orig_cancel(self, session_id, **kwargs)
        finally:
            if active:
                for aid in w.running():  # the goal's own turns aren't ours to cancel the usual way
                    try:
                        await self._cancel_admission(sid, aid)
                    except Exception:
                        logger.debug("one goals: cancel of %s skipped", aid, exc_info=True)

    cls.prompt, cls._project, cls._run_slash, cls.cancel = prompt, _project, _run_slash, cancel
    cls._one_goals = True

    # A message sent while the goal works reaches the turn running for it (the goal's turns aren't ours, so the
    # engine's /steer would otherwise queue it behind the whole goal).
    from acp_adapter import gateway_commands as gc
    orig_steer = gc._steer

    async def _steer(agent, session_id, text):
        w = getattr(agent, "_one_goal_watch", {}).get(session_id)
        running = w.running() if w and w.holding else []
        if agent._admissions.get(session_id) is None and running:
            agent._admissions[session_id] = running[-1]
            try:
                return await orig_steer(agent, session_id, text)
            finally:
                if agent._admissions.get(session_id) == running[-1]:
                    agent._admissions.pop(session_id, None)
        return await orig_steer(agent, session_id, text)

    gc._steer = _steer
