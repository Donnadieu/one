"""Rules about the shape of the repo rather than the shape of a line of Swift.

tools/lint/one-lint.py owns the per-line Swift rules; this module owns the ones that need to look at
the whole tree: the docs/ARCHITECTURE.md table, the workflows, and whether a check script can be
reached from anywhere at all. Same contract as every rule there: a function taking (path, lines) and
yielding (line number, what is wrong), plus a one-line why and a FIX in RULES.

Nothing here imports one-lint, so one-lint imports this. The file selectors every rule is declared
with live here too, for the same reason: this is the lower layer, and a rule in either file picks its
files from the same four names instead of retyping the predicate.

One idea runs through the whole file: a guard must reason about WIRING, not about text. Asking "does
this name appear somewhere in a workflow" reads a mention in a comment, a path in a test fixture's
label and a line behind a condition that is never true as "this runs in CI" — which is how a check
that tested nothing anywhere passed the rule written to catch exactly that.
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

# Which files a rule looks at. Everything skips the three folders above.
SWIFT = lambda p: p.startswith("Sources/") and p.endswith(".swift")  # noqa: E731
SHELL = lambda p: p.endswith(".sh") and os.path.basename(p) != "test-copy.sh"  # noqa: E731
WORKFLOW = lambda p: p.startswith(".github/workflows/") and p.endswith((".yml", ".yaml"))  # noqa: E731
# One's own source, whatever the language: the 600-line cap used to hold Swift alone while 4,500
# lines of Python and 37 shell scripts grew unchecked.
CODE = lambda p: p.endswith((".swift", ".py", ".sh", ".yml", ".yaml", ".html", ".m", ".h"))  # noqa: E731
ANY = lambda p: True  # noqa: E731


def tracked():
    """Every file that would be in a commit from here: tracked, plus new files not gitignored.

    Untracked files count, so the pre-commit hook judges a brand-new file the first time it is
    committed rather than the time after. --exclude-standard means .gitignore still wins.
    """
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("one-lint: can't list the files here (not a git repo?): " + out.stderr.strip())
    # islink before isfile: a symlink named .env points at content that isn't in this tree, so
    # reporting it by that path would send the reader to the wrong file.
    return sorted({p for p in out.stdout.split("\0") if p
                   and not os.path.islink(os.path.join(ROOT, p))
                   and os.path.isfile(os.path.join(ROOT, p))})


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

# The vocabulary, in one place. A tag outside it is a typo, and a typo used to fail SILENTLY: an
# unknown area made dependency-direction skip the file and destructive-fs-area flag it, with nothing
# saying the word was wrong. `architecture-table` reports it now.
AREAS = {
    "foundation",   # Env, Guards: no dependencies of its own, everything may call it
    "service",      # does one job for Model (engine, installer, updater, speaker, …)
    "state",        # Model and the stores it owns
    "ui",           # a view
    "chat",         # the chat column and its pieces
    "entry",        # the app's own entry point
    "model",        # Model.swift itself
    "bridge",       # the engine <-> app bridge
    "helpers",      # a helper's own files and jobs
    "check",        # a check's Swift side (--test-*)
    "dev only",     # renders, previews, stand-ins: never in a person's hands
    "rule",         # a rule the lint or the engine enforces
}
# Words the table has used for an area that already has a name. Canonicalised when the table is
# read, so one concept is one area in the code: `view` and `ui` had drifted into two spellings of the
# same thing, each needing its own entry in every set below. Tidying the doc's wording then changes
# nothing the lint decides, which is what lets tools/doc-drift-check.py tell a synonym rename from a
# retag that takes a file out of a safety rule.
ALIASES = {"view": "ui"}
LOWER_LAYERS = {"foundation", "service"}        # may not reach back up to Model.shared
MAY_HAVE_VIEWS = {"ui", "state", "chat", "entry", "model", "bridge"}
# Deleting a person's file is the riskiest thing One does, so it belongs where a folder has an owner:
# a service, foundation, a helper's own job files, or test code cleaning up its own scratch. A view or
# a piece of state deleting straight from the UI layer is how the 0.9.74 "reset onboarding" incident
# emptied `helpers`.
MAY_DELETE = {"foundation", "service", "check", "dev only", "helpers", "rule"}

_AREAS = None
HEADER = "| File | Area | Responsibility |"


def parse_areas(text):
    """{file name: set of area tags} from the one table in a docs/ARCHITECTURE.md.

    Takes the text rather than reading the file, because tools/doc-drift-check.py parses the version
    at the base ref with it: two parsers would have disagreed about aliases and about where the
    table ends, and the whole point of that check is comparing the two.

    Read strictly, because two safety rules take their scope from it: only rows inside the one table
    that starts at HEADER and ends at the first line that isn't a row, and split into exactly three
    cells so a `|` inside a Responsibility ("`--test-select <case|all>`") can't shift the Area column.
    """
    out, inside = {}, False
    for line in text.split("\n"):
        if line.strip() == HEADER:
            inside = True
            continue
        if not inside:
            continue
        if not line.startswith("|"):
            break   # one table, and this is the end of it
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|", 2)]
        if len(cells) < 3 or set(cells[0]) <= set("-: "):
            continue
        tagged = (t.strip().lower() for t in cells[1].split("+") if t.strip())
        out[cells[0]] = {ALIASES.get(t, t) for t in tagged}
    return out


def areas():
    """The table as it is now. It is the only place the areas live, so a rule that needs to know
    whether a file is foundation, a service or a view reads it from the docs instead of a list
    hand-typed in the lint (which is how a new service file used to slip past the dependency rule:
    nobody edited the list)."""
    global _AREAS
    if _AREAS is None:
        _AREAS = parse_areas(read("docs/ARCHITECTURE.md"))
    return _AREAS


def tags(path):
    """Area tags for a Sources file, or None when the table doesn't name it."""
    return areas().get(os.path.basename(path))


def r_architecture_table(path, lines):
    t = tags(path)
    if t is None:
        yield 1, "no row in the docs/ARCHITECTURE.md table, so every area rule skips this file"
        return
    for unknown in sorted(t - AREAS):
        yield 1, "its Area says %r, which is not one of the areas (%s)" % (unknown, ", ".join(sorted(AREAS)))


# MARK: - Deleting files

def r_destructive_fs(path, lines):
    t = tags(path)
    if t is not None and t <= MAY_DELETE:
        return   # a file the table doesn't name is disallowed too: nothing can say the delete is in
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


# GitHub pastes ${{ … }} into the script as text before bash ever parses it, so the quotes around it
# in the YAML do not contain it: a dispatch input of `guard"; curl …| sh; "` runs on the runner. The
# fix is always the same shape — put the value in env: and read it as "$VAR" in the shell.
# Safe to paste: a commit sha is hex, and a matrix value comes from the workflow file itself. NOT
# safe: inputs.* (free text on a dispatch) and github.event.*.{tag_name,title,body,…}, which a tag
# or a branch can carry a double quote into.
SAFE_EXPR = re.compile(
    r'^(?:matrix\.[\w.-]+|[\w.]*\.sha|github\.(?:sha|repository|repository_owner|run_id|run_number'
    r'|run_attempt|event_name|workflow|job)|github\.event\.pull_request\.number)$'
)
RUN_KEY = re.compile(r'(?:-\s+)?run:\s*(.*)$')


def r_workflow_run_injection(path, lines):
    run_at = None
    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        m = RUN_KEY.match(stripped)
        if m:
            run_at, text = indent, m.group(1)
        elif run_at is not None and (not stripped or indent > run_at):
            text = line
        else:
            run_at = None
            continue
        for expr in re.findall(r'\$\{\{\s*(.+?)\s*\}\}', text):
            if not SAFE_EXPR.match(expr.split("|")[0].strip()):
                yield i, "`${{ %s }}` is pasted into the shell before bash parses it" % expr[:48]


# MARK: - Every check script must be reachable

# A check nothing runs is a check that silently passes. Reachable means: a workflow or
# tools/preflight.sh runs it (directly, or through another script one of them runs), or it says in its
# own header where it does run and why it can't run in CI, and a make target starts it.
CI_VENUES = (".github/workflows/", "tools/preflight.sh", ".githooks/")
RUNS_LINE = re.compile(r'^#\s*runs:\s*(?P<venue>[\w -]+?)\s*\((?P<how>[^)]+)\)\s*[-–—]+\s*(?P<why>\S.*)$')

# A name has to be in a COMMAND position to count, so it is extracted rather than searched for:
# tools/jobs-check.sh used to read as "runs in CI" because tools/restart-guard-check.py has the
# string "(jobs-check.sh)" inside a test-case label, and engine-check.sh read as reachable because a
# workflow names goal-engine-check.sh (a basename that ends with it).
INVOKED = re.compile(r'(?<![\w/.-])(?:\./)?tools/([\w./-]+\.(?:sh|py))')
SIBLING = re.compile(r'\$\((?:dirname|cd)[^)]*\)(?:/[\w.-]+)*/([\w.-]+\.(?:sh|py))')
# In a workflow, only a `run:` body is a command. The rest of the YAML is configuration, and a path
# there is not an invocation: `.github/workflows/smooth.yml` names tools/smooth-compare.sh in its
# `paths:` filter, so deleting the step that actually runs it left it certified as "runs in CI".
# In a shell script every non-comment line is a command, and the shells here put a command after an
# env assignment, after a quoted description (preflight's `check "…" cmd`) and inside `bash -c "…"`,
# so trying to pin the position there costs more accuracy than it buys.
RUN_BODY = re.compile(r'(?:-\s+)?run:\s*(.*)$')
# tools/preflight.sh guards its owner-only lines with `[ $CI = 0 ]`, and every venue runs it with
# --ci, so a check named only on one of those lines runs nowhere. Counting such a line as an
# invocation is how tools/browser-guard-engine-check.sh passed this rule while testing nothing.
NEVER_IN_CI = re.compile(r'\[\[?\s*"?\$\{?CI\}?"?\s*==?\s*"?0"?\s*\]\]?')
COMMENT = re.compile(r'(?:^|(?<=\s))#.*$')
_REACH = None
_TARGETS = None


def commands(path):
    """The scripts this file really runs: comments stripped, dead-in-CI lines dropped."""
    out, in_yaml, run_at = set(), path.endswith((".yml", ".yaml")), None
    for line in read(path).split("\n"):
        if in_yaml:   # only a `run:` body is a command; the rest of the YAML is configuration
            stripped = line.lstrip()
            indent = len(line) - len(stripped)
            m = RUN_BODY.match(stripped)
            if m:
                run_at, line = indent, m.group(1)
            elif run_at is not None and (not stripped or indent > run_at):
                line = stripped
            else:
                run_at = None
                continue
        line = COMMENT.sub("", line)
        if not line.strip() or NEVER_IN_CI.search(line):
            continue
        out |= {os.path.basename(m) for m in INVOKED.findall(line)}
        out |= set(SIBLING.findall(line))
    return out


def make_targets():
    """{target: its recipe} from the Makefile, so a rule can check a target exists and what it does."""
    global _TARGETS
    if _TARGETS is None:
        _TARGETS, cur = {}, None
        for line in read("Makefile").split("\n"):
            m = re.match(r'^([a-zA-Z][\w-]*)\s*:(?!=)', line)
            if m:
                cur = m.group(1)
                _TARGETS.setdefault(cur, "")
            elif line.startswith("\t") and cur:
                _TARGETS[cur] += line + "\n"
            elif line.strip():
                cur = None
    return _TARGETS


def _reachable_in_ci():
    """The set of script basenames a workflow, preflight or a git hook ends up running."""
    global _REACH
    if _REACH is not None:
        return _REACH
    files = tracked()
    scripts = [p for p in files if p.startswith("tools/") and p.endswith((".sh", ".py"))]
    names = {os.path.basename(p) for p in scripts}
    refs = {os.path.basename(p): commands(p) & names for p in scripts}
    reach = set()
    for p in files:
        if p.startswith(CI_VENUES):
            reach |= commands(p) & names
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
    venue, how = declared.group("venue"), declared.group("how")
    target = re.search(r'make\s+([\w-]+)', how)
    recipe = make_targets().get(target.group(1)) if target else None
    if recipe is None:
        yield 1, "says `%s` starts it, but the Makefile has no such target" % how
    elif name not in recipe:
        yield 1, "says `%s` starts it, but that target doesn't run this script" % how
    elif "owner" in venue.lower() and not re.search(r'\$\(call live,|ONE_LIVE_CHECK', recipe):
        yield 1, "`%s` doesn't set ONE_LIVE_CHECK, so tools/ci-only.sh refuses it there too" % how


# A check is a check whatever it is called: tools/handoff-qa.sh carried a `runs:` header no rule read
# and had no make target, because its name doesn't end in -check.sh while it does start a test mode.
LIVE_GATE = re.compile(r'ci-only\.sh|ONE_(?:LIVE_CHECK|TEST_MODE)=')


def is_check_script(p):
    if re.fullmatch(r'tools/[\w-]+-check\.(sh|py)', p):
        return True
    return p.startswith("tools/") and p.endswith(".sh") and bool(LIVE_GATE.search(read(p)))


# MARK: - One wrapper for the live engine checks

# The family this guards: a live check that makes a test copy (tools/test-copy.sh) and runs its binary
# against One's REAL engine in an `env -i` clean environment, so no Hermes variable from the caller can
# steer it. Ten scripts each carried their own copy of that and had drifted on which settings it
# carries — which is the whole reason tools/engine-check.sh exists.
#
# The four families of check script, so the next one lands in a family instead of inventing a fifth:
#   1. live engine   test copy + `env -i` + the real engine      -> this rule; call engine-check.sh
#   2. stand-in      the same, with ONE_TEST_ENGINE=fake-engine.py -> skipped below; follow-up work
#                    (a fresh bundle id per run, several runs per script, kill -9 in the middle).
#                    Free, reachable and already covered on every pull request.
#   3. own build     builds a sanitizer or soak app of its own, no test copy -> not this shape at all
#   4. launch        starts a test copy through Launch Services   -> engine_launch_env in engine-check.sh
#
# The exemption is a real delegation, not a mention: "unlike engine-check.sh, this one …" in a comment
# used to switch the rule off, and engine-check.sh exempted ITSELF only because its own name appears
# in its own header.
DELEGATES = re.compile(r'(?:^|\s)(?:\.|source|exec)\s+.*engine-check\.sh')
STAND_IN = re.compile(r'ONE_TEST_ENGINE=\S*fake-engine\.py')


def r_engine_wrapper(path, lines):
    code = "\n".join(COMMENT.sub("", line) for line in lines)
    if "test-copy.sh" not in code or "env -i" not in code:
        return
    if DELEGATES.search(code) or STAND_IN.search(code):
        return
    for i, line in enumerate(lines, 1):
        if "env -i" in COMMENT.sub("", line):
            yield i, "its own copy of the test-copy + clean-environment setup"
            return


# MARK: - Files that look like a credential

SECRET_NAMES = re.compile(
    r'^(\.env(\.(?!example$|sample$).+)?|\.netrc|credentials\.json|client_secret.*\.json|secrets?\.ya?ml'
    r'|\.mcp\.json|settings\.local\.json'
    r'|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|.*\.(pem|key|p12|pfx|jks|keystore|kdbx|ovpn|gpg)|(?!.*\.pub)[\w.-]*\.asc)$'
)


def r_secret_file(path, lines):
    if SECRET_NAMES.match(os.path.basename(path)):
        yield 1, "the file name says credential, and this repo is public"


RULES = {
    "architecture-table": (
        r_architecture_table,
        "The table in docs/ARCHITECTURE.md is where every area rule reads a file's layer from.",
        "Add a row for it to the table in docs/ARCHITECTURE.md: | <File>.swift | <area> | <what it does> |.",
        SWIFT,
    ),
    "destructive-fs-area": (
        r_destructive_fs,
        "Deleting a person's file is the riskiest thing One does; it belongs where a folder has an owner.",
        "Move the delete into the service that owns that folder and call it, or give the file an area in "
        "docs/ARCHITECTURE.md that is allowed to delete (foundation, service, helpers, check, dev only).",
        SWIFT,
    ),
    "workflow-permissions": (
        r_workflow_permissions,
        "A workflow with no permissions block gets a write token it almost never needs.",
        "Add a top-level `permissions:` block with the least it needs (usually `contents: read`).",
        WORKFLOW,
    ),
    "action-pinned": (
        r_action_pinned,
        "A third-party action's tag can be moved to new code after you reviewed it.",
        "Pin it to a full 40-character commit SHA and put the version in a trailing comment.",
        WORKFLOW,
    ),
    "workflow-run-input": (
        r_workflow_run_injection,
        "GitHub pastes ${{ … }} into the script as text, so a dispatch input can run its own commands.",
        "Put the value in the step's `env:` block and read it as \"$VAR\" in the shell; the quotes in the "
        "YAML don't contain a ${{ }}, because it is substituted before bash sees the line.",
        WORKFLOW,
    ),
    "no-orphan-check": (
        r_orphan_check,
        "A check nothing can run is a check that silently passes.",
        "Run it from a workflow or tools/preflight.sh (a `[ $CI = 0 ]` line in preflight runs nowhere, "
        "because every venue passes --ci); or, if it needs this Mac (One's installed engine, the owner's "
        "own subscription, a real window), add `# runs: owner-only (make <target>) — <why>` to its header "
        "and a make target that runs it through $(call live,<this script>) so ONE_LIVE_CHECK names it.",
        is_check_script,
    ),
    "engine-check-wrapper": (
        r_engine_wrapper,
        "Ten copies of this setup had already drifted on the setting that isolates the test world.",
        "Call tools/engine-check.sh (as a command, or `. engine-check.sh --lib` for several runs) instead of "
        "repeating the test copy, the clean environment and the timeout here.",
        # engine-check.sh IS the wrapper, so it is the one file that may carry the setup. By basename
        # in the selector, not by its own name appearing somewhere in its own text, which is how it
        # used to exempt itself — rewording a header comment would have made it flag itself.
        lambda p: p.startswith("tools/") and p.endswith(".sh") and os.path.basename(p) != "engine-check.sh",
    ),
    "secret-file": (
        r_secret_file,
        "The repo is public, and .gitignore can't catch a file someone adds with -f.",
        "Delete it from the tree, keep it outside the repo, and load it at run time from the Keychain.",
        ANY,
    ),
}
