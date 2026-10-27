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
| Installer.swift | service | install Hermes (pinned commit), KeePass overlay, provider sign-in, tools Python |
| Engine.swift | service | the ACP connection to Hermes: sessions, prompts, permissions |
| Voice.swift | service | Kokoro voice process, speaking, listening (push to talk) |
| Updater.swift | service | check GitHub releases every 15 min (ETag, back-off), announce a new version once (notification, orb note, spoken line), download, swap the app |
| UpdaterCheck.swift | dev only | `One --test-updates`, run by preflight |
| Brain.swift | service | the memory folder and room templates, persona (SOUL) |
| Helpers.swift | service + UI | background helper sessions, the Ready for you shelf |
| HelperTrail.swift | service | each helper's trail file (`Support/One/helpers/<id>.md`) and picking helpers back up after a restart (all at once, no limit on helpers working; max 2 times each) |
| HelperStop.swift | helpers | stopping one helper (orb right-click or long press, "Stop this helper" in its card, the assistant's `[stop-helper: …]` line), "Start again", pausing helpers for an update; `HelperCard` |
| HelperStopCheck.swift | check | `One --test-helper-stop` and `--test-update-helpers` (tools/helper-stop-check.sh, `make helperstop`): real stops end only that turn and stay stopped; a real update swap with a helper at work, which picks back up after |
| HelperCheck.swift | dev only | `One --test-helpers`, run by preflight |
| HelperBurst.swift | dev only | `tools/jobs-check.sh --helpers`: five helpers asked for at once against the real engine (all start together, the assistant still answers) |
| VoiceCheck.swift | dev only | `One --test-voice` (stop talking just this once: never mutes, next reply speaks; stand-in voice), run by preflight |
| ShelfCopy.swift | UI | copying from the Ready for you shelf: ⌘C on a card (file + text for text files), the right-click menu (Copy file, Copy text, Show in Finder, Share…), the reader's Copy all; `One --test-shelf-copy <file>` |
| Pictures.swift | service | images and files attached to a message |
| Model.swift | state | `Model.shared`: stored state, bubbles, `Choices`, `Plain` step words |
| ModelSetup.swift | state | `extension Model`: onboarding, tour, sign-in, naming, routines, shared-room tending |
| ModelChat.swift | state | `extension Model`: sending, talking in the window, helpers, shelf, per-prompt notes, reveal |
| ModelHelpers.swift | state | `extension Model`: a finished helper stays orange until opened, one "by the way" line after the reply in progress, routines report together; `helperNews` status note |
| FollowUps.swift | state + UI | sending while busy: messages go into the running turn (engine mid-turn steer) or wait "Next up"; their tags and editor |
| FollowUpCheck.swift | check | `One --test-followups` (tools/followups-check.sh): real turn, messages during it, all arrive in order |
| HelperDoneCheck.swift | check | `One --test-helper-done` (tools/helper-done-check.sh, `make helperdone`): real helper finishes mid-reply, one "by the way" line after, orange until opened, good morning gets one report |
| HelperNote.swift | helpers | The note on every prompt to a helper session (do the work yourself, never `[helper: …]` lines) and the safety net that drops and logs a stray helper line |
| HelperSelfCheck.swift | check | `One --test-helper-self` (tools/helper-self-check.sh, `make helperself`): an opened helper asked for more work does it itself; stray `[helper: …]` lines are dropped and logged |
| Reader.swift | UI | `MarkdownText`: renders the assistant's Markdown replies |
| ChatText.swift | UI | `ChatText`: every chat message (the person's and the assistant's, home and helpers) as one selectable AppKit text with Copy / Copy as Markdown on right-click; `ReaderText` for the Ready for you and file readers |
| SelectCheck.swift | dev only | `One --test-select <case\|all>`: drag-select, ⌘C, ⌘A, right-click copy, link, choice row, scroll wheel, sent into a test window |
| SetupViews.swift | UI | root view, welcome, setup steps (`OnboardingView`) and their small pieces |
| MeCard.swift | UI | the brain and voice card (tap the assistant's name) |
| HomeView.swift | UI | home screen, ideas to try, choice buttons, ask cards |
| World.swift | UI | the orb (`Presence`), floating tiles, `WorldCanvas` |
| Connections.swift | UI + bridge | Connections world, Calendar/Mail bridge (`One --cal/--mail`), the "Something else…" brief (goal first, per the shipped `connect-goal-first` skill) |
| Rooms.swift | UI | rooms sheet (`RoomsView`), share-a-room sheet, note panel |
| RoomMap.swift | UI | `RoomMap`: reads the brain's notes and lays out the map |
| SharedRooms.swift | service | `Shared`: rooms kept in iCloud Drive, invites, clashes |
| Floater.swift | UI | the floating orb window (`Floater`, `OrbHost`, card panel) |
| FloatViews.swift | UI | the orb's SwiftUI views (`Orb`, `FloatingOrb`, hint, transcript, scene) |
| TalkKey.swift | UI | push-to-talk key: `TalkKey`, `TalkKeys` hotkeys, `TalkKeySheet` |
| Previews.swift | dev only | scenes for `--render-world` |
| BundledSkills.swift | service | skills that ship with One (`skills/` in the repo, Resources/skills in the app): copied into the engine at install and launch, never over an edited copy; `One --test-skills` |
| Guards.swift | service | safety rules enforced in code: shared-room leak hold, experimental connections off until tested, friction log |
| GuardsCheck.swift | dev only | `One --test-guards`, run by preflight |
| BrowserKeeper.swift | service | keeps the hidden browser helpers use running: if nothing answers on the local `browser.cdp_url` port, starts Chrome again with the same saved profile (sign-ins survive a crash; optional `browser/keeper.json` names the profile); `One --browser-check` reports the browser and the Claude sign-in |
| HumanStep.swift | service + UI | a step only the person can do (code, passkey, security key, robot check): reads `handoff/<id>.request.json` written by the engine overlay `tools/overlay/tools/one_human_step.py`, shows the line with Done / I'm not at the Mac, writes `<id>.answer.json` |
| StepWindow.swift | UI | the window in front: a live view of the hidden browser's own tab over its DevTools port (picture stream, clicks, typing, paste, scroll), so the shared browser and its sign-ins are never restarted |
| HumanStepCheck.swift | dev only | `One --test-human-step` (run by `make handoff` / tools/handoff-check.sh): plays the person on a local test page in a throwaway Chrome |
| BrowserCheck.swift | dev only | `One --test-browser`, run by preflight |
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
