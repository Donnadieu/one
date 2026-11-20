"""End to end, engine half: a hand-off shows the tab the ASKING helper was working in, never another helper's.

What happened (Nov 19 2026, One 0.9.138): two helpers shared the hidden browser on 9224. The daily-post helper opened
X's log-in page and called hand_off for a sign-in; the window showed the other helper's Greenhouse job form instead
(its captcha scored as a human step, X's plain log-in page didn't). Putting the X tab in front right before trying
again didn't help, so X was skipped that day.

Here, in one throwaway headless Chrome (own port, scratch profile, local pages, no account):
  helper 1 opens tab A (tests/handoff/pages/login.html, a plain log-in page, like X's) through the real browser_exec;
  helper 2 opens tab B (pages/captcha.html, a robot check, like Greenhouse's) through the real browser_exec, after it.
Helper 1 then calls hand_off twice, as the daily-post helper did: kind=check, then kind=sign_in. Both requests One
gets (what the window shows: the request's target_id and url) must be tab A, brought to the front of its browser.
Before the fix both showed tab B. "The person" answers each with Cancel, so nothing waits.
Env: OVERLAY, ONE_HANDOFF_DIR (its own folder), ONE_HANDOFF_CDP=http://127.0.0.1:<port>, ONE_TEST_WEB (site port).
"""
import importlib.util, json, os, sys, threading, time, urllib.request
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
port = int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
web = int(os.environ.get("ONE_TEST_WEB", "8791"))
base = f"http://127.0.0.1:{port}"
site = f"http://127.0.0.1:{web}"
os.environ["BROWSER_CDP_URL"] = base  # what One sets as browser.cdp_url: helpers share this one browser
os.environ["ONE_HANDOFF_SIBLING_PORTS"] = ""  # no sibling browsers here: a sign-in is never "found elsewhere"
d = Path(os.environ["ONE_HANDOFF_DIR"])

overlay = Path(os.environ["OVERLAY"])
for name, f in (("tools.one_own_tab", overlay.with_name("one_own_tab.py")), ("tools.one_human_step", overlay)):
    if f.exists():  # the version under test, not whatever the engine has installed
        spec = importlib.util.spec_from_file_location(name, f)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
hs = sys.modules["tools.one_human_step"]
import tools.browser_vault_tool as bv  # noqa: E402
import tools.browser_use_cli as bu  # noqa: E402

hs.install(vars(bv))  # what the engine's hook does at start (idempotent)


def pages() -> list:
    return [t for t in json.load(urllib.request.urlopen(f"{base}/json/list")) if t["type"] == "page"]


for t in pages():  # earlier checks' tabs: start from one blank tab
    if t["url"] != "about:blank":
        urllib.request.urlopen(f"{base}/json/close/{t['id']}")


def helper(task: str, page: str, session: str = "") -> str:
    # The address is put together in the page script so the engine's URL routing (not under test) never sees it.
    code = f'new_tab("http:" + "//127.0.0.1:{web}/{page}")\nwait_for_load()\nprint("TAB", current_tab()["targetId"])\n'
    out = bu.browser_exec(code=code, session=session, timeout_s=90, task_id=task)
    out = json.loads(out) if isinstance(out, str) else out
    tab = next((ln.split()[1] for ln in str(out.get("output", "")).splitlines() if ln.startswith("TAB ")), "")
    print(f"{task} opened {page}: {tab or out}")
    return tab


a = helper("helper-1-daily-post", "login.html")  # no session name, like the daily-post helper
b = helper("helper-2-job-apply", "captcha.html", session="jobs")
if not a or not b or a == b:
    print("OWN TAB SETUP FAIL: browser_exec didn't open two tabs", a, b)
    bu.stop_harness_daemons()
    os._exit(1)
print("tab B is a human step:", hs.page_step(next(t for t in pages() if t["id"] == b)["webSocketDebuggerUrl"]))

seen: list = []


def person():  # plays One: reads each request (what the window would show), then taps Cancel
    done: set = set()
    while True:
        for r in sorted(d.glob("*.request.json")):
            if r.name in done:
                continue
            done.add(r.name)
            req = json.loads(r.read_text())
            front = pages()[0]["id"] if pages() else ""
            seen.append((req, front))
            print("REQUEST:", req["kind"], "| target", req["target_id"], "| url", req["url"],
                  "| brought forward", req.get("brought_forward"), "| first in /json/list", front)
            (d / f"{req['id']}.answer.json").write_text(json.dumps({"answer": "cancelled", "by": "test"}))
        time.sleep(0.3)


threading.Thread(target=person, daemon=True).start()
results = [hs.hand_off(kind=k, task_id="helper-1-daily-post", why="X sign-in", wait=30) for k in ("check", "sign_in")]
time.sleep(1)
for r in results:
    print("hand_off ->", json.dumps(r)[:300])
ok = len(seen) == 2
for req, front in seen:
    ok = ok and req["target_id"] == a and req["url"].endswith("/login.html") and req.get("brought_forward") is True
    if front != a:  # Chrome lists the most recently active tab first; told, not failed on (headless may not reorder)
        print("note: tab A wasn't first in /json/list after the hand-off")
print("tab A (helper 1):", a, "| tab B (helper 2):", b)
print("OWN TAB", "PASS" if ok else "FAIL")
bu.stop_harness_daemons()
os._exit(0 if ok else 1)
