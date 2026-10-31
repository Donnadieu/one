# Docs

- [ARCHITECTURE.md](ARCHITECTURE.md): areas, dependencies, where to add things
- [PRODUCT_SENSE.md](PRODUCT_SENSE.md): users, journeys, non-goals
- [DESIGN.md](DESIGN.md): visual language and wording
- [design-docs/golden-principles.md](design-docs/golden-principles.md): enforced rules (the mechanical *what*)
- [design-docs/core-beliefs.md](design-docs/core-beliefs.md): the agent-first *why* behind golden principles
- [RELIABILITY.md](RELIABILITY.md): reliability targets and what enforces each one
- [SECURITY.md](SECURITY.md): secrets handling, the folder lock, trust boundaries, open findings
- `tools/doc-drift-check.py`: CI check that a PR touching sandbox/updater/secrets/browser-guard code
  also touches the doc that describes it (part of `make check` as `make docdrift`); see the mapping
  and the `[skip-doc-drift]` escape hatch at the top of the script.
- [QUALITY_SCORE.md](QUALITY_SCORE.md): per-area grading
- [exec-plans/README.md](exec-plans/README.md): active and completed plans, tech debt
