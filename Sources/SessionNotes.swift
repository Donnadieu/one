import Foundation

// MARK: - What every conversation is told on every prompt: the main assistant and every helper alike

/// A conversation picked back up after an update (`session/load`) keeps the system prompt it started with: the engine
/// reuses the stored prompt unless the model, provider or folder changed (agent/conversation_loop.py,
/// `_stored_prompt_matches_runtime`). So SOUL alone can't teach an old helper what a new One has built or what its
/// screen looks like. One adds the same notes to every prompt: the main chat, a helper's first turn, every follow-up,
/// and helpers picked back up after a restart or an update.
@MainActor
enum SessionNotes {
    /// One's real screen (also in SOUL, `Persona.soul`).
    nonisolated static let screen = """
        This app (One) is what they see. You know its screen: the orb in the middle, the chat under it with a box that says "Or say it your way…", a Ready for you list on the right, and a row of buttons along the top: Voice on/off, your brain and voice, Rooms, Connections (what you can reach: Email, Calendar, Passwords, Browser, Files and more), Routines (every scheduled job, watcher and skill you made for them, on a 24-hour dial, with Run now, Pause and Ask), Push to talk, Folders, Switch AI, and Stop. There is no Settings, gear, preferences or "Passwords & Logins" screen, and they never use a terminal. Never point them to those, even if a tool message says so; point to these buttons by name instead. The engine underneath sometimes names screens and tools from another app (a Settings, Credential Vault or "Passwords & Logins" screen, `hermes vault add`, an "MCP" connector): none of those exist here. Logins and password managers are connected in Connections › Passwords; their own Chrome they never connect by hand: you do it with `--connect-chrome` when they ask.
        """
    /// Where logins and their own browser get connected (also in SOUL).
    nonisolated static let logins = """
        Logins: when a job needs them to be signed in to a site (a bank, Monarch, Amazon…), don't send them hunting. Ask one simple question, ending with [choices: My password manager | My browser is signed in | I'll sign in myself | Something else]. Then:
        - Password manager: tell them to click Connections at the top, then Passwords, then pick theirs (KeePass, 1Password, Bitwarden, or Something else) and walk them through it step by step.
        - Browser: if it's Chrome (or they don't say), connect it yourself right now, no menus: say "Connecting your Chrome now." and run `\(Bridge.exe) --connect-chrome` (USE THEIR CHROME below). If it's already connected, just use it. Arc, Safari and other browsers can't be copied yet: say so in one line, and offer Chrome or saving a login for one site at a time.
        - Sign in themselves: open the site in the browser and let them type the password there; never ask them to type a password into this chat.
        Once it's connected, carry on with the job without making them ask again.
        """
    /// Newer than the conversation's own instructions, which froze when it started: where they differ, this wins.
    static var screenNote: String {
        "\n\n(One app note, not from the user: ONE'S SCREEN, as of this version. This is newer than anything earlier in your "
            + "instructions or this conversation; where they differ, this wins. " + screen + "\n" + logins + ")"
    }

    /// Every helper prompt, on top of `Helpers.helperNote` (which already carries the browser rule).
    static var helper: String {
        screenNote + Bridge.note + BrowserKeeper.note + Model.githubNote + FolderWatch.note + VersionNote.note
    }
    /// Every main-assistant prompt: the same notes, plus the browser rule.
    static var main: String { helper + BrowserGuard.note }
}
