#!/usr/bin/python3
"""Keeps tests/corrections/README.md honest (preflight; plain python, no app, safe anywhere).

Every row names the guard for one of Omar's corrections. This fails when a named guard doesn't exist: a repo file
that isn't there, a `--test-*` mode no Swift file handles, or a `corrections: <name>` scenario that
Sources/CorrectionsCheck.swift doesn't run. `none yet` is allowed (the gap stays visible) and counted.
`rule: <file>` names a rule in Omar's brain, outside this repo: counted, not checked.
Prints one summary line: "corrections: N listed, G guarded by a check, R by a rule, U with no guard yet".
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def rows(text):
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 4 and re.match(r"\d{4}-\d{2}-\d{2}$", cells[0]):
            yield cells


def sources():
    out = ""
    d = os.path.join(ROOT, "Sources")
    for f in sorted(os.listdir(d)):
        if f.endswith(".swift"):
            with open(os.path.join(d, f)) as h:
                out += h.read()
    return out


def problem(guard, src, scenarios):
    if guard == "none yet" or guard.startswith("rule: "):
        return None
    if guard.startswith("corrections: "):
        name = guard[len("corrections: "):]
        return None if name in scenarios else "no scenario %r in Sources/CorrectionsCheck.swift" % name
    if guard.startswith("--test-"):
        return None if '"%s"' % guard in src else "no Swift file handles %s" % guard
    return None if os.path.exists(os.path.join(ROOT, guard)) else "%s isn't in the repo" % guard


def main():
    with open(os.path.join(ROOT, "tests/corrections/README.md")) as f:
        table = list(rows(f.read()))
    src = sources()
    with open(os.path.join(ROOT, "Sources/CorrectionsCheck.swift")) as f:
        scenarios = set(re.findall(r'print\("\d{4}-\d{2}-\d{2} ([a-z0-9-]+):', f.read()))
    bad = 0
    for date, words, _, guard in table:
        p = problem(guard, src, scenarios)
        if p:
            bad += 1
            print("  ✗ %s %s: %s" % (date, words[:60], p))
    rule = sum(1 for r in table if r[3].startswith("rule: "))
    none = sum(1 for r in table if r[3] == "none yet")
    print("corrections: %d listed, %d guarded by a check, %d by a rule, %d with no guard yet" % (len(table), len(table) - rule - none, rule, none))
    if not table:
        print("  ✗ no rows read from tests/corrections/README.md")
        bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
