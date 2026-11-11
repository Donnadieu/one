"""Phone replies to a code hand-off (One's phone-chat plugin, tools/overlay/plugins/one-missed-messages).

When a helper waits on a code and the ask went to the phone chat, the person's reply there is read BEFORE the
assistant sees it. Only a reply that looks like a code is typed into the page (4 to 8 digits, or the site's own
format). "no code", "didn't get it", "cancel" end the ask; anything else goes to the waiting helper as their message.
On 0.9.113 "abc1234" was typed in as a code and "no code" / "cancel" changed nothing (Nov 11 2026).
Plain python, no engine: the hook is called the way the gateway calls it, with stand-in events and a stand-in gateway.
"""
import asyncio, datetime as dt, importlib.util, json, os, sys, tempfile, time
from enum import Enum
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parents[2] / "tools" / "overlay" / "plugins" / "one-missed-messages" / "__init__.py"
home = tempfile.mkdtemp(prefix="one-phone-replies-")
os.environ["HERMES_HOME"] = home
D = Path(home) / "handoff"
D.mkdir()
os.environ["ONE_HANDOFF_DIR"] = str(D)
NOW = time.time()
os.environ["ONE_MISSED_NOW"] = str(NOW)
spec = importlib.util.spec_from_file_location("one_missed", HERE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
fails = 0
CHAT = "8628960251"


def check(name, ok):
    global fails
    print(f"  {'✓' if ok else '✗'} {name}")
    fails += 0 if ok else 1


class Platform(Enum):
    TELEGRAM = "telegram"


class Adapter:
    def __init__(self):
        self.sent = []

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        self.sent.append((chat_id, content))


tg = Adapter()
gateway = SimpleNamespace(adapters={Platform.TELEGRAM: tg}, _is_user_authorized=lambda src: src.user_id == "omar")
n = 0


def ask():
    """A code step whose ask went to this phone chat (what One writes), still waiting."""
    global n
    n += 1
    for f in D.glob("*.phone.json"):  # one ask open at a time, as in real use
        f.unlink()
    rid = f"phone{n}"
    (D / f"{rid}.request.json").write_text(json.dumps({
        "id": rid, "created": NOW - 30, "site": "account-d.docusign.com", "kind": "code", "port": 9344,
        "target_id": "T", "url": "https://account-d.docusign.com/x", "box": True,
        "format": {"digits": False, "max": 6}}))  # DocuSign's box: type=text, maxlength 6
    (D / f"{rid}.phone.json").write_text(json.dumps({"id": rid, "chat": CHAT, "at": NOW - 20}))
    return rid


def reply(text):
    e = SimpleNamespace(text=text, internal=False, message_type=None,
                        timestamp=dt.datetime.fromtimestamp(NOW - 2, dt.timezone.utc),
                        source=SimpleNamespace(platform=Platform.TELEGRAM, chat_id=CHAT, user_id="omar"))
    return asyncio.run(m.pre_gateway_dispatch(event=e, gateway=gateway, session_store=None))


def ans(rid):
    f = D / f"{rid}.answer.json"
    return json.loads(f.read_text()) if f.exists() else None


for text, want in [("no code", "no_code"), ("didn't get it", "no_code"), ("Not receiving any code", "no_code"),
                   ("I never got a text", "no_code"), ("cancel", "cancelled"), ("Stop", "cancelled")]:
    rid = ask()
    tg.sent.clear()
    r = reply(text)
    a = ans(rid) or {}
    check(f"\"{text}\" ends the ask: {want}, never typed as a code, never to the assistant",
          a.get("answer") == want and "code" not in a and (r or {}).get("action") == "skip")
    check(f"\"{text}\": they're told in one line", len(tg.sent) == 1)
for text, code in [("123456", "123456"), ("12 34 56", "123456"), ("Code: 424-242", "424242")]:
    rid = ask()
    r = reply(text)
    a = ans(rid) or {}
    check(f"\"{text}\" is a code: it goes to the page", a.get("answer") == "code" and a.get("code") == code)
rid = ask()
r = reply("abc1234")
a = ans(rid) or {}
check("\"abc1234\" doesn't look like this site's code (6 characters): not typed in", a.get("answer") != "code")
check("...it goes to the waiting helper as their message", a.get("answer") == "message" and a.get("text") == "abc1234")
rid = ask()
r = reply("What's taking so long?")
a = ans(rid) or {}
check("any other reply goes to the waiting helper, not typed as a code",
      a.get("answer") == "message" and a.get("text") == "What's taking so long?" and (r or {}).get("action") == "skip")
for f in D.glob("*.phone.json"):
    f.unlink()
check("with no code ask open, \"no code\" is a normal message for the assistant", reply("no code") is None)
print("phone replies", "ok" if fails == 0 else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
