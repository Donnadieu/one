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

## F. The product plan
11. Sign the app (Apple Developer ID + notarization) so first open needs no Open Anyway.
12. Three jobs made flawless, with end-to-end checks: sort my files, handle my inbox,
    watch a price and book only with my OK.
13. First-time-user test: a kit for watching one non-technical friend install with no help.
14. Friction log: tell Elias "that annoyed me" and it's written to a list we fix weekly.

Order: A → B → C → D → E → F. Report after each step: what was checked, what wasn't.
