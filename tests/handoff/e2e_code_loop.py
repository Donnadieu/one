"""End to end, engine half: a code hand-off can never loop and always has a way out (Nov 11 2026, DocuSign's SMS step).

What happened on One 0.9.113: a helper on DocuSign's "Secure Your Account" SMS step called hand_off kind=code. One
asked Omar for a code over and over ("That code didn't work. Type the newest code ... sent you"), the code never came,
"I'm not at the Mac" did nothing, his message "I'm not receiving any code" sat behind the wait, and even stopping the
helper didn't end the wait: it kept writing new requests for minutes.

This plays the person by writing One's answer files itself (the One half has its own checks), on a local page built
like DocuSign's step (tests/handoff/pages/sms-enterphone.html: a phone number first, the code box only after "Send
Code", the same address throughout). Real Chrome (throwaway, own port), real overlay code, no account, no texts.
Env: OVERLAY, ONE_HANDOFF_DIR (its own folder), ONE_HANDOFF_CDP=http://127.0.0.1:<port>, ONE_TEST_WEB (site port).
"""
import importlib.util, json, os, sys, threading, time, types, urllib.request
from pathlib import Path

sys.stdout.reconfigure(line_buffering=True)
os.environ["ONE_INBOX_CODES"] = "0"  # no inbox: every code comes from "the person"
CURRENT = {"url": ""}
# The helper's own page, as browser_vault would report it (no browser session is started for this test).
sys.modules["tools.browser_vault_tool"] = types.SimpleNamespace(
    _eval_js=lambda tid, js: {"success": True, "result": json.dumps(CURRENT["url"])})
spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)
try:
    from tools.interrupt import set_interrupt  # the engine's own Stop (session/cancel) for a tool's thread
except Exception:  # outside the engine's runtime (a plain python with websockets): its real file, minus its config import
    sys.modules.pop("tools.interrupt", None)
    sys.modules.setdefault("utils", types.SimpleNamespace(env_var_enabled=lambda name: False))
    try:
        from tools.interrupt import set_interrupt
    except Exception:
        set_interrupt = None
print("engine Stop available:", set_interrupt is not None)

port = int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
web = int(os.environ.get("ONE_TEST_WEB", "8791"))
base = f"http://127.0.0.1:{port}"
site = f"http://127.0.0.1:{web}"
D = Path(os.environ["ONE_HANDOFF_DIR"])
D.mkdir(parents=True, exist_ok=True)
TID = "local-code-loop-helper"
ENTER = site + "/v2/usertoaccountinvite/smsverification-enterphone"
fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


def pages():
    return [t for t in json.load(urllib.request.urlopen(base + "/json/list")) if t["type"] == "page"]


def ws_of(target):
    return next((t["webSocketDebuggerUrl"] for t in pages() if t["id"] == target), "")


def ev(target, expr):
    w = ws_of(target)
    return hs._page_eval(w, expr) if w else None


def state():
    return json.load(urllib.request.urlopen(site + "/state.json"))


def only_tab(url):
    """Closes every tab, then opens `url`: the helper's one tab."""
    for t in pages():
        urllib.request.urlopen(f"{base}/json/close/{t['id']}")
    req = urllib.request.Request(f"{base}/json/new?{url}", method="PUT")
    t = json.load(urllib.request.urlopen(req))
    for _ in range(30):
        time.sleep(0.2)
        if ev(t["id"], "document.readyState") == "complete":
            break
    CURRENT["url"] = url
    return t["id"]


def send_code(target):
    """What the helper must do first: fill the phone number, press Send Code, see the code box appear."""
    ev(target, "document.getElementById('b6f6b88ccf').value = '5555550100'; document.getElementById('send').click()")
    for _ in range(30):
        time.sleep(0.2)
        if ev(target, "!!document.getElementById('c1')"):
            return True
    return False


def code_tab():
    t = only_tab(ENTER)
    ok = send_code(t)
    return t, ok


def requests(target):
    out = []
    for f in D.glob("*.request.json"):
        r = json.loads(f.read_text())
        if r.get("target_id") == target:
            out.append(r)
    return sorted(out, key=lambda r: r["created"])


def answered(rid):
    return (D / f"{rid}.answer.json").exists()


def open_request(target, n, secs=20.0):
    """Waits for the n-th request on this tab (1-based) to be open (no answer yet)."""
    end = time.time() + secs
    while time.time() < end:
        rs = requests(target)
        if len(rs) >= n and not answered(rs[n - 1]["id"]):
            return rs[n - 1]
        time.sleep(0.2)
    return None


def answer(rid, data):
    data = {"by": "person", "at": time.time(), **data}
    tmp = D / f"{rid}.answer.tmp"
    tmp.write_text(json.dumps(data))
    os.replace(tmp, D / f"{rid}.answer.json")


def start(kind="code", wait=25.0):
    box = {}

    def run():
        box["t0"] = time.time()
        box["r"] = hs.hand_off(kind, TID, wait=wait)
        box["t1"] = time.time()
    th = threading.Thread(target=run, daemon=True)
    th.start()
    box["thread"] = th
    return box


def finish(box, secs):
    box["thread"].join(secs)
    return box.get("r") or {}


def brief(r):
    return json.dumps({k: r.get(k) for k in ("success", "answer", "error_type", "moved_on", "message") if k in r})


print("1. DocuSign's SMS step before Send Code: the page asks for a phone number, not a code")
before = state()  # the site's counters so far (another check may share this server)
tab = only_tab(ENTER)
t0 = time.time()
r = hs.hand_off("code", TID, wait=12)
took = time.time() - t0
print("   hand_off:", brief(r), f"({took:.1f}s)")
check("hand_off kind=code refuses: no code box on the page", r.get("success") is False and r.get("error_type") == "not_a_code_step")
check("it refuses at once (no wait)", took < 8)
check("nobody was asked (no request written)", requests(tab) == [])
check("it tells the helper to send the code first", "send code" in str(r.get("next", "")).lower())
check("the site never sent a text", state()["sms_sent"] == before["sms_sent"])

print("2. after Send Code, the person types a wrong code twice: two tries, then code_failed, never a third ask")
fails_before = state()["sms_verify_fail"]
tab, ok = code_tab()
check("the helper pressed Send Code and the code box appeared (same address)", ok and ev(tab, "location.pathname").endswith("enterphone"))
box = start(wait=60)
q1 = open_request(tab, 1)
check("One is asked once, for this helper's session", bool(q1) and q1.get("session") == TID)
if q1:
    answer(q1["id"], {"answer": "code", "code": "111111", "by": "phone"})
q2 = open_request(tab, 2, 30)
check("after the first wrong code, one more ask: \"That code didn't work\"", bool(q2) and "didn't work" in q2.get("line", ""))
check("a code that came from the phone keeps the retry on the phone", bool(q2) and q2.get("phone") is True)
if q2:
    answer(q2["id"], {"answer": "code", "code": "222222"})
r = finish(box, 35)
print("   hand_off:", brief(r))
check("after the second wrong code it stops: answer code_failed", r.get("answer") == "code_failed" and r.get("success") is False)
time.sleep(3)
check("never a third ask", len(requests(tab)) == 2)
check("the site saw exactly two tries", state()["sms_verify_fail"] - fails_before == 2)

print("3. one wrong code, then the right one: it still goes through")
tab, ok = code_tab()
box = start(wait=60)
q1 = open_request(tab, 1)
if q1:
    answer(q1["id"], {"answer": "code", "code": "111111"})
q2 = open_request(tab, 2, 30)
if q2:
    answer(q2["id"], {"answer": "code", "code": "424242"})
r = finish(box, 35)
print("   hand_off:", brief(r))
check("the second try worked and the page moved on", r.get("moved_on") is True and ev(tab, "location.search") == "?who=sms")

print("4. the ways out while a code ask is open: each ends the wait at once, with an answer the helper sees")
outs = [({"answer": "cancelled"}, "cancelled", "Cancel"),
        ({"answer": "no_code"}, "no_code", "I didn't get a code"),
        ({"answer": "away", "by": "one"}, "not_at_mac", "I'm not at the Mac (One's card)"),
        ({"answer": "not_at_mac"}, "not_at_mac", "not_at_mac (as written by hand on Nov 11)"),
        ({"answer": "message", "text": "I'm not receiving any code"}, "message", "a message to the helper")]
for data, want, what in outs:
    tab, ok = code_tab()
    box = start(wait=30)
    q = open_request(tab, 1)
    t_ans = time.time()
    if q:
        answer(q["id"], data)
    r = finish(box, 12)
    took = (box.get("t1") or time.time() + 99) - t_ans
    print(f"   {what}:", brief(r), f"({took:.1f}s after the answer)")
    check(f"{what} ends the wait with answer {want}", r.get("answer") == want and took < 6)
    if want == "message":
        check("the helper gets their words", r.get("message") == "I'm not receiving any code")
    time.sleep(1.5)
    check(f"{what}: no new ask afterwards", len(requests(tab)) == 1)

print("5. the helper is stopped (the engine's Stop for its tool) mid-wait: the wait ends and the card goes")
tab, ok = code_tab()
box = start(wait=40)
q = open_request(tab, 1)
time.sleep(0.5)
t_stop = time.time()
if set_interrupt is not None:
    set_interrupt(True, box["thread"].ident)
r = finish(box, 10)
if set_interrupt is not None:
    set_interrupt(False, box["thread"].ident)
took = (box.get("t1") or time.time() + 99) - t_stop
print("   stopped:", brief(r), f"({took:.1f}s)")
check("a stopped helper's hand_off ends at once (answer stopped)", r.get("answer") == "stopped" and took < 6)
check("its ask is closed, so One's card goes away", bool(q) and answered(q["id"]))
time.sleep(1.5)
check("no new ask after the stop", len(requests(tab)) == 1)

print("6. the helper's tab is closed mid-wait: the wait ends")
tab, ok = code_tab()
box = start(wait=40)
q = open_request(tab, 1)
t_close = time.time()
urllib.request.urlopen(f"{base}/json/close/{tab}")
r = finish(box, 15)
took = (box.get("t1") or time.time() + 99) - t_close
print("   tab closed:", brief(r), f"({took:.1f}s)")
check("a closed tab ends the wait (answer tab_closed)", r.get("answer") == "tab_closed" and took < 10)
check("its ask is closed, so One's card goes away", bool(q) and answered(q["id"]))

print("7. a step done in the page (approve): a message to the helper ends that wait too")
tab = only_tab(site + "/approve-start")
ev(tab, "document.getElementById('start').click()")
time.sleep(1.5)
CURRENT["url"] = site + "/approve"
box = start("approve", wait=30)
q = open_request(tab, 1)
if q:
    answer(q["id"], {"answer": "message", "text": "Skip this one"})
r = finish(box, 12)
print("   approve + message:", brief(r))
check("the wait ends with answer message and their words", r.get("answer") == "message" and r.get("message") == "Skip this one")

print("CODE LOOP", "PASS" if fails == 0 else f"FAIL ({fails})")
os._exit(0 if fails == 0 else 1)
