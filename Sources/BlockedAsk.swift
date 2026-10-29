import AppKit

// MARK: - Blocked on something only they can do: stop, ask, show the window on a yes, carry on as asked
//
// Rule (Omar): when a helper or the assistant hits a step only the person can do (a Cloudflare or
// "verify you are human" check, a sign-in, a 2FA code, a passkey, a button), it stops at once, shows as
// "needs your yes" and asks in plain words: what's blocked, the one thing they must do, and "Can I show you
// the window?". After the yes One shows that one window (the live view of the hidden browser's tab,
// `StepWindow`, never a visible browser), then the job carries on exactly as asked: never skipped, never
// swapped for another method (a helper once drew pictures by hand when Claude Design showed a Cloudflare check).
//
// Three layers: SOUL (`Persona.soul`), the note on every prompt (`Helpers.note` for the main assistant,
// `Helpers.forHelper` for every helper turn, resumed and follow-up ones included), and One itself: it watches
// the hidden browser's tabs (`/json/list`) and, when a robot check stays up, asks on its own and turns the helper
// that was browsing orange, so it never depends on the model remembering.

enum BlockedAsk {
    static let question = "Can I show you the window?"
    static let choices = "[choices: Yes, show it | Not now]"
    static let marker = "BLOCKED = ASK."

    /// The SOUL paragraph; the per-prompt note carries the same words.
    static let soul = """
        Blocked on something only they can do (a Cloudflare or "verify you are human" check, a robot check, a sign-in, a 2FA code, a passkey, a button only they can press): stop right away. For a plain sign-in wall, call the browser tool's find_session action FIRST (another of One's hidden browsers may already be signed in there); only ask the person if none of them are. Never skip that part, never work around it, and never swap in another way of doing the job (like drawing pictures by hand when a design tool is blocked, or using a different site or app). Ask in plain words: what's blocked, the one thing they must do, and "\(question)", ending with \(choices). If you're a helper, that ask turns your orb orange (needs your yes). The window only opens when YOU call it: the moment they answer, call the browser tool's hand_off action yourself (pick the kind that fits: code, security_key, passkey, approve, check, or sign_in for a plain log-in wall with no code or captcha) — One cannot show any window until that call writes the request, so never assume asking in chat alone opens it. That same call waits for them and tells you once they're done; carry on with the job exactly as they asked from its answer. If they say not now, stop there and say the job is waiting on that one step. A routine can't ask anyone: it stops at that step and says so in its report.
        """
    static var note: String { "\n\n(One app note, not from the user: \(marker) " + soul + ")" }

    // MARK: Spotting a robot check in the hidden browser

    struct Page: Equatable {
        let target: String
        let url: String
        let title: String
    }

    /// A Cloudflare / "verify you are human" page, from its title or address alone (no page script runs).
    static func isChallenge(title: String, url: String) -> Bool {
        let t = title.lowercased()
        let u = url.lowercased()
        if ["challenges.cloudflare.com", "/cdn-cgi/challenge-platform", "__cf_chl", "/captcha", "validatecaptcha"].contains(where: { u.contains($0) })
        {
            return true
        }
        let titles = [
            "just a moment", "attention required! | cloudflare", "verify you are human", "are you a robot", "checking your browser",
            "human verification", "i'm not a robot", "security check", "one more step",
        ]
        return titles.contains { t.contains($0) }
    }

    /// The hidden browser's open tabs. Empty when it isn't answering.
    static func pages(port: Int) async -> [Page] {
        guard let u = URL(string: "http://127.0.0.1:\(port)/json/list") else { return [] }
        var r = URLRequest(url: u)
        r.timeoutInterval = 1.5
        guard let (d, _) = try? await URLSession.shared.data(for: r), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]
        else { return [] }
        return a.compactMap { j in
            guard j["type"] as? String == "page", let id = j["id"] as? String else { return nil }
            return Page(target: id, url: j["url"] as? String ?? "", title: j["title"] as? String ?? "")
        }
    }

    /// A step that looks like it drives the hidden browser (who was browsing when the check came up).
    static func browserish(_ step: String) -> Bool {
        let s = step.lowercased()
        return ["browser", "9223", "cdp", "new_tab", "goto_url", "playwright", "chrome", "claude.ai"].contains { s.contains($0) }
    }

    /// Who ran into it: the working helper that browsed last (within 10 minutes), or the only one working;
    /// nil = the main assistant (or nobody known), and the line goes in the main chat only.
    static func owner(working: [UUID], lastBrowser: [String: Date], now: Date = Date()) -> UUID? {
        let recent = working.compactMap { id in lastBrowser[id.uuidString].map { (id, $0) } }.filter { now.timeIntervalSince($0.1) < 600 }
        if let best = recent.max(by: { $0.1 < $1.1 }) {
            if let main = lastBrowser["main"], main > best.1 { return nil }
            return best.0
        }
        let mainBrowsing = lastBrowser["main"].map { now.timeIntervalSince($0) < 600 } ?? false
        return working.count == 1 && !mainBrowsing ? working.first : nil
    }

    static func site(_ url: String) -> String {
        guard let h = URL(string: url)?.host else { return "a site" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The plain ask, word for word.
    static func line(site: String, helper: String?) -> String {
        let who = helper.map { "\"\($0)\" is stuck" } ?? "I'm stuck"
        return
            "\(who): \(site) is showing a \"verify you are human\" check that only you can do. You tick it in the window, then I carry on with the job exactly as asked. \(question)"
    }

    /// What One writes into `<support>/handoff/` (the same files `HumanStep` shows: card, then the window on a yes).
    static func request(id: String, page: Page, port: Int, line: String, helper: UUID?, now: Date = Date()) -> [String: Any] {
        var j: [String: Any] = [
            "id": id, "site": site(page.url), "kind": "check", "line": line, "port": port, "target_id": page.target, "url": page.url,
            "created": now.timeIntervalSince1970, "ask": true, "by": "one",
        ]
        if let h = helper { j["helper"] = h.uuidString }
        return j
    }

    static func write(_ j: [String: Any]) -> Bool {
        guard let id = j["id"] as? String, let d = try? JSONSerialization.data(withJSONObject: j) else { return false }
        try? FileManager.default.createDirectory(at: HumanStep.dir, withIntermediateDirectories: true)
        return (try? d.write(to: HumanStep.dir.appendingPathComponent("\(id).request.json"), options: .atomic)) != nil
    }

    /// The helper's reply when the turn ends while One's ask is still open: the ask is always there, with its buttons.
    static func enforce(_ reply: String, line: String) -> String {
        if reply.contains("Yes, show it") { return reply }
        let body = Choices.split(reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
        return (body.isEmpty ? "" : body + "\n\n") + line + "\n" + choices
    }

    /// Their answer to the ask, from the helper's chat or the main chat.
    static func isYes(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("yes") || t == "show it" || t == "ok" || t == "sure"
    }

    static let stopNote =
        "\n\n(One app note, not from the user: \(marker) The hidden browser tab you were using is showing a \"verify you are human\" check. Stop now: don't retry, don't work around it, don't switch to another method. One has already asked them \"\(question)\" and turned your orb orange. Reply with one short plain line saying what's blocked and that you'll carry on after they tick it, ending with \(choices).)"
    static let shownNote =
        "\n\n(One app note, not from the user: they said yes and One is showing them the window of that tab. Wait for them: check the tab's title every 10 seconds, for up to 8 minutes, until it's past the check, then carry on with the job exactly as asked, from where you stopped. Never swap in another method.)"
    static let doneNote =
        "(One app note, not from the user: they did the check in the window. Carry on with the job exactly as asked, from where you stopped. Never swap in another method.)"

    static let settle: TimeInterval = 8  // Cloudflare often clears itself in a few seconds: only a check that stays up is asked about

    @MainActor static var lastBrowser: [String: Date] = [:]  // "main" or a helper id → its last browser step
    @MainActor static var firstSeen: [String: Date] = [:]  // tab → when the check was first seen
    @MainActor static var asked: [String: Date] = [:]  // tab → when One asked
    @MainActor static var helperFor: [String: UUID] = [:]  // request id → the helper it's for
    @MainActor static var busy = false

    @MainActor static func saw(_ step: String, by who: String) { if browserish(step) { lastBrowser[who] = Date() } }

    static func log(_ s: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-blocked.log")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
extension Model {
    /// Every few seconds: a robot check that stays up in the hidden browser gets One's own ask, and the helper
    /// that was browsing turns orange and is told to stop. Never opens or shows a window by itself.
    func tendBlocked(port: Int? = nil, settle: TimeInterval = BlockedAsk.settle) async {
        guard !BlockedAsk.busy, let port = port ?? BrowserKeeper.plan?.port else { return }
        BlockedAsk.busy = true
        defer { BlockedAsk.busy = false }
        let hits = await BlockedAsk.pages(port: port).filter { BlockedAsk.isChallenge(title: $0.title, url: $0.url) }
        let now = Date()
        BlockedAsk.firstSeen = BlockedAsk.firstSeen.filter { k, _ in hits.contains { $0.target == k } }
        for p in hits {
            let first = BlockedAsk.firstSeen[p.target] ?? now
            BlockedAsk.firstSeen[p.target] = first
            guard now.timeIntervalSince(first) >= settle else { continue }
            if let a = BlockedAsk.asked[p.target], now.timeIntervalSince(a) < 600 { continue }
            if HumanStep.pending().contains(where: { $0.target == p.target }) { continue }  // the engine already asked for it
            BlockedAsk.asked[p.target] = now
            askBlocked(p, port: port)
        }
    }

    func askBlocked(_ p: BlockedAsk.Page, port: Int) {
        let who = BlockedAsk.owner(working: helpers.filter { $0.state == "working" }.map(\.id), lastBrowser: BlockedAsk.lastBrowser)
        let h = who.flatMap { id in helpers.first { $0.id == id } }
        let line = BlockedAsk.line(site: BlockedAsk.site(p.url), helper: h?.title)
        let id = "blocked-" + UUID().uuidString.prefix(8).lowercased()
        guard BlockedAsk.write(BlockedAsk.request(id: id, page: p, port: port, line: line, helper: who)) else { return }
        BlockedAsk.log("asked: \(BlockedAsk.site(p.url)) \"\(p.title)\" for \(h?.title ?? "the main chat")")
        if let h {
            BlockedAsk.helperFor[id] = h.id
            update(h.id) {
                $0.state = "needsYes"
                $0.line = "Needs your yes"
                $0.seen = false
            }
            saveHelpers()
            if let sid = h.sid { Task { _ = await Engine.shared.steer(Helpers.forHelper(BlockedAsk.stopNote), session: sid) } }
            if !NSApp.isActive { Floater.shared.note("\(h.title) needs your yes.") }
        } else if thinking {
            Task { _ = await Engine.shared.steer(BlockedAsk.stopNote) }
        }
    }

    /// The open ask for this helper, if One's own ask is still waiting.
    func blockedAsk(for helper: UUID) -> HumanStepAsk? {
        humanSteps.first { BlockedAsk.helperFor[$0.id] == helper }
    }

    /// "Yes, show it" in the helper's chat (or the main chat): One shows that one window and tells the job to wait for them.
    func blockedYes(_ text: String, helper: UUID?) -> String {
        guard BlockedAsk.isYes(text) else { return "" }
        let a = helper.flatMap { blockedAsk(for: $0) } ?? (helper == nil ? humanSteps.first { $0.ask && BlockedAsk.helperFor[$0.id] == nil } : nil)
        guard let a else { return "" }
        showHumanStep(a)
        BlockedAsk.log("their yes: showed the window for \(a.site)")
        return BlockedAsk.shownNote
    }

    /// Done in the window or on the card: the helper carries on with the job as asked.
    func blockedAnswered(_ id: String, _ answer: String) {
        guard let hid = BlockedAsk.helperFor.removeValue(forKey: id) else { return }
        BlockedAsk.log("answer \(answer) for \(id)")
        guard answer == "done", let h = helpers.first(where: { $0.id == hid }), let sid = h.sid else { return }
        if h.state == "working" {
            Task { _ = await Engine.shared.steer(Helpers.forHelper(BlockedAsk.doneNote), session: sid) }
        } else {
            Task { await self.runHelper(hid, BlockedAsk.doneNote, images: []) }
        }
    }
}
