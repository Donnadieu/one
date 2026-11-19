# Docs

- [ARCHITECTURE.md](ARCHITECTURE.md): areas, dependencies, where to add things
- [PRODUCT_SENSE.md](PRODUCT_SENSE.md): users, journeys, non-goals
- [DESIGN.md](DESIGN.md): visual language and wording
- [design-docs/golden-principles.md](design-docs/golden-principles.md): enforced rules (the mechanical *what*)
- [design-docs/core-beliefs.md](design-docs/core-beliefs.md): the agent-first *why* behind golden principles
- [design-docs/improve-score.md](design-docs/improve-score.md): One gets better by itself, step 1: the look-only score, its files and `One --improve`
- [design/safety-features.md](design/safety-features.md): five safety features for running unattended (stop means stop, budgets, health watchdog, repo turns, phone hand-offs), screens in `design/`
- [design/bots.md](design/bots.md): bots, a helper you keep (B · Moons, built in 0.9.123): research, the two directions, as built, open questions
- [design-docs/ai-picker-extras.md](design-docs/ai-picker-extras.md): design for "Other AIs" (bring your own
  key) in Switch AI and the thinking level under the brain pills
- [RELIABILITY.md](RELIABILITY.md): reliability targets and what enforces each one
- [SECURITY.md](SECURITY.md): secrets handling, the folder lock, trust boundaries, open findings
- `tools/doc-drift-check.py`: CI check that a PR touching sandbox/updater/secrets/browser-guard code
  also touches the doc that describes it (part of `make check` as `make docdrift`); see the mapping
  and the `[skip-doc-drift]` escape hatch at the top of the script.
- `tools/doc-gardening.py`: weekly cron (`.github/workflows/doc-gardening.yml`, + manual
  `workflow_dispatch`) that checks every relative link in docs/AGENTS.md/README.md, that
  docs/INDEX.md (this file) reaches every doc under docs/, and that the doc-drift mapping above
  doesn't point at a missing file; `--fix` repairs unambiguous moved-file links and opens a small
  PR when it changes anything. See `.agents/skills/doc-gardening/SKILL.md` to run it by hand.
- `tools/knowledge-base-check.sh`: knowledge-base integrity test (part of `make check` as
  `make knowledgebase`, and of `.github/workflows/rules.yml` on every pull request) — every doc this
  repo's harness mandates exists, `doc-gardening.py --check` is clean (delegated to, never
  duplicated), and AGENTS.md stays a table of contents (≤200 lines).
- `tools/lint/one-lint.py` + `tools/lint/repo_rules.py`: One's own rules, each with a one-line why
  and a `FIX:`. `--list` prints them all; `--prove` runs each against the snippet in
  `tools/lint/canaries/` that breaks it, so a refactor can't quietly neuter one. Old debt is
  grandfathered in `tools/lint/baseline.json`, which may only shrink.
- `tools/lint/ext-lint.py`: ruff (bug rules only) and shellcheck over One's own Python and shell, on
  the same shrink-only ratchet (`tools/lint/ext-baseline.json`).
- `tools/hooks-check.sh`: the git hooks are armed in this clone (`make hooks`), and the pre-commit
  hook, `make check` and CI haven't drifted apart about what the rules are.
- `tools/engine-check.sh`: the one wrapper every live check that drives One's real engine goes
  through — the test copy, the throwaway One folder, the clean environment and the timeout, in one
  place instead of ten copies that had drifted.
- [decisions.md](decisions.md): design decisions that are easy to undo by accident, newest first
- [QUALITY_SCORE.md](QUALITY_SCORE.md): per-area grading
- [exec-plans/README.md](exec-plans/README.md): active and completed plans, tech debt
- [first-time-user-test.md](first-time-user-test.md): the kit for watching one non-technical
  friend install and use One with no help, and filing every stuck moment into the friction log
