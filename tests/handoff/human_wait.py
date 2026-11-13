"""A hand-off's wait counts as time spent waiting on a person, so the engine never cuts it off.

The engine gives one tool call 420 s (agent/tool_executor.py) and only leaves out time the engine's own human-wait
window covers (tools/approval_human_wait.py). hand_off waits up to 480 s for the person, longer while the real window
is up. On Nov 12 2026 the DocuSign helper's hand_off was killed at 420 s while Omar was typing the texted code in the
window: the engine's stop answered the ask "cancelled", and the helper only saw "timed out after 420.0s".
Plain python, no engine: a stand-in human-wait module records whether a window is open while the hand-off waits.
"""
import importlib.util, os, sys, tempfile, types
from pathlib import Path

HERE = Path(__file__).resolve().parents[2] / "tools" / "overlay" / "tools" / "one_human_step.py"
os.environ["ONE_HANDOFF_DIR"] = tempfile.mkdtemp(prefix="one-human-wait-")
fails = 0


def check(name, ok):
    global fails
    print(f"  {'✓' if ok else '✗'} {name}")
    fails += 0 if ok else 1


# The engine's human-wait accounting, as a stand-in: counts open windows.
state = {"pending": 0, "opened": 0}
hw = types.ModuleType("tools.approval_human_wait")


class _Window:
    def __enter__(self):
        state["pending"] += 1
        state["opened"] += 1

    def __exit__(self, *a):
        state["pending"] -= 1
        return False


hw.human_wait_window = lambda session_key=None: _Window()
tools_pkg = types.ModuleType("tools")
tools_pkg.__path__ = []
sys.modules["tools"] = tools_pkg
sys.modules["tools.approval_human_wait"] = hw

spec = importlib.util.spec_from_file_location("one_human_step", HERE)
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)

# A stand-in browser: one tab showing a code box, or one plain page.
TAB = {"target_id": "T1", "ws": "ws://stand-in/T1", "url": "https://account-d.docusign.com/v2/x", "title": "Docusign",
       "kind": "code", "score": 90}
hs._local_port = lambda tid: ("127.0.0.1", 9999)
hs.find_session = lambda url, exclude_port=0: None
hs._pages = lambda host, port: [{"id": "T1", "webSocketDebuggerUrl": TAB["ws"], "url": TAB["url"], "title": "Docusign"}]
seen = {}


def code_step(tab, site, port, why, seconds, session=""):
    seen["code"] = state["pending"]
    return {"success": True, "answer": "done", "moved_on": True, "site": site}


def wait(req, ws, start_url, seconds, port=0):
    seen["window"] = state["pending"]
    return "away"


hs.code_step = code_step
hs._wait = wait

print("A code hand-off waits inside the engine's human-wait window")
hs.pick_step_tab = lambda host, port, kinds=hs.HUMAN_KINDS, prefer_url="": dict(TAB)
hs.hand_off(kind="code", task_id="t", why="test", wait=1)
check("the code step ran with a human-wait window open", seen.get("code") == 1)
check("the window closed when the hand-off returned", state["pending"] == 0)

print("A window hand-off (sign-in, robot check) waits inside it too")
plain = dict(TAB, kind="check", score=50)
hs.pick_step_tab = lambda host, port, kinds=hs.HUMAN_KINDS, prefer_url="": dict(plain) if "check" in kinds else None
hs.hand_off(kind="check", task_id="t", why="test", wait=1)
check("the person's wait ran with a human-wait window open", seen.get("window") == 1)
check("the window closed when the hand-off returned", state["pending"] == 0)

print("Without the engine's module the hand-off still works")
del sys.modules["tools.approval_human_wait"]
seen.clear()
hs.pick_step_tab = lambda host, port, kinds=hs.HUMAN_KINDS, prefer_url="": dict(TAB)
r = hs.hand_off(kind="code", task_id="t", why="test", wait=1)
check("the code step still ran", "code" in seen and r.get("moved_on") is True)

print("HUMAN WAIT PASS" if fails == 0 else f"HUMAN WAIT FAIL ({fails})")
sys.exit(1 if fails else 0)
