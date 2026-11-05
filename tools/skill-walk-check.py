#!/usr/bin/env python3
"""The engine's two skill walks after One's overlay (SkillWalkFix in Sources/LinkGuard.swift).

Usage: skill-walk-check.py <dir with the patched skill_utils.py and prompt_builder.py>
Runs the real patched functions (cut out of the pinned engine's files with ast) on a skills folder that has a link
to the folder it's in, a link to a folder above, a folder linked in from elsewhere, a flat recipe and a recipe in
the older learned/ folder. Each skill must be found exactly once, and the walk must finish.
"""
import ast
import os
import sys
import tempfile
from pathlib import Path

MARK = "# One: skip a folder already walked"
d = sys.argv[1]
fails = 0


def ok(name, cond):
    global fails
    print(("  ✓ " if cond else "  ✗ ") + name)
    fails += 0 if cond else 1


def func(text, name):
    for n in ast.parse(text).body:
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return ast.get_source_segment(text, n)
    return None


src = {f: open(os.path.join(d, f), encoding="utf-8").read() for f in ("skill_utils.py", "prompt_builder.py")}
for f, t in src.items():
    ok(f"{f}: patched once", t.count(MARK) == 1)
    ok(f"{f}: still valid Python", bool(ast.parse(t)))

root = Path(tempfile.mkdtemp())
skills = root / "skills"
for rel in ("flat-recipe", "learned/pitch", "a/one"):
    (skills / rel).mkdir(parents=True)
    (skills / rel / "SKILL.md").write_text("---\nname: x\n---\n")
(root / "elsewhere" / "two").mkdir(parents=True)
(root / "elsewhere" / "two" / "SKILL.md").write_text("---\nname: two\n---\n")
os.symlink(skills, skills / "skills")  # the Nov 4 loop: a link to the folder it's in
os.symlink("..", skills / "a" / "one" / "up")  # a link to a folder above
os.symlink(root / "elsewhere", skills / "linked")  # a folder linked in from elsewhere: still read
want = sorted(["a/one/SKILL.md", "flat-recipe/SKILL.md", "learned/pitch/SKILL.md", "linked/two/SKILL.md"])

g = {"os": os, "Path": Path, "EXCLUDED_SKILL_DIRS": frozenset({".git"}), "SKILL_SUPPORT_DIRS": frozenset({"references"}),
     "file_signature": lambda st: (st.st_mtime_ns, st.st_size)}
exec(func(src["skill_utils.py"], "iter_skill_index_files"), g)
got = sorted(str(p.relative_to(skills)) for p in g["iter_skill_index_files"](skills, "SKILL.md"))
ok("skill_utils: each skill once, flat and learned/ both found, a linked folder still read", got == want)
exec(func(src["prompt_builder.py"], "_build_skills_manifest"), g)
got = sorted(g["_build_skills_manifest"](skills).keys())
ok("prompt_builder: the same, for the skills manifest", got == want)

print("skill walk ok" if fails == 0 else f"skill walk failed: {fails}")
sys.exit(1 if fails else 0)
