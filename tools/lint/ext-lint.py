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
than reporting a clean tree it never looked at. The same goes for a linter that IS here but exits
with an error: an empty report from a tool that refused to start reads exactly like a clean tree.
"""
import os
import re
import shutil
import subprocess
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ratchet  # noqa: E402  (same folder; sys.path is set above)
import repo_rules  # noqa: E402

ROOT = repo_rules.ROOT
BASELINE = os.path.join(ROOT, "tools", "lint", "ext-baseline.json")

# The versions rules.yml installs, and the ones this baseline was measured with. A different version
# finds a different set, so the same tree can be green here and red in CI with nothing saying why.
PINNED = {"ruff": "0.14.5", "shellcheck": "0.11.0"}

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

# shellcheck at INFO, not warning. Every class of bug the line below advertises — an unquoted
# expansion (SC2086), `a && b || c` where b can fail (SC2015), a `cd` whose failure is ignored — is
# info-level, so `-S warning` found exactly 0 of them across 39 scripts and the shell half of this
# ratchet was guarding nothing at all. SC1091 is excluded: it means "can't follow this source", which
# is a fact about shellcheck's view of a sourced library, not a bug in the script.
SHELLCHECK_SEVERITY = "info"
SHELLCHECK_EXCLUDE = "SC1091"

TOOLS = {
    "ruff": "undefined names, unused imports, broken except clauses, mutable default arguments",
    "shellcheck": "unquoted expansions, a `cd` whose failure is ignored, a pipeline whose exit code is lost",
}


def files(ext):
    return [p for p in repo_rules.tracked() if p.endswith(ext) and repo_rules.ours(p)]


SKIPPED = []
DRIFTED = []


def in_ci():
    return os.environ.get("GITHUB_ACTIONS") == "true"


def missing(tool, install):
    """A linter that isn't here: fatal in CI (rules.yml installs it), a notice on the Mac."""
    SKIPPED.append(tool)
    if in_ci():
        print(f"✗ {tool} is not installed, and in CI it always is. FIX: check the install step in rules.yml.")
        return True
    print(f"· {tool} is not installed, so its half is skipped here (CI runs it on every pull request).")
    print(f"    FIX, to run it on this Mac too: {install}")
    return False


def broke(tool, out):
    """A linter that ran and failed. Its empty report is not a clean tree."""
    SKIPPED.append(tool)
    print(f"✗ {tool} exited {out.returncode} instead of reporting findings, so nothing was checked:")
    for line in (out.stderr or out.stdout).strip().split("\n")[:5]:
        print(f"    {line}")
    print("    FIX: run it by hand to see why. A version that renamed a flag looks exactly like a clean "
          f"tree here, which is how a ratchet gets erased ({PINNED.get(tool, '?')} is the pinned version).")
    return True


def version(tool, cmd):
    """The installed version, and a note when it isn't the one rules.yml installs."""
    out = subprocess.run(cmd + ["--version"], capture_output=True, text=True)
    got = re.search(r'(\d+\.\d+(\.\d+)?)', out.stdout + out.stderr)
    got = got.group(1) if got else "?"
    if got != PINNED.get(tool):
        DRIFTED.append(f"{tool} {got} (this baseline and rules.yml use {PINNED.get(tool)})")
    return got


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
    # --isolated: every setting is on the command line above, so a ruff.toml appearing anywhere in
    # the tree (or in the owner's ~/.config) can't quietly re-point or switch off the Python half.
    "ruff": (".py", ruff_cmd, "python3 -m pip install ruff",
             ["check", "--isolated", "--no-cache", "--quiet", "--output-format", "concise",
              "--select", RUFF_SELECT, "--ignore", RUFF_IGNORE, "--target-version", RUFF_TARGET],
             re.compile(r'([^:]+):(\d+):\d+:\s*(\S+\s*.*)')),
    "shellcheck": (".sh", lambda: [shutil.which("shellcheck")] if shutil.which("shellcheck") else None,
                   "brew install shellcheck",
                   ["-S", SHELLCHECK_SEVERITY, "-e", SHELLCHECK_EXCLUDE, "-f", "gcc", "-x"],
                   re.compile(r'([^:]+):(\d+):\d+:\s*(?:note|info|warning|error):\s*(.*)')),
}
# Both report findings with exit 1 and a clean tree with 0. Anything else means the tool never
# looked: a renamed flag, a config error, a path that vanished mid-run.
REPORTED = (0, 1)


def run(tool):
    """{file: [(line, what)]} from one linter, and True when this run can't be trusted."""
    ext, start, install, flags, pattern = LINTERS[tool]
    paths = files(ext)
    if not paths:
        return {}, False
    cmd = start()
    if cmd is None:
        return {}, missing(tool, install)
    version(tool, cmd)
    out = subprocess.run(cmd + flags + paths, cwd=ROOT, capture_output=True, text=True)
    found = {}
    for line in out.stdout.split("\n"):
        m = pattern.match(line.strip())
        if m:
            found.setdefault(m.group(1), []).append((int(m.group(2)), m.group(3).strip()))
    if out.returncode not in REPORTED:
        return {}, broke(tool, out)
    # Belt and braces: "it exited 1" and "it printed something we could parse" should agree.
    if out.returncode == 1 and not found:
        return {}, broke(tool, out)
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


def why_not_write():
    """A reason not to touch the baseline file, or None.

    A skipped linter reports nothing, which looks exactly like debt paid down. A linter on a
    different version reports a different set. Either one, written in, un-ratchets the ratchet.
    """
    if SKIPPED:
        return f"{', '.join(SKIPPED)} didn't run, so its findings look paid down"
    if DRIFTED:
        return f"{'; '.join(DRIFTED)}, so the counts wouldn't be the ones CI measures"
    return None


RATCHET = ratchet.Ratchet(BASELINE, "ext-lint", refuse=why_not_write)


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
        return RATCHET.seed(counts)
    if "--update" in args:
        return RATCHET.shrink(counts)
    bad, paid, stale = RATCHET.gate(counts)
    base = ratchet.findings(RATCHET.load())
    for k in bad:
        tool, path = k.split("|", 1)
        print(f"✗ {tool} in {path}: {counts[k]} (allowed {base.get(k, 0)}). {TOOLS[tool]}")
        for line, msg in found[k]:
            print(f"    {path}:{line}  {msg}")
        print("    FIX: do what the finding says, or silence that one line the tool's own way with a reason.")
    # With a linter missing or on another version, "paid down" and "stale" would just mean
    # "not looked at", so neither is reported and neither can be locked in.
    rotten = RATCHET.report(counts, paid, stale) if not why_not_write() else 0
    if DRIFTED:
        print("· " + "; ".join(DRIFTED))
        if in_ci():
            print("    FIX: rules.yml pins both, so a mismatch in CI means the install step drifted.")
            return 1
    skipped = f", {', '.join(SKIPPED)} NOT RUN here" if SKIPPED else ""
    print(f"ext-lint: {len(files('.py'))} python + {len(files('.sh'))} shell files, "
          f"{sum(counts.values())} findings, {sum(base.values())} grandfathered, {len(bad)} new problems{skipped}")
    return 1 if bad or rotten else 0


if __name__ == "__main__":
    sys.exit(main())
