"""Checks One's stop plugin (tools/overlay/plugins/one-stop) on a made-up engine: a stopped helper's whole tree.
Plain python, no engine. The Nov 9 case: a background test run finishing after Stop must not wake the helper up."""

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

T = Path(tempfile.mkdtemp(prefix="one-stop-check-"))
home, guard = T / "hermes", T / "guard"
home.mkdir()
os.environ["HERMES_HOME"] = str(home)
os.environ["ONE_GUARD_DIR"] = str(guard)

ROOT, KID, GRAND, OTHER = "local-root", "20261109_113303_kid", "20261109_120000_grand", "local-other"
con = sqlite3.connect(home / "state.db")
con.execute("create table sessions (id text primary key, parent_session_id text)")
con.executemany("insert into sessions values (?, ?)", [(ROOT, None), (KID, ROOT), (GRAND, KID), (OTHER, None)])
con.commit()
con.close()

# A stand-in for the engine's gateway notifications mixin (the one place every wake-up goes through).
injected = []


class Mixin:
    def _build_process_event_source(self, evt):
        c = evt.get("_chat")
        return types.SimpleNamespace(chat_id=c) if c else None

    async def _inject_watch_notification(self, synth_text, evt, raise_not_accepted=False):
        injected.append(synth_text)
        return True


gw = types.ModuleType("gateway")
rn = types.ModuleType("gateway.run_notifications")
rn.GatewayNotificationsMixin = Mixin
sys.modules["gateway"], sys.modules["gateway.run_notifications"] = gw, rn

spec = importlib.util.spec_from_file_location(
    "one_stop", os.environ.get("ONE_STOP_PLUGIN", Path(__file__).resolve().parent / "overlay" / "plugins" / "one-stop" / "__init__.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails = 0


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


class Ctx:
    hooks = {}

    def register_hook(self, name, fn):
        self.hooks[name] = fn


ctx = Ctx()
g.register(ctx)
pre = ctx.hooks.get("pre_tool_call")
check("registers its tool-call check", pre is not None)
check("hooks the gateway's wake-ups", getattr(Mixin, "_one_stop", False))
check("nothing is blocked before any stop", pre("terminal", {"command": "ls"}, session_id=ROOT) is None)


def mark(sid):
    (guard / "stopped").mkdir(parents=True, exist_ok=True)
    (guard / "stopped" / (g.safe(sid) + ".json")).write_text(json.dumps({"session": sid, "title": "Finish NotArc", "at": time.time()}))


mark(ROOT)
g._parents_cache.clear()
block = pre("terminal", {"command": "./selftest.sh NotArc.app"}, session_id=ROOT)
check("a stopped helper can't run anything", isinstance(block, dict) and block.get("action") == "block" and "stopped" in block["message"])
check("nor its sub-helpers", pre("delegate_task", {"tasks": []}, session_id=KID) is not None)
check("nor theirs", pre("terminal", {"command": "open NotArc.app"}, session_id=GRAND) is not None)
check("another helper is untouched", pre("terminal", {"command": "ls"}, session_id=OTHER) is None)

m = Mixin()
run = lambda evt: asyncio.run(m._inject_watch_notification("[IMPORTANT: Background process proc_x completed normally]", evt))
injected.clear()
check("Nov 9: a background run finishing after Stop doesn't wake it", run({"parent_session_id": ROOT}) is None and not injected)
check("one that reports through the gateway's session key neither", run({"session_key": f"agent:main:local:dm:{ROOT}"}) is None)
check("one from a sub-helper neither", run({"origin_session_id": KID}) is None)
check("one named only by where it's delivered neither", run({"_chat": ROOT}) is None)
check("another helper's wake-ups still arrive", run({"parent_session_id": OTHER}) is True and len(injected) == 1)


class Proc:
    def __init__(self, pid, chat, cmd, task=""):
        self.id, self.pid, self.watcher_chat_id, self.command = f"proc_{pid}", pid, chat, cmd
        self.session_key, self.task_id, self.owner_task_id, self.exited = "", task, "", False


class Registry:
    def __init__(self, procs):
        self._running = {p.id: p for p in procs}
        self.killed = []

    def kill_process(self, pid, source="", consume_output=True):
        self.killed.append((pid, source))
        self._running[pid].exited = True
        return {"status": "killed"}


calls = []
deleg = types.SimpleNamespace(
    interrupt_for_session=lambda parent_session_id="", reason="": calls.append(("interrupt", parent_session_id)) or (2 if parent_session_id == ROOT else 0),
    refuse_for_session=lambda token, parent_session_ids=(): calls.append(("refuse", parent_session_ids)),
    allow_for_session=lambda token: calls.append(("allow", token)),
)
reg = Registry([Proc(101, ROOT, "./selftest.sh NotArc.app"), Proc(102, ROOT, "RUN_RESTORE=1 ./selftest.sh", task=KID),
                Proc(103, OTHER, "npm run dev")])
live = g.write_live(reg)
check("live programs are listed by conversation for One", sorted(p["pid"] for p in live.get(ROOT, [])) == [101, 102] and [p["pid"] for p in live[OTHER]] == [103])
check("and written where One reads them", json.loads((home / "one-stop" / "live.json").read_text()).keys() == {ROOT, OTHER})
rep = g.sweep_once(reg, deleg)
check("the sweep kills the stopped helper's background programs (its own and its sub-helpers')",
      sorted(k for k, _ in reg.killed) == ["proc_101", "proc_102"] and rep[ROOT]["killed"] == 2)
check("never another helper's", not reg._running["proc_103"].exited)
check("its sub-helpers (and theirs) are stopped and refused", ("interrupt", ROOT) in calls and ("interrupt", KID) in calls
      and ("interrupt", GRAND) in calls and any(c[0] == "refuse" for c in calls) and rep[ROOT]["delegations"] == 2)
g.write_status(rep)
check("what it did is written for One's \"Stopping…\" line", json.loads((home / "one-stop" / (g.safe(ROOT) + ".json")).read_text())["killed"] == 2)

old = time.time() - 16 * 60
(guard / "stopped" / (g.safe(ROOT) + ".json")).write_text(json.dumps({"session": ROOT, "at": old}))
check("an old mark is no longer swept", g.sweep_once(Registry([Proc(104, ROOT, "x")]), deleg) == {})
check("but its wake-ups are still dropped", run({"parent_session_id": ROOT}) is None)

(guard / "stopped" / (g.safe(ROOT) + ".json")).unlink()
g.lifted(deleg)
check("their message lifts it: tools run again", pre("terminal", {"command": "ls"}, session_id=ROOT) is None)
check("and wake-ups arrive again", run({"parent_session_id": ROOT}) is True)
check("its status goes and its sub-helpers may start again", not (home / "one-stop" / (g.safe(ROOT) + ".json")).exists()
      and any(c[0] == "allow" for c in calls))
check("the sweep never runs outside the gateway", not g._started)

# Against the real engine (CI's fresh install): the place this hooks into is still there, with the same shape.
eng = os.environ.get("ONE_ENGINE_DIR")
if eng:
    for k in ("gateway", "gateway.run_notifications"):
        sys.modules.pop(k, None)
    sys.path.insert(0, eng)
    import inspect

    from gateway import run_notifications as real  # noqa: E402

    cls = real.GatewayNotificationsMixin
    sig = list(inspect.signature(cls._inject_watch_notification).parameters)
    check("real engine: wake-ups still go through _inject_watch_notification(self, synth_text, evt, …)", sig[:3] == ["self", "synth_text", "evt"])
    check("real engine: it can still find where a wake-up goes", hasattr(cls, "_build_process_event_source"))
    from tools import async_delegation as ad  # noqa: E402

    check("real engine: sub-helpers can be interrupted and refused per conversation",
          all(hasattr(ad, f) for f in ("interrupt_for_session", "refuse_for_session", "allow_for_session")))
    from tools.process_registry import ProcessSession  # noqa: E402

    fields = getattr(ProcessSession, "__dataclass_fields__", {})
    check("real engine: background programs still say which conversation they report to", "watcher_chat_id" in fields and "session_key" in fields)

print("stop plugin ok" if fails == 0 else f"stop plugin: {fails} failed")
sys.exit(1 if fails else 0)
