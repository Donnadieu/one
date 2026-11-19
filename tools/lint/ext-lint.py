#!/usr/bin/env python3
"""ruff and shellcheck over One's own Python and shell, on the same ratchet as one-lint.py.

  tools/lint/ext-lint.py            check; exits 1 on any NEW or worsened finding
  tools/lint/ext-lint.py --update   shrink the baseline after paying debt down (never grows it)
  tools/lint/ext-lint.py --init     seed the baseline from the code as it stands
  tools/lint/ext-lint.py --list     print what each linter is told to look for, and the fix

Swift has had swift-format and one-lint.py for a long time. The 4,500 lines of Python in tools/ and
the 37 shell scripts had nothing at all, in a repo where a shell script runs the app against the
owner's own machine. These are the two stock linters for those languages; they bring their own rule
text, so there is nothing here to write a FIX for beyond "do what the tool says".

The baseline is tools/lint/ext-baseline.json, {"tool|file": count}, with exactly the one-lint
contract: a file with no entry must be clean, a count may only go down, and CI also checks the file
never grew compared with the base branch (tools/lint/check-baseline.sh, which takes the baseline
path as its second argument).

Missing tool: in CI that is a failure (rules.yml installs both, so it can only mean the install
broke). On the Mac it is a notice and that half is skipped — a check that can't run says so rather
than reporting a clean tree it never looked at.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repo_rules  # noqa: E402  (same folder; sys.path is set above)

ROOT = repo_rules.ROOT
BASELINE = os.path.join(ROOT, "tools", "lint", "ext-baseline.json")

# Bug-shaped rules only. This repo's Python is deliberately dense (`import json, os, re, sys`,
# one-line ifs) and it has to run on the system python3, so pycodestyle's layout opinions (E401,
# E7xx) and pyupgrade's "use X | None" would mean hundreds of findings about taste, which is how a
# lint on a mature codebase gets switched off on day two. What's left is the half that finds bugs:
#   F     pyflakes: undefined name, unused import, f-string with no placeholder, shadowed except
#   E9    the errors that are not style at all (syntax error, IO error, tab/space mix)
#   B     flake8-bugbear: mutable default argument, bare except, assert on a tuple, loop-variable capture
RUFF_SELECT = "F,E9,B"
RUFF_IGNORE = "B008"                       # a call in a default argument: the engine's own plugin style
RUFF_TARGET = "py39"                       # /usr/bin/python3 on macOS 14-26

# shellcheck: errors and warnings. Info and style are opinions about shell dialect; these two are bugs.
SHELLCHECK_SEVERITY = "warning"

TOOLS = {
    "ruff": "undefined names, unused imports, broken except clauses, mutable default arguments",
    "shellcheck": "unquoted expansions, a `cd` whose failure is ignored, a pipeline whose exit code is lost",
}


def files(ext):
    return [p for p in repo_rules.tracked() if p.endswith(ext) and repo_rules.ours(p)]


SKIPPED = []


def missing(tool, install):
    """A linter that isn't here: fatal in CI (rules.yml installs it), a notice on the Mac."""
    SKIPPED.append(tool)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"✗ {tool} is not installed, and in CI it always is. FIX: check the install step in rules.yml.")
        return True
    print(f"· {tool} is not installed, so its half is skipped here (CI runs it on every pull request).")
    print(f"    FIX, to run it on this Mac too: {install}")
    return False


def ruff_cmd():
    """ruff as a program, or as a module of this python; None when neither is here."""
    if shutil.which("ruff"):
        return [shutil.which("ruff")]
    if subprocess.run([sys.executable, "-m", "ruff", "--version"], capture_output=True).returncode == 0:
        return [sys.executable, "-m", "ruff"]
    return None


# One shape for both linters: the files it reads, how to start it, how to install it, and the
# pattern that turns one line of its output into (file, line, what).
LINTERS = {
    "ruff": (".py", ruff_cmd, "python3 -m pip install ruff",
             ["check", "--no-cache", "--quiet", "--output-format", "concise",
              "--select", RUFF_SELECT, "--ignore", RUFF_IGNORE, "--target-version", RUFF_TARGET],
             re.compile(r'([^:]+):(\d+):\d+:\s*(\S+\s*.*)')),
    "shellcheck": (".sh", lambda: [shutil.which("shellcheck")] if shutil.which("shellcheck") else None,
                   "brew install shellcheck",
                   ["-S", SHELLCHECK_SEVERITY, "-f", "gcc", "-x"],
                   re.compile(r'([^:]+):(\d+):\d+:\s*(?:warning|error):\s*(.*)')),
}


def run(tool):
    """{file: [(line, what)]} from one linter, and True when its absence should fail the run."""
    ext, start, install, flags, pattern = LINTERS[tool]
    paths = files(ext)
    if not paths:
        return {}, False
    cmd = start()
    if cmd is None:
        return {}, missing(tool, install)
    out = subprocess.run(cmd + flags + paths, cwd=ROOT, capture_output=True, text=True)
    found = {}
    for line in out.stdout.split("\n"):
        m = pattern.match(line.strip())
        if m:
            found.setdefault(m.group(1), []).append((int(m.group(2)), m.group(3).strip()))
    return found, False


def scan():
    fatal = False
    out = {}
    for tool in LINTERS:
        found, bad = run(tool)
        fatal = fatal or bad
        for path, hits in found.items():
            out[f"{tool}|{path}"] = hits
    return out, fatal


def load_baseline():
    return json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}


def save_baseline(b):
    json.dump(dict(sorted(b.items())), open(BASELINE, "w"), indent=1)
    open(BASELINE, "a").write("\n")


def main():
    args = sys.argv[1:]
    if "--list" in args:
        for tool, what in TOOLS.items():
            print(f"{tool}: {what}\n    FIX: do what the finding says, or silence that one line the tool's own way "
                  f"({'# noqa: <code>' if tool == 'ruff' else '# shellcheck disable=SC####'}) with a reason next to it.")
        return 0
    found, fatal = scan()
    if fatal:
        return 1
    counts = Counter({k: len(v) for k, v in found.items()})
    if "--init" in args:
        if SKIPPED:
            print(f"✗ won't seed the baseline: {', '.join(SKIPPED)} didn't run, so its debt would be invisible.")
            return 1
        save_baseline(dict(counts))
        print(f"Seeded ext baseline: {sum(counts.values())} grandfathered in {len(counts)} entries")
        return 0
    base = load_baseline()
    if "--update" in args:
        # A skipped linter reports nothing, which looks exactly like debt paid down. Refuse rather
        # than quietly dropping its entries from the baseline: that would un-ratchet the ratchet.
        if SKIPPED:
            print(f"✗ won't shrink the baseline: {', '.join(SKIPPED)} didn't run, so its findings look paid down.")
            print("    FIX: install it first (python3 -m pip install ruff / brew install shellcheck), then --update.")
            return 1
        new = {k: min(v, counts.get(k, 0)) for k, v in base.items() if counts.get(k, 0) > 0}
        save_baseline(new)
        print(f"Ext baseline: {sum(base.values())} -> {sum(new.values())}")
        return 0
    bad = [k for k, n in counts.items() if n > base.get(k, 0)]
    for k in sorted(bad):
        tool, path = k.split("|", 1)
        print(f"✗ {tool} in {path}: {counts[k]} (allowed {base.get(k, 0)}). {TOOLS[tool]}")
        for line, msg in found[k]:
            print(f"    {path}:{line}  {msg}")
        print("    FIX: do what the finding says, or silence that one line the tool's own way with a reason.")
    paid = sum(base.values()) - sum(min(v, counts.get(k, 0)) for k, v in base.items())
    if paid and not SKIPPED:   # with a linter missing, "paid down" would just mean "not looked at"
        print(f"Debt paid down: {paid}. Run tools/lint/ext-lint.py --update to lock it in.")
    skipped = f", {', '.join(SKIPPED)} NOT RUN here" if SKIPPED else ""
    print(f"ext-lint: {len(files('.py'))} python + {len(files('.sh'))} shell files, "
          f"{sum(counts.values())} findings, {sum(base.values())} grandfathered, {len(bad)} new problems{skipped}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
