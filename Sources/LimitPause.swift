import AppKit
import Foundation

// MARK: - The account limit is the only real ceiling (Omar, Nov 10 2026)

/// When the AI account a helper runs on hits its 5-hour or weekly limit, the helper pauses and asks, on its orb and
/// on their phone if they're away: "<job> hit the limit on <account>. Switch to <other account>, or wait for the
/// reset at <time>?". One never switches by itself (work accounts may sit next to his own; the engine's own
/// switching is off: `only_chosen` in the one-stop plugin). No answer = it waits for the reset and carries on by
/// itself. The answer is kept for that one job only: next time it does the same without asking.
enum Limit {
    /// Words in a turn's end (or its last words) that mean the account hit its limit, not a real error.
    static let words = [
        "rate limit", "rate_limit", "usage limit", "limit reached", "reached your limit", "hit your limit", "weekly limit",
        "5-hour limit", "out of extra usage", "quota", "too many requests", "429",
    ]
    /// In SOUL (Brain.swift), for the main assistant on every channel.
    static let soul = """
        Budgets: a helper has a share of the week only when they name one; then put it in its job as "up to 10% of the week". \
        Otherwise, and for every Goal: helper or "don't stop until it's done", write no budget: it never pauses to ask for more. \
        When a helper's AI account hits its limit, One asks them "Switch to <other account>, or wait for the reset?". If they \
        answer in a phone chat ("switch", "wait", "switch Quebec trip"), run `One --limit-answer switch <job title>` or \
        `One --limit-answer wait <job title>` and tell them in one line. Never switch accounts any other way.
        """
    /// Paused by One, not stopped by them: the turn that ends now is never picked back up as a cut-off.
    static func pausedOnPurpose(_ h: Helper) -> Bool { h.stoppedByYou != true && (h.pausedForBudget == true || h.pausedForLimit == true) }
    static func hit(stop: String, reply: String) -> Bool {
        let s = stop.lowercased()
        let tail = String(reply.suffix(400)).lowercased()
        return (s.hasPrefix("error") || s.contains("limit")) && words.contains { s.contains($0) }
            || words.contains { tail.contains($0) } && (tail.contains("limit") || tail.contains("429"))
    }
    /// A window at 100%: the account can't answer until it resets.
    static func full(_ m: Usage.Meter?) -> Date?? {
        guard let m else { return nil }
        if let s = m.session, s >= 100 { return .some(m.sessionReset) }
        if m.week >= 100 { return .some(m.reset) }
        return nil
    }
    static func time(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "the next reset" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }
    static func question(job: String, account: String, other: String?, reset: Date?) -> String {
        let wait = "wait for the reset at \(time(reset))"
        return other.map { "\(job) hit the limit on \(account). Switch to \($0), or \(wait)?" }
            ?? "\(job) hit the limit on \(account). It will \(wait) and carry on by itself."
    }
    static func line(account: String, reset: Date?) -> String { "Hit the limit on \(account) · carries on at \(time(reset))" }
    /// What they can text back from the phone chat (the assistant there runs `One --limit-answer`).
    static func phoneHint(_ other: String?) -> String {
        other == nil ? "Nothing to do: it carries on by itself." : "Reply \"switch\" or \"wait\" here, or do nothing and it waits."
    }

    /// `One --limit-answer switch|wait [<job>]`: their answer from a phone chat, picked up by the app within seconds.
    static var answers: URL { Env.support.appendingPathComponent("helpers/limit-answers", isDirectory: true) }
    static func cli(_ args: [String]) -> Int32? {
        guard let i = args.firstIndex(of: "--limit-answer") else { return nil }
        let rest = Array(args.dropFirst(i + 1))
        guard let pick = rest.first?.lowercased(), pick == "switch" || pick == "wait" else {
            print("usage: One --limit-answer switch|wait [<job name>]")
            return 2
        }
        try? FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        let j: [String: Any] = ["pick": pick, "job": rest.dropFirst().joined(separator: " "), "at": Date().timeIntervalSince1970]
        guard let d = try? JSONSerialization.data(withJSONObject: j),
            (try? d.write(to: answers.appendingPathComponent(UUID().uuidString + ".json"))) != nil
        else { return 1 }
        print("Got it: \(pick == "switch" ? "switching it to your other account" : "it waits for the reset and carries on by itself").")
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
    /// answered for this job last time.
    func pauseForLimit(_ id: UUID, reset: Date?) {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit != true else { return }
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
        JobTree.log("\(id.uuidString.prefix(8)): paused at the account's limit")
        let p = provider ?? .claude
        Task { @MainActor in
            let acct = await Limit.account(p)
            let other = await Budget.otherAccount(p)
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
    /// you asked", Nov 10), and never "stopped by you". Returns true if handled.
    func pausedTurnEnded(_ id: UUID, stop: String) -> Bool {
        guard let h = helpers.first(where: { $0.id == id }) else { return false }
        if Limit.pausedOnPurpose(h) {
            saveTrail(id)
        } else if Limit.hit(stop: stop, reply: h.reply) {
            pauseForLimit(id, reset: nil)
        } else {
            return false
        }
        resumeInterrupted()
        return true
    }

    /// Their answer (orb, or the phone chat): switch to the other account now, or wait for the reset.
    func answerLimit(_ id: UUID, switchAccount: Bool) async {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit == true else { return }
        update(id) { $0.limitChoice = switchAccount ? "switch" : "wait" }
        guard switchAccount else {
            update(id) {
                $0.seen = true
                HelperTrail.add("You said wait: it carries on at \(Limit.time($0.limitReset))", to: &$0)
            }
            return saveTrail(id)
        }
        guard let e = h.switchEntry, await Budget.makeDefault(provider ?? .claude, e) else { return }
        await carryOnAfterLimit(id, why: "they switched it to their \(h.switchTo ?? "other") account")
    }

    /// Every ~30 s: answers from the phone, and paused helpers whose limit has reset (or, when the reset time
    /// isn't known, every 30 minutes) carry on by themselves.
    func tendLimits(now: Date = Date()) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: Limit.answers, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            defer { try? fm.removeItem(at: f) }
            guard let j = (try? Data(contentsOf: f)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            let job = (j["job"] as? String ?? "").lowercased()
            let paused = helpers.filter { $0.pausedForLimit == true }
            let pick = paused.first { !job.isEmpty && $0.title.lowercased().contains(job) } ?? (paused.count == 1 ? paused.first : nil)
            if let id = pick?.id { Task { await answerLimit(id, switchAccount: j["pick"] as? String == "switch") } }
        }
        for h in helpers where h.pausedForLimit == true {
            let due = h.limitReset.map { now >= $0.addingTimeInterval(60) } ?? (h.limitAt.map { now.timeIntervalSince($0) >= 1800 } ?? true)
            if due { Task { await carryOnAfterLimit(h.id, why: "the limit on \(h.limitAccount ?? "your account") reset") } }
        }
    }

    func carryOnAfterLimit(_ id: UUID, why: String) async {
        guard let h = helpers.first(where: { $0.id == id }), h.pausedForLimit == true else { return }
        if let sid = h.sid { StopMark.lift(sid) }
        update(id) {
            $0.pausedForLimit = nil
            $0.limitReset = nil
            $0.limitAt = nil
            $0.switchTo = nil
            $0.switchEntry = nil
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
