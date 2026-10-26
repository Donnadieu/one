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

def r_messaging(path, lines):
    for i, l in enumerate(lines, 1):
        if re.search(r'\b(Telegram|WhatsApp)\b', l, re.I):
            yield i, "Telegram/WhatsApp mentioned"

# JobsCheck: test-only, runs a local fake shop page for `--test-jobs`.
# GatewayCheck: test-only, starts stand-in gateway processes for `--test-gateway`.
# RestartCheck: test-only, starts stand-in gateway processes for `--test-restart`.
PROCESS_OK = re.compile(r'(Installer|Engine|Bridge|Speaker|Voice|GoogleSignIn|SignIn|Updater|Access|hermesRun|Brain|Shared|JobsCheck|GatewayCheck|RestartCheck)')
def r_process_outside(path, lines):
    owner = None
    for i, l in enumerate(lines, 1):
        m = re.match(r'^(?:@\w+\s+)*(?:final\s+)?(?:struct|enum|class|extension|func)\s+(\w+)', l)
        if m: owner = m.group(1)
        if re.search(r'\bProcess\(\)', l) and not (owner and PROCESS_OK.search(owner)):
            yield i, f"Process() in {owner or 'top level'}"

def r_test_hook_selftest(path, lines):
    for i, l in enumerate(lines, 1):
        m = re.search(r'args\.contains\("(--test-[\w-]+)"\)', l)
        if m and not any("selfTest = true" in x for x in lines[i - 1:i + 6]):
            yield i, f"{m.group(1)} doesn't set Env.selfTest first"

def r_mail_send(path, lines):
    for i, l in enumerate(lines, 1):
        if re.search(r'\bsend\b[^"]*\b(outgoing message|message)\b', l) and "applescript" in l.lower() or re.search(r'to send\b', l) and "Mail" in l:
            yield i, "AppleScript that sends mail"

def r_secret_in_source(path, lines):
    for i, l in enumerate(lines, 1):
        if re.search(r'sk-ant-[A-Za-z0-9]|ghp_[A-Za-z0-9]{20}|AIza[0-9A-Za-z_-]{30}|"client_secret"\s*:', l):
            yield i, "secret in source"

RULES = {
    "file-length":   (r_file_length,   "Big files are hard to read and to edit safely.",
                      "Move whole declarations into a new file in Sources/ for that area (see docs/ARCHITECTURE.md)."),
    "assistant-name":(r_hardcoded_name,"People name their assistant; a fixed name in the UI is a bug.",
                      "Use m.name (views) or Shelf.who / Model.assistantName (elsewhere)."),
    "ui-jargon":     (r_jargon,        "One is for people who have never opened a terminal.",
                      "Say it in plain words (e.g. 'sign in', 'settings', 'your files'). See docs/PRODUCT_SENSE.md."),
    "broad-kill":    (r_broad_kill,    "pkill/killall can kill other apps or the host agent.",
                      "Kill only PIDs One started (keep the Process handle, or match Application Support/One)."),
    "no-messaging":  (r_messaging,     "One's phone path is its own app, not Telegram or WhatsApp.",
                      "Remove it. Phone = native companion app (docs/PRODUCT_SENSE.md)."),
    "process-area":  (r_process_outside,"Running programs is risky; keep it in a few known places.",
                      "Move the call into Installer/Engine/Bridge/Speaker (or add the owner to PROCESS_OK with a reason)."),
    "test-selftest": (r_test_hook_selftest,"Test hooks must never touch the user's real brain or settings.",
                      "Set Env.selfTest = true as the first line of the hook and export/import UserDefaults around it."),
    "no-mail-send":  (r_mail_send,     "The assistant drafts email; the person always presses Send.",
                      "Open a visible draft instead (Bridge --mail draft)."),
    "no-secrets":    (r_secret_in_source,"The repo is public.",
                      "Load it at build time from outside the repo, or from the user's Keychain at run time."),
}

def scan():
    found = []
    for path in swift_files():
        lines = open(os.path.join(ROOT, path), encoding="utf-8").read().split("\n")
        for rid, (fn, _, _) in RULES.items():
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
