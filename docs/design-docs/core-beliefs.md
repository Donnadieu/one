# Core beliefs

Golden principles (`design-docs/golden-principles.md`) are the mechanical *what*
— each rule names the test or lint that enforces it. This doc is the *why*
behind the judgment calls those rules can't fully mechanize: the beliefs that
decide how a new feature, file, or safety boundary should be shaped before any
lint gets a chance to check it.

## The person's Mac is production, always

There is no staging environment. Every test, check, and render must prove it
never touches the person's real files, settings, or shelf — `TestWorld.enter()`
is the single door into a test world, enforced by `one-lint: test-selftest`.
A "quick manual check" against the real bundle id is not a smaller version of
this rule; it is the exact mistake it exists to prevent (Oct 27: a check run
as the real One moved every file in Documents › Made by Elias into a test
folder).

## Enforce invariants in code, not in review

A safety promise that can be code goes in code, with a preflight check behind
it (`Sources/Guards.swift`). README keeps an honest "enforced vs relies on the
assistant" list in sync. A rule that only lives in SOUL text or a code-review
comment will eventually be violated by whichever agent — human or model —
never saw it.

## Dependencies point one way

UI → `Model` → services → `Env`/foundation (docs/ARCHITECTURE.md). A service
reaching back up to call `Model.shared` isn't a shortcut, it's a cycle: it
makes the file's real dependents unknowable by reading it top to bottom. Keep
services dumb and stateless where possible; let `Model` be the one place that
holds app state and makes decisions.

## Plain words over jargon, everywhere a person can see them

One is for people who have never opened a terminal. "API key", "OAuth",
"sandbox", "repo" — anything on that list in UI text is a bug
(`one-lint: ui-jargon`), not a style nit. If an engine-facing word would leave
a regular person asking "what does that mean?", it hasn't been translated
yet.

## Old debt only shrinks

The structural lint's baseline (`tools/lint/baseline.json`) is a ceiling, not
a floor. Grandfathering existing debt when a new rule lands is how a rule
survives contact with a real codebase; letting the ceiling rise again is how
a ratchet dies. CI checks the baseline never grew versus `main`, because the
easy way to beat a ratchet is to edit the ratchet.

## Point rather than duplicate

Knowledge about this repo lives in exactly one file — `AGENTS.md` points at
`docs/INDEX.md`, which points at everything else. A second copy of an
explanation is not redundancy, it is a drift source: the first time one copy
changes and the other doesn't, an agent reading the stale one makes a wrong
call with total confidence.

## A violation nobody can see isn't actually prevented

Every rule that matters enough to write down here gets, eventually, a test or
a lint with a `FIX:` line an agent can act on without asking a human first.
Until then it is a stated gap in `QUALITY_SCORE.md` or the tech-debt tracker,
not a quiet assumption that everyone already knows not to do that.
