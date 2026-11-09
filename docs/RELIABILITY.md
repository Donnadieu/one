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
- **Restarts and long jobs don't cut work off** (0.9.89): a folder restart or an
  update pauses working helpers only between two steps (no command running,
  `Model.helpersMidStep`, up to `FolderWatch.stepWait` = 10 min); a turn is
  waited for as long as it keeps doing something (`TurnWait`, EngineWait.swift)
  instead of a fixed 15/30 minutes; the saved conversation is waited for
  through a slow restart (`Engine.loadPatience`, only "not_found" counts as
  gone) instead of being replaced by a new one.

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
| Restarts pause helpers only between steps; long active turns aren't cut off; the chat reopens after a slow restart | `FolderWatch.due(midStep:)`, `Updater.install`, `TurnWait`, `Engine.loadPatience`; `HelperWorkCheck` (`One --test-helper-work`, preflight) |
| Crash-free session rate | **NOT YET ENFORCED** — no crash reporter wired up |
| Voice/engine process liveness under Bluetooth route changes | `Speaker.rebuild()` on `.AVAudioEngineConfigurationChange`; checked manually, no automated assertion |
| One never ends because sound can't start (dark wake, lid closed, no output, a headset switching) | every raising audio call goes through `AudioGate.attempt` (`OneCatch`, Sources/ObjC); the line starts only when `AudioGate.blocked()` is nil and retries on wake / output change / backoff; `SleepSafeCheck` (`One --test-sleep-safe`, preflight) |
| An update never restarts One in a dark wake or with the screens off | `Updater.waitForFullWake` (before the download, before the swap, before the quit); `UpdaterCheck.wakeChecks` (preflight) |
| One comes back by itself after a crash, a failed relaunch or a Mac restart | the keeper launch agent (`One --keeper` every 60 s, `Keeper.decide`: backoff 0/1/5/15/30/60 min, never after a quit they asked for, but after a logout, restart or shutdown (`Keeper.wantAfterQuit`, 0.9.100), puts the previous version back after 3 failed starts of a just-installed one); `tools/keeper-check.sh` (preflight, stand-in apps) |
| Phone messages sent while One was off are never silently dropped | Telegram keeps queued updates (`Messenger.missedFixes`); engine plugin `one-missed-messages` answers the last 2 h, lists older ones in one note, never acts on them; `tools/missed-messages-check.py` (preflight) + `tools/missed-messages-engine-check.sh` (fresh-install, real engine) |

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
  with a 15×3s retry. That still lost the chat on Nov 4 2026: the old gateway
  drained a routine for 54 s and the new one answered "Gateway could not
  start: Another gateway instance is already running", which wasn't on the
  retry list, so a new conversation replaced the saved one. Since 0.9.89 every
  answer except "not_found" is waited out for up to 4 minutes, and a load that
  still fails is logged in `one-gateway-guard.log`.
- Helper turns over 30 minutes came back "timed out" while still working (One's
  own fixed wait, not a restart) and were sent their job again: "Forge triage
  moves" twice on Nov 4 2026. Since 0.9.89 the wait restarts at every sign of
  life (`TurnWait`).
- Nov 6-7 2026, 18 hours with no phone chat: the lid was closed; an update clicked earlier went ahead in a
  minute-long dark wake (2:13 PM); the new 0.9.98 started its speaker at launch with no sound output, Apple's
  `AVAudioPlayerNode.play()` raised an Objective-C exception, and One ended (crash reports 14:14 Nov 6 and
  08:17 Nov 7, both `Speaker.wakeAudio`). Nothing reopened it, and the bot threw away what was sent meanwhile.
  0.9.99: `AudioSafe.swift` + `OneCatch`, `Updater.waitForFullWake`, the keeper (`Keeper.swift`), and the
  `one-missed-messages` plugin (rows above).
- A routine's `fire_claim` left with no `at` timestamp by a dead run (e.g.
  the update-swap script killing the engine mid-routine) used to read as
  "still running" forever, silently blocking that routine from ever firing
  again; `Routines.inFlight` (0.9.80) now matches the engine's own claim
  TTL instead of treating a missing `at` as live.

A requirement with no row above, or a row saying NOT YET ENFORCED, is a real
gap: file it in `docs/exec-plans/tech-debt-tracker.md` rather than assuming
it's covered by "the assistant will notice."
