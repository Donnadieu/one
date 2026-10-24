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
| Updater.swift | service | check GitHub releases, download, swap the app |
| Brain.swift | service | the memory folder and room templates, persona (SOUL) |
| Helpers.swift | service + UI | background helper sessions, the Ready for you shelf |
| Pictures.swift | service | images and files attached to a message |
| Model.swift | state | `Model.shared`: stored state, bubbles, `Choices`, `Plain` step words |
| ModelSetup.swift | state | `extension Model`: onboarding, tour, sign-in, naming, routines, shared-room tending |
| ModelChat.swift | state | `extension Model`: sending, talking in the window, helpers, shelf, per-prompt notes, reveal |
| Reader.swift | UI | `MarkdownText`: renders the assistant's Markdown replies |
| SetupViews.swift | UI | root view, welcome, setup steps (`OnboardingView`) and their small pieces |
| MeCard.swift | UI | the brain and voice card (tap the assistant's name) |
| HomeView.swift | UI | home screen, ideas to try, choice buttons, ask cards |
| World.swift | UI | the orb (`Presence`), floating tiles, `WorldCanvas` |
| Connections.swift | UI + bridge | Connections world, Calendar/Mail bridge (`One --cal/--mail`) |
| Rooms.swift | UI | rooms sheet (`RoomsView`), share-a-room sheet, note panel |
| RoomMap.swift | UI | `RoomMap`: reads the brain's notes and lays out the map |
| SharedRooms.swift | service | `Shared`: rooms kept in iCloud Drive, invites, clashes |
| Floater.swift | UI | the floating orb window (`Floater`, `OrbHost`, card panel) |
| FloatViews.swift | UI | the orb's SwiftUI views (`Orb`, `FloatingOrb`, hint, transcript, scene) |
| TalkKey.swift | UI | push-to-talk key: `TalkKey`, `TalkKeys` hotkeys, `TalkKeySheet` |
| Previews.swift | dev only | scenes for `--render-world` |
| App.swift | entry | `@main`, app delegate, CLI test hooks |

## Rules
1. `Env` depends on nothing in the app.
2. Services never import UI types. UI talks to services through `Model` (or the service's `shared`).
3. Running another program (`Process`) only happens in services (enforced: `process-area`).
4. Anything the engine can reach must be listed in `Access.profile()`; never widen it to all of home.
5. New area = new file; keep each under 600 lines (enforced: `file-length`).

## Extending
- New connection: a node in `worldNodes` or a `connections.json` entry, a `connect()` branch, and the
  paths it needs in `connectorReads`. Add a preflight check for it.
- New CLI test hook: `args.contains("--test-x")` in App.swift, `Env.selfTest = true` first (enforced).
