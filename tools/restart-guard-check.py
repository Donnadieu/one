"""Checks the restart guard in One's engine plugin (tools/overlay/plugins/one-browser-guard): no hand-made restart,
reinstall or relaunch of One while One is open or a routine is at work.

Run: python3 tools/restart-guard-check.py   (prints "restart guard ok" when every case passes)
The first blocked case is what a helper really ran on 2026-11-17 at 7:17 AM: it installed One 0.9.120 by hand and cut
the YouTube long-video routine off 17 minutes into its run. Nothing here stops or starts anything: the guard only
reads the command text, a fake jobs.json and a fake heartbeat in a throwaway folder.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
tmp = Path(tempfile.mkdtemp(prefix="one-restart-guard-"))
home = tmp / "hermes"
(home / "cron").mkdir(parents=True)
os.environ["HERMES_HOME"] = str(home)
os.environ["ONE_GUARD_DIR"] = str(tmp / "guard")
spec = importlib.util.spec_from_file_location("one_browser_guard", HERE / "overlay/plugins/one-browser-guard/__init__.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    if not ok:
        fails += 1


def result(cmd, tool="terminal"):
    key = "command" if tool == "terminal" else "code"
    return g.on_pre_tool_call(tool_name=tool, args={key: cmd}, session_id="test")


def blocked(cmd, tool="terminal"):
    r = result(cmd, tool)
    return isinstance(r, dict) and r.get("action") == "block"


def iso(dt):
    return dt.isoformat()


now = datetime.now(timezone.utc).astimezone()


def jobs(*js):
    (home / "cron" / "jobs.json").write_text(json.dumps({"jobs": list(js)}))


def heartbeat(age):
    (home / "pulse.json").write_text(json.dumps({"ts": (datetime.now(timezone.utc) - timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ"), "pid": 1}))


def no_heartbeat():
    p = home / "pulse.json"
    if p.exists():
        p.unlink()


# The Nov 17 job, as jobs.json had it at 7:17 AM: dispatched at 7:00, state "scheduled" (never "running"), no claim.
long_video = {"id": "9b2860139519", "name": "Then It Clicked: long video (Tue/Fri)", "enabled": True, "state": "scheduled",
              "last_run_at": iso(now - timedelta(days=4)), "fire_claim": None,
              "last_dispatch": {"dispatched_at": iso(now - timedelta(minutes=17))}}

# --- Reading which routines are at work, the way One does (and not the way the hand install did) ---
jobs(long_video)
check("a routine dispatched 17 min ago and not finished is at work (state still says \"scheduled\")",
      g.routines_at_work() == ["Then It Clicked: long video (Tue/Fri)"])
check("the test that let the hand install through (state == \"running\") would have missed it",
      not any(j.get("state") == "running" for j in json.loads((home / "cron" / "jobs.json").read_text())["jobs"]))
jobs(dict(long_video, last_run_at=iso(now - timedelta(minutes=1))))
check("once it finished (last run after the dispatch) it's no longer at work", g.routines_at_work() == [])
jobs(dict(long_video, last_dispatch={"dispatched_at": iso(now - timedelta(hours=4))}))
check("a dispatch over 3 hours old with no finish (a dead run) doesn't count forever", g.routines_at_work() == [])
jobs(dict(long_video, last_dispatch=None, fire_claim={"owner": "x", "at": iso(now - timedelta(seconds=30))}))
check("a live claim counts", g.routines_at_work() == ["Then It Clicked: long video (Tue/Fri)"])
jobs(dict(long_video, last_dispatch=None, fire_claim={"owner": "x"}))
check("a claim with no time doesn't", g.routines_at_work() == [])
jobs(dict(long_video, enabled=False))
check("a paused routine isn't at work", g.routines_at_work() == [])

# --- One closed, no routine: nothing to protect, hand installs are allowed (a first install, a dead One) ---
jobs()
no_heartbeat()
INSTALL = ('P=$(pgrep -x One); [ -n "$P" ] && kill $P; for p in $(pgrep -f "Application Support/One/(engine|voice)"); do kill $p; done; '
           'rm -rf /Applications/One.app && ditto new/One.app /Applications/One.app && open /Applications/One.app')
check("One closed and no routine at work: a hand install is allowed", not blocked(INSTALL))

# --- A routine at work: blocked even with One closed (its background helper keeps running the routine) ---
jobs(long_video)
check("the Nov 17 hand install is blocked while the long-video routine is at work", blocked(INSTALL))
msg = (result(INSTALL) or {}).get("message", "")
check("the message names the routine and gives One's own way", "Then It Clicked" in msg and "One --update" in msg)

# --- One open (fresh heartbeat), no routine: still blocked, helpers at work would be cut off ---
jobs()
heartbeat(10)
check("with One open, a hand install is blocked", blocked(INSTALL))
for name, cmd in [
    ("pkill -x One", "pkill -x One"),
    ("killall One", "killall One"),
    ("kill $(pgrep -x One)", "kill $(pgrep -x One)"),
    ("killing the engine by its folder", 'pkill -f "Application Support/One/engine"'),
    ("killing the gateway from its pid file", 'kill $(python3 -c "import json;print(json.load(open(\'gateway.pid\'))[\'pid\'])")'),
    ("hermes gateway restart", "hermes gateway restart"),
    ("cp -R a build over /Applications/One.app", "cp -R build/One.app /Applications/One.app"),
    ("rm -rf /Applications/One.app", "rm -rf /Applications/One.app"),
    ("mv into ~/Applications/One.app", "mv One.app ~/Applications/One.app"),
    ("osascript quit One", "osascript -e 'quit app \"One\"'"),
    ("inside bash -c", "bash -c 'pkill -x One; open -a One'"),
    ("the old restart recipe", 'P=$(pgrep -x One); [ -n "$P" ] && kill $P; for p in $(pgrep -f "Application Support/One/(engine|voice)"); do kill $p; done'),
    ("pgrep -f the installed app, then kill", 'kill $(pgrep -f "/Applications/One.app/Contents/MacOS/One")'),
    ("pgrep | xargs kill", "pgrep -x One | xargs kill"),
]:
    check(f"blocked: {name}", blocked(cmd))
check("blocked: from Python (subprocess kill of One)", blocked('import subprocess\nsubprocess.run(["pkill", "-x", "One"])', tool="execute_code"))
script = tmp / "install.sh"
script.write_text("#!/bin/bash\nP=$(pgrep -x One)\nkill $P\nditto new/One.app /Applications/One.app\nopen /Applications/One.app\n")
check("blocked: a script that does the swap, when it's run", blocked(f"bash {script}"))
check("blocked: that script started detached from Python",
      blocked(f'import subprocess, os\nsubprocess.Popen(["/bin/bash", "{script}"], start_new_session=True)', tool="execute_code"))

# --- What must keep working ---
for name, cmd in [
    ("One --update", "One --update"),
    ("One --update --from a build", '"/Applications/One.app/Contents/MacOS/One" --update --from ~/Repos/one-assistant/build/One.app'),
    ("looking at One's processes", "pgrep -x One; ps -o lstart= -p $(pgrep -x One)"),
    ("reading One's version", "/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/One.app/Contents/Info.plist"),
    ("checking One's signature", "codesign --verify --deep --strict /Applications/One.app"),
    ("killing a scratch test copy by pid", "kill 4242"),
    ("killing a dev server", "pkill -f 'puma 6' ; kill $(lsof -ti :3000)"),
    ("killing a scratch test copy by its path (jobs-check.sh)", 'for p in $(pgrep -f "$S/One.app"); do kill "$p" 2>/dev/null; done'),
    ("asking if the gateway is alive (kill -0)", 'p=$(cat gateway.pid); kill -0 "$p" && echo alive'),
    ("running build.sh (its never-taken --install branch isn't an install)", "bash build.sh --package"),
    ("building into build/", "./build.sh --package && cp build/One.dmg ~/Downloads/"),
    ("opening One when it's closed", "open -a /Applications/One.app"),
]:
    check(f"allowed: {name}", not blocked(cmd))

# --- A stale heartbeat means One is closed (or hung): not a reason to block on its own ---
heartbeat(600)
check("a heartbeat 10 min old (One closed) with no routine: allowed", not blocked("pkill -x One"))
check("every block was logged", (home / "logs" / g.RESTART_LOG).exists()
      and "blocked terminal" in (home / "logs" / g.RESTART_LOG).read_text())

print("restart guard ok" if fails == 0 else f"restart guard: {fails} failed")
sys.exit(1 if fails else 0)
