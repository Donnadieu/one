"""Local test site for hand-offs (tools/handoff-check.sh). Serves tests/handoff/pages, plus two steps that, like
DocuSign's sign-up code page, exist ONLY as the answer to a form POST: their state lives in the open page (a hidden
one-time `invite` field), and opening the same address again (a GET: a new tab, a reload, a reopened window) lands on
a log-in page. So a hand-off only works if the person is given the very tab the helper was on.

  GET  /signup.html       email form -> POST /send-code
  POST /send-code         the code step: "Enter the code we sent", box #x7, hidden invite, button #go -> POST /verify
  GET  /send-code         302 -> /login.html (the page can't be reopened)
  POST /verify            right code + live invite -> 302 /welcome.html?who=<email>; else the code step again
  GET  /approve-start     form -> POST /approve (a step the person does in the page: tick + Continue)
  POST /approve           "Confirm it's you": checkbox #ok, hidden invite, button #cont -> POST /approved
  GET  /approve           302 -> /login.html
  POST /approved          ticked + live invite -> 302 /welcome.html?who=approved
  GET  /v2/usertoaccountinvite/smsverification-enterphone   like DocuSign's SMS step (pages/sms-enterphone.html): asks
                          for a phone number first; only after Send Code does the same page show the code box
  POST /sms/send          Send Code (counted: sms_sent)       POST /sms/verify   {"ok": right code} (sms_verify_fail)
  GET  /state.json        what the server saw (invites issued and used), for the checks
Usage: python3 post_server.py <port> <pages dir>
"""
import html, json, secrets, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

CODE = "424242"
STATE = {"invites": {}, "used": [], "gets_bounced": 0, "verify_fail": 0, "sms_sent": 0, "sms_verify_fail": 0, "sms_ok": 0}
ENTER_PHONE = "/v2/usertoaccountinvite/smsverification-enterphone"


def page(title: str, body: str) -> bytes:
    return (f"<!doctype html><html><head><meta charset=utf-8><title>{title}</title></head>"
            f"<body style='font:16px -apple-system;margin:40px'>{body}</body></html>").encode()


def code_step(email: str, invite: str, note: str = "") -> bytes:
    return page("Enter your code", f"""
<h1>Enter the code we sent</h1><p id=who>We sent a 6-digit code to {html.escape(email)}.</p>{note}
<form method=post action=/verify>
  <input type=hidden name=invite value="{invite}"><input type=hidden name=email value="{html.escape(email)}">
  <label for=x7>Verification code</label>
  <input id=x7 name=x7 inputmode=numeric autocomplete=one-time-code maxlength=6 style='font-size:22px;width:9em'>
  <button id=go type=submit>Verify</button>
</form>""")


def approve_step(invite: str) -> bytes:
    return page("Confirm it's you", f"""
<h1>Confirm it's you</h1>
<form method=post action=/approved>
  <input type=hidden name=invite value="{invite}">
  <label><input type=checkbox id=ok name=ok value=1> Yes, it's me</label>
  <button id=cont type=submit>Continue</button>
</form>""")


class H(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body: bytes, status: int = 200, loc: str = ""):
        self.send_response(status)
        if loc:
            self.send_header("Location", loc)
        self.send_header("Content-Type", "text/html; charset=utf-8" if not loc else "text/plain")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p in ("/send-code", "/verify", "/approve", "/approved"):
            STATE["gets_bounced"] += 1  # someone reopened a POST-only page: it can't be, like DocuSign's
            return self._send(b"", 302, "/login.html")
        if p == "/state.json":
            return self._send(json.dumps(STATE).encode())
        if p == "/approve-start":
            return self._send(page("Start", "<form method=post action=/approve><button id=start>Start</button></form>"))
        if p == ENTER_PHONE:
            with open(f"{self.directory}/sms-enterphone.html", "rb") as fh:
                return self._send(fh.read())
        return super().do_GET()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        f = {k: v[0] for k, v in parse_qs(self.rfile.read(n).decode()).items()}
        p = self.path.split("?", 1)[0]
        if p == "/sms/send":
            STATE["sms_sent"] += 1
            return self._send(b'{"sent": true}')
        if p == "/sms/verify":
            ok = f.get("code", "").strip() == CODE
            STATE["sms_ok" if ok else "sms_verify_fail"] += 1
            return self._send(json.dumps({"ok": ok}).encode())
        if p == "/send-code":
            inv = secrets.token_hex(8)
            STATE["invites"][inv] = f.get("email", "")
            return self._send(code_step(f.get("email", ""), inv))
        if p == "/verify":
            inv = f.get("invite", "")
            if inv in STATE["invites"] and inv not in STATE["used"] and f.get("x7", "").strip() == CODE:
                STATE["used"].append(inv)
                return self._send(b"", 303, "/welcome.html?who=" + STATE["invites"][inv])
            STATE["verify_fail"] += 1
            if inv in STATE["invites"]:
                return self._send(code_step(f.get("email", ""), inv, "<p id=bad>That code didn't work.</p>"))
            return self._send(b"", 303, "/login.html")
        if p == "/approve":
            inv = secrets.token_hex(8)
            STATE["invites"][inv] = "approve"
            return self._send(approve_step(inv))
        if p == "/approved":
            inv = f.get("invite", "")
            if inv in STATE["invites"] and inv not in STATE["used"] and f.get("ok") == "1":
                STATE["used"].append(inv)
                return self._send(b"", 303, "/welcome.html?who=approved")
            return self._send(b"", 303, "/login.html")
        self._send(b"", 404)


if __name__ == "__main__":
    port, root = int(sys.argv[1]), sys.argv[2]
    handler = lambda *a, **k: H(*a, directory=root, **k)
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
