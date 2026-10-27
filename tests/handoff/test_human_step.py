"""Engine-side checks for one_human_step (run with epy.sh; HERMES_HOME + ONE_HANDOFF_DIR set to scratch).
Needs a Chrome on ONE_HANDOFF_CDP with the test pages open (decoy, code, boxes, captcha, passkey)."""
import json, os, sys, threading, time, importlib.util
from pathlib import Path

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("tools.one_human_step", os.environ["OVERLAY"])
hs = importlib.util.module_from_spec(spec)
sys.modules["tools.one_human_step"] = hs
spec.loader.exec_module(hs)

fails = []
def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        fails.append(what)

from agent.vault_login_classifier import LoginControl
C = lambda **k: LoginControl(autocomplete=k.get("ac", ""), form_index=k.get("form", 0), index=k["i"], label=k.get("label", ""),
                             name=k.get("name", ""), type=k.get("type", "text"), max_length=k.get("ml"))
amazon = [C(i=0, name="otpCode ap_otp_code", type="tel", ml=6, label="Enter code"), C(i=1, name="trustThisDevice", type="checkbox")]
check(len(hs.classify_otp_controls(amazon)) == 1, "Amazon's otpCode tel box (no autocomplete) is a code box")
check(len(hs.classify_otp_controls([C(i=0, name="field7", label="Enter code", type="tel", ml=6)])) == 1, "an unnamed tel box labelled 'Enter code'")
check(hs.classify_otp_controls([C(i=0, name="countryCode", type="text")]) == [], "a country code box is not a code box")
check(hs.classify_otp_controls([C(i=0, name="promo_code", type="text")]) == [], "a promo code box is not a code box")
boxes = [C(i=n, type="text", ml=1) for n in range(6)]
got = hs.classify_otp_controls(boxes)
check(len(got) == 6, "six unnamed one-character boxes are a split code input")
from agent.vault_login_classifier import build_otp_fills
fills = build_otp_fills(got, "123456")
check(len(fills) == 6 and [f["value"] for f in fills] == list("123456"), "a split input gets one digit per box")
check(len(hs.classify_otp_controls([C(i=0, ac="one-time-code", type="text")])) == 1, "autocomplete=one-time-code always counts")

host, port = "127.0.0.1", int(os.environ["ONE_HANDOFF_CDP"].rsplit(":", 1)[1])
kinds = {}
for t in hs._pages(host, port):
    kinds[t["url"].rsplit("/", 1)[-1]] = hs.page_step(t["webSocketDebuggerUrl"]).get("kind")
print("detected:", kinds)
check(kinds.get("code.html") == "code", "code page: code")
check(kinds.get("boxes.html") == "code", "split boxes page: code")
check(kinds.get("captcha.html") == "check", "robot check page: check")
check(kinds.get("passkey.html") in ("passkey", "security_key"), "passkey page: passkey")
check(kinds.get("decoy.html") == "none", "phone/country-code page: nothing to hand off")
tab = hs.pick_step_tab(host, port, kinds=("code",))
check(bool(tab) and tab["url"].endswith(("code.html", "boxes.html")), f"tab picker skips the decoy (picked {tab and tab['url']})")
check(hs.line_for("amazon.com", "code") == "I need you for one step: amazon.com is asking for a code. A Chrome window is open on it. Enter it there, then tap Done.", "the chat line, word for word")
check("Amazon app" in hs.phone_fallback("amazon.com", "code"), "phone fallback names the Amazon app")

print("unit:", "ok" if not fails else f"{len(fails)} failed")
sys.exit(1 if fails else 0)
