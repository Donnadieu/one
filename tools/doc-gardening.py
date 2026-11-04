#!/usr/bin/env python3
"""
Doc gardening: the recurring "garbage collector" for documentation debt in
this repo (the right-sized equivalent of Forge's harness-engineering skill's
artifact 9, adapted for a Swift app with hand-written judgment-call docs
instead of schema-generated ones — there's nothing here to regenerate, only
links and an index to keep honest).

--check (report; exit non-zero on a hard finding):
    1. Every relative markdown link inside docs/, AGENTS.md and README.md
       resolves to a real file.
    2. docs/INDEX.md links to every file actually present under docs/ (an
       orphan = a doc nobody can discover from the index).
    3. The code-area -> doc mapping in tools/doc-drift-check.py
       (SENSITIVE_AREAS) doesn't itself point at a doc that no longer
       exists — that mapping is the whole mechanism of the doc-drift check,
       so a stale entry there is a silent hole in it.

--fix (mechanically safe repairs only):
    - A broken relative link whose basename matches EXACTLY ONE file
      elsewhere in the repo gets rewritten to that file's real path ("one
      candidate means a rename, not a guess" — per the harness-engineering
      skill's own wording). Zero or multiple candidates are left alone and
      reported instead of guessed.
    - Everything else (orphans, a stale SENSITIVE_AREAS entry, prose that's
      gone stale) is a judgment call: --fix reports it but never guesses.

Usage:
    tools/doc-gardening.py --check
    tools/doc-gardening.py --fix
Exit 0 = clean (or --fix made it clean). Exit 1 = hard findings remain.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK_SOURCES = ["AGENTS.md", "README.md"]  # plus every file under docs/
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)\)")


def repo_root() -> Path:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(out.stdout.strip())


def md_files_to_scan(root: Path):
    files = [root / p for p in LINK_SOURCES if (root / p).exists()]
    files += sorted((root / "docs").rglob("*.md"))
    return files


def extract_relative_links(path: Path):
    """Yield (line_no, link_text, link_target) for relative, in-repo links.

    Skips http(s)/mailto links and pure anchors (#foo); keeps everything
    else, including a #anchor suffix on a real file path (checked up to the
    '#').
    """
    text = path.read_text(encoding="utf-8")
    for line_no, line in enumerate(text.splitlines(), start=1):
        for m in MD_LINK_RE.finditer(line):
            target = m.group(2)
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            yield line_no, m.group(1), target


def resolve_link(doc_path: Path, target: str) -> Path:
    target_path = target.split("#", 1)[0]
    return (doc_path.parent / target_path).resolve()


def find_broken_links(root: Path):
    """Return list of dicts: doc, line, text, target, resolved."""
    broken = []
    for doc in md_files_to_scan(root):
        for line_no, text, target in extract_relative_links(doc):
            resolved = resolve_link(doc, target)
            if not resolved.exists():
                broken.append(
                    {
                        "doc": doc.relative_to(root),
                        "line": line_no,
                        "text": text,
                        "target": target,
                        "resolved": resolved,
                    }
                )
    return broken


def find_index_orphans(root: Path):
    """Files under docs/ unreachable by following links starting from
    docs/INDEX.md (directly, or transitively through another linked doc —
    e.g. INDEX.md -> exec-plans/README.md -> tech-debt-tracker.md all
    counts as linked, not just a direct INDEX.md -> file hop)."""
    index = root / "docs" / "INDEX.md"
    if not index.exists():
        return []

    def doc_targets(doc: Path):
        text = doc.read_text(encoding="utf-8")
        targets = set()
        for line_no, link_text, target in extract_relative_links(doc):
            resolved = resolve_link(doc, target)
            if resolved.exists():
                targets.add(resolved)
        # Also catch doc paths only mentioned as inline code (`tools/x.py`
        # style, used for non-markdown entries like the doc-drift script).
        # Restrict to single-line, path-shaped spans so a stray/unclosed
        # backtick elsewhere in a table can't swallow the rest of the file.
        for m in re.finditer(r"`([\w./-]{1,80})`", text):
            candidate = root / m.group(1)
            if "/" in m.group(1) and candidate.is_file():
                targets.add(candidate.resolve())
        return targets

    reachable = {index.resolve()}
    frontier = [index]
    while frontier:
        doc = frontier.pop()
        for target in doc_targets(doc):
            if target not in reachable:
                reachable.add(target)
                if target.suffix == ".md" and target.exists():
                    frontier.append(target)

    orphans = []
    for doc in sorted((root / "docs").rglob("*.md")):
        if doc.resolve() not in reachable:
            orphans.append(doc.relative_to(root))
    return orphans


def find_stale_sensitive_area_docs(root: Path):
    """Entries in doc-drift-check.py's SENSITIVE_AREAS pointing at a doc
    that no longer exists — a silent hole in that check's own mapping."""
    script = root / "tools" / "doc-drift-check.py"
    if not script.exists():
        return []
    sys.path.insert(0, str(script.parent))
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location("doc_drift_check", script)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mapping = getattr(mod, "SENSITIVE_AREAS", {})
    except Exception as e:  # pragma: no cover - defensive, never crash --check
        print(f"doc-gardening: couldn't import doc-drift-check.py's mapping ({e}); skipping")
        return []
    finally:
        sys.path.pop(0)

    missing = []
    for src, docs in mapping.items():
        for d in docs:
            if not (root / d).exists():
                missing.append((src, d))
    return missing


def basename_candidates(root: Path, basename: str):
    return [
        p
        for p in root.rglob(basename)
        if ".git" not in p.parts and "build" not in p.parts and "node_modules" not in p.parts
    ]


def do_check(root: Path) -> int:
    hard_findings = 0

    broken = find_broken_links(root)
    if broken:
        print(f"✗ {len(broken)} broken relative link(s):")
        for b in broken:
            print(f"    {b['doc']}:{b['line']}: [{b['text']}]({b['target']}) -> no such file")
        hard_findings += len(broken)
    else:
        print("✓ every relative markdown link in docs/, AGENTS.md, README.md resolves")

    orphans = find_index_orphans(root)
    if orphans:
        print(f"✗ {len(orphans)} doc(s) under docs/ with no inbound link from docs/INDEX.md:")
        for o in orphans:
            print(f"    {o}")
        hard_findings += len(orphans)
    else:
        print("✓ docs/INDEX.md links to every file under docs/")

    stale_mapping = find_stale_sensitive_area_docs(root)
    if stale_mapping:
        print(
            "✗ tools/doc-drift-check.py's SENSITIVE_AREAS points at doc(s) that don't exist:"
        )
        for src, d in stale_mapping:
            print(f"    {src} -> {d} (missing)")
        hard_findings += len(stale_mapping)
    else:
        print("✓ tools/doc-drift-check.py's SENSITIVE_AREAS maps only to real doc files")

    if hard_findings:
        print(f"\ndoc-gardening --check: {hard_findings} hard finding(s)")
        return 1
    print("\ndoc-gardening --check: clean")
    return 0


def do_fix(root: Path) -> int:
    broken = find_broken_links(root)
    fixed = []
    left = []

    # Group by doc so we rewrite each file's text once.
    by_doc = {}
    for b in broken:
        by_doc.setdefault(b["doc"], []).append(b)

    for rel_doc, items in by_doc.items():
        doc_path = root / rel_doc
        text = doc_path.read_text(encoding="utf-8")
        changed = False
        for b in items:
            target = b["target"]
            target_path, _, anchor = target.partition("#")
            basename = Path(target_path).name
            candidates = basename_candidates(root, basename)
            if len(candidates) == 1:
                new_rel = Path(
                    "." if candidates[0].parent == doc_path.parent else ""
                )
                new_target_path = relpath(doc_path.parent, candidates[0])
                new_target = new_target_path + (f"#{anchor}" if anchor else "")
                old_link = f"[{b['text']}]({target})"
                new_link = f"[{b['text']}]({new_target})"
                if old_link in text:
                    text = text.replace(old_link, new_link, 1)
                    changed = True
                    fixed.append((rel_doc, b["line"], target, new_target))
                else:
                    left.append((rel_doc, b["line"], target, "link text changed since scan"))
            else:
                reason = "no candidate by basename" if not candidates else (
                    f"{len(candidates)} candidates by basename (ambiguous)"
                )
                left.append((rel_doc, b["line"], target, reason))
        if changed:
            doc_path.write_text(text, encoding="utf-8")

    if fixed:
        print(f"Fixed {len(fixed)} link(s):")
        for rel_doc, line, old, new in fixed:
            print(f"    {rel_doc}:{line}: {old} -> {new}")
    else:
        print("No mechanically-safe link fixes to make.")

    if left:
        print(f"\nLeft {len(left)} finding(s) for a human (ambiguous or not link-shaped):")
        for rel_doc, line, target, reason in left:
            print(f"    {rel_doc}:{line}: {target} ({reason})")

    orphans = find_index_orphans(root)
    if orphans:
        print(
            f"\n{len(orphans)} doc(s) under docs/ have no inbound link from docs/INDEX.md "
            "(left for a human — adding the right one-line description is a judgment call):"
        )
        for o in orphans:
            print(f"    {o}")

    stale_mapping = find_stale_sensitive_area_docs(root)
    if stale_mapping:
        print(
            "\ntools/doc-drift-check.py's SENSITIVE_AREAS points at missing doc(s) "
            "(left for a human — removing or redirecting a mapping entry is a judgment call):"
        )
        for src, d in stale_mapping:
            print(f"    {src} -> {d}")

    # Re-run check logic (without re-scanning broken links a second time
    # from scratch is unnecessary here; just report final state honestly).
    remaining = len(left) + len(orphans) + len(stale_mapping)
    if remaining:
        print(f"\ndoc-gardening --fix: {remaining} finding(s) still need a human")
        return 1
    print("\ndoc-gardening --fix: clean")
    return 0


def relpath(from_dir: Path, to_file: Path) -> str:
    try:
        rel = to_file.resolve().relative_to(from_dir.resolve())
        return str(rel)
    except ValueError:
        import os

        return os.path.relpath(to_file.resolve(), from_dir.resolve())


def main():
    args = sys.argv[1:]
    root = repo_root()
    if "--fix" in args:
        return do_fix(root)
    if "--check" in args:
        return do_check(root)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
