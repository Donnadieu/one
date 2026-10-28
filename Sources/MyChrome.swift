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
    /// 9223, the hidden browser's usual port. A test copy (its own bundle id) may pick another, never the person's One.
    static var firstPort: Int {
        if Bundle.main.bundleIdentifier != TestWorld.productionID,
            let p = ProcessInfo.processInfo.environment["ONE_BROWSER_PORT"].flatMap({ Int($0) })
        {
            return p
        }
        return 9223
    }
    /// The copy's port: 9223 unless another hidden browser (one the assistant or the person set up
    /// before) already answers there, then the next free one. That browser is left running.
    static var port: Int { BrowserKeeper.plan.flatMap { isCopy($0) ? $0.port : nil } ?? firstPort }
    static func freePort() -> Int {
        for p in firstPort..<(firstPort + 20) where p != 9333 {
            if !BrowserKeeper.alive(p) || BrowserKeeper.profileInUse(p) == copyDir.path { return p }
        }
        return firstPort
    }
    /// What the last copy found (profile, how many cookies, which well-known sign-ins). Names and counts only.
    static var reportFile: URL { Env.support.appendingPathComponent("browser/my-chrome.json") }
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
    static func sync(profile: String? = nil) async -> String? {
        if BrowserKeeper.alive(port), BrowserKeeper.profileInUse(port) == copyDir.path { return "the hidden browser is still open" }
        guard let src = Bundle.main.url(forResource: "one_my_chrome", withExtension: "py") else {
            return "One is missing a piece (one_my_chrome.py)."
        }
        let dst = Env.engineDir.appendingPathComponent("tools/one_my_chrome.py")
        if (try? Data(contentsOf: dst)) != (try? Data(contentsOf: src)) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        // The profile they use (picked once, kept in pinFile), so a refresh never swaps whose sign-ins these are.
        let prof = profile ?? pinned
        let (code, out) = await hermesRun(
            ["--run-module", "tools.one_my_chrome", "chrome", copyDir.path] + (prof.map { ["--profile", $0] } ?? []), timeout: 180)
        let line = out.split(whereSeparator: \.isNewline).last { $0.hasPrefix("{") }.map(String.init) ?? ""
        var j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        j["checked"] = ISO8601DateFormatter().string(from: Date())
        if j["ok"] == nil { j["ok"] = false }
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: reportFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: reportFile)
        }
        if code == 0, j["ok"] as? Bool == true {
            let n = (j["signs"] as? [Any])?.count ?? 0
            BrowserKeeper.log("copied Chrome's sign-ins (profile \(j["profile"] as? String ?? "?"), \(n) known sign-ins) into \(copyDir.path)")
            return nil
        }
        let why = (j["error"] as? String) ?? String(out.suffix(300))
        BrowserKeeper.log("couldn't copy Chrome's sign-ins: \(why)")
        return ChromeCheck.plain(why)
    }

    /// Stop the hidden browser only when it runs on the copy (never their own Chrome, never another profile).
    static func stopCopy() -> Bool {
        guard let pid = BrowserKeeper.pidOn(port) else { return true }
        guard BrowserKeeper.profileInUse(port) == copyDir.path else { return true }  // not the copy: left alone, the copy takes another port
        kill(pid, SIGTERM)
        for _ in 0..<40 where BrowserKeeper.alive(port) { usleep(250_000) }
        if BrowserKeeper.alive(port) { kill(pid, SIGKILL) }
        for _ in 0..<20 where BrowserKeeper.alive(port) { usleep(250_000) }
        return !BrowserKeeper.alive(port)
    }

    /// Connections › Browser › Chrome › Connect. Returns nil when the hidden browser runs on the copy.
    /// verify: false when the caller (`connectNow`) does its own check and says the result itself.
    static func connect(profile: String? = nil, verify: Bool = true) async -> String? {
        guard BrowserKeeper.chromeApp != nil else {
            return "Google Chrome isn't on this Mac. Install it, sign in to your sites there, then try again."
        }
        guard FileManager.default.fileExists(atPath: chromeData + "/Local State") else {
            return "Chrome hasn't been used on this Mac yet. Open it once, sign in to your sites, then try again."
        }
        // A hidden browser set up earlier (by the assistant, or One's own) used to block this with
        // "already set up", and the tile then read Connected with no way to switch: EK's dead end.
        // It's left running, untouched; the copy takes the next free port.
        if let p = BrowserKeeper.plan, !isCopy(p) { BrowserKeeper.log("switching from the hidden browser on \(p.port) to their Chrome's copy") }
        busy = true
        defer { busy = false }
        guard stopCopy() else { return "Something else is using the hidden browser's port \(port). Try again in a minute." }
        if let e = await sync(profile: profile) { return e }
        lastSync = Date()
        try? FileManager.default.createDirectory(at: copyDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let port = freePort()
        let k: [String: Any] = ["port": port, "profile": copyDir.path, "headless": true]
        if let d = try? JSONSerialization.data(withJSONObject: k, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: BrowserKeeper.settingsFile)
        }
        // The engine reads browser.cdp_url on every browser call: no restart, no helper cut off.
        _ = await hermesRun(["config", "set", "browser.cdp_url", "http://localhost:\(port)"])
        if !Env.commandLine { UserDefaults.standard.set("Chrome", forKey: "browserWith") }
        BrowserKeeper.lastStart = nil
        busy = false
        // Start it here (not only from the keeper loop), so this also works from `One --chrome-connect`.
        if let p = BrowserKeeper.plan, !BrowserKeeper.alive(p.port) { BrowserKeeper.start(p) }
        // A first start on a fresh copy can take half a minute.
        for _ in 0..<120 where !BrowserKeeper.alive(port) { try? await Task.sleep(for: .milliseconds(500)) }
        guard BrowserKeeper.alive(port) else {
            return
                "I copied your sign-ins, but the hidden browser didn't start yet. I'll keep trying by myself; try again in a minute if it still says this."
        }
        // The Mac must let Chrome unlock its saved sign-ins (Keychain, "Chrome Safe Storage"). Check it really did.
        return verify ? await ChromeCheck.verify() : nil
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

    /// Per-prompt note (main chat and every helper turn): what's built and the "use my Chrome" rule.
    static func note(_ p: BrowserKeeper.Plan?) -> String {
        let head = "\n\n(One app note, not from the user: "
        guard let p, isCopy(p) else {
            let state = p == nil ? "Their own Chrome isn't connected yet. " : ""
            return head + state + rule + ")"
        }
        return head
            + "the hidden browser on port \(p.port) is a copy of their own Chrome's sign-ins (\(copiedLine)). Sites they're signed in to in Chrome are signed in there too. If a site they signed in to in Chrome since then still shows signed out, run `\(Bridge.exe) --connect-chrome` again: it copies their Chrome again (it restarts that hidden browser, so not while another helper is mid-task in it). If they say a site doesn't work there, run `\(Bridge.exe) --chrome-check` and tell them what it says, in its own plain words. "
            + rule + ")"
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
