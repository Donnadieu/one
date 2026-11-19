# Tech debt

## High
- Files over 600 lines (see `tools/lint/baseline.json`): split Model, Views, Floater, Rooms by area.
  Since PER-33 the cap covers Python and shell too, and four of One's engine overlay files are over
  it: `tools/overlay/tools/one_human_step.py` (1,236), `plugins/one-browser-guard/__init__.py` (881),
  `plugins/one-phone-tags/__init__.py` (835), `plugins/one-main-queue/__init__.py` (710).
- Hermes patch (KeePass) until upstreamed to NousResearch/hermes-agent.
- **44 Swift files have no row in the docs/ARCHITECTURE.md table** (`one-lint: architecture-table` in
  `tools/lint/baseline.json`). **Paid down in PER-33**: all 44 rows were written, so the table now
  names every `Sources/*.swift` file and both doc-derived rules judge all 284 of them (every run
  prints that count). Keep it that way — `one-lint: architecture-table` fails on a file with no row,
  and `one-lint: dependency-direction` now fails closed on one too, rather than skipping it quietly.

## Medium
- Old dead code: `GoogleSignIn` (dev-only), kept until Google sign-in is decided for good.
- No automated test for helpers, voice playback, or the full update swap.
- Dependency-direction debt (see `tools/lint/baseline.json`, rule `dependency-direction`,
  docs/ARCHITECTURE.md rule 6): `Updater.swift`, `Pictures.swift` and `HumanStep.swift` (services)
  call `Model.shared` directly instead of returning a value or taking a closure/delegate — a reverse
  dependency on the state layer above them, grandfathered when the check was added. Pay down by
  threading the needed state/callback in from `Model` instead of reaching up for it.
  (PER-33 note: `Helpers.swift` left this list for free. The rule now reads the layers from the
  ARCHITECTURE.md table, which tags that file `service + UI`, so its five `: View` declarations were
  never a violation; `HumanStep.swift` arrived on it for the same reason — the hand-typed list of 32
  file names had never included it. That is a net +1 on the rule's total, which the ratchet is right
  to stop, so it is recorded as the single `_allow-growth` entry in `tools/lint/baseline.json` with
  the reason in words. **Delete that entry when `HumanStep.swift`'s six call sites are paid down** —
  an allowance nobody needs is one nobody reviews, and `check-baseline.sh` fails if it outlives the
  growth it excuses.)
- Deleting files outside an area that owns a folder (`one-lint: destructive-fs-area`, 12 files /
  15 sites in `tools/lint/baseline.json`). The ones worth a look first are the four in UI or state —
  `App.swift`, `BotsManage.swift`, `ModelLearning.swift`, `Helpers.swift` — because that is the shape
  the 0.9.74 "reset onboarding" incident had. The other eight are files with no row in the
  ARCHITECTURE.md table yet, so they'll resolve with the row.
- Nine `--test-*` modes are reached straight from `App.swift` and run in no venue:
  `--test-folders-fit`, `--test-message-click`, `--test-message-history`, `--test-message-typing`,
  `--test-select`, `--test-shared`, `--test-shelf-copy` (PER-33 wired `--test-panels` and
  `--test-shelf-search` into preflight, which is how the rest were counted). `no-orphan-check`
  enforces reachability for `tools/*-check.*` scripts but nothing does the same for a mode, which is
  the same class of hole one layer in. Worth a rule: every `--test-` string in `Sources/` must be
  named by a venue, with the same `# runs:`-style escape for one that needs this Mac.
- `one-lint: file-length`'s canary pins the 13 words in `JARGON` one per line, so deleting any one of
  them fails `--prove`. Adding a 14th leaves the count at 13 and passes, after which that word could
  be deleted unnoticed. Asserting `len(JARGON) == branches` (or generating the canary from the list)
  would close it; left for now because a rule gaining an alternative is a reviewed change.
- `TestWorld.liveCheck` checks only that `ONE_LIVE_CHECK` looks like a check's file name, not that the
  named check exists and declares itself owner-only — `tools/ci-only.sh` is what verifies that, and
  the Swift side is the second layer. Reading the name from a file the app can check would make both
  layers equally strict.
- The ten live checks that only Omar can run (`make jobs`, `make learning`, the five helper ones,
  `make routinglive`, `make humanwindow`, `make handoffqa`) are *reachable* but not *covered*: they
  need his own Claude subscription, so no runner can have them, and nothing records when one last
  ran green. Worth a small tracked log (date, commit, verdict) that a check can read, so an
  owner-only check whose last green is many commits old says so. Until then, run them by hand before
  a release that touches helpers or routing. Deliberately not a tracked file that every local run
  dirties, which is why this is a follow-up rather than part of PER-33.
- `tools/engine-check.sh`'s library half is exercised on a pull request only through
  `tools/reset-check.sh` (plain exec mode). `--engine-link`, `--test-engine`, `--env`, `--keep`,
  `--expect` and the whole `. engine-check.sh --lib` path are only hit by the owner-only checks above,
  so a typo in one of those branches is found by hand rather than by CI. A `--selftest` that composes
  the `env -i` vector with `/usr/bin/env` standing in for One would cover it in preflight for free.
- The baselines count findings per file, not fingerprints, so swapping one violation for a different
  one in the same file passes. That is on purpose — fingerprints churn on every reformat — and the
  stale-row check is the other half of it (a row kept after its finding went is a failure now). Worth
  revisiting only if a swap is ever seen in review.
- ruff findings in One's Python (`tools/lint/ext-baseline.json`, 16 in 11 files): unused imports,
  unused locals, f-strings with no placeholder. Check each unused import before deleting it — in the
  engine's overlay files an import can be there to register a plugin.
- The stand-in-engine checks each still carry their own copy of the test-copy + clean-environment
  setup (`tools/corrections-check.sh`, `helpers-check.sh`, `phone-tags-check.sh`,
  `restart-wait-check.sh`). The live ones went onto `tools/engine-check.sh` in PER-33; these were
  left out of that pass on purpose (a fresh bundle id per run, several runs each, a `kill -9` in the
  middle) and `one-lint: engine-check-wrapper` states the skip. Folding them in means teaching
  `engine-check.sh` a per-run id and a per-call support folder.
