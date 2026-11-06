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


def set_goal(sid, status, turns=0, reason=None):
    db.execute("insert or replace into state_meta values (?, ?)",
               ("goal:" + sid, json.dumps({"goal": "x", "status": status, "turns_used": turns, "max_turns": 20, "paused_reason": reason})))


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
        await asyncio.sleep(0.3)
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
    check("each later turn starts on a new paragraph", [x[1] for x in a._conn.sent].count("\n\n") == 2)

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


asyncio.run(main())
print("goal overlay ok" if fails == 0 else f"goal overlay: {fails} failed")
sys.exit(1 if fails else 0)
