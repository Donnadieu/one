"""One: hand a browser step to the person when only a human can do it.

Installed into the engine by One (``Installer.applyOverlay``): this file is copied to
``tools/one_human_step.py`` and a two-line hook at the end of ``tools/browser_vault_tool.py``
calls :func:`install`, which

* makes ``browser_vault enter_code`` find common code boxes (Amazon's "Enter code", ``type=tel``,
  ``autocomplete=one-time-code``, split 6-box inputs) and run on the tab that really asks for a code
  (it used to take the first tab with any input named "...code...", e.g. a country-code box);
* hands the step to the person after at most ``MAX_AUTO_TRIES`` failed automatic tries, or at once when
  nothing automatic can work (a code nobody can type for us, a passkey or security key, "approve on your
  device", a CAPTCHA or Cloudflare check);
* adds ``browser_vault action=hand_off``: One shows the SAME tab of the shared hidden browser in a
  window in front, posts one line in its chat with Done / I'm not at the Mac, and this call waits for the
  answer, then checks the page moved on.

Talks to One through files in ``<One support>/handoff/`` (``<id>.request.json`` written here,
``<id>.answer.json`` written by One or here). Codes never pass through the conversation.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlparse

MAX_AUTO_TRIES = 2
WAIT_SECONDS = int(os.environ.get("ONE_HANDOFF_WAIT", "480"))
HUMAN_KINDS = ("code", "security_key", "passkey", "approve", "check")

_lock = threading.Lock()
_failures: dict[str, int] = {}


# ---------------------------------------------------------------------------
# Where One listens
# ---------------------------------------------------------------------------

def handoff_dir() -> Path:
    override = os.environ.get("ONE_HANDOFF_DIR")
    if override:
        d = Path(override)
    else:
        from hermes_constants import get_hermes_home
        d = Path(get_hermes_home()).parent / "handoff"
    d.mkdir(parents=True, exist_ok=True)
    return d


# ---------------------------------------------------------------------------
# What the page asks for (runs in the page; reads only, returns no field values)
# ---------------------------------------------------------------------------

STEP_JS = r"""(() => {
  const vis = (e) => { const s = getComputedStyle(e); return s.display !== "none" && s.visibility !== "hidden" && e.getClientRects().length > 0; };
  const label = (e) => [e.name, e.id, e.getAttribute("aria-label"), e.getAttribute("placeholder"), e.getAttribute("title"),
    ...(e.labels ? Array.from(e.labels, (l) => l.textContent) : [])].filter(Boolean).join(" ")
    .replace(/([a-z])([A-Z])/g, "$1 $2").replace(/[^A-Za-z0-9]+/g, " ").toLowerCase();
  const text = ((document.body && document.body.innerText) || "").slice(0, 6000).toLowerCase();
  const asksCode = /\b(code|verification|verify|one[- ]time|2-step|two[- ]step|two[- ]factor|authenticator|otp|passcode)\b/.test(text);
  const strong = /\b(otp|totp|2fa|mfa|one ?time|onetime|passcode|verification|authenticator|security code|sms code|auth code)\b/;
  const notOtp = /\b(promo|coupon|discount|gift|voucher|zip|postal|country|area|referral|invite|invitation|tracking|search|captcha)\b/;
  const inputs = Array.from(document.querySelectorAll("input")).filter((e) => !e.disabled && !e.readOnly && vis(e)
    && ["text", "tel", "number", "password", ""].includes(e.type));
  let best = 0;
  for (const e of inputs) {
    const ac = (e.autocomplete || "").toLowerCase(), l = label(e), ml = e.maxLength;
    let s = 0;
    if (ac.split(/\s+/).includes("one-time-code")) s = 100;
    else if (strong.test(l)) s = 80;
    else if (/\bcode\b/.test(l) && !notOtp.test(l)) s = (e.type === "tel" || e.type === "number" || e.inputMode === "numeric") ? 70 : 60;
    else if (asksCode && (e.type === "tel" || e.type === "number" || e.inputMode === "numeric") && ml >= 4 && ml <= 8) s = 55;
    if (e.type === "password" && s < 80) s = 0;
    best = Math.max(best, s);
  }
  const boxes = inputs.filter((e) => e.maxLength === 1);
  if (boxes.length >= 4 && boxes.length <= 8 && asksCode) best = Math.max(best, 90);
  const frames = Array.from(document.querySelectorAll("iframe")).map((f) => f.src || "").join(" ").toLowerCase();
  const url = location.href.toLowerCase();
  let kind = "none", why = "";
  if (/recaptcha|hcaptcha|challenges\.cloudflare\.com|turnstile|arkoselabs|funcaptcha|captcha/.test(frames)
      || /\/captcha|validatecaptcha|\/cdn-cgi\/challenge/.test(url)
      || /verify you are (a )?human|\bi am human\b|i'?m not a robot|are you a robot|press (and|&) hold|just a moment\.\.\.|checking (if the site connection is secure|your browser)|enter the characters you see|type the characters|solve (this|the) puzzle/.test(text)) {
    kind = "check"; why = "human check";
  } else if (best >= 55) {
    kind = "code"; why = "code box";
  } else if (/\bpasskey\b/.test(text) && /(use|sign in with|continue with|verify with) (a |your )?passkey|touch id|face id|windows hello/.test(text)) {
    kind = "passkey"; why = "passkey";
  } else if (/security key|touch your (security )?key|insert your (security )?key|usb key|webauthn/.test(text)) {
    kind = "security_key"; why = "security key";
  } else if (/approve (the |this |your )?(sign[- ]?in|request|login|notification)|check your (phone|device)|tap yes|we sent a (notification|push|prompt|request)|open the .{0,30}app .{0,30}(approve|continue|verify)|waiting for (your )?approval|confirm (it'?s you|that it'?s you) on|approve on your/.test(text)) {
    kind = "approve"; why = "approve on device";
  }
  return JSON.stringify({ kind, score: kind === "code" ? best : (kind === "none" ? 0 : 50), why, url: location.href, title: document.title });
})()"""


# ---------------------------------------------------------------------------
# Better code-box classifier (replaces agent.vault_login_classifier.classify_otp_controls)
# ---------------------------------------------------------------------------

_STRONG = re.compile(r"\b(?:otp|totp|2fa|mfa|one ?time|onetime|passcode|verification|authenticator|security code|sms code|auth code)\b")
_CODE = re.compile(r"\bcode\b")
_NOT_OTP = re.compile(r"\b(?:promo|coupon|discount|gift|voucher|zip|postal|country|area|referral|invite|invitation|tracking|search|captcha)\b")


def _words(*parts: str) -> str:
    s = " ".join(p for p in parts if p)
    s = re.sub(r"([a-z])([A-Z])", r"\1 \2", s)
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


def classify_otp_controls(controls: list) -> list:
    """The inputs that take a one-time code. ``autocomplete=one-time-code`` is authoritative; then
    name/id/label words (camelCase split, so ``otpCode`` counts); a plain "code" box that is not a promo,
    zip or country code; a run of 4 to 8 one-character boxes in one form (split code inputs)."""
    from agent.vault_login_classifier import ClassifiedLoginControl

    out: list = []
    seen: set[int] = set()
    for c in controls:
        if "one-time-code" in c.autocomplete.lower().split():
            out.append(ClassifiedLoginControl(c, 100, "one-time-code"))
            seen.add(c.index)
            continue
        if c.type not in ("text", "tel", "number", "password", ""):
            continue
        w = _words(c.name, c.label)
        if _STRONG.search(w):
            score = 80
        elif _CODE.search(w) and not _NOT_OTP.search(w):
            score = 70 if c.type in ("tel", "number") else 60
        else:
            continue
        if c.type == "password" and score < 80:
            continue
        out.append(ClassifiedLoginControl(c, score, "one-time-code"))
        seen.add(c.index)
    # Split boxes: 4..8 adjacent one-character inputs in the same form, even with no useful names.
    boxes = sorted((c for c in controls if c.max_length == 1 and c.type in ("text", "tel", "number", "password", "")),
                   key=lambda c: c.index)
    run: list = []
    for c in boxes:
        if run and (c.index - run[-1].index != 1 or c.form_index != run[-1].form_index):
            if 4 <= len(run) <= 8:
                break
            run = []
        run.append(c)
    if 4 <= len(run) <= 8:
        out = [o for o in out if o.control.max_length != 1]
        out += [ClassifiedLoginControl(c, 90, "one-time-code") for c in run]
    return out


# ---------------------------------------------------------------------------
# Talking to the local browser directly (its DevTools port), never through the conversation
# ---------------------------------------------------------------------------

def _local_port(task_id: str) -> Optional[tuple[str, int]]:
    urls: list[str] = []
    try:
        from tools.browser_supervisor import SUPERVISOR_REGISTRY
        sup = SUPERVISOR_REGISTRY.get(task_id)
        if sup is not None and getattr(sup, "cdp_url", ""):
            urls.append(sup.cdp_url)
    except Exception:
        pass
    try:
        from tools.browser_tool_cdp import _get_cdp_override
        urls.append(_get_cdp_override() or "")
    except Exception:
        pass
    urls.append(os.environ.get("ONE_HANDOFF_CDP", ""))
    for u in urls:
        p = urlparse(u or "")
        if p.hostname in ("127.0.0.1", "localhost", "::1") and p.port:
            return ("127.0.0.1", p.port)
    return None


def _http_json(host: str, port: int, path: str) -> Any:
    with urllib.request.urlopen(f"http://{host}:{port}{path}", timeout=3) as r:
        return json.loads(r.read().decode())


def _pages(host: str, port: int) -> list[dict]:
    try:
        return [t for t in _http_json(host, port, "/json/list")
                if t.get("type") == "page" and str(t.get("url", "")).startswith(("http://", "https://"))]
    except Exception:
        return []


def _page_eval(ws_url: str, expression: str, timeout: float = 5.0) -> Any:
    from websockets.sync.client import connect
    with connect(ws_url, open_timeout=timeout, close_timeout=1, max_size=8 << 20) as ws:
        ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                            "params": {"expression": expression, "returnByValue": True}}))
        deadline = time.time() + timeout
        while time.time() < deadline:
            msg = json.loads(ws.recv(timeout=max(0.1, deadline - time.time())))
            if msg.get("id") == 1:
                return ((msg.get("result") or {}).get("result") or {}).get("value")
    return None


def page_step(ws_url: str) -> dict:
    try:
        raw = _page_eval(ws_url, STEP_JS)
        return json.loads(raw) if isinstance(raw, str) else {"kind": "none", "score": 0}
    except Exception as exc:
        return {"kind": "unknown", "score": 0, "error": str(exc)[:120]}


def pick_step_tab(host: str, port: int, kinds: tuple = HUMAN_KINDS, prefer_url: str = "") -> Optional[dict]:
    """The open tab most clearly asking for a human step (highest score; the agent's own page wins ties)."""
    best: Optional[dict] = None
    for t in _pages(host, port):
        ws = t.get("webSocketDebuggerUrl")
        if not ws:
            continue
        step = page_step(ws)
        if step.get("kind") not in kinds:
            continue
        rank = (step.get("score", 0), 1 if prefer_url and t.get("url") == prefer_url else 0)
        if best is None or rank > best["_rank"]:
            best = {"target_id": t.get("id"), "ws": ws, "url": step.get("url") or t.get("url"),
                    "title": step.get("title") or t.get("title", ""), "kind": step.get("kind"),
                    "score": step.get("score", 0), "_rank": rank}
    if best:
        best.pop("_rank", None)
    return best


def _site(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


# ---------------------------------------------------------------------------
# Words for the person
# ---------------------------------------------------------------------------

ASKING = {"code": "a code", "security_key": "your security key", "passkey": "your passkey",
          "approve": "a tap to approve on your phone", "check": "a quick check"}

_APPS = {"amazon.": "the Amazon app", "google.": "the Google app or Gmail", "apple.com": "Settings on your iPhone",
         "microsoft.": "the Microsoft Authenticator app", "live.com": "the Microsoft Authenticator app",
         "github.com": "GitHub Mobile", "paypal.": "the PayPal app", "facebook.": "the Facebook app",
         "instagram.": "the Instagram app", "x.com": "the X app", "linkedin.": "the LinkedIn app",
         "chase.": "the Chase app", "americanexpress.": "the Amex app", "bankofamerica.": "the Bank of America app"}


def line_for(site: str, kind: str) -> str:
    return (f"I need you for one step: {site} is asking for {ASKING.get(kind, 'a quick check')}. "
            "Tap Show the window to do it there, then tap Done.")


def phone_fallback(site: str, kind: str) -> str:
    app = next((a for k, a in _APPS.items() if k in site), "")
    where = f"{app} on your phone" if app else f"{site} in your phone's browser"
    step = {"approve": f"If {site} sent a sign-in request to your phone, approve it there now; I'll notice the page move on.",
            "code": f"You can do this part yourself in {where}.",
            }.get(kind, f"You can do this part yourself in {where}.")
    return (f"{step} Or, when you're back at the Mac, say so: the {site} page stays open on this same step and "
            "I'll show it to you again. Never send me the code here; it can't be used from the chat.")


# ---------------------------------------------------------------------------
# The hand-off itself
# ---------------------------------------------------------------------------

def _write_json(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    os.replace(tmp, path)


def _read_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def _open_request(target_id: str) -> Optional[dict]:
    d = handoff_dir()
    for f in d.glob("*.request.json"):
        r = _read_json(f)
        if r and r.get("target_id") == target_id and not (d / f"{r['id']}.answer.json").exists() \
                and time.time() - float(r.get("created", 0)) < 3600:
            return r
    return None


def hand_off(kind: str = "", task_id: Optional[str] = None, why: str = "", wait: Optional[float] = None) -> dict:
    """Show the person the page (same browser, same tab) and wait for Done / I'm not at the Mac."""
    tid = task_id or "default"
    port = _local_port(tid)
    current = ""
    try:
        from tools.browser_vault_tool import _eval_js
        r = _eval_js(tid, "window.location.href")
        current = str(r.get("result") or "").strip('"') if r.get("success") else ""
    except Exception:
        pass
    if port is None:
        site = _site(current) or "the site"
        k = kind or "check"
        return {"success": False, "error_type": "no_local_browser",
                "error": "This browser isn't on this Mac, so it can't be shown to the person.",
                "phone_fallback": phone_fallback(site, k),
                "next": "Tell the person in one short line what the site needs and give them the phone_fallback. Never ask for a code in chat."}
    host, p = port
    tab = pick_step_tab(host, p, prefer_url=current)
    if tab is None:
        # No tab looks like a human step: show the agent's own page (the person may see something the probe missed).
        pages = _pages(host, p)
        t = next((x for x in pages if x.get("url") == current), pages[0] if pages else None)
        if t is None:
            return {"success": False, "error_type": "no_page", "error": "No open page to show."}
        tab = {"target_id": t.get("id"), "ws": t.get("webSocketDebuggerUrl"), "url": t.get("url"),
               "title": t.get("title", ""), "kind": kind or "check", "score": 0}
    k = kind if kind in ASKING else (tab["kind"] if tab["kind"] in ASKING else "check")
    site = _site(tab["url"]) or "the site"
    req = _open_request(tab["target_id"])
    if req is None:
        req = {"id": secrets.token_hex(6), "created": time.time(), "site": site, "kind": k, "port": p,
               "target_id": tab["target_id"], "url": tab["url"], "title": tab.get("title", ""),
               "line": line_for(site, k), "phone_fallback": phone_fallback(site, k), "why": why[:200]}
        _write_json(handoff_dir() / f"{req['id']}.request.json", req)
    start_url = tab["url"]
    answer = _wait(req, tab.get("ws") or "", start_url, WAIT_SECONDS if wait is None else wait)
    _failures.pop(_key(tid, site), None)
    if answer is None:
        return {"success": False, "error_type": "still_waiting", "site": site, "asking": ASKING[k],
                "next": ("The window and the Done button are still up. Call browser_vault action=hand_off again to keep "
                         "waiting (it reuses the same window). Do not ask for the code in chat.")}
    if answer == "away":
        return {"success": False, "answer": "not_at_mac", "site": site, "phone_fallback": req["phone_fallback"],
                "next": ("The person isn't at the Mac. Give them phone_fallback in one or two short lines, adapted to the job. "
                         "The page stays open on this step; if they later say they're back, call hand_off again.")}
    after = page_step(tab["ws"]) if tab.get("ws") else {"kind": "unknown"}
    moved = after.get("kind") not in HUMAN_KINDS or (after.get("url") and after.get("url") != start_url
                                                      and after.get("kind") != k)
    out = {"success": bool(moved), "answer": answer, "moved_on": bool(moved), "site": site,
           "url": after.get("url", ""), "title": after.get("title", "")}
    out["next"] = ("The page moved on. Carry on with the job by yourself on this same tab (target "
                   f"{tab['target_id']}); don't ask the person anything else about this step." if moved else
                   f"The page still asks for {ASKING[k]}. Call browser_vault action=hand_off once more; if it still "
                   "hasn't moved on, tell the person plainly and stop.")
    return out


def _wait(req: dict, ws: str, start_url: str, seconds: float) -> Optional[str]:
    d = handoff_dir()
    ans_file = d / f"{req['id']}.answer.json"
    deadline = time.time() + max(0.0, seconds)
    last_probe = 0.0
    gone_since = 0.0
    while True:
        a = _read_json(ans_file)
        if a and a.get("answer"):
            return "away" if a["answer"] == "away" else "done"
        now = time.time()
        if now >= deadline:
            return None
        if ws and now - last_probe > 3:
            last_probe = now
            step = page_step(ws)
            gone = step.get("kind") not in HUMAN_KINDS and step.get("kind") != "unknown"
            if gone and step.get("url") != start_url:
                gone_since = gone_since or now
                if now - gone_since > 2:  # the page moved on by itself (the person typed the code and clicked Verify)
                    _write_json(ans_file, {"answer": "done", "by": "page", "at": now})
                    return "done"
            else:
                gone_since = 0.0
        time.sleep(0.5)


def _key(tid: str, site: str) -> str:
    return f"{tid}|{site}"


# ---------------------------------------------------------------------------
# Wiring into browser_vault
# ---------------------------------------------------------------------------

def install(ns: dict) -> None:
    """Called from the end of tools/browser_vault_tool.py with its globals()."""
    if ns.get("_ONE_HUMAN_STEP"):
        return
    ns["_ONE_HUMAN_STEP"] = True
    import agent.vault_login_classifier as clf
    clf.classify_otp_controls = classify_otp_controls

    original_enter_code = ns["browser_vault_enter_code"]
    probes = ns["_TAB_PROBES"]
    default_probe = probes.get("otp", "")

    def enter_code(handle: str = "", task_id: Optional[str] = None) -> str:
        tid = task_id or "default"
        port = _local_port(tid)
        tab = None
        if port is not None:
            tab = pick_step_tab(*port)
            if tab and tab["kind"] in ("check", "passkey", "security_key", "approve"):
                # Nothing automatic can do these: hand off straight away.
                return json.dumps(hand_off(tab["kind"], tid, why=f"enter_code met {tab['kind']}"))
        with _lock:
            if tab and tab["kind"] == "code":
                probes["otp"] = f"location.href === {json.dumps(tab['url'])}"
            try:
                raw = original_enter_code(handle=handle, task_id=tid)
            finally:
                probes["otp"] = default_probe
        try:
            res = json.loads(raw)
        except Exception:
            return raw
        site = _site((tab or {}).get("url") or str(res.get("origin") or ""))
        if res.get("success"):
            _failures.pop(_key(tid, site), None)
            return raw
        err = res.get("error_type") or "fill_failed"
        if err in ("code_declined", "human_has_control"):
            return raw
        if port is None:
            res["phone_fallback"] = phone_fallback(site or "the site", "code")
            res["next"] = "This browser can't be shown on this Mac. Give the person phone_fallback; never ask for the code in chat."
            return json.dumps(res)
        n = _failures.get(_key(tid, site), 0) + 1
        _failures[_key(tid, site)] = n
        # prompt_unavailable: nobody can type the code for us here, so retrying can't help.
        if err == "prompt_unavailable" or n >= MAX_AUTO_TRIES:
            out = hand_off("code", tid, why=f"enter_code: {err} (try {n})")
            out["auto_tries"] = n
            return json.dumps(out)
        res["next"] = (f"Automatic try {n} of {MAX_AUTO_TRIES} failed ({err}). Try enter_code once more; after that One "
                       "shows the page to the person by itself. Never ask for the code in chat.")
        return json.dumps(res)

    ns["browser_vault_enter_code"] = enter_code

    schema = ns["BROWSER_VAULT_SCHEMA"]
    props = schema["parameters"]["properties"]
    if "hand_off" not in props["action"]["enum"]:
        props["action"]["enum"].append("hand_off")
    props["kind"] = {"type": "string", "enum": list(ASKING),
                     "description": "hand_off only: what the site asks of the person (default: detected)."}
    schema["description"] += (
        " hand_off (kind optional): a step only the person can do (a code you can't enter, passkey, security key, "
        "approve on their device, CAPTCHA/Cloudflare check): One shows this same page in a window with Done / I'm not at "
        "the Mac and the call waits, then reports moved_on or a phone_fallback. enter_code hands off by itself after 2 "
        "failed tries. Never ask the person to type a code in chat.")

    original_handle = ns["_handle_vault"]

    def handle_vault(args: dict, **kwargs) -> str:
        if str(args.get("action") or "") == "hand_off":
            return json.dumps(hand_off(str(args.get("kind") or ""), kwargs.get("task_id")))
        return original_handle(args, **kwargs)

    ns["_handle_vault"] = handle_vault
    try:
        reg = ns["registry"]
        entry = reg._tools.get("browser_vault") if hasattr(reg, "_tools") else None
        if entry is not None and hasattr(entry, "handler"):
            entry.handler = handle_vault
            entry.description = schema["description"]
    except Exception:
        pass
