# One

**A personal AI assistant that lives on your Mac, for people who have never opened a terminal.**

You download it, you open it, and it talks you through the rest. It sets itself up, asks which AI you already pay for, learns your name, and shows you everything it can reach from your Mac. Then it works for you: your files, your browser, your email, your calendar, the web. It always asks before it does anything that matters.

![The world screen: everything One can reach, floating around the assistant](docs/world.png)

> Status: early test build (0.9). It runs end to end on Apple Silicon Macs. Passwords (KeePass), Gmail and Google Calendar (Sign in with Google), other email and calendars through the accounts on your Mac and your own Chrome now work; Phone and News are not built yet, but you can build your own with the assistant (experimental). See [Roadmap](#roadmap).

---

## Why this exists

Personal AI agents can already do remarkable things: tidy a folder, sign in to a site, watch a price, read fifty emails and tell you who is waiting on you. But getting one running still means a terminal, API keys, config files and a chat box that gives you no idea what to type.

When the iPhone arrived, every phone had a keyboard. The answer wasn't a better keyboard; it was removing it. One tries to do the same for assistants. The "keyboard" here is the setup friction and the empty chat box. So:

- **One button to start.** Everything after that is a conversation the assistant leads, out loud.
- **It lives on your Mac, not in a cloud.** It uses your own browser, already signed in, so websites treat it like you instead of blocking it as a bot. It can reach your files, but only the folders you allow.
- **Bring the AI you already pay for.** ChatGPT, Claude, Grok or OpenRouter. Switch any time. Nobody locks you to one model.
- **Its memory is yours.** Plain files on your Mac, organised in rooms. Switch AIs and it still remembers you.
- **A human stays in the loop.** Buying, paying, sending or deleting always waits for your yes.
- **Honest about its limits.** If your Mac is closed or off, so is the assistant. It tells you that up front.

This is a personal project, not a company. It is built for me, my friends and anyone who wants an assistant that is theirs.

## What it does today

1. **Welcome.** Four spoken lines surface on screen: who it is, where it lives, that it asks first, and that it's off when your Mac is off.
2. **Sets itself up.** On first launch it installs its own private copy of its engine (about 80 seconds, no terminal, no questions). It never touches your shell files or any other install.
3. **Pick your AI.** Sign in with ChatGPT, Claude, Grok or OpenRouter through each provider's own sign-in page. If your plan doesn't allow a model, it quietly tries the next one.
4. **Names.** "What would you like to call me? And what should I call you?"
5. **Memory and rooms.** Everything starts in a personal room. If part of your life needs different rules (your job, a business, something just for you), it gets its own room, kept separate.
6. **The world.** A short spoken tour of everything it can reach, then you tap what you want connected.
7. **Passwords and backup.** Where to find logins (your password manager, Keychain, or ask each time), and an optional copy of your memory to iCloud Drive.
8. **Home.** A greeting, the assistant itself, the answer to your latest request, any "needs your yes" cards, and a few ideas to try. The ideas hide themselves after three days, or with an X, and come back from "Ideas to try". The **Ready for you** sidebar (files your assistant made) collapses to a thin strip.
9. **Helpers.** Anything that takes real work (looking things up, browsing, comparing, making a file, watching a price) goes to helpers that run in the background, several at once when a job has separate parts. The assistant stays free to talk.
10. **Talk.** Hold a shortcut anywhere on your Mac to speak; let go to send. A small orb floats on screen when the window is closed and hides when the window is open. Closing the window tucks it into the orb; only Quit ends One.
11. **Voice everywhere.** Replies, helper results and finished routines are read aloud even when the window is closed, unless muted.
12. **Brain and voice.** Tap the assistant's name: pick Smartest, Balanced or Fastest (or any OpenRouter model), and a female or male voice with three styles each. Tap one to hear it. To rename the assistant, just ask it.
13. **Connections.** The same floating world as setup. Connected tiles are tied to the assistant by a thread; tap one to change it or disconnect.
    - **Passwords:** KeePass (1Password and Bitwarden through the engine's vault). Logins are filled without the model ever seeing the password.
    - **Email and Calendar:** Sign in with Google on Google's own page (Google shows a one-time "not verified" screen; up to 100 people until Google's review), or the accounts already on your Mac for Outlook, iCloud and Yahoo. The assistant drafts; you always press Send.
    - **Browser:** your own Chrome, already signed in.
    - **Something else…:** on every tile, plus its own tile. The assistant asks what you use, builds the connection with you, tests it in front of you and only then adds it, tagged **Experimental**.
14. **Rooms.** A live map of your rooms (personal, work, a shared room with a partner). Rooms can be shared through iCloud Drive or kept in sync with a private GitHub repo.

## How it is built

One is deliberately small: **one Swift file** and a build script. No Xcode project.

| Piece | What it is |
|---|---|
| **Face** | A SwiftUI app (`Sources/main.swift`), built with `swiftc` for Apple Silicon, macOS 14+. |
| **Engine** | [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research (MIT). It brings model routing to any provider, tools (files, browser, web, scheduling), memory and secret stores. One never shows it to the user. |
| **Talking to the engine** | Hermes's ACP adapter: JSON-RPC over stdio (`initialize`, `session/new`, `session/prompt`). Replies stream in; permission requests become "needs your yes" cards. |
| **Isolation** | One runs its own Hermes in `~/Library/Application Support/One`, with its own `HERMES_HOME`, so it never mixes with another Hermes on the same Mac. |
| **First-launch install** | Hermes's official installer, bundled in the app and run non-interactively with a scratch `HOME`, so nothing outside One's folder changes. |
| **Folder lock** | The engine runs inside a macOS sandbox profile (`sandbox-exec`). Your home folder is closed except One's own data, your memory and the folders you approve. This is enforced by the Mac, not by the model's good behaviour. |
| **Sign-in** | Hermes's own OAuth/device-code flows (`hermes auth add <provider>`), so any provider Hermes supports becomes available to One. |
| **Memory** | Rooms built from a "brain starter" template set: plain Markdown files, one folder per room, with rules for what each room may hold. Writes inside your memory need no yes; anything outside still asks. |
| **Voice** | [Kokoro](https://github.com/thewh1teagle/kokoro-onnx) (open source, default voice `af_heart`, six to choose from), running on the Mac: no account, no cost per word, nothing leaves the Mac. Downloaded once after the engine (`tools/install_voice.sh`, ~350 MB) and run by `tools/speak.py`. It speaks setup lines with the user's and assistant's names, and reads replies aloud sentence by sentence. Setup lines are also pre-recorded in the same voice as a fallback until the download finishes. |
| **Connections** | Passwords use a KeePass vault backend for Hermes (`tools/overlay/agent/vault_backends/keepass.py`, via `keepassxc-cli`); the master password can come from the macOS Keychain and is held in memory only. One copies the KeePass backend into its engine after every install, so it survives engine updates. Each connection opens only the paths it needs in the sandbox. Connections built with the assistant are saved as skills under `skills/my-connections/` and listed in `connections.json`. |
| **Routines** | Hermes scheduled jobs. One watches their results and reads new ones aloud. |
| **Design** | The world screen was designed in Claude Design and rebuilt natively: a living set of soft rings for the assistant, upright tiles drifting around it, links that draw in when you tap. |

### Build it

Requirements: an Apple Silicon Mac, macOS 14+, Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh             # builds build/One.app
./build.sh --install   # also copies it to ~/Applications
./build.sh --package   # builds build/One.dmg
```

Optional: `BRAIN_STARTER=/path/to/brain-starter` to bundle memory room templates.

Developer flags on the app binary: `--selftest` (runs the engine against a throwaway home; needs `OPENROUTER_API_KEY`), `--install-test` (fresh-user install into `ONE_SUPPORT_DIR`), `--render-world <prefix>` (renders the world, Connections, rooms and the brain and voice card to PNGs), `--say "text"` (speaks a line through the voice engine), `--signin-probe <provider>`, `--reset`.

To re-record the fallback voice lines: edit `voice/lines.json`, then `python3 tools/render_voice.py <dir with kokoro-v1.0.onnx and voices-v1.0.bin>` (needs `kokoro-onnx`, `soundfile`, `ffmpeg`).

## Privacy

- Your files, memory and settings stay on your Mac.
- What you ask is sent to the AI provider you chose, under your own account.
- One has no server, no analytics and no account of its own.

## Roadmap

- News as a built-in connection.
- Outlook sign-in through Microsoft (needs a free Microsoft developer directory).
- A "Today" page: what it did, what needs your yes, what it noticed.
- It reaches out first ("your flight dropped $80, book it?").
- Your phone: a small companion app for iPhone and Android, so you can reach your assistant away from the Mac.
- Signed and notarised builds.
- Maybe later: an optional hosted version for people who don't want to keep a Mac on. One stays free and open source.

## Contributing

Ideas, bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). The bar for every change is the same question: does this make it simpler for someone who is not technical?

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research, the engine underneath.
- Voice by [Kokoro](https://huggingface.co/hexgrad/Kokoro-82M) (Apache 2.0). World screen first designed with Claude Design.

## License

[MIT](LICENSE)
