import Foundation

// MARK: - One live phone hand-off: one tab's picture out, the phone's taps in

/// Ties the loopback server (PhoneServer), the tunnel (PhoneTunnel), that one tab's DevTools socket and the
/// phone chat message together, for one hand-off request (`handoff/<id>.request.json`). Ends on Done / Not now,
/// after `PhoneHandoff.life`, when the step is answered another way, or when the tab leaves the step's site.
final class PhoneSession: @unchecked Sendable {
    let ask: HumanStepAsk
    let title: String
    let link = PhoneHandoff.newLink()
    let stepSite: String
    private(set) var server: PhoneServer?
    private let tunnel = PhoneTunnel()
    private var cdp: URLSessionWebSocketTask?
    private var nextID = 1
    private var size = (w: 390.0, h: 844.0)
    private var phone: PhoneSocket?
    private(set) var ended: String?
    private var messageID: Int?
    var onEnd: ((String) -> Void)?
    /// Checks put a stand-in in place of the phone chat send and of the tunnel.
    nonisolated(unsafe) static var send: (String, String) -> Int? = { text, url in Messenger.sendLink(text, url: url) }
    nonisolated(unsafe) static var edit: (Int, String) -> Void = { id, text in Messenger.editLink(id, text) }
    nonisolated(unsafe) static var publicBase: ((UInt16, PhoneTunnel) -> String?)? = nil

    init(ask: HumanStepAsk, title: String) {
        self.ask = ask
        self.title = title
        stepSite = PhoneHandoff.site(URL(string: ask.url)?.host ?? ask.site)
    }

    /// Starts everything and sends the link. False = couldn't (nothing was sent).
    func start() -> Bool {
        let s = PhoneServer(room: link.room, page: PhonePage.html(title: title, ends: Date().addingTimeInterval(PhoneHandoff.life)))
        guard let port = s.start() else { return false }
        server = s
        s.onPhone = { [weak self] sock, fields in self?.phoneOpened(sock, fields) }
        s.onRefused = { [weak self] ua in
            guard let self else { return }
            PhoneHandoff.audit(self.ask.id, "refused a second phone", ["browser": String(ua.prefix(120))])
        }
        let base = Self.publicBase.map { $0(port, tunnel) } ?? PhoneHandoff.tunnelTool.flatMap { tunnel.start(port: port, tool: $0) }
        guard let base else {
            PhoneHandoff.audit(ask.id, "no way to reach the phone (no tunnel)")
            s.stop()
            return false
        }
        PhoneHandoff.audit(ask.id, "created", ["site": stepSite, "kind": ask.kind, "helper": title])
        messageID = Self.send(PhoneHandoff.message(title: title, site: ask.site, kind: ask.kind), link.url(base: base))
        guard messageID != nil else {
            PhoneHandoff.audit(ask.id, "couldn't send the link")
            stop("not sent")
            return false
        }
        PhoneHandoff.audit(ask.id, "link sent to their phone chat")
        DispatchQueue.global().asyncAfter(deadline: .now() + PhoneHandoff.life) { [weak self] in self?.stop("expired") }
        return true
    }

    private func phoneOpened(_ sock: PhoneSocket, _ fields: [String: String]) {
        phone = sock
        PhoneHandoff.audit(
            ask.id, "opened on their phone", ["browser": String((fields["user-agent"] ?? "").prefix(120)), "country": fields["cf-ipcountry"] ?? ""])
        sock.onMessage = { [weak self] d in self?.fromPhone(d) }
        sock.onClose = { [weak self] in PhoneHandoff.audit(self?.ask.id ?? "", "phone page closed") }
        attach()
    }

    // MARK: That one tab

    private func attach() {
        guard let u = URL(string: "ws://127.0.0.1:\(ask.port)/devtools/page/\(ask.target)") else { return stop("no page") }
        let t = URLSession.shared.webSocketTask(with: u)
        t.maximumMessageSize = 16 << 20
        cdp = t
        t.resume()
        receive()
        call("Page.enable", [:])
        call("Page.startScreencast", ["format": "jpeg", "quality": 60, "maxWidth": 780, "maxHeight": 1600, "everyNthFrame": 1])
    }
    private func call(_ method: String, _ params: [String: Any]) {
        let msg: [String: Any] = ["id": nextID, "method": method, "params": params]
        nextID += 1
        guard let d = try? JSONSerialization.data(withJSONObject: msg) else { return }
        cdp?.send(.string(String(decoding: d, as: UTF8.self))) { _ in }
    }
    private func receive() {
        cdp?.receive { [weak self] r in
            guard let self, self.ended == nil else { return }
            if case .success(let m) = r {
                if case .string(let s) = m { self.fromPage(Data(s.utf8)) }
                if case .data(let d) = m { self.fromPage(d) }
                self.receive()
            } else {
                self.stop("the page closed")
            }
        }
    }
    private func fromPage(_ d: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let method = j["method"] as? String,
            let p = j["params"] as? [String: Any]
        else { return }
        if method == "Page.screencastFrame", let data = p["data"] as? String, let sid = p["sessionId"] {
            call("Page.screencastFrameAck", ["sessionId": sid])
            if let meta = p["metadata"] as? [String: Any], let w = meta["deviceWidth"] as? Double, let h = meta["deviceHeight"] as? Double {
                size = (w, h)
            }
            toPhone(["t": "frame", "d": data])
        } else if method == "Page.frameNavigated", let f = p["frame"] as? [String: Any], f["parentId"] == nil,
            let s = f["url"] as? String, let u = URL(string: s)
        {
            PhoneHandoff.audit(ask.id, "page moved", ["to": u.host ?? ""])
            if !PhoneHandoff.stays(u, stepSite: stepSite) {
                toPhone(["t": "left"])
                stop("the page went to another site (\(u.host ?? "?"))")
            }
        }
    }
    private func toPhone(_ j: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: j), let sealed = PhoneHandoff.seal(d, link.key) else { return }
        phone?.send(sealed)
    }
    private func fromPhone(_ d: Data) {
        guard let plain = PhoneHandoff.open(d, link.key), let i = PhoneHandoff.allowed(plain) else {
            PhoneHandoff.audit(ask.id, "dropped something the phone isn't allowed to send", ["bytes": d.count])
            return
        }
        PhoneHandoff.audit(ask.id, PhoneHandoff.auditWords(i))
        switch i {
        case .done:
            HumanStep.answer(ask.id, "done")
            toPhone(["t": "thanks"])
            stop("done on the phone")
        case .notNow:
            HumanStep.answer(ask.id, "away")
            stop("not now")
        default:
            for (m, p) in PhoneHandoff.cdp(i, w: size.w, h: size.h) { call(m, p) }
        }
    }

    /// Everything off: the picture, both sockets, the tunnel; the phone chat message says how it ended.
    func stop(_ why: String) {
        guard ended == nil else { return }
        ended = why
        call("Page.stopScreencast", [:])
        cdp?.cancel(with: .normalClosure, reason: nil)
        server?.stop()
        tunnel.stop()
        if let id = messageID { Self.edit(id, why == "done on the phone" ? "Done. \(title) is carrying on." : "This link has ended.") }
        PhoneHandoff.audit(ask.id, "ended", ["why": why])
        onEnd?(why)
    }
}

@MainActor
extension Model {
    /// Every 2 s (from `tendEveryTwo`): a step only they can do that's waited a minute, or that came while they're
    /// away, goes to their phone once. A step answered any other way ends its phone session.
    func tendPhoneHandoffs(now: Date = Date()) {
        for (id, s) in phoneSessions where !humanSteps.contains(where: { $0.id == id }) || s.ended != nil {
            if s.ended == nil { s.stop("answered at the Mac") }
            phoneSessions[id] = nil
        }
        let idle = PhoneHandoff.idleSeconds
        // A code step away from the Mac: the ask goes to the phone chat and their reply is the code (no page, no link).
        for a in humanSteps where HumanStep.takesCode(a.kind) && !phoneSent.contains(a.id) && HumanCheck.active?.id != a.id {
            let seen = humanStepSeen[a.id] ?? now
            humanStepSeen[a.id] = seen
            if PhoneHandoff.due(waited: now.timeIntervalSince(seen), idle: idle) { askCodeByPhone(a) }
        }
        guard !Env.selfTest || PhoneSession.publicBase != nil, PhoneHandoff.ready || PhoneSession.publicBase != nil else { return }
        for a in humanSteps
        where phoneSessions[a.id] == nil && !phoneSent.contains(a.id) && !HumanStep.takesCode(a.kind)
            && HumanCheck.active?.id != a.id
        {
            let seen = humanStepSeen[a.id] ?? now
            humanStepSeen[a.id] = seen
            guard PhoneHandoff.due(waited: now.timeIntervalSince(seen), idle: idle) else { continue }
            phoneSent.insert(a.id)
            let title = helpers.first(where: { $0.state == "working" })?.title ?? "your job"
            let s = PhoneSession(ask: a, title: title)
            phoneSessions[a.id] = s
            Task.detached { if !s.start() { s.stop("not started") } }
        }
    }
}
