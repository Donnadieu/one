# Tech debt

## High
- Files over 600 lines (see `tools/lint/baseline.json`): split Model, Views, Floater, Rooms by area.
  Since PER-33 the cap covers Python and shell too, and four of One's engine overlay files are over
  it: `tools/overlay/tools/one_human_step.py` (1,236), `plugins/one-browser-guard/__init__.py` (881),
  `plugins/one-phone-tags/__init__.py` (835), `plugins/one-main-queue/__init__.py` (710).
- Hermes patch (KeePass) until upstreamed to NousResearch/hermes-agent.
- **44 Swift files have no row in the docs/ARCHITECTURE.md table** (`one-lint: architecture-table` in
  `tools/lint/baseline.json`). This is the one worth paying down first: the table is where
  `dependency-direction` and `destructive-fs-area` read a file's layer from, so a file missing from it
  is invisible to both. Pay it down a few rows at a time — the lint names them.

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
  file names had never included it.)
- Deleting files outside an area that owns a folder (`one-lint: destructive-fs-area`, 12 files /
  15 sites in `tools/lint/baseline.json`). The ones worth a look first are the four in UI or state —
  `App.swift`, `BotsManage.swift`, `ModelLearning.swift`, `Helpers.swift` — because that is the shape
  the 0.9.74 "reset onboarding" incident had. The other eight are files with no row in the
  ARCHITECTURE.md table yet, so they'll resolve with the row.
- ruff findings in One's Python (`tools/lint/ext-baseline.json`, 16 in 11 files): unused imports,
  unused locals, f-strings with no placeholder. Check each unused import before deleting it — in the
  engine's overlay files an import can be there to register a plugin.
- The stand-in-engine checks each still carry their own copy of the test-copy + clean-environment
  setup (`tools/corrections-check.sh`, `helpers-check.sh`, `phone-tags-check.sh`,
  `restart-wait-check.sh`). The live ones went onto `tools/engine-check.sh` in PER-33; these were
  left out of that pass on purpose (a fresh bundle id per run, several runs each, a `kill -9` in the
  middle) and `one-lint: engine-check-wrapper` states the skip. Folding them in means teaching
  `engine-check.sh` a per-run id and a per-call support folder.
