"""One's browser guard (installed by One into <hermes home>/plugins/one-browser-guard).

The rule: no assistant, helper or routine opens a visible browser window unless the person said yes
to that exact window first. Everything runs in the background on the saved hidden browsers (One's on
port 9223, Project Ledger's on 9333, both headless).

This ``pre_tool_call`` hook reads every ``terminal`` command and ``execute_code`` script (and the
shell scripts they run) before it runs, and blocks anything that would open, show or drive a visible
browser:
- ``open`` with a browser app, bundle id, web address or web page. Inside One's folder lock macOS
  drops ``--args`` from ``open``, so even ``open -g -n -a "Google Chrome" --args --headless=new``
  starts a plain, visible Chrome window. That is what opened windows over the person's work.
- ``osascript`` that talks to a browser (activate, open location, quit, new window...).
- a browser's own program started without ``--headless``.
- ``webbrowser.open``, ``headless=False`` / ``headless: false``, ``--headed``, ``AGENT_BROWSER_HEADED``.
Each block is logged to ``<hermes home>/logs/one-browser-guard.log`` and leaves ``guard/ask.json``
so One knows what is waiting for a yes. When the person says yes in One's chat, One (outside the
folder lock) writes ``guard/allow/<id>.json``; the engine can read that folder but not write it, so
only a real yes unlocks one window, once.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import time
from pathlib import Path
from typing import Any, Optional

# App names (lowercase, without .app) and bundle ids -> the name said to the person.
BROWSERS = {
    "google chrome": "Chrome", "chrome": "Chrome", "google chrome canary": "Chrome", "google chrome beta": "Chrome",
    "chromium": "Chromium", "arc": "Arc", "safari": "Safari", "safari technology preview": "Safari",
    "firefox": "Firefox", "firefox developer edition": "Firefox", "brave browser": "Brave", "brave": "Brave",
    "microsoft edge": "Edge", "edge": "Edge", "opera": "Opera", "vivaldi": "Vivaldi", "orion": "Orion",
    "zen": "Zen", "zen browser": "Zen", "dia": "Dia", "comet": "Comet",
}
BUNDLES = {
    "com.google.chrome": "Chrome", "com.google.chrome.canary": "Chrome", "com.google.chrome.beta": "Chrome",
    "company.thebrowser.browser": "Arc", "com.apple.safari": "Safari", "org.mozilla.firefox": "Firefox",
    "com.brave.browser": "Brave", "com.microsoft.edgemac": "Edge", "org.chromium.chromium": "Chromium",
    "com.operasoftware.opera": "Opera", "com.vivaldi.vivaldi": "Vivaldi", "company.thebrowser.dia": "Dia",
}
_APP_NAMES = "Google Chrome(?: Canary| Beta)?|Chromium|Arc|Brave Browser|Microsoft Edge|Firefox(?: Developer Edition)?|Safari|Opera|Vivaldi|Orion|Zen(?: Browser)?|Dia|Comet"
# A browser's own program, e.g. /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
BINARY = re.compile(r"(%s)\.app/Contents/MacOS/" % _APP_NAMES, re.I)
# Commands that only look at a browser (list, read, stop it), never show one.
LOOK_ONLY = {"pgrep", "pkill", "ps", "grep", "egrep", "rg", "lsof", "kill", "killall", "ls", "cat", "stat", "codesign",
             "defaults", "mdls", "file", "otool", "echo", "printf", "head", "tail", "wc", "du", "find", "xattr", "plutil",
             "spctl", "test", "[", "which", "type", "readlink", "realpath", "sed", "awk", "cut", "sort"}
WRAPPERS = {"sudo", "exec", "nohup", "command", "builtin", "time", "caffeinate", "nice", "env", "then", "do", "else", "!", "{", "("}
WEB = re.compile(r"^(https?|file)://|\.(html?|webloc|url|xhtml)$", re.I)
SPLIT = re.compile(r"&&|\|\||[;|&\n]|\$\(|`|\bthen\b|\bdo\b")
HEADED = [
    (re.compile(r"\bwebbrowser\.(open|open_new|open_new_tab|get)\s*\(|-m\s+webbrowser\b"), "Python's webbrowser opens the default browser in front"),
    (re.compile(r"headless\s*[=:]\s*(False|false|0)\b|[\"']headless[\"']\s*:\s*(false|False)"), "a browser started with headless off shows a window"),
    (re.compile(r"(^|\s)--headed\b"), "--headed shows a browser window"),
    (re.compile(r"AGENT_BROWSER_HEADED\s*=\s*[\"']?(1|true|yes)", re.I), "AGENT_BROWSER_HEADED shows a browser window"),
    (re.compile(r"config\s+set\s+browser\.headed\s+[\"']?(true|1|yes)", re.I), "browser.headed makes every browser tool open a window"),
    (re.compile(r"plugins\s+(disable|remove|uninstall)\s+[\"']?one-browser-guard", re.I), "it would switch off the guard that keeps browsers hidden"),
]
# Python lines that really start a program (a mention inside a string or a regex doesn't).
EXEC_LINE = re.compile(r"\b(subprocess\.\w+|os\.system|os\.popen|os\.exec\w*|os\.spawn\w*|Popen|check_call|check_output|getoutput|getstatusoutput|pty\.spawn)\s*\(")
OPEN_FLAGS_WITH_VALUE = {"-a", "-b", "--env", "--stdin", "--stdout", "--stderr", "-u", "--url"}
MAX_SCRIPT = 256 * 1024


# MARK: places

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


def log(line: str) -> None:
    try:
        f = hermes_home() / "logs" / "one-browser-guard.log"
        f.parent.mkdir(parents=True, exist_ok=True)
        with f.open("a", encoding="utf-8") as h:
            h.write(time.strftime("%Y-%m-%dT%H:%M:%S%z ") + line.replace("\n", " ")[:600] + "\n")
    except Exception:
        pass


# MARK: what a command would do

def _browser_of_app(name: str) -> Optional[str]:
    n = os.path.basename(name.strip().rstrip("/"))
    if n.lower().endswith(".app"):
        n = n[:-4]
    return BROWSERS.get(n.lower())


def _tokens(seg: str) -> list[str]:
    try:
        return shlex.split(seg, posix=True)
    except ValueError:
        return seg.split()


def _command_start(toks: list[str]) -> int:
    """Index of the real command in a segment, past VAR=x assignments and wrappers like nohup or perl's alarm."""
    i = 0
    while i < len(toks):
        t = toks[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in WRAPPERS:
            i += 1
            continue
        if t in ("timeout", "gtimeout") and i + 1 < len(toks):
            i += 2
            continue
        if t == "perl" and i + 2 < len(toks) and toks[i + 1] == "-e" and "exec" in toks[i + 2]:
            i += 3
            continue
        return i
    return len(toks)


def check_open(args: list[str]) -> Optional[tuple[str, str]]:
    """``open <args>``: (browser, why) when it would open a browser."""
    browser = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--args":
            break
        if a in ("-a", "-b") or (re.fullmatch(r"-[A-Za-z]{2,}", a) and a[-1] in "ab"):
            if i + 1 >= len(args):
                break
            v = args[i + 1]
            browser = browser or (_browser_of_app(v) if a[-1] == "a" else BUNDLES.get(v.lower()))
            i += 2
            continue
        if a in ("-u", "--url") and i + 1 < len(args):
            if WEB.search(args[i + 1]):
                browser = browser or "your browser"
            i += 2
            continue
        if a in OPEN_FLAGS_WITH_VALUE:
            i += 2
            continue
        if a == "-R":  # reveal in Finder
            return None
        if not a.startswith("-"):
            if a.lower().rstrip("/").endswith(".app"):
                browser = browser or _browser_of_app(a)
            elif WEB.search(a):
                browser = browser or "your browser"
        i += 1
    if not browser:
        return None
    if any(x.startswith("--headless") for x in args):
        why = ("inside One, `open` drops everything after --args, so --headless never reaches it and a normal "
               f"{browser} window opens")
    else:
        why = f"`open` puts a {browser} window in front of their work"
    return browser, why


def check_osascript(text: str) -> Optional[tuple[str, str]]:
    names = re.findall(r"\b(?:application|app)\s+(?:id\s+)?\"([^\"]+)\"", text, re.I)
    for n in names:
        b = _browser_of_app(n) or BUNDLES.get(n.lower())
        if b:
            return b, f"AppleScript would control {b} on their screen (show, open or quit its windows)"
    return None


def check_segment(seg: str) -> Optional[tuple[str, str]]:
    toks = _tokens(seg)
    i = _command_start(toks)
    if i >= len(toks):
        return None
    cmd = os.path.basename(toks[i])
    rest = toks[i + 1:]
    if cmd == "open":
        return check_open(rest)
    if cmd == "osascript":
        text = " ".join(rest)
        for t in rest:  # a script file
            p = Path(os.path.expanduser(t))
            if t.endswith((".applescript", ".scpt")) and p.is_file():
                try:
                    text += "\n" + p.read_text(errors="ignore")[:MAX_SCRIPT]
                except Exception:
                    pass
        return check_osascript(text)
    if cmd in LOOK_ONLY:
        return None
    for rx, why in HEADED:
        if rx.search(seg):
            return "a browser", why
    m = BINARY.search(seg)
    if m and "--headless" not in seg and not re.search(r"(^|\s)--?version\b", seg):
        b = _browser_of_app(m.group(1)) or m.group(1)
        return b, f"{b} started without --headless shows a window"
    return None


def scripts_run_by(command: str) -> list[Path]:
    """Shell scripts a command runs (``bash x.sh``, ``./x.sh``, ``$HOME/.cache/x.sh``), so a script can't hide an `open`."""
    out = []
    home = os.path.expanduser("~")
    for t in _tokens(command.replace("$HOME", home).replace("${HOME}", home)):
        t = os.path.expanduser(t)
        if not t.endswith((".sh", ".bash", ".zsh", ".command")) or len(out) >= 8:
            continue
        p = Path(t)
        try:
            if p.is_file() and p.stat().st_size <= MAX_SCRIPT:
                out.append(p)
        except Exception:
            pass
    return out


def split_segments(command: str) -> list[str]:
    """Splits a shell line into simple commands at ; & | && || newlines, $( and backticks, outside quotes."""
    out, cur, q, i = [], [], "", 0
    while i < len(command):
        ch = command[i]
        if q:
            cur.append(ch)
            if ch == q:
                q = ""
            elif ch == "\\" and q == '"' and i + 1 < len(command):
                cur.append(command[i + 1])
                i += 1
        elif ch in "'\"":
            q = ch
            cur.append(ch)
        elif ch in ";&|\n`" or command.startswith("$(", i):
            out.append("".join(cur))
            cur = []
            if command.startswith("$(", i):
                i += 1
        else:
            cur.append(ch)
        i += 1
    out.append("".join(cur))
    segs = []
    for s in out:  # `if x; then open ...`, `for ...; do open ...`
        s = re.sub(r"^\s*(then|do|else|\{|\()\s+", "", s)
        if s.strip():
            segs.append(s)
    return segs


def check_shell(command: str, depth: int = 0) -> Optional[tuple[str, str]]:
    """(browser, why) when this shell command would open, show or drive a visible browser; else None."""
    if not command:
        return None
    for seg in split_segments(command):
        hit = check_segment(seg)
        if hit:
            return hit
    # bash -c "...", zsh -lc '...': look inside the quoted command too.
    for inner in re.findall(r"\b(?:ba|z)?sh\s+-\w*c\s+(\"[^\"]*\"|'[^']*')", command):
        hit = check_shell(inner[1:-1], depth + 1)
        if hit:
            return hit
    if depth < 2:
        for p in scripts_run_by(command):
            try:
                hit = check_shell(p.read_text(errors="ignore"), depth + 1)
            except Exception:
                hit = None
            if hit:
                return hit[0], f"{hit[1]} (inside {p.name})"
    return None


def _code_only(line: str) -> str:
    """The line with its string literals blanked, so a regex or a printed word isn't read as code."""
    return re.sub(r"[rbuRBUfF]{0,2}(\"[^\"\\]*(?:\\.[^\"\\]*)*\"|'[^'\\]*(?:\\.[^'\\]*)*')", "''", line)


def check_code(code: str) -> Optional[tuple[str, str]]:
    """execute_code / browser_exec: Python that would start or show a visible browser (subprocess lists included)."""
    if not code:
        return None
    for line in code.splitlines():
        bare = _code_only(line)
        if re.search(r"\bwebbrowser\.(open|open_new|open_new_tab|get)\s*\(", bare):
            return "a browser", "Python's webbrowser opens the default browser in front"
        if re.search(r"\bheadless\s*=\s*(False|0)\b", bare) or re.search(r"[\"']headless[\"']\s*:\s*(False|0)\b", line):
            return "a browser", "a browser started with headless off shows a window"
    execs = [ln for ln in code.splitlines() if EXEC_LINE.search(_code_only(ln))]
    for line in execs:
        # subprocess.run(["open", "-a", "Google Chrome"]) -> open -a 'Google Chrome'; os.system("open -a Arc") -> as written.
        lits = [x[1:-1] for x in re.findall(r"\"[^\"]*\"|'[^']*'", line)]
        if "[" in line and len(lits) > 1:
            flat = " ".join(shlex.quote(x) for x in lits)
        elif lits:
            flat = " ".join(lits)
        else:
            flat = re.sub(r"[\"'\[\],]+", " ", line)
        hit = check_shell(flat, 1)
        if hit:
            return hit
        if re.search(r"(^|\s)(/usr/bin/)?open\s", flat) or re.search(r"(^|\s)(/usr/bin/)?osascript\s", flat):
            m = re.search(r"(?:^|\s)((?:/usr/bin/)?(?:open|osascript)\s.*)$", flat)
            hit = check_segment(m.group(1)) if m else None
            if not hit and "osascript" in flat:
                hit = check_osascript(line)
            if hit:
                return hit
        for rx, why in HEADED:
            if rx.search(flat):
                return "a browser", why
    if execs and "--headless" not in code:
        m = BINARY.search(code)
        if m and not re.search(r"(pgrep|pkill|ps\b|lsof|grep)", " ".join(execs)):
            b = _browser_of_app(m.group(1)) or m.group(1)
            return b, f"{b} started without --headless shows a window"
    return None


def check_tool(tool_name: str, args: dict[str, Any]) -> Optional[tuple[str, str]]:
    if tool_name == "terminal":
        return check_shell(str(args.get("command") or ""))
    if tool_name in ("execute_code", "browser_exec"):
        return check_code(str(args.get("code") or ""))
    return None


# MARK: one window after a yes

def take_allowance(browser: str) -> Optional[str]:
    """Uses up one yes from One's chat for this browser, if there is a fresh one. Returns its id."""
    g = guard_dir()
    allow = g / "allow"
    used_f = g / "used.json"
    try:
        used = set(json.loads(used_f.read_text())) if used_f.exists() else set()
    except Exception:
        used = set()
    try:
        files = sorted(allow.glob("*.json"))
    except Exception:
        return None
    now = time.time()
    for f in files:
        try:
            j = json.loads(f.read_text())
        except Exception:
            continue
        tid = str(j.get("id") or f.stem)
        if tid in used or float(j.get("expires") or 0) < now:
            continue
        want = str(j.get("browser") or "")
        if want not in ("any", browser) and browser != "a browser" and browser != "your browser":
            continue
        used.add(tid)
        try:
            used_f.write_text(json.dumps(sorted(used)))
        except Exception:
            return None  # can't record it as used: don't let it through
        return tid
    return None


def leave_ask(browser: str, why: str, tool: str, what: str, session_id: str) -> None:
    try:
        g = guard_dir()
        g.mkdir(parents=True, exist_ok=True)
        j = {"browser": browser, "why": why, "tool": tool, "command": what[:400], "session": session_id, "at": time.time()}
        tmp = g / "ask.json.tmp"
        tmp.write_text(json.dumps(j))
        os.replace(tmp, g / "ask.json")
    except Exception:
        pass


def block_message(browser: str, why: str) -> str:
    b = "a browser" if browser in ("a browser", "your browser") else browser
    return (
        f"One blocked this: it would open a visible {'browser' if b == 'a browser' else b} window on their screen ({why}). "
        "Their rule: no visible browser window unless they said yes to that exact window first. "
        "Keep working in the background: use the hidden browser One keeps on port 9223 (Project Ledger's on 9333), "
        "headless. If that port isn't answering, wait 20 seconds and try again: One starts it again by itself. "
        "If you must start a hidden Chrome yourself, run Chrome's own program with --headless=new, never `open`. "
        f"If this job truly needs a visible window, ask them in plain words: \"I need to open {b if b != 'a browser' else '<browser>'} "
        "to <reason>. Can I?\" (say the reason), end with [choices: Yes, open it | No, stay hidden], and wait. "
        "Only their yes in One's chat unlocks one window, once. In a scheduled routine nobody can say yes: skip that step and report it."
    )


def on_pre_tool_call(tool_name: str = "", args: Optional[dict[str, Any]] = None, session_id: str = "", **_: Any):
    try:
        args = args if isinstance(args, dict) else {}
        hit = check_tool(tool_name, args)
        if not hit:
            return None
        browser, why = hit
        what = str(args.get("command") or args.get("code") or "")
        tid = take_allowance(browser)
        if tid:
            log(f"allowed once ({tool_name}, session {session_id or '?'}): their yes in chat ({tid}) for a visible {browser} window: {what[:300]}")
            return None
        log(f"blocked {tool_name} (session {session_id or '?'}): would open a visible {browser} window: {why}: {what[:300]}")
        leave_ask(browser, why, tool_name, what, session_id)
        return {"action": "block", "message": block_message(browser, why)}
    except Exception as e:  # never break a tool call because the guard itself failed
        log(f"guard error on {tool_name}: {e}")
        return None


# --- One's own words for the engine's tool messages -------------------------------------------------------------
# The engine's tools were written for another app: they tell the model to send people to "Desktop → Settings →
# Passwords & Logins", "Settings → Credential Vault", `hermes vault add` or "the desktop Settings → Browser section".
# One has none of those, and the model repeats them to the person (EK was sent hunting for a Settings screen). Every
# tool result passes through here before the model sees it; the screens are swapped for One's real buttons.
_ARROW = r"\s*(?:→|\\u2192|->)\s*"
_PASSWORDS = "click Connections at the top of One, then Passwords, and connect their password manager (or sign in themselves on the site in the hidden browser)"
SCREEN_FIXES = [
    (re.compile(r"run `hermes vault add`(?: in a terminal)?,? or (?:use|in the desktop app open) (?:Desktop" + _ARROW + r")?Settings" + _ARROW
                + r"(?:Passwords (?:&|\\u0026|and) Logins|Credential Vault)"), _PASSWORDS),
    (re.compile(r"(?:Enable it in config\.yaml \(browser\.use_real_profile: true\) or )?the desktop Settings" + _ARROW + r"Browser section"),
     "Their own Chrome is connected in Connections at the top of One (Browser, then Chrome, then Connect; One copies its sign-ins into a hidden browser)"),
    (re.compile(r"(?:Desktop" + _ARROW + r")?Settings" + _ARROW + r"(?:Passwords (?:&|\\u0026|and) Logins|Credential Vault)"), "Connections, then Passwords"),
    (re.compile(r"(?:Desktop" + _ARROW + r")?Settings" + _ARROW + r"Browser"), "Connections, then Browser"),
    (re.compile(r"`hermes vault add`"), "Connections, then Passwords"),
]


def one_words(text: str) -> str:
    """The same message with One's real buttons in place of screens One doesn't have."""
    for rx, to in SCREEN_FIXES:
        text = rx.sub(to, text)
    return text


def on_transform_tool_result(tool_name: str = "", result: Any = None, **_: Any):
    try:
        if not isinstance(result, str) or ("Settings" not in result and "hermes vault" not in result):
            return None
        fixed = one_words(result)
        return fixed if fixed != result else None
    except Exception as e:  # never break a tool result because the rewrite failed
        log(f"screen-words error on {tool_name}: {e}")
        return None


def register(ctx) -> None:
    ctx.register_hook("pre_tool_call", on_pre_tool_call)
    ctx.register_hook("transform_tool_result", on_transform_tool_result)
