# Architecture

```
            App.swift  (entry, CLI hooks, renders)
                 │
   Views / World / Connections / Rooms / Floater      ← UI (SwiftUI)
                 │  reads/writes
               Model                                  ← app state, one shared instance
                 │
   Engine · Voice · Installer · Updater · Brain · Helpers · Pictures   ← services
                 │
               Env  (paths, folder-lock profile, environment)        ← foundation
```

| File | Area | Responsibility |
|---|---|---|
| Env.swift | foundation | paths, `Access.profile()` (the folder lock), engine environment |
| TestWorld.swift | foundation | the person's Mac is production: `TestWorld.enter()` (the only way into a test mode; refuses as the real One, scratch One folder), `Env.production`, `isProduction(url)` |
| ProductionCheck.swift | dev only | `One --test-production`: a test copy keeps to its own world; the Oct 27 shelf move replayed on fakes |
| Installer.swift | service | install Hermes (pinned commit), KeePass overlay, provider sign-in, tools Python |
| Engine.swift | service | the ACP connection to Hermes: sessions, prompts, permissions |
| Voice.swift | service | Kokoro voice process, speaking, listening (push to talk) |
| HelperSound.swift | service | the organ swell when a helper's orb turns orange (done / needs your yes): on the voice line, after any sentence, never muted or during push to talk, one for several (`sounds/`, made by `sounds/make_sounds.py`) |
| Updater.swift | service | check GitHub releases every 15 min (ETag, back-off), announce a new version once (notification, orb note, spoken line), download, swap the app |
| VersionNote.swift | service | the hidden note on every prompt (assistant and helpers): running version, newer release if any, read the code at that tag before saying how One works |
| UpdaterCheck.swift | dev only | `One --test-updates`, run by preflight |
| Brain.swift | service | the memory folder and room templates, persona (SOUL) |
| Helpers.swift | service + UI | background helper sessions, the Ready for you shelf |
| HelperTrail.swift | service | each helper's trail file (`Support/One/helpers/<id>.md`) and picking helpers back up after a restart (all at once, no limit on helpers working; max 2 times each) |
| HelperStop.swift | helpers | stopping one helper (orb right-click or long press, "Stop this helper" in its card, the assistant's `[stop-helper: …]` line), "Start again", pausing helpers for an update; `HelperCard` |
| HelperStopCheck.swift | check | `One --test-helper-stop` and `--test-update-helpers` (tools/helper-stop-check.sh, `make helperstop`): real stops end only that turn and stay stopped; a real update swap with a helper at work, which picks back up after |
| HelperFinish.swift | helpers | a helper is "done" only when its job really finished (`HelperEnd.of`): a turn cut off (engine restart, dropped connection, cancelled without Stop, out of room, no words) shows "Stopped · picking it back up" and resumes by itself; its old turn still running = wait and retry (not a cut-off); a real error = stopped with the reason |
| HelperCutCheck.swift | check | `One --test-helper-stop --cut` (tools/helper-cut-check.sh, `make helpercut`): the engine restarts under two working helpers (real engine): neither shows done early, both pick back up and finish with their real answer |
| HelperRecovery.swift | helpers | each job once (`Helpers.undouble` for a reply delivered twice, `Helpers.unique` for a repeated or already-running job, skips logged to hermes/logs/one-helpers.log); `startEngineAgain` when the engine died under helpers |
| HelperStress.swift | check | `One --test-helpers-stress <phase>` (tools/helpers-check.sh, `make helpers-check`, in preflight): 100 helpers against the stand-in engine `tools/fake-engine.py`, engine killed, One killed, an update; none lost, doubled, run twice or falsely done; every result filed; finished ones stay until dismissed |
| HelperCheck.swift | dev only | `One --test-helpers`, run by preflight |
| HelperBurst.swift | dev only | `tools/jobs-check.sh --helpers`: five helpers asked for at once against the real engine (all start together, the assistant still answers) |
| VoiceCheck.swift | dev only | `One --test-voice` (stop talking just this once: never mutes, next reply speaks; helper sound rules; stand-in voice), run by preflight |
| ShelfCopy.swift | UI | copying from the Ready for you shelf: ⌘C on a card (file + text for text files), the right-click menu (Copy file, Copy text, Show in Finder, Share…), the reader's Copy all; `One --test-shelf-copy <file>` |
| ShelfRead.swift | UI | the shelf's title row (`ShelfHeader`) and "Mark all read" (`Model.markShelfRead`: every card read in one save, their helpers seen); renders `shelf-read-new` / `shelf-read-done` |
| Pictures.swift | service | images and files attached to a message |
| Model.swift | state | `Model.shared`: stored state, bubbles, `Choices`, `Plain` step words |
| ModelSetup.swift | state | `extension Model`: onboarding, tour, sign-in, naming, routines, shared-room tending |
| ModelChat.swift | state | `extension Model`: sending, talking in the window, helpers, shelf, per-prompt notes, reveal |
| ModelHelpers.swift | state | `extension Model`: a finished helper stays orange until opened, one "by the way" line after the reply in progress, routines report together; `helperNews` status note |
| FollowUps.swift | state + UI | sending while busy: messages go into the running turn (engine mid-turn steer) or wait "Next up"; their tags and editor |
| FollowUpCheck.swift | check | `One --test-followups` (tools/followups-check.sh): real turn, messages during it, all arrive in order |
| HelperDoneCheck.swift | check | `One --test-helper-done` (tools/helper-done-check.sh, `make helperdone`): real helper finishes mid-reply, one "by the way" line after, orange until opened, good morning gets one report |
| HelperNote.swift | helpers | The note on every prompt to a helper session (do the work yourself, never `[helper: …]` lines) and the safety net that drops and logs a stray helper line |
| HelperNotesCheck.swift | check | `One --test-helper-notes` (tools/helper-notes-check.sh, `make helpernotes`): a helper started under an old SOUL, forked after the SOUL updates, asked "can you use my Chrome?" / "where do I save a password?" must name Connections › Browser / Passwords, never a Settings screen |
| SessionNotes.swift | chat | the notes every prompt carries, main chat and every helper turn alike (screen, logins, connections, hidden browser, GitHub, folders, version); old conversations keep their first system prompt, so these are how they learn what a newer One has |
| HelperSelfCheck.swift | check | `One --test-helper-self` (tools/helper-self-check.sh, `make helperself`): an opened helper asked for more work does it itself; stray `[helper: …]` lines are dropped and logged |
| Reader.swift | UI | `MarkdownText`: renders the assistant's Markdown replies |
| ChatText.swift | UI | `ChatText`: every chat message (the person's and the assistant's, home and helpers) as one selectable AppKit text with Copy / Copy as Markdown on right-click; `ReaderText` for the Ready for you and file readers |
| GlassCheck.swift | dev only | `One --test-glass`: a real window with home's glass; only the blur layer is left, blur 40 and saturate 1.4, after focus, resize and appearance changes |
| SelectCheck.swift | dev only | `One --test-select <case\|all>`: drag-select, ⌘C, ⌘A, right-click copy, link, choice row, scroll wheel, sent into a test window |
| SetupViews.swift | UI | root view, welcome, setup steps (`OnboardingView`) and their small pieces |
| MeCard.swift | UI | the brain and voice card (tap the assistant's name) |
| HomeView.swift | UI | home screen (greeting, helpers, last reply, ask box with + menu), choice buttons, ask cards |
| AskEditor.swift | UI | the ask box's typing area: wraps and grows to half the window, then scrolls with the cursor in view (`AskEditor`, an NSTextView; Return sends, Shift+Return new line), the expand button's `WritingPanel` (X, click outside, Esc), `LongMessageRender` for `long-*` renders |
| HelperConstellation.swift | UI | every helper as an orb on dashed orbits around the assistant, no limit (Claude Design "Helper View Options", A · Constellation): `HelperRings` layout checkpoints 4/8/10/15 and more orbits past 15, dust, hover pill |
| HomeChrome.swift | UI | home's title row (name pill, icon buttons, outlined Stop), smoked-glass `HomeBackdrop` (`WindowGlass` blur behind the window with AppKit's own grey layers hidden by `Glass.clearMaterial`, so it matches the design's CSS: blur 40, saturate 1.4, tint at `Glass.solid`; `GlassStill` draws it over a picture for `home-glass` renders), the name card's See-through slider, `StillScroll` for renders |
| HomeRender.swift | dev only | `--render-world` frames `home-4/8/10/15/22/33` (run from a test copy: it fills the model with made-up helpers) |
| Routines.swift | service | Routines panel data, read only: the engine's scheduled jobs (`hermes/cron/jobs.json` + last result), skills (engine + each room's `skills/learned`), jobs a Hermes outside One runs; cron schedules in plain words |
| RoutinesDial.swift | UI | the 24-hour day dial (Claude Design "Routines View Options", B): marks, bands, labels pushed apart, skills as stars; `One --render-routines <png>` |
| RoutinesView.swift | UI | the Routines panel (top row › Routines): dial around the assistant's orb, header counts, "Not on today's dial", runs outside One, star hover; closes with X, a click outside, Esc |
| RoutinesCard.swift | UI | the panel's floating card (Run now / Pause / Turn back on via `hermes cron`, Ask), the "want me to save how I did …?" question by the orb, the fading "I learned something new" notice |
| World.swift | UI | the orb (`Presence`), floating tiles, `WorldCanvas` |
| Connections.swift | UI + bridge | Connections world, Calendar/Mail bridge (`One --cal/--mail`), the "Something else…" brief (goal first, per the shipped `connect-goal-first` skill); what's connected is read off the main thread and kept (`ConnectionsWorld.Status`, `prefetch`), never per frame |
| ConnectionsCheck.swift | dev only | `One --test-connections-open [rounds] [png dir]` (from a test copy): opens Connections as the toolbar sheet in a test window and fails if any frame after the slide takes over 25 ms |
| Rooms.swift | UI | rooms sheet (`RoomsView`), share-a-room sheet, note panel |
| RoomMap.swift | UI | `RoomMap`: reads the brain's notes and lays out the map |
| SharedRooms.swift | service | `Shared`: rooms kept in iCloud Drive, invites, clashes |
| Floater.swift | UI | the floating orb window (`Floater`, `OrbHost`, card panel) |
| FloatViews.swift | UI | the orb's SwiftUI views (`Orb`, `FloatingOrb`, hint, transcript, scene) |
| TalkKey.swift | UI | push-to-talk key: `TalkKey`, `TalkKeys` hotkeys, `TalkKeySheet` |
| Previews.swift | dev only | scenes for `--render-world` |
| BundledSkills.swift | service | skills that ship with One (`skills/` in the repo, Resources/skills in the app): copied into the engine at install and launch, never over an edited copy; `One --test-skills` |
| Learning.swift | service | "tell me when I learn": reads the engine's skill log (`skills/.curator_ledger.jsonl`, by entry id, never the skills folder or the chat stream), matches lines to One's chats, decides new skill / fix / ask; `learning.json`; Undo (engine rollback, or Trash for room skills); `LearnedDirs` (private rooms' `skills/learned` in `skills.external_dirs`, never a shared room) |
| ModelLearning.swift | state | `extension Model`: counts each job's steps, the line + Undo after a new skill, the "want me to remember?" question ~2 min after a long or repeated job, taps (`choose`), saving into a room, Learned cards |
| LearningCheck.swift | dev only | `One --test-learning`, run by preflight (decisions on a made-up log) |
| LearningLiveCheck.swift | check | `One --test-learning-live` (tools/learning-check.sh, `make learning`): new skill, fix, long job, No, Yes, helper, Undo, with the real engine |
| Guards.swift | service | safety rules enforced in code: shared-room leak hold, experimental connections off until tested, friction log |
| GuardsCheck.swift | dev only | `One --test-guards`, run by preflight |
| BrowserKeeper.swift | service | keeps the hidden browser helpers use running: if nothing answers on the local `browser.cdp_url` port, starts Chrome again with the same saved profile, always headless (sign-ins survive a crash; optional `browser/keeper.json` names the profile); `One --browser-check` reports the browser and the Claude sign-in |
| HumanStep.swift | service + UI | a step only the person can do (code, passkey, security key, robot check): reads `handoff/<id>.request.json` written by the engine overlay `tools/overlay/tools/one_human_step.py`, shows the line with Done / I'm not at the Mac, writes `<id>.answer.json` |
| StepWindow.swift | UI | the window in front: a live view of the hidden browser's own tab over its DevTools port (picture stream, clicks, typing, paste, scroll), so the shared browser and its sign-ins are never restarted |
| BlockedAsk.swift | service + rule | blocked on a step only the person can do = ask, never substitute: the SOUL paragraph and the note on every prompt (main via `Helpers.note`, every helper turn via `Helpers.forHelper`), and One's own catch: every 4 s it reads the hidden browser's `/json/list`, and a Cloudflare / "verify you are human" tab that stays up 8 s gets a `handoff/blocked-*.request.json` with `ask: true` (card: Yes, show it / Not now, then the `StepWindow`), the browsing helper turns needsYes and is told to stop; its reply always ends on the ask; Done tells it to carry on as asked. Log `hermes/logs/one-blocked.log` |
| BlockedAskCheck.swift | dev only | `One --test-blocked` (preflight): the rule in SOUL and every helper turn, and the catch against a stand-in `/json/list` |
| HumanStepCheck.swift | dev only | `One --test-human-step` (run by `make handoff` / tools/handoff-check.sh): plays the person on a local test page in a throwaway Chrome |
| BrowserGuard.swift | service | no visible browser window without the person's yes: installs the engine plugin `tools/overlay/plugins/one-browser-guard` (blocks and logs `open -a`/AppleScript/non-headless browser launches in terminal, execute_code and browser_exec) at every engine start, keeps `browser.headed: false`, writes `guard/allow/<id>.json` when they say yes to "I need to open <browser> to <reason>. Can I?" (the folder lock makes that folder read-only for the engine); log `hermes/logs/one-browser-guard.log` |
| MyChrome.swift | service | Connections › Browser › Chrome: copies the person's own Chrome sign-ins (Hermes's real-profile snapshot, `tools/overlay/tools/one_my_chrome.py`, run by One outside the folder lock) into `browser/my-chrome`, points `browser/keeper.json` + `browser.cdp_url` at it (port 9223, always headless, `--disable-sync`), refreshes the copy before every start and on `browser/resync`; Disconnect deletes the copy; the per-prompt note says what's built; 1Password and Arc connect prompts |
| BrowserCheck.swift | dev only | `One --test-browser`, run by preflight |
| BrowserGuardCheck.swift | dev only | the browser guard part of `One --test-browser`; `tools/browser-guard-check.py` (the plugin on real commands) and `tools/browser-guard-engine-check.sh` (the real engine blocks) run in preflight |
| GatewayGuard.swift | service | stops the engine's background helper (gateway) only when it's stale, never a healthy one another One uses |
| FolderWatch.swift | service | notices a changed folder list (`folders`, `connectorReads`) and restarts the engine and its helper under the new lock once nothing is mid-reply, then carries on |
| RestartCheck.swift | dev only | `One --test-restart`, run by preflight |
| GatewayCheck.swift | dev only | `One --test-gateway`, run by preflight |
| App.swift | entry | `@main`, app delegate, CLI test hooks |
| JobsCheck.swift | dev only | `One --test-jobs` (three core jobs end to end, run by `make jobs`) and `FakeMail`, the test inbox behind `ONE_FAKE_MAIL` |

## Rules
1. `Env` depends on nothing in the app.
2. Services never import UI types. UI talks to services through `Model` (or the service's `shared`).
3. Running another program (`Process`) only happens in services (enforced: `process-area`).
4. Anything the engine can reach must be listed in `Access.profile()`; never widen it to all of home.
5. New area = new file; keep each under 600 lines (enforced: `file-length`).

## Extending
- New connection: a node in `worldNodes` or a `connections.json` entry, a `connect()` branch, and the
  paths it needs in `connectorReads`. Add a preflight check for it.
- New shipped skill: a folder `skills/<category>/<name>/SKILL.md` (description 60 characters max, trigger first). build.sh
  bundles it and `BundledSkills.sync()` installs it; change its content and the next release updates untouched copies.
  Never put one person's details (account ids, names, emails) in a shipped skill.
- New CLI test hook: `args.contains("--test-x")` in App.swift, `Env.selfTest = true` first (enforced).
