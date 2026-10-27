"""enter_code really fills a code box it used to miss (unnamed tel box, split boxes), on the right tab.
A stand-in code source plays the authenticator (TOTP) so no person is needed. Env as e2e_engine.py."""
import importlib.util, json, os, sys, time, urllib.request

spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)
import tools.browser_vault_tool as bv
from tools.browser_supervisor import SUPERVISOR_REGISTRY
from tools.browser_tool_cdp import _get_dialog_policy_config
import agent.vault_backends as vb

port = int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
base = f"http://127.0.0.1:{port}"
for t in json.load(urllib.request.urlopen(base + "/json/list")):
    if t["type"] == "page":
        urllib.request.urlopen(f"{base}/json/close/{t['id']}")
def tab(page):
    req = urllib.request.Request(f"{base}/json/new?http://127.0.0.1:8791/{page}", method="PUT")
    return json.load(urllib.request.urlopen(req))
tab("decoy.html"); tab("code.html")
time.sleep(1.5)

class FakeTotp:  # what a password manager with an authenticator seed returns
    name = "fake"
    def resolve_otp(self, handle):
        return "424242"
vb.backend_for_handle = lambda h: FakeTotp() if h == "fake:1" else None

ver = json.load(urllib.request.urlopen(base + "/json/version"))
policy, tmo = _get_dialog_policy_config()
TID = "fill-check"
sup = SUPERVISOR_REGISTRY.get_or_start(task_id=TID, cdp_url=ver["webSocketDebuggerUrl"], dialog_policy=policy, dialog_timeout_s=tmo)
time.sleep(1)
stock = json.loads(bv.browser_vault_enter_code(handle="fake:1", task_id=TID))
print("stock enter_code:", stock.get("error_type") or stock)
hs.install(vars(bv))
r = json.loads(bv._handle_vault({"action": "enter_code", "handle": "fake:1"}, task_id=TID))
print("One enter_code:", r)
v = bv._eval_js(TID, "document.getElementById('x7').value.length + ' digits on ' + location.pathname")
print("page now:", v.get("result"))
ok = r.get("success") and r.get("filled_fields") == 1 and "6 digits on /code.html" in str(v.get("result"))
print("FILL", "PASS" if ok else "FAIL")
os._exit(0 if ok else 1)
