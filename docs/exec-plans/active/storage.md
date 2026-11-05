# Storage plan: rooms, notes and recipes (Nov 2026)

Goal: the brain is plain files the person owns (`My Brain`); One keeps rebuildable machinery next to it
(a search index, dated copies, the engine's front page) and never lets a private room leak. Privacy comes from
each room's `room.yaml` (`private: true|false`), checked in code by `RoomPrivacy`, never from a folder name.

## The steps
| # | Step | Status |
|---|---|---|
| 0 | Safety copy of the brain and the engine home before anything moves | done by hand on the first Mac (not app code) |
| 1 | Fix existing damage (self-pointing shortcuts, a missing sign-in file) | by hand, outside this repo |
| 2 | Shortcut guard + room.yaml privacy (`LinkGuard`, `SkillWalkFix`, `RoomPrivacy`, `BrainLayout`, `LearnedDirs`) | **this release** (#90) |
| 3 | Hourly instant copies + restore (`History`, `HistoryRestore`, Earlier versions, `One --restore`) | **this release** (#91) |
| 4 | Search index (`BrainIndex`, `One --search`; no room named = private rooms left out, in code) | **this release** (#89) |
| 5 | Notes move: `My Brain/assistant/`, the front page (USER.md from live Connections, MEMORY.md filed and rebuilt) | app side **this release** (`FrontPage`, #88); moving an existing brain's notes is a per-person yes |
| 6 | Recipes move: flat `skills/<name>`, the recipe filer (`One --file-skills`) | filer **this release** (`SkillFiler`, #88): non-private room → `<room>/skills/<name>` only when the engine reads it, private room → its own `skills/<name>`, no room → `assistant/skills/<name>`; moving old recipes is a per-person yes |
| 7 | Nightly tidy, report-only for a week | not started |
| 8 | Nightly tidy, safe edits on (filing, front page rebuild, up to 5 lesson edits, Undo last night) | not started |
| 9 | Off-Mac locked copy (opt-in card, nightly `aea` archive into iCloud Drive) | **this release** (`Offsite`, `OffsiteCard`, #91) |
| 10 | Shared room plumbing (one-way mirrors, linked transcripts, broken links) | not started |
| 11 | Fresh-install test into an empty folder and an empty brain | not started |

Also in this release: "One gets better by itself", step 1, the look-only score (`Improve*`, `One --improve`,
#92), and the correction finder that now feeds the friction log (`Corrections`).

## How the pieces agree (release integration)
- One source of truth for privacy: `RoomPrivacy.isPrivate` (no room.yaml = private; a shared room never). Used by
  the share sheet, `LearnedDirs`, the search index (`BrainRooms`), the recipe filer and the score's private marks
  (`ImprovePrivate`). History and the locked copy keep every room (the locked copy is encrypted) and so make no
  privacy choice; the front page never reads a room.
- The engine reads `assistant/skills` (once) and each non-private, non-shared room's `skills`
  (`LearnedDirs.wanted`, the authority). The filer only moves a recipe into a non-private room's folder that
  this list contains.
- The storage command lines go through `StorageCLI` (App.swift is at the 600-line limit); `--search` stays in
  `Bridge.run`.

## Not done yet
- "Yes, remember it" still writes `<room>/skills/learned/<name>` (the engine still reads it, since it walks
  `<room>/skills` down); moving it to the flat layout needs the live learning check (`make learning`).
- `assistant/routines.md` (a readable list of routines) isn't written yet; it belongs to the nightly tidy.
