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
        expect(!BrowserKeeper.launchArguments(vis, app: "x").contains("--headless=new"), "a visible window when asked")

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
        expect(BrowserKeeper.note.isEmpty || BrowserKeeper.note.contains("--browser-check"), "the assistant is told how to check sign-ins")

        print(fails.isEmpty ? "browser ok" : "browser FAILED: \(fails.count)")
        return fails.isEmpty ? 0 : 1
    }
}
