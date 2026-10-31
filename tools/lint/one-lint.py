#!/usr/bin/env python3
"""One's own lint rules ("cops"): the project rules a generic Swift linter can't know.

  tools/lint/one-lint.py            check; exits 1 on any NEW or worsened violation
  tools/lint/one-lint.py --update   shrink the baseline after paying debt down (never grows it)
  tools/lint/one-lint.py --init     seed the baseline from the code as it stands (review the diff)
  tools/lint/one-lint.py --list     print every rule and its fix

Old debt lives in tools/lint/baseline.json as {"rule|file": count}. It is a ceiling, not a floor:
a file with no entry must be clean, and a count may only go down. CI also checks the baseline
never grew compared with main (tools/lint/check-baseline.sh), because the easy way to beat a
ratchet is to edit the ratchet.

Adding a rule: write a function below, add it to RULES with an id, a one-line why and a FIX
an agent can follow. A repeated mistake in review means a new rule here.
"""
import json, os, re, sys
from collections import Counter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BASELINE = os.path.join(ROOT, "tools", "lint", "baseline.json")
MAX_LINES = 600

def swift_files():
    src = os.path.join(ROOT, "Sources")
    for d, _, fs in os.walk(src):
        for f in sorted(fs):
            if f.endswith(".swift"):
                yield os.path.relpath(os.path.join(d, f), ROOT)

def strings(line):
    """User-facing string literals on a line (skips comments)."""
    code = line.split("//", 1)[0] if '"' not in line.split("//", 1)[0][-1:] else line
    return re.findall(r'"((?:[^"\\]|\\.)*)"', code)

UI_CALL = re.compile(r'\b(Text|Label|Button|note\s*=|say\(|sayNow\(|Bubble\(|help\(|caption|placeholder|TextField)\b')
RENDER_ONLY = re.compile(r'--render|--test|selftest|Persona\.write\(assistant: "|Chip\(label|\["Juno", "Max"')
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
PROCESS_OK = re.compile(r'(Installer|Engine|Bridge|Speaker|Voice|GoogleSignIn|SignIn|Updater|Access|hermesRun|Brain|Shared|JobsCheck|GatewayCheck|RestartCheck|Messenger|BrowserKeeper|Learning|ScreenGrab|BlockedAskCheck|LocalModels)')  # ScreenGrab: the ask box's + › Screenshot runs Apple's screencapture -i; BlockedAskCheck: a stand-in browser list (python3 http.server) in preflight; LocalModels: probes/starts the person's own local model server on loopback only
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

def r_secret_in_source(path, lines):
    for i, l in enumerate(lines, 1):
        if re.search(r'sk-ant-[A-Za-z0-9]|ghp_[A-Za-z0-9]{20}|AIza[0-9A-Za-z_-]{30}|"client_secret"\s*:', l):
            yield i, "secret in source"

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
# A foundation or service file reaching back up to Model.shared (or declaring a SwiftUI View) turns
# that one-way graph into a cycle. Swift has no per-file `import` to parse, so this pattern-matches the
# two concrete, reliable signals named in ARCHITECTURE.md rather than trying to model the whole type
# graph (a stated skip on anything indirect, e.g. a closure/protocol carrying the reverse dependency).
FOUNDATION_FILES = {"Sources/Env.swift", "Sources/TestWorld.swift"}
SERVICE_FILES = {
    "Sources/Installer.swift", "Sources/Engine.swift", "Sources/Voice.swift", "Sources/HelperSound.swift",
    "Sources/Updater.swift", "Sources/VersionNote.swift", "Sources/Brain.swift", "Sources/Helpers.swift",
    "Sources/HelperTrail.swift", "Sources/Pictures.swift", "Sources/Routines.swift", "Sources/RoutineRuns.swift",
    "Sources/QuitHold.swift", "Sources/SharedRooms.swift", "Sources/BundledSkills.swift", "Sources/Learning.swift",
    "Sources/Guards.swift", "Sources/BrowserKeeper.swift", "Sources/HumanCheck.swift", "Sources/MyChrome.swift",
    "Sources/ChromeCheck.swift", "Sources/ChromeBridge.swift", "Sources/BrowserGuard.swift",
    "Sources/GatewayGuard.swift", "Sources/FolderWatch.swift",
}
REVERSE_DEP = re.compile(r'\bModel\.shared\b|:\s*View\b')
def r_dependency_direction(path, lines):
    if path not in FOUNDATION_FILES and path not in SERVICE_FILES: return
    for i, l in enumerate(lines, 1):
        code = l.split("//", 1)[0]
        if REVERSE_DEP.search(code):
            yield i, "reaches back up to Model.shared / declares a View from a foundation-or-service file (docs/ARCHITECTURE.md rule 6)"

RULES = {
    "file-length":   (r_file_length,   "Big files are hard to read and to edit safely.",
                      "Move whole declarations into a new file in Sources/ for that area (see docs/ARCHITECTURE.md)."),
    "assistant-name":(r_hardcoded_name,"People name their assistant; a fixed name in the UI is a bug.",
                      "Use m.name (views) or Shelf.who / Model.assistantName (elsewhere)."),
    "ui-jargon":     (r_jargon,        "One is for people who have never opened a terminal.",
                      "Say it in plain words (e.g. 'sign in', 'settings', 'your files'). See docs/PRODUCT_SENSE.md."),
    "broad-kill":    (r_broad_kill,    "pkill/killall can kill other apps or the host agent.",
                      "Kill only PIDs One started (keep the Process handle, or match Application Support/One)."),
    "no-messaging":  (r_messaging,     "Telegram code belongs only in Messenger.swift; no WhatsApp.",
                      "Remove it. Phone = native companion app (docs/PRODUCT_SENSE.md)."),
    "process-area":  (r_process_outside,"Running programs is risky; keep it in a few known places.",
                      "Move the call into Installer/Engine/Bridge/Speaker (or add the owner to PROCESS_OK with a reason)."),
    "test-selftest": (r_test_hook_selftest,"The person's files and settings are production; a test never touches them.",
                      "Make TestWorld.enter() the first line of the hook (never set Env.selfTest yourself); run it from tools/test-copy.sh."),
    "test-copy":     (r_test_copy,     "A copy of One with the real bundle id shares the person's settings (Oct 27: it moved their files).",
                      "Use APP=$(tools/test-copy.sh <name> <folder>): its own bundle id and settings."),
    "no-mail-send":  (r_mail_send,     "The assistant drafts email; the person always presses Send.",
                      "Open a visible draft instead (Bridge --mail draft)."),
    "no-secrets":    (r_secret_in_source,"The repo is public.",
                      "Load it at build time from outside the repo, or from the user's Keychain at run time."),
    "human-window":  (r_live_view_show,"After their yes a person gets a real Chrome window with an address bar, not the live view.",
                      "Call Model.shared.showHumanStep(a); it opens the real window and falls back to the live view itself."),
    "popup-glass":   (r_popup_glass,   "Every pop-up wears the same glass and closes with its X, a click outside and Esc.",
                      "Use PopupStage(close:) { size in … } or .onePopup(shown, close:) { size in … } (Sources/PopupGlass.swift); no .sheet/.popover/.alert or own dim."),
    "dependency-direction": (r_dependency_direction, "Dependencies point one way: UI -> Model -> services -> Env/foundation (docs/ARCHITECTURE.md rule 6).",
                      "Return a value or take a closure/delegate instead of calling Model.shared from a foundation/service file; move a View out of a service file into Sources UI."),
}

SHELL_RULES = {"test-copy"}

def scan():
    found = []
    shell = sorted(os.path.relpath(os.path.join(ROOT, "tools", f), ROOT) for f in os.listdir(os.path.join(ROOT, "tools"))
                   if f.endswith(".sh") and f != "test-copy.sh")
    for path in list(swift_files()) + shell:
        lines = open(os.path.join(ROOT, path), encoding="utf-8").read().split("\n")
        for rid, (fn, _, _) in RULES.items():
            if (rid in SHELL_RULES) != path.endswith(".sh"):
                continue
            for line, msg in fn(path, lines):
                found.append((rid, path, line, msg))
    return found

def load_baseline():
    return json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}

def save_baseline(b):
    json.dump(dict(sorted(b.items())), open(BASELINE, "w"), indent=1)
    open(BASELINE, "a").write("\n")

def main():
    args = sys.argv[1:]
    if "--list" in args:
        for rid, (_, why, fix) in RULES.items(): print(f"{rid}: {why}\n    FIX: {fix}")
        return 0
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
        _, why, fix = RULES[rid]
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
