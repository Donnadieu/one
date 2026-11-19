# Golden principles

Each rule names what enforces it. A rule without an enforcer is a gap.

| Rule | Enforced by |
|---|---|
| Files stay under 600 lines, in every language | `one-lint: file-length` (Swift, Python, shell, workflows, HTML; the vendored engine copies under `tests/fixtures/` are a stated skip) |
| No hardcoded assistant name in UI | `one-lint: assistant-name` |
| No jargon in UI text | `one-lint: ui-jargon` |
| A helper orb has three looks only: working, needs you, done | `Helper.viewState` + `One --test-helpers` (HelperCheck) |
| Helpers finishing together get one quiet line, never a turn each, never repeated | SayQueue `.helperNews` + helpers-check part `queue` (QueueCheck) |
| The long app notes go once per conversation, not on every message | `NoteCache` + `One --test-helpers` |
| The routines dial says Done, Partly, Missed or Didn't work; only a real failure is orange, a routine that ran all its runs moves to Finished | `Dial.legend`, `Dial.alarm`, `Routines.failedRecord` + preflight "Updater" (UpdaterCheck) and "Routines" (`One --test-routines`, RoutinesCheck) |
| No broad process kills | `one-lint: broad-kill` |
| No Telegram/WhatsApp | `one-lint: no-messaging` |
| Programs only run from services | `one-lint: process-area` |
| The person's files and settings are production: no test, check or render touches them | `TestWorld.enter()` refuses under the real bundle id and gives a scratch One folder; `one-lint: test-selftest` + `test-copy`; preflight "Your files and settings are production" (real build refuses, `One --test-production`, nothing in Made by or on the shelf went missing) |
| Only the person's own One moves or forgets their Ready for you files and cards | `Env.production` in `Shelf.load`/`Shelf.save`; missing cards kept in `shelfMissing`; preflight `--test-production` |
| Every pop-up wears the same glass and closes with its X, a click outside and Esc | `one-lint: popup-glass` (no `.sheet`/`.popover`/`.alert`/own dim outside `PopupGlass.swift`), preflight glass check (`One --test-glass`, pop-up glass too) |
| Every note can be put back: hourly instant copies, and putting one back first saves what's there now; pruning never touches a folder not named like a copy | `History` + `HistoryRestore` + preflight "Instant copies" (`One --test-history`) |
| Nothing readable goes to iCloud: the off-Mac copy is locked as it's written, its key only in the Keychain | `Offsite` (aa `-key-value`, temp file in One's folder) + preflight "Instant copies" (`One --test-history`) |
| Email is never sent by One | `one-lint: no-mail-send` |
| No secrets anywhere in the tree, and no file whose name says credential | `one-lint: no-secrets` (every tracked text file, not just `Sources/`) + `one-lint: secret-file` + `.gitignore`, preflight "no keys or tokens bundled" |
| Every check script can be run from somewhere | `one-lint: no-orphan-check` — a `tools/*-check.*` must be run by a workflow or `tools/preflight.sh`, or carry a `# runs: owner-only (make <target>) — <why>` header and have that target |
| One wrapper for the live engine checks, so the setting that isolates the test world can't drift | `tools/engine-check.sh` + `one-lint: engine-check-wrapper` |
| A test never runs on the person's Mac by accident, and only ever in a world of its own | `TestWorld.enter()` (CI, or `ONE_LIVE_CHECK=1` for a live check asked for by name; never the real bundle id, never the real One folder) + `tools/ci-only.sh` |
| Every Swift file has an area in docs/ARCHITECTURE.md, and the lint reads its layers from there | `one-lint: architecture-table`; `dependency-direction` and `destructive-fs-area` both take their file sets from that table, not from a list typed in the lint |
| Deleting files happens where a folder has an owner, never from a view or from state | `one-lint: destructive-fs-area` |
| Every workflow asks for the least it needs, and a third-party action is pinned to a commit | `one-lint: workflow-permissions` + `one-lint: action-pinned` |
| One's Python and shell are linted too | `tools/lint/ext-lint.py` (ruff bug rules, shellcheck warnings) with its own shrink-only baseline |
| Every rule above is proved to still block, not just to exist | `one-lint --prove`: one canary per rule in `tools/lint/canaries/`, in the hook, `make lint` and `rules.yml` |
| The fast rules run on every pull request, a docs-only one included | `.github/workflows/rules.yml` (no `paths-ignore`); `preflight.yml` keeps only formatting, which needs macOS |
| The git hooks are armed, and the hook and `make check` agree on the rules | `tools/hooks-check.sh` (in `make check`, and `--ci` in `rules.yml`) |
| Docs-map integrity is checked in CI, not only on the maintainer's Mac | `tools/knowledge-base-check.sh` in `make check` and in `rules.yml` |
| The slow memory checks run nightly | `.github/workflows/deep-checks.yml` (`tools/sanitizer-check.sh`, `tools/soak-check.sh`) |
| Consistent formatting | `swift-format lint` (`.swift-format`) |
| Old lint debt only shrinks, in both baselines | `tools/lint/check-baseline.sh` on `tools/lint/baseline.json` and `tools/lint/ext-baseline.json`, in the hook, `make lint` and `rules.yml` |
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
