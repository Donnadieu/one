import AppKit
import Foundation

// MARK: - `One --test-hidden-browser`: a hidden browser never shows in the Dock or Stage Manager, never comes to the front

/// The decisions always run. The live part starts a real headless Chrome and runs only on CI (`CI` set), where no
/// person's screen is in the way: it also opens "Google Chrome" the way a Dock click would while only the hidden one
/// runs, which is what turned Project Ledger's hidden browser into a normal app with a Dock icon (Nov 2026).
enum HiddenBrowserCheck {
    nonisolated(unsafe) static var step = "starting"
    static func say(_ s: String) {
        step = s
        FileHandle.standardError.write(Data("  … \(s)\n".utf8))
    }

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        Task.detached {
            try? await Task.sleep(for: .seconds(150))
            print("✗ stuck at: \(step)")
            exit(1)
        }
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            Task { @MainActor in exit(await checks()) }
        }
        NSApplication.shared.run()
        return 0
    }

    @MainActor static func checks() async -> Int32 {
        var fails = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "✓ " : "✗ ") + what)
            if !ok { fails += 1 }
        }
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        check(HiddenBrowser.isHeadless([chrome, "--headless=new", "--user-data-dir=/p"]), "a headless Chrome is a hidden browser")
        check(!HiddenBrowser.isHeadless([chrome, "--user-data-dir=/p"]), "their own Chrome (a window) is never touched")
        check(!HiddenBrowser.isHeadless([chrome + " Helper", "--type=renderer", "--headless"]), "Chrome's helper processes are skipped")
        check(HiddenBrowser.port([chrome, "--remote-debugging-port=9333"]) == 9333, "reads a hidden browser's port")

        let approved = FileManager.default.temporaryDirectory.appendingPathComponent("one-hb-approved-\(getpid())").path
        Access.override = [approved]
        defer { Access.override = nil }
        check(
            HiddenBrowser.allowed(profile: Env.support.appendingPathComponent("browser/ledger").path),
            "a saved profile in One's folder may be started")
        check(HiddenBrowser.allowed(profile: approved + "/ai-content-chrome"), "so may one in a folder they let One use")
        check(!HiddenBrowser.allowed(profile: "/tmp/one-never-approved"), "a folder they never let One use, never")
        check(
            !HiddenBrowser.allowed(profile: MyChrome.chromeData) && !HiddenBrowser.allowed(profile: MyChrome.chromeData + "/Default"),
            "their own Chrome's folder, never (its copy lives in One's folder)")
        check(!HiddenBrowser.allowed(profile: Env.support.path + "/../../Google/Chrome"), "no climbing out of One's folder with ..")
        check(HiddenBrowser.refusal(port: 80, profile: approved + "/x") != nil, "a port under 1024 is refused")

        let app = "/Applications/Google Chrome.app"
        let a = HiddenBrowser.requestArguments(
            port: 9333, profile: approved + "/x", url: "https://x.com/home",
            flags: ["--disable-renderer-backgrounding", "--remote-allow-origins=*", "--no-sandbox"], app: app)
        check(a.first == "--headless=new" && a.contains("--remote-debugging-port=9333"), "a requested browser is always hidden, on its port")
        check(
            a.contains("--disable-renderer-backgrounding") && !a.contains("--remote-allow-origins=*") && !a.contains("--no-sandbox"),
            "only the known switches pass")
        check(a.last == "https://x.com/home", "it opens the page asked for")
        let f = HiddenBrowser.requestArguments(port: 9333, profile: approved + "/x", url: "file:///etc/hosts", flags: [], app: app)
        check(f.last == "about:blank", "only web pages, never a file")
        check(
            BrowserGuard.note.contains("--hidden-browser") && BrowserGuard.soul.contains("--hidden-browser"), "the assistant is told how to start one"
        )

        guard ProcessInfo.processInfo.environment["CI"] != nil, let app = BrowserKeeper.chromeApp else {
            print("hidden browser: the live part runs on CI only (it starts Chrome)")
            print(fails == 0 ? "hidden browser ok" : "hidden browser FAILED: \(fails)")
            return fails == 0 ? 0 : 1
        }
        await live(app: app, check)
        print(fails == 0 ? "hidden browser ok" : "hidden browser FAILED: \(fails)")
        return fails == 0 ? 0 : 1
    }

    @MainActor static func live(app: String, _ check: (Bool, String) -> Void) async {
        say("live part: starting a hidden Chrome")
        HiddenBrowser.testing = true
        HiddenBrowser.watch()
        let port = 9871
        let prof = Env.support.appendingPathComponent("browser/hb-test").path
        let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: HiddenBrowser.chromeID).map(\.processIdentifier))
        let plan = BrowserKeeper.Plan(port: port, profile: prof, headless: true)
        let e = await Task.detached { HiddenBrowser.launch(app: app, arguments: BrowserKeeper.launchArguments(plan, app: app)) }.value
        check(e == nil, "started through the Mac (\(e ?? "ok"))")
        say("waiting for it to answer")
        var pid: pid_t?
        var frontSeen = false
        var regularSeen = false
        let start = Date()
        while Date().timeIntervalSince(start) < 30 {
            if pid == nil {
                pid =
                    NSRunningApplication.runningApplications(withBundleIdentifier: HiddenBrowser.chromeID)
                    .first { !before.contains($0.processIdentifier) }?.processIdentifier
            }
            if let pid, let r = NSRunningApplication(processIdentifier: pid) {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { frontSeen = true }
                if r.activationPolicy == .regular && Date().timeIntervalSince(start) > 3 { regularSeen = true }
                if Date().timeIntervalSince(start) > 6 && BrowserKeeper.alive(port) { break }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard let pid, let r = NSRunningApplication(processIdentifier: pid) else {
            check(false, "the hidden browser answers")
            return
        }
        check(BrowserKeeper.alive(port), "the hidden browser answers on its port")
        check(!frontSeen, "never the front app while it starts")
        check(!regularSeen && r.activationPolicy != .regular, "not a normal app once started: no Dock icon, not in Stage Manager")

        // Someone opens "Google Chrome" (a Dock click, Spotlight, a script) while only the hidden one runs.
        say("opening Google Chrome while only the hidden one runs")
        let c = NSWorkspace.OpenConfiguration()
        c.activates = true
        c.createsNewApplicationInstance = false
        let got = Box<pid_t?>(nil)
        let answered = Box(false)
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: c) { a, e in
            got.v = a?.processIdentifier
            answered.v = true
            if let e { print("  the Mac said: \(e.localizedDescription)") }
        }
        let asked = Date()
        while !answered.v && Date().timeIntervalSince(asked) < 15 { try? await Task.sleep(for: .milliseconds(100)) }
        if !answered.v { print("  the Mac didn't answer that launch within 15 s") }
        let opened = got.v
        let reused = opened == pid
        say("watching the front for 4 s")
        print("  macOS sent that launch to the hidden browser: \(reused ? "yes" : "no, it started their Chrome")")
        var frontAfter = false
        var hiddenOrBackground = true
        let t = Date()
        while Date().timeIntervalSince(t) < 4 {
            HiddenBrowser.tend(idle: false)
            if Date().timeIntervalSince(t) > 1, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { frontAfter = true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let r = NSRunningApplication(processIdentifier: pid), r.activationPolicy == .regular, !r.isHidden { hiddenOrBackground = false }
        check(!frontAfter, "the hidden browser doesn't stay in front (One hides it within a second)")
        check(hiddenOrBackground, "and stays out of Stage Manager (background-only, or hidden)")
        if reused, NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
            // It's a normal app now: once nothing uses it, One closes it politely so it starts again fresh.
            let u = Date()
            while Date().timeIntervalSince(u) < 25 && kill(pid, 0) == 0 {
                HiddenBrowser.tend(idle: true)
                try? await Task.sleep(for: .milliseconds(250))
            }
            check(kill(pid, 0) != 0, "a hidden browser macOS made a normal app is closed once nothing uses it")
        }
        // Tidy up: the hidden browser and any Chrome that launch started.
        say("tidying up")
        await HiddenBrowser.close(pid: pid, port: port)
        for x in NSRunningApplication.runningApplications(withBundleIdentifier: HiddenBrowser.chromeID) where !before.contains(x.processIdentifier) {
            x.forceTerminate()
        }
        try? FileManager.default.removeItem(atPath: prof)
    }
}
