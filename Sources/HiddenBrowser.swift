import AppKit
import Darwin
import Foundation

// MARK: - Hidden browsers stay hidden: never in the Dock or Stage Manager, never in front
//
// Why (Nov 5 2026, Omar: "Chrome keeps popping up in Stage Manager and taking focus"): macOS treats a headless
// Chrome as a normal app. Measured on his Mac: every start registers as a foreground app first and only then
// switches itself to background-only (6 starts out of 6 showed "Foreground" for about 70 ms), and Project
// Ledger's hidden browser (port 9333, started from inside the folder lock by its own script) sat as a normal
// foreground app for two days: a Chrome icon in the Dock and Stage Manager that could come to the front with no
// window at all, pushing their windows aside. Chrome has no flag for this, `chrome-headless-shell` can't read the
// saved sign-ins (it uses the "Chromium Safe Storage" key, not Chrome's), and a stand-in app bundle breaks
// Chrome's own signature checks. So One keeps every hidden browser in line from outside, in three layers:
// 1. Start: every hidden browser One starts goes through `launch` (the Mac's own launcher, run by One outside the
//    folder lock, told not to bring it forward), never as a child of the folder lock.
// 2. Front: the moment any headless Chrome becomes the front app, One hides it, which hands the front back.
// 3. Dock: a headless Chrome macOS has turned into a normal app is hidden at once and, if it's one of One's,
//    closed politely as soon as no helper, routine or person's step is using it; it starts again fresh, hidden.
enum HiddenBrowser {
    static let chromeID = "com.google.Chrome"
    /// Extra Chrome switches a start request may ask for (Project Ledger's browser keeps background tabs running).
    static let allowedFlags: Set<String> = [
        "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-backgrounding-occluded-windows",
    ]
    static var startDir: URL { Env.support.appendingPathComponent("browser/start", isDirectory: true) }
    static func log(_ s: String) { BrowserKeeper.log("hidden browser: " + s) }

    // MARK: 1. Start

    /// How every hidden browser is started, through the Mac's own launcher (One runs outside the folder lock, where
    /// `open` keeps the switches): a new copy (-n), never brought forward (-g). Not "start hidden" (-j, or the
    /// workspace's `hides`): the Mac then waits for a headless Chrome to say it's ready to be shown, which it never
    /// does (CI, Nov 6 2026: `open -j` never returned; the workspace call never answered in 20 s).
    static func openArguments(app: String, arguments: [String]) -> [String] { ["-g", "-n", "-a", app, "--args"] + arguments }

    /// Starts Chrome with these switches. It isn't One's child, so it keeps running if One quits. nil = started.
    static func launch(app: String, arguments: [String]) -> String? {
        if let e = BrowserKeeper.openApp(openArguments(app: app, arguments: arguments)) { return e }
        if let prof = value(arguments, "--user-data-dir") {
            for _ in 0..<20 {
                if let pid = HumanCheck.mainChrome(profile: prof) {
                    DispatchQueue.main.async { ours.insert(pid) }
                    break
                }
                usleep(250_000)
            }
        }
        return nil
    }

    // MARK: 2 + 3. Front and Dock (every second, from the main loop)

    @MainActor static var watching = false
    /// Hidden browsers this One started (their profile is One's either way; see `isOurs`).
    nonisolated(unsafe) static var ours: Set<pid_t> = []
    /// Hidden browsers macOS made into a normal app, waiting for a quiet moment to start again fresh.
    @MainActor static var stuck: [pid_t: Date] = [:]
    @MainActor static var argsCache: [pid_t: [String]] = [:]

    /// The browser's own process started headless (not one of its helper processes, not their own Chrome).
    static func isHeadless(_ args: [String]) -> Bool {
        args.contains { $0.hasPrefix("--headless") } && !args.contains { $0.hasPrefix("--type=") }
    }

    @MainActor static func args(_ pid: pid_t) -> [String] {
        if let a = argsCache[pid] { return a }
        let a = GatewayGuard.arguments(of: pid)
        argsCache[pid] = a
        return a
    }

    /// Every headless Chrome running now, whoever started it.
    @MainActor static func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: chromeID).filter { isHeadless(args($0.processIdentifier)) }
    }

    static func value(_ args: [String], _ name: String) -> String? {
        args.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    static func port(_ args: [String]) -> Int? { value(args, "--remote-debugging-port").flatMap { Int($0) } }

    static func describe(_ args: [String]) -> String { port(args).map { "on port \($0)" } ?? "(no port)" }

    /// One's own: started by this One, or on a saved profile in One's folder or a folder they let One use.
    @MainActor static func isOurs(_ pid: pid_t) -> Bool {
        if ours.contains(pid) { return true }
        guard let prof = value(args(pid), "--user-data-dir") else { return false }
        return allowed(profile: prof)
    }

    /// The first time it runs: notice the moment a hidden browser comes to the front, whatever brought it there.
    @MainActor static func watch() {
        if watching { return }
        watching = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { cameForward(pid) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
            n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let pid {
                    argsCache[pid] = nil
                    stuck[pid] = nil
                    ours.remove(pid)
                }
            }
        }
    }

    /// A hidden browser has no window to show: hiding it hands the front back to what they were using.
    @MainActor static func cameForward(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == chromeID, isHeadless(args(pid)) else { return }
        app.hide()
        log("a hidden browser \(describe(args(pid))) came to the front; hid it so the front goes back to what they were using")
    }

    /// `idle`: no helper is working and no step is waiting on the person (from the main loop, HumanStep.swift).
    @MainActor static func tend(idle: Bool) {
        if (Env.selfTest || Env.commandLine) && !testing { return }
        watch()
        serveStarts()
        for app in running() {
            let pid = app.processIdentifier
            if app.isActive { cameForward(pid) }
            guard app.activationPolicy == .regular else { continue }
            if !app.isHidden { app.hide() }
            if stuck[pid] == nil {
                stuck[pid] = Date()
                log(
                    "a hidden browser \(describe(args(pid))) shows in the Dock (macOS made it a normal app); hid it"
                        + (isOurs(pid) ? ", it starts again fresh as soon as nothing is using it" : ", not One's, left running"))
            }
        }
        // Close one politely (it saves its cookies): BrowserKeeper, or the next start request, brings it back hidden.
        guard idle, HumanCheck.active == nil, let (pid, _) = stuck.first(where: { isOurs($0.key) }) else { return }
        guard Routines.inFlight().isEmpty else { return }
        let a = args(pid)
        stuck[pid] = nil
        log("closing the hidden browser \(describe(a)) so it starts again fresh, out of the Dock")
        let port = port(a)
        Task.detached { await close(pid: pid, port: port) }
    }

    /// Browser.close over its own port, then SIGTERM if it's still there 15 seconds later.
    static func close(pid: pid_t, port: Int?) async {
        if let port, let ws = BrowserKeeper.version(port)?["webSocketDebuggerUrl"] as? String, let u = URL(string: ws) {
            let task = URLSession.shared.webSocketTask(with: u)
            task.resume()
            try? await task.send(.string(#"{"id":1,"method":"Browser.close"}"#))
            try? await Task.sleep(for: .milliseconds(300))
            task.cancel(with: .normalClosure, reason: nil)
        }
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        kill(pid, SIGTERM)
    }

    // MARK: Start requests: `One --hidden-browser <port> <profile> [page] [switches]`

    /// A saved profile One may start a hidden browser on: in One's own folder or a folder they let One use,
    /// and never their own Chrome's folder (its copy lives in One's folder: Connections › Browser).
    static func allowed(profile: String) -> Bool {
        let p = URL(fileURLWithPath: NSString(string: profile).expandingTildeInPath).standardizedFileURL.path
        let chrome = URL(fileURLWithPath: MyChrome.chromeData).standardizedFileURL.path
        if p == chrome || p.hasPrefix(chrome + "/") { return false }
        let roots = [Env.support.path] + Access.folders
        return roots.contains { r in
            let r = URL(fileURLWithPath: NSString(string: r).expandingTildeInPath).standardizedFileURL.path
            return p == r || p.hasPrefix(r + "/")
        }
    }

    /// The switches for a requested browser: always hidden, same shape as One's own (BrowserKeeper).
    static func requestArguments(port: Int, profile: String, url: String?, flags: [String], app: String) -> [String] {
        var a = BrowserKeeper.launchArguments(BrowserKeeper.Plan(port: port, profile: profile, headless: true), app: app)
        a.removeLast()  // about:blank
        a += flags.filter { allowedFlags.contains($0) }
        a.append(url.flatMap { $0.hasPrefix("https://") || $0.hasPrefix("http://") ? $0 : nil } ?? "about:blank")
        return a
    }

    /// Why a request can't be served, or nil.
    static func refusal(port: Int, profile: String) -> String? {
        if !(1024...65535).contains(port) { return "port \(port) isn't one One can use" }
        if !allowed(profile: profile) { return "that profile isn't in One's folder or a folder they let One use" }
        if let p = BrowserKeeper.plan, p.port == port { return "port \(port) is the hidden browser One keeps itself; it comes back by itself" }
        return nil
    }

    nonisolated(unsafe) static var starting = false

    /// One's side: start each waiting request (not from inside the folder lock), then leave the answer.
    @MainActor static func serveStarts() {
        if starting { return }
        let fm = FileManager.default
        guard let n = (try? fm.contentsOfDirectory(atPath: startDir.path))?.first(where: { $0.hasSuffix(".json") && !$0.hasSuffix(".out.json") })
        else { return }
        let req = startDir.appendingPathComponent(n)
        let j = (try? Data(contentsOf: req)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        try? fm.removeItem(at: req)
        let port = j["port"] as? Int ?? 0
        let profile = NSString(string: j["profile"] as? String ?? "").expandingTildeInPath
        let out = startDir.appendingPathComponent(String(n.dropLast(5)) + ".out.json")
        starting = true
        Task.detached {
            defer { starting = false }
            var why = refusal(port: port, profile: profile)
            if why == nil, !BrowserKeeper.alive(port) {
                if HumanCheck.mainChrome(profile: profile) != nil {
                    why = "that profile is already open in another Chrome"
                } else if let app = BrowserKeeper.chromeApp {
                    try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
                    let a = requestArguments(port: port, profile: profile, url: j["url"] as? String, flags: j["flags"] as? [String] ?? [], app: app)
                    why = launch(app: app, arguments: a)
                    log(why.map { "couldn't start one on port \(port): \($0)" } ?? "started one on port \(port) with the saved profile \(profile)")
                } else {
                    why = "Google Chrome isn't installed"
                }
            }
            let answer: [String: Any] = why.map { ["ok": false, "why": $0] } ?? ["ok": true]
            try? JSONSerialization.data(withJSONObject: answer).write(to: out)
        }
    }

    /// The engine's side (inside the folder lock): ask the open One, wait for the port to answer.
    static func cli(_ args: [String]) -> Int32? {
        if args.contains("--test-hidden-browser") {
            TestWorld.enter()  // a test copy only; starts Chrome only on CI (HiddenBrowserCheck.swift)
            return HiddenBrowserCheck.run()
        }
        guard let k = args.firstIndex(of: "--hidden-browser") else { return nil }
        let rest = Array(args.dropFirst(k + 1))
        guard rest.count >= 2, let port = Int(rest[0]) else {
            print("usage: One --hidden-browser <port> <saved profile folder> [page] [switches]")
            return 2
        }
        if BrowserKeeper.alive(port) {
            print("hidden browser: already answering on port \(port)")
            return 0
        }
        let url = rest.dropFirst(2).first { !$0.hasPrefix("--") }
        let flags = rest.dropFirst(2).filter { $0.hasPrefix("--") }
        let id = "\(port)-\(getpid())"
        let req: [String: Any] = ["port": port, "profile": rest[1], "url": url ?? "", "flags": flags]
        try? FileManager.default.createDirectory(at: startDir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: req).write(to: startDir.appendingPathComponent(id + ".json"))
        let out = startDir.appendingPathComponent(id + ".out.json")
        for _ in 0..<90 {
            usleep(500_000)
            if let d = try? Data(contentsOf: out), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                j["ok"] as? Bool == false
            {
                try? FileManager.default.removeItem(at: out)
                print("hidden browser: One didn't start it: \(j["why"] as? String ?? "unknown")")
                return 1
            }
            if BrowserKeeper.alive(port) {
                try? FileManager.default.removeItem(at: out)
                print("hidden browser: answering on port \(port) (hidden, never in the Dock or in front)")
                return 0
            }
        }
        try? FileManager.default.removeItem(at: startDir.appendingPathComponent(id + ".json"))
        print("hidden browser: nothing answered on port \(port) within 45 seconds (is One open?)")
        return 1
    }

    /// `--test-hidden-browser` turns the loop on inside a test copy.
    nonisolated(unsafe) static var testing = false
}
