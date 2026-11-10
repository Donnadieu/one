# Five safety features: One that can run unattended (and later in the cloud)

Design doc, Nov 9 2026. Code read at **v0.9.101** (tag `03b40ee`, same tree as `main` at `5b574dc`).
Engine read at One's pinned Hermes `bf0203a` (`Support/One/engine`). Nothing here is built yet.
Screens: `docs/design/safety-*.jpg` (two directions, made in Claude Design, project "One Safety Features") and the captioned PDF `Made by Iris/2026-11-09 One safety features - designs.pdf`.

## In plain words (for Omar)

1. **Stop means stop.** Today Stop ends the helper's current turn and nothing else. Its test runs keep going in
   the background, and when one finishes the engine wakes the helper up again by itself. That's what happened
   to Finish NotArc: stopped at 11:21, woke up 1 second later, sent out 5 new sub-helpers at 11:33. The fix:
   stopping a helper stops its whole family (sub-helpers, background programs, test apps, dev servers), and
   nothing can wake it up again. The orb says "Stopping…" until every piece is really gone.
2. **A budget per job.** Each helper gets a share of the week (5% by default, 10% for a goal, editable). One
   shows what each job used, warns at 80%, and pauses it at 100% with "Give it 5% more", "Switch to
   <other account>" or "Stop it", one tap each.
3. **A health watchdog.** Every 30 seconds One looks at memory, swap, free disk and stray programs. It cleans
   up what's clearly its own (a dev server a stopped helper left behind) and tells you in plain words about
   the rest. It never touches your own apps or Docker without a yes.
4. **One helper at a time on a repo's main.** Every repo job gets its own copy (worktree), and putting work
   onto `main` waits its turn. The orb says "Waiting for Forge Desktop's main · 2nd in line".
5. **Hand-offs from the phone.** When a helper hits a sign-in, a code or a robot check and you're away, One
   sends a Telegram link that opens just that one page, live, on your phone. You tap through it, the helper
   carries on. The link works once, on one phone, for 10 minutes, and every use is logged.

Plus a small one first, which you asked for tonight: **tests and renders can never touch your real settings**
(a test run wrote "Elias" into them at 9:58 PM and hid new results on Ready for you).

**Build order:** 0 Tests can't touch real settings → 1 Stop means stop (a bug, and 2, 3 and 4 lean on it) →
2 Budgets → 3 Watchdog → 4 Repo turns → 5 Phone hand-offs. One PR each.

---

## 1. Stop means stop

### What happened on Nov 9 (from `hermes/state.db` and `hermes/logs/agent.log`)

Helper "Finish NotArc feature parity and release" = engine session `local-190b2637…` (started 09:49:59).

| Time | What the logs show |
|---|---|
| 10:17 to 10:39 | 10 sub-helpers dispatched (`delegate_task`, async), plus several `selftest.sh … NotArc.app` runs as **background** terminal processes (`proc_999090c2ca2b`, `proc_edf1347a1d4f`, `proc_39fbabc045f0`, …). |
| 11:21:35 | Stop arrives: `Interrupt requested (hard): explicit stop requested` + `parent delegation ended`. All 10 sub-helpers' commands return `[Command interrupted]` (exit 130). The parent turn ends `interrupted_by_user`. **So far correct.** |
| 11:21:36 | 1 s later: `inbound message … msg='[IMPORTANT: Background process proc_edf1347a1d4f completed normally…'`. The gateway injects the finished background process as a new message and **starts a fresh turn on the stopped session**. |
| 11:21 to 11:28 | That turn runs 12 API calls on Opus, then another completion (`proc_82a21d4c5bfb`) starts another turn. |
| 11:33:03 | The woken turn calls `delegate_task` with 5 new tasks. 5 new sub-helpers start (`20261109_113303_*`), each starting new self-test runs (the windows Omar saw). |
| 11:47:13 | Iris's `[tell-helper | /goal stop]` lands; the parent stops its own sub-helpers. Completions keep arriving until 11:48:05 (`proc_bc0b2a2aaffe`, `proc_999090c2ca2b`, then two killed by hand with SIGTERM). |

Usage of that one tree: 16 sessions, 195 M cache-read, 7.0 M cache-write, 1.2 M output tokens. By the same
price-weighted count it is the biggest job in One's last 7 days (6.9% of everything One itself sent to Anthropic;
the account meter's 27% also counts Claude Code, Claude Design and everything else on that login).

### Root cause

Not the sub-helpers: the engine did interrupt them. Three gaps:

1. **Background processes survive Stop.** One's Stop is `session/cancel` (`Sources/Engine.swift:467`, called from
   `Model.stopHelper`, `Sources/ModelChat.swift:567-572`). The engine's ACP adapter turns that into
   `prompt.cancel` / `session.interrupt` for the running turn only (`engine/acp_adapter/gateway_server.py:414-449`).
   The engine already has a per-session "kill my background processes" call, `process.stop`
   (`engine/gateway/session_ancillary.py:356-371`, which also interrupts async delegations), but nothing in
   One's path ever calls it.
2. **A stopped session can be woken up.** When a surviving background process finishes (or matches a watch
   pattern), `gateway/run.py:3024` formats an `[IMPORTANT: …]` message and the gateway runs it as a new turn on
   that session. Nobody checks that the person stopped it. One has no prompt open for it, so those turns are
   invisible: the orb said "Stopped" for 26 minutes while it worked.
3. **Programs nobody tracks.** Even `process.stop` only reaches what the engine's process registry started for
   that exact session. It misses: processes started by sub-helper sessions (owned by the child's id), apps
   launched with `open` (LaunchServices starts them as children of launchd), and daemons that double-fork
   (reparented to pid 1, e.g. dev servers). That is the ~90 processes Iris killed by hand.

Smaller ones found on the way:
- `HelperTrail.stopByYou` (`Sources/HelperTrail.swift:73-83`) only asks for a cancel when the helper was
  `working`; a helper in `needsYes` or paused gets no engine call at all, so its processes stay.
- The goal overlay pauses the goal on Stop (`tools/overlay/acp_adapter/one_goals.py:400-415`), but completion
  turns aren't goal turns, so the pause didn't matter.

### Design

**One word for it: a helper's tree.** The tree of helper H = its engine session, every session whose
`parent_session_id` chain leads to it (sub-helpers, theirs), every process any of those started, and anything
running from H's own folders.

**Stopping = fence, then sweep, then verify.**

1. **Fence (engine overlay, new `tools/overlay/acp_adapter/one_stop.py`, installed next to `one_goals.py`).**
   On `session/cancel` with `_meta.one.tree=true`:
   - write `guard/stopped/<root sid>` (One's guard dir, engine-readable like `guard/look-only/`);
   - `refuse_for_session(...)` for the root and every child session (`tools/async_delegation.py:1292`), so no
     new delegation can start;
   - patch the gateway's completion injector (`gateway/run.py:3024` and the watch-pattern path) to drop, not
     run, an `[IMPORTANT: …]` message for any session in `guard/stopped/` (logged as `one stop: dropped wake-up`);
   - pause the goal (as today), then `prompt.cancel` / `session.interrupt` the running turn (as today).
   A new message from the person in that thread (or "Start again") removes the fence, same rule as look-only.
2. **Sweep (engine side).** `process.stop` for the root and for each child session (the existing RPC, called per
   session from the overlay), then `interrupt_for_session` for each. That reaches everything the registry knows,
   including `persist_on_release` jobs.
3. **Sweep (One side, new `Sources/JobTree.swift`).** One keeps a **process ledger per helper**: every 5 s while
   a helper works, it walks the process table with libproc (`proc_listallpids`, `proc_pidinfo` with
   `PROC_PIDTBSDINFO` for ppid/pgid and `PROC_PIDVNODEPATHINFO` for the working folder, `proc_pidpath`; the
   pattern `HumanCheck.mainChrome` already uses at `Sources/HumanCheck.swift:174`) and records every process
   that is
   - a descendant of a process the engine's registry lists for any session in the tree
     (`process.list`), or
   - running from, or with its working folder inside, the helper's own folders: its worktree(s)
     (`HelperRepos`), `Support/One/work/<project>` folders it created, or a build product inside them
     (`…/build/Release/NotArc.app`).
   Being in the ledger while it was alive is what makes a later orphan (ppid 1) still "ours". On stop, One sends
   SIGTERM to every live ledger pid (process groups first), waits 5 s, then SIGKILL, and quits apps from the
   ledger with `NSRunningApplication.terminate()` then `forceTerminate()`.
   Tested on this Mac: libproc gives ppid, session and the working folder of other processes from inside
   One's sandbox. Environment variables of other processes are **not** readable on macOS (KERN_PROCARGS2
   returns no env), so tagging by `HERMES_SESSION_ID` doesn't work; the ledger + folder rule replaces it.
4. **Verify.** The helper shows **Stopping…** (with "3 programs left") until the tree is empty: no running turn
   in any of its sessions (`sessions.last_activity_at` stops moving and no admission is open), no live ledger
   pid, no async delegation in an active state. Then **Stopped**. If something is still alive after 60 s, the
   card says what in plain words ("NotArc test app won't close") with **Force stop** (SIGKILL) and logs it.
5. **Never:** another helper's tree, the main chat, routines, the engine/gateway, One's hidden browsers
   (`BrowserKeeper` ports), the person's own apps (anything not in the ledger). A process in two trees (shared
   dev server) is left running and named in the card.

**Stop all** does the same for each working helper in parallel. **Pausing for an update/folder** is not a stop:
no fence, no sweep (unchanged, `HelperStop.pauseForUpdate`, `Sources/HelperStop.swift:54`).

### Data and code changes (file:line at v0.9.101)

| Where | Change |
|---|---|
| `Sources/Helpers.swift:14-41` (`struct Helper`) | `stopping: Date?` (fence sent, sweep not finished), `leftovers: [String]?` (plain names still alive). New state word "stopping" in `HelperStop.word` (`Sources/HelperStop.swift:73`) and `status` (`Sources/HelperConstellation.swift:101`). |
| `Sources/ModelChat.swift:567-572` (`stopHelper`) | Always fence the tree, also for `needsYes`/paused (fixes `HelperTrail.stopByYou` only cancelling `working`, `Sources/HelperTrail.swift:74`); then `JobTree.stop(helper)`; state → `stopping` until `JobTree.empty`. |
| `Sources/Engine.swift:467` (`cancel(session:)`) | Default parameter `tree: Bool = false` adds `_meta: {one: {tree: true}}` (Engine.swift is at 599 lines: extend, don't add a func). |
| New `Sources/JobTree.swift` | ledger (`Support/One/helpers/<id>.procs.json`), the libproc walk, `stop`, `empty`, plain names for programs ("NotArc test app", "Rails server"). |
| `Sources/App.swift:173-180` (1 s loop) | `tendJobTrees()` every 5 s while any helper works or stops. |
| New `tools/overlay/acp_adapter/one_stop.py` | the fence, per-session `process.stop`, dropping wake-ups for fenced sessions. Installed by `Installer.applyGoals` next to `one_goals.py`. |
| `Sources/HelperStop.swift` | `[stop-helper:]` and the orb's Stop go through the same path (they already call `stopHelper`). |
| `docs/ARCHITECTURE.md` | rows for JobTree.swift, one_stop.py. |

### Mac vs cloud

- **Mac:** as above (libproc, NSRunningApplication).
- **Cloud (Fly, Linux):** the engine's registry already runs each background command in its own systemd scope
  and stops the whole cgroup (`tools/process_registry.py:2141-2166`, `_stop_scope`). The ledger uses `/proc`
  instead of libproc (same rules: descendants + working folder). No GUI apps there, so no NSRunningApplication.

### Tests

- `One --test-stop-tree` (new, in preflight, stand-in engine `tools/fake-engine.py` extended): a helper with 2
  sub-sessions, 3 background processes, one double-forked `sleep` (reparented to pid 1), one app-like process
  started from the helper's worktree; Stop → orb "stopping" → all gone within 10 s → "stopped".
- **The Nov 9 replay:** a background process finishes 1 s after Stop and its completion is injected →
  the overlay drops it (log line), no new turn, `sessions.last_activity_at` unchanged for 60 s.
- Real engine (`fresh-install` workflow, stand-in model): `delegate_task` with 2 async children each running
  `terminal(background=true) sleep 120`; Stop; assert no child turn and no `sleep` left; a new message from
  "the person" lifts the fence and the helper answers.
- Negative: another helper's processes, a routine's process and a hidden browser are still alive after Stop all.
- `needsYes` helper with a background process: Stop kills it.

---

## 2. A usage budget per job

### Problem

A job can burn a big share of the plan's week with nobody watching. Nov 9: the NotArc goal alone was about
27% of the week by the account meter. One shows no usage at all today; the only signal is the engine's
failover between accounts, which One notices after the fact (`Model.checkAccountLimit`,
`Sources/LimitBanner.swift:17`, from the multiple-accounts work in 0.9.101, PR #106).

### Design

- **Every helper and goal has a budget**, as a share of the AI plan's week: default 5% for a helper, 10% for a
  goal (`/goal` or a "Goal:" job), main chat and routines none. The main chat can set one ("up to 10% of the
  week") and the person can change it in the helper's card (tap the number: 5 / 10 / 20 / No limit).
  Engine-free text form for the main assistant: `[helper: Title | Budget 10%: …]` / `Goal (50 turns, 10%): …`,
  parsed like the turn limit is today.
- **Measure (two layers):**
  1. *Exact per job, from `hermes/state.db`:* sum `input_tokens`, `output_tokens`, `cache_read_tokens`,
     `cache_write_tokens` over the helper's session and every session below it (recursive
     `parent_session_id`, the same query that gave the Nov 9 numbers above). Weight them like the price list
     (input 1, output 5, cache write 1.25, cache read 0.1) into **units**. Read-only, every 30 s, indexed by
     `parent_session_id`.
  2. *The real meter, per account:* the engine already reads the account's own windows
     (`engine/agent/account_usage.py:844-871`: Anthropic `five_hour` and `seven_day` utilization with reset
     times; Codex has the same). One reads it through the engine's `/usage` (served through One's link) every
     5 minutes while anything works. **Calibration:** units per 1% of the week = units One sent between two
     readings ÷ the change in `seven_day` %. Kept as a rolling median per account in `Support/One/usage.json`.
     A job's share = its units ÷ that number. Until there's a calibration (fresh install), the card says
     "about" and uses a stored default.
  The account meter also counts use outside One (Claude Code, claude.ai), so a job's share is One's own use,
  and the week line under the main orb shows the real meter.
- **Warn and pause:**
  - 80% of a job's budget: one line in its thread and the orb gets an amber arc ("Finish NotArc has used 8% of
    its 10%").
  - 100%: One **pauses** it (the fence from feature 1, without killing its processes: cancel the turn, pause
    the goal, drop wake-ups). Its orb turns orange, "Used its 10% · paused", and the card offers one tap each:
    **Give it 10% more**, **Switch to <other account>** (only when another account for that AI is signed in),
    **Stop it**.
  - Account level: at 80% of the week (real meter) one line under the main orb, once; at 95% every helper over
    half its budget pauses, the rest keep going.
- **Switch to <other account>** reuses the multiple-accounts work: `Accounts.makeDefault(provider, entryID:)`
  (`Sources/Accounts.swift`, `hermes auth priority`) then resumes the helper. Hermes's pool is per provider, not
  per conversation, so this moves the default for everything; the card says so ("everything uses Forge from
  now on") and the existing `LimitNoticeCard` wording stays for the automatic failover.

### Data and code changes

| Where | Change |
|---|---|
| `Sources/Helpers.swift:14-41` | `budget: Double?` (share of the week, 0.05), `used: Double?`, `budgetWarned: Bool?`, `pausedForBudget: Bool?`. |
| New `Sources/Usage.swift` | the state.db roll-up (read-only SQLite, recursive CTE), units, `usage.json` calibration, the `/usage` reader. |
| `Sources/Helpers.swift` / `HelperLines.swift` | parse `Budget N%:` in a job (like the turn limit). |
| `Sources/LimitBanner.swift` | the budget card next to `LimitNoticeCard`; the "Switch to" button calls `Accounts.makeDefault`. |
| `Sources/HelperConstellation.swift:267-283` (orb drawing) | the budget arc; `status` (`:101`) gets "Used its 10% · paused". |
| `Sources/ModelGoals.swift:80` | a budget pause uses the same `/goal pause` call. |
| `Sources/HelperStop.swift` | `pauseForBudget` (like `pauseForUpdate` at `:54`, but never auto-resumed). |
| SOUL (`Sources/Brain.swift` helper paragraph) + per-prompt note | how to write "Budget N%:" and that the card can change it. |

### Mac vs cloud

Same code path: state.db and `/usage` live with the engine. In the cloud the box has its own sign-in
(`one-cloud-fly`: access token only, never the refresh token), so its meter is the same account's meter;
`usage.json` is kept on the volume. The phone gets the pause card as a Telegram message with buttons
("tap to answer" idea from Nov 5).

### Tests

- Pure: units and the roll-up on a fixture state.db (a parent + 2 levels of children, the Nov 9 tree shape).
- Calibration from two fake meter readings; "about" before any.
- Stand-in engine: a helper whose fake session grows tokens; at 80% one warning line, at 100% paused, the
  three buttons do what they say (more budget resumes, switch calls `hermes auth priority` on a scratch home,
  stop goes through feature 1).
- Never: a routine or the main chat paused by a budget.

---

## 3. A health watchdog

### Problem

The Mac got slow and full while nobody watched: dozens of idle orphan dev servers (puma, vite, sidekiq, ppid 1)
from Conductor and Forge workspaces, a QA log that grew to 78 GB in about 3 minutes, Postgres test copies
eating 225 GB (Nov 9, "Find disk space hogs"). `ps` and `top` are blocked in One's sandbox, so the assistant
can't even look without the libproc workaround.

### Design

`HealthWatch` runs every 30 s on its own detached loop (like `Messenger.tend`, `Sources/App.swift:166-171`), never
on the main thread.

| Signal | How (no ps/top) | Warn when |
|---|---|---|
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` (1 normal, 2 warn, 4 critical) | 2 for 5 min, or 4 |
| Swap | `sysctl vm.swapusage` | over 8 GB, or +4 GB in 10 min |
| Free disk | `volumeAvailableCapacityForImportantUsage` of `/` and the brain's volume | under 10% or 30 GB; "dropping fast" at -10 GB in 5 min |
| Runaway writer | `proc_pid_rusage` (`ri_diskio_byteswritten`) per process, delta per 30 s; the file via `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO` | over 200 MB/s for 60 s, or a single file over 10 GB that grew 5 GB in 5 min |
| Runaway CPU | `proc_pidinfo PROC_PIDTASKINFO` total time × `mach_timebase_info` | over 90% of a core for 10 min |
| Orphans | ppid 1 + known dev-server names (puma, vite, node, sidekiq, rails, ruby, esbuild, webpack, selftest apps) + a working folder in a repo/workspace folder | idle (no CPU) for 30 min |

**Whose is it?** Three classes, decided by rules, never by guessing:
- **One's own:** in a helper's ledger (feature 1), a descendant of One's engine, or working from
  `Support/One/work`, a helper worktree or One's scratch. → One cleans it up by itself **only if its helper is not
  working** (stopped, done, gone), and says one line after ("I closed 4 dev servers a stopped helper left
  running.").
- **His tools' leftovers:** in Conductor/Forge workspace folders (`~/conductor/…`, `~/forge-workspaces/…`) or
  `~/Repos/*` with ppid 1. → a warning with **Close them** / **Leave them** (one tap closes all in that group).
- **His own:** everything else, explicitly including anything under `/Applications` he opened, Docker
  (`com.docker.*`, `vmnetd`, containers), databases (postgres, redis, mysql), his own Chrome, and Xcode. →
  only named in a warning, and only with a yes does One act (and for databases it never deletes data; it
  explains, as the disk helper did).

Big files: a growing file in One's own folders (logs under `hermes/logs`, scratch) is truncated or rotated by One
and said. A growing file elsewhere: "<program> is writing <file> at 400 MB a second (78 GB so far). Stop it?"
with **Stop <program>** / **Leave it**. Never deletes a file without a yes.

Warnings are cards in the home column (one card, several rows), spoken once, and sent to the phone when the
Mac's owner is away (idle 15 min) and it's critical (disk under 5%, critical memory, a writer that would fill
the disk within 30 min).

### Data and code changes

| Where | Change |
|---|---|
| New `Sources/HealthWatch.swift` | the loop, the signals, the three classes, `Support/One/health.json` (last readings, warned items, "leave it" choices for 24 h), `hermes/logs/one-health.log`. |
| New `Sources/ProcTable.swift` | the libproc reader shared with `JobTree` (feature 1) and `HumanCheck.mainChrome` (`Sources/HumanCheck.swift:174`); `GatewayGuard.arguments(of:)` (`Sources/GatewayGuard.swift:121`) stays the argument reader. |
| `Sources/App.swift:166` | start `HealthWatch.loop()` next to Messenger's loop. |
| Home (`Sources/HomeView.swift`) | the health card (render first). |
| `StorageCLI` | `One --health` (prints the same plain lines, read-only) so the assistant can answer "why is my Mac slow?" from inside the lock, where ps is blocked. |

### Mac vs cloud

Cloud: `/proc/meminfo` + PSI (`/proc/pressure/memory`), `statvfs` for the volume (5 GB), `/proc/<pid>/io`
write_bytes for runaway writers, cgroups for whose-is-it (everything on the box is One's, so all three
classes collapse to "One's own"). Warnings go to Telegram only (no screen).

### Tests

- `One --test-health` with a fake proc table (pure decisions): each class, never Docker/postgres/Chrome/
  `/Applications`, "leave it" remembered, a stopped helper's dev server closed but a working helper's kept.
- Real: start `python3 -m http.server` from a scratch "worktree", reparent it (double fork), mark its helper
  stopped → closed within 60 s. A scratch writer at 300 MB/s for 70 s → the warning names the file
  (writes into the scratch dir, deleted after; keep under 25 GB).
- Disk: fake a low free value via an override env var; check the card text.

---

## 4. One helper per repo at a time on main

### Problem

Since 0.9.89 a helper gets its own worktree, but only when its job names a repo **by path** and another busy
helper already uses it (`HelperRepos.make`, `Sources/HelperRepos.swift:69-91`, decided in
`Model.helperStartNotes`, `Sources/HelperStart.swift:32-43`). A job that says "Forge Desktop" gets none, and
nothing orders the end of the work: two helpers can rebase, push and merge to the same `main` at once (this job
itself runs next to "Local repo cleanup" in `~/Repos/one-assistant`). Only builds of One wait for each other
(`/tmp/one-build-<uid>.lock`, `Sources/HelperProgress.swift:102-103`).

### Design

- **Always a worktree.** Any helper whose job touches a git repo gets its own worktree, even when it's alone
  (cheap, and the person's own checkout is never touched). Repos named by name are found through a small index
  of `~/Repos/*/` remotes and folder names ("Forge Desktop" → `~/Repos/forge-desktop`,
  `Donnadieu/one` → `~/Repos/one-assistant`). Existing clean-up rules stay (`HelperRepos.release`/`sweep`).
- **The main queue.** Per repo, a queue file `Support/One/locks/<repo id>.queue.json` (repo id = hash of the
  main checkout's path) guarded with `flock`. An engine plugin `one-main-queue` (`on_pre_tool_call` on
  `terminal`, like `one-learning-cap`) recognizes the commands that change a repo's main: `git push … main`,
  `git push` on main, `git merge`/`rebase` onto main in the main checkout, `gh pr merge`, `gh release create`.
  Before running one it joins the queue and **waits** (the tool call blocks, up to 30 min, re-checking every
  5 s); when it's first in line it holds the lease for 15 minutes, renewed while its next commands are queue
  commands, released when it ends a turn without one, is stopped (feature 1), or the lease runs out.
  The helper is told in the tool result: "Waiting for your turn on Forge Desktop's main (2nd in line, behind
  NotArc release). Keep working on your branch meanwhile; this command runs when it's your turn."
- **When it's your turn**, the plugin first fetches and, if main moved since the helper's base, tells it to
  rebase and re-run checks before merging (exit with a plain message, no merge). That turns "two merges clash"
  into "the second one rebases first".
- **Orb:** "Waiting for Forge Desktop's main · 2nd in line"; first in line: "Putting work on Forge Desktop's main".
- Never: a queue for the brain or One's own data; never blocks the person's own terminal (the plugin is
  engine-side only).

### Data and code changes

| Where | Change |
|---|---|
| `Sources/HelperRepos.swift:26` (`repos(in:)`) | add name lookup via `RepoIndex` (new, small); `Sources/HelperStart.swift:32-43` makes a copy for every repo job. |
| New `tools/overlay/plugins/one-main-queue/` | the plugin (`decide()` pure + tested like `tools/browser-guard-check.py`), queue + lease. Added to `plugins.enabled`. |
| `Sources/HelperProgress.swift:54` | a step "Waiting for <repo>'s main" shows as the orb line (like "Waiting for another build…"). |
| New `Sources/RepoQueue.swift` | reads queue files for the orb, releases a stopped helper's place (called from feature 1's stop). |

### Mac vs cloud

Same files and plugin. In the cloud the repos are clones on the volume; the queue is local to the box. If the
Mac and the cloud box ever work on the same repo at once, GitHub's protected main + required checks is the
outer guard (the second push fails and is told to rebase); a shared queue isn't worth it before that happens.

### Tests

- Plugin `decide()` on command text (which commands count; `git push origin feature` doesn't).
- Two stand-in helpers push to a scratch bare repo's main at the same moment: second waits, then is told to
  rebase, then merges; history linear, no lost commit.
- Lease expiry and stop release the place. A repo named only by name gets a worktree.

---

## 5. Hand-offs from the phone

### Problem

When a helper hits a sign-in, a code, a passkey or a robot check, One shows the same hidden-browser tab in a
window with **Done / I'm not at the Mac** (`tools/overlay/tools/one_human_step.py:398-455`,
`Sources/HumanCheck.swift:52`). If Omar is away, "I'm not at the Mac" only gives him a text fallback ("approve
it in the Amazon app") and the job waits. In the cloud there is no screen at all
(`hand_off` returns `no_local_browser`, `one_human_step.py:408-414`).

### Design

**A link that shows one page, live, on his phone.**

1. The hand-off request is written as today (`handoff/<id>.request.json`, with the tab's `target_id`). If the
   window isn't answered in 60 s, or he's idle/away (no input 5 min, screen locked), or there's no screen,
   One starts a **phone hand-off** at once and sends it through the existing Telegram bot (`Messenger`,
   `Sources/Messenger.swift`): "Amazon needs a code for **Order paper towels**. Tap to open the page (works
   once, 10 min)." with one URL button.
2. **Transport: an end-to-end encrypted relay.** The Mac (or the cloud box) has no public address and keeps
   none. A small relay we run (Cloudflare Worker + Durable Object, the same relay the phone plan already
   names) pairs two WebSockets by a random 128-bit room id. The Mac dials out to it; the phone page connects
   to it. The link is `https://hand.one.forjado.ai/h/<room id>#k=<256-bit key>&s=<id>`. The part after `#`
   never leaves the phone's browser, so the relay only ever sees ciphertext (AES-GCM with WebCrypto on the
   phone, CryptoKit on the Mac). The phone page itself is static and served from the relay (no secrets in it).
   v1 option with nothing to run: `cloudflared` quick tunnel to a 127.0.0.1-only server for the life of the
   hand-off; rejected as the default because it pulls in a binary and a random domain per hand-off.
3. **What the phone sees and can do:** the Mac side attaches to **that one target only** through its own page
   WebSocket (`/devtools/page/<target_id>`, never the browser endpoint), runs `Page.startScreencast` (JPEG,
   phone width) and forwards only these inputs: tap (`Input.dispatchMouseEvent` press/release at a point),
   scroll, typed text (`Input.insertText`), Enter/Backspace/Tab. No URL bar, no tabs, no back/forward, no
   downloads, no devtools, no file pickers, no other CDP method; anything else is dropped and logged.
4. **Fences:**
   - one page: if the tab navigates to a site outside the step's site (its registrable domain plus the known
     sign-in hosts for it: `accounts.google.com`, `appleid.apple.com`, `login.microsoftonline.com`, …), the
     stream pauses with "This page went somewhere else" and ends;
   - expiring: 10 minutes from sending, or 2 minutes after the step moved on, or on Done; the Telegram message
     is edited to "Done" / "Expired";
   - single device: the first phone that opens it gets a device secret (in the page's memory) and the relay
     refuses a second connection to that room;
   - no other tabs: the hidden browser's other tabs are never attached;
   - passkeys and security keys can't go through a picture of a page: for those the phone page says so and
     offers the site's own phone route (the existing `phone_fallback` text), or "I'll do it at the Mac";
   - the link is only ever sent to `TELEGRAM_HOME_CHANNEL` (his own chat), never to a group.
5. **Audit:** `handoff/<id>.audit.jsonl` + `hermes/logs/one-handoff.log`: created (helper, site, kind), link
   sent, opened (time, phone's user agent, the relay's country), every input **type** (tap at x,y / typed 6
   characters, never the characters), navigations, ended (why). The helper's thread gets one line: "You
   finished the Amazon step from your phone at 9:41."
6. **Carrying on:** the existing `_wait` in `one_human_step.py` already watches the page move on; the phone
   session writes the same `answer.json` ("done", or "away" if he taps "Not now"), so the helper continues
   exactly as with the window.

### Data and code changes

| Where | Change |
|---|---|
| New `Sources/PhoneHandoff.swift` | start/stop a phone hand-off from a request file; the CDP page attach, screencast, input whitelist, encryption, relay socket; audit. |
| `Sources/HumanCheck.swift:52` (`begin`) and `:66` (`request`) | after 60 s unanswered, away, or no screen: `PhoneHandoff.start`. |
| `Sources/Messenger.swift` | `send(link:)` with a URL button (Bot API `sendMessage` + `reply_markup`), and edit on expiry. One-lint `r_messaging` keeps Telegram code in this file. |
| `tools/overlay/tools/one_human_step.py:408-414` | in the cloud (`no_local_browser`) write the request anyway with `"remote": true` instead of giving up. |
| New `relay/` (Worker, ~150 lines) | room pairing, static phone page, size and rate limits; no storage. |

### Mac vs cloud

Identical: the box runs the same headless Chrome and One's hand-off code dials the relay. Cloud is the reason
the relay design wins: the Fly app keeps no public port (`one-cloud-fly`, no `[http_service]`).

### Tests

- Pure: the input whitelist (every CDP method not listed is dropped), domain fence (google sign-in allowed for
  a Google step, a different site ends it), expiry, single device.
- Local loop test without the internet: relay run locally (`wrangler dev` or a 40-line Python stand-in), a
  scratch Chrome on a test port showing a local "enter code" page, a scripted "phone" client decrypts frames,
  taps the box, types 123456, page moves on, `answer.json` = done, audit has no digits.
- Security review checklist in the PR: key never in logs or the relay; link only to the home channel;
  screenshots never saved to disk.
- Not testable by CI: a real tap from Omar's phone; say so when shipping.

---

## 0. Tests and renders never touch the real settings (Omar, Nov 9)

Around 9:58 PM on Nov 9 a test or render run of One wrote `assistantName = "Elias"` into the real
`ai.forjado.one` settings (owner.yaml says Iris), so Ready for you looked in "Made by Elias" and hid new results.
`TestWorld.enter()` / `enterRender()` (`Sources/TestWorld.swift:22`, `:52`) already refuse as the real One, but
a copy built from the repo carries the same bundle id `ai.forjado.one`, so its plain `UserDefaults.standard`
writes land in the real domain.

Design: every `--test-*` and `--render-*` entry point (the CLI chain in `Sources/App.swift:271-286` and
`StorageCLI.run`) goes through one gate that swaps `UserDefaults.standard` for a scratch suite
(`ai.forjado.one.test.<pid>`) before any view or model is built, and refuses to start if `Env.support` or the
brain resolve to the real ones. A preflight check (`One --test-production`, extended) runs every render and test
mode once from a build with the production bundle id, with `defaults export ai.forjado.one` taken before and after,
and fails on any changed key (assistantName, shelf, helpers, bubbles above all). Ships as the first PR, ahead of 1.

## Build order and what each PR ships

| # | PR | Why this order |
|---|---|---|
| 0 | **Tests can't touch real settings** | Omar asked; a real leak on Nov 9. Small, and every later PR's checks rely on it. |
| 1 | **Stop means stop** (fence, sweep, verify, "Stopping…") | It's a bug that cost real usage and put windows on screen. Features 2-4 reuse its fence and ledger. |
| 2 | **Budgets** (state.db roll-up, meter calibration, warn/pause card, switch account) | Builds on 1's pause and on the accounts work already in 0.9.101. |
| 3 | **Health watchdog** | Reuses 1's ledger to know what's One's own. |
| 4 | **Repo turns** (always a worktree, main queue) | Independent; smaller blast radius once stop releases places. |
| 5 | **Phone hand-offs** | Needs the relay (new infrastructure, a domain) and the most security review. |

Each PR: tests in CI, `make check` green, a render for any UI, then the usual release (VERSION bump, signed tag,
`gh release create` with One.dmg + One.zip). Nothing is copied into /Applications by the builder.

## Confirmed vs guess

| Claim | Status |
|---|---|
| Stop interrupted the 10 sub-helpers at 11:21:35 | Confirmed (agent.log) |
| A background process completion started a new turn 1 s after Stop | Confirmed (agent.log 11:21:36, state.db user rows) |
| The woken turn dispatched 5 new sub-helpers at 11:33 | Confirmed (state.db sessions, tool_calls) |
| One's cancel never calls `process.stop` | Confirmed (Engine.swift:467, gateway_server.py:414-449) |
| Env vars of other processes are unreadable on this Mac | Confirmed (KERN_PROCARGS2 test from inside the lock) |
| libproc gives ppid, session and working folder from inside the lock | Confirmed (test) |
| ~90 processes / windows on screen | From Omar and Iris, not re-counted |
| "27% of the week" | From the account meter as reported; One's own share computed here is 6.9% of One's Anthropic use |
| Units-per-% calibration will be stable enough | Guess; needs a few days of readings |
| Anthropic's `/api/oauth/usage` works inside the folder lock | Guess (the engine already calls it; untested inside the lock) |
| One can read the meter through the engine's `/usage` over its link | From the Nov 5 "Hermes features for One" check, not rechecked; fallback is running `agent/account_usage.py` with the engine's python |
| Relay at `hand.one.forjado.ai` | Proposal; needs a domain and a Cloudflare account (cost: free tier) |
