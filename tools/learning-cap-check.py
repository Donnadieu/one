"""Checks One's learning cap (tools/overlay/plugins/one-learning-cap) on made-up calls. Plain python, no engine."""

import datetime as dt
import importlib.util
import os
import sys
from pathlib import Path

HERE = Path(os.environ.get("ONE_CAP_PLUGIN", Path(__file__).resolve().parent / "overlay" / "plugins" / "one-learning-cap" / "__init__.py"))
spec = importlib.util.spec_from_file_location("one_learning_cap", HERE)
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
fails = 0


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


def op(name, action="patch"):
    return {"operations": [{"name": name, "action": action, "old_string": "a", "new_string": "b"}]}


now = dt.datetime.now(dt.timezone.utc).isoformat()
rec = lambda n: {"ts": now, "actor": "curator", "action": "patch", "skill": n}
L = (5, 1)
check("helpers and the person are never capped", g.decide("skill_manage", op("x"), False, [rec(str(i)) for i in range(9)], L) is None)
check("other tools pass", g.decide("terminal", {"command": "ls"}, True, [], L) is None)
check("first review edit passes", g.decide("skill_manage", op("x"), True, [], L) is None)
check("a second edit to the same skill in a day is held", g.decide("skill_manage", op("x"), True, [rec("x")], L) is not None)
check("a different skill passes", g.decide("skill_manage", op("y"), True, [rec("x")], L) is None)
check("the 6th edit of the day is held", g.decide("skill_manage", op("z"), True, [rec(str(i)) for i in range(5)], L) is not None)
check("a batch that crosses the limit is held",
      g.decide("skill_manage", {"operations": [{"name": "a", "action": "patch"}, {"name": "b", "action": "patch"}]}, True,
               [rec(str(i)) for i in range(4)], L) is not None)
check("the same skill twice in one batch is held",
      g.decide("skill_manage", {"operations": [{"name": "a", "action": "patch"}, {"name": "a", "action": "write_file"}]}, True, [], L) is not None)
check("limits come from settings", g.decide("skill_manage", op("q"), True, [rec(str(i)) for i in range(5)], (10, 1)) is None)
sys.exit(1 if fails else 0)
