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
import os
import re
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ratchet  # noqa: E402  (same folder; sys.path is set above)
import repo_rules  # noqa: E402

ROOT = repo_rules.ROOT
BASELINE = os.path.join(ROOT, "tools", "lint", "baseline.json")
CANARIES = os.path.join(ROOT, "tools", "lint", "canaries")
MAX_LINES = 600

# Which files a rule looks at, from the layer that owns the file list (repo_rules): a rule in either
# file picks from the same four names instead of retyping the predicate. Everything skips old/, the
# vendored engine copies under tests/fixtures/ and the canaries (see repo_rules.SKIP_DIRS).
SWIFT, SHELL, CODE, ANY = repo_rules.SWIFT, repo_rules.SHELL, repo_rules.CODE, repo_rules.ANY


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

# file-length answers "is it over the cap at all", one finding per file — and four files are
# grandfathered at exactly that, so one of them could have grown from 601 lines to 10,000 with the
# ratchet still green. This is the other half: one finding per 100 lines over the cap, so the count
# tracks the size. Its own id, because changing how file-length counts would have churned a baseline
# that may only shrink; together they mean a file already over the cap can only get shorter.
def r_file_bloat(path, lines):
    over = len(lines) - MAX_LINES
    for step in range(100, over + 1, 100):
        yield 1, f"{len(lines)} lines, {step} over the {MAX_LINES}-line cap and still counting"

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

# Both spellings of the receiver: `args.contains(…)` matched 28 hooks and
# `CommandLine.arguments.contains(…)` — the majority, 45 of them — was invisible, which is how
# --test-panels, --test-shelf-search and --test-window-guard reached a real window with no gate.
TEST_HOOK = re.compile(r'(?:CommandLine\.arguments|args)\.(?:contains|firstIndex)\((?:of: )?"(--test-[\w-]+)"\)')


def r_test_hook_selftest(path, lines):
    for i, l in enumerate(lines, 1):
        m = TEST_HOOK.search(l)
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
#
# A file with no row FAILS CLOSED, under this rule's own id. It used to return quietly, on the
# grounds that architecture-table reports the missing row — but those rows are grandfathered, so 44
# Swift files sat outside this rule while the output said "0 new problems". Its sibling
# destructive-fs-area already failed closed on the same condition; two rules reading one table now
# answer it the same way, and paying down a row re-arms both.
REVERSE_UI = re.compile(r':\s*View\b')
def r_dependency_direction(path, lines):
    t = repo_rules.tags(path)
    if t is None:
        yield 1, "no row in the docs/ARCHITECTURE.md table, so this rule can't tell which layer it is"
        return
    if not (t & repo_rules.LOWER_LAYERS):
        return   # not a lower layer, so it may call anything
    may_have_views = bool(t & repo_rules.MAY_HAVE_VIEWS)
    for i, l in enumerate(lines, 1):
        code = l.split("//", 1)[0]
        if "Model.shared" in code:
            yield i, "reaches back up to Model.shared from a %s file" % "/".join(sorted(t))
        elif not may_have_views and REVERSE_UI.search(code):
            yield i, "declares a SwiftUI View in a %s file" % "/".join(sorted(t))

RULES = {
    "file-length":   (r_file_length,   "Big files are hard to read and to edit safely.",
                      "Move whole declarations into a new file for that area (see docs/ARCHITECTURE.md).", CODE),
    "file-bloat":    (r_file_bloat,    "A file already over the cap must get shorter, never longer.",
                      "Split it by area (see docs/ARCHITECTURE.md). Its count here is how far over the cap it is, "
                      "so the baseline only lets it shrink.", CODE),
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


def body(path):
    """A file's lines, or [] when there is nothing to read.

    [] and not None, because two rules judge a file by its NAME: secret-file used to be skipped for
    every binary file, which is every format in the list it names (.p12, .jks, .kdbx) and an empty
    .env too — the public-repo backstop was blind exactly where it was the backstop.
    """
    text = repo_rules.read(path)
    return text.split("\n") if text else []


def scan():
    found = []
    files = [p for p in repo_rules.tracked() if repo_rules.ours(p)]
    cache = {}
    for path in files:
        for rid, (fn, _, _, picks) in RULES.items():
            if not picks(path):
                continue
            if path not in cache:
                cache[path] = body(path)
            for line, msg in fn(path, cache[path]):
                found.append((rid, path, line, msg))
    return found


def coverage():
    """How many files each rule actually judges, so narrowing a rule's scope shows up as a number.

    The two rules that take their scope from docs/ARCHITECTURE.md can be switched off for a file by
    editing one word in a doc, and the ratchet reads that as debt paid down. Printing the scope means
    a shrinking denominator is visible in the diff of any run.
    """
    files = [p for p in repo_rules.tracked() if repo_rules.ours(p)]
    return {rid: sum(1 for p in files if picks(p)) for rid, (_, _, _, picks) in RULES.items()}


ALLOW_MARK = "\n--allow--\n"


def prove(verbose=False):
    """Every rule still fires on its canary, so a refactor can't quietly neuter one.

    A canary is tools/lint/canaries/<rule id>.canary: a header of `pretend: <path>` (the path the
    rule should judge it as) and an optional `repeat: <n>`, then `--`, then the snippet that breaks
    the rule. Nothing compiles it; the rule only ever sees its lines.

    After the snippet, an optional `--allow--` separator and lines the rule must NOT report. Without
    that half a rule can be narrowed to its canary and nothing notices: cutting JARGON down to just
    "API key", or SECRETS down to one alternative, left --prove at 20/20 while real mistakes shipped.

    `branches: <n>` is the other half of that: the rule must report at least n findings on the
    snippet, one per shape of the mistake it claims to catch. A rule with five alternatives and one
    canary line is proved by its own narrowest case; with `branches: 5` it has to still catch all of
    them. Keep the snippet's lines in the same order as the rule's alternatives so a failure reads.

    And the rule's own selector is asserted, not just its matcher. --prove used to call the rule
    function directly, so a rule wired to zero files still reported "proved to block": narrowing
    no-secrets back to Sources/*.swift (the very regression this change exists to undo) stayed green.
    """
    bad = []
    for rid, (fn, _, fix, picks) in RULES.items():
        canary = os.path.join(CANARIES, rid + ".canary")
        if not os.path.exists(canary):
            bad.append(f"✗ {rid}: no canary. FIX: add tools/lint/canaries/{rid}.canary breaking this rule.")
            continue
        head, sep, rest = open(canary, encoding="utf-8").read().partition("\n--\n")
        if not sep:
            bad.append(f"✗ {rid}: malformed canary. FIX: tools/lint/canaries/{rid}.canary needs a "
                       f"`pretend: <path>` header, then a line with just `--`, then the snippet.")
            continue
        meta = dict(re.findall(r'^(\w+):\s*(.+)$', head, re.M))
        path = meta.get("pretend", "Sources/Canary.swift")
        breaks, _, allowed = rest.partition(ALLOW_MARK)
        try:
            times = int(meta.get("repeat", 1))
        except ValueError:
            bad.append(f"✗ {rid}: its canary's `repeat:` is not a number. FIX: `repeat: <n>`, or drop the line.")
            continue
        if not picks(path):
            bad.append(f"✗ {rid}: its canary pretends to be {path}, but the rule's selector never looks at "
                       f"that path, so the rule judges nothing. FIX: widen the rule's files in RULES, or "
                       f"point `pretend:` at a path it does judge.")
            continue
        if not repo_rules.ours(path):
            bad.append(f"✗ {rid}: its canary pretends to be {path}, which repo_rules.SKIP_DIRS excludes from "
                       f"every rule. FIX: point `pretend:` at a path the lint actually reads.")
            continue
        hits = list(fn(path, breaks.rstrip("\n").split("\n") * times))
        if not hits:
            bad.append(f"✗ {rid}: its canary passed. FIX: the rule stopped matching — fix the rule, or "
                       f"update tools/lint/canaries/{rid}.canary to today's shape of the mistake.")
            continue
        # Exactly, not at least. With `>=` a canary carrying six shapes could report nine findings
        # (three of its lines held two jargon words each) and three alternatives could then be
        # deleted with the count still over the line — three findings of slack, invisible.
        want = int(meta.get("branches", 1))
        if len(hits) != want:
            how = "no longer catches all of them" if len(hits) < want else "reports more than that"
            bad.append(f"✗ {rid}: its canary says `branches: {want}` but the rule reported {len(hits)}, "
                       f"so it {how}. FIX: if the rule was narrowed, widen it back. If the count was "
                       f"always wrong, set `branches: {len(hits)}` in tools/lint/canaries/{rid}.canary — "
                       f"it has to be exact, or the slack hides an alternative going dead.")
            continue
        wrong = list(fn(path, allowed.rstrip("\n").split("\n"))) if allowed.strip() else []
        if wrong:
            bad.append(f"✗ {rid}: it reported line {wrong[0][0]} of its own `--allow--` block "
                       f"({wrong[0][1]}). FIX: the rule now fires on code it is supposed to let through — "
                       f"narrow the rule, or move that line out of the allow block if it really is a mistake.")
            continue
        if verbose:
            print(f"✓ {rid} blocks: {path}:{hits[0][0]}  {hits[0][1]}"
                  f"{'  (and lets its allow block through)' if allowed.strip() else ''}")
            print(f"    FIX: {fix}")
    for b in bad:
        print(b)
    # Every canary file must belong to a rule, so deleting a rule from RULES can't go unnoticed.
    orphans = sorted(f[:-7] for f in os.listdir(CANARIES) if f.endswith(".canary") and f[:-7] not in RULES)
    for o in orphans:
        print(f"✗ {o}: a canary for a rule that no longer exists. FIX: put the rule back in RULES, or "
              f"delete tools/lint/canaries/{o}.canary with the reason in the commit message.")
    print(f"one-lint --prove: {len(RULES) - len(bad)}/{len(RULES)} rules proved to block"
          f"{f', {len(orphans)} canary without a rule' if orphans else ''}")
    return 1 if bad or orphans else 0


RATCHET = ratchet.Ratchet(BASELINE, "one-lint")

# The two rules that read docs/ARCHITECTURE.md: their scope is printed on every run, because a
# one-word edit to that doc can take a file out of them and the ratchet reads that as debt paid.
FROM_DOCS = ("dependency-direction", "destructive-fs-area")


def main():
    args = sys.argv[1:]
    if "--list" in args:
        for rid, (_, why, fix, _) in RULES.items(): print(f"{rid}: {why}\n    FIX: {fix}")
        return 0
    if "--prove" in args:
        return prove("--verbose" in args or "-v" in args)
    found = scan()
    counts = Counter(f"{r}|{p}" for r, p, _, _ in found)
    if "--init" in args:
        return RATCHET.seed(counts)
    if "--update" in args:
        return RATCHET.shrink(counts)
    bad, paid, stale = RATCHET.gate(counts)
    base = ratchet.findings(RATCHET.load())
    for k in bad:
        rid, path = k.split("|", 1)
        _, why, fix, _ = RULES[rid]
        print(f"✗ {rid} in {path}: {counts[k]} (allowed {base.get(k, 0)}). {why}")
        for r, p, line, msg in found:
            if r == rid and p == path: print(f"    {path}:{line}  {msg}")
        print(f"    FIX: {fix}")
    rotten = RATCHET.report(counts, paid, stale)
    seen = coverage()
    print("scope: " + ", ".join(f"{rid} judges {seen[rid]} files" for rid in FROM_DOCS if rid in seen)
          + " (from the table in docs/ARCHITECTURE.md)")
    # Every rule's file count, not just those two: a selector narrowed from "every tracked file" to
    # "*.py" keeps its canary's path selected and so passes --prove, and the only visible trace is
    # the number here falling. A rule that selects nothing is a rule that is switched off.
    print("       " + ", ".join(f"{rid}:{seen[rid]}" for rid in sorted(seen)))
    empty = sorted(rid for rid, n in seen.items() if n == 0)
    for rid in empty:
        print(f"✗ {rid} judges 0 files, so it cannot report anything. FIX: widen the rule's files in "
              f"RULES (tools/lint/one-lint.py), or delete the rule and its canary.")
    print(f"one-lint: {len(RULES)} rules, {sum(counts.values())} findings, {sum(base.values())} grandfathered, {len(bad)} new problems")
    return 1 if bad or rotten or empty else 0

if __name__ == "__main__":
    sys.exit(main())
