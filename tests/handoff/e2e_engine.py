"""End to end, engine half: browser_vault enter_code on a test page in a real Chrome, with the overlay wired
the way One installs it. SIMULATE=1 plays the person (types the code over CDP, writes Done); otherwise a
running One (same ONE_SUPPORT_DIR) must show the window and the person/test taps Done.
Env: OVERLAY, ONE_HANDOFF_DIR, ONE_HANDOFF_CDP=http://127.0.0.1:<port>, HERMES_HOME (scratch)."""
import importlib.util, json, os, sys, threading, time, urllib.request
from pathlib import Path

spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)

import tools.browser_vault_tool as bv
from tools.browser_supervisor import SUPERVISOR_REGISTRY
from tools.browser_tool_cdp import _get_dialog_policy_config

port = int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
for _t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list")):
    if _t["type"] == "page" and not _t["url"].endswith(("decoy.html", "code.html")):
        urllib.request.urlopen(f"http://127.0.0.1:{port}/json/close/{_t['id']}")
ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))
policy, tmo = _get_dialog_policy_config()
TID = "handoff-e2e"
sup = SUPERVISOR_REGISTRY.get_or_start(task_id=TID, cdp_url=ver["webSocketDebuggerUrl"], dialog_policy=policy, dialog_timeout_s=tmo)
time.sleep(1)

before = json.loads(bv.browser_vault_enter_code(handle="", task_id=TID))
print("BEFORE (stock enter_code):", before.get("error_type") or before)

hs.install(vars(bv))
entry = bv.registry._tools.get("browser_vault")
print("registered handler is One's:", entry.handler is bv._handle_vault, "| hand_off in schema:",
      "hand_off" in bv.BROWSER_VAULT_SCHEMA["parameters"]["properties"]["action"]["enum"])

d = Path(os.environ["ONE_HANDOFF_DIR"])

def person():
    # Plays the human: waits for One's request, types the code into the SAME tab, clicks Verify, taps Done.
    from websockets.sync.client import connect
    while True:
        reqs = sorted(d.glob("*.request.json"))
        if reqs:
            break
        time.sleep(0.3)
    req = json.loads(reqs[-1].read_text())
    print("REQUEST:", req["line"], "| target", req["target_id"], "| url", req["url"])
    t = next(x for x in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list")) if x["id"] == req["target_id"])
    with connect(t["webSocketDebuggerUrl"]) as ws:
        n = 0
        def call(m, p):
            nonlocal n
            n += 1
            ws.send(json.dumps({"id": n, "method": m, "params": p}))
            while json.loads(ws.recv()).get("id") != n:
                pass
        call("Runtime.evaluate", {"expression": "document.getElementById('x7').focus()"})
        for ch in "424242":
            call("Input.dispatchKeyEvent", {"type": "keyDown", "text": ch, "key": ch})
            call("Input.dispatchKeyEvent", {"type": "keyUp", "key": ch})
        call("Runtime.evaluate", {"expression": "document.getElementById('go').click()"})
    time.sleep(0.5)
    (d / f"{req['id']}.answer.json").write_text(json.dumps({"answer": "done", "by": "test"}))

if os.environ.get("SIMULATE") == "1":
    threading.Thread(target=person, daemon=True).start()

t0 = time.time()
tries = []
for n in range(3):
    r = json.loads(bv._handle_vault({"action": "enter_code"}, task_id=TID))
    tries.append(r)
    print(f"enter_code call {n+1}:", json.dumps(r)[:400])
    if "answer" in r or r.get("error_type") == "still_waiting":
        break
print(f"waited {time.time()-t0:.1f}s")
last = tries[-1]
ok = last.get("moved_on") is True
# carry on by itself on the same tab: read the page it landed on
sup.focus_page("", accept="location.pathname === '/welcome.html'")
w = bv._eval_js(TID, "document.getElementById('w') ? document.getElementById('w').textContent : document.title")
print("CARRIED ON, page says:", w.get("result"))
SUPERVISOR_REGISTRY.stop(TID) if hasattr(SUPERVISOR_REGISTRY, "stop") else None
print("E2E", "PASS" if ok and "Welcome" in str(w.get("result")) else "FAIL")
os._exit(0 if ok else 1)
