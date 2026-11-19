# Golden principles

Each rule names what enforces it. A rule without an enforcer is a gap.

The names are checked both ways: `tools/knowledge-base-check.sh` fails when a row here names a
`one-lint:` rule that doesn't exist, and when a rule exists that no doc names. This table is read,
not just written.

| Rule | Enforced by |
|---|---|
| Files stay under 600 lines, in every language | `one-lint: file-length` (Swift, Python, shell, workflows, HTML; the vendored engine copies under `tests/fixtures/` are a stated skip) |
| A file already over the cap only ever gets shorter | `one-lint: file-bloat` — its count is how far over the cap it is, so the shrink-only baseline can't let a grandfathered 1,236-line file reach 10,000 |
| No hardcoded assistant name in UI | `one-lint: assistant-name` |
| No jargon in UI text | `one-lint: ui-jargon` |
| A helper orb has three looks only: working, needs you, done | `Helper.viewState` + `One --test-helpers` (HelperCheck) |
| Helpers finishing together get one quiet line, never a turn each, never repeated | SayQueue `.helperNews` + helpers-check part `queue` (QueueCheck) |
| The long app notes go once per conversation, not on every message | `NoteCache` + `One --test-helpers` |
| The routines dial says Done, Partly, Missed or Didn't work; only a real failure is orange, a routine that ran all its runs moves to Finished | `Dial.legend`, `Dial.alarm`, `Routines.failedRecord` + preflight "Updater" (UpdaterCheck) and "Routines" (`One --test-routines`, RoutinesCheck) |
| No broad process kills | `one-lint: broad-kill` |
| No Telegram/WhatsApp | `one-lint: no-messaging` |
| Programs only run from services | `one-lint: process-area` |
| The person's files and settings are production: no test, check or render touches them | `TestWorld.enter()` refuses under the real bundle id and gives a scratch One folder; `one-lint: test-selftest` + `one-lint: test-copy`; preflight "Your files and settings are production" (real build refuses, `One --test-production`, nothing in Made by or on the shelf went missing) |
| Only the person's own One moves or forgets their Ready for you files and cards | `Env.production` in `Shelf.load`/`Shelf.save`; missing cards kept in `shelfMissing`; preflight `--test-production` |
| Every pop-up wears the same glass and closes with its X, a click outside and Esc | `one-lint: popup-glass` (no `.sheet`/`.popover`/`.alert`/own dim outside `PopupGlass.swift`), preflight glass check (`One --test-glass`, pop-up glass too) |
| After their yes a person gets a real Chrome window, never the live view | `one-lint: human-window` — only `Model.shared.showHumanStep(a)` opens it, which falls back to the live view itself |
| Every note can be put back: hourly instant copies, and putting one back first saves what's there now; pruning never touches a folder not named like a copy | `History` + `HistoryRestore` + preflight "Instant copies" (`One --test-history`) |
| Nothing readable goes to iCloud: the off-Mac copy is locked as it's written, its key only in the Keychain | `Offsite` (aa `-key-value`, temp file in One's folder) + preflight "Instant copies" (`One --test-history`) |
| Email is never sent by One | `one-lint: no-mail-send` |
| No secrets anywhere in the tree, and no file whose name says credential | `one-lint: no-secrets` (every tracked text file, not just `Sources/`) + `one-lint: secret-file` + `.gitignore`, preflight "no keys or tokens bundled" |
| Every check script can be run from somewhere | `one-lint: no-orphan-check` — a `tools/*-check.*` must be run by a workflow or `tools/preflight.sh`, or carry a `# runs: owner-only (make <target>) — <why>` header and have that target |
| One wrapper for the live engine checks, so the setting that isolates the test world can't drift | `tools/engine-check.sh` + `one-lint: engine-check-wrapper` |
| A test never runs on the person's Mac by accident, and only ever in a world of its own | `TestWorld.enter()` (CI, or `ONE_LIVE_CHECK=<that check's file name>`; never the real bundle id, never the real One folder — neither refusal has an opt-in) + `tools/ci-only.sh`, which unlocks **one named** script that declares itself `# runs: owner-only`. `ONE_LIVE_CHECK=1` used to unlock all twenty scripts that source it, `tools/preflight.sh` among them |
| Every Swift file has an area in docs/ARCHITECTURE.md, and the lint reads its layers from there | `one-lint: architecture-table` (an unknown area word is reported too); `one-lint: dependency-direction` and `one-lint: destructive-fs-area` both take their file sets from that table, not from a list typed in the lint, and both FAIL CLOSED on a file with no row |
| Dependencies point one way: UI → Model → services → Env/foundation | `one-lint: dependency-direction` (no `Model.shared` and no `: View` in a foundation or service file). Narrowing it by retagging a file in the docs shows up: every run prints how many files each of the two doc-derived rules judges, and `tools/doc-drift-check.py` fails when a file's Area changes without the file |
| Deleting files happens where a folder has an owner, never from a view or from state | `one-lint: destructive-fs-area` |
| Every workflow asks for the least it needs, and a third-party action is pinned to a commit | `one-lint: workflow-permissions` + `one-lint: action-pinned` |
| No workflow input is pasted into a shell command | `one-lint: workflow-run-input` — a `${{ … }}` in a `run:` block is substituted before bash parses the line, so it goes through `env:` and is read as `"$VAR"` |
| One's Python and shell are linted too | `tools/lint/ext-lint.py` (ruff bug rules; shellcheck at **info**, because every bug class it looks for — unquoted expansions, `A && B \|\| C`, an ignored `cd` — is info-level and `-S warning` found none of them) with its own shrink-only baseline. A linter that is missing, that exits with an error, or that is on another version is a refusal, never a clean tree |
| Every rule above is proved to still block, not just to exist | `one-lint --prove`: one canary per rule in `tools/lint/canaries/`, in the hook, `make lint` and `rules.yml`. It asserts the rule's own file selector matches the canary's path (a rule wired to zero files used to report "proved to block"), and a canary's `--allow--` block must come back clean, so a rule can't be narrowed down to its own canary |
| The fast rules run on every pull request, a docs-only one included | `.github/workflows/rules.yml` (no `paths-ignore`); `preflight.yml` keeps only formatting, which needs macOS |
| The git hooks are armed, and the hook, `make check` and `rules.yml` agree on the rules | `tools/hooks-check.sh` (in `make check`, and `--ci` in `rules.yml`). It reads all three files and compares the gates as sets — nothing is enumerated, so a step deleted from any one of them turns red. The only hand-written lists are the differences that are on purpose, each with its reason |
| Docs-map integrity is checked in CI, not only on the maintainer's Mac | `tools/knowledge-base-check.sh` in `make check` and in `rules.yml` |
| The slow memory checks run nightly | `.github/workflows/deep-checks.yml` (`tools/sanitizer-check.sh`, `tools/soak-check.sh`) |
| Consistent formatting | `swift-format lint` (`.swift-format`), in the hook, `make check` and `preflight.yml` (it needs macOS, so it is the one fast rule not in `rules.yml`) |
| Every commit is Donnadieu's, and signed | `tools/check-identity.sh` — the config in the hook and `make check`, the whole commit range on push and in `rules.yml` (on a push to main too, not only on a pull request). A range git can't resolve is a failure, not a pass. **Signatures** are verified by the pre-push hook and by GitHub's own "Require signed commits" on `main`: CI has no copy of the key, so `--ci` checks author and committer only |
| Old lint debt only shrinks, in every baseline | `tools/lint/check-baseline.sh --all` (globs `tools/lint/*baseline.json`, so a third one is guarded the day it is added), in the hook, `make lint` and `rules.yml`. A **rule** gets one seed; a new file or a rename under an existing rule does not, and a per-rule total may only fall. A ref it can't resolve is a failure, not a pass |
| Folder lock blocks unapproved folders | preflight "a folder you never approved is blocked" |
| KeePass survives engine installs | preflight "KeePass overlay" checks |
| Engine version is pinned | preflight "Hermes version pinned" + fresh-install check |
| Old copies see updates | preflight "Updater" |
| Screens render | preflight "Screens" |
| Private notes don't leak into shared rooms | `SharedGuard` + preflight "Guards" |
| A shortcut that points to itself or a folder above it never survives a launch; the engine's skill walks never loop | `LinkGuard` + `SkillWalkFix` + preflight (`One --test-link-guard`, `tools/skill-walk-check.py` on the pinned engine's files) |
| Privacy comes from room.yaml, never a folder name: a private room is never offered for sharing or put in the engine's recipe list | `RoomPrivacy` + `LearnedDirs` + preflight (`One --test-rooms-privacy`) |
| Experimental connections are off until tested | `ExperimentalGuard` (`skills.disabled`) + preflight "Guards" |
| A search that names no room never looks in a private room (its index file isn't even opened) or a `confidential/` folder | `BrainSearch.rooms` + `BrainIndex.files` + preflight "Brain search" (`One --test-search`) |
| Corrections are captured ("No…", "I don't see it", "Where is…") | `FrictionLog` via `Corrections` + preflight "Guards" |
| A night of learning stays inside its limits and can be undone (suggestions only = nothing changed; at most 5 recipes, 1 change each; never a private or shared room) | `ImproveNight.end`/`undo` + preflight "Nightly review" (`One --test-nightly`) |
| The engine's own after-job learning is capped (5 a day, 1 per recipe) | engine plugin `one-learning-cap` (`LearningCap`) + preflight `tools/learning-cap-check.py` |
| A fresh install gets brain, recipes, index, first copy, nightly routine and front page with no questions and no git | `.github/workflows/fresh-install.yml` (`One --test-first-launch`) |
| The score only reads the engine's history, and never shows a private conversation | `ReadOnlyDB` (read-only, query_only) + `ImprovePrivate` + preflight "Improve" (`One --test-improve`) |
| The three core jobs work end to end (sort files, inbox draft-only, price watch asks before buying) | `make jobs` (`tools/jobs-check.sh` → `One --test-jobs`): a live check, so the target sets `ONE_LIVE_CHECK=1` and it runs on the owner's Mac with his own engine. It refused everywhere until PER-33, which is why `no-orphan-check` now exists |
| The mail bridge has no send command | `make jobs` ("bridge has no send command"), same live check as the row above |
| Shipped skills reach every install and never overwrite an edited copy | `BundledSkills` + preflight "Shipped skills" (`One --test-skills`) |
| A NEW folder is only ever added after a yes IN THE CONVERSATION (chat-visible ask, chat-visible yes or a tapped card), logged with who/when/why/how; a folder already allowed before this rule shipped is never dropped, re-asked or at risk from it | `FolderApprovals.grant` is the one function allowed to add a folder (ledger `folder-approvals.json` + `Access.set`); `FolderApprovals.migrateExisting()` grandfathers in everything already on the list, once, unconditionally; `Access.folders` itself is never filtered against the ledger; `Model.tendFolderLedger` flags (never removes) anything that shows up with no ledger entry; preflight "Folder approval ledger" (`One --test-folder-approval`) |
| The front page (USER.md, MEMORY.md) is generated from the brain and live Connections, never the store; the assistant's new memory lines are filed into `assistant/this-mac.md` before a rebuild, nothing from a room goes on it | `FrontPage` + preflight "Front page and recipe filer" (`One --test-front-page`) |
| New recipes the assistant saves move into the brain (their room, or `assistant/skills`), never into a shared room, never a built-in, always undoable | `SkillFiler` + preflight "Front page and recipe filer" (`One --test-front-page`) |
| A standing goal (`/goal`) is the engine's own loop; Stop pauses it (no next turn starts by itself), its turn budget grows only while its progress count moves and never passes the ceiling (500), it pauses when it stalls, a question to them pauses it as waiting for them (an answer picks it back up), and every goal carries the stop-when yes rule its judge reads | overlays `tools/overlay/acp_adapter/one_goals.py` + `tools/overlay/hermes_cli/one_goal_progress.py` (`Installer.applyGoals`) + preflight "Standing goals" (`tools/goal-overlay-check.py`, `tools/goal-progress-check.py`, `One --test-goals`) + fresh-install workflow (`tools/goal-engine-check.sh`, real engine, stand-in model) |
| Home stays smooth: a keystroke redraws only the ask box; a clock (`TimelineView`) wraps only the small picture that moves, never a column, a constellation or a screen; streamed words reach the model a few times a second in one change; nothing on a redraw reads a file | `AskBox`/`AskDraft`, `BotMoon.live`, `HelperMotion`, `BotThreads`, `HelperStream` + CI workflow `smooth` (`One --test-smooth`, optimized build, budgets in `SmoothCheck.Budget`) |
