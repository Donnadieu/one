# Security

One runs a background AI engine (Hermes) under a macOS sandbox profile — the
"folder lock" — plus a handful of bridges into things the sandbox can't reach
(Mail, Calendar, Keychain, the person's own Chrome). This doc names the real
boundaries today, not an aspirational version of them.

## Secrets handling

- **API keys**: `App.swift` writes a one-time `OPENROUTER_API_KEY` into
  `hermes/.env` on first install (`try? "...".write(...)`). As of this
  writing that write does **not** set restrictive permissions on the file,
  and nothing re-checks/hardens its mode on later reads — see Known findings
  below.
- **Google OAuth tokens**: `tools/google_signin.py` writes
  `google_tokens/<email>.json` and explicitly `os.chmod(path, 0o600)`s it —
  the one secret-bearing file in the repo that already self-hardens its
  permissions on write. Use this as the pattern when fixing the `.env` gap.
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
  never pass it as a CLI argument, write it to disk only inside
  `Env.support`/`hermes/.env` with owner-only permissions set explicitly
  (don't rely on `umask`).

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
  settings directory.
- `BrowserGuard.lockedPaths` are explicitly denied write access on top of the
  allow-list, so an engine-driven command cannot silently flip on a visible
  browser window without the person's yes.
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
- **What this does NOT yet cover**: there is no sandboxing of the *content*
  the engine reads back from a web page before it's added to the model's
  context — a page could contain adversarial text aimed at the model itself
  (a prompt-injection attempt), and nothing here claims to neutralize that at
  the content layer. The mitigations above are about *what privileged action
  the engine can take as a result*, not about scrubbing what it reads. That
  gap is real and should be treated as an open question, not a solved one.

## Known findings / open items (current state of `main`, checked today)

- **Over-broad GitHub-login allow-list**: `Access.profile()`'s `logins` list
  currently includes `~/.ssh` and `~/.git-credentials` as read-only paths.
  `gh`'s HTTPS auth already lives in the macOS Keychain (separately
  allow-listed) and needs neither file; allow-listing them lets any helper
  or skill running inside the lock read private SSH keys / stored git
  passwords, and the base policy is `(allow default)` outside `$HOME` so
  nothing stops that content leaving over the network once read. **Not yet
  fixed on `main`** as of this doc's writing — fix is to drop both paths
  from `logins`.
- **`.env` secret file has no permission hardening**: unlike
  `google_signin.py`'s explicit `chmod(0o600)`, the `OPENROUTER_API_KEY`
  write in `App.swift` and the general `hermes/.env` file are not
  permission-hardened at write or read time. **Not yet fixed on `main`.**
- **Update download host is not yet restricted**: `Updater.pick` does not
  currently verify that a release asset's `browser_download_url` points at
  `github.com`/`*.githubusercontent.com` before downloading it — a tampered
  or spoofed releases response could point the updater anywhere.
  **Not yet fixed on `main`.**
- Track new findings here (or in `docs/exec-plans/tech-debt-tracker.md` for
  anything that's also a code-quality item) rather than letting "we did a
  security pass once" stand in for a current, accurate list.
