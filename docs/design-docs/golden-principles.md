# Golden principles

Each rule names what enforces it. A rule without an enforcer is a gap.

| Rule | Enforced by |
|---|---|
| Files stay under 600 lines | `one-lint: file-length` |
| No hardcoded assistant name in UI | `one-lint: assistant-name` |
| No jargon in UI text | `one-lint: ui-jargon` |
| A helper orb has three looks only: working, needs you, done | `Helper.viewState` + `One --test-helpers` (HelperCheck) |
| Helpers finishing together get one quiet line, never a turn each, never repeated | SayQueue `.helperNews` + helpers-check part `queue` (QueueCheck) |
| The long app notes go once per conversation, not on every message | `NoteCache` + `One --test-helpers` |
| The routines dial says Done, Partly or Didn't run | `Dial.legend` + preflight "Updater" (UpdaterCheck) |
| No broad process kills | `one-lint: broad-kill` |
| No Telegram/WhatsApp | `one-lint: no-messaging` |
| Programs only run from services | `one-lint: process-area` |
| The person's files and settings are production: no test, check or render touches them | `TestWorld.enter()` refuses under the real bundle id and gives a scratch One folder; `one-lint: test-selftest` + `test-copy`; preflight "Your files and settings are production" (real build refuses, `One --test-production`, nothing in Made by or on the shelf went missing) |
| Only the person's own One moves or forgets their Ready for you files and cards | `Env.production` in `Shelf.load`/`Shelf.save`; missing cards kept in `shelfMissing`; preflight `--test-production` |
| Every pop-up wears the same glass and closes with its X, a click outside and Esc | `one-lint: popup-glass` (no `.sheet`/`.popover`/`.alert`/own dim outside `PopupGlass.swift`), preflight glass check (`One --test-glass`, pop-up glass too) |
| Email is never sent by One | `one-lint: no-mail-send` |
| No secrets in source or in the app | `one-lint: no-secrets`, preflight "no keys or tokens bundled" |
| Consistent formatting | `swift-format lint` (`.swift-format`) |
| Old lint debt only shrinks | `tools/lint/check-baseline.sh` |
| Folder lock blocks unapproved folders | preflight "a folder you never approved is blocked" |
| KeePass survives engine installs | preflight "KeePass overlay" checks |
| Engine version is pinned | preflight "Hermes version pinned" + fresh-install check |
| Old copies see updates | preflight "Updater" |
| Screens render | preflight "Screens" |
| Private notes don't leak into shared rooms | `SharedGuard` + preflight "Guards" |
| Experimental connections are off until tested | `ExperimentalGuard` (`skills.disabled`) + preflight "Guards" |
| Complaints are captured | `FrictionLog` + preflight "Guards" |
| The three core jobs work end to end (sort files, inbox draft-only, price watch asks before buying) | `make jobs` (`tools/jobs-check.sh` → `One --test-jobs`) |
| The mail bridge has no send command | `make jobs` ("bridge has no send command") |
| Shipped skills reach every install and never overwrite an edited copy | `BundledSkills` + preflight "Shipped skills" (`One --test-skills`) |
| A NEW folder is only ever added after a yes IN THE CONVERSATION (chat-visible ask, chat-visible yes or a tapped card), logged with who/when/why/how; a folder already allowed before this rule shipped is never dropped, re-asked or at risk from it | `FolderApprovals.grant` is the one function allowed to add a folder (ledger `folder-approvals.json` + `Access.set`); `FolderApprovals.migrateExisting()` grandfathers in everything already on the list, once, unconditionally; `Access.folders` itself is never filtered against the ledger; `Model.tendFolderLedger` flags (never removes) anything that shows up with no ledger entry; preflight "Folder approval ledger" (`One --test-folder-approval`) |
