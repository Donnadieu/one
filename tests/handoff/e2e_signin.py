"""End to end, engine half, for a PLAIN SIGN-IN WALL (no code, no captcha): proves (1) the page classifier
correctly does NOT think it's a code/check step (that's the whole point: nothing can auto-detect a login
form), and (2) the model's own browser_vault action=hand_off call with kind=sign_in still writes the
request, shows it, waits, and reports moved_on once the person signs in. This is the exact gap behind the
"NotArc correction" / Sienna Facebook incidents: a plain sign-in page was never automatically caught, and
nothing told the model to call hand_off itself, so no window was ever requested.
Env: OVERLAY, ONE_HANDOFF_DIR, ONE_HANDOFF_CDP=http://127.0.0.1:<port>, HERMES_HOME (scratch).
"""
import importlib.util, json, os, sys, threading, time, urllib.request
from pathlib import Path

spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)

import tools.browser_vault_tool as bv  # noqa: E402  (overlay needs this imported first)

port = int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
for _t in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list")):
    if _t["type"] == "page" and not _t["url"].endswith("login.html"):
        urllib.request.urlopen(f"http://127.0.0.1:{port}/json/close/{_t['id']}")
ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version"))
TID = "handoff-e2e-signin"

tabs = hs._pages("127.0.0.1", port)
login_tab = next(t for t in tabs if t["url"].endswith("login.html"))
step = hs.page_step(login_tab["webSocketDebuggerUrl"])
print("PAGE CLASSIFIED AS:", step)
not_auto_detected = step.get("kind") == "none"

d = Path(os.environ["ONE_HANDOFF_DIR"])


def person():
    # Plays the human: waits for One's request, clicks Sign in on the SAME tab, taps Done.
    from websockets.sync.client import connect

    while True:
        reqs = sorted(d.glob("*.request.json"))
        if reqs:
            break
        time.sleep(0.3)
    req = json.loads(reqs[-1].read_text())
    print("REQUEST:", req["line"], "| kind", req["kind"], "| target", req["target_id"], "| url", req["url"])
    assert req["kind"] == "sign_in", f"expected kind=sign_in, got {req['kind']}"
    t = next(x for x in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list")) if x["id"] == req["target_id"])
    with connect(t["webSocketDebuggerUrl"]) as ws:
        ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "document.getElementById('go').click()"}}))
        while json.loads(ws.recv()).get("id") != 1:
            pass
    time.sleep(0.5)
    (d / f"{req['id']}.answer.json").write_text(json.dumps({"answer": "done", "by": "test"}))


threading.Thread(target=person, daemon=True).start()

t0 = time.time()
out = hs.hand_off(kind="sign_in", task_id=TID, why="plain sign-in wall, no code or captcha")
print(f"hand_off waited {time.time()-t0:.1f}s ->", json.dumps(out)[:400])
ok = not_auto_detected and out.get("moved_on") is True and "welcome.html" in out.get("url", "")
print("E2E SIGNIN", "PASS" if ok else "FAIL")
os._exit(0 if ok else 1)
