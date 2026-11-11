import AppKit
import Foundation

// MARK: - The account limit is the only real ceiling (Omar, Nov 10 2026)

/// When the AI account a helper runs on hits its 5-hour or weekly limit, the helper pauses and asks, on its orb and
/// on their phone if they're away: "<job> hit the limit on <account>. Switch to <other account>, or wait for the
/// reset at <time>?". One never switches by itself (work accounts may sit next to his own; the engine's own
/// switching is off: `only_chosen` in the one-stop plugin). No answer = it waits for the reset and carries on by
/// itself. The answer is kept for that one job only: next time it does the same without asking.
enum Limit {
    /// Words that name an account limit. They count only inside the engine's own failure notice (or an error stop),
    /// never in a helper's prose: Nov 10, a LinkedIn post link (…activity:75260294150264299…) held "429", and a
    /// helper explaining the pause said "usage limit", so a finished job was paused at a false limit 6 times, every 30 minutes.
    static let words = [
        "rate limit", "rate_limit", "rate-limit", "usage limit", "limit reached", "reached your limit", "hit your limit",
        "weekly limit", "5-hour limit", "daily limit", "out of extra usage", "quota", "too many requests",
    ]
    /// How the engine's failure notice starts or reads (agent/turn_failure_copy.py, conversation_loop.py), and the
    /// provider's own words when it comes through as text ("API Error: …").
    static let notices = [
        "provider said:", "rate-limited every one of", "is rate-limiting requests right now", "billing or credits exhausted",
        "provider reported usage/credit exhaustion", "api error", "limit resets at", "usage limit resets in",
    ]
    /// In SOUL (Brain.swift), for the main assistant on every channel.
    static let soul = """
        Budgets: a helper has a share of the week only when they name one; then put it in its job as "up to 10% of the week". \
        Otherwise, and for every Goal: helper or "don't stop until it's done", write no budget: it never pauses to ask for more. \
        When a helper's AI account hits its limit, One asks them "Switch to <other account>, or wait for the reset?". If they \
        answer in a phone chat ("switch", "wait", "switch Quebec trip"), run `One --limit-answer switch <job title>` or \
        `One --limit-answer wait <job title>` and tell them in one line; "keep going" (the limit wasn't real) is \
        `One --limit-answer keep <job title>`. Never switch accounts any other way.
        """
    /// Paused by One, not stopped by them: the turn that ends now is never picked back up as a cut-off.
    static func pausedOnPurpose(_ h: Helper) -> Bool { h.stoppedByYou != true && (h.pausedForBudget == true || h.pausedForLimit == true) }

    /// "429" as a code on its own, never inside a longer number (a post id, a phone number).
    static func has429(_ t: String) -> Bool { t.range(of: #"(?<![0-9])429(?![0-9])"#, options: .regularExpression) != nil }
    static func names(_ t: String) -> Bool { words.contains { t.contains($0) } || has429(t) }
    /// The engine's failure notice at the end of a turn: the last paragraphs, from the first one that reads like it.
    static func notice(_ reply: String) -> String? {
        let paras = reply.lowercased().components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tail = Array(paras.suffix(3))
        guard let k = tail.firstIndex(where: { p in notices.contains { p.contains($0) } }) else { return nil }
        return tail[k...].joined(separator: "\n\n")
    }
    /// A real provider limit: an error stop naming one, or the engine's failure notice naming one. Nothing else.
    static func hit(stop: String, reply: String) -> Bool {
        let s = stop.lowercased()
        if s.hasPrefix("error"), names(s) { return true }
        return notice(reply).map(names) ?? false
    }
    /// When the limit lifts, from the provider's own words: "resets in ~9h", "resets in ~45 min", "(in 2h 03m)",
    /// "Limit resets at 15:56", "resets 3pm". Nil = no real reset time, so it isn't treated as a limit.
    static func reset(in text: String, now: Date = Date()) -> Date? {
        let t = text.lowercased()
        func first(_ p: String) -> [String]? {
            guard let rx = try? NSRegularExpression(pattern: p), let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else {
                return nil
            }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: t).map { String(t[$0]) } ?? "" }
        }
        if let g = first(#"resets? in ~?(\d+)\s*h(?:ours?|rs?)?(?:\s*(\d+)\s*m)?"#) ?? first(#"\(in (\d+)h(?:\s*(\d+)m)?\)"#),
            let h = Double(g[1])
        {
            return now.addingTimeInterval(h * 3600 + (Double(g[2]) ?? 0) * 60)
        }
        if let g = first(#"resets? in ~?(\d+)\s*m(?:in(?:ute)?s?)?\b"#) ?? first(#"\(in (\d+)m\)"#), let mins = Double(g[1]) {
            return now.addingTimeInterval(mins * 60)
        }
        // A clock time: needs "hh:mm" or am/pm, so "resets 3 times" is not a time.
        guard let g = first(#"resets?(?: at)? (\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#), var hour = Int(g[1]), !(g[2].isEmpty && g[3].isEmpty)
        else { return nil }
        if g[3] == "pm", hour < 12 { hour += 12 }
        if g[3] == "am", hour == 12 { hour = 0 }
        guard hour < 24, let day = Calendar.current.date(bySettingHour: hour, minute: Int(g[2]) ?? 0, second: 0, of: now) else { return nil }
        return day > now ? day : Calendar.current.date(byAdding: .day, value: 1, to: day)
    }
    /// The plan's meter, last read (every 5 minutes while helpers work): a limit notice that names no time gets the
    /// full window's reset from here.
    @MainActor static var lastMeter: (at: Date, meter: Usage.Meter)?
    /// The reset of the last full reading already logged (Budget.swift `meterRead`): one log line per full window.
    @MainActor static var meterFullLogged: Date?
    @MainActor static func meterReset(now: Date = Date()) -> Date? {
        guard let l = lastMeter, now.timeIntervalSince(l.at) <= 900 else { return nil }
        return full(l.meter)
    }
    /// A window at 100% with its reset time: the account can't answer until then. No reset time = not a limit.
    static func full(_ m: Usage.Meter?) -> Date? {
        guard let m else { return nil }
        if let s = m.session, s >= 100, let r = m.sessionReset { return r }
        if m.week >= 100, let r = m.reset { return r }
        return nil
    }
    static func time(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }
    static func question(job: String, account: String, other: String?, reset: Date) -> String {
        let wait = "wait for the reset at \(time(reset))"
        return other.map { "\(job) hit the limit on \(account). Switch to \($0), or \(wait)?" }
            ?? "\(job) hit the limit on \(account). It will \(wait) and carry on by itself."
    }
    static func line(account: String, reset: Date) -> String { "Hit the limit on \(account) · carries on at \(time(reset))" }
    /// Clears a limit pause from a helper (Stop, their reply, a pause that was never a real limit).
    static func clear(_ h: inout Helper) {
        h.pausedForLimit = nil
        h.limitReset = nil
        h.limitAt = nil
        h.switchTo = nil
        h.switchEntry = nil
    }
    /// What they can text back from the phone chat (the assistant there runs `One --limit-answer`).
    static func phoneHint(_ other: String?) -> String {
        other == nil
            ? "Nothing to do: it carries on by itself (reply \"keep going\" if it wasn't a real limit)."
            : "Reply \"switch\", \"wait\" or \"keep going\" here, or do nothing and it waits."
    }

    /// `One --limit-answer switch|wait|keep [<job>]`: their answer from a phone chat, picked up by the app within seconds.
    static var answers: URL { Env.support.appendingPathComponent("helpers/limit-answers", isDirectory: true) }
    static func cli(_ args: [String]) -> Int32? {
        guard let i = args.firstIndex(of: "--limit-answer") else { return nil }
        let rest = Array(args.dropFirst(i + 1))
        guard let pick = rest.first?.lowercased(), ["switch", "wait", "keep"].contains(pick) else {
            print("usage: One --limit-answer switch|wait|keep [<job name>]")
            return 2
        }
        try? FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        let j: [String: Any] = ["pick": pick, "job": rest.dropFirst().joined(separator: " "), "at": Date().timeIntervalSince1970]
        guard let d = try? JSONSerialization.data(withJSONObject: j),
            (try? d.write(to: answers.appendingPathComponent(UUID().uuidString + ".json"))) != nil
        else { return 1 }
        let said =
            ["switch": "switching it to your other account", "keep": "it carries on now"][pick] ?? "it waits for the reset and carries on by itself"
        print("Got it: \(said).")
        return 0
    }
    /// Seams for checks (no engine, no accounts, no phone in a check).
    @MainActor static var account: (Provider) async -> String = { p in await Accounts.list(p).first(where: \.isActive)?.label ?? p.title }
    @MainActor static var tellPhone: (String) -> Void = { t in
        Task.detached { _ = Messenger.envValue(Messenger.tokenKey) == nil ? nil : Messenger.tell(t) }
    }
    @MainActor static var away: () -> Bool = { !NSApp.isActive || PhoneHandoff.idleSeconds >= PhoneHandoff.awayAfter }
}

@MainActor
extension Model {
    /// The account hit its limit under this helper: pause (never "stopped by you"), then ask, or do what they
    /// answered for this job last time. Only with a real reset time: without one it isn't a limit.
    func pauseForLimit(_ id: UUID, reset: Date) {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit != true, h.stoppedByYou != true else { return }
        if let sid = h.sid {
            StopMark.mark(sid, title: h.title, why: "its AI account hit its limit")
            if h.state == "working" { Engine.shared.cancel(session: sid) }
        }
        update(id) {
            $0.state = "stopped"
            $0.pausedForLimit = true
            $0.limitReset = reset
            $0.limitAt = Date()
            $0.resumeQueued = false
            $0.stoppedByYou = nil
            $0.seen = $0.limitChoice == nil ? false : $0.seen
            $0.line = Limit.line(account: "your account", reset: reset)
            HelperTrail.add("Paused: its AI account hit its limit", to: &$0)
        }
        saveTrail(id)
        JobTree.log("\(id.uuidString.prefix(8)): paused at the account's limit (resets \(ISO8601DateFormatter().string(from: reset)))")
        let p = provider ?? .claude
        Task { @MainActor in
            let acct = await Limit.account(p)
            let other = await Budget.otherAccount(p)
            guard helpers.first(where: { $0.id == id })?.pausedForLimit == true else { return }  // stopped meanwhile
            update(id) {
                $0.limitAccount = acct
                $0.switchTo = other?.label
                $0.switchEntry = other?.entry
                $0.line = Limit.line(account: acct, reset: reset)
            }
            guard let now = helpers.first(where: { $0.id == id }) else { return }
            if now.limitChoice == "switch", other != nil { return await answerLimit(id, switchAccount: true) }
            if now.limitChoice == "wait" { return }  // their answer for this job: wait quietly
            if Limit.away() {
                Limit.tellPhone(
                    Limit.question(job: now.title, account: acct, other: other?.label, reset: reset) + " " + Limit.phoneHint(other?.label))
            }
        }
    }

    /// A helper's turn ended while One had paused it (its budget, the account's limit), or because the account hit
    /// its limit: never a cut-off to pick back up (the restart prompt then met the pause and said "I've stopped, as
    /// you asked", Nov 10), never "stopped by you", and never left showing "working". Returns true if handled.
    func pausedTurnEnded(_ id: UUID, stop: String) -> Bool {
        guard let h = helpers.first(where: { $0.id == id }) else { return false }
        if Limit.pausedOnPurpose(h) {
            update(id) {
                guard $0.state == "working" else { return }  // its turn is over: paused, not at work
                $0.state = "stopped"
                if let r = $0.limitReset, $0.pausedForLimit == true { $0.line = Limit.line(account: $0.limitAccount ?? "your account", reset: r) }
                if $0.pausedForBudget == true, let b = Budget.of($0) { $0.line = Budget.pausedLine(b) }
            }
            saveTrail(id)
        } else if Limit.hit(stop: stop, reply: h.reply) {
            // A real limit names when it lifts (or the plan's meter does). Without a time it isn't a limit: the
            // turn failed and says so, and nothing waits for a reset that never comes.
            guard let reset = Limit.reset(in: stop + "\n\n" + (Limit.notice(h.reply) ?? "")) ?? Limit.meterReset() else {
                update(id) { HelperTrail.notFinished(&$0, .failed("its AI account turned it away for a moment")) }
                saveTrail(id)
                JobTree.log("\(id.uuidString.prefix(8)): a limit notice with no reset time: failed, not paused")
                resumeInterrupted()
                return true
            }
            pauseForLimit(id, reset: reset)
        } else {
            return false
        }
        resumeInterrupted()
        return true
    }

    /// They wrote to a helper paused at the account's limit: that's the go-ahead, like a budget pause. If the limit
    /// is still real, the engine says so again and it pauses again with the reset time.
    func carryOnAfterLimitWrittenTo(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit == true else { return }
        if let sid = h.sid { StopMark.lift(sid) }
        update(id) {
            Limit.clear(&$0)
            HelperTrail.add("Carrying on: you wrote to it", to: &$0)
        }
        saveTrail(id)
    }

    /// Their answer (orb, or the phone chat): switch to the other account now, or wait for the reset.
    func answerLimit(_ id: UUID, switchAccount: Bool) async {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit == true, h.stoppedByYou != true else { return }
        update(id) { $0.limitChoice = switchAccount ? "switch" : "wait" }
        guard switchAccount else {
            update(id) {
                $0.seen = true
                HelperTrail.add("You said wait: it carries on at \($0.limitReset.map { Limit.time($0) } ?? "the reset")", to: &$0)
            }
            return saveTrail(id)
        }
        guard let e = h.switchEntry, await Budget.makeDefault(provider ?? .claude, e) else { return }
        await carryOnAfterLimit(id, why: "they switched it to their \(h.switchTo ?? "other") account")
    }

    /// Every ~30 s: answers from the phone, and paused helpers whose limit has reset carry on by themselves. A pause
    /// with no reset time (made by 0.9.109 and earlier) was never a real limit: it's dropped, nothing is sent.
    func tendLimits(now: Date = Date()) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Limit.answers, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            defer { try? fm.removeItem(at: f) }
            guard let j = (try? Data(contentsOf: f)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            let job = (j["job"] as? String ?? "").lowercased()
            let paused = helpers.filter { $0.pausedForLimit == true }
            let pick = paused.first { !job.isEmpty && $0.title.lowercased().contains(job) } ?? (paused.count == 1 ? paused.first : nil)
            guard let id = pick?.id else { continue }
            if j["pick"] as? String == "keep" {
                Task { await keepGoingAfterLimit(id) }
            } else {
                Task { await answerLimit(id, switchAccount: j["pick"] as? String == "switch") }
            }
        }
        for h in helpers where h.pausedForLimit == true {
            guard h.stoppedByYou != true, let r = h.limitReset else {
                dropFalseLimit(h.id)
                continue
            }
            if now >= r.addingTimeInterval(60) {
                Task { await carryOnAfterLimit(h.id, why: "the limit on \(h.limitAccount ?? "your account") reset") }
            }
        }
    }

    /// A limit pause that was never real (no reset time) or that Stop already ended: cleared, never resent.
    func dropFalseLimit(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit == true else { return }
        if let sid = h.sid, h.stoppedByYou != true { StopMark.lift(sid) }
        update(id) {
            Limit.clear(&$0)
            if $0.state == "working" { $0.state = "stopped" }
            if $0.stoppedByYou != true, !$0.reply.isEmpty {
                $0.state = "done"
                $0.line = "Done · " + Helpers.summary(Choices.split($0.reply).body, 30)
            }
            HelperTrail.add("Not a real limit: no reset time, so nothing waits", to: &$0)
        }
        saveTrail(id)
        JobTree.log("\(id.uuidString.prefix(8)): dropped a limit pause with no reset time")
    }

    /// "Keep going" (orb, or "keep going" from the phone): a pause that wasn't a real limit is undone at once. If the
    /// limit is real, the AI service says so again and it pauses again with the reset time.
    func keepGoingAfterLimit(_ id: UUID) async {
        JobTree.log("\(id.uuidString.prefix(8)): Keep going tapped on a limit pause")
        await carryOnAfterLimit(id, why: "they said Keep going, so it carries on now without waiting for the reset")
    }

    func carryOnAfterLimit(_ id: UUID, why: String) async {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit == true, h.stoppedByYou != true else { return }
        if let sid = h.sid { StopMark.lift(sid) }
        update(id) {
            Limit.clear(&$0)
            HelperTrail.add("Carrying on: \(why)", to: &$0)
        }
        saveTrail(id)
        let text =
            Goals.helperGoal(h.task) != nil
            ? "/goal resume"
            : "(One app note, not from the user: you were paused because the AI account hit its limit; \(why). Nobody pressed Stop. Carry on from where you stopped.)"
        await Budget.resend(id, text)
    }
}
