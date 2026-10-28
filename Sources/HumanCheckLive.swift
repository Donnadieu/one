import AppKit
import SQLite3

/// `One --test-human-window` (tools/human-window-check.sh): the whole human-check flow, end to end, on a real
/// robot-check page, with a real Chrome window the person (or the tester) clicks in. Never the shared browser:
/// a throwaway hidden Chrome on its own port (ONE_CHECK_PORT, not 9223) on a copied profile (ONE_CHECK_PROFILE).
/// Steps: hidden browser up → page blocked → One's own ask → the card's yes → a plain Chrome window on the
/// same profile and page (no DevTools port) with One's card beside it → the check passes or Done
/// (`<support>/done`) → the window goes away, the hidden browser comes back on the same profile, the page is
/// reopened past the check and the answer carries the new tab.
enum HumanCheckLive {
    @MainActor
    static func launch() -> Bool {
        // From the test copy's Info.plist (LSEnvironment) too: a check run from inside the folder lock starts the copy
        // through Launch Services, so it runs like the real One (outside the lock) and its own `open` works.
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.contains("--test-human-window") || env["ONE_TEST_MODE"] == "--test-human-window" else { return false }
        if let log = env["ONE_CHECK_LOG"] {
            freopen(log, "a", stdout)
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        TestWorld.enter()  // a throwaway hidden Chrome on its own port and a copied profile
        let flushOnly = env["ONE_CHECK_FLUSH"] != nil
        Task { @MainActor in exit(flushOnly ? await flush() : await run()) }
        return true
    }

    /// No window: a hidden Chrome started through Launch Services gets a cookie, then `HumanCheck.quit` closes it
    /// at once. The cookie must be in the profile's Cookies file afterwards (SIGTERM lost it).
    @MainActor
    static func flush() async -> Int32 {
        let env = ProcessInfo.processInfo.environment
        guard Env.selfTest, let port = env["ONE_CHECK_PORT"].flatMap(Int.init), port != 9223, let profile = env["ONE_CHECK_PROFILE"],
            let app = BrowserKeeper.chromeApp
        else {
            print("refusing: run tools/human-window-check.sh (own port, copied profile, never port 9223)")
            return 2
        }
        let p = BrowserKeeper.Plan(port: port, profile: profile, headless: true)
        _ = BrowserKeeper.openApp(BrowserKeeper.launchArguments(p, app: app))
        var pid: pid_t?
        for _ in 0..<30 where pid == nil || !BrowserKeeper.alive(port) {
            try? await Task.sleep(for: .milliseconds(500))
            pid = HumanCheck.mainChrome(profile: profile)
        }
        guard let pid, let target = await HumanCheck.openTab(port: port, url: "https://example.com/") else {
            print("cookie flush: no browser")
            return 1
        }
        try? await Task.sleep(for: .seconds(3))
        let page = StepPage(port: port, target: target)
        page.connectQuiet()
        _ = await page.call("Runtime.evaluate", ["expression": "document.cookie='oneflush=1; max-age=86400; path=/'"])
        page.disconnect()
        try? await Task.sleep(for: .milliseconds(500))
        let t = Date()
        await HumanCheck.quit(pid)
        let took = Date().timeIntervalSince(t)
        var db: OpaquePointer?
        var found = false
        if sqlite3_open_v2("file:\(profile)/Default/Cookies?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cookies WHERE name = 'oneflush'", -1, &st, nil) == SQLITE_OK,
                sqlite3_step(st) == SQLITE_ROW
            {
                found = sqlite3_column_int(st, 0) > 0
            }
            sqlite3_finalize(st)
        }
        sqlite3_close(db)
        print("cookie flush: quit took \(String(format: "%.1f", took)) s, cookie saved: \(found)")
        print(found ? "human window ok" : "human window FAILED: cookie lost")
        return found ? 0 : 1
    }

    /// A real screenshot of a hidden tab over its DevTools socket, saved into ONE_CHECK_SHOTS (when set).
    @MainActor
    static func shot(port: Int, target: String, name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["ONE_CHECK_SHOTS"] else { return }
        let page = StepPage(port: port, target: target)
        page.connectQuiet()
        try? await Task.sleep(for: .milliseconds(400))
        let r = await page.call("Page.captureScreenshot", ["format": "png"])
        page.disconnect()
        guard let b = r["data"] as? String, let d = Data(base64Encoded: b) else { return print("   screenshot \(name): none") }
        let f = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? d.write(to: f)
        print("   screenshot: \(f.path)")
    }

    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            fflush(stdout)
            if !ok { fails += 1 }
        }
        let env = ProcessInfo.processInfo.environment
        guard Env.selfTest, let port = env["ONE_CHECK_PORT"].flatMap(Int.init), port != 9223, let profile = env["ONE_CHECK_PROFILE"],
            let url = env["ONE_CHECK_URL"]
        else {
            print("refusing: run tools/human-window-check.sh (own port, copied profile, never port 9223)")
            return 2
        }
        let plan = BrowserKeeper.Plan(port: port, profile: profile, headless: true)
        BrowserKeeper.planOverride = plan
        print("1. hidden browser on \(port) with the copied profile")
        BrowserKeeper.lastStart = nil
        BrowserKeeper.tend()
        var up = false
        for _ in 0..<40 where !up {
            try? await Task.sleep(for: .milliseconds(500))
            up = BrowserKeeper.alive(port)
        }
        check("hidden browser answering", up)
        guard up else { return 1 }
        let ua = (BrowserKeeper.version(port)?["User-Agent"] as? String) ?? ""
        print("   user agent: \(ua)")
        guard let target = await HumanCheck.openTab(port: port, url: url) else {
            check("opened the page", false)
            return 1
        }
        print("2. waiting for the robot check on \(url)")
        var page: BlockedAsk.Page?
        for _ in 0..<40 where page == nil {
            try? await Task.sleep(for: .seconds(1))
            page = await BlockedAsk.pages(port: port).first { $0.target == target && BlockedAsk.isChallenge(title: $0.title, url: $0.url) }
        }
        check("the hidden browser is stopped by the check (\(page?.title ?? "no check"))", page != nil)
        guard let page else { return 1 }
        await shot(port: port, target: target, name: "1 hidden browser blocked")

        print("3. One's ask, then the card's yes")
        let m = Model.shared
        m.askBlocked(page, port: port)
        m.tendHumanSteps()
        guard let a = m.humanSteps.first(where: { $0.target == target }) else {
            check("One asked", false)
            return 1
        }
        check("One asked: \(a.line)", a.ask && a.kind == "check")
        let started = Date()
        m.showHumanStep(a)  // what "Yes, show it" on the card does since this fix
        check("the live view did not open", HumanStep.windows[a.id]?.window == nil)
        var pid: pid_t?
        for _ in 0..<40 where pid == nil {
            try? await Task.sleep(for: .milliseconds(500))
            if let p = HumanCheck.active?.pid { pid = p }
        }
        check("a Chrome window opened on the same profile", pid != nil)
        guard let pid else { return 1 }
        let args = GatewayGuard.arguments(of: pid)
        print("   window Chrome: \(args.joined(separator: " "))")
        check(
            "nothing attached (no DevTools port, not headless)", !args.contains { $0.hasPrefix("--remote-debugging") || $0.hasPrefix("--headless") })
        check("on the blocked page", args.last == page.url)
        check("the hidden browser is down while the window is up", !BrowserKeeper.alive(port))
        try? await Task.sleep(for: .seconds(2))
        check("One's card is on screen beside it", HumanCheckCard.panel?.isVisible == true)
        let frame = HumanCheckCard.chromeFrame(pid: pid)
        print("   chrome window: \(frame.map { "\($0)" } ?? "none"), card: \(HumanCheckCard.panel.map { "\($0.frame)" } ?? "none")")
        let doneFile = Env.support.appendingPathComponent("done")
        print("WINDOW UP pid=\(pid). Tick the check in the window, or touch \(doneFile.path) to tap Done.")
        fflush(stdout)

        print("4. waiting for the check to pass or Done (up to 10 minutes)")
        while HumanCheck.active != nil {
            if FileManager.default.fileExists(atPath: doneFile.path) {
                try? FileManager.default.removeItem(at: doneFile)
                m.answerHumanStep(a.id, "done")  // the card's Done
            }
            try? await Task.sleep(for: .seconds(1))
        }
        let answerFile = HumanStep.dir.appendingPathComponent("\(a.id).answer.json")
        var ans: [String: Any] = [:]
        for _ in 0..<60 where ans.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            if let d = try? Data(contentsOf: answerFile), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { ans = j }
        }
        print("   answer: \(ans)")
        check("the window is gone", kill(pid, 0) != 0 && HumanCheckCard.panel == nil)
        check("the hidden browser is back on the same profile", BrowserKeeper.alive(port) && BrowserKeeper.profileInUse(port) == profile)
        let newTarget = ans["target_id"] as? String ?? ""
        check("the page was reopened for the helper (\(ans["why"] ?? "?"))", ans["relaunched"] as? Bool == true && !newTarget.isEmpty)
        var after: BlockedAsk.Page?
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            after = await BlockedAsk.pages(port: port).first { $0.target == newTarget }
            if let p = after, !p.title.isEmpty, !BlockedAsk.isChallenge(title: p.title, url: p.url) { break }
        }
        print("   hidden tab now: \(after?.title ?? "?") \(after?.url ?? "")")
        check("the hidden browser is past the check", after.map { !BlockedAsk.isChallenge(title: $0.title, url: $0.url) } ?? false)
        if !newTarget.isEmpty { await shot(port: port, target: newTarget, name: "3 hidden browser after the window") }
        let t = HumanCheck.lastClearance(cookies: profile + "/Default/Cookies", site: a.site) ?? 0
        print("   check cookie saved: \(t > started.timeIntervalSince1970 ? "yes, new" : "no new one")")
        let cookies = await BrowserKeeper.cookies(port)
        print("   claude.ai: \(BrowserKeeper.signIn(site: "claude.ai", cookies: cookies) ?? "unknown")")
        BrowserKeeper.planOverride = nil
        print(fails == 0 ? "human window ok" : "human window FAILED: \(fails)")
        return fails == 0 ? 0 : 1
    }
}
