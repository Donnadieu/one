# One

A one-button personal AI assistant for Mac, for people who have never opened a terminal.
A SwiftUI app (the face) runs Hermes Agent (the engine) inside a macOS folder lock. Setup is
spoken, the UI is an orb with things floating around it, and a person approves money, sending,
posting and deleting. Open source (MIT), not a business.

## Stack
Swift 6 toolchain (language mode 5) / SwiftUI + AppKit / macOS 14+, Apple Silicon / no Xcode project:
`swiftc` via `build.sh`. Engine: Hermes Agent over ACP (JSON-RPC on stdio). Voice: Kokoro (local).

## Commands
    make build         # build build/One.app
    make format        # format Sources/ (swift-format, config in .swift-format)
    make lint          # One's own rules + baseline ratchet
    make check         # format-check + lint + preflight: must pass before every commit
    make full          # check + a fresh install into an empty folder: before every release
    make hooks         # once per clone: turn on the pre-commit hook

## Map
- [docs/INDEX.md](docs/INDEX.md): every doc
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the areas in `Sources/` and what may call what
- [docs/PRODUCT_SENSE.md](docs/PRODUCT_SENSE.md): who One is for, what it must never do
- [docs/DESIGN.md](docs/DESIGN.md): the world look, words, renders-before-install
- [docs/design-docs/golden-principles.md](docs/design-docs/golden-principles.md): rules and the check that enforces each
- [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md): how solid each area is
- [docs/exec-plans/](docs/exec-plans/README.md): plans in progress and done

## Rules that bite
- Every rule in `tools/lint/one-lint.py` prints a `FIX:`; follow it. List them: `tools/lint/one-lint.py --list`.
- Old debt is in `tools/lint/baseline.json`. It may only shrink (`--update` after paying it down). Never add to it.
- Max 600 lines per file. Split by area (see ARCHITECTURE.md); don't create a "Misc" file.
- Never hardcode the assistant's name in UI text (`m.name`). Plain words only, no jargon.
- **The person's Mac is production.** Their Documents, settings, One's folder and the installed app are never
  read-written by a test, check or render. A test mode starts with `TestWorld.enter()` (refuses as the real One)
  and runs from `APP=$(tools/test-copy.sh <name>)` (own bundle id, own settings) with its own scratch folder and
  fixtures. Never run a `--test-*` mode on `build/app.noindex/One.app` or /Applications/One.app.
- Never run One's `--install-test` without `ONE_SUPPORT_DIR=<empty dir>`.
- Visual changes: render (`One --render-world <prefix>`), show, get a yes, then install.
- Commits are signed. `main` has linear history.
- One is a personal project: every commit, tag, PR, release and comment is the **Donnadieu** account (Donnadieu <donnadieu.86@gmail.com>, GPG ABAFD67086BDA7E0). The Andela work account `donnadieu-andela` must leave no trace here. `make hooks` pins the clone; `tools/check-identity.sh` runs in pre-commit, pre-push, `make check` and CI. For `gh`, use `GH_TOKEN=$(gh auth token --user Donnadieu)` instead of trusting the active account (it flips when Omar does Andela work, and `gh auth switch` fails inside One's folder lock).

## Skills (the compound loop)
Repo playbooks live in [.agents/skills/](.agents/skills/). Before work: load the one that matches.
After work: if you learned something reusable, update that skill. If the same mistake shows up
twice, add a rule to `tools/lint/one-lint.py` so it can't happen a third time.
