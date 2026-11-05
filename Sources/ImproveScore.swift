import Foundation

// MARK: - The score: a line a day, a line a week, and incidents
// Measures (design section 5): right the first time (helpers with no correction, redo, stop or cut-off),
// corrections per 100 messages from the person, the same mistake again (a pattern already a rule seen again),
// cut off, walls and slow jobs. A week with fewer than 20 helper jobs shows "not enough jobs this week".

/// One line of `score.jsonl` (a day) or `weeks.jsonl` (an ISO week).
struct ImproveScoreLine: Codable, Equatable {
    var period: String
    var said: Int
    var corrections: Int
    var perHundred: Double?
    var helpers: Int
    var right: Int
    var rightPct: Double?
    var note: String?
    var sameAgain: Int
    var cutOff: Int
    var walls: Int
    var handoffs: Int
    var slowJobs: Int
    var helpersOver30: Int
    var timeouts: Int
    var slowHelpers: Int?
    var incidents: Int
    var kinds: [String: [Int]]

    enum CodingKeys: String, CodingKey {
        case period, said, corrections, helpers, right, note, walls, handoffs, timeouts, incidents, kinds
        case perHundred = "corrections_per_100"
        case rightPct = "right_first_time_pct"
        case sameAgain = "same_mistake_again"
        case cutOff = "cut_off"
        case slowJobs = "slow_jobs"
        case helpersOver30 = "helpers_over_30_min"
        case slowHelpers = "slow_helpers"
    }
}

enum ImproveScore {
    static let minWeekJobs = 20
    static let notEnough = "not enough jobs this week"

    /// The score for some days' counts (summed).
    static func line(_ period: String, _ days: [ImproveDay], week: Bool) -> ImproveScoreLine {
        var c: [String: Int] = [:]
        var kinds: [String: [Int]] = [:]
        var incidents = 0
        for d in days {
            for (k, v) in d.counts { c[k, default: 0] += v }
            for (k, v) in d.kinds {
                var t = kinds[k] ?? [0, 0]
                t[0] += v.first ?? 0
                t[1] += v.dropFirst().first ?? 0
                kinds[k] = t
            }
            incidents += d.incidents.count
        }
        let n = { (k: String) in c[k] ?? 0 }
        let said = n(ImproveCount.said)
        let helpers = n(ImproveCount.helpers)
        let enough = !week || helpers >= minWeekJobs
        let pct = helpers > 0 && enough ? (Double(n(ImproveCount.right)) * 1000 / Double(helpers)).rounded() / 10 : nil
        let per = said > 0 ? (Double(n(ImproveCount.corrections)) * 1000 / Double(said)).rounded() / 10 : nil
        let walls = n(ImproveCount.handoffs) + n(ImproveCount.folderLock) + n(ImproveCount.signedOut) + n(ImproveCount.rateLimits)
        return ImproveScoreLine(
            period: period, said: said, corrections: n(ImproveCount.corrections), perHundred: per, helpers: helpers,
            right: n(ImproveCount.right), rightPct: pct, note: week && !enough ? notEnough : nil, sameAgain: n(ImproveCount.sameAgain),
            cutOff: n(ImproveCount.cutOff) + n(ImproveCount.pickedAlone), walls: walls, handoffs: n(ImproveCount.handoffs),
            slowJobs: n(ImproveCount.slowHelpers) + n(ImproveCount.timeouts), helpersOver30: n(ImproveCount.over30),
            timeouts: n(ImproveCount.timeouts), slowHelpers: n(ImproveCount.slowHelpers), incidents: incidents, kinds: kinds)
    }

    // MARK: Files

    static func readLines(_ u: URL) -> [ImproveScoreLine] {
        guard let t = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return t.split(separator: "\n").compactMap { try? JSONDecoder().decode(ImproveScoreLine.self, from: Data($0.utf8)) }
    }
    static func writeLines(_ lines: [ImproveScoreLine], to u: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = lines.sorted { $0.period < $1.period }.compactMap { (try? enc.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
            .joined(separator: "\n")
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (text + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    /// Replaces the lines of these days in score.jsonl and their weeks in weeks.jsonl (from every day file of the week).
    static func write(days keys: [String]) {
        var byDay = Dictionary(readLines(Improve.scoreFile).map { ($0.period, $0) }, uniquingKeysWith: { _, b in b })
        for k in keys { if let d = Improve.readDay(k) { byDay[k] = line(k, [d], week: false) } }
        writeLines(Array(byDay.values), to: Improve.scoreFile)
        var byWeek = Dictionary(readLines(Improve.weeksFile).map { ($0.period, $0) }, uniquingKeysWith: { _, b in b })
        let all = Improve.dayKeys()
        for w in Set(keys.map(Improve.weekKey)) {
            byWeek[w] = line(w, all.filter { Improve.weekKey($0) == w }.compactMap(Improve.readDay), week: true)
        }
        writeLines(Array(byWeek.values), to: Improve.weeksFile)
    }

    // MARK: Incidents (design section 6.2)

    /// The usual daily level of each signal around a day: the 14 days before (day files or this batch); with fewer
    /// than 3 such days, the days after in this batch too.
    static func around(_ key: String, _ mine: [String: ImproveDay], _ stored: Set<String>) -> [[String: Int]] {
        guard let d0 = Improve.day(key) else { return [] }
        var out: [[String: Int]] = []
        for i in 1...14 {
            guard let d = Calendar.current.date(byAdding: .day, value: -i, to: d0) else { continue }
            let k = Improve.dayKey(d)
            if let s = mine[k]?.signals ?? (stored.contains(k) ? Improve.readDay(k)?.signals : nil) { out.append(s) }
        }
        guard out.count < 3 else { return out }
        for i in 1...14 where out.count < 14 {
            if let d = Calendar.current.date(byAdding: .day, value: i, to: d0), let s = mine[Improve.dayKey(d)]?.signals { out.append(s) }
        }
        return out
    }

    /// A signal more than 5 times its usual daily level (and at least 6) on one day becomes ONE incident: its events
    /// leave the day's list (the counts stay, so the score still shows the bad day). Corrections never fold.
    static func foldIncidents(_ batch: [ImproveDay]) -> [ImproveDay] {
        let mine = Dictionary(batch.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let stored = Set(Improve.dayKeys())
        return batch.map { day in
            let usualDays = around(day.date, mine, stored)
            var out = day
            // The person's own words always stay events: a bad day of corrections is still a day of lessons.
            for (key, n) in day.signals.sorted(by: { $0.key < $1.key }) where n >= 6 && !key.hasPrefix("correction/") {
                let usual = ImproveCollect.median(usualDays.map { Double($0[key] ?? 0) }) ?? 0
                guard Double(n) > 5 * max(usual, 1) else { continue }
                let evs = out.events.filter { $0.key == key }
                guard let f = evs.first, let l = evs.last else { continue }
                var sessions: [String] = []
                for e in evs { if let s = e.session, !sessions.contains(s), sessions.count < 30 { sessions.append(s) } }
                out.incidents.append(
                    ImproveIncident(
                        kind: f.kind, sub: f.sub, count: n, usual: usual, first: f.time, last: l.time, sessions: sessions,
                        quote: evs.first { $0.quote != nil }?.quote))
                out.events.removeAll { $0.key == key }
            }
            return out
        }
    }

    // MARK: The same mistake again

    /// For each day: lessons already a rule (status rule/proven/retired, `rule_since` before that day) whose
    /// pattern was seen again that day (`seen` dates). `improve/lessons.jsonl` is written by the nightly review;
    /// until it exists this is 0.
    static func sameAgain(_ days: [String]) -> [String: Int] {
        guard let t = try? String(contentsOf: Improve.lessonsFile, encoding: .utf8) else { return [:] }
        var latest: [String: [String: Any]] = [:]  // a lesson's last line wins
        for l in t.split(separator: "\n") {
            guard let j = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] else { continue }
            latest[(j["id"] as? String) ?? (j["pattern"] as? String) ?? UUID().uuidString] = j
        }
        var out: [String: Int] = [:]
        for j in latest.values {
            guard ["rule", "proven", "retired"].contains((j["status"] as? String) ?? ""), let since = j["rule_since"] as? String else { continue }
            for d in Set((j["seen"] as? [String]) ?? []) where d > since && days.contains(d) { out[d, default: 0] += 1 }
        }
        return out
    }

    // MARK: Plain lines for the morning brief

    static func pct(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))%" : String(format: "%.1f%%", v) }
    static func num(_ v: Double) -> String { String(format: "%.1f", v) }

    /// The week line for the ISO week holding `day`.
    static func week(of day: Date) -> ImproveScoreLine {
        let w = Improve.weekKey(Improve.dayKey(day))
        return line(w, Improve.dayKeys().filter { Improve.weekKey($0) == w }.compactMap(Improve.readDay), week: true)
    }

    /// 1-3 short lines: this week so far against last week (or, with `lastWeek`, the last full week against the one before).
    static func brief(lastWeek: Bool, today: Date = Date()) -> [String] {
        guard !Improve.dayKeys().isEmpty else { return ["No score yet: run `One --improve collect` first."] }
        let cal = Calendar.current
        let shown = cal.date(byAdding: .day, value: lastWeek ? -7 : 0, to: today) ?? today
        let b = week(of: shown)
        let a = week(of: cal.date(byAdding: .day, value: -7, to: shown) ?? shown)
        let label = lastWeek ? "last week" : "this week"
        var out: [String] = []
        switch (a.rightPct, b.rightPct) {
        case (.some(let x), .some(let y)): out.append("Right the first time: \(pct(x)) → \(pct(y)) \(label).")
        case (_, .some(let y)): out.append("Right the first time: \(pct(y)) \(label).")
        default: out.append("Right the first time: \(notEnough) (\(b.helpers) so far).")
        }
        if let p = b.perHundred {
            out.append("Corrections: \(num(p)) per 100 messages" + (a.perHundred.map { " (\(num($0)) the week before)." } ?? "."))
        }
        var rest = ["Cut off: \(b.cutOff)", "Walls: \(b.walls)", "Slow jobs: \(b.slowJobs)"]
        if b.sameAgain > 0 { rest.insert("Same mistake again: \(b.sameAgain)", at: 0) }
        out.append(rest.joined(separator: " · ") + " \(label).")
        return out
    }
}
