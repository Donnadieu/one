#!/usr/bin/env python3
"""
Doc drift check: a PR that changes a sensitive code area must also touch the
doc that describes that area — or say explicitly why not.

This is the right-sized equivalent of a "regenerate and diff" drift guard for
judgment-call docs (docs/SECURITY.md, docs/RELIABILITY.md,
docs/design-docs/core-beliefs.md). Those aren't generated from a schema the
way a db-schema doc would be, so there's nothing to regenerate — but a human
(or an agent) reads the real code once, writes the doc, and then two more PRs
can change that same code without ever touching the doc again. That's exactly
what happened on 0.9.79 → 0.9.81: three security fixes landed and
docs/SECURITY.md kept describing them as open for two more releases, caught
only by a manual harness-engineering pass. This script is the mechanical
catch for that specific failure mode.

Usage:
    tools/doc-drift-check.py [<base>] [<head>]
        <base>  ref to diff from (default: origin/main)
        <head>  ref to diff to (default: the working tree, i.e. uncommitted
                 changes included — this is what `make check` wants locally;
                 CI passes an explicit base..head commit range)

Exit 0 = clean, or a stated skip (see SKIP_MARKER below).
Exit 1 = a mapped source file changed with none of its docs touched, and no
         skip marker was given.

Also prints (never fails on) a best-effort scan of SECURITY.md/RELIABILITY.md
for phrases that usually mean "this is still open" — a nudge to double check
a finding is still true, not an authoritative check.
"""
import re
import subprocess
import sys

# --- The mapping. Keep this current: when a new sensitive area gets its own
# --- doc section in SECURITY.md / RELIABILITY.md / core-beliefs.md (or a new
# --- doc), add an entry here. An area with no entry is invisible to this
# --- check — the mapping is the whole mechanism, there's no other signal.
SENSITIVE_AREAS = {
    # Access.profile(): the sandbox allow/deny list (the "folder lock")
    "Sources/Env.swift": ["docs/SECURITY.md"],
    # Secret-file (.env) permission self-heal on read
    "Sources/Messenger.swift": ["docs/SECURITY.md"],
    # Download-host pinning, code-signature verification, swap-script safety
    "Sources/Updater.swift": ["docs/SECURITY.md", "docs/RELIABILITY.md"],
    "Sources/UpdaterCheck.swift": ["docs/SECURITY.md", "docs/RELIABILITY.md"],
    # Stale fire_claim / routine-retry semantics
    "Sources/Routines.swift": ["docs/RELIABILITY.md"],
    # Visible-browser approval gate + what gets logged about that approval
    "Sources/BrowserGuard.swift": ["docs/SECURITY.md"],
    # Hidden Chrome instance / CDP bind address
    "Sources/BrowserKeeper.swift": ["docs/SECURITY.md"],
    # Code-level safety invariants (the "enforce in code" belief)
    "Sources/Guards.swift": ["docs/SECURITY.md", "docs/design-docs/core-beliefs.md"],
    # Google token file/directory permissions
    "tools/google_signin.py": ["docs/SECURITY.md"],
}

# Add this (with a one-line reason) to the HEAD commit message to treat a
# real doc-drift hit as a stated skip instead of a CI failure — for the rare
# case where the change genuinely doesn't affect what the doc claims.
SKIP_MARKER = "[skip-doc-drift]"

# Best-effort, not authoritative: these phrases usually mean a doc is
# claiming something is still unresolved. Printed as a visible warning so a
# human re-checks it's still true — never a hard failure on their own.
STALE_PHRASES = [
    "currently open",
    "currently-open",
    "not yet fixed",
    "known gap",
    "todo",
    "unfixed",
]

WATCHED_DOCS = ["docs/SECURITY.md", "docs/RELIABILITY.md"]


def repo_root():
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    )
    return out.stdout.strip()


def changed_files(base, head):
    diff_range = base if head is None else f"{base}..{head}"
    out = subprocess.run(
        ["git", "diff", "--name-only", diff_range], capture_output=True, text=True
    )
    if out.returncode != 0:
        return None
    return set(f for f in out.stdout.splitlines() if f)


def head_commit_message():
    out = subprocess.run(["git", "log", "-1", "--format=%B"], capture_output=True, text=True)
    return out.stdout if out.returncode == 0 else ""


def check_drift(changed):
    failures = []
    for src, docs in SENSITIVE_AREAS.items():
        if src in changed and not any(d in changed for d in docs):
            failures.append((src, docs))
    return failures


def scan_stale_phrases(root):
    hits = []
    for doc in WATCHED_DOCS:
        try:
            text = open(f"{root}/{doc}", encoding="utf-8").read()
        except FileNotFoundError:
            continue
        for phrase in STALE_PHRASES:
            for m in re.finditer(re.escape(phrase), text, re.IGNORECASE):
                line_no = text.count("\n", 0, m.start()) + 1
                snippet = text.splitlines()[line_no - 1].strip()
                hits.append(f"{doc}:{line_no}: '{phrase}' — {snippet[:100]}")
    return hits


def main():
    root = repo_root()
    base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
    head = sys.argv[2] if len(sys.argv) > 2 else None

    changed = changed_files(base, head)
    if changed is None:
        print(f"doc-drift-check: couldn't diff against {base!r}, skipping (not a hard failure)")
        return 0

    skip = SKIP_MARKER in head_commit_message()
    failures = check_drift(changed)

    exit_code = 0
    if failures:
        print("✗ doc-drift-check: sensitive code changed without its doc:")
        for src, docs in failures:
            doc_list = " or ".join(docs)
            print(f"    {src} changed, but none of [{doc_list}] were touched in this diff.")
            print(
                f"    FIX: if this changes what's granted or enforced, update {doc_list}. "
                f"If it genuinely doesn't, touch the doc with a no-op comment, or add "
                f"'{SKIP_MARKER}' to the commit message with a one-line reason why no doc "
                f"update is needed."
            )
        if skip:
            print(f"  ({SKIP_MARKER} found in HEAD commit message — treated as a stated skip.)")
        else:
            exit_code = 1

    stale_hits = scan_stale_phrases(root)
    if stale_hits:
        print(
            "⚠ doc-drift-check: possible stale 'still open' phrasing (best-effort, verify by hand):"
        )
        for h in stale_hits:
            print(f"    {h}")

    if exit_code == 0 and not failures and not stale_hits:
        print("doc-drift-check: clean")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
