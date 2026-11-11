"""End to end, engine half: a code step on a page that exists ONLY as a form POST answer (like DocuSign's sign-up
"enter the code we sent"). Any reopen of its address lands on a log-in page, so the code must go into the very tab
the helper was on. Real Chrome (throwaway, own port), real browser_vault with One's overlay wired the way One installs
it, local site tests/handoff/post_server.py.

Round 1, the person: enter_code can't get the code itself, so One is asked (its card's box). The One half
(`One --test-human-step`) plays the person: it taps "yes" on whatever One shows, then sends the code through the
card's box. Checks: the page was never reopened (the site saw no GET of a POST-only page), the code went into the SAME
tab, the site accepted it with the tab's own hidden one-time state, and the helper carries on in that tab.
Round 2, an inbox: the code is in an inbox One can read (a stand-in inbox, ONE_INBOX_DIR): filled with nobody asked.
Env: OVERLAY, ONE_HANDOFF_DIR, ONE_HANDOFF_CDP=http://127.0.0.1:<port>, HERMES_HOME (scratch), ONE_TEST_WEB (site port).
"""
import importlib.util, json, os, sys, time, urllib.request
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)

import tools.browser_vault_tool as bv
from tools.browser_supervisor import SUPERVISOR_REGISTRY
from tools.browser_tool_cdp import _get_dialog_policy_config
from websockets.sync.client import connect

port = int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
web = int(os.environ.get("ONE_TEST_WEB", "8791"))
base = f"http://127.0.0.1:{port}"
fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


def pages():
    return [t for t in json.load(urllib.request.urlopen(base + "/json/list")) if t["type"] == "page"]


def site_state(host="127.0.0.1"):
    return json.load(urllib.request.urlopen(f"http://{host}:{web}/state.json"))


def ev(target, expr):
    t = next((x for x in pages() if x["id"] == target), None)
    if t is None:
        return None
    with connect(t["webSocketDebuggerUrl"], max_size=8 << 20) as ws:
        ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "returnByValue": True}}))
        while True:
            m = json.loads(ws.recv(timeout=5))
            if m.get("id") == 1:
                return ((m.get("result") or {}).get("result") or {}).get("value")


def post_code_tab(host, email):
    """Opens the sign-up page and submits it: the tab is then on the POST-only code step."""
    req = urllib.request.Request(f"{base}/json/new?http://{host}:{web}/signup.html", method="PUT")
    t = json.load(urllib.request.urlopen(req))
    time.sleep(1.2)
    ev(t["id"], f"document.getElementById('email').value={json.dumps(email)}; document.getElementById('send').click()")
    for _ in range(30):
        time.sleep(0.3)
        if ev(t["id"], "location.pathname") == "/send-code" and ev(t["id"], "!!document.getElementById('x7')"):
            break
    ev(t["id"], "window.__oneMark = 'same-tab'")  # gone if the page is ever reloaded or reopened
    return t["id"]


for t in pages():
    urllib.request.urlopen(f"{base}/json/close/{t['id']}")
ver = json.load(urllib.request.urlopen(base + "/json/version"))
policy, tmo = _get_dialog_policy_config()
TID = "handoff-e2e"
hs.install(vars(bv))
print("1. the helper is on a code page that exists only in its tab (a form POST answer)")
tab = post_code_tab("127.0.0.1", "test@example.com")
check("the tab is on the code step", ev(tab, "location.pathname") == "/send-code")
invite = ev(tab, "document.querySelector('input[name=invite]').value")
check("the code step holds its one-time state in the page", bool(invite))
sup = SUPERVISOR_REGISTRY.get_or_start(task_id=TID, cdp_url=ver["webSocketDebuggerUrl"], dialog_policy=policy, dialog_timeout_s=tmo)
time.sleep(1)
sup.focus_page("", accept="location.pathname === '/send-code'")

print("2. enter_code can't get the code, so One asks the person (the One half plays them)")
t0 = time.time()
r = {}
for n in range(3):
    r = json.loads(bv._handle_vault({"action": "enter_code"}, task_id=TID))
    print(f"   enter_code call {n + 1}:", json.dumps({k: r.get(k) for k in ('success', 'answer', 'moved_on', 'source', 'error_type', 'url')}))
    if "answer" in r or r.get("error_type") == "still_waiting":
        break
print(f"   waited {time.time() - t0:.1f}s")
st = site_state()
check("the page was never reopened (no GET of the POST-only page)", st["gets_bounced"] == 0)
check("the code went in and the page moved on", r.get("moved_on") is True)
check("the site took it with the tab's own one-time state", invite in st["used"])
check("still the same tab, now past the code step",
      ev(tab, "location.pathname + location.search") == "/welcome.html?who=test@example.com")
check("the code never came back in the tool's answer", "424242" not in json.dumps(r))
reqs = sorted(Path(os.environ["ONE_HANDOFF_DIR"]).glob("*.answer.json"))
check("the code isn't kept in the answer file", all("424242" not in f.read_text() for f in reqs))

print("3. a code in an inbox One can read: filled with nobody asked")
inbox = Path(os.environ["HERMES_HOME"]) / "stand-in-inbox"
inbox.mkdir(parents=True, exist_ok=True)
os.environ["ONE_INBOX_DIR"] = str(inbox)
tab2 = post_code_tab("localhost", "inbox@example.com")
before = set(Path(os.environ["ONE_HANDOFF_DIR"]).glob("*.request.json"))
(inbox / "m1.json").write_text(json.dumps({"from": "Other site <codes@other.example>", "subject": "Your code is 111111",
                                          "at": time.time()}))
(inbox / "m2.json").write_text(json.dumps({"from": "Localhost <codes@localhost>", "subject": "Your code is 424242",
                                          "at": time.time()}))
sup.focus_page("", accept="location.host.startsWith('localhost') && location.pathname === '/send-code'")
r2 = json.loads(bv._handle_vault({"action": "hand_off", "kind": "code"}, task_id=TID))
print("   hand_off:", json.dumps({k: r2.get(k) for k in ('success', 'answer', 'moved_on', 'source', 'url')}))
check("filled from the inbox, nobody asked", r2.get("moved_on") is True and r2.get("source") == "inbox"
      and set(Path(os.environ["ONE_HANDOFF_DIR"]).glob("*.request.json")) == before)
check("the other site's code was never used", site_state("localhost")["verify_fail"] == 0)
check("same tab, past the code step", ev(tab2, "location.pathname + location.search") == "/welcome.html?who=inbox@example.com")
try:
    SUPERVISOR_REGISTRY.stop(TID)
except Exception:
    pass
print("E2E", "PASS" if fails == 0 else f"FAIL ({fails})")
os._exit(0 if fails == 0 else 1)
