import AppKit

// MARK: - Pages left open in One's hidden browsers go back to a blank tab once nothing uses them

/// A page a helper left open keeps running in the hidden browser for as long as One is open: on Omar's Mac on Nov 19
/// 2026 a video page left in One's hidden browser kept it near 20% CPU with nothing at work. Once nothing has been at
/// work for `after` and a browser's open pages haven't changed in all that time, they're closed and one blank tab
/// stays. Sign-ins and cookies stay (the profile isn't touched). Looks once a minute, only while idle.
enum HiddenTabs {
    static let after: TimeInterval = 10 * 60
    static let every: TimeInterval = 60
    @MainActor static var seen: [Int: (pages: [String], since: Date)] = [:]
    @MainActor static var lastLook = Date.distantPast
    @MainActor static var looking = false

    /// From HiddenBrowser.tend: `ports` = One's own hidden browsers, `idle` = nothing at work and no step waiting.
    @MainActor static func tend(idle: Bool, ports: [Int], now: Date = Date()) {
        guard idle, KeepAwake.routinesRunning == 0, !ports.isEmpty else {
            seen = [:]  // something works: its pages are in use, start counting again once it's over
            return
        }
        guard !looking, now.timeIntervalSince(lastLook) >= every else { return }
        lastLook = now
        looking = true
        Task { @MainActor in
            for port in ports { await look(port: port, now: now) }
            looking = false
        }
    }

    /// What to do with a browser's pages: nil = leave them, otherwise the pages to close (and whether to open a blank one).
    static func decide(pages: [BlockedAsk.Page], before: (pages: [String], since: Date)?, now: Date) -> (close: [String], blank: Bool)? {
        let busy = pages.filter { !blank($0.url) }
        guard !busy.isEmpty, let before, before.pages == signature(pages), now.timeIntervalSince(before.since) >= after else { return nil }
        return (busy.map(\.target), !pages.contains { blank($0.url) })
    }

    static func blank(_ url: String) -> Bool { url.isEmpty || url == "about:blank" || url.hasPrefix("chrome://newtab") }
    static func signature(_ pages: [BlockedAsk.Page]) -> [String] { pages.map { "\($0.target) \($0.url)" }.sorted() }

    @MainActor static func look(port: Int, now: Date) async {
        let pages = await BlockedAsk.pages(port: port)
        guard !pages.isEmpty else {
            seen[port] = nil
            return
        }
        guard let act = decide(pages: pages, before: seen[port], now: now) else {
            if seen[port]?.pages != signature(pages) { seen[port] = (signature(pages), now) }
            return
        }
        if act.blank { _ = await call(port, "/json/new?about:blank", method: "PUT") }
        for id in act.close { _ = await call(port, "/json/close/\(id)") }
        seen[port] = nil
        HiddenBrowser.log("closed \(act.close.count) page(s) left open on port \(port) after \(Int(after / 60)) min with nothing at work")
    }

    static func call(_ port: Int, _ path: String, method: String = "GET") async -> Bool {
        guard let u = URL(string: "http://127.0.0.1:\(port)\(path)") else { return false }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: r)) != nil
    }
}
