# Tech debt

## High
- Files over 600 lines (see `tools/lint/baseline.json`): split Model, Views, Floater, Rooms by area.
- Hermes patch (KeePass) until upstreamed to NousResearch/hermes-agent.

## Medium
- Old dead code: `GoogleSignIn` (dev-only), kept until Google sign-in is decided for good.
- No automated test for helpers, voice playback, or the full update swap.
- Dependency-direction debt (see `tools/lint/baseline.json`, rule `dependency-direction`,
  docs/ARCHITECTURE.md rule 6): `Updater.swift`, `Helpers.swift`, `Pictures.swift` (services) call
  `Model.shared` directly instead of returning a value or taking a closure/delegate — a reverse
  dependency on the state layer above them, grandfathered when the check was added. Pay down by
  threading the needed state/callback in from `Model` instead of reaching up for it.
