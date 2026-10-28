import Darwin
import Foundation

// MARK: - Their own Chrome's sign-ins, in the hidden browser (Connections › Browser › Chrome)

/// Up to 0.9.45 Connections › Browser always read "Connected" and did nothing, so an assistant that
/// read One's code rightly said "using your Chrome isn't built". Connect now copies the sign-ins of
/// the person's own Chrome (One runs outside the folder lock, so it can read Chrome's folder) into
/// One's folder and points the hidden browser at that copy: same port, always headless, never a
/// window. Their Chrome keeps running and is never touched. The copy is refreshed every time One
/// starts the hidden browser, on Connect, and when the assistant leaves `browser/resync`.
enum MyChrome {
    static var copyDir: URL { Env.support.appendingPathComponent("browser/my-chrome") }
    static var resyncFile: URL { Env.support.appendingPathComponent("browser/resync") }
    static var chromeData: String { NSHomeDirectory() + "/Library/Application Support/Google/Chrome" }
    static let port = 9223
    nonisolated(unsafe) static var busy = false
    nonisolated(unsafe) static var lastSync: Date?

    /// Is this hidden browser the copy of their own Chrome?
    static func isCopy(_ p: BrowserKeeper.Plan?) -> Bool { p?.profile == copyDir.path }
    static var connected: Bool { isCopy(BrowserKeeper.plan) }
    static var copiedAt: Date? {
        let marker = copyDir.appendingPathComponent(".hermes-snapshot-complete").path
        return (try? FileManager.default.attributesOfItem(atPath: marker))?[.modificationDate] as? Date
    }
    static var copiedLine: String {
        guard let d = copiedAt else { return "not copied yet" }
        return "copied " + d.formatted(date: .abbreviated, time: .shortened)
    }

    /// Copy their Chrome's sign-ins into `copyDir` (Hermes's own snapshot code, run outside the lock).
    /// Never while a browser has the copy open: a copy over open databases corrupts them.
    static func sync() async -> String? {
        if BrowserKeeper.alive(port), BrowserKeeper.profileInUse(port) == copyDir.path { return "the hidden browser is still open" }
        guard let src = Bundle.main.url(forResource: "one_my_chrome", withExtension: "py") else {
            return "One is missing a piece (one_my_chrome.py)."
        }
        let dst = Env.engineDir.appendingPathComponent("tools/one_my_chrome.py")
        if (try? Data(contentsOf: dst)) != (try? Data(contentsOf: src)) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        let (code, out) = await hermesRun(["--run-module", "tools.one_my_chrome", "chrome", copyDir.path], timeout: 180)
        let line = out.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }.map(String.init) ?? ""
        let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        if code == 0, j?["ok"] as? Bool == true {
            BrowserKeeper.log("copied Chrome's sign-ins (profile \(j?["profile"] as? String ?? "?")) into \(copyDir.path)")
            return nil
        }
        let why = (j?["error"] as? String) ?? String(out.suffix(300))
        BrowserKeeper.log("couldn't copy Chrome's sign-ins: \(why)")
        return why
    }

    /// Stop the hidden browser only when it runs on the copy (never their own Chrome, never another profile).
    static func stopCopy() -> Bool {
        guard let pid = BrowserKeeper.pidOn(port) else { return true }
        guard BrowserKeeper.profileInUse(port) == copyDir.path else { return false }
        kill(pid, SIGTERM)
        for _ in 0..<40 where BrowserKeeper.alive(port) { usleep(250_000) }
        if BrowserKeeper.alive(port) { kill(pid, SIGKILL) }
        for _ in 0..<20 where BrowserKeeper.alive(port) { usleep(250_000) }
        return !BrowserKeeper.alive(port)
    }

    /// Connections › Browser › Chrome › Connect. Returns nil when the hidden browser runs on the copy.
    static func connect() async -> String? {
        guard BrowserKeeper.chromeApp != nil else {
            return "Google Chrome isn't on this Mac. Install it, sign in to your sites there, then tap Connect again."
        }
        guard FileManager.default.fileExists(atPath: chromeData + "/Local State") else {
            return "Chrome hasn't been used on this Mac yet. Open it once, sign in to your sites, then tap Connect again."
        }
        if let p = BrowserKeeper.plan, !isCopy(p), BrowserKeeper.alive(p.port) {
            return "A hidden browser is already set up here with its own sign-ins, so I left it as it is."
        }
        busy = true
        defer { busy = false }
        guard stopCopy() else { return "Something else is using the hidden browser's port \(port). Try again in a minute." }
        if let e = await sync() { return "I couldn't copy Chrome's sign-ins: \(e)" }
        lastSync = Date()
        try? FileManager.default.createDirectory(at: copyDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let k: [String: Any] = ["port": port, "profile": copyDir.path, "headless": true]
        if let d = try? JSONSerialization.data(withJSONObject: k, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: BrowserKeeper.settingsFile)
        }
        // The engine reads browser.cdp_url on every browser call: no restart, no helper cut off.
        _ = await hermesRun(["config", "set", "browser.cdp_url", "http://localhost:\(port)"])
        UserDefaults.standard.set("Chrome", forKey: "browserWith")
        BrowserKeeper.lastStart = nil
        busy = false
        BrowserKeeper.tend()
        for _ in 0..<40 where !BrowserKeeper.alive(port) { try? await Task.sleep(for: .milliseconds(500)) }
        return BrowserKeeper.alive(port) ? nil : "I copied your sign-ins, but the hidden browser didn't start. I'll keep trying by myself."
    }

    /// Disconnect: stop the copy and delete it (it holds copies of their sign-ins). Their Chrome is untouched.
    static func disconnect() async {
        guard connected else { return }
        busy = true
        defer { busy = false }
        _ = stopCopy()
        try? FileManager.default.removeItem(at: BrowserKeeper.settingsFile)
        try? FileManager.default.removeItem(at: copyDir)
        _ = await hermesRun(["config", "set", "browser.cdp_url", ""])
        UserDefaults.standard.removeObject(forKey: "browserWith")
        BrowserKeeper.log("disconnected their Chrome: copy deleted")
    }

    /// From `BrowserKeeper.tend()`: before starting the copy again, refresh it (the browser is down,
    /// so it's safe), and honour the assistant's request in `browser/resync`. True = tend should wait.
    static func tend(_ p: BrowserKeeper.Plan, alive: Bool) -> Bool {
        if busy { return true }
        guard isCopy(p) else { return false }
        let asked = FileManager.default.fileExists(atPath: resyncFile.path)
        if alive && !asked { return false }
        // Down and just refreshed (or the refresh failed): let the keeper start it on what's there.
        if !alive && !asked, let t = lastSync, Date().timeIntervalSince(t) < 120 { return false }
        busy = true
        lastSync = Date()
        Task.detached {
            if asked { try? FileManager.default.removeItem(at: resyncFile) }
            if !alive || stopCopy() { _ = await sync() }
            lastSync = Date()
            BrowserKeeper.lastStart = nil
            busy = false
        }
        return true
    }

    /// Per-prompt note (main chat and helpers): what's built, so nobody says it isn't.
    static func note(_ p: BrowserKeeper.Plan?) -> String {
        guard let p else {
            return """


                (One app note, not from the user: their own browser isn't connected yet. Using their Chrome IS built: they click Connections at the top, then Browser, pick Chrome and tap Connect. One copies the sign-ins from their own Chrome into a hidden browser you can use (their Chrome stays open and untouched, no window opens). If they want you to use their Chrome or their signed-in sites, send them there; never say it isn't built. Arc, Safari and other browsers aren't built yet.)
                """
        }
        guard isCopy(p) else { return "" }
        return """


            (One app note, not from the user: the hidden browser on port \(p.port) is a copy of their own Chrome's sign-ins (\(copiedLine)), connected in Connections › Browser. Sites they're signed in to in Chrome are signed in there too. If a site they signed in to in Chrome since then still shows signed out, create an empty file at \(resyncFile.path): One copies their Chrome again within a minute (it restarts that hidden browser, so not while another helper is mid-task in it). It's always hidden; their own Chrome is never touched.)
            """
    }

    /// What Connect tells the assistant for the browsers and password managers One doesn't do by itself.
    static func ask(_ id: String, _ with: String) -> String? {
        switch (id, with) {
        case ("Browser", "Arc"):
            return
                "I use Arc and want you to use my signed-in sites. Say plainly in one line that One copies sign-ins only from Chrome so far, so Arc isn't built yet. Then offer the two ways that work today: if I also have Chrome, I sign in there and connect it in Connections › Browser › Chrome; or you save a login for one site at a time (I type it into the secure box, never this chat)."
        case ("Passwords", "1Password"):
            return """
                Connect my 1Password. Do it one step at a time and do every part you can yourself:
                1. Check that the 1Password app and its command-line tool are on this Mac (`op --version`). If the tool is missing and Homebrew is there, install it with `brew install 1password-cli`; if not, tell me to get "1Password CLI" from 1password.com/downloads/command-line.
                2. Ask me to open the 1Password app, then Settings, Developer, and turn on "Integrate with 1Password CLI". 1Password must be unlocked.
                3. Run `op vault list`. 1Password may show its own "Allow access" box: tell me to click Authorize there. Never ask for my 1Password password in this chat.
                4. Check you can see my logins (names only, never a password). If op says it can't read its settings, say exactly what it said.
                5. Only when that works, run `defaults write ai.forjado.one passwordsWith 1Password` so Connections shows it, and tell me in one line it's connected.
                """
        default: return nil
        }
    }
}
