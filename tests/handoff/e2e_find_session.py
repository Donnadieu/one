"""Proves: hand_off(kind=sign_in) on a logged-out browser (9348) finds a real session cookie on a sibling
hidden browser (9347) and reports found_elsewhere WITHOUT ever writing a handoff request / asking the
person. Mirrors the real NotArc incident (9224 logged out, 9223 already signed in).
Env: OVERLAY, ONE_HANDOFF_DIR, HERMES_HOME (scratch)."""
import importlib.util, json, os, sys, time, urllib.request
from pathlib import Path

spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)

import tools.browser_vault_tool as bv  # noqa: E402  (overlay needs this imported first)
from tools.browser_supervisor import SUPERVISOR_REGISTRY
from tools.browser_tool_cdp import _get_dialog_policy_config
from websockets.sync.client import connect

SIGNED_PORT = 9347
CURRENT_PORT = 9348
TID = "signin-elsewhere"

print("step: installing overlay", flush=True)
hs.install(vars(bv))
print("step: overlay installed", flush=True)

# Set a realistic auth cookie on the "signed in" sibling browser (9347), targeting a made-up site so we
# exercise the generic (non-named-site) heuristic path, same as any site not in KNOWN_AUTH_COOKIES.
tabs = json.load(urllib.request.urlopen(f"http://127.0.0.1:{SIGNED_PORT}/json/list"))
tab = next(t for t in tabs if t["type"] == "page" and t["url"].endswith("welcome.html"))
with connect(tab["webSocketDebuggerUrl"], open_timeout=3, close_timeout=1) as ws:
    ws.send(json.dumps({"id": 1, "method": "Network.setCookie",
                        "params": {"url": "http://127.0.0.1:8794/", "name": "sid",
                                   "value": "s3cr3t-session-token-abcdefghijklmnop", "httpOnly": True}}))
    while json.loads(ws.recv()).get("id") != 1:
        pass

# Point this task's own browsing session at the LOGGED-OUT browser (9348), on the login wall.
print("step: cookie set, opening supervisor", flush=True)
ver = json.load(urllib.request.urlopen(f"http://127.0.0.1:{CURRENT_PORT}/json/version"))
policy, tmo = _get_dialog_policy_config()
print("step: got dialog policy", flush=True)
sup = SUPERVISOR_REGISTRY.get_or_start(task_id=TID, cdp_url=ver["webSocketDebuggerUrl"], dialog_policy=policy, dialog_timeout_s=tmo)
print("step: supervisor started", flush=True)
time.sleep(1)

d = Path(os.environ["ONE_HANDOFF_DIR"])
before = sorted(d.glob("*.request.json"))

os.environ["ONE_HANDOFF_SIBLING_PORTS"] = str(SIGNED_PORT)
out = json.loads(bv._handle_vault({"action": "hand_off", "kind": "sign_in"}, task_id=TID))
print("hand_off ->", json.dumps(out)[:400])

after = sorted(d.glob("*.request.json"))
no_request_written = after == before
ok = (out.get("answer") == "found_elsewhere" and out.get("signed_in_port") == SIGNED_PORT and no_request_written)
print("no handoff request was written (nobody was asked to sign in):", no_request_written)
print("E2E FIND_SESSION", "PASS" if ok else "FAIL")
os._exit(0 if ok else 1)
