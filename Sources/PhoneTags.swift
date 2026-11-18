import Foundation

// MARK: - Helper lines in a phone-chat reply do what they do in One's own chat
// Nov 15 2026, 8:45 PM: in the phone chat the assistant answered "I'm sending a helper to build it now" with a
// [helper: Science explainer channel | …] line, then passed on a change with [tell-helper: …]. Nothing started: the
// tags were read only here, in One's own chat (Helpers.read), and a phone-chat reply goes from the engine's
// background helper (the gateway) straight to the phone. Omar thought the job had run all night.
// Now the engine plugin `tools/overlay/plugins/one-phone-tags` hands every phone reply with those tags to One
// (`hermes/one-phone/inbox/<id>.json`) and sends the phone the reply without them. One acts on it with the very
// code its own chat uses (`Model.actOn`): the helper starts and shows here, a tell reaches it, a stop stops it.
// When a helper sent from the phone ends, the phone gets its result (it can't tap an orb), and every phone turn
// carries One's helper news (`one-phone/news.md`) so the assistant there knows how they're doing.
// Each reply acts once: the plugin writes the same reply in a conversation once, and One remembers what it acted on.
// Checked by tools/phone-tags-check.py (the plugin) and tools/phone-tags-check.sh (`One --test-helpers-stress phone`).

/// One phone-chat reply the engine handed over.
struct PhoneReply: Codable {
    var id: String
    var platform: String
    var chat: String?
    var session: String?
    var at: Double?
    var reply: String
}

enum PhoneTags {
    static let plugin = "one-phone-tags"
    static var dir: URL { Env.hermesHome.appendingPathComponent("one-phone", isDirectory: true) }
    static var inbox: URL { dir.appendingPathComponent("inbox", isDirectory: true) }
    static var actedFile: URL { dir.appendingPathComponent("acted.json") }
    static var newsFile: URL { dir.appendingPathComponent("news.md") }
    /// The same reply again within this long (a re-run turn, a file left behind) acts once.
    static let replayWindow: TimeInterval = 24 * 3600
    /// What one phone message may hold (the chat app's own limit is about 4,000).
    static let maxResult = 3200

    /// Replies waiting, oldest first. One that can't be read comes back with nil (removed, logged).
    static func pending() -> [(URL, PhoneReply?)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .map { u in (u, (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(PhoneReply.self, from: $0) }) }
            .sorted { ($0.1?.at ?? 0) < ($1.1?.at ?? 0) }
    }

    /// Marks a reply as acted on. False when it already was (the same reply again): nothing happens twice.
    static func claim(_ id: String, now: Date = Date()) -> Bool {
        let t = now.timeIntervalSince1970
        let d = (try? Data(contentsOf: actedFile)) ?? Data()
        var seen = ((try? JSONDecoder().decode([String: Double].self, from: d)) ?? [:]).filter { t - $0.value < replayWindow }
        guard seen[id] == nil else { return false }
        seen[id] = t
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let out = try? JSONEncoder().encode(seen) { try? out.write(to: actedFile, options: .atomic) }
        return true
    }

    static func origin(_ r: PhoneReply) -> String { r.platform.lowercased() + ":" + (r.chat ?? "") }

    /// What the phone gets when a helper it sent ends: the result itself (no orb to tap there), and its choices as
    /// buttons. nil when there's nothing to say (still working, picked back up, stopped on purpose).
    static func report(_ h: Helper) -> (text: String, choices: [String])? {
        let parts = Choices.split(Helpers.strip(h.reply))
        var body = parts.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let long = body.count > maxResult
        if long { body = String(body.prefix(maxResult)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        let said = body.isEmpty ? "" : "\n\n" + body
        let more = long ? "\n\nThe whole report is under Ready for you on your Mac." : ""
        switch h.state {
        case "done":
            return ("\(h.title) is done." + said + more, [])
        case "needsYes":
            return ("\(h.title) needs your yes." + said + more + "\n\nAnswer here and I'll pass it on.", parts.choices)
        case "stopped" where h.resumeQueued != true && h.stoppedByYou != true && h.updatePaused != true:
            return ("\(h.title) stopped before it finished (\(h.line))." + said, [])
        default:
            return nil
        }
    }

    /// A short mark of what was sent, so the same result never goes twice.
    static func mark(_ h: Helper, _ text: String) -> String {
        var x: UInt64 = 5381
        for b in text.utf8 { x = (x &* 33) &+ UInt64(b) }
        return h.state + ":" + String(x, radix: 36)
    }

    /// The note every phone-chat turn carries (the plugin adds it): how the helpers are doing.
    static func news(_ hs: [Helper], line: (Helper) -> String) -> String {
        let shown = hs.filter { $0.stopping != true }.suffix(12)
        guard !shown.isEmpty else { return "" }
        var lines = ["Helpers right now (One keeps this up to date):"]
        for h in shown {
            let from = h.phone == nil ? "" : ", sent from this chat"
            switch h.state {
            case "working":
                lines.append("- \(h.title)\(from): still working (\(line(h))).")
            case "needsYes":
                let ask = Helpers.summary(Choices.split(Helpers.strip(h.reply)).body, 160)
                lines.append(
                    "- \(h.title)\(from): waiting for their yes (\"\(ask)\"). When they answer, pass it on with [tell-helper: \(h.title) | their answer]."
                )
            case "stopped":
                lines.append("- \(h.title)\(from): \(h.resumeQueued == true ? "cut off, One picks it back up by itself" : "stopped (\(h.line))").")
            default:
                let sent = h.phone != nil && h.phoneTold != nil ? " Its result was already sent to this chat; don't repeat it." : ""
                lines.append("- \(h.title)\(from): done (\"\(Helpers.summary(Choices.split(Helpers.strip(h.reply)).body, 160))\").\(sent)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func log(_ s: String) { Helpers.appendLog("\(ISO8601DateFormatter().string(from: Date())) phone chat: \(s)\n") }
}

@MainActor
extension Model {
    /// Every 2 s (tendEveryTwo): act on phone-chat replies the engine handed over, and keep the phone's news fresh.
    func tendPhoneTags() {
        guard isReady, !paused else { return }  // helpers are back and the chat is open; Stop holds these too
        for (url, r) in PhoneTags.pending() {
            try? FileManager.default.removeItem(at: url)
            guard let r else {
                PhoneTags.log("couldn't read \(url.lastPathComponent); dropped")
                continue
            }
            guard PhoneTags.claim(r.id) else {
                PhoneTags.log("\(r.id) again: already acted on, nothing done twice")
                continue
            }
            let tags = Helpers.read(r.reply)
            let from = PhoneTags.origin(r)
            let misses = actOn(tags, typed: "", phone: from)
            PhoneTags.log(
                "\(r.id) from \(r.platform): \(tags.jobs.count) helper(s), \(tags.tells.count) tell(s), \(tags.stops.count) stop(s), \(tags.closes.count) clear(s)"
            )
            if !misses.isEmpty { sendPhone(misses.joined(separator: "\n\n"), to: from) }
        }
        writePhoneNews()
    }

    /// A helper sent from a phone chat ended its turn: the phone gets its result (or its question), once per result.
    func phoneDone(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), let from = h.phone, let r = PhoneTags.report(h) else { return }
        let mark = PhoneTags.mark(h, r.text)
        guard h.phoneTold != mark else { return }
        update(id) { $0.phoneTold = mark }
        sendPhone(r.text, to: from, choices: r.choices)
        writePhoneNews()
    }

    func sendPhone(_ text: String, to origin: String, choices: [String] = []) {
        Task.detached { if !Messenger.send(text, to: origin, choices: choices) { PhoneTags.log("couldn't message \(origin)") } }
    }

    func writePhoneNews() {
        // The review's open question first (the plugin keeps only the first 3000 characters), then the helpers.
        let text = [
            ImproveAsk.phoneNote.trimmingCharacters(in: .whitespacesAndNewlines), PhoneTags.news(helpers) { self.progressLine($0, now: Date()) },
        ]
        .filter { !$0.isEmpty }.joined(separator: "\n")
        let old = (try? String(contentsOf: PhoneTags.newsFile, encoding: .utf8)) ?? ""
        // Rewritten when it changed, and at least every hour so the plugin knows One is still here.
        let age = (try? PhoneTags.newsFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map {
            Date().timeIntervalSince($0)
        }
        guard text != old || (age ?? .infinity) > 3600 else { return }
        try? FileManager.default.createDirectory(at: PhoneTags.dir, withIntermediateDirectories: true)
        try? text.write(to: PhoneTags.newsFile, atomically: true, encoding: .utf8)
    }
}
