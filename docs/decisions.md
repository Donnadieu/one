# Decisions

Design decisions that are easy to undo by accident. Newest first. Each says what was picked, what was rejected and
the evidence.

## Release checks: one red check never hides the rest; the routine check installs its Anthropic SDK; smooth takes 3 tries (0.9.150, Nov 28 2026)

**Problem.** Since 0.9.148 the fresh-install check failed on every tag and release (v0.9.148, v0.9.149) at "Routines
through the real engine", with only "engine python not found", and GitHub skipped the eight real-engine checks after it.
The cause: `tools/routine-stall-check.sh` looked for an engine python that already imports `anthropic`. The Anthropic
SDK is an optional engine extra that the engine installs itself on the first Claude call (`pm.ensure_import`), so a
brand-new engine never has it; the check passed only on a Mac that had used Claude. Separately, the `smooth` check
failed about 1 push to main in 3, each time one budget by a hair on its single try (keystroke p95 40.2-48.5 ms of 40,
a bot's chat opening 127-137 ms of 120, hitches 8.2-9.7% of 8%), a different budget each time: runner noise.

**Picked.**
- The routine check boots onto the engine's committed dependency set the way the engine's own processes do
  (`pm.environments.activate_dependencies`, as `hermes_bootstrap` and `cron/worker_bootstrap.py` do): on the newer
  engine layout a python started directly has only the base venv (no ruamel.yaml). The Anthropic SDK the engine pins
  (its pyproject's `anthropic` extra) goes in a throwaway folder, added with the engine's own uv when it is missing
  and searched after the engine's own packages (the engine is never changed); then it runs with lazy installs off as
  before. Tried first on the runner and dropped: the engine's own lazy install (refused from a python started
  directly), `hermes pm install --extra anthropic` (stops on a test install without ffmpeg, node and ripgrep), and a
  `uv pip install` into the venv (lands in the base venv the engine doesn't boot from).
  It prints the import error if it still finds no python.
- In fresh-install, every check after the install runs `if: !cancelled() && steps.install.outcome == 'success'`, so
  each check reports on its own and the job still fails if any did. Nothing runs without an engine.
- `smooth`: a measurement over budget is taken again, up to 3 tries, and fails only when every try is over. Budgets are
  unchanged. A shared runner only adds time; a real slowdown is over on every try.

**Rejected.** Raising the 120 ms / 40 ms budgets (the passing runs sit far under them: a bot's chat opens in 40-96 ms,
keystroke p95 12-36 ms, so they're not wrong); preinstalling every engine extra in `--install-test` (a real person gets
the SDK on first use, and the check should not hide a different install path); `continue-on-error` (it would turn a
failed check green).

## The phone chat saves helper lines as written; a promise with no line gets one silent correction (0.9.149, Nov 28 2026)

**Problem.** On Nov 28 the Telegram chat got five or more "Nothing started… Say go" notes in one morning, twice right
after Omar complained: replies said "I'm sending a helper to set up Cal.com:" or ended in a hand-written "↳ Passed on
to Cal.com booking setup", with no line. The cause was One's own phone plugin: it cut the helper lines out in
`transform_llm_output`, whose result is what the engine stores and replays, so a long chat showed only "↳" receipts
and never a real line, and the model copied the receipt.

**Picked.** What's saved is the reply as written, with its real lines, and never a receipt (a "↳" line the assistant
typed itself comes off first). The cut and One's receipts happen only on the way out, inside the gateway's last step
before sending (`gateway.run._sanitize_gateway_final_response`, wrapped once by the plugin; every delivery path,
crash-left replies included, imports it by name). A reply that says a helper is being sent or told with no line gets
one silent correction turn (the same main model, this chat's recent messages) that must answer with only the missing
line(s); they're added to the reply, handed to One, and the person sees only the fixed reply. Only if that fails too
do they get a one-line note. **Rejected:** more prompt text (it was already there and was copied around), saving the
cut text with a different receipt shape (still a finished-job shape to copy), and patching the engine's gateway files
(lost on every engine bump). **Evidence:** `tools/phone-tags-check.py` replays the Nov 28 replies
(`tests/fixtures/phone-tags/nov28-missing.json`) with a stand-in assistant: 42 checks failed before, all pass after;
`tools/phone-choices-engine-check.sh` runs the same through the pinned engine's own turn end and send step. Not tested:
a live correction turn against a real model.
## A routine's quiet reply is cut off at 4 minutes and the same turn goes again (0.9.148, Nov 28 2026)

**Problem.** Nov 25 2026 "Forge release" and "Forge X replies (afternoon)" failed after 4343 s (72 min), Nov 27
"Then It Clicked: long video" after 661 s, all with "Operation interrupted: waiting for model response", and every
step they had done went with the run. The logs (agent.log, pmset): the Mac was in lid-shut sleep with dark wakes.
The model reply sent nothing while it slept; at each dark wake the engine's stall timer fired late (940-1023 s past
its 240 s), its retries ran into a network that was not back yet, and then the session lease, whose 300 s deadline
had passed during the sleep, hard-stopped the turn ("Session turn lease refresh stayed locked through its lifetime"
then "interrupted_during_api_call(session_turn_lease_lost)"). The engine also allows 900 s of silence for a model
on this Mac. Cron runs a failed turn again only when it never reached the model (`cron/unreachable_retry.py`), and
then from scratch.

**Picked.** An engine overlay hooked into `cron/scheduler.py` (`tools/overlay/cron/one_routine_stall.py`,
`Installer.applyRoutineStall`), routines and their own helpers only. A streamed reply quiet for
`ONE_ROUTINE_STALL_SECONDS` (240 s) is cut off. A turn that still ends on the model with no person behind it (a
lapsed lease, the turn watchdog, retries run out on an unreachable AI) waits until the AI's address takes a
connection (every 15 s, up to 30 min, its run claim kept fresh) and runs the same turn again, its messages so far as
history, so a finished upload or post is not done twice; at most 3 times a run.

**Rejected.** Changing the lease (it guards the transcript against a second process; a new turn takes a fresh
one). Capping non-streamed calls (they send nothing until done, so silence there is not a stall). Re-running the
whole routine (redoes finished steps). A Stop, a gateway restart, a rate limit, a billing or sign-in wall: never
retried.

**Checked.** `tools/routine-stall-check.py`, the real engine with a stand-in Anthropic model: a stalled stream is
cut off in 3 s (the test limit) and, the Mac "sleeping" through one (the lease's own path), the routine waits for
the stand-in to listen again and finishes with its upload done once. Before the overlay: still waiting at 60 s, and
"Operation interrupted: waiting for model response".

## No third-party course material in One; the co-founder room is a normal room (0.9.147, Nov 27 2026)

**Problem.** `build.sh` bundled the whole private brain starter with `git archive HEAD`, and the starter carries a
third-party course kit in `templates/cofounder-room/` (framework cards, its own skills, `kit.yaml`, its licence) that
may not be passed on. It shipped inside every public One from 0.4 (Oct 23 2026) to 0.9.146, and a new co-founder
room was copied from it.

**Picked.** One bundles the starter's own files only. `tools/brain-starter-bundle.py` archives the starter without
`templates/cofounder-room`, takes out the few lines of its docs that pointed at the kit, swaps its private licence
note for One's MIT terms (the starter's own files are by One's author), and fails the build if any kit file or word
is left. Every room kind, the co-founder room too, is built from `templates/room` (with its own `brain/company.md`
hub). A room that already exists is never touched: no delete, move or rewrite on install or update. The rooms, the
personal room by default, a new room only when the rules differ, AGENTS.md/BRAIN.md/HELP.md, owner.yaml,
starter.yaml and the brain's own skills are unchanged. Every release before 0.9.147 was deleted from GitHub (the tags
stay: the repo itself never held the kit). **Rejected:** keeping the kit for licensed members only (One is public
and has no way to tell), and rewriting the starter repo (the owner keeps his own licensed copy there). **Evidence:**
`make check` (`brainstarter`: a poisoned stand-in comes out clean, and each kind of leftover is caught),
`BrainKitCheck` in `One --test-guards`, the fresh-install workflow's check on the released app, and unzip-and-grep of
the released One.dmg and One.zip.

## A bot's room is its only source of truth (0.9.147, Nov 25 2026)

**Problem.** Omar, Nov 25 2026: "Ideally we want to have the brain and the rooms be the source of truth and never have
a discrepancy between bots and rooms." Bots kept their own log in `bots/<slug>/memory.md`, so what a bot knew and what
its room said drifted apart.

**Picked.** A bot's start context (`BotRoom.context`) = its memory.md **Rules** and **Working state** (never the
Archive) plus the room's lines tagged `[<bot name>]` from the last 14 days of `memory/*.md` and `vault/` (never
`confidential/`, newest 60). New facts are appended to `<room>/memory/<today>.md`, tagged; `BotRoom.record` does the
same for a kept helper's first line. Renames keep old tags via `BotInfo.was`. **Rejected:** keeping memory.md as the
log and syncing it into the room (two copies drift again). **Evidence:** `BotRoomCheck` and `BotsManageCheck` in
`One --test-helpers` (PR 172, RED run 45656844793 then green).

## A turn a restart cuts is picked back up at the root, on every surface (0.9.146, Nov 22 2026)

**Problem.** Nov 10-22, One's nightly review saw "your answer was lost to a restart" 12 times, after PR 150 (0.9.134)
too. Evidence (state.db, gateway.log, one-gateway-guard.log): 40 engine stops, ~20 of them One update installs; each
ran the engine's drain with `agent.restart_drain_timeout: 0`, settled every person's turn in flight `interrupted`
(333 admissions) and wrote "this turn was interrupted and will not be run again. Send your message again" into the
conversation and onto the stream (`owner_stop_notice`). The engine never runs that turn again. PR 150 only hid those
words on One's screen and carried a helper's own words into its pick-up: the conversation still said them (so the
review kept counting), the phone chat was never covered (Nov 11 "Yes go ahead" was lost), and the main chat's retry and
every Next up message (taps included) lived in memory only, so a One restart dropped them.

**Picked.** Durable before the turn starts, replayed once after any restart: One writes the main chat's turn and
everything waiting to `<support>/turns/pending.json` (fsync'd) before it goes to the engine and sends what's left again
once at launch (`TurnJournal.swift`; the engine's own record decides "answered after all"; 2 pick-ups max; stale after
2 h). The engine plugin `one-restart-replay` replaces the engine's words at their one source with One's line, keeps a
phone-chat turn the restart cut on disk and sends it again once when Telegram is back. **Rejected:** a non-zero
`restart_drain_timeout` (updates and quits would hang on long helper turns, and a kill still cuts them); patching the
engine's admission state machine to re-queue interrupted turns (deep, version-bound, and One already re-sends its own
turns, so ACP turns would run twice); hiding the words again in more places (PR 150's approach). **Evidence:**
`tools/restart-replay-check.sh`, `tools/restart-replay-plugin-check.py`, `tools/restart-replay-engine-check.sh`,
`TurnJournalCheck` in `One --test-helpers`.

## Recipes stay small by themselves; lessons live next to them (0.9.145, Nov 22 2026)

**Problem.** Recipes (SKILL.md) only grow. The nightly review could add a lesson only to a recipe under 12 KB and
listed the rest as "too big", so the most used ones never learned: one-assistant-dev reached 98 KB and 26 of the
brain's recipes were over the limit. A lesson that came back was written as a new line each time.

**Picked.** A size limit in code (12 KB, `RecipeTidy.limit`). Before every nightly review, on suggestion nights too,
any recipe over it is split: `SKILL.md.bak-<date>` first, long sections word for word into new `references/<topic>.md`
files (never written over), the frontmatter, overview, key-rule sections that fit and a one-line index left in
SKILL.md. Every non-empty line of the old SKILL.md must be in the new files, checked in memory and again from disk;
otherwise it is put back exactly as it was. Lessons live in `LESSONS.md` next to the recipe, linked from it, one line
per lesson id: `One --improve lesson add` merges a repeat (dates widen, count goes up), and it is the review's only way
to add one. Old `## Lessons` sections move there. One line in the morning brief, no question. **Rejected:** asking
the person before each split (he asked for it to happen by itself), summarising sections (loses words), and capping
lessons inside SKILL.md (they'd still compete with the recipe for space). **Evidence:** `RecipeTidyCheck` in
`One --test-nightly` (preflight), red on the stub commit, green after.

## Bots: a helper you keep, as moons on the left (0.9.123, Nov 17 2026)

**Problem.** Omar's friends use Grok Bot, Meta's Muse and OpenAI's dots; his friend Danny keeps a Growth bot and an
Intake bot. One's helpers end when their job is done, so nothing could be gone back to for one focused job.

**Picked.** Claude Design "One bots design", Direction B · Moons (Omar, Nov 17), with A's facts line: a bot is a
`Helper` kept for good (`BotInfo`), shown as a small orb in its colour on the left, grouped by room (private rooms
locked), a lit thread to the assistant while it works, its chat with what it uses, when it checks in, how much it
remembers and What it did; made by saying it (three questions, then a `[bot: …]` line) or Keep as a bot. Routines
stay their own dial: a routine made in a bot's conversation belongs to it, wears its colour, and the dial filters by
bot. The column shows only after the first bot (before that, one faint New bot circle). **Rejected:** Direction A, a
panel twin of Ready for you ("what every other app has"), a separate bots page, and moving routines into bots (Omar
was firm that routines keep their dial). The contractor box was dropped by Omar. **Evidence:** `BotsCheck` in
`One --test-helpers` (preflight) and the `bots-*` renders.

## Updates, installs and restarts wait until no routine is at work (0.9.122, Nov 17 2026)

**Problem.** At 7:17 AM a helper installed 0.9.120 by hand (kill One, swap the app, open it) and cut the YouTube
long-video routine 17 minutes into its run. Its "is a routine running?" test read `state == "running"` in jobs.json,
which the engine never writes; the new One's first engine start then found the old gateway orphaned and stopped it as
stale. One's own updater already waited for routines, but only for 2 hours, and nothing stopped a hand install.

**Picked.** One way in: `One --update [--from <One.app>] [--restart]` leaves a request the open One carries out with
every wait (`UpdateRequest`); routines are waited for with no time limit (the engine's own record ends a "running" read
after 3 hours); helpers still pause only between steps. The engine plugin refuses hand-made kill/swap/relaunch of One
while One is open or a routine is at work, and `GatewayGuard` leaves a stale gateway that is still running a routine and
retires it once the routine is done. **Rejected:** a fixed longer cap (still cuts a long run) and asking helpers in the
prompt only (the Nov 17 helper had the rule and still read the wrong field). **Evidence:** `UpdaterCheck.busyChecks`
(`One --test-updates`) and `tools/restart-guard-check.py` in preflight, with the real Nov 17 job and command as fixtures.
## A phone reply that says a job is starting must carry its helper line (0.9.121, Nov 17 2026)

**Problem.** On Nov 16-17 several Telegram replies said "It's starting now…:" or "I'm sending a helper…:" and ended at
the colon; nothing started. The model never wrote the line (the plugin logged no hand-over, and those turns' output
tokens leave no room for one). The engine saves and replays the cut reply, so every earlier success in the chat read
as a promise ending at a colon, and the model copied that.

**Picked.** The phone-tags plugin leaves a receipt ("↳ Helper sent: <title>") where lines were cut, flags a reply that
says a job is starting with no line (loud log, a one-shot note to the next turn in that chat, and a visible "Nothing
started" when the reply plainly hangs), and the phone rule says only the line starts a job. **Rejected:** saving the raw
reply while sending the cut one (the engine stores exactly what the person sees, by design) and starting helpers from
promise words (guessing a job from prose). **Evidence:** the exact Nov 16-17 replies as fixtures in
`tools/phone-tags-check.py`, and the real engine's turn end in `tools/phone-choices-engine-check.py` (PR #135).

## Choices in a phone reply become tap buttons (0.9.120, Nov 17 2026)

**Problem.** Replies that end with `[choices: A | B]` showed as buttons in One's own chat but reached Telegram as that
raw line, because a phone reply goes from the engine's gateway straight to the phone.

**Picked.** The same engine plugin (`tools/overlay/plugins/one-phone-tags`) cuts a last-line choices list exactly like
`Choices.split` and sends it as Telegram buttons under the reply, with its own `oc:` taps; a tap goes through the
gateway's allowlist and in as the person's own message. Older sets stop working once a newer set arrives or the person
types. **Rejected:** patching the engine's Telegram adapter or reusing its shared `cp:` picker state (collides with
`/reasoning`). **Evidence:** `tools/phone-choices-check.py` in preflight, Swift parity in `--test-helpers`, and
`tools/phone-choices-engine-check.sh` against the pinned engine in the fresh-install workflow (PR #133). No live tap on a
phone yet.

## Helper lines from the phone chat are acted on by One (0.9.119, Nov 16 2026)

**Problem.** On Nov 15 the assistant answered in the Telegram chat with a `[helper: …]` line and later a
`[tell-helper: …]` line. Nothing started: those lines are read only by One's own chat, and a phone reply goes from the
engine's gateway straight to the phone.

**Picked.** An engine plugin (`tools/overlay/plugins/one-phone-tags`) hands phone replies that carry helper, tell, stop
or clear lines to One through `hermes/one-phone/inbox/`, and strips those lines from what the phone shows; One acts on
each reply once through `Model.actOn`, the same code its own chat uses, and sends the helper's result back to that chat.
**Rejected:** patching the engine's gateway files (lost on every engine bump) or teaching the assistant to avoid helper
lines on the phone (the phone is where Omar is when he asks for work). **Evidence:** `tools/phone-tags-check.py` in
preflight and the stand-in engine run in `One --test-helpers-stress phone` (PR #131); the pinned engine's own
`apply_llm_output_transform` loaded the plugin in a scratch home. Also ships PR #130 (a hidden browser can start muted).

## A hand-off's wait is time spent waiting on the person (0.9.118, Nov 12 2026)

**Problem.** The engine stops any tool call after 420 s unless the time is inside its human-wait window
(`tools/approval_human_wait.py`, the one approval prompts use). `browser_vault hand_off` waits up to 480 s, and longer
while the real window is up, outside that window. In the live DocuSign test the engine stopped the call at 420 s while
Omar was typing the texted code in the real window; the stop answered the ask "cancelled" and the sign-up page was lost.

**Picked.** The hand-off's waits (the code step and the window wait) run inside `human_wait_window()`, so the engine
leaves them out of the 420 s budget (it caps each window at approvals.timeout + 60 s). **Rejected:** raising the
engine's tool limit (it guards every tool, not just this one) or shortening the hand-off's wait (people take longer
than 7 minutes when they're away from the Mac). **Evidence:** `tests/handoff/human_wait.py` red before, green after,
in `make handoff`; checked against the installed engine's real module.

## A routine the engine switched off for good comes back by itself, out loud (0.9.117, Nov 12 2026)

**Problem.** Project Ledger PM (7:15 PM daily) didn't run Nov 9, 10 or 11, so the FanVue page got no daily post. On
Nov 8 One quit at 9:18 PM while that run was two hours in. The engine marked the run interrupted, gave up on it
(`CronExecutionUnknown`) and paused the job: `paused_reason` "Cron execution unverified; reconcile
cron/admissions/fc775d….json". That pause is lifted only when the run's admission journal proves the run ended. But
the give-up had already booked the run `failed`, and the engine's next recovery pass deletes a failed run's journal
without lifting the pause (`cron/scheduler_authority.py` `reconcile_pending`). So the job stayed `enabled: false` with
`next_run_at` stuck at Nov 9 7:15 PM, and nothing would ever turn it back on. Nobody was told: the run's report had
only an `## Error` section, and One spoke only reports with a `## Response`; the Routines panel drew it as a calm
"paused". The morning run noticed three days later.

**Picked: One turns it back on and says so (RoutineRevive.swift).** Every 15 s (with the routine reports), a job
paused with one of the engine's own uncertainty reasons ("Cron execution unverified", "Canonical cron unknown") and no
journal left for it in `cron/admissions` is resumed with `hermes cron resume` (the card's Turn back on). A slot it
missed while off stays due, so the engine makes it up once, right away (checked live on 0.9.116's engine: a held job
resumed with a past slot fired once at the next tick and moved on to its next time). One says in the chat, aloud:
"<routine> turned itself off on <day> after a run was cut off, and nothing told you. I turned it back on, and it's
making up its missed run now." If the engine refuses, it says it couldn't, and tries again at most once an hour
(`hermes/logs/one-routine-revive.log`). A run that left only an error is now said too ("<routine> didn't work.
Stopped partway because One restarted …").

**Rejected.** Patching the engine's `reconcile_pending` (One carries no engine patches for cron; a text patch breaks on
the next pinned Hermes). Resuming while a journal is still there (the engine can still settle that run itself and
lift its own pause; resuming early could run it twice). Touching a pause the person made, or one for another reason.

## Reverted: the main chat hands a long turn to a helper itself (0.9.126, Nov 17 2026)

**Problem.** Since 0.9.116 One cut off any turn that ran past ~20 s or 3 steps and replied with a canned "That needs more than a quick look, so I've sent a helper… I'm free to talk." Omar: every ask got that bot line, nothing was answered like a person, and the assistant was never actually free. **Picked.** Revert 0.9.116 (`MainFree`, its check and the "first reply, right away" rule) in full; the assistant again decides itself when a job needs a helper.

## The real window comes back for every step, on the helper's very page (0.9.115, Nov 12 2026)

**Problem.** 0.9.113 replaced the real Chrome window for sign-in and approve steps with One's own picture of the
hidden tab (StepWindow). Omar: the window must be the real browser, as before, with One's card beside it ("the live
view from previous versions stays forever"), and One decides what to show. On 0.9.114 the DocuSign helper called its
SMS code page "approve", so he got that picture instead of a code box, and it took no input. The older window
(0.9.58 to 0.9.112) had its own bug: it opened the page's address again, and DocuSign's code steps exist only as the
answer to a form, so a fresh load showed the sign-up form (reproduced live Nov 12: the window showed "Create Your Free
Account" at the code step's address).

**Picked.**
1. Every step can be shown in the real window (`HumanCheck.wanted` is every kind again); StepWindow is never shown.
2. A code is asked in the card's box first ("I need the code <site> sent you. Type it here and I'll take care of it."),
   with Show the window on the same card. After two codes that didn't work, the card says so and offers the window.
3. The window opens on the helper's very page (`StepPageCopy`): a page reached by sending a form (navigation
   `form_submit`, or Chrome has no copy to give) is kept as a still copy (fields as typed, the page's style sheets
   including rules scripts wrote, scripts left out) and shown at its real address through the window's DevTools
   socket (`Fetch.fulfillRequest`, once). What the person submits goes to the site itself. Pages the site sends in the
   window are kept as sent (`StepPageWatch`) so the helper's tab comes back on the person's last page with its scripts
   working. A page its address brings back opens by its address, as before.
4. The engine decides the kind from the page: a code box means a code step, whatever the helper asked.

**Rejected.** Replaying the page with its own scripts: DocuSign's React app drew the step twice. Reloading or
re-sending the form: a reload lands on the sign-up form, and re-sending would send another text.

**Proof.** Live DocuSign developer sign-up, throwaway accounts and browser, a test copy of One (`--qa-handoff`): email
code through the card (inbox) and through the window; Omar's texted code through the card's box (accepted, "Set your
password"), and his texted code typed in the real window (accepted, window closed, helper's tab on "Set your
password"). Guard in CI: `make handoff` part 3 (window on a POST-only step, never a GET of it) and the code loop's
part 2 (window offer) and part 8 (a code page called "approve" gets the code box).

## A code ask always ends, and never before a code was sent (0.9.114, Nov 11 2026)

**Problem.** On 0.9.113 a helper on DocuSign's SMS step pressed Send Code (the code box did appear, at the same address
as the phone-number step) and handed off; the text never reached Omar. In `code_step` (`one_human_step.py:794-812` at
v0.9.113) only `away` ended the wait: any other answer without a code fell to "Done with no code" and made a new ask,
and a wrong code made a new ask with no limit. "I'm not at the Mac" on the card did nothing once the phone had been
asked (`HumanStep.swift:123` + `:167` returned before writing an answer). A message to the helper waited behind the tool
call, and a Stop didn't end it (the tool thread kept polling with its cached tab id).
**Picked.** Two tries, then `code_failed`; every answer (and Stop, and a closed tab) ends the wait; a message to the
helper becomes the answer; the code ask refuses on a page with no code box. Proof: tests/handoff/e2e_code_loop.py,
phone_replies.py and `HumanStepWaysOutCheck` (red on v0.9.113, green after).
**Rejected.** Keeping the retry loop with a longer limit (Omar: never ask a third time on its own).

## Hand-offs keep the helper's own tab (0.9.113, Nov 11 2026)

**Problem.** From 0.9.58 (Oct 28 2026, `HumanCheck.wanted` widened from robot checks to every kind) to 0.9.112, a step
only the person can do made One close the hidden browser (`HumanCheck.closeHidden`, `HumanCheck.swift:84` at
v0.9.112) and open the same profile as a visible Chrome window on the same address (`HumanCheck.swift:86`); after Done
it quit that window and reopened the address again in a new hidden tab (`HumanCheck.swift:143`). A step that lives
only in the open tab can't survive that. Proved on DocuSign's free developer sign-up (throwaway headless Chrome, email
code only, Nov 11 2026): opening the "Check your email" step's own address in a new tab of the SAME running browser
shows a fresh "Create Your Free Account" form. Omar was shown DocuSign's log-in page twice. 0.9.112 (keeping
session cookies through the close) didn't help, because the cookies weren't what was lost. Robot checks and Claude
sign-ins had worked through it because those pages come back on a reload.

**Picked: by the step's kind, never reopen the tab.**
1. Code: no browser at all. Inbox first (Gmail tokens the engine already has), else One's card asks for the code in
   a box, or their phone chat when they're away (their reply is the code). The engine types it into the still-open
   tab and checks the page moved on. Works at the Mac, from the phone, and with no screen (cloud).
2. Sign-in, approve: the same live tab in One's window (StepWindow: the page's real address on top, a picture from
   the first moment, clicks and typing passed to the page), or the phone link (PhoneSession) when away.
3. Robot check, passkey, security key: the plain Chrome window, as before. A click through DevTools is refused by
   Cloudflare (proved Oct 28), and a hidden browser can't show the Mac's passkey sheet; these pages come back on a
   reopen.

**Rejected: run the hidden browsers as normal (headful) Chrome kept off screen and bring the same window forward.**
Spike on a GitHub macOS runner (branch `spike-headful-window`, Nov 11 2026): bringing the SAME window and tab on
screen and back works (typed text and page state kept). But a normal Chrome is a regular app: it sits in the Dock and
Cmd-Tab the whole time (`ApplicationType=Foreground`; `lsappinfo setinfo` can't change it), its window shows on
screen and takes the focus at start (`-30000,-30000` is clamped to `0,31`; the app is active), and off-screen
positions are clamped. That breaks the no-surprise-windows rule for every hidden browser, all day, to fix one step.

**Guard.** `make handoff` (fresh-install CI): pages that exist only as a POST answer (`tests/handoff/post_server.py`;
a GET bounces to log-in). It fails if the tab is ever reopened, the browser closed, or the code doesn't land in the
same tab. Red on 0.9.112 (run 43058647342), green on 0.9.113.
