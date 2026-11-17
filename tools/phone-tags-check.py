"""Checks One's phone-tags plugin (tools/overlay/plugins/one-phone-tags) on the Nov 15 2026 Telegram replies.

Plain python, no engine: the hooks are called the way the engine calls them (`transform_llm_output(response_text=…,
session_id=…, platform=…, turn_id=…)`, `pre_llm_call(platform=…)`) with a scratch HERMES_HOME. Proves: a phone-chat
reply with a [helper: …] line is handed to One exactly once (the same reply again is not written twice) and the
person never sees the line; a [tell-helper: …] reply is handed over too; a reply that was only tags gets one plain
line; One's own chat, helpers and sub-helpers are never touched; what the phone shows is what One's own chat shows
(tests/fixtures/phone-tags/shown.json, also checked against Helpers.strip in `One --test-helpers`); every phone turn
tells the assistant helper lines work there, with One's latest helper news.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HERE = ROOT / "tools" / "overlay" / "plugins" / "one-phone-tags" / "__init__.py"
FIX = ROOT / "tests" / "fixtures" / "phone-tags"
home = tempfile.mkdtemp(prefix="one-phone-tags-")
os.environ["HERMES_HOME"] = home
os.environ["HERMES_SESSION_CHAT_ID"] = "4242"  # the gateway's per-chat setting (outside the engine: plain env)
spec = importlib.util.spec_from_file_location("one_phone_tags", HERE)
m = importlib.util.module_from_spec(spec)
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


helper = (FIX / "nov15-helper.txt").read_text()
tell = (FIX / "nov15-tell.txt").read_text()

print("1. the Nov 15 reply in the phone chat: a [helper: …] line over several paragraphs that never closed")
out = m.transform_llm_output(response_text=helper, session_id="tg-1", platform="telegram", turn_id="t1")
check("the person gets the reply without the helper line, and a receipt for it",
      out == "I'm sending a helper to build it now. It runs until the channel is live and posting by itself.\n\n"
             "↳ Helper sent: Science explainer channel")
check("nothing of the job shows", out is not None and "[helper" not in out and "Brand Account" not in out)
files = handed()
check("the whole reply is handed to One, once", len(files) == 1)
rec = json.loads(files[0].read_text()) if files else {}
check("with where it came from (platform, chat, conversation)",
      rec.get("platform") == "telegram" and rec.get("chat") == "4242" and rec.get("session") == "tg-1")
check("and the reply exactly as written", rec.get("reply") == helper)
again = m.transform_llm_output(response_text=helper, session_id="tg-1", platform="telegram", turn_id="t1")
check("the same turn again shows the same", again == out)
m.transform_llm_output(response_text=helper, session_id="tg-1", platform="telegram", turn_id="t1-rerun")
check("the same reply again (a re-run turn) is handed over once, not twice", len(handed()) == 1)
m.transform_llm_output(response_text=helper, session_id="tg-2", platform="Telegram", turn_id="t9")
check("the same words in another conversation are their own reply", len(handed()) == 2)
for f in handed():
    f.unlink()

print("2. the Nov 15 tell: passed on to the helper, never shown")
out = m.transform_llm_output(response_text=tell, session_id="tg-1", platform="telegram", turn_id="t2")
check("the person sees only the confirmation", out is not None and out.startswith("Sent to Science explainer channel.")
      and "[tell-helper" not in out and "Wikimedia" not in out)
check("and One gets the tell", len(handed()) == 1 and json.loads(handed()[0].read_text())["reply"] == tell)
for f in handed():
    f.unlink()

print("3. a reply that was only tags gets one plain line")
only = "[helper: Hotels | Find a hotel in Quebec for Dec 20 to 24.]"
out = m.transform_llm_output(response_text=only, session_id="tg-1", platform="telegram", turn_id="t3")
check(f"a plain line instead of nothing ({out})", out is not None and "Hotels" in out and "[" not in out)
check("and the helper still goes to One", len(handed()) == 1)
for f in handed():
    f.unlink()
out = m.transform_llm_output(response_text="[stop-helper: Hotels]", session_id="tg-1", platform="whatsapp", turn_id="t4")
check(f"a stop alone says it stopped ({out})", out == "Stopped Hotels.")
for f in handed():
    f.unlink()

print("4. nothing else is touched")
os.environ.pop("HERMES_SESSION_PLATFORM", None)
for p in ["acp", "subagent", "cron", "cli"]:
    check(f"a {p} reply is left alone", m.transform_llm_output(response_text=helper, session_id="x", platform=p, turn_id="t") is None)
check("nothing handed to One for them", handed() == [])
plain = "Keep it running, and keep science.\n\n[choices: Yes, send it | Keep it pure science]"
check("a phone reply without helper lines is left as it is",
      m.transform_llm_output(response_text=plain, session_id="tg-1", platform="telegram", turn_id="t5") is None)
learned = "Here you go.\n[learned: Omar likes short answers]"
check("a [learned: …] line is hidden on the phone too, and nothing handed over",
      m.transform_llm_output(response_text=learned, session_id="tg-1", platform="telegram", turn_id="t6") == "Here you go."
      and handed() == [])
check("an empty or odd answer never breaks", m.transform_llm_output(response_text=None, platform="telegram") is None)
os.environ["HERMES_SESSION_PLATFORM"] = "telegram"
check("the gateway's own platform setting counts when the hook isn't told one",
      m.transform_llm_output(response_text=only, session_id="tg-3", platform="", turn_id="t7") is not None and len(handed()) == 1)
os.environ.pop("HERMES_SESSION_PLATFORM", None)
for f in handed():
    f.unlink()

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

print("7. Nov 17: replies that said a job was starting but held no helper line (tests/fixtures/phone-tags/nov17-missing.json)")
log = Path(home) / "logs" / "one-phone-tags.log"
missing = Path(home) / "one-phone" / "missing.json"
for case in json.loads((FIX / "nov17-missing.json").read_text()):
    before = log.read_text() if log.exists() else ""
    out = m.transform_llm_output(response_text=case["reply"], session_id="tg-1", platform="telegram", turn_id="t-" + case["name"])
    said = (out or case["reply"])
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
m.transform_llm_output(response_text=json.loads((FIX / "nov17-missing.json").read_text())[3]["reply"], session_id="tg-1",
                       platform="telegram", turn_id="t-miss")
out = m.transform_llm_output(response_text=succ, session_id="tg-1", platform="telegram", turn_id="t-ok")
check("handed to One once", len(handed()) == 1)
check(f"the person sees the receipts, not the lines ({out!r:.80})", out is not None and "[helper" not in out and out.endswith(
    "Sending them now, for real:\n\n↳ Helper sent: Rerun today's video\n↳ Helper sent: Updates wait for routines"))
check("no missing-line warning", m.MISSING_SHOWN not in out)
check("and it clears the earlier miss for that chat", "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])
for f in handed():
    f.unlink()
with_choice = "On it.\n[helper: Hotels | Find a hotel in Quebec.]\n\n[choices: Cheap | Nice]"
out = m.transform_llm_output(response_text=with_choice, session_id="tg-1", platform="whatsapp", turn_id="t-c")
check(f"a receipt goes above a last choices line ({out!r})", out == "On it.\n\n↳ Helper sent: Hotels\n\n[choices: Cheap | Nice]")
for f in handed():
    f.unlink()

print("9. what isn't a promise is left alone")
for text in ["Should I start a helper to look into it?", "If you say yes, I'm sending a helper to book it.",
             "The helper I sent yesterday is still working on it.", "Here's what changed:\n- the buttons\n- the voice",
             "Rerun today's video is still running (waiting on a slow command).", "I've started thinking about it. More soon."]:
    out = m.transform_llm_output(response_text=text, session_id="tg-1", platform="telegram", turn_id="t-n")
    check(f"{text[:50]!r}: untouched, no note", out is None
          and "started NOTHING" not in m.pre_llm_call(platform="telegram")["context"])
fake = "Starting it now.\n↳ Helper sent: Hotels"
out = m.transform_llm_output(response_text=fake, session_id="tg-1", platform="telegram", turn_id="t-f")
check("a receipt the assistant wrote itself, with no line, is taken off and the person told",
      out is not None and "↳" not in out and m.MISSING_SHOWN in out and handed() == [])
check("the rule tells the assistant saved replies are cut and only the line starts a job",
      "only when THIS reply holds its own" in m.pre_llm_call(platform="telegram")["context"])
check("One's own chat is never warned", m.transform_llm_output(response_text=fake, session_id="x", platform="acp", turn_id="t") is None)

print("phone-tags ok" if fails == 0 else f"phone-tags: {fails} failed")
sys.exit(1 if fails else 0)
