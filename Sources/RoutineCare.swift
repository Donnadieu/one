import Foundation

// MARK: - Routines that fix themselves, and ask once when only the person can
//
// Omar, Nov 19 2026: "We had a routine fail three times today and you didn't do anything about it." The X replies
// routines failed on Nov 18 (afternoon, evening) and Nov 19 because X was signed out of the hidden browser on 9224;
// each run put one `[CRON_FAILURE]` line in the chat and the assistant asked once. Now, every minute:
// - A routine whose run failed gets one fixer helper (`fixerBrief`): it tries every fix that needs nobody and makes
//   the missed run up, or hands a step only the person can do back to One (`One --routine-care block`).
// - A sign-in a routine needs (declared in `routines/needs.json`, `One --routine-care need`) that is missing is a
//   blocker: ONE "needs you" item at the top of the screen with Show me the window (the hand-off window), one message
//   to the phone chat, reminders at 30 min, 2 h, then every 6 h (never 10 PM to 8 AM), and every routine that needs it
//   paused so its runs skip instead of failing again.
// - An hour before each run of such a routine, its sign-ins are checked (the cookies, over the browser's DevTools
//   port, read only), so the item comes up before the run would fail.
// - While a blocker is open, a routine failing on it (declared or not) stays out of the chat and joins it.
// - Once it clears (the cookies are back), the routines are turned back on one at a time; a run missed today that the
//   engine doesn't make up by itself within 5 minutes is run once. The routine's own daily limits still hold.
// - Every event goes to `routines/care-log.jsonl`; a good morning or status report gets the week's line.
// `step` is pure (plus the event log); RoutineCareTend.swift carries its effects out.

enum RoutineCare {
    static var dir: URL { Env.support.appendingPathComponent("routines") }
    static var stateFile: URL { dir.appendingPathComponent("care.json") }
    static var needsFile: URL { dir.appendingPathComponent("needs.json") }
    static var logFile: URL { dir.appendingPathComponent("care-log.jsonl") }
    static var inboxFile: URL { dir.appendingPathComponent("care-inbox.jsonl") }
    static var weekFile: URL { dir.appendingPathComponent("week.md") }
    static let askPrefix = "routine-"
    /// Reminders after the first message: 30 min, 2 h, then every 6 h.
    static let reminders: [TimeInterval] = [1800, 7200]
    static let remindEvery: TimeInterval = 6 * 3600
    static let preflightAhead: TimeInterval = 3600
    static let fixerAgain: TimeInterval = 6 * 3600

    /// A sign-in a routine needs: these cookies for this site in the hidden browser on this port.
    struct Need: Codable, Equatable, Hashable {
        var site: String
        var port: Int
        var cookies: [String]
        var login: String?
        var key: String { "sign_in:\(site)@\(port)" }
        var loginURL: String { login ?? "https://\(site)/" }
    }

    /// Something only the person can do that routines wait on.
    struct Blocker: Codable, Equatable {
        var key = ""
        var site = ""
        var kind = "sign_in"  // sign_in, code, check, approve, passkey, yes
        var port = 9224
        var login: String?
        var why = ""
        var routines: [String] = []  // job ids waiting on it
        var paused: [String] = []  // job ids One paused for it (only these are turned back on)
        var opened = Date()
        var source = ""  // preflight, failure, fixer
        var pings: [Date] = []  // phone messages sent (the first one when it opened)
        var missed: [String: [Date]] = [:]  // job id → runs that failed while it was open
        var asks = 0  // how many times the window ask was raised
        var cleared: Date?
        var hasCookies = true  // false for a fixer's step with no cookie to watch (cleared by `clear` or Done)
    }

    /// A routine being turned back on after a fix, one at a time.
    struct CatchUp: Codable, Equatable {
        var job: String
        var cleared: Date
        var missedToday: Bool
        var started: Date?
        var ranNow = false
    }

    struct Event: Codable, Equatable {
        var at: Date
        var job: String
        var kind: String  // failed, skipped, blocked, cleared, fixed, caught_up, fixer
        var cause: String
        var minutes: Int?
    }

    struct State: Codable, Equatable {
        var blockers: [Blocker] = []
        var handled: [String: String] = [:]  // job id → the last run already looked at
        var preflighted: [String: String] = [:]  // job id → the next run already checked
        var fixers: [String: Date] = [:]  // job id → when its fixer started
        var failedSince: [String: Date] = [:]  // job id → its first failure not yet fixed
        var catchUp: [CatchUp] = []
        var open: [Blocker] { blockers.filter { $0.cleared == nil } }
    }

    /// One thing for One to do: ask (the needs-you item and its hand-off request), ping (phone), pause, resume,
    /// run (a missed run now), fixer (a helper), swallow (keep a report out of the chat), say (one chat line).
    struct Effect: Equatable {
        var kind: String
        var job = ""
        var text = ""
        var blocker = ""
    }

    /// The part of a routine the step reads, from `cron/jobs.json`.
    struct Job: Equatable {
        var id: String
        var title: String
        var lastRunISO: String
        var lastRun: Date?
        var next: Date?
        var nextISO: String
        var failed: Bool
        var why: String
        var enabled: Bool
        var dispatched: Date?  // the engine started a run then (it may still be going)

        init?(_ j: [String: Any], out: URL?) {
            guard let id = j["id"] as? String else { return nil }
            self.id = id
            title = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A routine"
            lastRunISO = j["last_run_at"] as? String ?? ""
            lastRun = Routines.date(j["last_run_at"])
            nextISO = j["next_run_at"] as? String ?? ""
            next = Routines.date(j["next_run_at"])
            failed = Routines.failedRecord(j, out: out)
            why = (j["last_error"] as? String) ?? ((j["last_failure"] as? [String: Any])?["detail"] as? String) ?? ""
            if let cut = why.range(of: "\n⚠️") { why = String(why[..<cut.lowerBound]) }
            why = why.trimmingCharacters(in: .whitespacesAndNewlines)
            enabled = (j["enabled"] as? Bool ?? true) && (j["state"] as? String) != "paused"
            dispatched = Routines.date((j["last_dispatch"] as? [String: Any])?["dispatched_at"])
        }
    }

    /// What `perform` needs from One (the test hands in stand-ins).
    struct Doer {
        var cron: ([String]) -> Void
        var fixer: (String, String) -> Void
        var say: (String) -> Void
        var target: (Blocker) -> String?
    }

    // MARK: the step

    /// The sign-ins to look at now: pre-flights due within the hour, routines that just failed, open blockers.
    static func wanted(_ s: State, jobs: [Job], needs: [String: [Need]], now: Date) -> Set<Need> {
        var out = Set<Need>()
        for j in jobs {
            guard let ns = needs[j.id], !ns.isEmpty else { continue }
            if j.enabled, let n = j.next, n > now, n.timeIntervalSince(now) <= preflightAhead, s.preflighted[j.id] != j.nextISO {
                out.formUnion(ns)
            }
            if j.failed, s.handled[j.id] != j.lastRunISO { out.formUnion(ns) }
        }
        for b in s.open where b.hasCookies {
            for ns in needs.values { for n in ns where n.key == b.key { out.insert(n) } }
        }
        return out
    }

    /// One minute of looking after routines. `signedIn` holds what `wanted` asked for (missing = the browser didn't
    /// answer: nothing is decided on it). `quiet`: 10 PM to 8 AM, no messages.
    static func step(
        _ s: inout State, jobs: [Job], needs: [String: [Need]], signedIn: [String: Bool], now: Date, quiet: Bool = false,
        inbox: [[String: String]]? = nil
    ) -> [Effect] {
        var e: [Effect] = []
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A fixer said only the person can do it (`One --routine-care block`), or a blocker was cleared by hand.
        for item in inbox ?? takeInbox() { e += fromInbox(&s, item, byID: byID, needs: needs, now: now, quiet: quiet) }
        // Cleared: the cookies are back.
        for k in s.blockers.indices where s.blockers[k].cleared == nil && s.blockers[k].hasCookies {
            guard signedIn[s.blockers[k].key] == true else { continue }
            e += clear(&s, k, byID: byID, now: now, quiet: quiet)
        }
        // New runs.
        for j in jobs {
            let first = s.handled[j.id] == nil
            guard s.handled[j.id] != j.lastRunISO, !j.lastRunISO.isEmpty else { continue }
            s.handled[j.id] = j.lastRunISO
            if first, !j.failed || (j.lastRun.map { now.timeIntervalSince($0) > 2 * 3600 } ?? true) { continue }  // seen at launch
            e += j.failed ? failed(&s, j, jobs: jobs, needs: needs, signedIn: signedIn, now: now, quiet: quiet) : worked(&s, j, now: now)
        }
        // Pre-flight: an hour before each run, its sign-ins.
        for j in jobs where j.enabled {
            guard let ns = needs[j.id], !ns.isEmpty, let n = j.next, n > now, n.timeIntervalSince(now) <= preflightAhead,
                s.preflighted[j.id] != j.nextISO
            else { continue }
            let missing = ns.filter { signedIn[$0.key] == false }
            if ns.allSatisfy({ signedIn[$0.key] != nil }) { s.preflighted[j.id] = j.nextISO }
            for need in missing where s.open.contains(where: { $0.key == need.key }) == false {
                e += open(
                    &s, need, why: "\(siteName(need.site)) is signed out of the hidden browser", source: "preflight", jobs: jobs, needs: needs,
                    now: now,
                    quiet: quiet)
            }
        }
        // Reminders.
        for k in s.blockers.indices where s.blockers[k].cleared == nil {
            guard !quiet, due(s.blockers[k], now: now) else { continue }
            s.blockers[k].pings.append(now)
            s.blockers[k].asks += 1
            e.append(Effect(kind: "ping", text: reminderLine(s.blockers[k], byID: byID), blocker: s.blockers[k].key))
            e.append(Effect(kind: "ask", blocker: s.blockers[k].key))
        }
        e += catchUps(&s, byID: byID, now: now)
        return e
    }

    static func failed(
        _ s: inout State, _ j: Job, jobs: [Job], needs: [String: [Need]], signedIn: [String: Bool], now: Date, quiet: Bool = false
    ) -> [Effect] {
        var e: [Effect] = []
        let cause = self.cause(j.why)
        if s.failedSince[j.id] == nil { s.failedSince[j.id] = j.lastRun ?? now }
        // Same blocker: no repeat noise.
        if let k = s.blockers.firstIndex(where: { $0.cleared == nil && covers($0, j, needs: needs) }) {
            s.blockers[k].missed[j.id, default: []].append(j.lastRun ?? now)
            if !s.blockers[k].routines.contains(j.id) { s.blockers[k].routines.append(j.id) }
            if j.enabled, !s.blockers[k].paused.contains(j.id) {
                s.blockers[k].paused.append(j.id)
                e.append(Effect(kind: "pause", job: j.id))
            }
            record(Event(at: now, job: j.id, kind: "skipped", cause: blockCause(s.blockers[k])))
            return e + [Effect(kind: "swallow", job: j.id)]
        }
        record(
            Event(
                at: now, job: j.id, kind: "failed",
                cause: (needs[j.id] ?? []).contains { signedIn[$0.key] == false } ? "\(siteName((needs[j.id] ?? [])[0].site)) signed out" : cause))
        // A sign-in it needs is missing: only the person can do that.
        if let need = (needs[j.id] ?? []).first(where: { signedIn[$0.key] == false }) {
            e += open(
                &s, need, why: "\(siteName(need.site)) is signed out of the hidden browser", source: "failure", jobs: jobs, needs: needs, now: now,
                quiet: quiet)
            if let k = s.blockers.firstIndex(where: { $0.cleared == nil && $0.key == need.key }) {
                s.blockers[k].missed[j.id, default: []].append(j.lastRun ?? now)
            }
        }
        // Every failure gets one fixer, once per routine every 6 hours.
        if now.timeIntervalSince(s.fixers[j.id] ?? .distantPast) > fixerAgain {
            s.fixers[j.id] = now
            let b = s.open.first { $0.routines.contains(j.id) }
            e.append(Effect(kind: "fixer", job: j.id, text: fixerBrief(j, blocker: b), blocker: "Fix " + short(j.title)))
            record(Event(at: now, job: j.id, kind: "fixer", cause: cause))
        }
        return e
    }

    static func worked(_ s: inout State, _ j: Job, now: Date) -> [Effect] {
        if let since = s.failedSince.removeValue(forKey: j.id) {
            record(Event(at: now, job: j.id, kind: "fixed", cause: "", minutes: max(1, Int((j.lastRun ?? now).timeIntervalSince(since) / 60))))
        }
        s.fixers[j.id] = nil
        return []
    }

    /// A new blocker (or more routines on an open one). Every routine that needs the same sign-in is paused.
    static func open(
        _ s: inout State, _ need: Need, why: String, source: String, jobs: [Job], needs: [String: [Need]], now: Date, quiet: Bool = false
    ) -> [Effect] {
        var e: [Effect] = []
        let users = jobs.filter { j in (needs[j.id] ?? []).contains { $0.key == need.key } }
        if let k = s.blockers.firstIndex(where: { $0.cleared == nil && $0.key == need.key }) {
            for j in users where !s.blockers[k].routines.contains(j.id) { s.blockers[k].routines.append(j.id) }
            return e
        }
        var b = Blocker(key: need.key, site: need.site, kind: "sign_in", port: need.port, login: need.login, why: why, opened: now, source: source)
        b.routines = users.map(\.id)
        for j in users where j.enabled {
            b.paused.append(j.id)
            e.append(Effect(kind: "pause", job: j.id))
        }
        b.pings = quiet ? [] : [now]  // at night the item is up, the phone hears at 8 AM
        b.asks = 1
        s.blockers.append(b)
        record(Event(at: now, job: users.first?.id ?? "", kind: "blocked", cause: blockCause(b)))
        let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return [Effect(kind: "ask", blocker: b.key)] + (quiet ? [] : [Effect(kind: "ping", text: phoneLine(b, byID: byID), blocker: b.key)]) + e
    }

    static func clear(_ s: inout State, _ k: Int, byID: [String: Job], now: Date, quiet: Bool = false) -> [Effect] {
        s.blockers[k].cleared = now
        let b = s.blockers[k]
        let mins = max(1, Int(now.timeIntervalSince(b.opened) / 60))
        record(Event(at: now, job: b.routines.first ?? "", kind: "cleared", cause: blockCause(b), minutes: mins))
        let cal = Calendar.current
        func missedToday(_ id: String) -> Bool { (b.missed[id] ?? []).contains { cal.isDate($0, inSameDayAs: now) } }
        let order = b.paused.filter(missedToday) + b.paused.filter { !missedToday($0) }
        for id in order where !s.catchUp.contains(where: { $0.job == id }) {
            s.catchUp.append(CatchUp(job: id, cleared: now, missedToday: missedToday(id)))
        }
        for id in b.routines { s.failedSince[id] = nil }
        let n = order.filter(missedToday).count
        let line =
            "\(siteName(b.site)) is signed in again, so your routines are back on"
            + (n == 0 ? "." : ", and I'm catching up \(n == 1 ? "the run" : "\(n) runs") it missed today.")
        return [Effect(kind: "say", text: line, blocker: b.key)]
            + (b.pings.isEmpty || quiet ? [] : [Effect(kind: "ping", text: line, blocker: b.key)])
    }

    /// Turn the paused routines back on one at a time. The engine makes up a run missed while off by itself; when it
    /// hasn't within 5 minutes, it's run once now. Only runs missed today, so a day's limits still hold.
    static func catchUps(_ s: inout State, byID: [String: Job], now: Date) -> [Effect] {
        var e: [Effect] = []
        while var c = s.catchUp.first {
            guard let j = byID[c.job] else {
                s.catchUp.removeFirst()
                continue
            }
            if c.started == nil {
                c.started = now
                s.catchUp[0] = c
                e.append(Effect(kind: "resume", job: c.job))
                if !c.missedToday {
                    s.catchUp.removeFirst()
                    continue
                }
                break
            }
            if let last = j.lastRun, last > c.cleared {
                record(Event(at: now, job: c.job, kind: "caught_up", cause: ""))
                s.catchUp.removeFirst()
                continue
            }
            let waited = now.timeIntervalSince(c.started ?? now)
            let going = j.dispatched.map { $0 > c.cleared } ?? false  // the engine is making it up right now
            if !c.ranNow, !going, waited >= 300 {
                c.ranNow = true
                s.catchUp[0] = c
                e.append(Effect(kind: "run", job: c.job))
            } else if waited > 45 * 60 {
                s.catchUp.removeFirst()  // it never ran: the next scheduled run will do
                continue
            }
            break
        }
        return e
    }

    static func fromInbox(
        _ s: inout State, _ item: [String: String], byID: [String: Job], needs: [String: [Need]], now: Date, quiet: Bool = false
    ) -> [Effect] {
        let site = (item["site"] ?? "").lowercased()
        if item["do"] == "clear" {
            guard let k = s.blockers.firstIndex(where: { $0.cleared == nil && ($0.site == site || $0.key == item["key"]) }) else { return [] }
            return clear(&s, k, byID: byID, now: now, quiet: quiet)
        }
        guard item["do"] == "block", !site.isEmpty else { return [] }
        let job = item["job"] ?? ""
        if let k = s.blockers.firstIndex(where: { $0.cleared == nil && $0.site == site }) {
            if !job.isEmpty, !s.blockers[k].routines.contains(job) { s.blockers[k].routines.append(job) }
            var e: [Effect] = []
            if let j = byID[job], j.enabled, !s.blockers[k].paused.contains(job) {
                s.blockers[k].paused.append(job)
                e.append(Effect(kind: "pause", job: job))
            }
            return e
        }
        let kind = item["kind"].flatMap { HumanStep.asking[$0] == nil && $0 != "yes" ? nil : $0 } ?? "sign_in"
        let port =
            Int(item["port"] ?? "") ?? needs.values.joined().first { $0.site == site }?.port ?? BrowserKeeper.plan?.port ?? 9224
        let n = needs.values.joined().first { $0.site == site && $0.port == port }
        var b = Blocker(
            key: n?.key ?? "\(kind):\(site)@\(port)", site: site, kind: kind, port: port, login: n?.login,
            why: item["why"] ?? "\(siteName(site)) needs you", opened: now, source: "fixer")
        b.hasCookies = n != nil && kind == "sign_in"
        b.routines = job.isEmpty ? [] : [job]
        var e: [Effect] = []
        if let j = byID[job], j.enabled {
            b.paused = [job]
            e.append(Effect(kind: "pause", job: job))
        }
        b.pings = quiet ? [] : [now]
        b.asks = 1
        s.blockers.append(b)
        record(Event(at: now, job: job, kind: "blocked", cause: blockCause(b)))
        return [Effect(kind: "ask", blocker: b.key)] + (quiet ? [] : [Effect(kind: "ping", text: phoneLine(b, byID: byID), blocker: b.key)]) + e
    }

    /// The blocker is about this run's failure: the routine needs that sign-in, or its words say it was signed out of
    /// that site ("X is signed out", "x.com login page").
    static func covers(_ b: Blocker, _ j: Job, needs: [String: [Need]]) -> Bool {
        if b.routines.contains(j.id) || (needs[j.id] ?? []).contains(where: { $0.key == b.key }) { return true }
        let t = j.why.lowercased()
        let name = siteName(b.site).lowercased()
        let mentions = t.contains(b.site) || t.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
        return mentions && signedOutWords.contains { t.contains($0) }
    }

    static let signedOutWords = ["signed out", "sign in", "sign-in", "log in", "login", "logged out", "signed-out"]

    static func due(_ b: Blocker, now: Date) -> Bool {
        let n = b.pings.count  // the first one goes when it opens (or at 8 AM, when it opened at night)
        guard n > 0, let first = b.pings.first else { return true }
        let after = n - 1 < reminders.count ? reminders[n - 1] : reminders.last! + Double(n - reminders.count) * remindEvery
        return now.timeIntervalSince(first) >= after
    }

}
