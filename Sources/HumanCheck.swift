import AppKit
import Darwin
import Foundation
import SQLite3

// MARK: - A robot check ("verify you are human") in a plain Chrome window, nothing attached
//
// Why the tick looped: the hidden browser is headless Chrome, and its user agent says "HeadlessChrome".
// Cloudflare refuses that by itself (tested 2026-10-28: fresh headless profiles with that user agent stayed on
// "Just a moment…" 6 times out of 6; the same browser with a normal Chrome user agent passed 6 out of 6 with no
// click, DevTools attached or not, Runtime.enable or not). Signed in to claude.ai, Cloudflare asks for the tick
// even with a normal user agent, and a tick through One's live view lands in that headless browser as a DevTools
// click: the page refreshes and asks again, forever.
//
// So for a robot check, once the person taps Show the window (their yes to that window), One closes the hidden
// browser and opens the SAME profile as a plain Chrome window: no DevTools port, no automation flags, nothing
// attached while they click. When the check's cookie lands in the profile (or they tap Done, or quit that Chrome),
// One closes the window and starts the hidden browser again with the same profile and a normal Chrome user agent
// (`BrowserKeeper.userAgent`), so the pass holds there. The engine is told the tab was reopened.
enum HumanCheck {
    struct Session {
        let id: String
        let site: String
        let url: String
        let profile: String
        let port: Int
        let kind: String
        let started: Date
        var pid: pid_t?
    }

    nonisolated(unsafe) static var active: Session?
    /// Set by Done / I'm not at the Mac while the window is up: "done" or "away".
    nonisolated(unsafe) static var requested: String?
    static let waitLimit: TimeInterval = 600

    /// Every step only a person can do (robot check, sign-in, code, passkey, approve) gets the real window: the live
    /// view had no address bar, showed a dark page and its clicks were DevTools clicks a robot check refuses.
    static func wanted(_ a: HumanStepAsk) -> Bool { !a.kind.isEmpty }

    /// Robot checks end by themselves when the check's cookie lands; other steps end on Done or Chrome closing.
    static func watchesCookie(_ kind: String) -> Bool { kind == "check" }

    /// A plain Chrome window on the saved profile: no DevTools port, no automation flags, no headless.
    static func headedArguments(profile: String, url: String, app: String) -> [String] {
        ["-n", "-a", app, "--args", "--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check", url]
    }

    static func log(_ s: String) { BrowserKeeper.log("human check: " + s) }

    /// Their tap on Show the window. False when this browser can't be swapped (then the live view is used).
    @MainActor static func begin(_ a: HumanStepAsk, finished: @escaping @MainActor (String) -> Void) -> Bool {
        if active?.id == a.id { return true }
        guard active == nil, let p = BrowserKeeper.plan, p.port == a.port, let app = BrowserKeeper.chromeApp else { return false }
        let url = a.url.hasPrefix("http") ? a.url : "https://\(a.site)/"
        active = Session(id: a.id, site: a.site, url: url, profile: p.profile, port: p.port, kind: a.kind, started: Date(), pid: nil)
        requested = nil
        Task.detached {
            let answer = await run(app: app)
            await MainActor.run { finished(answer) }
        }
        return true
    }

    /// Done or I'm not at the Mac from the chat card while the window is up.
    static func request(_ id: String, _ answer: String) -> Bool {
        guard active?.id == id else { return false }
        requested = answer
        return true
    }

    static func run(app: String) async -> String {
        guard var s = active else { return "done" }
        defer { active = nil }
        log("\(s.site): closing the hidden browser and opening a plain Chrome window on the same profile")
        await closeHidden(port: s.port, profile: s.profile)
        if let e = BrowserKeeper.openApp(headedArguments(profile: s.profile, url: s.url, app: app)) { log("couldn't open the window: \(e)") }
        for _ in 0..<20 where s.pid == nil {
            try? await Task.sleep(for: .milliseconds(500))
            s.pid = mainChrome(profile: s.profile)
        }
        if s.pid == nil {
            log("\(s.site): the window didn't open; trying once more")
            _ = BrowserKeeper.openApp(headedArguments(profile: s.profile, url: s.url, app: app))
            for _ in 0..<20 where s.pid == nil {
                try? await Task.sleep(for: .milliseconds(500))
                s.pid = mainChrome(profile: s.profile)
            }
        }
        active = s
        let shown = s
        await MainActor.run { HumanCheckCard.show(id: shown.id, site: shown.site, url: shown.url, kind: shown.kind, pid: shown.pid) }
        var answer = "done"
        var why = s.pid == nil ? "the window didn't open" : "time limit"
        if s.pid == nil { answer = "away" }
        let cookies = s.profile + "/Default/Cookies"
        while s.pid != nil, Date().timeIntervalSince(s.started) < waitLimit {
            try? await Task.sleep(for: .seconds(2))
            let pid = s.pid
            await MainActor.run { HumanCheckCard.place(pid: pid) }
            if let r = requested {
                answer = r
                why = r == "away" ? "they're not at the Mac" : "they tapped Done"
                break
            }
            if watchesCookie(s.kind), let t = lastClearance(cookies: cookies, site: s.site), t > s.started.timeIntervalSince1970 {
                why = "the check passed (its cookie is saved)"
                break
            }
            if let pid = s.pid, kill(pid, 0) != 0 {
                why = "they closed Chrome"
                break
            }
        }
        log("\(s.site): \(why); closing the window and hiding the browser again")
        await MainActor.run { HumanCheckCard.close() }
        if let pid = s.pid ?? mainChrome(profile: s.profile) { await quit(pid) }
        // The keeper starts the hidden browser again (same profile, normal user agent) as soon as nothing holds the profile.
        active = nil
        // Their Chrome's copy must not be refreshed now: that would replace the cookie they just earned.
        if MyChrome.isCopy(BrowserKeeper.plan) { MyChrome.lastSync = Date() }
        BrowserKeeper.lastStart = nil
        BrowserKeeper.tend()
        var target = ""
        for _ in 0..<30 where target.isEmpty {
            try? await Task.sleep(for: .seconds(1))
            if BrowserKeeper.alive(s.port) { target = await openTab(port: s.port, url: s.url) ?? "" }
        }
        log("\(s.site): hidden again\(target.isEmpty ? " (the page didn't reopen)" : ", page reopened in tab \(target)")")
        HumanStep.answer(s.id, answer, extra: ["relaunched": true, "target_id": target, "url": s.url, "why": why])
        return answer
    }

    // MARK: The hidden browser and the window

    /// Closes the hidden browser politely (it saves its cookies), then makes sure nothing holds the profile.
    static func closeHidden(port: Int, profile: String) async {
        if let ws = BrowserKeeper.version(port)?["webSocketDebuggerUrl"] as? String, let u = URL(string: ws) {
            let task = URLSession.shared.webSocketTask(with: u)
            task.resume()
            try? await task.send(.string(#"{"id":1,"method":"Browser.close"}"#))
            try? await Task.sleep(for: .milliseconds(300))
            task.cancel(with: .normalClosure, reason: nil)
        }
        for i in 0..<40 {
            guard let pid = mainChrome(profile: profile) else { return }
            if i == 20 { kill(pid, SIGTERM) }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Quits the window's Chrome politely, the way ⌘Q does, so it writes its cookies first. SIGTERM (0.9.51-0.9.53)
    /// ends Chrome without saving the last ~30 seconds of cookies, so the pass from their tick was lost (proved
    /// 2026-10-28: a cookie set 1 s before SIGTERM never reached the Cookies file).
    static func quit(_ pid: pid_t) async {
        let asked = Date()
        let polite = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.terminate() ?? false }
        for _ in 0..<40 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("Chrome didn't quit politely (asked: \(polite)); waiting for it to save its cookies, then stopping it")
        // Chrome saves cookies at least every 30 seconds.
        while Date().timeIntervalSince(asked) < 32, kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(500)) }
        kill(pid, SIGTERM)
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        kill(pid, SIGKILL)
    }

    /// The main Chrome process using this profile (not its helpers), if one runs.
    static func mainChrome(profile: String) -> pid_t? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let want = "--user-data-dir=\(profile)"
        for pid in pids.prefix(Int(max(0, got))) where pid > 0 {
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            guard String(cString: buf).hasSuffix("/Contents/MacOS/Google Chrome") else { continue }
            let a = GatewayGuard.arguments(of: pid)
            if a.contains(want) && !a.contains(where: { $0.hasPrefix("--type=") }) { return pid }
        }
        return nil
    }

    static func openTab(port: Int, url: String) async -> String? {
        let q = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let u = URL(string: "http://127.0.0.1:\(port)/json/new?\(q)") else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "PUT"
        req.timeoutInterval = 5
        guard let (d, _) = try? await URLSession.shared.data(for: req),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return j["id"] as? String
    }

    /// When the robot-check cookie for this site was last set (Unix time), from the profile's cookie file.
    /// Chrome writes cookies to disk within about 30 seconds; read-only, never locks the file.
    static func lastClearance(cookies path: String, site: String) -> TimeInterval? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        let host = site.hasPrefix("www.") ? String(site.dropFirst(4)) : site
        for col in ["MAX(last_update_utc, creation_utc)", "creation_utc"] {
            var st: OpaquePointer?
            let sql = "SELECT MAX(\(col)) FROM cookies WHERE name = 'cf_clearance' AND (host_key = ?1 OR host_key = ?2 OR host_key LIKE ?3)"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                sqlite3_finalize(st)
                continue
            }
            defer { sqlite3_finalize(st) }
            let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(st, 1, host, -1, T)
            sqlite3_bind_text(st, 2, "." + host, -1, T)
            sqlite3_bind_text(st, 3, "%." + host, -1, T)
            guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
            return chromeTime(sqlite3_column_int64(st, 0))
        }
        return nil
    }

    /// Chrome stores times as microseconds since 1601.
    static func chromeTime(_ v: Int64) -> TimeInterval { Double(v) / 1_000_000 - 11_644_473_600 }
}
