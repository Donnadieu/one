import Darwin
import Foundation

// MARK: - The hidden browser: keep it running with its saved sign-ins

/// Helpers browse in a hidden Chrome that One's settings point at (`browser.cdp_url`, a local port).
/// Its profile folder holds the person's sign-ins (Claude, Google, shops…). When that Chrome crashed,
/// nothing inside the folder lock could start it again with the same profile (the lock closes the
/// folder, and Chrome can't open its own lock file), so helpers opened fresh browsers with no
/// sign-ins and got stuck on human checks. One itself is outside the lock, so it does the restart:
/// same profile, same port, hidden. It never stops a browser that is already answering on the port.
enum BrowserKeeper {
    struct Plan: Equatable {
        var port: Int
        var profile: String
        var headless: Bool
    }

    /// Optional settings file the assistant can write (it's inside One's own folder):
    /// {"port": 9223, "profile": "/path/to/profile", "headless": true}
    static var settingsFile: URL { Env.support.appendingPathComponent("browser/keeper.json") }
    static var healthFile: URL { Env.support.appendingPathComponent("browser/health.json") }
    static var defaultProfile: String { Env.support.appendingPathComponent("browser/chrome-profile").path }

    /// The local port in `browser.cdp_url`, or nil when it's missing or points at another machine.
    static func port(fromConfig text: String) -> Int? {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("cdp_url:") else { continue }
            let pattern = #"https?://(localhost|127\.0\.0\.1):(\d+)"#
            guard let r = l.range(of: pattern, options: .regularExpression) else { return nil }
            let url = String(l[r])
            return url.split(separator: ":").last.flatMap { Int($0) }
        }
        return nil
    }

    static func plan(config: String, settings: Data?) -> Plan? {
        var p: Plan? = port(fromConfig: config).map { Plan(port: $0, profile: defaultProfile, headless: true) }
        if let d = settings, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let port = (j["port"] as? Int) ?? p?.port
            guard let port else { return nil }
            let prof = (j["profile"] as? String).map { NSString(string: $0).expandingTildeInPath } ?? defaultProfile
            p = Plan(port: port, profile: prof, headless: (j["headless"] as? Bool) ?? true)
        }
        return p
    }

    static var plan: Plan? {
        let cfg = (try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? ""
        return plan(config: cfg, settings: try? Data(contentsOf: settingsFile))
    }

    static var chromeApp: String? {
        ["/Applications/Google Chrome.app", NSHomeDirectory() + "/Applications/Google Chrome.app"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func launchArguments(_ p: Plan, app: String) -> [String] {
        var a = ["-g", "-n", "-a", app, "--args"]
        if p.headless { a.append("--headless=new") }
        a += [
            "--user-data-dir=\(p.profile)", "--remote-debugging-port=\(p.port)", "--no-first-run", "--no-default-browser-check",
            "--window-size=1440,900", "--disable-blink-features=AutomationControlled", "about:blank",
        ]
        return a
    }

    /// Does a browser answer on this port?
    static func alive(_ port: Int) -> Bool { version(port) != nil }

    static func version(_ port: Int) -> [String: Any]? {
        guard let u = URL(string: "http://127.0.0.1:\(port)/json/version") else { return nil }
        let out = Box<[String: Any]?>(nil)
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: u)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { d, _, _ in
            out.v = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out.v
    }

    nonisolated(unsafe) static var lastStart: Date?
    nonisolated(unsafe) static var lastNote = ""
    nonisolated(unsafe) static var lastHealth: Date?

    static func log(_ s: String) {
        guard s != lastNote else { return }
        lastNote = s
        let f = Env.hermesHome.appendingPathComponent("logs/one-browser-keeper.log")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    /// Called every few seconds from its own loop (App.swift).
    static func tend() {
        if Env.selfTest || Env.commandLine { return }
        guard let p = plan else { return log("no local browser set up") }
        if alive(p.port) {
            log("browser answering on \(p.port)")
            if lastHealth.map({ Date().timeIntervalSince($0) > 1800 }) ?? true {
                lastHealth = Date()
                Task.detached { await writeHealth(p) }
            }
            return
        }
        // One start a minute at most: a broken profile must not loop.
        if let t = lastStart, Date().timeIntervalSince(t) < 60 { return }
        guard let app = chromeApp else { return log("Google Chrome isn't installed; nothing to start") }
        lastStart = Date()
        try? FileManager.default.createDirectory(atPath: p.profile, withIntermediateDirectories: true)
        let pr = Process()
        // Through Launch Services, so Chrome isn't One's child: it keeps running if One quits.
        pr.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        pr.arguments = launchArguments(p, app: app)
        pr.standardOutput = FileHandle.nullDevice
        pr.standardError = FileHandle.nullDevice
        do {
            try pr.run()
            pr.waitUntilExit()
            log("browser was down on \(p.port); started it again with its saved profile \(p.profile)")
        } catch {
            log("couldn't start the browser: \(error.localizedDescription)")
        }
    }

    // MARK: Sign-in health (Claude first; any site by its session cookie)

    /// Session cookies that prove a sign-in, by site.
    static let sessionCookies: [String: String] = ["claude.ai": "sessionKey"]

    static func cookies(_ port: Int) async -> [[String: Any]]? {
        guard let ws = version(port)?["webSocketDebuggerUrl"] as? String, let u = URL(string: ws) else { return nil }
        let task = URLSession.shared.webSocketTask(with: u)
        task.maximumMessageSize = 64 << 20
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        do {
            try await task.send(.string(#"{"id":1,"method":"Storage.getCookies"}"#))
            for _ in 0..<50 {
                guard case .string(let s) = try await task.receive(),
                    let j = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], j["id"] as? Int == 1
                else { continue }
                return (j["result"] as? [String: Any])?["cookies"] as? [[String: Any]]
            }
        } catch {}
        return nil
    }

    /// "signed in until 2026-11-26", "signed out", or nil when the browser isn't answering.
    static func signIn(site: String, cookies: [[String: Any]]?) -> String? {
        guard let cookies else { return nil }
        let name = sessionCookies[site] ?? "sessionKey"
        let hit = cookies.first { c in
            (c["name"] as? String) == name && ((c["domain"] as? String) ?? "").hasSuffix(site)
        }
        guard let hit else { return "signed out" }
        let exp = (hit["expires"] as? Double) ?? -1
        if exp > 0 && exp < Date().timeIntervalSince1970 { return "signed out (expired)" }
        if exp <= 0 { return "signed in (until the browser closes)" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "signed in until " + f.string(from: Date(timeIntervalSince1970: exp))
    }

    static func writeHealth(_ p: Plan) async {
        let c = await cookies(p.port)
        var j: [String: Any] = ["checked": ISO8601DateFormatter().string(from: Date()), "port": p.port, "profile": p.profile]
        j["browser"] = c == nil ? "not answering" : "answering"
        for site in sessionCookies.keys.sorted() { j[site] = signIn(site: site, cookies: c) ?? "unknown" }
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: healthFile)
        }
        if let s = j["claude.ai"] as? String, s.hasPrefix("signed out") { log("health: claude.ai is \(s)") }
    }

    /// Which profile the browser on this port really uses (another helper may have started its own).
    static func profileInUse(_ port: Int) -> String? {
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        pr.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        pr.standardOutput = pipe
        pr.standardError = FileHandle.nullDevice
        guard (try? pr.run()) != nil else { return nil }
        pr.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let pid = out.split(whereSeparator: \.isNewline).first.flatMap({ pid_t($0) }) else { return nil }
        return GatewayGuard.arguments(of: pid).first { $0.hasPrefix("--user-data-dir=") }.map { String($0.dropFirst(16)) }
    }

    /// `One --browser-check`: read-only, prints the browser's state and the Claude sign-in. Exit 0 = signed in.
    static func check() async -> Int32 {
        guard let p = plan else {
            print("browser: none set up (no local browser.cdp_url and no \(settingsFile.path))")
            return 2
        }
        print("browser: port \(p.port), saved profile \(p.profile)")
        let c = await cookies(p.port)
        if c == nil {
            print("browser: not answering. One starts it again within about 20 seconds while it's open.")
            return 1
        }
        if let used = profileInUse(p.port), used != p.profile {
            print("browser: WARNING the browser on \(p.port) uses another profile (\(used)); its sign-ins aren't the saved ones")
        }
        var code: Int32 = 0
        for site in sessionCookies.keys.sorted() {
            let s = signIn(site: site, cookies: c) ?? "unknown"
            print("\(site): \(s)")
            if !s.hasPrefix("signed in") { code = 1 }
        }
        return code
    }

    /// Added to every prompt while a local browser is set up.
    static var note: String {
        guard let p = plan else { return "" }
        return """


            (One app note, not from the user: the hidden browser on port \(p.port) keeps their sign-ins in a saved profile. If it isn't answering, wait 20 seconds and try again: One starts it again by itself with the same profile. Never start your own Chrome on port \(p.port) or a fresh profile for a site that needs a sign-in. Check sign-ins with `\(Bridge.exe) --browser-check`.)
            """
    }
}
