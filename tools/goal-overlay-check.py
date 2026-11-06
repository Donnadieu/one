"""Checks One's standing-goals overlay (tools/overlay/acp_adapter/one_goals.py) on a stand-in connection.

Run: python3 tools/goal-overlay-check.py   (prints "goal overlay ok" when every case passes; CI runs it in preflight)
No engine here: a stand-in for the engine's GatewayACPAgent and a throwaway state.db carry the goal's state, so the
rules are checked on every pull request: the notes stay out of the goal, the yes rule is added, a prompt is held while
its goal is active and only then, Stop pauses the goal and stops its turn, a message reaches the running goal turn.
tools/goal-engine-check.sh runs the same overlay against the real engine (fresh-install workflow).
"""

import asyncio
import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import time
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
tmp = Path(tempfile.mkdtemp(prefix="one-goal-"))
os.environ["ONE_GOAL_IDLE"] = "1.5"

# Stand-ins for the engine modules the overlay imports.
acp = types.ModuleType("acp")
acp.update_agent_message_text = lambda t: {"text": t}
schema = types.ModuleType("acp.schema")


class PromptResponse:
    def __init__(self, stop_reason, usage=None):
        self.stop_reason, self.usage = stop_reason, usage


schema.PromptResponse = PromptResponse
acp.schema = schema
gc = types.ModuleType("acp_adapter.gateway_commands")
steered = []


async def _steer(agent, session_id, text):
    steered.append((session_id, agent._admissions.get(session_id), text))
    return "steered" if agent._admissions.get(session_id) else None


gc._steer = _steer
pkg = types.ModuleType("acp_adapter")
pkg.gateway_commands = gc
sys.modules.update({"acp": acp, "acp.schema": schema, "acp_adapter": pkg, "acp_adapter.gateway_commands": gc})
spec = importlib.util.spec_from_file_location("one_goals", HERE / "overlay/acp_adapter/one_goals.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


db = sqlite3.connect(tmp / "state.db", isolation_level=None)
db.execute("pragma journal_mode=wal")
db.execute("create table state_meta (key text primary key, value text)")


def set_goal(sid, status, turns=0, reason=None, max_turns=20, created=0.0, goal="x"):
    db.execute("insert or replace into state_meta values (?, ?)",
               ("goal:" + sid, json.dumps({"goal": goal, "status": status, "turns_used": turns, "max_turns": max_turns,
                                           "paused_reason": reason, "created_at": created})))


def row(sid):
    r = db.execute("select value from state_meta where key = ?", ("goal:" + sid,)).fetchone()
    return json.loads(r[0]) if r else {}


class Conn:
    def __init__(self):
        self.sent = []

    async def session_update(self, session_id, update):
        self.sent.append((session_id, update["text"]))


class Client:
    def __init__(self, agent):
        self.agent, self.calls = agent, []

    async def rpc(self, method, **kw):
        self.calls.append((method, kw))
        if method == "slash.exec" and kw.get("command") == "/goal pause":
            set_goal(kw["session_id"], "paused", reason="user-paused")
        return {}


class Agent:
    """The parts of GatewayACPAgent the overlay wraps or reads."""

    def __init__(self):
        self._home, self._aliases, self._conn, self._failure, self._admissions = tmp, {}, Conn(), None, {}
        self.client = Client(self)
        self.slash_seen, self.cancelled, self.cancelled_admissions = [], [], []
        self.next = ("end_turn", False)

    def _editor_id(self, sid):
        return sid

    async def _client(self):
        return self.client

    async def _cancel_admission(self, sid, aid):
        self.cancelled_admissions.append(aid)

    async def _project(self, event):
        pass

    async def _run_slash(self, held_id, session_id, text):
        self.slash_seen.append(text)
        if text.strip().startswith("/goal status") or text.strip() == "/goal pause":
            return True, None
        if text.startswith("/goal "):
            if getattr(self, "sets_goals", False):  # what the engine does: the goal set with the default limit
                set_goal(session_id, "active", goal=text[6:].split("\n")[0], created=time.time())
            return False, "KICKOFF"
        return False, text

    async def prompt(self, prompt, session_id, **kw):
        answered, text = await self._run_slash(session_id, session_id, prompt)
        self.submitted = text
        return PromptResponse(self.next[0])

    async def cancel(self, session_id, **kw):
        self.cancelled.append(session_id)


g.install(Agent)
check("installing twice changes nothing", (g.install(Agent), Agent._one_goals)[1])


async def event(a, sid, kind, aid, text=""):
    await a._project({"session_id": sid, "type": kind, "admission_id": aid, "payload": {"text": text}})


async def main():
    # 1. Notes, the yes rule.
    a = Agent()
    set_goal("s1", "done")
    await a.prompt("/goal Tidy my Downloads\n\n(One app note, not from the user: RULES)", "s1")
    check("the goal command reaches the engine without One's notes", a.slash_seen[-1].startswith("/goal Tidy my Downloads\nstop when:") and "RULES" not in a.slash_seen[-1])
    check("the yes rule is added to the goal (the engine's stop-when line)", "their yes" in a.slash_seen[-1])
    check("the first turn gets the yes rule and the notes", a.submitted.startswith("KICKOFF") and "STANDING GOAL" in a.submitted and a.submitted.endswith("RULES)"))
    check("control commands are left alone", g.with_safety("/goal pause") == "/goal pause" and g.with_safety("/goal resume") == "/goal resume" and g.with_safety("/goal stop") == "/goal stop")
    check("a goal that says when to stop keeps its own words", g.with_safety("/goal x\nstop when: I say so") == "/goal x\nstop when: I say so")
    check("ordinary messages pass untouched", g.split_notes("hello\n\n(One app note, x)") == ("hello\n\n(One app note, x)", ""))

    # 2. Held while the goal works, returns when it's done; each new turn on its own paragraph.
    a = Agent()
    set_goal("s2", "active")
    async def goal_runs():
        await event(a, "s2", "message.delta", "t1", "one")  # the first turn's words, then the next turn at once
        await event(a, "s2", "message.complete", "t1")
        await event(a, "s2", "message.delta", "t2", "two")
        await event(a, "s2", "message.complete", "t2")
        set_goal("s2", "active", 1)
        await asyncio.sleep(0.6)
        await event(a, "s2", "message.delta", "t3", "three")
        await event(a, "s2", "message.complete", "t3")
        set_goal("s2", "done", 2)
    t = time.time()
    r, _ = await asyncio.gather(a.prompt("/goal count", "s2"), goal_runs())
    check("held until the goal was done", r.stop_reason == "end_turn" and time.time() - t >= 0.9)
    check("each later turn starts on a new paragraph, even one that starts before the hold", [x[1] for x in a._conn.sent].count("\n\n") == 2)

    # 3. Budget used: the goal is paused by the engine, the prompt returns.
    a = Agent()
    set_goal("s3", "active", 3)
    async def budget():
        await asyncio.sleep(0.4)
        set_goal("s3", "paused", 20, "turn budget exhausted (20/20)")
    r, _ = await asyncio.gather(a.prompt("/goal count", "s3"), budget())
    check("returns when the budget is used", r.stop_reason == "end_turn")

    # 4. Stop while the goal works: the goal is paused first, its running turn cancelled, the prompt says stopped.
    a = Agent()
    set_goal("s4", "active")
    async def stop():
        await asyncio.sleep(0.3)
        await event(a, "s4", "message.delta", "t5", "five")
        await a.cancel("s4")
    r, _ = await asyncio.gather(a.prompt("/goal count", "s4"), stop())
    check("Stop ends the prompt as stopped", r.stop_reason == "cancelled")
    check("Stop pauses the goal in the engine", ("slash.exec", {"session_id": "s4", "command": "/goal pause"}) in a.client.calls)
    check("and cancels the goal's running turn", "t5" in a.cancelled_admissions)
    check("the engine's own cancel still runs", "s4" in a.cancelled)

    # 5. Stop before the first turn ended (not held yet): an active goal is still paused.
    a = Agent()
    set_goal("s5", "active")
    await a.cancel("s5")
    check("Stop pauses an active goal even before its first turn ended", ("slash.exec", {"session_id": "s5", "command": "/goal pause"}) in a.client.calls)
    set_goal("s6", "done")
    await a.cancel("s6")
    check("Stop with no goal at work only cancels", all(c[1].get("session_id") != "s6" for c in a.client.calls))

    # 6. A command answered without a turn is never held, even with a goal at work.
    a = Agent()
    set_goal("s7", "active")
    t = time.time()
    r = await a.prompt("/goal status", "s7")
    check("/goal status is answered at once", r.stop_reason == "end_turn" and time.time() - t < 0.5)

    # 7. No goal: nothing changes.
    a = Agent()
    t = time.time()
    r = await a.prompt("hello", "nogoal")
    check("a message with no goal returns as before", r.stop_reason == "end_turn" and time.time() - t < 0.5)

    # 8. A goal that goes quiet (waiting on something) doesn't hold One forever.
    a = Agent()
    set_goal("s8", "active")
    t = time.time()
    r = await a.prompt("/goal wait for it", "s8")
    check("a quiet goal lets the prompt go after a while", r.stop_reason == "end_turn" and 1.4 < time.time() - t < 6)

    # 9. A message sent while the goal works goes into its running turn.
    a = Agent()
    set_goal("s9", "active")
    async def steer():
        await asyncio.sleep(0.3)
        await event(a, "s9", "message.delta", "t9", "nine")
        said = await gc._steer(a, "s9", "make it Dec 21")
        await event(a, "s9", "message.complete", "t9")
        set_goal("s9", "done", 1)
        return said
    _, said = await asyncio.gather(a.prompt("/goal count", "s9"), steer())
    check("a message mid-goal reaches the turn at work", said == "steered" and steered[-1] == ("s9", "t9", "make it Dec 21"))
    check("and leaves no stale turn behind", "s9" not in a._admissions)

    # 10. A goal's own turn limit: each way of writing it, the bounds, no number = the default.
    P = g.parse_limit
    check("\"/goal 50 turns: <goal>\" carries 50", P("/goal 50 turns: Find a flight") == ("set", "/goal Find a flight", 50, 50))
    check("\"/goal --turns 50 <goal>\" too", P("/goal --turns 50 Find a flight") == ("set", "/goal Find a flight", 50, 50)
          and P("/goal --turns=50 Find a flight")[2] == 50)
    check("and plain words (\"up to 50 tries:\")", P("/goal up to 50 tries: Find a flight") == ("set", "/goal Find a flight", 50, 50))
    check("a goal that only starts with a number is just a goal", P("/goal 3 kids' lunches packed")[0] is None
          and P("/goal 10 rounds of edits on the essay")[0] is None)
    check("\"/goal turns 50\" changes the limit", P("/goal turns 50")[:3] == ("change", "/goal turns 50", 50)
          and P("/goal 30 turns")[2] == 30 and P("/goal turns: 7")[2] == 7)
    check("more than 200 is capped at 200", P("/goal 500 turns: x")[2:] == (200, 500) and P("/goal turns 9999")[2] == 200)
    check("less than 1 becomes 1", P("/goal 0 turns: x")[2] == 1)
    check("controls and plain goals have no limit", P("/goal pause")[0] is None and P("/goal Tidy")[0] is None)

    a = Agent()
    a.sets_goals = True
    answered, submit = await a._run_slash("h10", "s10", "/goal 50 turns: Find a flight\n\n(One app note, not from the user: RULES)")
    r10 = row("s10")
    check("the engine sets the goal without the number in it", a.slash_seen[-1].startswith("/goal Find a flight\nstop when:") and r10.get("goal") == "Find a flight")
    check("and it gets its own limit", r10.get("max_turns") == 50 and not answered and submit.startswith("KICKOFF"))
    check("a limit asked for in range isn't remarked on", not [t for _, t in a._conn.sent if "at most" in t])
    await a._run_slash("h11", "s11", "/goal 500 turns: Find a flight")
    check("a capped number gets 200", row("s11").get("max_turns") == 200)
    check("and the reply says so plainly, first", any(sid == "h11" and t.startswith("A goal can take at most 200 turns") for sid, t in a._conn.sent))
    await a._run_slash("h12", "s12", "/goal Find a flight")
    check("no number = the engine's default limit", row("s12").get("max_turns") == 20 and row("s12").get("goal") == "Find a flight")

    # 11. Changing the limit of the goal here: answered at once, never a turn or a new goal.
    a = Agent()
    set_goal("s13", "active", turns=3, created=111.0, goal="Plan")
    t = time.time()
    r = await a.prompt("/goal turns 30", "s13")
    check("/goal turns 30 is answered at once", r.stop_reason == "end_turn" and time.time() - t < 0.5)
    check("the goal keeps everything and gets 30", row("s13").get("max_turns") == 30 and row("s13").get("turns_used") == 3 and row("s13").get("goal") == "Plan")
    check("it never reached the engine as a goal", not a.slash_seen)
    check("its answer is the notice One keeps off the screen", a._conn.sent[-1][1].startswith(g.LIMIT_NOTICE + ": 30 turns"))
    set_goal("s14", "paused", turns=20, reason="turn budget exhausted (20/20)", created=5.0)
    await a.prompt("/goal turns 40", "s14")
    check("a paused goal's limit changes too (for its resume)", row("s14").get("max_turns") == 40 and row("s14").get("status") == "paused")
    await a.prompt("/goal turns 40", "s15")
    check("no goal: nothing is made up", row("s15") == {} and a._conn.sent[-1][1].startswith(g.LIMIT_NOTICE + ": no goal"))

    # 12. Mid-goal: a judge that loaded the goal before the change and saves the old limit back loses to the new one.
    a = Agent()
    set_goal("s16", "active", created=222.0)
    async def mid():
        await asyncio.sleep(0.3)
        await event(a, "s16", "message.delta", "t16", "one")
        r = await a.prompt("/goal turns 60", "s16")  # beside the goal's turn, like One's steer
        set_goal("s16", "active", turns=1, max_turns=20, created=222.0)  # the stale save
        await asyncio.sleep(1.0)
        fixed = row("s16").get("max_turns")
        await event(a, "s16", "message.complete", "t16")
        set_goal("s16", "done", turns=2, max_turns=60, created=222.0)
        return r.stop_reason, fixed
    held, (quick, fixed) = await asyncio.gather(a.prompt("/goal count", "s16"), mid())
    check("a change mid-goal is answered while the goal works", quick == "end_turn" and held.stop_reason == "end_turn")
    check("and holds against a stale save", fixed == 60)


asyncio.run(main())
print("goal overlay ok" if fails == 0 else f"goal overlay: {fails} failed")
sys.exit(1 if fails else 0)
