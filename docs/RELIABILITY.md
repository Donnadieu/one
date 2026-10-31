# Reliability

One is a native macOS desktop app with a background engine (Hermes, installed
per-user), not a hosted service — these targets are about what runs on the
person's own Mac, not about a server One's team operates.

## Targets

- **Startup / getting-ready time**: the window should open and either show a
  real conversation or the getting-ready layer within seconds of launch, never
  a blank or frozen window. `StartupGate`/`ReadyLayer` never stay stuck: helpers
  stop holding the chat after 60 s, "no engine after 90 s or a failed start"
  shows a plain line + Try again (`Engine.startOver` replaces a hung start).
- **Crash-free session rate**: not currently measured (no crash reporter is
  wired up). NOT YET ENFORCED — a gap, not a target assumed to be met.
- **Update-mechanism safety**: an update must never leave the app partially
  swapped, and must never install a build it didn't actually fetch from this
  project's own releases.
  - `Updater.pick` only considers a release's `browser_download_url` when its
    host is `github.com` or a `*.githubusercontent.com` asset host (defense
    in depth against a tampered or spoofed releases response).
  - Before the swap script replaces the installed bundle, the downloaded
    app's code signature must verify (`codesign --verify --deep --strict`)
    **and** its signing team must match the running app's; a tampered or
    unsigned download is left on disk untouched and the currently-installed
    app is never replaced (`Sources/Updater.swift`, proven by fixture
    bundles in `UpdaterCheck.swift`: unsigned and signed-then-tampered
    bundles are both rejected before anything is touched).
  - The swap script waits for the running app's PID to exit before replacing
    the bundle, so a user is never left with half-old/half-new binaries. It
    never sends `kill 0` (the whole process group, including the script's
    own) when no engine PID is known — it skips the kill in that case
    instead, a bug fixed in 0.9.80 that could otherwise kill the swap
    script mid-swap.
  - A failed/timed-out download or swap must leave the currently-installed
    app runnable, not inconsistent (checked by `UpdaterCheck.swift`,
    `One --test-updates`).
- **Engine liveness**: a gateway (phone-chat bridge) restart must never cut
  off a routine or a reply mid-turn. `GatewayGuard` only stops a *stale*
  gateway, never a healthy one another One process is using; a dropped turn
  is retried once.
- **No silent data loss on a folder-permission or iCloud change**: a change
  to the person's folders restarts the engine under the new lock only once
  nothing is mid-reply (`FolderWatch`); shared-room sync treats a conflicting
  edit as a merge note, not an overwrite (`SharedRooms`/`tend()`).

## Enforcement

| Requirement | Enforced by |
|---|---|
| Startup never stuck | `StartupGate`/`ReadyLayer` timeouts + retry; `StartupRender` renders checked by hand |
| Update only from a trusted host | `Updater.trustedDownloadHost` + `UpdaterCheck.swift` (`One --test-updates`, run by preflight) |
| Update swap only installs a genuinely-signed, matching-team build | `Updater.swift` codesign/team-ID verify before swap; `UpdaterCheck.swift` signing-check fixtures |
| Update swap is atomic (no half-swapped app) | swap script waits on the running PID before replacing the bundle; `UpdaterCheck.swift` |
| A dropped engine turn is retried, not lost | `GatewayGuard` + retry-once in `Engine` |
| Stale (not healthy) gateways only are stopped | `GatewayGuard`; preflight `GatewayCheck`/`RestartCheck` |
| Folder-permission changes never corrupt a mid-reply turn | `FolderWatch` (waits for idle before restarting) |
| Crash-free session rate | **NOT YET ENFORCED** — no crash reporter wired up |
| Voice/engine process liveness under Bluetooth route changes | `Speaker.rebuild()` on `.AVAudioEngineConfigurationChange`; checked manually, no automated assertion |

## Failure modes considered (real, from this repo's history)

- An engine SIGTERM mid-turn during a `make check`/preflight run on the SAME
  machine running the live gateway (fixed via `GatewayGuard`/`GatewayCheck`:
  only stale gateways are stopped, every preflight step gets its own scratch
  home, a dropped turn is retried once).
- A test/check run against the real bundle id moving the person's real files
  (Oct 27 incident) — the reason `TestWorld.enter()` is the one door into any
  test mode and refuses to run as the real app.
- A Bluetooth headset switching into call mode on push-to-talk release,
  leaving the audio engine bound to a dead output route so replies play into
  nothing (`Speaker.rebuild()`).
- `session/load` returning "Gateway draining: not_ready" on the very first
  load after a restart (the restart itself kills and re-wakes the gateway);
  giving up after one try used to open a blank chat on every restart — fixed
  with a 15×3s retry.
- A routine's `fire_claim` left with no `at` timestamp by a dead run (e.g.
  the update-swap script killing the engine mid-routine) used to read as
  "still running" forever, silently blocking that routine from ever firing
  again; `Routines.inFlight` (0.9.80) now matches the engine's own claim
  TTL instead of treating a missing `at` as live.

A requirement with no row above, or a row saying NOT YET ENFORCED, is a real
gap: file it in `docs/exec-plans/tech-debt-tracker.md` rather than assuming
it's covered by "the assistant will notice."
