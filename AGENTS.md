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
    make lint          # One's own rules + their canaries + ruff/shellcheck; every baseline may only shrink
    make check         # the one local gate: format, identity, lint, doc drift, docs map, hooks. Before every commit.
    make full          # check + a fresh install into an empty folder: before every release
    make hooks         # once per clone: turn on the pre-commit hook (`make check` fails until you do)
    make prove         # just the canaries: every lint rule still fires on a snippet that breaks it
    make -s help 2>/dev/null || grep '##' Makefile   # every target, with what it costs

## Map
- [docs/INDEX.md](docs/INDEX.md): every doc
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): the areas in `Sources/` and what may call what.
  Its Area column is read by the lint, so a new file needs its row in the same change.
- [docs/PRODUCT_SENSE.md](docs/PRODUCT_SENSE.md): who One is for, what it must never do
- [docs/DESIGN.md](docs/DESIGN.md): the world look, words, renders-before-install
- [docs/design-docs/golden-principles.md](docs/design-docs/golden-principles.md): every rule and the check that enforces it
- [docs/SECURITY.md](docs/SECURITY.md): secrets, the folder lock, the test world, trust boundaries
- [docs/QUALITY_SCORE.md](docs/QUALITY_SCORE.md): how solid each area is
- [docs/exec-plans/](docs/exec-plans/README.md): plans in progress and done, and the tech-debt tracker

## Where the rules live
- `tools/lint/one-lint.py` — One's own rules. Each prints a `FIX:`; follow it. List them: `--list`.
  Add one: a function, a row in `RULES`, and a canary in `tools/lint/canaries/` (`--prove` checks it blocks).
- `tools/lint/ext-lint.py` — ruff (bug rules) and shellcheck over One's Python and shell.
- Old debt is in `tools/lint/baseline.json` and `tools/lint/ext-baseline.json`. Both may only shrink
  (`--update` after paying debt down). Never add to one; fix the finding instead.
- Three places, same rules: `.githooks/pre-commit`, `make check`, and
  `.github/workflows/rules.yml` on every pull request (no `paths-ignore`, so a docs-only one too).
  `tools/hooks-check.sh` fails if the three drift apart.

## Rules that bite
- **A test never runs on the person's Mac by accident.** It opens windows and takes the focus.
  Checks run in CI (GitHub). The exception is a *live* check that needs One's installed engine and
  the owner's own subscription: its make target sets `ONE_LIVE_CHECK=1` (`make jobs`, `make learning`,
  `make helperdone`, …) and the script says so in a `# runs:` header. `make check` runs no test.
- **Every check script must be runnable from somewhere.** A `tools/*-check.*` is in `tools/preflight.sh`
  or a workflow, or carries `# runs: owner-only (make <target>) — <why>` and has that target
  (enforced: `no-orphan-check`). A check reachable from nowhere is a check that silently passes.
- **The person's Mac is production.** Their Documents, settings, One's folder and the installed app are
  never read-written by a test, check or render. A test mode starts with `TestWorld.enter()` (refuses as
  the real One, refuses the real One folder) and runs from `APP=$(tools/test-copy.sh <name>)` (own
  bundle id, own settings). Never run a `--test-*` mode on `build/app.noindex/One.app` or /Applications/One.app.
- A check that drives the real engine goes through `tools/engine-check.sh`, never its own copy of the
  test copy, clean environment and timeout (enforced: `engine-check-wrapper`).
- Never run One's `--install-test` without `ONE_SUPPORT_DIR=<empty dir>`.
- Max 600 lines per file, in any language. Split by area (see ARCHITECTURE.md); don't create a "Misc" file.
- Never hardcode the assistant's name in UI text (`m.name`). Plain words only, no jargon.
- Visual changes: render (`One --render-world <prefix>`), show, get a yes, then install.
- Commits are signed. `main` has linear history.
- One is a personal project: every commit, tag, PR, release and comment is the **Donnadieu** account (Donnadieu <donnadieu.86@gmail.com>, GPG ABAFD67086BDA7E0). The Andela work account `donnadieu-andela` must leave no trace here. `make hooks` pins the clone; `tools/check-identity.sh` runs in pre-commit, pre-push, `make check` and CI. For `gh`, use `GH_TOKEN=$(gh auth token --user Donnadieu)` instead of trusting the active account (it flips when Omar does Andela work, and `gh auth switch` fails inside One's folder lock).

## Skills (the compound loop)
Repo playbooks live in [.agents/skills/](.agents/skills/). Before work: load the one that matches.
After work: if you learned something reusable, update that skill. If the same mistake shows up
twice, add a rule to `tools/lint/one-lint.py` so it can't happen a third time.
