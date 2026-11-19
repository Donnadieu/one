"""Rules about the shape of the repo rather than the shape of a line of Swift.

tools/lint/one-lint.py owns the per-line Swift rules; this module owns the ones that need to look at
the whole tree: the docs/ARCHITECTURE.md table, the workflows, and whether a check script can be
reached from anywhere at all. Same contract as every rule there: a function taking (path, lines) and
yielding (line number, what is wrong), plus a one-line why and a FIX in RULES.

Nothing here imports one-lint, so one-lint imports this.
"""
import os
import re
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ARCH = os.path.join(ROOT, "docs", "ARCHITECTURE.md")

# Not our code, so our rules don't apply (stated skips, not silent ones):
#   old/                  one 2024 file kept as a souvenir of the first version
#   tests/fixtures/*.py   vendored copies of the engine's own files, kept byte-identical for diffing
#   tools/lint/canaries/  the snippets that prove each rule still fires, which are broken on purpose
SKIP_DIRS = ("old/", "tests/fixtures/", "tools/lint/canaries/")


def tracked():
    """Every file that would be in a commit from here: tracked, plus new files not gitignored.

    Untracked files count, so the pre-commit hook judges a brand-new file the first time it is
    committed rather than the time after. --exclude-standard means .gitignore still wins.
    """
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, text=True, check=True)
    return sorted({p for p in out.stdout.split("\0") if p and os.path.isfile(os.path.join(ROOT, p))})


def ours(path):
    """True for a file this repo wrote and these rules may judge."""
    return not path.startswith(SKIP_DIRS)


def read(path):
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


# MARK: - docs/ARCHITECTURE.md is the one list of areas

_AREAS = None


def areas():
    """{file name: set of area tags} from the table in docs/ARCHITECTURE.md.

    The table is the only place the areas live, so a rule that needs to know whether a file is
    foundation, a service or a view reads it from the docs instead of a list hand-typed in the lint
    (which is how a new service file used to slip past the dependency rule: nobody edited the list).
    """
    global _AREAS
    if _AREAS is None:
        _AREAS = {}
        for line in read("docs/ARCHITECTURE.md").split("\n"):
            if not line.startswith("|"):
                continue
            cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
            if len(cells) < 2 or cells[0] == "File" or set(cells[0]) <= set("-: "):
                continue
            _AREAS[cells[0]] = {t.strip().lower() for t in cells[1].split("+") if t.strip()}
    return _AREAS


def tags(path):
    """Area tags for a Sources file, or None when the table doesn't name it."""
    return areas().get(os.path.basename(path))


def r_architecture_table(path, lines):
    if tags(path) is None:
        yield 1, "no row in the docs/ARCHITECTURE.md table, so every area rule skips this file"


# MARK: - Deleting files

# Deleting a person's file is the riskiest thing One does, so it belongs where a folder has an owner:
# a service, foundation, a helper's own job files, or test code cleaning up its own scratch. A view or
# a piece of state deleting straight from the UI layer is how the 0.9.74 "reset onboarding" incident
# emptied `helpers`. A file the architecture table doesn't name is disallowed too (fail closed): its
# area is unknown, so nothing can say the deletion is in the right place.
DELETE_OK_AREAS = {"foundation", "service", "check", "dev only", "helpers", "rule"}


def r_destructive_fs(path, lines):
    t = tags(path)
    if t is not None and t <= DELETE_OK_AREAS:
        return
    where = "an area docs/ARCHITECTURE.md doesn't name" if t is None else "/".join(sorted(t))
    for i, line in enumerate(lines, 1):
        if re.search(r'\bremoveItem\(', line.split("//", 1)[0]):
            yield i, "deletes files from %s" % where


# MARK: - Workflows

def r_workflow_permissions(path, lines):
    if not any(re.match(r'^permissions:', line) for line in lines):
        yield 1, "no top-level permissions: block, so the job gets the default write token"


# Actions from actions/ and github/ are GitHub's own and move with the runner; anything else is a
# third party whose tag can be repointed at new code after review (a tag is not a version).
def r_action_pinned(path, lines):
    for i, line in enumerate(lines, 1):
        m = re.search(r'uses:\s*([\w.-]+)/([\w.-]+)(?:/[\w./-]+)?@(\S+)', line)
        if not m or m.group(1) in ("actions", "github"):
            continue
        if not re.fullmatch(r'[0-9a-f]{40}', m.group(3)):
            yield i, "third-party action %s/%s pinned to the movable tag %s" % (m.group(1), m.group(2), m.group(3))


# MARK: - Every check script must be reachable

# A check nothing runs is a check that silently passes. Reachable means: a workflow or
# tools/preflight.sh runs it (directly, or through another script one of them runs), or it says in its
# own header where it does run and why it can't run in CI, and a make target starts it.
CI_VENUES = (".github/workflows/", "tools/preflight.sh", ".githooks/")
RUNS_LINE = re.compile(r'^#\s*runs:\s*(?P<venue>[\w -]+?)\s*\((?P<how>[^)]+)\)\s*[-—]+\s*(?P<why>\S.*)$')
_REACH = None


def _reachable_in_ci():
    """The set of script basenames a workflow, preflight or a git hook ends up running."""
    global _REACH
    if _REACH is not None:
        return _REACH
    files = tracked()
    scripts = [p for p in files if p.startswith("tools/") and p.endswith((".sh", ".py"))]
    names = {os.path.basename(p) for p in scripts}
    venue_text = "\n".join(read(p) for p in files if p.startswith(CI_VENUES))
    refs = {os.path.basename(p): {n for n in names if n != os.path.basename(p) and n in read(p)} for p in scripts}
    reach = {n for n in names if n in venue_text}
    changed = True
    while changed:  # a check run by a reachable script is reachable too
        changed = False
        for name in sorted(reach):
            for n in refs.get(name, ()):
                if n not in reach:
                    reach.add(n)
                    changed = True
    _REACH = reach
    return reach


def r_orphan_check(path, lines):
    name = os.path.basename(path)
    if name in _reachable_in_ci():
        return
    declared = next(filter(None, (RUNS_LINE.match(line) for line in lines[:25])), None)
    if not declared:
        yield 1, "no workflow and no preflight runs this, and it doesn't say where it does run"
        return
    if name not in read("Makefile"):
        yield 1, "says it runs %s, but no make target starts it" % declared.group("venue")


# MARK: - One wrapper for the live engine checks

# The family this guards: a live check that makes a test copy (tools/test-copy.sh) and runs its binary
# against One's REAL engine in an `env -i` clean environment, so no Hermes variable from the caller can
# steer it. Ten scripts each carried their own copy of that and had drifted on which settings it
# carries — which is the whole reason tools/engine-check.sh exists.
#
# Stated skip: the stand-in-engine checks (they set ONE_TEST_ENGINE to tools/fake-engine.py) are a
# different family — a fresh bundle id per run so two preflights can't wipe each other, several runs
# per script, kill -9 in the middle. They are reachable, free and already covered on every pull
# request, so folding them in is follow-up work (docs/exec-plans/tech-debt-tracker.md), not something
# to do in the same pass that installs the guard. Scripts that start a test copy through Launch
# Services, or build a sanitizer app of their own, aren't this family either and don't match.
def r_engine_wrapper(path, lines):
    text = "\n".join(lines)
    if "test-copy.sh" not in text or "env -i" not in text:
        return
    if "engine-check.sh" in text or "fake-engine.py" in text:
        return
    for i, line in enumerate(lines, 1):
        if "env -i" in line:
            yield i, "its own copy of the test-copy + clean-environment setup"
            return


# MARK: - Files that look like a credential

SECRET_NAMES = re.compile(
    r'^(\.env(\..+)?|\.netrc|credentials\.json|client_secret.*\.json|secrets?\.ya?ml'
    r'|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|.*\.(pem|key|p12|pfx|jks|keystore|kdbx|ovpn|asc|gpg))$'
)


def r_secret_file(path, lines):
    if SECRET_NAMES.match(os.path.basename(path)):
        yield 1, "the file name says credential, and this repo is public"


RULES = {
    "architecture-table": (
        r_architecture_table,
        "The table in docs/ARCHITECTURE.md is where every area rule reads a file's layer from.",
        "Add a row for it to the table in docs/ARCHITECTURE.md: | <File>.swift | <area> | <what it does> |.",
        lambda p: p.startswith("Sources/") and p.endswith(".swift"),
    ),
    "destructive-fs-area": (
        r_destructive_fs,
        "Deleting a person's file is the riskiest thing One does; it belongs where a folder has an owner.",
        "Move the delete into the service that owns that folder and call it, or give the file an area in "
        "docs/ARCHITECTURE.md that is allowed to delete (foundation, service, helpers, check, dev only).",
        lambda p: p.startswith("Sources/") and p.endswith(".swift"),
    ),
    "workflow-permissions": (
        r_workflow_permissions,
        "A workflow with no permissions block gets a write token it almost never needs.",
        "Add a top-level `permissions:` block with the least it needs (usually `contents: read`).",
        lambda p: p.startswith(".github/workflows/") and p.endswith((".yml", ".yaml")),
    ),
    "action-pinned": (
        r_action_pinned,
        "A third-party action's tag can be moved to new code after you reviewed it.",
        "Pin it to a full 40-character commit SHA and put the version in a trailing comment.",
        lambda p: p.startswith(".github/workflows/") and p.endswith((".yml", ".yaml")),
    ),
    "no-orphan-check": (
        r_orphan_check,
        "A check nothing can run is a check that silently passes.",
        "Run it from a workflow or tools/preflight.sh; or, if it needs this Mac (One's installed engine, the "
        "owner's own subscription, a real window), add `# runs: owner-only (make <target>) — <why>` to its "
        "header and a make target that sets ONE_LIVE_CHECK=1.",
        lambda p: re.fullmatch(r'tools/[\w-]+-check\.(sh|py)', p) and os.path.basename(p) != "engine-check.sh",
    ),
    "engine-check-wrapper": (
        r_engine_wrapper,
        "Ten copies of this setup had already drifted on the setting that isolates the test world.",
        "Call tools/engine-check.sh (as a command, or `. engine-check.sh --lib` for several runs) instead of "
        "repeating the test copy, the clean environment and the timeout here.",
        lambda p: p.startswith("tools/") and p.endswith(".sh"),
    ),
    "secret-file": (
        r_secret_file,
        "The repo is public, and .gitignore can't catch a file someone adds with -f.",
        "Delete it from the tree, keep it outside the repo, and load it at run time from the Keychain.",
        lambda p: True,
    ),
}
