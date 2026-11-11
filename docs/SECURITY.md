# Security

One runs a background AI engine (Hermes) under a macOS sandbox profile — the
"folder lock" — plus a handful of bridges into things the sandbox can't reach
(Mail, Calendar, Keychain, the person's own Chrome). This doc names the real
boundaries today, not an aspirational version of them.

## Secrets handling

- **API keys / bot tokens**: `App.swift` and `Messenger.swift` write
  `OPENROUTER_API_KEY`/`TELEGRAM_BOT_TOKEN` into `hermes/.env` through
  `Env.writeSecretEnv()` (`Sources/Env.swift`), which `chmod`s the file
  `0o600` on every write; `Messenger.configured` self-heals the mode on read
  too, so a copy created or left world/group-readable before this existed
  gets re-hardened the next time the gateway checks it. Fixed in 0.9.81 —
  see Known findings for the prior state.
- **Keys pasted in Switch AI › Other AIs**: checked first against the AI's
  own model list (a refused key is never kept), then saved by the engine's
  own `save_provider_env_credential` (`tools/overlay/tools/one_ai_catalog.py
  save-key`) into `hermes/.env` (0600) plus its credential pool. The key goes
  in on **stdin** (`hermesRun(input:)`), never `argv`, and the script prints
  only `ok` and the variable's name; the field is cleared after use.
- **Google OAuth tokens**: `tools/google_signin.py` writes
  `google_tokens/<email>.json` and explicitly `os.chmod(path, 0o600)`s it,
  and (since 0.9.81) `chmod(0o700)`s the containing `google_tokens/`
  directory itself, so the list of connected Google accounts isn't
  group/other-readable even before any individual token file is read.
- **KeePass master password**: read from the macOS Keychain
  (`keychain_service`/`keychain_account` in `vault.keepass.*` config), never
  prompted for and never passed as a CLI argument — the bridge
  (`tools/overlay/agent/vault_backends/keepass.py`) shells out to
  `keepassxc-cli` with the master password on **stdin**, not `argv`, which is
  the whole point: process listings (`ps`), shell history, and crash reports
  that capture argv would otherwise leak it.
- **Telegram bot token**: stored in the person's KeePass vault (never in
  chat), read into a shell variable and written into `hermes/.env`
  (chmod 600 at write time per the skill runbook) — never echoed, never
  logged.
- **General rule for any new secret**: never log it (`one-lint: no-secrets`
  also blocks literal secret-shaped strings from ever landing in source),
  never pass it as a CLI argument, write it through `Env.writeSecretEnv()`
  (or an equivalent explicit `chmod(0o600)`/`0o700` on write) rather than a
  plain `write(to:)` — don't rely on `umask`.
- **Chat text is never persisted beyond the decision it produced**:
  `BrowserGuard` (`Sources/BrowserGuard.swift`) used to log a snippet of
  what the person typed when they said yes to a visible browser window;
  since 0.9.81 only the derived decision (`browser`, `expiry`, `approved`)
  is written, never the message text itself.

## Sandbox / permission boundaries (the "folder lock")

- The engine runs under `sandbox-exec` with the profile from `Access.profile()`
  (`Sources/Env.swift`): the base policy is `(allow default)` with an
  explicit `(deny file-read-data file-write* (subpath "<home>"))`, then a
  narrow allow-list of `rw` and `ro` paths layered back on top. This is a
  **deny-by-default-for-$HOME, allow-list on top** model, not a full
  default-deny sandbox — anything outside `$HOME` is unrestricted by this
  profile (network access, other volumes, `/tmp`, etc. are not part of this
  boundary).
- `rw`: `Support/One`, the Brain folder, `~/.cache`, `~/Library/Caches`,
  `~/.config/gh`, every folder the person has explicitly approved
  (`folders`), and any active shared-room paths.
- `ro`: `~/.local`, `~/Library/Keychains`, the GitHub/git login files
  (`~/.config/gh`, `~/.gitconfig*`, `~/.config/git`), per-connection reads
  (`connectorReads`, e.g. a KeePass database path), and KeePassXC's own
  settings directory. `gh`'s GitHub auth is HTTPS-only, backed entirely by
  the Keychain plus those three config paths — `~/.ssh` and
  `~/.git-credentials` are **never** allow-listed (`Sources/Env.swift`,
  `Access.profile()`'s `logins` list has a comment saying so explicitly),
  closing a prompt-injection-to-exfiltration path a helper running inside
  the lock could otherwise use to read raw SSH keys or stored git
  passwords. Fixed in 0.9.81 — see Known findings for the prior state.
- The lock is fixed when a process starts, and the engine's tools run in its
  background helper (the Hermes gateway). So a newly approved folder only
  reaches the engine once that helper is stopped and started again under the
  new profile (`FolderWatch`, `GatewayGuard.stopForNewAccess`). Hermes can
  relaunch itself as `python3 -I -c "…sys.argv = ['-c', 'gateway', 'run', …]…"`;
  until 0.9.91 that shape was taken for "not a gateway", the old helper kept
  the old lock, and an approved folder still said "Operation not permitted".
  `GatewayGuard.isGateway` reads that script's argument list too
  (`--test-restart` covers both, plus a granted folder with a space under
  `~/Library/Application Support`).
- `BrowserGuard.lockedPaths` are explicitly denied write access on top of the
  allow-list, so an engine-driven command cannot silently flip on a visible
  browser window without the person's yes. Since 0.9.89 that includes
  `guard/look-only/`: One marks a helper whose job starts with "Look only:"
  there, and the engine plugin blocks that helper's commits, pushes, tags,
  merges, releases, pull requests/issues, `gh api` writes, installs (brew, mas,
  installer, npm -g, copies into /Applications), posting (x-cli/xurl, curl or
  wget sending data except GraphQL reads) and `send_message`. The helper can't
  write the mark away; only the person's own message in that helper's thread
  lifts it (`LookOnly.swift`, `tools/look-only-check.py` in preflight). It
  reads command text, like the browser guard: a determined script could still
  get round it, so it's a strong guard against mistakes, not a sandbox.
- The hidden Chrome instance `BrowserKeeper` manages pins its CDP listener
  to `--remote-debugging-address=127.0.0.1` explicitly (`Sources/BrowserKeeper.swift`),
  rather than relying on Chrome's current default, so the debugging port is
  never reachable from outside the Mac.
- Since 0.9.97 every hidden Chrome One starts goes through `HiddenBrowser.launch`
  (`Sources/HiddenBrowser.swift`): the Mac's own launcher, a new copy, never
  brought forward, outside the folder lock. The engine can ask for one on
  another saved profile (`One --hidden-browser <port> <profile>`), but One only
  starts it on a profile in its own folder or a folder the person approved,
  never on their own Chrome's folder, always headless and on 127.0.0.1, with a
  short list of allowed extra switches and only http(s) pages. Any headless
  Chrome that comes to the front is hidden at once; one macOS turned into a
  normal app is hidden and, if it's One's, closed politely when nothing uses it.
- Widening this profile to "all of home" defeats the entire point of the
  lock; `docs/ARCHITECTURE.md` rule 4 says so explicitly, and any new
  allow-listed path should be the narrowest one that actually unblocks the
  feature (a specific subpath, not a whole dotfile-heavy directory).

## Trust boundaries for the agent/tool-execution surface

One's engine is itself an agent that can browse, run shell commands, and
write files inside the folder lock, in response to the person's own chat
messages and to whatever those tools fetch back (web pages, file contents,
tool output). That is the surface where "untrusted content meets
tool-execution privilege":

- **Where untrusted content enters**: web pages visited by `browser_exec`
  (via the hidden Chrome instance `BrowserKeeper` manages) and file/tool
  output the engine reads back into its own context. Both can contain
  attacker-authored text that looks like an instruction.
- **What stops a self-approval loop**: the engine cannot grant itself new
  privilege. Concretely:
  - **Showing a real browser window** requires the person's explicit yes
    (`BrowserGuard`: a plugin installed at every engine start blocks
    `open -a`/AppleScript/non-headless browser launches outright; the engine
    can only write a `guard/allow/<id>.json` request, which the *person*,
    not the engine, approves through `Model`/the UI). The engine proposing
    "I need to open Chrome" and then approving its own request is not a
    path that exists in code — the allow file only gets written from the
    UI side after a human taps yes.
  - **A "verify you are human" / Cloudflare-style challenge** always routes
    to a human ask (`BlockedAsk`), never to the engine solving it itself.
  - **Sending money, email, or anything irreversible** is not something the
    engine's tool surface can do unattended: Mail can only open a visible,
    human-reviewed draft (`one-lint: no-mail-send` plus the Bridge code path
    itself has no send command), and the per-prompt SOUL rule names
    money/send/post/delete as always needing a plain-words yes. The
    enforcement for the irreversible-action class is currently split between
    code (Mail has no send path at all) and the prompt/SOUL layer (money,
    delete) — the SOUL-level ones are a policy, not a hard code gate, and
    should be read as weaker than the Mail case.
  - **Experimental, user-authored connections** (`ConnectionsWorld`'s
    "Something else…" path) are disabled by `ExperimentalGuard` until a real
    read-only test has passed and an explicit `{tested: true}` record exists
    in `hermes/connections.json` — the engine that built the connection
    cannot flip it on for itself; the gate is a separate, static check run
    before every engine start.
  - **The look-only score** (`Improve*.swift`, docs/design-docs/improve-score.md)
    reads the engine's history `hermes/state.db` through `ReadOnlyDB`
    (`mode=ro`, `query_only`, never written or checkpointed) and One's own logs,
    and writes only `improve/` in One's folder. Conversations touching the Nyx
    room, a `confidential/` path or a shared room keep counts but no words, and
    `One --improve moments` leaves them out. The friction log (`FrictionLog`,
    Guards.swift) now uses the same correction finder; it still only appends
    the person's own message and the last reply to `friction-log.md`. The
    phone-chat source names live in `Messenger.phoneSources` (read only here).
- **What this does NOT yet cover**: there is no sandboxing of the *content*
  the engine reads back from a web page before it's added to the model's
  context — a page could contain adversarial text aimed at the model itself
  (a prompt-injection attempt), and nothing here claims to neutralize that at
  the content layer. The mitigations above are about *what privileged action
  the engine can take as a result*, not about scrubbing what it reads. That
  gap is real and should be treated as an open question, not a solved one.

## Resolved findings (fixed as of 0.9.81 — kept here as the record of what closed)

These three were tracked as open, unfixed findings as of the 0.9.79 security
pass. All three landed in 0.9.80/0.9.81 and are now **resolved invariants**,
each enforced in code rather than by convention:

- **Over-broad GitHub-login allow-list** — `Access.profile()`'s `logins`
  list no longer includes `~/.ssh` or `~/.git-credentials`. Enforced by
  `Sources/Env.swift` (`Access.profile()`, see the `NEVER add .ssh or
  .git-credentials back here` comment above the `logins` array); verified
  end-to-end with `gh auth`/`git ls-remote` over HTTPS using only the
  Keychain token, with both paths removed from the sandbox profile.
- **`.env` has no permission hardening** — every write to `hermes/.env`
  goes through `Env.writeSecretEnv()`, which `chmod`s the file `0o600`;
  `Messenger.configured` additionally self-heals the mode on read, so an
  `.env` created before this existed gets re-hardened automatically rather
  than needing a manual `chmod`.
- **Update download host is unrestricted** — `Updater.pick` now refuses a
  release asset whose `browser_download_url` host isn't `github.com` or a
  `*.githubusercontent.com` subdomain (`Updater.trustedDownloadHost`,
  checked by `UpdaterCheck.swift` / `One --test-updates`, run by preflight).

## Other update-integrity hardening (0.9.80, not previously documented here)

- Before the swap script replaces the installed app, the downloaded bundle's
  code signature must verify (`codesign --verify --deep --strict`) **and**
  its signing team must match the running app's — a tampered or unsigned zip
  is left on disk untouched and the old app stays in place
  (`Sources/Updater.swift`, proven by fixture bundles in `UpdaterCheck.swift`:
  an unsigned update and a signed-then-tampered one are both rejected before
  anything is touched).
- The swap script no longer sends `kill 0` (the whole process group,
  including itself) when no engine PID is known — it skips the kill in that
  case instead, fixing a bug that could kill the script's own process group
  mid-swap. `docs/RELIABILITY.md` covers this as a reliability property;
  listed here too because it was found during the same security pass.

## Updates, the keeper and missed phone messages (0.9.99)

- The swap script keeps the replaced app in `<support>/update-previous/` (outside the download folder) instead of
  deleting it. The keeper (`One --keeper`, a launch agent inside One.app registered with `SMAppService`) may put it
  back after a just-installed version fails to start three times, only if `codesign -dvv` shows the same signing team
  for both (`Keeper.sameSigner`); the failed one is moved to `update-failed/<version>`, never deleted, and the updater
  never offers that version again (`Updater.pick(skip:)`). The keeper only ever runs `open -g` on the app path One
  itself recorded, and never opens One after a quit (or `kill`) the person asked for.
- Phone chats now keep messages sent while One was off. The `one-missed-messages` engine plugin acts only for senders
  the gateway authorizes (`_is_user_authorized`); messages over 2 hours old are never handed to the assistant: they
  are listed in one note, and the next new message carries that list with the standing rule that sending, posting,
  spending and deleting still need a fresh yes.

## One account at a time (0.9.108)

One never moves work to another signed-in AI account by itself (a work account may sit next to the person's own).
The engine's credential pool would: when the chosen account hit a limit, its next pick was any other signed-in
account. The one-stop plugin (`only_chosen`, `patch_one_account`) makes the pool offer only the chosen account (the
first by priority, plus rows sharing its key); at a limit the turn fails and One asks the person ("Switch to <other
account>, or wait for the reset?", `LimitPause.swift`). Only their tap or their reply in the phone chat
(`One --limit-answer`) switches, and the answer counts for that one job. Checked in `tools/stop-plugin-check.py`.
A pause (a budget, a limit) marks the conversation with its reason, so the engine tells the helper it's paused,
never "they pressed Stop".

## Hand-offs from the phone (0.9.107)

A step only the person can do (a code, a sign-in, a robot check) can be finished from their phone
(`PhoneHandoff.swift`, `PhoneSession.swift`, `PhoneServer.swift`, `PhonePage.swift`):
- **One page only.** One attaches to that one tab's own DevTools socket (`/devtools/page/<id>`), never the browser
  endpoint, and forwards only taps, scrolls, text (max 200 characters, one line) and Enter/Backspace/Tab
  (`PhoneHandoff.allowed`); anything else is dropped and logged. The tab leaving the step's site (other than that
  site's known sign-in hosts) ends the link. No address bar, tabs, downloads or file pickers on the phone page.
- **Short life, one phone.** 10 minutes, or until Done / Not now / the step answered at the Mac; the first phone to
  open it is the only one (a second socket gets 409). The loopback server (127.0.0.1 only) serves only
  `/h/<room>` and `/ws/<room>`; the room is 128 random bits.
- **Sealed end to end.** AES-GCM with a 256-bit key that exists only in the link's `#` fragment (never sent to any
  server; the page drops it from the address bar on load). The tunnel (`cloudflared` quick tunnel, started for that
  hand-off only) sees only ciphertext.
- **Only to them.** The link goes only to `TELEGRAM_HOME_CHANNEL`; off when the phone chat or the tunnel tool is missing.
- **Audit.** `handoff/<id>.audit.jsonl` + `hermes/logs/one-handoff.log`: created, sent, opened (browser, country),
  each input's kind (never what was typed), navigations, refused phones, dropped messages, ended (why).
- Not covered: passkeys and security keys can't be done through a picture of a page (the site's own phone route is
  offered instead), and a person who forwards the link before opening it hands that one page to whoever opens it first.

## Codes and live tabs in hand-offs (0.9.113)

A step only the person can do no longer closes the hidden browser and reopens its page (that lost any page reached
by a form POST: DocuSign's code page went to its log-in page). By kind (`HumanCheck.windowKinds`, `HumanStep.takesCode`):
- **A code** never shows a browser. The engine (`tools/overlay/tools/one_human_step.py`, `code_step`) first looks for
  the code in an inbox One can read: Gmail accounts the engine already holds tokens for (`hermes/google_tokens/`),
  read-only (`messages` list + metadata), only mail newer than the step and whose sender or subject names the site
  (another site's code is never used). Else One's card asks for it in a box; away from the Mac the ask goes to the
  owner's own phone chat (`TELEGRAM_HOME_CHANNEL` only) and the reply is the code: the engine's phone plugin
  (`one-missed-messages`, `take_code_reply`) writes it straight into the step's answer file and the message is
  skipped, so the code never reaches the assistant, the conversation or a log. The engine reads it once, rewrites the
  answer file without it and types it into the still-open tab over that tab's own DevTools socket.
- **A sign-in or approve** is shown as the SAME live tab in One's window (StepWindow), never reopened.
- **A robot check, passkey or security key** keeps the plain Chrome window (they need a real window).

## Memory safety across threads (0.9.85)

- State one thread writes while another reads (the engine's reader thread vs the main thread, two background
  loops) goes through `Guarded` (Env.swift, a lock around every read and write): the engine's callbacks
  (`Engine.onText` and friends) and `BrowserKeeper.lastNote`. The voice's playback state is main-thread only.
  Nothing granted or enforced changes; this closes heap corruption that crashed One (0.9.32 to 0.9.84).
  `make sanitize` runs the audio line under the thread and address sanitizers.

## Known findings / open items (current state of `main`, checked today)

- **No automated knowledge-base-integrity test**: unlike repos hardened with
  the newer harness-engineering skill, this repo has no
  `test/architecture/knowledge-base.*`-style check asserting doc links
  resolve, `docs/INDEX.md` agrees with disk, and no doc is orphaned — doc
  drift (like the three findings above sitting undetected for two releases)
  is caught by a manual harness pass, not by CI. Tracked in
  `docs/exec-plans/tech-debt-tracker.md` rather than built in this pass.
- Track new findings here (or in `docs/exec-plans/tech-debt-tracker.md` for
  anything that's also a code-quality item) rather than letting "we did a
  security pass once" stand in for a current, accurate list.
