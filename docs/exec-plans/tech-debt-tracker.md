# Tech debt

## High
- Files over 600 lines (see `tools/lint/baseline.json`): split Model, Views, Floater, Rooms by area.
- Hermes patch (KeePass) until upstreamed to NousResearch/hermes-agent.

## Medium
- Old dead code: `GoogleSignIn` (dev-only), kept until Google sign-in is decided for good.
- No automated test for helpers, voice playback, or the full update swap.
