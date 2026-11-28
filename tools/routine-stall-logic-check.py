"""Checks One's routine stall overlay (tools/overlay/cron/one_routine_stall.py) on its own, no engine needed.

Run: python3 tools/routine-stall-logic-check.py      prints "routine stall logic ok" (CI runs it in preflight)
The real engine with a stand-in model is tools/routine-stall-check.py (fresh-install workflow). This one pins the
decisions: which ended turns are picked back up (a lapsed lease, retries run out on an unreachable AI) and which never
are (a person's Stop, a gateway restart, a rate limit, a billing wall, a cancelled run); what the retry sends (the
turn's own request again, or the work so far plus "carry on"); the stall cap (routines and their helpers only,
streamed replies only); the wait for the AI's address; and the scheduler wrapper (same turn, its history, at most
ONE_ROUTINE_TURN_RETRIES times, nothing when the address never answers).
"""

import importlib.util
import logging
import os
import socket
import sys
import threading
import types
import weakref

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("one_routine_stall", os.path.join(HERE, "overlay/cron/one_routine_stall.py"))
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)
logging.getLogger("cron.scheduler").addHandler(logging.NullHandler())  # its log lines are not the result
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name + ("" if ok or not detail else f"  ({detail})"), flush=True)
    fails += 0 if ok else 1


failed = lambda **k: dict({"failed": True, "completed": False}, **k)  # noqa: E731

# ---- which ended turns are picked back up -------------------------------------------------------------------------
check("a lease that lapsed while the Mac slept (Nov 25, 27)",
      rs.should_retry(failed(turn_exit_reason="interrupted_during_api_call(session_turn_lease_lost)",
                             final_response="Operation interrupted: waiting for model response (661.2s elapsed).")))
check("the turn liveness watchdog", rs.should_retry(failed(turn_exit_reason="interrupted_during_api_call(turn_liveness_watchdog)")))
check("the engine's retries ran out on a dead connection", rs.should_retry(failed(failure_reason="timeout", error="Connection error.")))
check("the AI never answered at all", rs.should_retry(failed(turn_exit_reason="all_retries_exhausted_no_response")))
check("an unclassified 'can't reach the model provider'", rs.should_retry(failed(error="Hermes can't reach the model provider.")))
check("never a person's Stop", not rs.should_retry(failed(turn_exit_reason="interrupted_during_api_call")))
check("never a person's Stop between steps", not rs.should_retry(failed(turn_exit_reason="interrupted_by_user")))
check("never a gateway restart", not rs.should_retry(failed(turn_exit_reason="interrupted_during_api_call(gateway_shutdown)")))
check("never a rate limit", not rs.should_retry(failed(failure_reason="rate_limit", error="timed out")))
check("never a billing wall", not rs.should_retry(failed(failure_reason="billing", billing_block=("anthropic",))))
check("never the step limit", not rs.should_retry(failed(turn_exit_reason="max_iterations_reached(8/8)", error="timed out")))
check("never a finished turn", not rs.should_retry({"completed": True, "final_response": "done"}))
stop = threading.Event()
stop.set()
check("never a cancelled run", not rs.should_retry(failed(failure_reason="timeout"), stop))

# ---- what the retry sends -----------------------------------------------------------------------------------------
work = [{"role": "user", "content": "Upload it"}, {"role": "assistant", "content": "", "tool_calls": [{"id": "t1"}]},
        {"role": "tool", "tool_call_id": "t1", "content": "uploaded"}]
history, msg = rs.continuation({"messages": work + [{"role": "assistant", "content": "Operation interrupted: waiting"}]}, "Upload it")
check("work so far is the history (the engine's interrupted note dropped), and it is told to carry on",
      history == work and msg == rs.CONTINUE)
history, msg = rs.continuation({"messages": [{"role": "user", "content": "Upload it"}]}, "Upload it")
check("a turn the model never answered sends its own request again, with no history", history is None and msg == "Upload it")
history, msg = rs.continuation({"messages": work + [{"role": "user", "content": "And post it"}]}, "x")
check("a later request the model never answered is sent again after the work so far", history == work and msg == "And post it")
check("no messages: the prompt again", rs.continuation({}, "Upload it") == (None, "Upload it"))

# ---- the stall cap ---------------------------------------------------------------------------------------------------
os.environ["ONE_ROUTINE_STALL_SECONDS"] = "240"
cron, chat = types.SimpleNamespace(platform="cron"), types.SimpleNamespace(platform="acp")


class Helper:  # a helper a routine started (delegate_tool keeps a weakref to its parent)
    platform = "subagent"


helper = Helper()
helper._delegate_parent_ref = weakref.ref(Helper())  # a dead parent: not a routine
check("a routine's 900s stall patience becomes 240s", rs.capped(cron, 900.0) == 240.0)
check("a shorter one stays", rs.capped(cron, 180.0) == 180.0)
check("a chat's is never touched", rs.capped(chat, 900.0) == 900.0)
check("nor a helper with no routine above it", rs.capped(helper, 900.0) == 900.0)
parent = types.SimpleNamespace(platform="cron")


class Child:
    platform = "subagent"


child = Child()
child._delegate_parent_ref = lambda: parent
check("a routine's own helper is capped too", rs.capped(child, 900.0) == 240.0)
check("a disarmed timer (None) stays disarmed", rs.capped(cron, None) is None)
os.environ["ONE_ROUTINE_STALL_SECONDS"] = "nonsense"
check("a bad setting falls back to 240s", rs.stall_seconds() == 240.0)

# ---- the wait for the AI ---------------------------------------------------------------------------------------------
listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(5)
port = listener.getsockname()[1]
os.environ["ONE_ROUTINE_REACH_POLL_SECONDS"] = "0.1"
os.environ["ONE_ROUTINE_REACH_WAIT_SECONDS"] = "0.5"
up = types.SimpleNamespace(base_url=f"http://127.0.0.1:{port}/v1")
check("an address that answers: no wait", rs.wait_until_reachable(up, {"id": "j"}, types.SimpleNamespace()))
listener.close()
check("one that never does: gives up at the limit", not rs.wait_until_reachable(up, {"id": "j"}, types.SimpleNamespace()))
check("https without a port means 443", rs._address(types.SimpleNamespace(base_url="https://api.anthropic.com")) == ("api.anthropic.com", 443))

# ---- the scheduler wrapper -------------------------------------------------------------------------------------------
os.environ["ONE_ROUTINE_REACH_WAIT_SECONDS"] = "5"


class Agent:
    platform = "cron"
    base_url = None  # no address to poll: reachable

    def __init__(self):
        self.calls = []

    def run_conversation(self, message, conversation_history=None, task_id=None):
        self.calls.append((message, conversation_history))
        return {}

    def clear_interrupt(self, hard_cancel=False):
        self.cleared = hard_cancel


def scheduler_with(results):
    sched = types.ModuleType("fake_scheduler")

    def _run_agent_with_watchdog(agent, prompt, job, job_id, job_name, task_id, cancel_event, worker_state=None):
        agent.run_conversation(prompt, task_id=task_id)  # what the engine's watchdog runs
        return results.pop(0)

    sched._run_agent_with_watchdog = _run_agent_with_watchdog
    check("the wrapper installs", rs.install(sched) and sched._one_routine_stall is True)
    check("installing twice changes nothing", rs.install(sched) and sched._run_agent_with_watchdog.__wrapped__ is _run_agent_with_watchdog)
    return sched


lapsed = failed(turn_exit_reason="interrupted_during_api_call(session_turn_lease_lost)", messages=work)
sched = scheduler_with([lapsed, {"completed": True, "final_response": "done"}])
agent = Agent()
out = sched._run_agent_with_watchdog(agent, "Upload it", {"id": "j", "name": "J"}, "j", "J", "t", None)
check("a lapsed turn runs again and the routine ends ok", out.get("final_response") == "done")
check("the same turn: its work so far as history, told to carry on",
      len(agent.calls) == 2 and agent.calls[1] == (rs.CONTINUE, work), str(agent.calls)[:200])
check("the agent's interrupt is cleared first", getattr(agent, "cleared", None) is True)
check("the agent is left as it was", "run_conversation" not in vars(agent))

os.environ["ONE_ROUTINE_TURN_RETRIES"] = "2"
sched = scheduler_with([lapsed, lapsed, lapsed, {"completed": True}])
agent = Agent()
out = sched._run_agent_with_watchdog(agent, "Upload it", {"id": "j"}, "j", "J", "t", None)
check("at most ONE_ROUTINE_TURN_RETRIES times, then it ends as it was", len(agent.calls) == 3 and out is lapsed)

sched = scheduler_with([failed(turn_exit_reason="interrupted_during_api_call"), {"completed": True}])
agent = Agent()
sched._run_agent_with_watchdog(agent, "Upload it", {"id": "j"}, "j", "J", "t", None)
check("a person's Stop is never run again", len(agent.calls) == 1)

os.environ["ONE_ROUTINE_REACH_WAIT_SECONDS"] = "0.3"
sched = scheduler_with([lapsed, {"completed": True}])
agent = Agent()
agent.base_url = f"http://127.0.0.1:{port}"  # nothing listens there any more
out = sched._run_agent_with_watchdog(agent, "Upload it", {"id": "j"}, "j", "J", "t", None)
check("an AI that stays out of reach: no retry, the run ends as it was", len(agent.calls) == 1 and out is lapsed)

print("routine stall logic ok" if not fails else f"routine stall logic FAILED ({fails} failed)")
sys.exit(1 if fails else 0)
