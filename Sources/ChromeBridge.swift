import Foundation

// MARK: - "Use my Chrome" from a chat: `One --connect-chrome [profile]`

/// Up to 0.9.48 the only way to connect their own Chrome was Connections › Browser › Chrome › Connect:
/// the engine runs inside the folder lock, which closes Chrome's own folder, so the assistant could only
/// send people to a menu. Now the assistant runs `One --connect-chrome` itself. Inside the lock that
/// command can't read Chrome either, so it hands the job to the One that's open (outside the lock)
/// through a request file in One's own folder and prints what One answers. Run outside the lock (a
/// person in Terminal, a test), it does the job in its own process. Either way: the profile they really
/// use, a copy of its sign-ins in the hidden browser (headless, their Chrome untouched), one real
/// signed-in site checked, a plain-words result. The engine needs no new folder and no restart: it only
/// talks to the hidden browser's local port and reads `browser.cdp_url` on every browser call, so
/// helpers already at work keep going and use it on their next step.
extension MyChrome {
    static var requestDir: URL { Env.support.appendingPathComponent("browser/connect-requests") }
    static var pinFile: URL { Env.support.appendingPathComponent("browser/my-chrome-profile") }

    /// Exit codes the assistant is told about.
    enum Result: Int32 {
        case connected = 0
        case failed = 1
        case askProfile = 3
        case otherBrowser = 4
        case unverified = 5
        case keychain = 6
    }

    // MARK: Which Chrome profile

    struct Profile: Equatable {
        var dir: String
        var name: String
        var active: Date?
    }

    /// Chrome's own list of profiles (Local State), and the one it used last.
    static func profiles(localState: Data?) -> (last: String, all: [Profile]) {
        guard let d = localState, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let p = j["profile"] as? [String: Any]
        else { return ("Default", []) }
        let last = (p["last_used"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Default"
        let cache = (p["info_cache"] as? [String: Any]) ?? [:]
        let all = cache.keys.sorted().map { dir -> Profile in
            let e = (cache[dir] as? [String: Any]) ?? [:]
            let t = (e["active_time"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return Profile(dir: dir, name: (e["name"] as? String) ?? dir, active: t)
        }
        return (last, all)
    }

    enum Pick: Equatable {
        case use(Profile)
        case ask([Profile])
        case notFound(String, [Profile])
    }

    /// The profile to copy: the one they named; else the one picked before; else the only one in use
    /// lately (opened in the last 7 days), falling back to Chrome's last used. Asks only when several
    /// profiles were really used this week.
    static func pick(_ asked: String?, last: String, all: [Profile], pinned: String?, now: Date = Date()) -> Pick {
        let lastP = all.first { $0.dir == last } ?? Profile(dir: last, name: last, active: nil)
        if let a = asked?.trimmingCharacters(in: .whitespaces).lowercased(), !a.isEmpty {
            if let p = all.first(where: { $0.dir.lowercased() == a || $0.name.lowercased() == a }) { return .use(p) }
            if let p = all.first(where: { $0.name.lowercased().contains(a) }) { return .use(p) }
            return .notFound(asked ?? "", all)
        }
        if let pin = pinned, let p = all.first(where: { $0.dir == pin }) { return .use(p) }
        let recent = all.filter { ($0.active.map { now.timeIntervalSince($0) < 7 * 86400 }) ?? false }
        if recent.count > 1 { return .ask(recent.sorted { ($0.active ?? .distantPast) > ($1.active ?? .distantPast) }) }
        return .use(recent.first ?? lastP)
    }

    static var pinned: String? {
        (try? String(contentsOf: pinFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Checking one real signed-in site

    struct Site {
        let host: String
        let cookie: String
        let page: String
        let signedOut: [String]
    }
    /// Well-known sites: a session cookie that proves a sign-in, a page only a signed-in person sees,
    /// and where the site sends someone who isn't signed in.
    static let sites: [Site] = [
        Site(host: "google.com", cookie: "SID", page: "https://myaccount.google.com/", signedOut: ["accounts.google.com", "/signin"]),
        Site(host: "github.com", cookie: "user_session", page: "https://github.com/settings/profile", signedOut: ["/login", "/session"]),
        Site(host: "amazon.com", cookie: "x-main", page: "https://www.amazon.com/gp/css/homepage.html", signedOut: ["/ap/signin"]),
        Site(host: "claude.ai", cookie: "sessionKey", page: "https://claude.ai/settings", signedOut: ["/login"]),
        Site(host: "x.com", cookie: "auth_token", page: "https://x.com/settings/account", signedOut: ["/login", "/i/flow/"]),
        Site(host: "facebook.com", cookie: "c_user", page: "https://www.facebook.com/settings", signedOut: ["/login"]),
        Site(host: "linkedin.com", cookie: "li_at", page: "https://www.linkedin.com/feed/", signedOut: ["/login", "authwall", "/uas/"]),
        Site(host: "netflix.com", cookie: "NetflixId", page: "https://www.netflix.com/account", signedOut: ["/login"]),
    ]

    /// Sites whose session cookie the hidden browser holds (not expired), in `sites` order.
    static func candidates(_ cookies: [[String: Any]]) -> [Site] {
        let now = Date().timeIntervalSince1970
        return sites.filter { s in
            cookies.contains { c in
                (c["name"] as? String) == s.cookie && ((c["domain"] as? String) ?? "").hasSuffix(s.host)
                    && (((c["expires"] as? Double) ?? -1) <= 0 || ((c["expires"] as? Double) ?? 0) > now)
            }
        }
    }

    static func http(_ method: String, _ url: String, timeout: TimeInterval = 5) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = timeout
        return try? await URLSession.shared.data(for: r).0
    }

    /// Opens the site's signed-in page in a hidden tab and checks where it lands. Closes the tab after.
    static func signedIn(_ s: Site, port: Int) async -> Bool {
        let base = "http://127.0.0.1:\(port)/json"
        guard let d = await http("PUT", "\(base)/new?\(s.page)"),
            let t = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = t["id"] as? String
        else { return false }
        var url = ""
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(500))
            guard let d = await http("GET", "\(base)/list"), let l = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]],
                let me = l.first(where: { $0["id"] as? String == id })
            else { continue }
            url = (me["url"] as? String) ?? ""
            if !url.isEmpty && url != "about:blank" && !url.hasPrefix(s.page) { break }
        }
        _ = await http("GET", "\(base)/close/\(id)")
        guard url.contains(s.host) else { return false }
        return !s.signedOut.contains { url.contains($0) }
    }

    // MARK: The connect itself (in One's own process, outside the lock)

    /// Connect (or refresh) their Chrome in the hidden browser and check one site. Returns (code, plain words).
    static func connectNow(_ asked: String?) async -> (Result, String) {
        guard BrowserKeeper.chromeApp != nil else {
            return (
                .failed,
                "Google Chrome isn't on this Mac, so there are no Chrome sign-ins to use. Once Chrome is installed and you've signed in to your sites there, ask me again."
            )
        }
        guard let state = FileManager.default.contents(atPath: chromeData + "/Local State") else {
            return (.failed, "Chrome hasn't been used on this Mac yet. Open it once and sign in to your sites, then ask me again.")
        }
        let (last, all) = profiles(localState: state)
        let profile: Profile
        switch pick(asked, last: last, all: all, pinned: asked == nil ? pinned : nil) {
        case .use(let p): profile = p
        case .ask(let ps):
            let names = ps.map(\.name)
            return (
                .askProfile,
                "You use more than one Chrome profile: \(names.joined(separator: ", ")). Which one should I use?\nASK: end with [choices: \(names.prefix(4).joined(separator: " | "))], then run `\(Bridge.exe) --connect-chrome \"<their pick>\"`."
            )
        case .notFound(let a, let ps):
            return (.failed, "I couldn't find a Chrome profile called \"\(a)\". Your profiles: \(ps.map(\.name).joined(separator: ", ")).")
        }
        // Another hidden browser set up before is left running; the copy takes the next free port (MyChrome.freePort).
        if let e = await connect(profile: profile.dir, verify: false) { return (.failed, e) }
        try? profile.dir.write(to: pinFile, atomically: true, encoding: .utf8)
        let who = all.count > 1 ? " (profile \"\(profile.name)\")" : ""
        // The copied cookies are locked with Chrome's key in the Mac's Keychain; a Deny there leaves the hidden browser with none.
        var cookies: [[String: Any]] = []
        for _ in 0..<10 {
            cookies = await BrowserKeeper.cookies(port) ?? []
            if cookies.count > 2 { break }
            try? await Task.sleep(for: .seconds(1))
        }
        // What the copy held vs what the hidden browser can read (ChromeCheck): almost nothing readable = the Keychain said no.
        var check = await ChromeCheck.current()
        for _ in 0..<5 where !check.ok {
            try? await Task.sleep(for: .seconds(2))
            check = await ChromeCheck.current()
        }
        if !check.ok && check.lines.joined().contains("Chrome Safe Storage") {
            return (
                .keychain,
                "KEYCHAIN: your Mac didn't let Chrome's saved logins be read, so the hidden browser isn't signed in to anything. If a box asked about \"Chrome Safe Storage\" and you tapped Deny, I can try again: this time tap Always Allow."
            )
        }
        for s in candidates(cookies) {
            guard await signedIn(s, port: port) else { continue }
            return (
                .connected,
                "Connected: your Chrome's sign-ins\(who) are in my hidden browser. Checked: you're signed in to \(s.host) there. No window opens, and your Chrome stays as it is."
            )
        }
        return (
            .unverified,
            "Connected: your Chrome's sign-ins\(who) are in my hidden browser (no window, your Chrome untouched). I couldn't confirm a sign-in on one of the big sites; tell me a site you use and I'll check it there."
        )
    }

    // MARK: Requests from inside the folder lock

    /// `One --connect-chrome [profile]`. Returns nil when this isn't that command.
    static func cli(_ args: [String]) -> Int32? {
        if let k = args.firstIndex(of: "--chrome-serve") {
            // A test copy only (lint: TestWorld): One's request loop without its window, for a set time.
            TestWorld.enter()
            let secs = k + 1 < args.count ? Double(args[k + 1]) ?? 300 : 300
            return blocking {
                let end = Date().addingTimeInterval(secs)
                while Date() < end {
                    await serve()
                    try? await Task.sleep(for: .milliseconds(500))
                }
                return 0
            }
        }
        if args.contains("--print-chrome-prompt") {
            // A test copy only: what a brand-new person's assistant is told (SOUL, then the per-prompt note).
            TestWorld.enter()
            print(Persona.soul(assistant: "Juan", user: "EK"))
            print("=====NOTE=====")
            print(BrowserKeeper.note + Helpers.helperNote)
            return 0
        }
        if args.contains("--chrome-check") { return blocking { await ChromeCheck.run() } }
        if args.contains("--chrome-connect") { return blocking { await ChromeCheck.connectFromCommandLine() } }
        guard let k = args.firstIndex(of: "--connect-chrome") else { return nil }
        let asked = k + 1 < args.count && !args[k + 1].hasPrefix("--") ? args[k + 1] : nil
        return blocking {
            let (code, text): (Result, String)
            if FileManager.default.isReadableFile(atPath: chromeData + "/Local State") {
                (code, text) = await connectNow(asked)  // outside the lock: do it here
            } else {
                (code, text) = await request(asked)  // inside the lock: the open One does it
            }
            print(text)
            return code.rawValue
        }
    }

    static func blocking(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
        let out = Box<Int32>(1)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            out.v = await body()
            sem.signal()
        }
        sem.wait()
        return out.v
    }

    /// Leave a request for the open One and wait for its answer (up to 5 minutes).
    static func request(_ asked: String?) async -> (Result, String) {
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: requestDir, withIntermediateDirectories: true)
        let req = requestDir.appendingPathComponent("\(id).json")
        let j: [String: Any] = ["profile": asked ?? "", "asked": ISO8601DateFormatter().string(from: Date())]
        guard let d = try? JSONSerialization.data(withJSONObject: j), (try? d.write(to: req)) != nil else {
            return (.failed, "I couldn't reach One's own folder to ask for your Chrome.")
        }
        let taken = requestDir.appendingPathComponent("\(id).taken")
        let answer = requestDir.appendingPathComponent("\(id).out.json")
        let start = Date()
        while Date().timeIntervalSince(start) < 300 {
            if let d = try? Data(contentsOf: answer), let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                try? FileManager.default.removeItem(at: answer)
                try? FileManager.default.removeItem(at: taken)
                let code = Result(rawValue: Int32((a["code"] as? Int) ?? 1)) ?? .failed
                return (code, (a["text"] as? String) ?? "")
            }
            if Date().timeIntervalSince(start) > 30 && !FileManager.default.fileExists(atPath: taken.path) {
                try? FileManager.default.removeItem(at: req)
                return (.failed, "One didn't answer just now (it does the copy itself, so it has to be open). I'll try again in a moment.")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return (.failed, "Copying your Chrome's sign-ins is taking too long. I'll keep the hidden browser as it is; try again in a few minutes.")
    }

    nonisolated(unsafe) static var serving = false

    /// The open One's own loop: the engine can't read Chrome's folder, so One does the copy for it.
    static func serveLoop() {
        Task.detached {
            while true {
                if !Env.selfTest && !Env.commandLine { await serve() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One's side (its own loop, and `--chrome-serve` in a test copy): answer each waiting request.
    static func serve() async {
        if serving { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: requestDir.path) else { return }
        for n in names where n.hasSuffix(".json") && !n.hasSuffix(".out.json") {
            let req = requestDir.appendingPathComponent(n)
            let id = String(n.dropLast(5))
            let age = ((try? fm.attributesOfItem(atPath: req.path))?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? 0
            if age > 600 {
                try? fm.removeItem(at: req)
                continue
            }
            serving = true
            defer { serving = false }
            let j = (try? Data(contentsOf: req)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            try? fm.removeItem(at: req)
            fm.createFile(atPath: requestDir.appendingPathComponent("\(id).taken").path, contents: nil)
            let asked = (j["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            BrowserKeeper.log("the assistant asked to connect their Chrome\(asked.map { " (profile \($0))" } ?? "")")
            let (code, text) = await connectNow(asked)
            BrowserKeeper.log("connect their Chrome: \(code) \(text.prefix(120))")
            let out: [String: Any] = ["code": Int(code.rawValue), "text": text]
            if let d = try? JSONSerialization.data(withJSONObject: out) {
                try? d.write(to: requestDir.appendingPathComponent("\(id).out.json"), options: .atomic)
            }
        }
    }

    // MARK: What the assistant and every helper are told

    /// The "use my Chrome" rule, in SOUL and in every prompt (main chat, helpers, follow-ups, resumes).
    static var rule: String {
        """
        USE THEIR CHROME: when they say anything like "use my Chrome", "use my browser", "connect my Chrome", "use the sites I'm signed in to", do it right away yourself: say one line, "Connecting your Chrome now.", and run `\(Bridge.exe) --connect-chrome` (add a profile name only if they named one). It copies the sign-ins from their own Chrome into your hidden browser (always hidden, their Chrome untouched, stays connected for every helper and routine) and checks one site. Then tell them its result in plain words. Exit 3 = it lists their Chrome profiles: ask which one with the choices it gives, then run it again with that name. Exit 6 (a line starting KEYCHAIN) = their Mac didn't let Chrome's saved logins be read: say once "Your Mac will ask if One can read Chrome's saved logins. Tap Always Allow." and run it again; if it fails the same way again, explain once that without that yes you can't use their Chrome sign-ins, and offer to try again ([choices: Try again | Not now]). If it or a site they need doesn't work, run `\(Bridge.exe) --chrome-check` and tell them what it says in its own plain words. Helpers run it the same way as the main chat. Never send them to Connections or any menu or setting for this, never say it isn't built. Arc, Safari and other browsers: only Chrome's sign-ins can be copied so far; say so in one line and offer Chrome or saving a login for one site at a time.
        """
    }
}
