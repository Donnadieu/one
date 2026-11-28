#!/usr/bin/env python3
"""The brain starter One bundles: the owner's own files only, never third-party course material.

The brain starter (a private repo) also carries a third-party kit in templates/cofounder-room/ that its
licence forbids passing on. It went out inside every public One from 0.4 to 0.9.146. One's co-founder
room is a normal room now (templates/room), so the bundle leaves the kit out entirely, rewrites the few
lines of the starter's own docs that pointed at it, and swaps the starter's private licence note for
One's MIT terms (the starter's own files are by One's author).

    brain-starter-bundle.py bundle <starter-checkout> <Resources-dir>   build.sh: git archive, clean, check
    brain-starter-bundle.py check <brain-starter-dir>                   fail if any kit file or word is left
    brain-starter-bundle.py selftest                                    make check: the cleaning and the check
                                                                        both work, on a poisoned stand-in

Nothing here ever writes to the starter checkout itself: it is read with `git archive` only.
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "tests" / "fixtures" / "brain-starter-min"

# Paths that must never be in the bundle (relative to brain-starter/, any depth where it says so).
BAD_DIRS = {"frameworks", "kit-update", "five-filters", "idea-foundation", "what-step"}
BAD_FILES = {"kit.yaml", "MAP.html", "START-HERE.md", "GITHUB-BACKUP.md"}
# Words that must never be in a bundled file. Case-insensitive unless the pattern says (?-i:...).
BAD_WORDS = [
    r"next\s*badge",
    r"vibe\s*found",
    r"starter\s*kit",
    r"templates/cofounder-room",
    r"cofounder-room/",
    r"kit\.yaml",
    r"kit-update",
    r"five-filters",
    r"idea-foundation",
    r"what-step",
    r"\bframeworks?\b",
    r"\bthe kit\b",
    r"(?-i:\bKit\b)",
    r"germ[áa]n\b",
    r"\bbrian\b",
    r"not for distribution",
]

LICENSE = """# License

MIT License

Copyright (c) 2026 Omar Donnadieu

The brain starter's own files (everything in this folder), as bundled in the One app.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

# The co-founder room is a normal room built from templates/room. One's own words (Brain.swift has the same hub).
COFOUNDER_KIND = """## Co-founder room (a business)

Built from `templates/room/`, like every other room.

- **Holds:** a business the owner runs or is starting: ideas, customers, the offer, the pipeline, decisions.
- **Never holds:** personal life, a job's work.
- **Hub file:** `brain/company.md`
- **Vault folders:** `people/`, `customers/`, `projects/`, plus `decisions.md`
- **Rule that earns it:** it pushes toward buyers and revenue, and it may one day be shared with a partner, an advisor or a hire.

**`brain/company.md` headings:**
```markdown
# The business, as it stands
## This week
- **The one thing that matters:** [not yet]
## What it is
- **What we sell:** [not yet]
- **Who buys it:** [not yet]
## Customers and leads
| Who | Where it stands | Next step | Note |
|---|---|---|---|
## Decisions
```

**Setup questions,** one at a time:
1. In one line, what is the business, or the idea?
2. Who is it for?
3. Where does it stand today: an idea, the first customers, or up and running?
4. Who else is in it with you?
5. What's the one thing that matters this week?

**Importer keeps:** the business's ideas, customers and leads, numbers, decisions, the people involved. **Skips:** personal life and a job's work.

**Starting principles:**
1. Talk to buyers early. A real conversation beats a plan.
2. A claim about the market has a source, or it's marked as a guess.
3. One priority a week.
4. Money in and money out is written down.
5. A decision is written with its date and its reason.
"""

# (file, pattern, replacement): the starter's own docs, minus the lines that pointed at the kit.
# A pattern that no longer matches is fine (the starter changed); `check` is the gate either way.
EDITS = [
    ("README.md", r" Private: shared by invitation only\.", ""),
    ("README.md", r"^- `templates/cofounder-room/`:[^\n]*\n", ""),
    ("CHANGELOG.md", r"and a co-founder room from the AI Brain Starter Kit 2026\.", "a co-founder room for a business, and any other room."),
    ("starter.yaml", r";\s*a co-founder room updates with kit-update", ""),
    ("HELP.md", r" A co-founder room updates itself the same way from a Kit release \(its own `kit-update` skill\)\.", ""),
    ("templates/kinds.md", r"## Co-founder room \(a business\).*?(?=\n## |\Z)", COFOUNDER_KIND.rstrip("\n")),
    ("skills/add-room/SKILL.md", r" \(fixed by the Kit\)", ""),
    ("skills/add-room/SKILL.md", r"\*\*A business \(co-founder room\)\*\* is built from the Kit.*?(?=\*\*Every other room:\*\*)", ""),
    ("skills/add-room/SKILL.md", r"\*\*Every other room:\*\*", "**Every room** (a business too):"),
    ("skills/onboarding/SKILL.md", r", built from the Kit \(`templates/kinds\.md`\)", " (`templates/kinds.md`)"),
    ("skills/onboarding/SKILL.md", r", with a method for finding buyers built in\.", " and pushes you toward buyers and revenue."),
]


def git_env(**extra) -> dict:
    """The environment for git on another repo. A git hook (pre-commit runs `selftest`) exports GIT_DIR, GIT_INDEX_FILE
    and friends, and git obeys them over `-C`: without this, the stand-in's `init`, `config` and `commit` landed in
    One's own repository (a stray commit on the branch, `core.bare=true`, `commit.gpgsign=false`)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(extra)
    return env


def clean(bs: Path) -> None:
    """Remove the kit and every pointer to it from an extracted brain-starter/ folder."""
    import shutil

    shutil.rmtree(bs / "templates" / "cofounder-room", ignore_errors=True)
    for p in sorted(bs.rglob("*"), reverse=True):
        if p.is_dir() and p.name in BAD_DIRS:
            shutil.rmtree(p, ignore_errors=True)
        elif p.is_file() and p.name in BAD_FILES:
            p.unlink()
    for rel, pat, rep in EDITS:
        f = bs / rel
        if f.is_file():
            t = f.read_text(encoding="utf-8")
            t = re.sub(pat, lambda _m, r=rep: r, t, flags=re.S | re.M)
            f.write_text(t if t.endswith("\n") else t + "\n", encoding="utf-8")
    (bs / "LICENSE.md").write_text(LICENSE, encoding="utf-8")


def findings(bs: Path) -> list:
    """Every kit file or word left in a brain-starter folder (empty = clean)."""
    out = []
    if not bs.is_dir():
        return [f"{bs}: no such folder"]
    words = [re.compile(w, re.I) for w in BAD_WORDS]
    for p in sorted(bs.rglob("*")):
        rel = p.relative_to(bs).as_posix()
        if rel == "templates/cofounder-room" or rel.startswith("templates/cofounder-room/"):
            out.append(f"{rel}: the kit's template folder")
        elif p.is_dir() and p.name in BAD_DIRS:
            out.append(f"{rel}/: a kit folder")
        elif p.is_file() and p.name in BAD_FILES:
            out.append(f"{rel}: a kit file")
        if not p.is_file():
            continue
        try:
            t = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for w in words:
            m = w.search(t)
            if m:
                line = t.count("\n", 0, m.start()) + 1
                out.append(f"{rel}:{line}: {m.group(0)!r}")
    return out


def check(bs: Path, quiet: bool = False) -> int:
    bad = findings(bs)
    for b in bad:
        print(f"  kit material in the bundled brain starter: {b}", file=sys.stderr)
    if bad:
        print("FIX: tools/brain-starter-bundle.py leaves the kit out; add the new file or line to its clean step.", file=sys.stderr)
        return 1
    if not quiet:
        print(f"brain starter clean: {bs}")
    return 0


def bundle(starter: Path, resources: Path, quiet: bool = False) -> int:
    dest = resources / "brain-starter"
    if dest.exists():
        import shutil

        shutil.rmtree(dest)
    arch = subprocess.run(
        ["git", "-C", str(starter), "archive", "--prefix=brain-starter/", "HEAD", "--", ".", ":(exclude)templates/cofounder-room"],
        capture_output=True,
        check=False,
        env=git_env(),
    )
    if arch.returncode != 0:
        print(arch.stderr.decode(errors="replace"), file=sys.stderr)
        return 1
    subprocess.run(["tar", "-x", "-C", str(resources)], input=arch.stdout, check=True)
    clean(dest)
    return check(dest, quiet)


def selftest() -> int:
    """A stand-in starter poisoned with kit files and lines must come out clean, and `check` must catch each one."""
    fails = 0

    def ok(name, cond):
        nonlocal fails
        print(("  ✓ " if cond else "  ✗ ") + name)
        fails += 0 if cond else 1

    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "starter"
        subprocess.run(["cp", "-R", str(FIXTURE), str(src)], check=True)
        kit = src / "templates" / "cofounder-room"
        (kit / "frameworks").mkdir(parents=True)
        (kit / "frameworks" / "card.md").write_text("# A card\n", encoding="utf-8")
        (kit / "kit.yaml").write_text("version: x\n", encoding="utf-8")
        (src / "skills" / "kit-update").mkdir(parents=True)
        (src / "skills" / "kit-update" / "SKILL.md").write_text("# update\n", encoding="utf-8")
        (src / "LICENSE.md").write_text("Private. Not for distribution. The Kit is by Next Badge Inc.\n", encoding="utf-8")
        (src / "README.md").write_text("# Starter\n\n- `templates/cofounder-room/`: the AI Brain Starter Kit 2026, for a business.\n", encoding="utf-8")
        env = git_env(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@localhost", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@localhost")
        # Never another repository's config: refuse unless git sees the stand-in as its own top level.
        for cmd in (["init", "-q"], ["config", "--local", "commit.gpgsign", "false"], ["add", "-A"], ["commit", "-qm", "starter"]):
            subprocess.run(["git", "-C", str(src), *cmd], check=True, env=env)
            if cmd[0] == "init":
                top = subprocess.run(["git", "-C", str(src), "rev-parse", "--show-toplevel"], capture_output=True, text=True, env=env, check=False)
                if Path(top.stdout.strip()).resolve() != src.resolve():
                    print(f"refusing: git doesn't see {src} as its own repository ({top.stdout.strip() or top.stderr.strip()})")
                    return 1
        res = Path(tmp) / "Resources"
        res.mkdir()
        bs = res / "brain-starter"
        ok("a poisoned stand-in starter bundles clean", bundle(src, res, quiet=True) == 0)
        ok("no templates/cofounder-room in the bundle", not (bs / "templates" / "cofounder-room").exists())
        ok("the normal room template is kept", (bs / "templates" / "room" / "AGENTS.md").is_file())
        ok("the brain's own files are kept", all((bs / f).is_file() for f in ("AGENTS.md", "owner.yaml")))
        ok("LICENSE.md is One's MIT terms", "MIT License" in (bs / "LICENSE.md").read_text(encoding="utf-8"))
        ok("the starter checkout itself is untouched", (kit / "kit.yaml").is_file() and (kit / "frameworks" / "card.md").is_file())
        # The check is a real gate: each kind of leftover is caught.
        for name, make in (
            ("a templates/cofounder-room folder", lambda: (bs / "templates" / "cofounder-room").mkdir()),
            ("a kit.yaml", lambda: (bs / "kit.yaml").write_text("x\n", encoding="utf-8")),
            ("a frameworks/ folder", lambda: (bs / "templates" / "room" / "frameworks").mkdir()),
            ("a kit skill", lambda: (bs / "skills" / "five-filters").mkdir(parents=True)),
            ("the kit maker's name", lambda: (bs / "HELP.md").write_text("By Next Badge.\n", encoding="utf-8")),
            ("the course's name", lambda: (bs / "HELP.md").write_text("From Vibe Founding.\n", encoding="utf-8")),
        ):
            make()
            ok(f"check catches {name}", findings(bs) != [])
            subprocess.run(["rm", "-rf", str(bs)], check=True)
            bundle(src, res, quiet=True)
        ok("and passes again once it's gone", findings(bs) == [])
    # The bundle One actually built, when there is one here.
    built = ROOT / "build" / "app.noindex" / "One.app" / "Contents" / "Resources" / "brain-starter"
    if built.is_dir():
        ok(f"the built app's brain starter is clean ({built.relative_to(ROOT)})", findings(built) == [])
    print("brain starter bundle ok" if fails == 0 else f"brain starter bundle: {fails} failed")
    return 1 if fails else 0


def main(argv: list) -> int:
    if len(argv) == 3 and argv[0] == "bundle":
        return bundle(Path(argv[1]), Path(argv[2]))
    if len(argv) == 2 and argv[0] == "check":
        return check(Path(argv[1]))
    if argv == ["selftest"]:
        return selftest()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
