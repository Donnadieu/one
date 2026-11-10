"""Checks One's main-queue plugin (tools/overlay/plugins/one-main-queue): one helper at a time puts work on a repo's main.
Plain python and git, in a temp folder (no engine, no network): which commands count; two stand-in helpers pushing to a
scratch repo's main at the same moment (the second waits, is told to rebase, then pushes: history linear, nothing
lost); a turn that runs out, a stopped helper and a finished turn free the place."""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
from pathlib import Path

T = Path(os.path.realpath(tempfile.mkdtemp(prefix="one-main-queue-check-")))
home, guard = T / "One" / "hermes", T / "One" / "guard"  # One's folder; the repos live outside it, as on a Mac
home.mkdir(parents=True)
os.environ["HERMES_HOME"] = str(home)
os.environ["ONE_GUARD_DIR"] = str(guard)
os.environ["ONE_REPOS_DIR"] = str(T / "Repos")
gitcfg = T / "gitconfig"
gitcfg.write_text("[user]\n\tname = Test\n\temail = t@example.com\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n"
                  "[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n")
os.environ["GIT_CONFIG_GLOBAL"] = str(gitcfg)
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"

spec = importlib.util.spec_from_file_location(
    "one_main_queue",
    os.environ.get("ONE_MAIN_QUEUE_PLUGIN", Path(__file__).resolve().parent / "overlay" / "plugins" / "one-main-queue" / "__init__.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

fails = 0


def check(name, ok, got=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or got == "" else f"  (got: {got})"))
    sys.stdout.flush()
    fails += 0 if ok else 1


# --- 1. which commands put work on main -----------------------------------------------------------------------------

# A stand-in git: /r/main is the repo's main checkout (on main), /r/wt a helper's own copy on its branch.
STATE = {"/r/main": ("main", True), "/r/wt": ("helper/fix-1a2b", False), "/r/wt-on-main": ("main", False),
         "/r/x": ("main", True), "/Users/me/Repos/x": ("feature", False)}


def fake_git(args, cwd):
    br, main = STATE.get(cwd, ("", False))
    if args[:1] == ["symbolic-ref"]:
        return (0, br + "\n") if br else (1, "")
    if args[:1] == ["rev-parse"] and "--git-common-dir" in args:
        if not br:
            return 128, ""
        return 0, (f"{cwd}/.git\n{cwd}/.git\n" if main else f"/r/main/.git/worktrees/x\n/r/main/.git\n")
    return 1, ""


def d(cmd, cwd="/r/wt"):
    h = g.decide(cmd, cwd, fake_git)
    return h["kind"] if h else None


counts = [
    ("git push origin main", "/r/wt", "push"),
    ("git push origin HEAD:main", "/r/wt", "push"),
    ("git push origin helper/fix-1a2b:main", "/r/wt", "push"),
    ("git push --force-with-lease origin +HEAD:refs/heads/master", "/r/wt", "push"),
    ("git push", "/r/main", "push"),
    ("git push origin", "/r/wt-on-main", "push"),
    ("git push origin HEAD", "/r/main", "push"),
    ("git push origin :main", "/r/wt", "push"),
    ("git -C /r/main push", "/somewhere", "push"),
    ("cd /r/main && git push -u origin main", "/somewhere", "push"),
    ("git push origin main 2>&1 | tail -5", "/r/wt", "push"),
    ("GH_TOKEN=$(gh auth token -u Donnadieu) git push origin HEAD:main", "/r/wt", "push"),
    ("cd /r/main && git merge --ff-only helper/fix-1a2b", "/r/wt", "merge"),
    ("git rebase origin/main", "/r/main", "rebase"),
    ("git merge --continue", "/r/main", "merge"),
    ("gh pr merge 12 --squash --delete-branch", "/r/wt", "pr-merge"),
    ("GH_TOKEN=$(gh auth token -u Donnadieu) gh pr merge 112 -R Donnadieu/one --rebase", "/tmp", "pr-merge"),
    ("gh release create v0.9.105 build/One.dmg --notes x", "/r/main", "release"),
    ("make check && git add -A && git commit -m 'wip' && git push origin main", "/r/wt", "push"),
    ("git push origin main\n", "/r/wt", "push"),
]
for cmd, cwd, want in counts:
    got = d(cmd, cwd)
    check(f"counts: {cmd!r} ({cwd}) -> {want}", got == want, got)

never = [
    ("git push origin helper/fix-1a2b", "/r/wt"),
    ("git push -u origin repo-turns", "/r/wt"),
    ("git push", "/r/wt"),
    ("git push origin HEAD", "/r/wt"),
    ("git push origin main-fix", "/r/wt"),
    ("git push origin v1.2.0", "/r/wt"),
    ("git push --tags", "/r/wt"),
    ("git push --dry-run origin main", "/r/wt"),
    ("git push origin --delete old-branch", "/r/wt"),
    ("git merge origin/main", "/r/wt"),
    ("git rebase origin/main", "/r/wt"),
    ("git rebase origin/main", "/r/wt-on-main"),  # a helper's own copy on main isn't the main checkout
    ("git rebase --abort", "/r/main"),
    ("git merge-base --is-ancestor origin/main HEAD", "/r/main"),
    ("git pull --rebase origin main", "/r/main"),
    ("git log main..HEAD && git checkout main", "/r/main"),
    ("git commit -m 'push to main later'", "/r/wt"),
    ("echo git push origin main", "/r/wt"),
    ("gh pr view 12", "/r/wt"),
    ("gh pr create --draft --base main", "/r/wt"),
    ("gh release view v1", "/r/main"),
    ("ls ~/Repos", "/r/wt"),
]
for cmd, cwd in never:
    got = d(cmd, cwd)
    check(f"doesn't count: {cmd!r} ({cwd})", got is None, got)
h = g.decide("git -C /r/x push origin main", "/r/wt", fake_git)
check("git -C <folder> is where it runs", h and h["cwd"] == "/r/x", h)
h = g.decide("git push origin helper/fix-1a2b:main", "/r/wt", fake_git)
check("the branch pushed is what's compared with main", h and h["source"] == "helper/fix-1a2b" and h["main"] == "main", h)
h = g.decide("gh pr merge 112 -R Donnadieu/one", "/tmp", fake_git)
check("gh -R names the repo", h and h["slug"] == "Donnadieu/one", h)
check("names read as the person says them", g.humanize("forge-desktop") == "Forge Desktop" and g.humanize("NotArc") == "NotArc")
check("ordinals", [g.ordinal(n) for n in (1, 2, 3, 4, 11, 12, 13, 21, 22)] == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"])
check("never a queue for the brain", not g.allowed(os.path.expanduser("~/Documents/My Brain/work-room")))
check("…nor One's own data", not g.allowed(str(home / "skills")) and g.allowed(str(home.parent / "work" / "clone")))
check("…nor a shared room", not g.allowed(os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/One Rooms/x")))

# --- 2. two helpers push to a scratch repo's main at the same moment -------------------------------------------------


def git(*args, cwd=None, ok=True):
    p = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if ok and p.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {p.stderr}")
    return p


repos = T / "Repos"
repos.mkdir()
origin, main = repos / "origin.git", repos / "forge-desktop"
git("init", "-q", "--bare", "-b", "main", str(origin))
git("init", "-q", "-b", "main", str(main))
(main / "README.md").write_text("hi\n")
git("add", ".", cwd=main)
git("commit", "-q", "-m", "first", cwd=main)
git("remote", "add", "origin", str(origin), cwd=main)
git("push", "-q", "origin", "main", cwd=main)
wa, wb = repos / "forge-desktop-tray", repos / "forge-desktop-export"
git("worktree", "add", "-q", "-b", "helper/tray", str(wa), "main", cwd=main)
git("worktree", "add", "-q", "-b", "helper/export", str(wb), "main", cwd=main)
for w, f in ((wa, "tray.txt"), (wb, "export.txt")):
    (w / f).write_text(f + "\n")
    git("add", ".", cwd=w)
    git("commit", "-q", "-m", f"add {f}", cwd=w)
A, B = "local-helper-tray", "local-helper-export"
g.WAIT_FOR, g.CHECK_EVERY = 6.0, 0.3


def hook(sid, cwd, cmd="git push origin HEAD:main"):
    return g.on_pre_tool_call(tool_name="terminal", args={"command": cmd, "workdir": str(cwd)}, session_id=sid, task_id=sid)


def waiting():
    try:
        return json.loads((home / "one-main-queue" / "waiting.json").read_text())
    except Exception:
        return {}


hit = g.decide("git push origin HEAD:main", str(wa))
repo = g.repo_for(hit) if hit else None
check("both copies of the repo share one line (same repo id)", repo and repo == g.repo_for(g.decide("git push origin HEAD:main", str(wb))), repo)
check("…named after the main checkout", repo and repo["name"] == "Forge Desktop" and repo["path"] == str(main), repo)
check("pushing a helper's own branch is never held", hook(A, wa, "git push -u origin helper/tray") is None and not waiting())

events: list = []
seen_waiting: list = []
go = threading.Barrier(2)


def helper(sid, cwd, delay):
    go.wait()
    time.sleep(delay)
    for _ in range(6):
        t0 = time.monotonic()
        r = hook(sid, cwd)
        took = time.monotonic() - t0
        if r is None:
            events.append((sid, "turn", round(took, 1)))
            time.sleep(1.5 if sid == A else 0)  # the first one runs its checks a moment, holding the turn
            p = git("push", "-q", "origin", "HEAD:main", cwd=cwd, ok=False)
            events.append((sid, "pushed" if p.returncode == 0 else "push failed: " + p.stderr.strip()[:200], 0))
            g.on_post_llm_call(session_id=sid)  # its turn ends
            return
        msg = r.get("message", "")
        if "rebase" in msg:
            events.append((sid, "told to rebase", round(took, 1)))
            git("fetch", "-q", "origin", cwd=cwd)
            git("rebase", "-q", "origin/main", cwd=cwd)
        else:
            events.append((sid, "waiting: " + msg, round(took, 1)))


ta = threading.Thread(target=helper, args=(A, wa, 0))
tb = threading.Thread(target=helper, args=(B, wb, 0.05))
ta.start()
tb.start()
for _ in range(40):
    w = waiting()
    if w.get(B, {}).get("place") == 2:
        seen_waiting.append(w)
        break
    time.sleep(0.1)
ta.join(60)
tb.join(60)
print("   events:", events)
evA = [e[1] for e in events if e[0] == A]
evB = [e[1] for e in events if e[0] == B]
check("the first one gets its turn at once and pushes", evA == ["turn", "pushed"], evA)
check("the second waits while the first holds main (place 2 in waiting.json)", bool(seen_waiting) and seen_waiting[0][B]["ahead"] == A,
      seen_waiting)
check("…and its own turn came while it waited, not by failing", next((e[2] for e in events if e[0] == B), 0) >= 1.0, events)
check("…then it's told to rebase on main first, and pushes after", evB == ["told to rebase", "turn", "pushed"], evB)
log = git("log", "--format=%s", "main", cwd=str(origin)).stdout.split("\n")
merges = git("rev-list", "--merges", "main", cwd=str(origin)).stdout.strip()
check("main's history is linear, nothing lost", log[:3] == ["add export.txt", "add tray.txt", "first"] and merges == "", log)
check("the line is empty after both turns ended", waiting() == {}, waiting())

# --- 3. waiting, a turn that runs out, a stopped helper, a finished turn ---------------------------------------------

g.WAIT_FOR, g.CHECK_EVERY = 0.6, 0.2
for w, f in ((wa, "tray2.txt"), (wb, "export2.txt")):
    git("fetch", "-q", "origin", cwd=w)
    git("rebase", "-q", "origin/main", cwd=w)
    (w / f).write_text(f + "\n")
    git("add", ".", cwd=w)
    git("commit", "-q", "-m", f"add {f}", cwd=w)
check("first in line: its turn", hook(A, wa) is None)
r = hook(B, wb)
msg = (r or {}).get("message", "")
check("second in line is told in plain words and keeps working",
      msg.startswith("Waiting for your turn on Forge Desktop's main (2nd in line)") and "Keep working on your branch meanwhile" in msg,
      msg)
w = waiting()
check("waiting.json: the one at work, then the one waiting", w.get(A, {}).get("place") == 1 and w.get(B, {}).get("place") == 2
      and w[B]["repo"] == "Forge Desktop" and w[B]["ahead"] == A, w)
check("a further queue command of the one at work keeps its turn", hook(A, wa, "gh release create v1 --notes x") is None)

g.release(A)
check("its turn ending frees main for the next one", hook(B, wb) is None)
g.release(B)

g.LEASE = 1
check("a turn with a short lease", hook(A, wa) is None)
check("…holds the others back while it lasts", hook(B, wb) is not None)
time.sleep(1.3)
g.LEASE = 15 * 60
check("…and when it runs out the next one goes", hook(B, wb) is None and waiting().get(A, {}).get("place") != 1, waiting())
check("the one whose lease ran out joins the line again behind", hook(A, wa) is not None and waiting().get(A, {}).get("place") == 2)
g.release(B)
q = home / "one-main-queue"
for f in q.glob("*.json"):
    f.unlink()

check("a turn for the helper that's stopped next", hook(A, wa) is None)
check("…the other waits", hook(B, wb) is not None)
(guard / "stopped").mkdir(parents=True, exist_ok=True)
(guard / "stopped" / f"{A}.json").write_text(json.dumps({"session": A, "title": "Tray", "at": time.time()}))
check("One marks it stopped: its place is released and the other goes", hook(B, wb) is None)
check("…and it's no longer shown in line", A not in waiting(), waiting())
g.release(B)

# Told once: running it again without rebasing is its own call (git says what's wrong then).
(guard / "stopped" / f"{A}.json").unlink()
git("push", "-q", "origin", "HEAD:main", cwd=wa)  # main moves past B's branch
r1, r2 = hook(B, wb), hook(B, wb)
check("main moved: told to rebase once, then left to it", r1 is not None and "rebase" in r1["message"] and r2 is None, (r1, r2))
g.release(B)
check("waiting places stay when the one waiting ends its turn", True)

# The engine loads it.
ctx = types.SimpleNamespace(hooks=[])
ctx.register_hook = lambda name, fn: ctx.hooks.append(name)
g.register(ctx)
check("the plugin registers its two hooks", ctx.hooks == ["pre_tool_call", "post_llm_call"], ctx.hooks)
check("other tools are never held", g.on_pre_tool_call(tool_name="read_file", args={"path": "x"}, session_id=A) is None)
check("a command outside any repo is never held",
      g.on_pre_tool_call(tool_name="terminal", args={"command": "git push origin main", "workdir": str(T)}, session_id=A) is None)

shutil.rmtree(T, ignore_errors=True)
print("main queue ok" if fails == 0 else f"main queue: {fails} failed")
sys.exit(1 if fails else 0)
