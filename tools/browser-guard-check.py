"""Checks One's browser guard (tools/overlay/plugins/one-browser-guard) on real commands.

Run: python3 tools/browser-guard-check.py   (prints "browser guard ok" when every case passes)
Every "blocked" case is a command a helper or routine really ran on 2026-10-28 or a close variant.
Nothing here starts a browser: the guard only reads the command text.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
tmp = Path(tempfile.mkdtemp(prefix="one-guard-"))
os.environ["HERMES_HOME"] = str(tmp / "hermes")
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


def blocked(cmd, tool="terminal"):
    key = "command" if tool == "terminal" else "code"
    r = g.on_pre_tool_call(tool_name=tool, args={key: cmd}, session_id="test")
    return isinstance(r, dict) and r.get("action") == "block"


CHROME = '"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"'
LEDGER = "--user-data-dir=/Users/x/.hermes/ai-content-chrome --remote-debugging-port=9333 --no-first-run"

# What opened visible windows today.
check("a routine's `open -g -n -a \"Google Chrome\" --args --headless=new` (args dropped inside One) is blocked",
      blocked(f'open -g -n -a "Google Chrome" --args --headless=new {LEDGER} "https://x.com/home"; echo rc=$?'))
check("a helper's `open -na \"Google Chrome\" --args --headless=new` is blocked",
      blocked(f'pgrep -fl "remote-debugging-port=9333" | head; open -na "Google Chrome" --args --headless=new {LEDGER}; sleep 6'))
check("quitting and reopening Arc with remote debugging is blocked",
      blocked("osascript -e 'tell application \"Arc\" to quit' 2>&1; open -a Arc --args --remote-debugging-port=9222 2>&1"))
check("`open -a Arc` alone is blocked", blocked("open -a Arc"))
check("a web address with plain `open` (default browser) is blocked", blocked("open https://x.com/home"))
check("a web page file with `open` is blocked", blocked("open ~/Desktop/report.html"))
check("`open -b com.google.Chrome` is blocked", blocked("open -b com.google.Chrome"))
check("an alarm-wrapped osascript activating Chrome is blocked",
      blocked("perl -e 'alarm 10; exec @ARGV' osascript -e 'tell application \"Google Chrome\" to activate'"))
check("Chrome's own program without --headless is blocked", blocked(f"{CHROME} {LEDGER} https://x.com/home"))
check("inside bash -c too", blocked(f"bash -c 'cd /tmp && {CHROME} --user-data-dir=/tmp/p'"))
check("Python's webbrowser.open is blocked", blocked("import webbrowser\nwebbrowser.open('https://x.com')", tool="execute_code"))
check("playwright with headless=False is blocked", blocked("b = p.chromium.launch(headless=False)", tool="execute_code"))
check("subprocess open -a Chrome in Python is blocked",
      blocked('import subprocess\nsubprocess.run(["open", "-n", "-a", "Google Chrome", "--args", "--headless=new"])', tool="execute_code"))
check("os.system open -a Arc in Python is blocked", blocked('import os\nos.system("open -a Arc")', tool="execute_code"))
check("browser_exec code that runs open -a Chrome is blocked",
      blocked('import subprocess\nsubprocess.Popen(["open", "-a", "Google Chrome", "https://x.com"])', tool="browser_exec"))
check("Chrome's own program from Python without --headless is blocked",
      blocked(f'import subprocess\nC = {CHROME}\nsubprocess.Popen([C, "--user-data-dir=/tmp/p"])', tool="execute_code"))
check("switching browser.headed on is blocked", blocked("hermes config set browser.headed true"))
check("switching the guard off is blocked", blocked("hermes plugins disable one-browser-guard"))
check("agent-browser --headed is blocked", blocked("agent-browser --headed open https://x.com"))
script = tmp / "ai_chrome.sh"
script.write_text(f'#!/bin/bash\ncurl -s localhost:9333/json/version && exit 0\nopen -g -n -a "Google Chrome" --args --headless=new {LEDGER}\n')
check("a script that runs `open -a Chrome` is blocked when the script is run", blocked(f"sleep 20; {script} >/dev/null 2>&1; echo rc=$?"))

# What must keep working.
check("Chrome's own program with --headless=new is allowed",
      not blocked(f"{CHROME} --headless=new --no-sandbox {LEDGER} https://x.com/home 2>&1 | grep -v crashpad"))
check("a headless screenshot is allowed", not blocked(f"perl -e 'alarm 40; exec @ARGV' {CHROME} --headless=new --screenshot=t.png file:///tmp/t.html"))
check("talking to the hidden browser over its port is allowed", not blocked("curl -s localhost:9223/json/version; curl -s localhost:9333/json/list"))
check("looking for Chrome processes is allowed", not blocked('pgrep -fl "Google Chrome.app/Contents/MacOS/Google Chrome" | cut -c1-150'))
check("reading Chrome's version is allowed", not blocked('defaults read "/Applications/Google Chrome.app/Contents/Info.plist" CFBundleShortVersionString'))
check("opening a folder or a PDF is allowed", not blocked("open ~/Downloads; open -R ~/Desktop/a.pdf; open -a Preview a.pdf"))
check("searching code for headless=False is allowed", not blocked("grep -rn 'headless=False' src/ | head"))
check("osascript for Notes is allowed", not blocked("osascript -e 'tell application \"Notes\" to get name of every note'"))
check("CDP from Python is allowed", not blocked("import json, urllib.request\nurllib.request.urlopen('http://127.0.0.1:9223/json')", tool="execute_code"))
check("a script that only searches for `open -a` in text is allowed (a helper's scan today)",
      not blocked('import re\npat = re.compile(r"(open -a|open -na|Google Chrome\\.app)")\nprint(pat)', tool="execute_code"))
check("a regex for headless=False is allowed", not blocked('import re\nre.findall(r"headless=False", t)', tool="execute_code"))
check("browser_exec driving the hidden browser is allowed", not blocked("# Open the page\nnew_tab('https://x.com')\nwait_for_load()", tool="browser_exec"))
check("other tools pass", g.on_pre_tool_call(tool_name="read_file", args={"path": "/x"}) is None)

# The log, the ask, and one window after a yes.
logf = tmp / "hermes/logs/one-browser-guard.log"
check("each block is logged", logf.exists() and "blocked terminal" in logf.read_text())
ask = json.loads((tmp / "guard/ask.json").read_text())
check("the ask names the browser for One", ask.get("browser") and ask.get("session") == "test")
r = g.on_pre_tool_call(tool_name="terminal", args={"command": "open -a Arc"})
check("the block message asks in plain words", "I need to open Arc to <reason>. Can I?" in r["message"] and "[choices:" in r["message"])
allow = tmp / "guard/allow"
allow.mkdir(parents=True, exist_ok=True)
(allow / "t1.json").write_text(json.dumps({"id": "t1", "browser": "Arc", "expires": time.time() + 600}))
check("a yes for Arc doesn't open Chrome", blocked('open -a "Google Chrome"'))
check("a yes from the chat lets one Arc window through", not blocked("open -a Arc"))
check("only once", blocked("open -a Arc"))
(allow / "t2.json").write_text(json.dumps({"id": "t2", "browser": "Arc", "expires": time.time() - 1}))
check("an old yes doesn't count", blocked("open -a Arc"))
check("the allowed window is logged", "allowed once" in logf.read_text())

# The engine's own words for screens One doesn't have are swapped for One's buttons before the model reads them.
def words(text):
    r = g.on_transform_tool_result(tool_name="browser_vault", result=text)
    return text if r is None else r
vault = "Tell them to run `hermes vault add` or use Desktop → Settings → Passwords & Logins for https://www.monarchmoney.com."
for t in (vault, json.dumps({"error": vault})):
    r = words(t)
    check("Settings → Passwords & Logins becomes Connections › Passwords", "Settings" not in r and "Connections at the top of One, then Passwords" in r)
check("Credential Vault too", "Connections" in words("To save a credential: run `hermes vault add` in a terminal, or in the desktop app open Settings → Credential Vault."))
check("the browser section points at Connections › Browser", "Connections at the top of One (Browser, then Chrome" in words(
    "Enable it in config.yaml (browser.use_real_profile: true) or the desktop Settings → Browser section, then retry."))
check("plain results untouched", g.on_transform_tool_result(tool_name="terminal", result="ok") is None)

print("browser guard ok" if fails == 0 else f"browser guard: {fails} failed")
sys.exit(1 if fails else 0)
