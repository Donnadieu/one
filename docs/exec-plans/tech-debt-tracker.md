# Tech debt

## High
- Files over 600 lines (see `tools/lint/baseline.json`): split Model, Views, Floater, Rooms by area.
- Hermes patch (KeePass) until upstreamed to NousResearch/hermes-agent.

## Medium
- Old dead code: `GoogleSignIn` (dev-only), kept until Google sign-in is decided for good.
- No automated test for helpers, voice playback, or the full update swap.
- No automated knowledge-base-integrity test (unlike repos hardened with the newer
  harness-engineering skill's artifact 8: a `test/architecture/knowledge-base.*`-style check that
  asserts every doc link resolves, `docs/INDEX.md` agrees with disk both ways, and no doc is
  orphaned). `tools/doc-drift-check.py` (added 0.9.82) covers the narrower, higher-value case of
  sensitive-code-changed-without-its-doc, but doesn't check link integrity or orphaned docs.
- Dependency-direction debt (see `tools/lint/baseline.json`, rule `dependency-direction`,
  docs/ARCHITECTURE.md rule 6): `Updater.swift`, `Helpers.swift`, `Pictures.swift` (services) call
  `Model.shared` directly instead of returning a value or taking a closure/delegate — a reverse
  dependency on the state layer above them, grandfathered when the check was added. Pay down by
  threading the needed state/callback in from `Model` instead of reaching up for it.
