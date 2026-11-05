# Connecting accounts and services: methods once the goal is agreed

Reference for `connect-goal-first`. The SKILL.md stays the plain-words, goal-first flow; this file is the
"how" once the person has said yes to a goal. Everything here is optional: pick what fits the goal.

## How to work
- **Do the clicking yourself.** If a browser on this Mac is signed in to the right account, drive the setup
  page yourself instead of handing the person a list of steps. Hand off only what truly needs them: their
  sign-in, a code, a consent click, a password-manager unlock, a physical approval.
- **Find accounts; don't quiz them.** Their notes, welcome or billing emails and "Sign in with Google" on the
  service's own login page usually tell you which account they use. Show what you found and let them pick.
- **Personal over work.** Build anything that holds tokens under their personal account, never a work
  organisation's, so an employer can't see or revoke it. Skip work accounts unless asked.
- **Prefer what stays on this Mac.** Mac apps and the Mac's own accounts first, then a sign-in they own whose
  tokens stay local, and hosted connector services (Zapier and the like) only as an alternative they choose.
  Free before paid; say the cost before anything paid.
- **Email and calendar:** One's Connections already uses the Mac's own accounts (System Settings › Internet
  Accounts, then Mail and Calendar). Point there before building anything else for email or calendar.
- Stop for a yes before each step that can't be undone (a final "Create", "Publish", "Delete" in a setup page).
- The person may be away from the Mac. Anything that needs a click at the Mac (a macOS permission, unlocking a
  password manager) waits for them; say so plainly instead of trying. Approval prompts time out after about a
  minute: do several steps per approval, and on a timeout say what's done and what's left.
- **Prove it with one real read** per account (list calendars, read one message, show a balance) before saying
  it works.

## 1. Look before building
- See what's already there: the connections list, the skills folder, apps in `/Applications`, any MCP servers in
  the engine's config. Report it as working / installed but not set up / available.
- Ask which phone or platform before recommending anything device-specific (Apple-only routes are little use
  without an iPhone).

## 2. Sign-ins with a token (OAuth) and MCP servers
- Start the tool's sign-in, open its link in the signed-in browser, let the person click Allow, then pick up
  the `localhost` redirect the tool waits for. Match the redirect on its `state` value, never "the latest
  redirect". Write codes and secrets to owner-only (0600) files from a script; never print them.
- **Google:** one Google Cloud project with a Desktop OAuth client can serve several of their accounts (a token
  file per account). Apps left in "Testing" get tokens that expire after 7 days, and tokens made while in
  Testing keep that expiry; moving the app to "In production" needs a homepage and privacy page on a domain
  they own. If that's too much for them, say so and use the Mac's own accounts instead.
- **MCP server with a sign-in:** `hermes mcp add <name> --url <url> --auth oauth --connect-timeout 300`, run in
  the background so you can open the printed sign-in link and answer its "enable all tools?" question; then
  `hermes mcp test <name>`. The default 30 s timeout runs out before a person finishes approving. New tools
  appear only in a new conversation: say so.
- **An installer that refuses the Node version:** check what the person's own shell runs
  (`zsh -ic 'which -a node; node -v'` in that folder). A version file in the folder (mise/asdf) can pin an old
  Node; use a supported one there or run the installer once through `mise exec node@<version> -- npx ...`.
- **Installers that edit several apps' configs:** run their dry-run first and read what they plan to write. A
  non-zero exit can just mean optional extras are left: read the message before calling it failed.
- Anything that changes the engine's config only takes effect after an engine restart, which cuts off the
  current chat. Inside One, don't restart it yourself: tell the person.

## 3. Driving their browser for a setup page
- Use their own signed-in browser when the connection's browser route allows it; open your own tab, never take
  over one of theirs. Pop-ups (an account chooser) open as new tabs: look for them.
- Check which account is signed in before changing anything.
- Pages built with Angular or Material ignore a plain `.value =`: use the native input value setter, then send
  `input`, `change` and `blur`. When a scripted click does nothing, use a real mouse event at the element.
  Look the fields up again after every page load.
- Pages that show keys or secrets: never read out labels or buttons in full (copy buttons often contain the
  whole secret), and mask anything that looks like a key. If a key field stays masked, use the page's own
  Copy button and read the clipboard inside a script that writes straight to a 0600 file, then clear the
  clipboard and check the key against the service.
- Before clicking anything destructive, check it belongs to the row you mean and that the confirm box names
  the thing you mean: a page-level "Delete" often deletes the parent.
- macOS has no `timeout` command; a command wrapped in it silently doesn't run.

## 4. Passwords and codes
- Logins come from their password manager through Connections › Passwords (KeePass, 1Password, Bitwarden).
  `browser_vault` fills a login without the password ever reaching the chat. Don't push a paid password
  manager; free options exist.
- KeePass: never write to their database file (it often syncs with their phone). One-time codes can come from
  the entry's TOTP setting instead of asking them. "Invalid credentials" right after they "updated entries"
  usually means the file's master password or key file changed, not that it broke: ask which one opens it now,
  and never restore or overwrite the file yourself.
- Google often refuses sign-ins from a hidden browser after the email step ("This browser or app may not be
  secure"): let them sign in in a normal browser window.

## 5. A remote browser (optional)
- If a job must not open anything on screen, only the browser can run remotely (for example Browserbase);
  the assistant, keys and passwords stay on the Mac. Free tiers are small (short sessions, about an hour a
  month), so check the job fits before suggesting it.
- Prove it's really remote by IP: compare `https://api.ipify.org` seen by the browser with the Mac's own. A
  `ws://127.0.0.1` address proves nothing (it can be a local proxy).

## 6. The assistant as its own chat bot
- Use the engine's built-in chat adapters with the assistant as its OWN bot, never acting as the person. Each
  person needs their own bot: two engines sharing one bot token steal each other's messages.
- A platform turns on from its keys in the engine's `.env` (for example `TELEGRAM_BOT_TOKEN`, or
  `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN`). Always set the allow-list (`TELEGRAM_ALLOWED_USERS`,
  `SLACK_ALLOWED_USERS`) to the owner's own user ID, or nobody gets answers. Back up `.env` first, write the
  keys from a script (never through the chat), and check with the token values hidden.
- A bot can't message first: the person opens it and taps Start (Telegram) or opens its DM (Slack) once.
- Slack: `hermes slack manifest --agent-view --name <Bot> --write <file>` makes the app description; trim the
  slash commands to a few (the full list is too long for the create-app link); create the app in the right
  workspace, make a Socket Mode app token (`connections:write`) and install it to get the bot token. Check
  both tokens with Slack's `auth.test` and `apps.connections.open` before writing them, then tell the person a
  restart is needed and ask them to send the bot one message as the live test.
- Docs: https://hermes-agent.nousresearch.com/docs/user-guide/messaging/
