"""One: one helper at a time puts work on a repo's main.

Every helper works in its own copy of a repo (a git worktree, One's HelperRepos), but the end of the work still
lands on one shared ``main``: two helpers could push, merge or release onto it at the same moment, and the second
one's work then clashes with (or quietly drops) the first's. This plugin gives each repo a queue:

- ``decide(command, cwd)`` tells the commands that change a repo's main: ``git push`` to main/master (a refspec
  naming it, or a plain ``git push`` while on it), ``git merge`` / ``git rebase`` run in the repo's main checkout
  while it's on main, ``gh pr merge`` and ``gh release create``. Pushing any other branch is never held.
- Before one runs, its conversation joins the repo's line (``<hermes home>/one-main-queue/<repo id>.json``, repo id
  = sha1 of the repo's shared git folder, so every worktree of a repo shares one line; guarded with ``flock``).
- Not first in line: the command waits a little (re-checking every 5 s), then is held back with a plain message:
  "Waiting for your turn on Forge Desktop's main (2nd in line, behind ...). Keep working on your branch meanwhile;
  run this again when it's your turn." The engine stops any pre_tool_call hook after 30 s (and then blocks the
  command anyway and mutes the hook for a minute), so holding the call for 30 minutes isn't possible: a short wait
  and a held-back message is the safe choice.
- First in line: it holds the turn for 15 minutes, renewed by each further queue command of the same conversation.
  The turn ends when the lease runs out, when its turn ends (``post_llm_call``), or when One marks it stopped
  (``guard/stopped/<session>.json``, the stop feature). A waiting place nobody asked about for 30 minutes goes.
- When it's its turn and the remote main moved past its branch (``git fetch``, then ``git merge-base --is-ancestor
  origin/main HEAD`` fails), it is held back once with: rebase on main and run the checks again first.
- ``<hermes home>/one-main-queue/waiting.json`` ({session: {repo, place, ahead, ...}}) is what One shows under the
  helper's orb: "Waiting for Forge Desktop's main · 2nd in line", or "Putting work on Forge Desktop's main".

Never: a queue for the brain or One's own data; never the person's own terminal (this runs inside the engine only).
Logged to ``logs/one-main-queue.log``. Any error lets the command through (a broken check never stops work).
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shlex
import sqlite3
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Optional

LEASE = 15 * 60  # seconds a turn on main lasts after its last queue command
WAIT_FOR = 15.0  # seconds a queue command waits inside the tool call (the engine gives a hook 30 s at most)
CHECK_EVERY = 5.0
FORGET_AFTER = 30 * 60  # a waiting place nobody asked about for this long goes
FETCH_TIMEOUT = 8.0
MAINS = ("main", "master")

Git = Callable[[list, str], tuple]


# --- where things live --------------------------------------------------------------------------------------------


def hermes_home() -> Path:
    h = os.environ.get("HERMES_HOME")
    if not h:
        try:
            from hermes_constants import get_hermes_home

            h = str(get_hermes_home())
        except Exception:
            h = os.path.expanduser("~/.hermes")
    return Path(h)


def guard_dir() -> Path:
    return Path(os.environ.get("ONE_GUARD_DIR") or (hermes_home().parent / "guard"))


def queue_dir() -> Path:
    return hermes_home() / "one-main-queue"


def log(line: str) -> None:
    try:
        f = hermes_home() / "logs" / "one-main-queue.log"
        f.parent.mkdir(parents=True, exist_ok=True)
        with f.open("a", encoding="utf-8") as h:
            h.write(time.strftime("%Y-%m-%dT%H:%M:%S%z ") + line.replace("\n", " ")[:600] + "\n")
    except Exception:
        pass


def run_git(args: list, cwd: str, timeout: float = 10.0) -> tuple:
    try:
        p = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=timeout,
                           env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
        return p.returncode, p.stdout
    except Exception:
        return 128, ""


# --- which commands put work on main (decide) ----------------------------------------------------------------------

_PUNCT = set("();<>|&")
_PREFIX = {"sudo", "command", "exec", "time", "nice", "nohup", "builtin", "noglob", "env"}
_GIT_VALUE_OPTS = {"-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"}
_PUSH_VALUE_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def segments(command: str) -> list[list[str]]:
    """The simple commands in a shell line (split at && || ; | & and parentheses), redirections left out."""
    text = command.replace("\\\n", " ").replace("\n", " ; ")
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = text.split()
    out: list[list[str]] = []
    cur: list[str] = []
    skip = False
    for t in toks:
        if skip:
            skip = False
            continue
        if t and set(t) <= _PUNCT:
            if "<" in t or ">" in t:  # a redirection: drop "2" in "2>&1" and the file it goes to
                if cur and cur[-1].isdigit():
                    cur.pop()
                skip = True
                continue
            if cur:
                out.append(cur)
            cur = []
            continue
        cur.append(t)
    if cur:
        out.append(cur)
    return out


def _strip_prefix(seg: list[str]) -> list[str]:
    i = 0
    while i < len(seg):
        t = seg[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in _PREFIX:
            i += 1
            continue
        if t.startswith("-") and i > 0 and seg[i - 1] in ("env", "sudo", "nice"):
            i += 1
            continue
        break
    return seg[i:]


def _resolve(p: str, cwd: str) -> str:
    p = os.path.expandvars(os.path.expanduser(p))
    return os.path.normpath(p if os.path.isabs(p) else os.path.join(cwd, p))


def _branch(cwd: str, git: Git) -> str:
    rc, out = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd)
    return out.strip() if rc == 0 else ""


def _abs_dirs(cwd: str, git: Git) -> tuple[str, str]:
    """(this checkout's git folder, the repo's shared git folder), absolute; ("", "") outside a repo."""
    rc, out = git(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], cwd)
    lines = out.split("\n") if rc == 0 else []
    if len(lines) < 2 or not lines[0].startswith("/"):
        rc, out = git(["rev-parse", "--git-dir", "--git-common-dir"], cwd)
        lines = out.split("\n") if rc == 0 else []
        if len(lines) < 2:
            return "", ""
    d, c = (os.path.realpath(os.path.join(cwd, x.strip())) for x in lines[:2])
    return d, c


def _main_checkout_on_main(cwd: str, git: Git) -> bool:
    d, c = _abs_dirs(cwd, git)
    return bool(d) and d == c and _branch(cwd, git) in MAINS


def _push(args: list[str], cwd: str, git: Git) -> Optional[dict]:
    pos: list[str] = []
    dry = every = delete = False
    skip = False
    rest = False
    for a in args:
        if skip:
            skip = False
            continue
        if rest or not a.startswith("-"):
            pos.append(a)
            continue
        if a == "--":
            rest = True
        elif a in ("-n", "--dry-run"):
            dry = True
        elif a in ("--all", "--mirror", "--branches"):
            every = True
        elif a in ("-d", "--delete"):
            delete = True
        elif a in _PUSH_VALUE_OPTS:
            skip = True
    if dry:
        return None
    remote = pos[0] if pos else ""
    specs = pos[1:]
    if every:
        return {"kind": "push", "main": "", "source": None, "remote": remote}
    current = None
    for s in specs:
        s = s.lstrip("+")
        if delete:
            src, dst = None, s
        elif ":" in s:
            src, dst = s.split(":", 1)
            src = src or None
        else:
            src = dst = s
        if dst == "HEAD":
            current = _branch(cwd, git) if current is None else current
            dst = current
        dst = dst[len("refs/heads/"):] if dst.startswith("refs/heads/") else dst
        if dst in MAINS:
            return {"kind": "push", "main": dst, "source": src, "remote": remote}
    if not specs:
        br = _branch(cwd, git)
        if br in MAINS:
            return {"kind": "push", "main": br, "source": "HEAD", "remote": remote}
    return None


def _gh(seg: list[str]) -> Optional[dict]:
    words: list[str] = []
    slug = ""
    skip = False
    for i, a in enumerate(seg[1:], 1):
        if skip:
            skip = False
            continue
        if a in ("-R", "--repo"):
            slug = seg[i + 1] if i + 1 < len(seg) else ""
            skip = True
        elif a.startswith("--repo="):
            slug = a.split("=", 1)[1]
        elif a.startswith("-R") and len(a) > 2:
            slug = a[2:]
        elif not a.startswith("-"):
            words.append(a)
    if words[:2] == ["pr", "merge"]:
        return {"kind": "pr-merge", "slug": slug}
    if words[:2] == ["release", "create"]:
        return {"kind": "release", "slug": slug}
    return None


def decide(command: str, cwd: str, git: Optional[Git] = None) -> Optional[dict]:
    """The first part of a shell command that puts work on a repo's main, or None.

    Returns {"kind": push | merge | rebase | pr-merge | release, "cwd": where it runs, "what": its words, ...}.
    `git` answers the two questions text can't (the current branch, whether this is the main checkout); tests pass a
    stand-in."""
    git = git or run_git
    if not isinstance(command, str) or ("git" not in command and "gh" not in command):
        return None
    here = cwd or os.getcwd()
    for raw in segments(command):
        seg = _strip_prefix(raw)
        if not seg:
            continue
        head = os.path.basename(seg[0])
        if head in ("cd", "pushd") and len(seg) > 1 and not seg[1].startswith("-"):
            here = _resolve(seg[1], here)
            continue
        hit: Optional[dict] = None
        where = here
        if head == "git":
            i = 1
            while i < len(seg) and seg[i].startswith("-"):
                o = seg[i]
                if o == "-C" and i + 1 < len(seg):
                    where = _resolve(seg[i + 1], where)
                    i += 2
                    continue
                i += 2 if o in _GIT_VALUE_OPTS else 1
            sub, args = (seg[i], seg[i + 1:]) if i < len(seg) else ("", [])
            if sub == "push":
                hit = _push(args, where, git)
            elif sub in ("merge", "rebase"):
                stop = {"--abort", "--quit", "--skip", "--edit-todo", "--show-current-patch"}
                if not stop.intersection(args) and _main_checkout_on_main(where, git):
                    hit = {"kind": sub, "main": _branch(where, git), "source": "HEAD", "remote": ""}
        elif head == "gh":
            hit = _gh(seg)
        if hit:
            hit["cwd"] = where
            hit["what"] = " ".join(seg)[:200]
            return hit
    return None


# --- which repo -----------------------------------------------------------------------------------------------------


def humanize(folder: str) -> str:
    """'forge-desktop' -> 'Forge Desktop' (what the person calls it)."""
    words = [w for w in re.split(r"[-_\s]+", folder) if w]
    return " ".join(w[:1].upper() + w[1:] for w in words) or folder


def allowed(path: str) -> bool:
    """Never a queue for the brain, a shared room or One's own data (except work/, where helpers clone things)."""
    p = os.path.realpath(path)
    home = os.path.expanduser("~")
    brain = os.environ.get("ONE_BRAIN_DIR") or os.path.join(home, "Documents", "My Brain")
    support = os.path.realpath(str(hermes_home().parent))
    for no in (os.path.realpath(brain), os.path.realpath(os.path.join(home, "Library", "Mobile Documents"))):
        if p == no or p.startswith(no + "/"):
            return False
    if p == support or (p.startswith(support + "/") and not p.startswith(support + "/work/")):
        return False
    return True


def _origin(gitdir: str) -> str:
    try:
        text = Path(gitdir, "config").read_text(errors="ignore")
    except Exception:
        return ""
    m = re.search(r'\[remote "origin"\][^\[]*?url\s*=\s*(\S+)', text, re.S)
    return m.group(1) if m else ""


def _slug_of(url: str) -> str:
    m = re.search(r"github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", url)
    return f"{m.group(1)}/{m.group(2)}".lower() if m else ""


def local_clone(slug: str, root: Optional[str] = None) -> str:
    """The shared git folder of a clone under ~/Repos whose GitHub origin is `slug` (shortest folder name wins)."""
    root = root or os.environ.get("ONE_REPOS_DIR") or os.path.expanduser("~/Repos")
    best = ""
    try:
        for d in sorted(os.listdir(root), key=len):
            g = os.path.join(root, d, ".git")
            if os.path.isdir(g) and _slug_of(_origin(g)) == slug.lower():
                best = os.path.realpath(g)
                break
    except Exception:
        pass
    return best


def repo_for(hit: dict, git: Optional[Git] = None) -> Optional[dict]:
    """{"id", "path", "name"} of the repo a queue command changes, or None (not a repo, or one never queued)."""
    git = git or run_git
    _, common = _abs_dirs(hit.get("cwd") or os.getcwd(), git)
    slug = (hit.get("slug") or "").strip()
    if slug and (not common or _slug_of(_origin(common)) not in ("", slug.lower())):
        common = local_clone(slug) or ""
        if not common:
            name = slug.rsplit("/", 1)[-1]
            return {"id": hashlib.sha1(f"github:{slug.lower()}".encode()).hexdigest(), "path": "", "name": humanize(name)}
    if not common:
        return None
    path = os.path.dirname(common) if os.path.basename(common) == ".git" else common
    if not allowed(path):
        return None
    name = os.path.basename(path)
    name = name[:-4] if name.endswith(".git") else name
    return {"id": hashlib.sha1(common.encode()).hexdigest(), "path": path, "name": humanize(name)}


# --- the line -------------------------------------------------------------------------------------------------------


def marks() -> set[str]:
    """Conversations One marked stopped (the stop feature): their places are released."""
    out: set[str] = set()
    d = guard_dir() / "stopped"
    try:
        for f in d.iterdir() if d.is_dir() else []:
            if f.suffix != ".json":
                continue
            out.add(f.stem)
            try:
                s = json.loads(f.read_text()).get("session")
                if s:
                    out.add(str(s))
            except Exception:
                pass
    except Exception:
        pass
    return out


def _db_one(sql: str, arg: str) -> Optional[str]:
    try:
        db = hermes_home() / "state.db"
        if not db.exists():
            return None
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute(sql, (arg,)).fetchone()
        finally:
            con.close()
        return str(row[0]) if row and row[0] else None
    except Exception:
        return None


def root_of(sid: str) -> str:
    """The helper's own conversation above a sub-helper's (what One knows the helper by)."""
    cur = sid
    for _ in range(12):
        up = _db_one("select parent_session_id from sessions where id = ?", cur)
        if not up:
            break
        cur = up
    return cur


def title_of(sid: str, root: str) -> str:
    return _db_one("select title from sessions where id = ?", sid) or _db_one("select title from sessions where id = ?", root) or ""


def _qfile(rid: str) -> Path:
    return queue_dir() / f"{rid}.json"


@contextmanager
def _locked(name: str):
    queue_dir().mkdir(parents=True, exist_ok=True)
    with open(queue_dir() / f"{name}.lock", "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def _load(rid: str) -> dict:
    try:
        return json.loads(_qfile(rid).read_text())
    except Exception:
        return {}


def _save(rid: str, q: dict) -> None:
    f = _qfile(rid)
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(q, indent=1))
    tmp.replace(f)


def _stopped(e: dict, have: set[str]) -> bool:
    return any(x and (x in have or re.sub(r"[^A-Za-z0-9_-]", "_", x) in have) for x in (e.get("session"), e.get("root")))


def tidy(q: dict, now: float, have: set[str]) -> None:
    """Places that are over: a stopped helper's, a turn whose lease ran out, a waiting place nobody asked about."""
    name = q.get("name", "?")
    line = []
    for e in q.get("line", []):
        if _stopped(e, have):
            log(f"{e.get('session')}: stopped, its place on {name}'s main is released")
        else:
            line.append(e)
    while line:
        head = line[0]
        if head.get("lease_until") is None:
            head["lease_until"] = now + LEASE  # its turn starts now, held for the lease
            head["turn_at"] = now
            break
        if head["lease_until"] < now:
            log(f"{head.get('session')}: its turn on {name}'s main ran out")
            line.pop(0)
            continue
        break
    q["line"] = line[:1] + [e for e in line[1:] if now - float(e.get("seen") or now) < FORGET_AFTER]


def label(e: Optional[dict]) -> str:
    return (e or {}).get("title") or (e or {}).get("session") or ""


def take(repo: dict, sid: str, root: str = "", title: str = "", now: Optional[float] = None) -> tuple[int, dict, dict]:
    """Join (or keep) this conversation's place in the repo's line. Returns (place, the one just ahead, its entry)."""
    now = time.time() if now is None else now
    rid = repo["id"]
    with _locked(rid):
        q = _load(rid) or {"repo": repo["path"], "name": repo["name"], "line": []}
        q["name"], q["repo"] = repo["name"], repo["path"]
        tidy(q, now, marks())
        line = q["line"]
        e = next((x for x in line if x.get("session") == sid), None)
        if e is None:
            e = {"session": sid, "root": root or sid, "title": title, "joined": now}
            line.append(e)
        e["seen"] = now
        i = line.index(e)
        if i == 0:
            e["lease_until"] = now + LEASE  # renewed by every queue command of the one whose turn it is
            e.setdefault("turn_at", now)
        _save(rid, q)
        ahead = dict(line[i - 1]) if i > 0 else {}
        mine = dict(e)
    write_waiting(now)
    return i + 1, ahead, mine


def remember_told(repo: dict, sid: str, key: str) -> None:
    with _locked(repo["id"]):
        q = _load(repo["id"])
        for e in q.get("line", []):
            if e.get("session") == sid:
                e["told"] = key
        if q:
            _save(repo["id"], q)


def release(sid: str, now: Optional[float] = None, why: str = "its turn ended") -> int:
    """This conversation's turn on any main is over (it ends a turn). Waiting places stay. Returns how many."""
    now = time.time() if now is None else now
    n = 0
    d = queue_dir()
    for f in sorted(d.glob("*.json")) if d.is_dir() else []:
        if f.name == "waiting.json":
            continue
        rid = f.stem
        with _locked(rid):
            q = _load(rid)
            line = q.get("line", [])
            if line and line[0].get("session") == sid:
                line.pop(0)
                tidy(q, now, marks())
                _save(rid, q)
                n += 1
                log(f"{sid}: {why}, {q.get('name')}'s main is free for the next one")
    if n:
        write_waiting(now)
    return n


def write_waiting(now: Optional[float] = None) -> dict:
    """{session: {repo, path, place, ahead, root, title, lease_until, at}} over every repo's line, for One's orbs."""
    now = time.time() if now is None else now
    out: dict[str, dict] = {}
    have = marks()
    d = queue_dir()
    with _locked("waiting"):
        for f in sorted(d.glob("*.json")) if d.is_dir() else []:
            if f.name == "waiting.json":
                continue
            try:
                q = json.loads(f.read_text())
            except Exception:
                continue
            line = [e for e in q.get("line", []) if not _stopped(e, have)]
            if line and float(line[0].get("lease_until") or now) < now:
                line = line[1:]
            for i, e in enumerate(line):
                out[str(e.get("session"))] = {
                    "repo": q.get("name", ""), "path": q.get("repo", ""), "place": i + 1,
                    "ahead": label(line[i - 1]) if i > 0 else "", "root": e.get("root") or "",
                    "title": e.get("title") or "", "lease_until": e.get("lease_until"), "at": e.get("seen") or now,
                }
        try:
            d.mkdir(parents=True, exist_ok=True)
            tmp = d / "waiting.tmp"
            tmp.write_text(json.dumps(out, indent=1))
            tmp.replace(d / "waiting.json")
        except Exception as e:
            log(f"waiting write error: {e}")
    return out


# --- what the helper is told ----------------------------------------------------------------------------------------


def ordinal(n: int) -> str:
    suffix = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def waiting_message(name: str, place: int, ahead: str) -> str:
    behind = f", behind \u201c{ahead}\u201d" if ahead and not ahead.startswith(("local-", "20")) else ""
    return (f"Waiting for your turn on {name}'s main ({ordinal(place)} in line{behind}). Keep working on your branch "
            f"meanwhile; run this again when it's your turn (try again in a few minutes). This command did not run.")


def rebase_message(name: str, main: str, remote: str) -> str:
    r = remote or "origin"
    return (f"It's your turn on {name}'s main, but main moved since your branch started (someone else put work on it). "
            f"First rebase your branch on it ({'git fetch ' + r}, then git rebase {r}/{main}) and run the checks again, "
            f"then run this again. Your turn is kept for {LEASE // 60} minutes. This command did not run.")


def behind_main(hit: dict, repo: dict, mine: dict, git: Optional[Git] = None) -> Optional[str]:
    """Its turn, but the remote main moved past its branch: the rebase message (once per state), else None."""
    git = git or run_git
    kind, cwd = hit.get("kind"), hit.get("cwd") or ""
    if kind in ("release", "rebase") or not cwd or ("source" in hit and hit.get("source") is None):
        return None
    if kind == "pr-merge" and _branch(cwd, git) in MAINS + ("",):
        return None  # merged on GitHub from main's own checkout: nothing local to compare
    remote = hit.get("remote") or "origin"
    if "/" in remote or ":" in remote:
        remote = "origin"  # a URL: compare with origin
    mains = [hit["main"]] if hit.get("main") else list(MAINS)
    main = ""
    for b in mains:
        rc, _ = run_git(["fetch", "-q", remote, b], cwd, FETCH_TIMEOUT) if git is run_git else git(["fetch", "-q", remote, b], cwd)
        if rc == 0:
            main = b
            break
    if not main:
        return None  # no network or no such branch: let git itself say
    src = hit.get("source") or "HEAD"
    rc, _ = git(["merge-base", "--is-ancestor", f"refs/remotes/{remote}/{main}", src], cwd)
    if rc != 1:
        return None
    key = (git(["rev-parse", f"refs/remotes/{remote}/{main}"], cwd)[1].strip() + ":" + git(["rev-parse", src], cwd)[1].strip())
    if mine.get("told") == key:
        return None  # told once already for exactly this state: its call
    remember_told(repo, mine.get("session", ""), key)
    return rebase_message(repo["name"], main, remote)


# --- hooks ----------------------------------------------------------------------------------------------------------


def cwd_for(args: dict, session_id: str = "", task_id: str = "") -> str:
    w = args.get("workdir")
    if isinstance(w, str) and w.strip():
        return _resolve(w.strip(), os.getcwd())
    try:
        from tools.terminal_tool import get_session_cwd

        keys = []
        try:
            from tools.approval import get_current_session_key

            keys.append(get_current_session_key(default=""))
        except Exception:
            pass
        for k in [*keys, task_id, session_id]:
            c = get_session_cwd(k) if k else None
            if c:
                return c
    except Exception:
        pass
    return _db_one("select cwd from sessions where id = ?", session_id) or os.environ.get("TERMINAL_CWD") or os.getcwd()


def turn(hit: dict, repo: dict, sid: str, git: Optional[Git] = None, sleep: Callable[[float], None] = time.sleep):
    """Wait for this conversation's turn on the repo's main; None lets the command run, else a block directive."""
    root = root_of(sid)
    title = title_of(sid, root)
    deadline = time.monotonic() + WAIT_FOR
    told_wait = False
    while True:
        place, ahead, mine = take(repo, sid, root, title)
        if place == 1:
            break
        if not told_wait:
            log(f"{sid}: waits on {repo['name']}'s main, {ordinal(place)} in line: {hit.get('what')}")
            told_wait = True
        if time.monotonic() + CHECK_EVERY > deadline:
            return {"action": "block", "message": waiting_message(repo["name"], place, label(ahead))}
        sleep(CHECK_EVERY)
    msg = behind_main(hit, repo, mine, git)
    if msg:
        log(f"{sid}: its turn on {repo['name']}'s main, told to rebase first: {hit.get('what')}")
        return {"action": "block", "message": msg}
    log(f"{sid}: its turn on {repo['name']}'s main: {hit.get('what')}")
    return None


def on_pre_tool_call(tool_name: str = "", args: Optional[dict[str, Any]] = None, session_id: str = "", task_id: str = "", **_: Any):
    try:
        if tool_name != "terminal" or not isinstance(args, dict):
            return None
        cmd = args.get("command")
        if not isinstance(cmd, str) or ("git" not in cmd and "gh" not in cmd):
            return None
        hit = decide(cmd, cwd_for(args, session_id, task_id))
        if not hit:
            return None
        repo = repo_for(hit)
        if not repo:
            return None
        return turn(hit, repo, session_id or task_id or "default")
    except Exception as e:  # never break a command because the queue itself failed
        log(f"check error: {e}")
        return None


def on_post_llm_call(session_id: str = "", task_id: str = "", **_: Any):
    """Its turn ended: whatever it put on main is done; the next one in line goes."""
    try:
        sid = session_id or task_id
        if sid:
            release(sid)
    except Exception as e:
        log(f"release error: {e}")
    return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("post_llm_call", on_post_llm_call)
    log("loaded")
