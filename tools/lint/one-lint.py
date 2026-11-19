#!/usr/bin/env python3
"""One's own lint rules ("cops"): the project rules a generic Swift linter can't know.

  tools/lint/one-lint.py            check; exits 1 on any NEW or worsened violation
  tools/lint/one-lint.py --prove    every rule still fires on its canary (tools/lint/canaries/)
  tools/lint/one-lint.py --update   shrink the baseline after paying debt down (never grows it)
  tools/lint/one-lint.py --init     seed the baseline from the code as it stands (review the diff)
  tools/lint/one-lint.py --list     print every rule, where it looks, and its fix

Old debt lives in tools/lint/baseline.json as {"rule|file": count}. It is a ceiling, not a floor:
a file with no entry must be clean, and a count may only go down. CI also checks the baseline
never grew compared with main (tools/lint/check-baseline.sh), because the easy way to beat a
ratchet is to edit the ratchet.

Adding a rule: write a function below (or in repo_rules.py for one that reads the whole tree), add
it to RULES with an id, a one-line why, a FIX an agent can follow and the files it looks at, then a
canary in tools/lint/canaries/<id>.canary so `--prove` can show it still blocks. A repeated mistake
in review means a new rule here.
"""
import json
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repo_rules  # noqa: E402  (same folder; sys.path is set above)

ROOT = repo_rules.ROOT
BASELINE = os.path.join(ROOT, "tools", "lint", "baseline.json")
CANARIES = os.path.join(ROOT, "tools", "lint", "canaries")
MAX_LINES = 600

# Which files a rule looks at. Everything skips old/, the vendored engine copies under
# tests/fixtures/ and the canaries (see repo_rules.SKIP_DIRS).
SWIFT = lambda p: p.startswith("Sources/") and p.endswith(".swift")  # noqa: E731
SHELL = lambda p: p.endswith(".sh") and os.path.basename(p) != "test-copy.sh"  # noqa: E731
# One's own source, whatever the language: the 600-line cap used to hold Swift alone while 4,500
# lines of Python and 37 shell scripts grew unchecked.
CODE = lambda p: p.endswith((".swift", ".py", ".sh", ".yml", ".yaml", ".html", ".m", ".h"))  # noqa: E731
ANY = lambda p: True  # noqa: E731


def strings(line):
    """User-facing string literals on a line (skips comments)."""
    code = line.split("//", 1)[0] if '"' not in line.split("//", 1)[0][-1:] else line
    return re.findall(r'"((?:[^"\\]|\\.)*)"', code)


UI_CALL = re.compile(r'\b(Text|Label|Button|note\s*=|say\(|sayNow\(|Bubble\(|help\(|caption|placeholder|TextField)\b')
RENDER_ONLY = re.compile(r'--render|--test|selftest|Persona\.write\(assistant: "|Chip\(label|\["Juno", "Max"\]')
JARGON = ["API key", "OAuth", "token", "sandbox", "CLI", "terminal", "JSON", "config", "ACP", "endpoint", "repo", "webhook", "cron"]


def r_file_length(path, lines):
    if len(lines) > MAX_LINES:
        yield 1, f"{len(lines)} lines (max {MAX_LINES})"

def r_hardcoded_name(path, lines):
    if path.endswith("Previews.swift"): return   # render-only scenes, never shown to a user
    for i, l in enumerate(lines, 1):
        if RENDER_ONLY.search(l) or not UI_CALL.search(l): continue
        for s in strings(l):
            if re.search(r'\b(Nova|Juno|Elias)\b', s):
                yield i, f'assistant name in UI text: "{s[:50]}"'

def r_jargon(path, lines):
    for i, l in enumerate(lines, 1):
        if not UI_CALL.search(l) or RENDER_ONLY.search(l): continue
        for s in strings(l):
            for w in JARGON:
                if re.search(r'(?<![\w/.-])' + re.escape(w) + r'(?![\w/.-])', s):
                    yield i, f'jargon "{w}" in UI text: "{s[:50]}"'

def r_broad_kill(path, lines):
    for i, l in enumerate(lines, 1):
        if re.search(r'\b(pkill|killall)\b', l) and not re.search(r'pkill -f "\\\(Env\.(engineDir|support)', l):
            yield i, "broad process kill"

# Messenger.swift: Omar's phone chat runs through One's own Telegram bot (decided 2026-10-27).
# Telegram lives only there; WhatsApp and Telegram stay out of everything else.
def r_messaging(path, lines):
    if path.endswith("Messenger.swift"):
        return
    for i, l in enumerate(lines, 1):
        if re.search(r'\b(Telegram|WhatsApp)\b', l, re.I):
            yield i, "Telegram/WhatsApp mentioned"

# JobsCheck: test-only, runs a local fake shop page for `--test-jobs`.
# GatewayCheck: test-only, starts stand-in gateway processes for `--test-gateway`.
# RestartCheck: test-only, starts stand-in gateway processes for `--test-restart`.
# Messenger: keeps the engine's background helper running while a phone bot is set up.
# BrowserKeeper: starts the hidden browser again (same saved profile) when it's down; One is outside the lock.
# Learning: a read-only sqlite3 lookup of which chat a subagent belongs to (state.db).
PROCESS_OK = re.compile(r'(Installer|Engine|Bridge|Speaker|Voice|GoogleSignIn|SignIn|Updater|Access|hermesRun|Brain|Shared|JobsCheck|GatewayCheck|RestartCheck|Messenger|BrowserKeeper|Learning|ScreenGrab|BlockedAskCheck|LocalModels|HelperRepos|Offsite|ImproveNightCheck|HiddenBrowserCheck|Keeper|JobTreeCheck|Usage|HealthCheck|PhoneTunnel|SmoothCheck)')  # SmoothCheck: on CI only, Apple's /usr/bin/sample profiles its own test run (ONE_SMOOTH_SAMPLE); PhoneTunnel: cloudflared quick tunnel to the loopback hand-off page for 10 minutes; HealthCheck: spawns /bin/sleep stand-ins a stopped helper leaves running on CI, the watchdog closes them; Usage: runs the engine's own python on bundled tools/usage_meter.py to read the AI plan's meter (read only);  # JobTreeCheck: spawns /bin/sleep stand-ins for a helper's programs on CI, then stops them;  # Keeper: `open -g` One again after it ended without being asked to, and codesign to check a version it puts back (Keeper.swift); HiddenBrowserCheck: on CI only, starts Chrome directly once to tell a launcher problem from a Chrome one; ImproveNightCheck: runs the nightly routine's own pre-run script (bash) against stand-in copies of One in its test; Offsite: Apple's own /usr/bin/aa locks and opens the nightly copy (no other program); HelperRepos: git worktree add/remove for a helper's own copy of a repo (One itself, outside the lock); ScreenGrab: the ask box's + › Screenshot runs Apple's screencapture -i; BlockedAskCheck: a stand-in browser list (python3 http.server) in preflight; LocalModels: probes/starts the person's own local model server on loopback only
def r_process_outside(path, lines):
    owner = None
    for i, l in enumerate(lines, 1):
        m = re.match(r'^(?:@\w+\s+)*(?:final\s+)?(?:struct|enum|class|extension|func)\s+(\w+)', l)
        if m: owner = m.group(1)
        if re.search(r'\bProcess\(\)', l) and not (owner and PROCESS_OK.search(owner)):
            yield i, f"Process() in {owner or 'top level'}"

def r_test_hook_selftest(path, lines):
    for i, l in enumerate(lines, 1):
        m = re.search(r'args\.(?:contains|firstIndex)\((?:of: )?"(--test-[\w-]+)"\)', l)
        if m and not any("TestWorld.enter()" in x for x in lines[i - 1:i + 6]):
            yield i, f"{m.group(1)} doesn't call TestWorld.enter() first"
        if "selfTest = true" in l.split("//", 1)[0] and not path.endswith("TestWorld.swift"):
            yield i, "sets Env.selfTest by hand"

def r_test_copy(path, lines):
    """Shell side: check scripts run One only from a test copy (tools/test-copy.sh)."""
    for i, l in enumerate(lines, 1):
        if re.search(r'(cp -R|ditto)\s+"?build/(app\.noindex/)?One\.app', l):
            yield i, "copies the built One by hand"

def r_mail_send(path, lines):
    for i, l in enumerate(lines, 1):
        if re.search(r'\bsend\b[^"]*\b(outgoing message|message)\b', l) and "applescript" in l.lower() or re.search(r'to send\b', l) and "Mail" in l:
            yield i, "AppleScript that sends mail"

# The repo is public, so this looks at every tracked text file, not just Sources: before PER-33 it
# read Sources/*.swift only, which left tools/, tests/, the workflows and the published site/ out.
SECRETS = re.compile(
    r'sk-ant-[A-Za-z0-9]{10}|sk-or-v1-[A-Za-z0-9]{10}|ghp_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}'
    r'|AIza[0-9A-Za-z_-]{30}|xox[baprs]-[A-Za-z0-9-]{10}|"client_secret"\s*:\s*"[^"]{8,}"'
    r'|-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}'
)
def r_secret_in_source(path, lines):
    for i, l in enumerate(lines, 1):
        if SECRETS.search(l):
            yield i, "secret in a tracked file"

# Every pop-up shares one look and closes three ways (Claude Design "Popup Glass", A · Smoked glass, Oct 28).
# Mac sheets, popovers and alerts have no X and no click-outside; a hand-made dim drifts from the shared look.
POPUP_CALL = re.compile(r'\.(sheet|popover|alert|confirmationDialog|fullScreenCover)\s*\(|\bNSAlert\s*\(')
def r_popup_glass(path, lines):
    if path.endswith(("PopupGlass.swift", "Previews.swift")): return   # the shared style itself; render-only scenes
    for i, l in enumerate(lines, 1):
        code = l.split("//", 1)[0]
        m = POPUP_CALL.search(code)
        if m:
            yield i, f"{m.group(0).strip('( ')} instead of the shared pop-up"
        if re.search(r'Color\.black\.opacity\(', code) and any("onTapGesture" in x for x in lines[i - 1:i + 2]):
            yield i, "hand-made dim backdrop"

# Oct 28, 0.9.51-0.9.53: the card's "Yes, show it" called the live view's show() directly, so the real Chrome
# window (HumanCheck) never opened and Omar got a window with no address bar he couldn't click in.
def r_live_view_show(path, lines):
    if path.endswith("HumanStepCheck.swift"): return   # the live view's own check
    inside = False
    for i, l in enumerate(lines, 1):
        code = l.split("//", 1)[0]
        if re.search(r'func showHumanStep\(', code): inside = True
        elif re.search(r'^\s*(func|var|static func|struct|enum|final class|class)\b', code) and inside and "showHumanStep" not in code: inside = False
        if re.search(r'HumanStep\.windows\[[^\]]*\]\??\.show\(\)', code) and not inside:
            yield i, "shows the live view directly"

# docs/ARCHITECTURE.md rule 6: dependencies point one way, UI -> Model -> services -> Env/foundation.
# A foundation or service file reaching back up to Model.shared (or declaring a SwiftUI View) turns that
# one-way graph into a cycle. Swift has no per-file `import` to parse, so this pattern-matches the two
# concrete, reliable signals named in ARCHITECTURE.md rather than trying to model the whole type graph
# (a stated skip on anything indirect, e.g. a closure or protocol carrying the reverse dependency).
#
# Which files count as foundation or service is read from that table, not from a list typed here: the
# hand-typed list had 32 names in it and had already missed HumanStep.swift, so a new service file
# escaped this rule until somebody remembered to edit the lint. A file the table also tags UI (say
# `service + UI`) may declare a View; it still may not call Model.shared.
REVERSE_UI = re.compile(r':\s*View\b')
def r_dependency_direction(path, lines):
    t = repo_rules.tags(path)
    if t is None or not (t & {"foundation", "service"}):
        return   # not a lower layer, or no row yet (architecture-table reports that)
    may_have_views = bool(t & {"ui", "view", "state", "chat", "entry", "model", "bridge"})
    for i, l in enumerate(lines, 1):
        code = l.split("//", 1)[0]
        if "Model.shared" in code:
            yield i, "reaches back up to Model.shared from a %s file" % "/".join(sorted(t))
        elif not may_have_views and REVERSE_UI.search(code):
            yield i, "declares a SwiftUI View in a %s file" % "/".join(sorted(t))

RULES = {
    "file-length":   (r_file_length,   "Big files are hard to read and to edit safely.",
                      "Move whole declarations into a new file for that area (see docs/ARCHITECTURE.md).", CODE),
    "assistant-name":(r_hardcoded_name,"People name their assistant; a fixed name in the UI is a bug.",
                      "Use m.name (views) or Shelf.who / Model.assistantName (elsewhere).", SWIFT),
    "ui-jargon":     (r_jargon,        "One is for people who have never opened a terminal.",
                      "Say it in plain words (e.g. 'sign in', 'settings', 'your files'). See docs/PRODUCT_SENSE.md.", SWIFT),
    "broad-kill":    (r_broad_kill,    "pkill/killall can kill other apps or the host agent.",
                      "Kill only PIDs One started (keep the Process handle, or match Application Support/One).", SWIFT),
    "no-messaging":  (r_messaging,     "Telegram code belongs only in Messenger.swift; no WhatsApp.",
                      "Remove it. Phone = native companion app (docs/PRODUCT_SENSE.md).", SWIFT),
    "process-area":  (r_process_outside,"Running programs is risky; keep it in a few known places.",
                      "Move the call into Installer/Engine/Bridge/Speaker (or add the owner to PROCESS_OK with a reason).", SWIFT),
    "test-selftest": (r_test_hook_selftest,"The person's files and settings are production; a test never touches them.",
                      "Make TestWorld.enter() the first line of the hook (never set Env.selfTest yourself); run it from tools/test-copy.sh.", SWIFT),
    "test-copy":     (r_test_copy,     "A copy of One with the real bundle id shares the person's settings (Oct 27: it moved their files).",
                      "Use APP=$(tools/test-copy.sh <name> <folder>): its own bundle id and settings.", SHELL),
    "no-mail-send":  (r_mail_send,     "The assistant drafts email; the person always presses Send.",
                      "Open a visible draft instead (Bridge --mail draft).", SWIFT),
    "no-secrets":    (r_secret_in_source,"The repo is public, and that includes tools/, tests/, the workflows and site/.",
                      "Load it at build time from outside the repo, or from the user's Keychain at run time.", ANY),
    "human-window":  (r_live_view_show,"After their yes a person gets a real Chrome window with an address bar, not the live view.",
                      "Call Model.shared.showHumanStep(a); it opens the real window and falls back to the live view itself.", SWIFT),
    "popup-glass":   (r_popup_glass,   "Every pop-up wears the same glass and closes with its X, a click outside and Esc.",
                      "Use PopupStage(close:) { size in … } or .onePopup(shown, close:) { size in … } (Sources/PopupGlass.swift); no .sheet/.popover/.alert or own dim.", SWIFT),
    "dependency-direction": (r_dependency_direction, "Dependencies point one way: UI -> Model -> services -> Env/foundation (docs/ARCHITECTURE.md rule 6).",
                      "Return a value or take a closure/delegate instead of calling Model.shared from a foundation/service file; move a View out of a service file into Sources UI.", SWIFT),
}
RULES.update(repo_rules.RULES)


def scan():
    found = []
    files = [p for p in repo_rules.tracked() if repo_rules.ours(p)]
    cache = {}
    for path in files:
        for rid, (fn, _, _, picks) in RULES.items():
            if not picks(path):
                continue
            if path not in cache:
                text = repo_rules.read(path)
                cache[path] = text.split("\n") if text else None
            lines = cache[path]
            if lines is None:   # unreadable or binary: nothing to look at
                continue
            for line, msg in fn(path, lines):
                found.append((rid, path, line, msg))
    return found


def prove():
    """Every rule still fires on its canary, so a refactor can't quietly neuter one.

    A canary is tools/lint/canaries/<rule id>.canary: a header of `pretend: <path>` (the path the
    rule should judge it as) and an optional `repeat: <n>`, then `--`, then the snippet that breaks
    the rule. Nothing compiles it; the rule only ever sees its lines.
    """
    bad = []
    for rid, (fn, _, fix, _) in RULES.items():
        canary = os.path.join(CANARIES, rid + ".canary")
        if not os.path.exists(canary):
            bad.append(f"✗ {rid}: no canary. FIX: add tools/lint/canaries/{rid}.canary breaking this rule.")
            continue
        head, _, body = open(canary, encoding="utf-8").read().partition("\n--\n")
        meta = dict(re.findall(r'^(\w+):\s*(.+)$', head, re.M))
        path = meta.get("pretend", "Sources/Canary.swift")
        lines = body.rstrip("\n").split("\n") * int(meta.get("repeat", 1))
        hits = list(fn(path, lines))
        if hits:
            print(f"✓ {rid} blocks: {path}:{hits[0][0]}  {hits[0][1]}")
            print(f"    FIX: {fix}")
        else:
            bad.append(f"✗ {rid}: its canary passed. FIX: the rule stopped matching — fix the rule, or "
                       f"update tools/lint/canaries/{rid}.canary to today's shape of the mistake.")
    for b in bad:
        print(b)
    print(f"one-lint --prove: {len(RULES) - len(bad)}/{len(RULES)} rules proved to block")
    return 1 if bad else 0


def load_baseline():
    return json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}

def save_baseline(b):
    json.dump(dict(sorted(b.items())), open(BASELINE, "w"), indent=1)
    open(BASELINE, "a").write("\n")

def main():
    args = sys.argv[1:]
    if "--list" in args:
        for rid, (_, why, fix, _) in RULES.items(): print(f"{rid}: {why}\n    FIX: {fix}")
        return 0
    if "--prove" in args:
        return prove()
    found = scan()
    counts = Counter(f"{r}|{p}" for r, p, _, _ in found)
    if "--init" in args:
        save_baseline(dict(counts)); print(f"Seeded baseline: {sum(counts.values())} grandfathered in {len(counts)} entries"); return 0
    base = load_baseline()
    if "--update" in args:
        new = {k: min(v, counts.get(k, 0)) for k, v in base.items() if counts.get(k, 0) > 0}
        save_baseline(new); print(f"Baseline: {sum(base.values())} -> {sum(new.values())}"); return 0
    bad = [k for k, n in counts.items() if n > base.get(k, 0)]
    for k in bad:
        rid, path = k.split("|", 1)
        _, why, fix, _ = RULES[rid]
        print(f"✗ {rid} in {path}: {counts[k]} (allowed {base.get(k, 0)}). {why}")
        for r, p, line, msg in found:
            if r == rid and p == path: print(f"    {path}:{line}  {msg}")
        print(f"    FIX: {fix}")
    paid = sum(base.values()) - sum(min(v, counts.get(k, 0)) for k, v in base.items())
    if paid: print(f"Debt paid down: {paid}. Run tools/lint/one-lint.py --update to lock it in.")
    print(f"one-lint: {len(RULES)} rules, {sum(counts.values())} findings, {sum(base.values())} grandfathered, {len(bad)} new problems")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
