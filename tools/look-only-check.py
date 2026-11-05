"""Checks One's look-only guard (tools/overlay/plugins/one-browser-guard) on real commands.

Run: python3 tools/look-only-check.py   (prints "look-only guard ok" when every case passes; CI runs it in preflight)
A helper whose job starts with "Look only:" gets a mark from One in guard/look-only/<session>.json. For that
conversation (and the ones it continues into), commands that save, publish, install or post are blocked; everything
else, and every other conversation, runs as before. Nothing here runs a command: the guard only reads the text.
"""

import importlib.util
import json
import os
import sqlite3
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
tmp = Path(tempfile.mkdtemp(prefix="one-look-"))
os.environ["HERMES_HOME"] = str(tmp / "hermes")
os.environ["ONE_GUARD_DIR"] = str(tmp / "guard")
(tmp / "hermes").mkdir(parents=True)
spec = importlib.util.spec_from_file_location("one_browser_guard", HERE / "overlay/plugins/one-browser-guard/__init__.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    if not ok:
        fails += 1


LOOK = "local-look-1"
OTHER = "local-busy-2"
(tmp / "guard" / "look-only").mkdir(parents=True)
(tmp / "guard" / "look-only" / f"{LOOK}.json").write_text(json.dumps({"session": LOOK, "title": "Check Forge compound loop"}))


def result(cmd, tool="terminal", sid=LOOK):
    key = "command" if tool == "terminal" else "code"
    return g.on_pre_tool_call(tool_name=tool, args={key: cmd}, session_id=sid)


def blocked(cmd, tool="terminal", sid=LOOK):
    r = result(cmd, tool, sid)
    return isinstance(r, dict) and r.get("action") == "block"


# What "Check Forge compound loop" did on Nov 4 while told to change nothing ("Saving to GitHub…").
check("git commit is blocked", blocked('cd ~/Repos/forge && git add -A && git commit -m "fix loop"'))
check("git push is blocked", blocked("git -C ~/Repos/forge push origin main"))
check("git tag (making one) is blocked", blocked("git tag -s v1.2.0 -m release"))
check("git merge / rebase / cherry-pick are blocked", blocked("git merge feature") and blocked("git rebase main") and blocked("git cherry-pick abc123"))
check("gh release create is blocked", blocked("gh release create v0.9.89 build/One.zip --notes x"))
check("gh pr create / merge / comment are blocked",
      blocked("gh pr create --fill") and blocked("gh pr merge 12 --squash") and blocked("gh pr comment 12 -b hi"))
check("gh issue create is blocked", blocked("GH_TOKEN=$(gh auth token -u X) gh issue create -t bug -b x"))
check("gh api writes are blocked", blocked("gh api repos/x/y/issues -f title=hi") and blocked("gh api -X DELETE repos/x/y/git/refs/heads/z"))
check("brew install is blocked", blocked("brew install --cask arc"))
check("copying an app into /Applications is blocked", blocked("cp -R build/One.app /Applications/") and blocked("ditto One.app ~/Applications/One.app"))
check("npm -g install is blocked", blocked("npm install -g some-cli"))
check("posting on X is blocked", blocked("xurl post 'hello world'") and blocked("x-cli tweet 'hi'"))
check("curl sending data is blocked", blocked("curl -X POST https://api.example.com/posts -d 'x=1'"))
check("inside bash -c too", blocked("bash -c 'cd /tmp && git push'"))
check("inside a script it runs too", (lambda p: (p.write_text("#!/bin/sh\ngit push origin HEAD\n"), blocked(f"bash {p}"))[1])(tmp / "ship.sh"))
check("from Python's subprocess too", blocked('import subprocess\nsubprocess.run(["git", "push", "origin", "main"])', tool="execute_code"))
check("the send_message tool is blocked", isinstance(g.on_pre_tool_call(tool_name="send_message", args={"text": "hi"}, session_id=LOOK), dict))
msg = (result("git push origin main") or {}).get("message", "")
check("the message says what it wanted and tells it to ask instead",
      "look only" in msg and "save or push code (git push)" in msg and "[choices: Do it | Not now]" in msg and "Don't look for another way" in msg)
log = tmp / "hermes" / "logs" / "one-look-only.log"
check("every block is logged", log.exists() and "git push" in log.read_text())

# Looking stays allowed.
for cmd in ["git status", "git log --oneline -20", "git diff HEAD~3", "git -C ~/Repos/forge fetch origin", "git tag -l", "git tag --list 'v0.9*'",
            "git show v0.9.88:Sources/Engine.swift | head", "gh pr list", "gh pr view 12", "gh release list", "gh run list -L 5",
            "gh api repos/Donnadieu/one/releases", "gh api graphql -f query='{ viewer { login } }'", "curl -s https://api.github.com/repos/x/y",
            "curl -s -X POST https://api.linear.app/graphql -d '{\"query\":\"{ issues { nodes { id } } }\"}'", "grep -rn push Sources/",
            "echo 'git push is blocked here'", "make check", "./build.sh", "ls /Applications"]:
    check(f"allowed while looking: {cmd[:60]}", not blocked(cmd))
check("reading code that mentions subprocess and git push is allowed",
      not blocked('print("git push")\nx = "subprocess.run([\'git\', \'push\'])"', tool="execute_code"))

# Other helpers are untouched.
check("another helper can push", not blocked("git push origin main", sid=OTHER))
check("another helper can release", not blocked("gh release create v1 x.zip", sid=OTHER))

# A long conversation the engine continued under a new id stays look-only.
db = tmp / "hermes" / "state.db"
con = sqlite3.connect(db)
con.execute("create table sessions (id text primary key, parent_session_id text)")
con.execute("insert into sessions values (?, ?)", (LOOK, None))
con.execute("insert into sessions values ('local-cont-3', ?)", (LOOK,))
con.execute("insert into sessions values ('local-cont-4', 'local-cont-3')")
con.commit()
con.close()
check("its continuation (two squeezes later) is still look-only", blocked("git push", sid="local-cont-4"))

# Lifted (their message in its thread): One removes the mark.
(tmp / "guard" / "look-only" / f"{LOOK}.json").unlink()
check("once lifted, it can push", not blocked("git push origin main"))

# The browser guard still works alongside it.
check("a visible browser is still blocked for everyone", blocked('open -a "Google Chrome"', sid=OTHER))

print("look-only guard ok" if fails == 0 else f"look-only guard: {fails} failed")
raise SystemExit(1 if fails else 0)
