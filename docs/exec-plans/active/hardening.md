# One: hardening plan (Oct 2026)

Goal: make what exists solid before adding anything. Feature freeze while this runs.

## A. Guardrails first
1. **Preflight test run** (`tools/preflight.sh`), required before every release:
   build, bundle contents (no secrets), version match, KeePass overlay on a pristine engine file,
   folder lock (allows One's data and KeePass, blocks the rest of home), updater sees a newer
   version, screens render. `--full` adds a fresh install into an empty folder.
2. **GitHub CI**: the parts that need no login run on every push (build, bundle check, renders).

## B. Works the same on any Mac
3. One builds everything itself during setup: the tools Python (`tools-venv`) and its
   `~/.cache/one-py` link, the vault/browser config written by Connect, the overlay.
   Nothing borrowed from Omar's Mac. Proven by a fresh install on an empty folder.

## C. Stop patching Hermes by hand
4. Pin the Hermes version One installs (tested one, not "latest").
5. If the KeePass patch can't apply, say so in plain words (not a silent loss).
6. Offer the KeePass backend upstream to NousResearch/hermes-agent as a pull request.

## D. Readable code
7. Split `Sources/main.swift` by area (setup, engine, voice, orb/talk, helpers, rooms,
   connections, updater, renders). Delete dead code (old Connections list). Same behaviour,
   checked by preflight.

## E. Safety in code, not just instructions
8. Shared rooms: One holds back any new file in a shared room that copies text from your
   other rooms, and tells you.
9. Experimental connections stay off until their test passed.
10. README lists honestly what still depends on the assistant following instructions.

## D2. Harness engineering + guardrails (Omar: "like RuboCop with custom cops")
Follows the Forge `harness-engineering` skill, adapted to Swift.
- **Agent map:** `AGENTS.md` (+ `CLAUDE.md` = `@AGENTS.md`), `docs/INDEX.md`, `docs/ARCHITECTURE.md`
  (areas + which may depend on which), `docs/DESIGN.md` (world look: colors, rings, tiles, plain words),
  `docs/PRODUCT_SENSE.md` (non-technical user, simplicity, human in the loop), golden principles,
  `docs/QUALITY_SCORE.md`, exec-plans (this plan moves there).
- **Formatter + linter:** Apple's `swift-format` (ships with Xcode) with a repo config: `format` and `lint` commands.
- **Custom rules ("cops")** in `tools/lint/one-lint.py`, each with a `FIX:` message an agent can follow:
  max file length, no hardcoded assistant names in UI text (`m.name` only), no jargon words in user-facing
  strings, no `pkill`/broad kills, no secrets or Google client files bundled, no Telegram/WhatsApp,
  no direct `Process` calls outside the engine/bridge areas, every CLI test hook sets `Env.selfTest`,
  no email-send path in Bridge, `private` areas don't reach into each other.
- **Ratchet:** existing debt is recorded in a baseline and can only shrink; new code must be clean.
  CI fails if the baseline grows.
- **Enforcement:** `make check` = format check + lint + one-lint + preflight; git pre-commit hook for the
  fast part; GitHub runs all of it.
- **Teach the agents:** the rules live in AGENTS.md and a repo skill (`.agents/skills/`) with the
  compound loop: load before work, update the skill when a lesson is learned, add a cop when a mistake repeats.

## F. The product plan
11. Sign the app (Apple Developer ID + notarization) so first open needs no Open Anyway.
12. Three jobs made flawless, with end-to-end checks: sort my files, handle my inbox,
    watch a price and book only with my OK.
13. First-time-user test: a kit for watching one non-technical friend install with no help.
14. Friction log: tell Elias "that annoyed me" and it's written to a list we fix weekly.

Order: A → B → C → D → E → F. Report after each step: what was checked, what wasn't.

## Progress (2026-10-24)
- [x] 1 Preflight · [x] 2 CI (newest macOS image) · [x] 3 builds its own tools · [x] 4 Hermes pinned · [x] 5 plain-words KeePass notice
- [ ] 6 KeePass upstream PR (in progress)
- [x] 7 split into area files, every file < 600 lines, dead code removed
- [x] D2 harness: AGENTS.md, docs map, swift-format, 9 custom rules with FIX, shrinking baseline, pre-commit hook, `make check`, repo skill
- [x] 8 shared-room leak hold (code) · [x] 9 experimental connections off until tested (code, verified in engine) · [x] 10 README honest list
- [ ] 11 Apple signing: blocked on Omar's Apple ID login
- [ ] 12 three jobs end-to-end check (in progress) · [x] 13 first-time-user kit (docs/first-time-user-test.md) · [x] 14 friction log (code)
