"""The shrink-only baseline, once, for every linter that has one.

one-lint.py and ext-lint.py both grandfather old debt as {"rule|file": count} and both may only ever
shrink it. That was ~35 lines copied into each, and the copies had already diverged on the subtlest
part: ext-lint refuses to shrink when a linter didn't run, because "nothing found" and "debt paid
down" look identical from the outside. Keeping one Ratchet means neither can grow that hole again.

A count is per file, not a fingerprint, so swapping one violation for a different one in the same
file passes. That is deliberate — fingerprints churn on every reformat — but it is the main way debt
rots in place, so the stale check below is the other half: a baseline row for something that no
longer exists has to go, and the gate says so rather than letting the row sit there as headroom.
"""
import json
import os

# A key starting with "_" is metadata, not a finding: today that is "_allow-growth", where a rule
# whose file set legitimately changed records WHY its total went up, in words a reviewer reads in the
# diff (tools/lint/check-baseline.sh is what reads it). It is deliberately the only way past the
# ratchet, it cannot be added silently, and it has to be deleted once the debt is paid.
META = "_"


def findings(base):
    return {k: v for k, v in base.items() if not k.startswith(META)}


def meta(base):
    return {k: v for k, v in base.items() if k.startswith(META)}


class Ratchet:
    def __init__(self, path, what, refuse=None):
        """refuse(): a reason not to write the file (a linter was skipped), or None when it's safe."""
        self.path = path
        self.what = what
        self.refuse = refuse or (lambda: None)

    def load(self):
        """The whole file, metadata included. Callers that count findings go through findings()."""
        return json.load(open(self.path)) if os.path.exists(self.path) else {}

    def save(self, base):
        json.dump(dict(sorted(base.items())), open(self.path, "w"), indent=1)
        open(self.path, "a").write("\n")

    def _refuse(self, verb):
        why = self.refuse()
        if why is None:
            return False
        print(f"✗ won't {verb} the {self.what} baseline: {why}")
        print("    FIX: make every linter run first (see its own FIX line above), then try again.")
        return True

    def seed(self, counts):
        """--init: grandfather the code as it stands. Rare, and the diff wants reading."""
        if self._refuse("seed"):
            return 1
        self.save({**meta(self.load()), **dict(counts)})
        print(f"Seeded {self.what} baseline: {sum(counts.values())} grandfathered in {len(counts)} entries")
        return 0

    def shrink(self, counts):
        """--update: lock in debt that was paid down. Never grows, and drops rows that are now clean."""
        if self._refuse("shrink"):
            return 1
        base = findings(self.load())
        new = {k: min(v, counts.get(k, 0)) for k, v in base.items() if counts.get(k, 0) > 0}
        self.save({**meta(self.load()), **new})
        print(f"{self.what} baseline: {sum(base.values())} -> {sum(new.values())}")
        return 0

    def gate(self, counts):
        """(what grew, how much was paid down, rows that no longer match anything)."""
        base = findings(self.load())
        grew = sorted(k for k, n in counts.items() if n > base.get(k, 0))
        paid = sum(base.values()) - sum(min(v, counts.get(k, 0)) for k, v in base.items())
        stale = sorted(k for k in base if not counts.get(k))
        return grew, paid, stale

    def report(self, counts, paid, stale):
        """The two lines every linter prints after its findings."""
        if stale:
            print(f"✗ {self.path.split('/')[-1]} has {len(stale)} row(s) for a finding that is gone:")
            for k in stale:
                print(f"    {k}")
            print("    FIX: run the linter with --update. A row kept after its finding went is headroom "
                  "for the next one, and it hides a file that was renamed or deleted.")
        if paid:
            print(f"Debt paid down: {paid}. Run --update to lock it in.")
        return 1 if stale else 0
