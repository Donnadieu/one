"""Checks One's phone-tags plugin (tools/overlay/plugins/one-phone-tags) on real Telegram replies (Nov 15, 17, 28 2026).

Plain python, no engine: the hooks are called the way the engine calls them (`transform_llm_output(response_text=…,
session_id=…, platform=…, turn_id=…)`, `pre_llm_call(platform=…)`) with a scratch HERMES_HOME, and the gateway's last
step before sending (`gateway.run._sanitize_gateway_final_response`) is a stand-in. Proves: a phone-chat reply with a
[helper: …] line is handed to One exactly once (the same reply again is not written twice) and the person never sees
the line; a [tell-helper: …] reply is handed over too; a reply that was only tags gets one plain line; One's own chat,
helpers and sub-helpers are never touched; what the phone shows is what One's own chat shows
(tests/fixtures/phone-tags/shown.json, also checked against Helpers.strip in `One --test-helpers`); every phone turn
tells the assistant helper lines work there, with One's latest helper news.

Nov 28: the SAVED reply (what the engine stores and replays next turn) keeps its real helper lines and never holds a
"↳" receipt, so the assistant has no receipt shape to copy; the receipts are only in what the phone gets. A reply that
says a helper was sent or told but holds no line gets one silent correction turn (the assistant stub here) and the
person sees only the fixed reply; only when that fails too are they told nothing started.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "tools" / "overlay" / "plugins" / "one-phone-tags" / "__init__.py"
FIX = ROOT / "tests" / "fixtures" / "phone-tags"
home = tempfile.mkdtemp(prefix="one-phone-tags-")
os.environ["HERMES_HOME"] = home
os.environ["HERMES_SESSION_CHAT_ID"] = "4242"  # the gateway's per-chat setting (outside the engine: plain env)
# Loaded the way the engine loads a plugin (hermes_cli/plugins_loader.py): a package, so its own tags.py imports.
spec = importlib.util.spec_from_file_location("one_phone_tags", HERE, submodule_search_locations=[str(HERE.parent)])
m = importlib.util.module_from_spec(spec)
sys.modules["one_phone_tags"] = m
spec.loader.exec_module(m)

fails = 0


def check(name, ok):
    global fails
    print(f"  {'✓' if ok else '✗'} {name}")
    if not ok:
        fails += 1


inbox = Path(home) / "one-phone" / "inbox"


def handed():
    return sorted(inbox.glob("*.json")) if inbox.exists() else []


def clear():
    for f in handed():
        f.unlink()


# The assistant, for the one correction turn: a stand-in that records what it was asked and answers as told.
asked = []


def assistant(answer):
    def ask(messages):
        asked.append(messages)
        if isinstance(answer, BaseException):
            raise answer
        return answer
    return ask


m._ask = assistant("")  # unless a section says otherwise, the correction turn brings nothing back

# The gateway's last step before a reply goes to the chat (gateway/run.py), standing in for the engine's own.
gw = types.ModuleType("gateway.run")
gw._sanitize_gateway_final_response = lambda platform, text: text
sys.modules.setdefault("gateway", types.ModuleType("gateway"))
sys.modules["gateway.run"] = gw
install = getattr(m, "install_delivery", None)
if install:
    install()


def sent(saved, platform="telegram"):
    """What the gateway sends to that chat for a saved reply."""
    return gw._sanitize_gateway_final_response(types.SimpleNamespace(value=platform), saved)


def turn(text, sid="tg-1", platform="telegram", tid="t"):
    """One turn's end: (what's saved and replayed next turn, what the phone gets)."""
    out = m.transform_llm_output(response_text=text, session_id=sid, platform=platform, turn_id=tid)
    saved = text if out is None else out
    return saved, sent(saved, platform)


def clean_save(saved):
    return "↳" not in saved and m.MISSING_SHOWN not in saved


helper = (FIX / "nov15-helper.txt").read_text()
tell = (FIX / "nov15-tell.txt").read_text()

print("1. the Nov 15 reply in the phone chat: a [helper: …] line over several paragraphs that never closed")
saved, out = turn(helper, tid="t1")
check("the person gets the reply without the helper line, and a receipt for it",
      out == "I'm sending a helper to build it now. It runs until the channel is live and posting by itself.\n\n"
             "↳ Helper sent: Science explainer channel")
check("nothing of the job shows", "[helper" not in out and "Brand Account" not in out)
check("the saved reply keeps its real helper line, and no receipt the assistant could copy",
      saved == helper and clean_save(saved))
files = handed()
check("the whole reply is handed to One, once", len(files) == 1)
rec = json.loads(files[0].read_text()) if files else {}
check("with where it came from (platform, chat, conversation)",
      rec.get("platform") == "telegram" and rec.get("chat") == "4242" and rec.get("session") == "tg-1")
check("and the reply exactly as written", rec.get("reply") == helper)
_, again = turn(helper, tid="t1")
check("the same turn again shows the same", again == out)
turn(helper, tid="t1-rerun")
check("the same reply again (a re-run turn) is handed over once, not twice", len(handed()) == 1)
turn(helper, sid="tg-2", platform="Telegram", tid="t9")
check("the same words in another conversation are their own reply", len(handed()) == 2)
clear()

print("2. the Nov 15 tell: passed on to the helper, never shown")
saved, out = turn(tell, tid="t2")
check("the person sees only the confirmation", out.startswith("Sent to Science explainer channel.")
      and "[tell-helper" not in out and "Wikimedia" not in out and "↳ Passed on to Science explainer channel" in out)
check("the saved reply keeps its real tell line", "[tell-helper: Science explainer channel" in saved and clean_save(saved))
check("and One gets the tell", len(handed()) == 1 and json.loads(handed()[0].read_text())["reply"] == tell)
clear()

print("3. a reply that was only tags gets one plain line")
only = "[helper: Hotels | Find a hotel in Quebec for Dec 20 to 24.]"
saved, out = turn(only, tid="t3")
check(f"a plain line instead of nothing ({out})", "Hotels" in out and "[" not in out)
check("the saved reply is the line itself", saved == only)
check("and the helper still goes to One", len(handed()) == 1)
clear()
_, out = turn("[stop-helper: Hotels]", platform="whatsapp", tid="t4")
check(f"a stop alone says it stopped ({out})", out == "Stopped Hotels.")
clear()

print("4. nothing else is touched")
os.environ.pop("HERMES_SESSION_PLATFORM", None)
for p in ["acp", "subagent", "cron", "cli", "api_server"]:
    check(f"a {p} reply is left alone, saved and sent",
          m.transform_llm_output(response_text=helper, session_id="x", platform=p, turn_id="t") is None
          and sent(helper, p) == helper)
check("nothing handed to One for them", handed() == [])
plain = "Keep it running, and keep science.\n\n[choices: Yes, send it | Keep it pure science]"
check("a phone reply without helper lines is left as it is",
      m.transform_llm_output(response_text=plain, session_id="tg-1", platform="telegram", turn_id="t5") is None
      and sent(plain) == plain)
learned = "Here you go.\n[learned: Omar likes short answers]"
_, out = turn(learned, tid="t6")
check("a [learned: …] line is hidden on the phone too, and nothing handed over", out == "Here you go." and handed() == [])
check("an empty or odd answer never breaks", m.transform_llm_output(response_text=None, platform="telegram") is None
      and sent(None) is None and sent("") == "")
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
check("the gateway's own platform setting counts when the hook isn't told one",
      m.transform_llm_output(response_text=only, session_id="tg-3", platform="", turn_id="t7") is None
      and len(handed()) == 1)
os.environ.pop("HERMES_SESSION_PLATFORM", None)
clear()

print("5. the phone shows what One's own chat shows (shared with Helpers.strip in One --test-helpers)")
for case in json.loads((FIX / "shown.json").read_text()):
    check(case["name"], m.shown(case["reply"]) == case["shown"])

print("6. every phone turn tells the assistant helper lines work there, with One's news")
note = m.pre_llm_call(platform="telegram", session_id="tg-1")
check("the rule rides along", note is not None and "Helper lines work here" in note["context"])
check("never on One's own chat", m.pre_llm_call(platform="acp") is None and m.pre_llm_call(platform="subagent") is None)
news = Path(home) / "one-phone" / "news.md"
news.parent.mkdir(parents=True, exist_ok=True)
news.write_text("Helpers right now:\n- Science explainer channel: still working (Writing the first script, 4 min).")
note = m.pre_llm_call(platform="telegram")
check("with how its helpers are doing", "Science explainer channel: still working" in note["context"])
old = time.time() - 8 * 24 * 3600
os.utime(news, (old, old))
check("but not a week-old note (One gone quiet)", "Science explainer" not in m.pre_llm_call(platform="telegram")["context"])

print("7. Nov 17: replies that said a job was starting, no helper line, and the correction turn brought none either")
log = Path(home) / "logs" / "one-phone-tags.log"
for case in json.loads((FIX / "nov17-missing.json").read_text()):
    before = log.read_text() if log.exists() else ""
    _, said = turn(case["reply"], tid="t-" + case["name"])
    check(f"{case['name']}: nothing handed to One", handed() == [])
    check(f"{case['name']}: logged loudly", "MISSING HELPER LINE" in (log.read_text() if log.exists() else "")[len(before):])
    note = m.pre_llm_call(platform="telegram")["context"]
    check(f"{case['name']}: the next turn is told nothing started", "started NOTHING" in note)
    check(f"{case['name']}: once", "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])
    hangs = case["reply"].rstrip().endswith(":") or "sending a helper" in case["reply"]
    check(f"{case['name']}: the person {'is' if hangs else 'is not'} told nothing started",
          (m.MISSING_SHOWN in said) == hangs)
    if hangs:
        check(f"{case['name']}: what they wrote still shows", said.startswith(case["reply"].rstrip()))

print("8. the 08:45 reply that worked (its lines rebuilt from the helpers it started): handed over, with receipts")
succ = "Yes, you should see every helper as an orb in One. Right now there are two: **Freelance profiles** and **Post daily build**.\n\nThe rerun of today's video and the update fix aren't there because I never actually sent them. I wrote \"starting now\" without starting anything, for the third time. Sending them now, for real:\n\n[helper: Rerun today's video | Then It Clicked YouTube channel: today's (Tue Nov 17) 7 AM long-video routine was cut about 3 minutes in when One updated. Make today's video now.]\n[helper: Updates wait for routines | Omar's One Mac app (repo Donnadieu/one). Bug: installing a One update restarts the engine and kills any scheduled routine that's mid-run. Fix it.]"
turn(json.loads((FIX / "nov17-missing.json").read_text())[3]["reply"], tid="t-miss")
n = len(asked)
saved, out = turn(succ, tid="t-ok")
check("handed to One once", len(handed()) == 1)
check(f"the person sees the receipts, not the lines ({out!r:.80})", "[helper" not in out and out.endswith(
    "Sending them now, for real:\n\n↳ Helper sent: Rerun today's video\n↳ Helper sent: Updates wait for routines"))
check("saved with both real lines, no receipts", saved == succ and clean_save(saved))
check("no missing-line warning, and no correction turn", m.MISSING_SHOWN not in out and len(asked) == n)
check("and it clears the earlier miss for that chat", "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])
clear()
with_choice = "On it.\n[helper: Hotels | Find a hotel in Quebec.]\n\n[choices: Cheap | Nice]"
_, out = turn(with_choice, platform="whatsapp", tid="t-c")
check(f"a receipt goes above a last choices line ({out!r})", out == "On it.\n\n↳ Helper sent: Hotels\n\n[choices: Cheap | Nice]")
clear()

print("9. what isn't a promise is left alone (no correction turn either)")
n = len(asked)
for text in ["Should I start a helper to look into it?", "If you say yes, I'm sending a helper to book it.",
             "The helper I sent yesterday is still working on it.", "Here's what changed:\n- the buttons\n- the voice",
             "Rerun today's video is still running (waiting on a slow command).", "I've started thinking about it. More soon.",
             "Should I tell the helper to skip the tests?", "If you want, I'll pass that on to the helper."]:
    out = m.transform_llm_output(response_text=text, session_id="tg-1", platform="telegram", turn_id="t-n")
    check(f"{text[:50]!r}: untouched, no note", out is None and sent(text) == text
          and "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])
check("the assistant was never asked to fix any of them", len(asked) == n)
fake = "Starting it now.\n↳ Helper sent: Hotels"
saved, out = turn(fake, tid="t-f")
check("a receipt the assistant wrote itself, with no line, is taken off and the person told",
      "↳" not in out and m.MISSING_SHOWN in out and handed() == [])
check("and it's never saved for the assistant to copy", "↳" not in saved)
check("the rule tells the assistant only the line itself starts a job",
      "only when THIS reply holds its own" in m.pre_llm_call(platform="telegram")["context"])
check("the rule no longer says saved replies are cut", "saved without" not in m.pre_llm_call(platform="telegram")["context"])
check("One's own chat is never warned", m.transform_llm_output(response_text=fake, session_id="x", platform="acp", turn_id="t") is None)

print("10. Nov 28: 'I'm sending a helper' / '↳ Passed on to …' with no line: one silent correction turn, the fixed reply")
for i, case in enumerate(json.loads((FIX / "nov28-missing.json").read_text())):
    m._ask = assistant(case["answer"])
    n = len(asked)
    saved, out = turn(case["reply"], tid=f"t28-{i}")
    name = case["name"][:60]
    check(f"{name}: the assistant was asked once", len(asked) == n + 1)
    prompt = json.dumps(asked[-1]) if len(asked) > n else ""
    check(f"{name}: and told what it promised, to answer with ONLY the line", "ONLY" in prompt and "[helper:" in prompt
          and "[tell-helper:" in prompt)
    check(f"{name}: the person never sees 'Nothing started'", m.MISSING_SHOWN not in out)
    check(f"{name}: they see One's own receipt, once", out.count(case["receipt"]) == 1 and out.count("↳") == 1)
    check(f"{name}: and no tag", "[helper" not in out and "[tell-helper" not in out)
    files = handed()
    rec = json.loads(files[0].read_text()) if files else {}
    check(f"{name}: the job goes to One once, with the real line", len(files) == 1
          and case["answer"].split("\n")[-1] in rec.get("reply", ""))
    check(f"{name}: the saved reply holds the real line and no receipt", case["answer"].split("\n")[-1] in saved
          and clean_save(saved))
    check(f"{name}: the next turn isn't told nothing started", "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])
    clear()
first = json.loads((FIX / "nov28-missing.json").read_text())[1]
m._ask = assistant(first["answer"])
turn(first["reply"], tid="t28-x")
turn(first["reply"], tid="t28-x-rerun")
check("the same reply again (a re-run turn) starts its fixed job once", len(handed()) == 1)
clear()

print("11. the correction turn fails too: then, and only then, a short plain note")
cal = json.loads((FIX / "nov28-missing.json").read_text())[1]["reply"]
for label, answer in [("brings back no line", "Sorry, here's the plan again: set up Cal.com."), ("brings back nothing", ""),
                      ("can't be reached", RuntimeError("no provider")), ("a line with no job", "[helper: Cal.com setup]")]:
    m._ask = assistant(answer)
    _, out = turn(cal, sid="tg-11-" + label, tid="t11-" + label)  # its own chat: never the fix above
    check(f"{label}: they're told nothing started, in one short line", out.endswith(m.MISSING_SHOWN)
          and len(m.MISSING_SHOWN) < 90)
    check(f"{label}: what they wrote still shows, nothing goes to One", out.startswith(cal.rstrip()) and handed() == [])
    check(f"{label}: the next turn is told", "started NOTHING" in m.pre_llm_call(platform="telegram")["context"])
m._ask = assistant("NONE")
_, out = turn("Starting it now. More in a minute.", sid="tg-11-none", tid="t11-none")
check("the assistant says it meant no job (NONE): no note, nothing started",
      m.MISSING_SHOWN not in out and handed() == [] and "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])

print("12. the gateway's own last step: receipts only on the way out, installed once")
if install:
    install()
check("installed once, however often it's called", getattr(gw._sanitize_gateway_final_response, "__wrapped__", None) is not None
      and getattr(gw._sanitize_gateway_final_response.__wrapped__, "__wrapped__", None) is None)
check("a crash-left saved reply sent again later gets the same receipts",
      sent(helper).endswith("↳ Helper sent: Science explainer channel") and "[helper" not in sent(helper))

print("phone-tags ok" if fails == 0 else f"phone-tags: {fails} failed")
sys.exit(1 if fails else 0)
