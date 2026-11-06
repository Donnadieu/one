"""Checks One's "keep going while it makes progress" overlay (tools/overlay/hermes_cli/one_goal_progress.py) on the
engine's REAL goal loop (the pinned Hermes's hermes_cli/goals.py, hooked by `One --apply-overlay`), with a stand-in
judge and an in-memory state store.

Run: python3 tools/goal-progress-check.py <engine folder whose hermes_cli/goals.py One hooked>
     (prints "goal progress ok" when every case passes; CI runs it in preflight)
Cases: more turns while the count moves, the ceiling, a stall pauses with the count, a question to them pauses as
"waiting for you" (a send's yes too), a goal that can't be done stays so, no count (the judge's own verdict), no
signal at all (the old turn limit), its own helpers still at work park the goal instead of ending it, a file or a
command the goal names is counted (and beats the reply's own number), the judge is asked for the two extra fields.
"""

import datetime
import importlib
import json
import os
import sys
import tempfile
import types

if not hasattr(datetime, "UTC"):  # the engine's goals.py wants Python 3.11's datetime.UTC; the Mac's python3 is older
    datetime.UTC = datetime.timezone.utc
ENGINE = os.path.abspath(sys.argv[1])
sys.path.insert(0, ENGINE)
tmp = tempfile.mkdtemp(prefix="one-goal-progress-")
fails = 0
failed = []


def check(name, ok, detail=""):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name + ("" if ok or not detail else f"  ({detail})"), flush=True)
    fails += 0 if ok else 1
    if not ok:
        failed.append(name + (f" ({detail})" if detail else ""))


# ---- stand-ins for the engine modules goals.py reaches for --------------------------------------------------------
def module(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    sys.modules[name] = m
    return m


import hermes_cli  # the engine's own package (its __init__ is all that's imported from it here)

CONFIG = {"goals": {"extend_by": 3, "max_turns_ceiling": 10, "stall_turns": 2}}
module("hermes_cli._subprocess_compat", noninteractive_git_env=lambda *a, **k: dict(os.environ))
module("hermes_cli.config", load_config=lambda: CONFIG)
module("hermes_time", safe_strftime=lambda dt, fmt: dt.strftime(fmt))
module("agent")


class Unavailable(Exception):
    pass


module("agent.auxiliary_unavailable", AuxiliaryClientUnavailable=Unavailable)
module("agent.runtime_cwd", resolve_agent_cwd=lambda: tmp, scoped_session_cwd=lambda: None)
JUDGE = {"reply": lambda last: {"verdict": "continue", "reason": "more to do"}}
SYSTEM = []


class _Msg:
    def __init__(self, content):
        self.message = types.SimpleNamespace(content=content)


def call_llm(task=None, messages=None, **kw):
    SYSTEM.append(messages[0]["content"])
    last = messages[-1]["content"]
    return types.SimpleNamespace(choices=[_Msg(json.dumps(JUDGE["reply"](last)))])


module("agent.auxiliary_client", call_llm=call_llm)

goals = importlib.import_module("hermes_cli.goals")
check("the engine's goal loop has One's progress overlay hooked in", getattr(goals, "_one_goal_progress", False) is True)
if not getattr(goals, "_one_goal_progress", False):
    print("goal progress: overlay not installed")
    sys.exit(1)
import hermes_cli.one_goal_progress as gp


class DB:
    def __init__(self):
        self.rows = {}

    def get_meta(self, k):
        return self.rows.get(k)

    def set_meta(self, k, v):
        self.rows[k] = v


db = DB()
goals._get_session_db = lambda: db
n = [0]


def new_goal(text, max_turns=4):
    n[0] += 1
    sid = f"s{n[0]}"
    goals.GoalManager(session_id=sid).set(text, max_turns=max_turns)
    return sid


def turn(sid, reply, **kw):
    mgr = goals.GoalManager(session_id=sid)  # a fresh manager every turn, as the gateway makes one
    return mgr.evaluate_after_turn(reply, **kw), goals.load_goal(sid)


def mine(sid):
    return json.loads(db.rows.get("one-goal:" + sid) or "{}")


def run(sid, replies, **kw):
    """Turns until the goal stops continuing (or the replies run out): (turns run, last decision, state)."""
    count, d, st = 0, None, None
    for r in replies:
        d, st = turn(sid, r, **kw)
        count += 1
        if not d.get("should_continue"):
            break
    return count, d, st


def counting(target, report=True):
    def judge(last):
        if f"{target} DONE" in last:
            return {"verdict": "done", "reason": "reached"}
        return {"verdict": "continue", "reason": "more to do", "progress": True}
    JUDGE["reply"] = judge
    return [f"{i}{' DONE' if i == target else ''}" + (f"\nProgress: {i}/{target}" if report else "") for i in range(1, 60)]


print("More turns while the count moves", flush=True)
s = new_goal("Count to 7, one number per turn.")
t, d, st = run(s, counting(7))
check("it ran past its limit of 4 and finished at 7", t == 7 and st.status == "done" and st.turns_used == 7, f"{t}, {st.status}, {st.turns_used}")
check("it was given 3 more turns once (4 -> 7)", st.max_turns == 7 and mine(s).get("extended") == 1, f"{st.max_turns}, {mine(s)}")
check("its count is kept for One", mine(s).get("done") == 7 and mine(s).get("total") == 7 and mine(s).get("source") == "reply")

print("The ceiling", flush=True)
s = new_goal("Count to 40, one number per turn.")
t, d, st = run(s, counting(40))
check("it stopped at the ceiling (10), still moving", t == 10 and st.status == "paused" and st.max_turns == 10
      and "budget" in (st.paused_reason or ""), f"{t}, {st.status}, {st.max_turns}, {st.paused_reason}")
check("and One knows it was the ceiling", mine(s).get("ceiling") is True)

print("A stall pauses, with the count", flush=True)
JUDGE["reply"] = lambda last: {"verdict": "continue", "reason": "more to do", "progress": True}
s = new_goal("Fix the tests.", max_turns=20)
t, d, st = run(s, ["Fixed some.\nProgress: 3/9"] * 10)
check("paused after 2 turns with no new progress (3 turns in all)", t == 3 and st.status == "paused", f"{t}, {st.status}")
check("and says why, with the count", (st.paused_reason or "") == "stalled: no progress in the last 2 turns (3/9 done)", st.paused_reason)
check("the count beats the judge's 'moving'", mine(s).get("stalled") is True)
d2, st2 = turn(s, "x")  # paused: nothing happens
goals.GoalManager(session_id=s).resume()
t, d, st = run(s, ["Fixed more.\nProgress: 5/9", "Progress: 5/9", "Progress: 5/9"])
check("a resume gets a fresh run before the next stall", t == 3 and (st.paused_reason or "").startswith("stalled"), f"{t}, {st.paused_reason}")

print("A question to them is waiting for them, not unachievable", flush=True)
JUDGE["reply"] = lambda last: {"verdict": "blocked", "reason": "it asked them to pick a design direction", "needs_user": True}
s = new_goal("Design and build the app.", max_turns=100)
d, st = turn(s, "Which direction do you want?")
check("paused as waiting for you", st.status == "paused" and (st.paused_reason or "").startswith("waiting for you: it asked them"), st.paused_reason)
check("and nothing carries on", not d.get("should_continue"))
JUDGE["reply"] = lambda last: {"verdict": "blocked", "reason": "it needs their yes to send the email"}
s = new_goal("Email the note to Bob.")
d, st = turn(s, "The note is ready. Sending it needs your yes.\n\n[choices: Yes, send it | Not now]")
check("a send asking for a yes (its [choices: ...] line) waits for them too", (st.paused_reason or "").startswith("waiting for you")
      and not d.get("should_continue"), st.paused_reason)
JUDGE["reply"] = lambda last: {"verdict": "blocked", "reason": "there is no such API", "needs_user": False}
s = new_goal("Use the Acme API.")
d, st = turn(s, "Acme has no public API, so this can't be done.")
check("a goal that truly can't be done still says so", (st.paused_reason or "").startswith("judged unachievable"), st.paused_reason)

print("No count: the judge's own verdict", flush=True)
s = new_goal("Write the essay.")
t, d, st = run(s, counting(6, report=False))
check("moving (by the judge) gets more turns", t == 6 and st.status == "done" and st.max_turns == 7, f"{t}, {st.status}, {st.max_turns}")
check("and is kept as the judge's", mine(s).get("source") == "judge" and mine(s).get("done") is None, str(mine(s)))
JUDGE["reply"] = lambda last: {"verdict": "continue", "reason": "still thinking", "progress": False}
s = new_goal("Write the essay.", max_turns=20)
t, d, st = run(s, ["Still thinking about it."] * 6)
check("not moving (by the judge) stalls", t == 2 and (st.paused_reason or "") == "stalled: no progress in the last 2 turns", f"{t}, {st.paused_reason}")
JUDGE["reply"] = lambda last: {"verdict": "continue", "reason": "more to do"}
s = new_goal("Write the essay.")
t, d, st = run(s, ["Some words."] * 8)
check("no signal at all keeps the old limit (no extension, no stall)", t == 4 and st.max_turns == 4 and "budget" in (st.paused_reason or ""),
      f"{t}, {st.max_turns}, {st.paused_reason}")

print("Its own helpers still at work", flush=True)
JUDGE["reply"] = lambda last: {"verdict": "done", "reason": "all parts were handed out"}
s = new_goal("Build all 8 parts.", max_turns=100)
d, st = turn(s, "All 8 builders are working. I'll merge each part as it reports back.", active_delegations=2)
check("a turn that ends to wait on them parks the goal, not done", st.status == "active" and st.last_verdict == "wait"
      and st.waiting_until > 0 and st.waiting_on_delegations == 2 and not d.get("should_continue"), f"{st.status}, {st.last_verdict}")
JUDGE["reply"] = lambda last: {"verdict": "blocked", "reason": "waiting on the builders"}
s = new_goal("Build all 8 parts.", max_turns=100)
d, st = turn(s, "Waiting on the builders.", active_delegations=1)
check("blocked on them parks it too", st.status == "active" and st.last_verdict == "wait", f"{st.status}, {st.last_verdict}")
JUDGE["reply"] = lambda last: {"verdict": "blocked", "reason": "it asked them", "needs_user": True}
s = new_goal("Build all 8 parts.", max_turns=100)
d, st = turn(s, "Which look? [choices: A | B]", active_delegations=1)
check("but a question to them still waits for them", (st.paused_reason or "").startswith("waiting for you"), st.paused_reason)

print("A count the goal names", flush=True)
box = os.path.join(tmp, "spec coverage.md")
cnt = os.path.join(tmp, "n.txt")


def ticks(done, total=5):
    with open(box, "w") as f:
        f.write("Status: `[ ]` not built, `[x]` built\n" + "".join(f"- [{'x' if i < done else ' '}] R-{i}\n" for i in range(total)))


JUDGE["reply"] = lambda last: {"verdict": "continue", "reason": "more to do", "progress": False}
s = new_goal(f"Build it.\nProgress: file `{box}`", max_turns=3)
t = 0
for i in range(1, 6):
    ticks(i)
    d, st = turn(s, "Progress: 999/999")
    t += 1
    if not d.get("should_continue"):
        break
check("a checklist file is counted (ticked boxes of all boxes), not the reply's number", mine(s).get("done") == 5
      and mine(s).get("total") == 5 and mine(s).get("source") == "file", str(mine(s)))
check("and its moving count beats the judge's 'not moving'", st.max_turns == 6 and st.status == "active", f"{st.max_turns}, {st.status}")
s = new_goal(f"Pass the tests. Progress: command `cat '{cnt}'`", max_turns=20)
for v in ("Tests passing: 12", "Tests passing: 12", "Tests passing: 12"):
    open(cnt, "w").write(v + "\n")
    d, st = turn(s, "working")
check("a command's output is counted", mine(s).get("done") == 12 and mine(s).get("source") == "command", str(mine(s)))
check("and a flat count stalls", (st.paused_reason or "").startswith("stalled: no progress in the last 2 turns (12 done)"), st.paused_reason)

print("What the judge is asked", flush=True)
check("the judge is asked whether the turn moved it and whether it needs them",
      bool(SYSTEM) and all(gp.JUDGE_EXTRA in x for x in SYSTEM) and '"needs_user"' in gp.JUDGE_EXTRA)
check("settings come from goals.* in config.yaml", gp.settings() == {"extend_by": 3, "max_turns_ceiling": 10, "stall_turns": 2})
CONFIG["goals"] = {}
check("with the defaults 20 more, a ceiling of 500, a stall after 5", gp.settings() == {"extend_by": 20, "max_turns_ceiling": 500, "stall_turns": 5})

print("goal progress ok" if fails == 0 else f"goal progress: {fails} failed: " + "; ".join(failed))
sys.exit(1 if fails else 0)
