import SQLite3
import Foundation

// MARK: - `One --test-browser`: the hidden-browser keeper's decisions, without starting Chrome

enum BrowserCheck {
    static func run() -> Int32 {
        var fails: [String] = []
        func expect(_ ok: Bool, _ what: String) {
            print((ok ? "ok   " : "FAIL ") + what)
            if !ok { fails.append(what) }
        }
        let cfg = "browser:\n  cdp_url: http://localhost:9223   # hidden Chrome\n  inactivity_timeout: 120\n"
        expect(BrowserKeeper.port(fromConfig: cfg) == 9223, "reads the local port from browser.cdp_url")
        expect(BrowserKeeper.port(fromConfig: "browser:\n  cdp_url: \"http://127.0.0.1:9444\"\n") == 9444, "127.0.0.1 and quotes work")
        expect(BrowserKeeper.port(fromConfig: "browser:\n  cdp_url: wss://cloud.example.com/x\n") == nil, "a remote browser is never started here")
        expect(BrowserKeeper.port(fromConfig: "browser:\n  inactivity_timeout: 120\n") == nil, "no cdp_url, nothing to keep")

        let p = BrowserKeeper.plan(config: cfg, settings: nil)
        expect(p?.port == 9223 && p?.profile == BrowserKeeper.defaultProfile && p?.headless == true, "default: One's own saved profile, hidden")
        let s = #"{"port": 9223, "profile": "~/profiles/mine", "headless": true}"#.data(using: .utf8)
        let q = BrowserKeeper.plan(config: cfg, settings: s)
        expect(q?.profile == NSHomeDirectory() + "/profiles/mine", "keeper.json names the saved profile (~ expanded)")
        expect(BrowserKeeper.plan(config: "", settings: s)?.port == 9223, "keeper.json alone is enough")
        expect(BrowserKeeper.plan(config: "", settings: nil) == nil, "nothing set up, nothing started")

        let a = BrowserKeeper.launchArguments(q!, app: "/Applications/Google Chrome.app")
        expect(a.prefix(4) == ["-g", "-n", "-a", "/Applications/Google Chrome.app"], "starts through the Mac, in the background")
        expect(a.contains("--user-data-dir=\(q!.profile)") && a.contains("--remote-debugging-port=9223"), "same profile, same port")
        expect(a.contains("--headless=new"), "hidden")
        expect(!a.contains("--no-sandbox"), "Chrome keeps its own safety sandbox (it runs outside the folder lock)")
        var vis = q!
        vis.headless = false
        expect(BrowserKeeper.launchArguments(vis, app: "x").contains("--headless=new"), "hidden even when a plan asks for a window")
        let visible = #"{"port": 9223, "headless": false}"#.data(using: .utf8)
        expect(BrowserKeeper.plan(config: cfg, settings: visible)?.headless == true, "keeper.json can't ask for a visible window")

        let future = Date().timeIntervalSince1970 + 86400 * 30
        let signedIn: [[String: Any]] = [["name": "sessionKey", "domain": ".claude.ai", "expires": future]]
        expect(BrowserKeeper.signIn(site: "claude.ai", cookies: signedIn)?.hasPrefix("signed in until") == true, "Claude session cookie = signed in")
        let old: [[String: Any]] = [["name": "sessionKey", "domain": ".claude.ai", "expires": 1000.0]]
        expect(BrowserKeeper.signIn(site: "claude.ai", cookies: old) == "signed out (expired)", "expired cookie = signed out")
        let other: [[String: Any]] = [["name": "cf_clearance", "domain": ".claude.ai", "expires": future]]
        expect(BrowserKeeper.signIn(site: "claude.ai", cookies: other) == "signed out", "a human-check cookie alone isn't a sign-in")
        expect(BrowserKeeper.signIn(site: "claude.ai", cookies: nil) == nil, "browser down = unknown, not signed out")

        // The loop never starts Chrome from a test or command-line copy.
        BrowserKeeper.lastStart = nil
        BrowserKeeper.tend()
        expect(BrowserKeeper.lastStart == nil, "a test copy never starts a browser")
        expect(
            BrowserKeeper.note.contains("--connect-chrome") && (BrowserKeeper.plan == nil || BrowserKeeper.note.contains("--browser-check")),
            "the assistant is told how to connect their Chrome itself, and how to check sign-ins")

        // Their own Chrome (Connections › Browser › Chrome): a hidden copy, never a window, never their Chrome.
        let mine = BrowserKeeper.Plan(port: 9223, profile: MyChrome.copyDir.path, headless: true)
        expect(MyChrome.isCopy(mine) && !MyChrome.isCopy(q) && !MyChrome.isCopy(nil), "knows when the hidden browser is their Chrome's copy")
        expect(!MyChrome.copyDir.path.contains("Google/Chrome"), "the copy lives in One's folder, not in Chrome's")
        let ma = BrowserKeeper.launchArguments(mine, app: "/Applications/Google Chrome.app")
        expect(ma.contains("--headless=new") && ma.contains("--disable-sync"), "the copy runs hidden and never syncs back into their Google account")
        expect(ma.last == "about:blank" && !a.contains("--disable-sync"), "other hidden browsers keep their settings")
        expect(!MyChrome.tend(q!, alive: true), "a hidden browser that isn't the copy is left alone")
        let none = MyChrome.note(nil)
        expect(
            none.contains("--connect-chrome") && none.contains("Connecting your Chrome now.") && none.contains("Never send them to Connections")
                && none.contains("never say it isn't built"),
            "with no browser connected, every prompt says: connect their Chrome yourself, right now, no menus")
        expect(
            none.contains("Your Mac will ask if One can read Chrome's saved logins. Tap Always Allow.") && none.contains("Try again"),
            "a Keychain Deny is explained once, with a way to try again")
        expect(
            MyChrome.note(mine).contains("--connect-chrome") && MyChrome.note(mine).contains("copy of their own Chrome"),
            "once connected, the assistant knows how to refresh the copy")
        expect(MyChrome.note(q).contains("--connect-chrome"), "the rule is there even when another hidden browser is set up")
        expect(!(none + MyChrome.note(mine)).contains("Connections › Browser"), "no prompt sends anyone to the Connections menu for Chrome")
        ChromeBridgeCheck.run(expect)
        expect(MyChrome.note(mine).contains("--chrome-check"), "once connected, the assistant knows the plain-words self-test")
        expect(MyChrome.ask("Browser", "Arc")?.contains("isn't built yet") == true, "Arc: told plainly it isn't built, with what works")
        let op = MyChrome.ask("Passwords", "1Password") ?? ""
        expect(
            op.contains("Integrate with 1Password CLI") && op.contains("op vault list"), "1Password: the real steps (CLI, desktop integration, test)")
        expect(Env.vars()["OP_CONFIG_DIR"]?.hasPrefix(Env.support.path) == true, "1Password's op gets a settings folder inside the lock")
        let soul = Persona.soul(assistant: "Ava", user: "EK")
        expect(
            soul.contains("--connect-chrome") && soul.contains("Connecting your Chrome now.") && !soul.contains("pick Chrome and tap Connect"),
            "SOUL: connect their Chrome yourself when asked, never the menu")

        // `--chrome-check`: plain words for every way the copy can fail (EK's Mac).
        let sid: [String: Any] = ["site": "Google", "domain": ".google.com", "name": "SID"]
        let gh: [String: Any] = ["site": "GitHub", "domain": "github.com", "name": "user_session"]
        let good: [String: Any] = ["ok": true, "cookies": 600, "signs": [sid, gh], "checked": "2026-10-28T15:00:00Z"]
        let liveOK: [[String: Any]] =
            [["name": "SID", "domain": ".google.com", "value": "x"]] + Array(repeating: ["name": "a", "domain": ".a.com", "value": "y"], count: 400)
        let ok = ChromeCheck.evaluate(report: good, live: liveOK, connected: true, otherBrowser: true)
        expect(
            ok.ok && ok.lines.joined().contains("Signed in, in my hidden browser: Google") && ok.lines.joined().contains("GitHub"),
            "chrome check: lists sites signed in, and copied ones not working yet")
        let denied = ChromeCheck.evaluate(report: good, live: [], connected: true, otherBrowser: true)
        expect(
            !denied.ok && denied.lines.joined().contains("Always Allow") && denied.lines.joined().contains("Chrome Safe Storage"),
            "chrome check: Keychain Deny is explained, with how to fix it")
        let notConn = ChromeCheck.evaluate(report: nil, live: nil, connected: false, otherBrowser: false)
        expect(
            notConn.code == 2 && notConn.lines.joined().contains("use your Chrome") && !notConn.lines.joined().contains("Connections"),
            "chrome check: not connected says to just ask, no menu")
        let otherB = ChromeCheck.evaluate(report: nil, live: nil, connected: false, otherBrowser: true)
        expect(otherB.code == 2 && otherB.lines.joined().contains("not your Chrome"), "chrome check: another hidden browser is named as such")
        let failed = ChromeCheck.evaluate(
            report: ["ok": false, "error": "Chrome is running and holds a write lock"], live: nil, connected: true, otherBrowser: true)
        expect(failed.code == 1 && failed.lines.joined().contains("try again"), "chrome check: a failed copy says what to do")
        let starting = ChromeCheck.evaluate(report: good, live: nil, connected: true, otherBrowser: true)
        expect(!starting.ok && starting.lines.joined().contains("starting up"), "chrome check: a browser still starting isn't called broken")
        for w in [
            "no-chrome-folder", "chrome-folder-unreadable",
            "SQLite backup made no progress within five seconds — a running browser holds a write lock on it", "weird",
        ] {
            let s = ChromeCheck.plain(w)
            expect(!s.contains("SQLite") && !s.contains("-folder") && s.count < 260, "plain words for \"\(w.prefix(30))\"")
        }
        expect(
            !MyChrome.note(nil).isEmpty && MyChrome.note(nil).contains("--chrome-check"),
            "no browser yet: the assistant knows the self-test for a failed Connect")

        BrowserGuardCheck.run(expect)
        humanCheck(expect)

        print(fails.isEmpty ? "browser ok" : "browser FAILED: \(fails.count)")
        return fails.isEmpty ? 0 : 1
    }

    /// The "verify you are human" loop: a normal user agent when hidden, a plain window for the tick.
    static func humanCheck(_ expect: (Bool, String) -> Void) {
        let ua = BrowserKeeper.userAgent(version: "156.0.8078.48") ?? ""
        expect(
            ua == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36",
            "hidden browser sends the user agent Chrome sends in a window (no HeadlessChrome)")
        expect(BrowserKeeper.userAgent(version: "") == nil, "unknown Chrome version: no made-up user agent")
        if let app = BrowserKeeper.chromeApp {
            let a = BrowserKeeper.launchArguments(BrowserKeeper.Plan(port: 9223, profile: "/tmp/p", headless: true), app: app)
            let u = a.first { $0.hasPrefix("--user-agent=") } ?? ""
            expect(u.contains("Chrome/") && !u.contains("Headless") && a.contains("--headless=new"), "still hidden, with the normal user agent")
        }
        let h = HumanCheck.headedArguments(profile: "/tmp/p", url: "https://claude.ai/design", app: "/Applications/Google Chrome.app")
        expect(h.contains("--user-data-dir=/tmp/p") && h.last == "https://claude.ai/design", "the check window opens the same profile on the page")
        expect(
            !h.contains {
                $0.hasPrefix("--remote-debugging") || $0.hasPrefix("--headless") || $0.contains("Automation") || $0.hasPrefix("--user-agent")
            },
            "the check window has nothing attached: no DevTools port, no automation flags, Chrome's own user agent")
        expect(!h.contains("-g"), "the check window comes to the front (their tap on Show the window is the yes)")
        let ask = HumanStepAsk(id: "x", site: "claude.ai", kind: "check", line: "", port: 9223, target: "t", url: "https://claude.ai/")
        let code = HumanStepAsk(id: "y", site: "claude.ai", kind: "code", line: "", port: 9223, target: "t", url: "https://claude.ai/")
        expect(HumanCheck.wanted(ask) && !HumanCheck.wanted(code), "only robot checks get the plain window; codes keep the live view")
        expect(
            HumanCheckCard.siteName(site: "claude.ai", url: "https://claude.ai/design/p/1") == "Claude Design"
                && HumanCheckCard.siteName(site: "amazon.com", url: "https://amazon.com/") == "amazon.com",
            "the card names the site (Claude Design for its pages)")
        expect(
            HumanCheckCard.action("check") == "tick “I'm human”" && HumanCheckCard.action("code") == "enter the code",
            "the card says the one thing to do")
        expect(HumanCheck.mainChrome(profile: "/tmp/one-no-such-profile-\(getpid())") == nil, "no Chrome holds an unused profile")

        // The pass is read from the profile's cookie file, the way Chrome stores it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("one-cf-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("Cookies").path
        let when = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        var db: OpaquePointer?
        sqlite3_open(f, &db)
        sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, name TEXT, creation_utc INTEGER, last_update_utc INTEGER)", nil, nil, nil)
        sqlite3_exec(db, "INSERT INTO cookies VALUES ('.claude.ai', 'cf_clearance', 1, \(when)), ('.claude.ai', 'sessionKey', 1, 1)", nil, nil, nil)
        sqlite3_close(db)
        let t = HumanCheck.lastClearance(cookies: f, site: "claude.ai") ?? 0
        expect(abs(t - Date().timeIntervalSince1970) < 5, "sees the check's cookie land (last update time)")
        expect(HumanCheck.lastClearance(cookies: f, site: "example.com") == nil, "another site's check doesn't count")
        expect(HumanCheck.lastClearance(cookies: f + "-missing", site: "claude.ai") == nil, "no cookie file, no pass")
        try? FileManager.default.removeItem(at: dir)
    }
}
