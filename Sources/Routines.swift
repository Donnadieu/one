import Foundation

// MARK: - Routines: everything the assistant made that keeps working (Claude Design "Routines View Options",
// B · Day dial, picked by Omar). Read-only here: the engine's scheduled jobs (`hermes/cron/jobs.json` and the
// last result of each in `hermes/cron/output/<id>/`), the skills it knows (engine skills folder, each room's
// `skills/learned`), and the jobs a Hermes outside One runs. Read off the main thread (rooms live in Documents).
// The only writes are the person's own taps: Run now / Pause / Turn back on, through the engine's `cron` command.

struct Routine: Identifiable, Equatable {
    enum State: String { case worked, failed, never, running, paused, finished }
    let id: String
    let title: String
    let what: String  // plain words: the last thing it said, or what it does
    let often: String  // "Every day at 9:30 AM"
    let today: [Int]  // minutes after midnight it runs today
    let every: Int?  // minutes, for the ones that run every few minutes
    let lastRun: Date?
    let next: Date?
    let state: State
    let reason: String?  // why the last run didn't work, in plain words
    var outside = false  // run by a Hermes outside One
    /// How a run that didn't work went: stopped (nothing says more), cut off by One restarting mid-run
    /// (what it did before that is done), or partly done (its own report says which part failed).
    enum Miss: Equatable { case stopped, cut, partly }
    var miss: Miss = .stopped
}

struct SkillStar: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let about: String
    let room: String?  // "Co-Founder room"; nil = the assistant's own skills
    let made: Date?
    let mine: Bool  // learned or saved for this person (through One, or in a room)
    let path: String
    var title: String { Routines.plainName(name) }
}

struct RoutinesSnapshot: Equatable {
    var routines: [Routine] = []
    var skills: [SkillStar] = []
    var now = Date()
    var needLook: Int { routines.filter { $0.state == .failed && !$0.outside }.count }
}

enum Routines {
    static var cron: URL { Env.hermesHome.appendingPathComponent("cron") }

    /// Everything, read fresh. Call off the main thread.
    static func load(now: Date = Date()) -> RoutinesSnapshot {
        var s = RoutinesSnapshot(now: now)
        s.routines = jobs(at: cron, now: now)
        if Env.production {
            let mine = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".hermes/cron")
            if mine.standardizedFileURL != cron.standardizedFileURL {
                s.routines += jobs(at: mine, now: now).filter { $0.state != .paused && $0.state != .finished }.map {
                    var r = $0
                    r.outside = true
                    return r
                }
            }
        }
        s.skills = skills()
        return s
    }

    // MARK: Scheduled jobs

    static func jobs(at dir: URL, now: Date) -> [Routine] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("jobs.json")),
            let top = try? JSONSerialization.jsonObject(with: d)
        else { return [] }
        let list = (top as? [String: Any])?["jobs"] as? [[String: Any]] ?? top as? [[String: Any]] ?? []
        return list.compactMap { routine($0, dir: dir, now: now) }
    }

    static func routine(_ j: [String: Any], dir: URL, now: Date) -> Routine? {
        guard let id = j["id"] as? String else { return nil }
        let title = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A routine"
        let sched = j["schedule"] as? [String: Any] ?? [:]
        let last = date(j["last_run_at"])
        let next = date(j["next_run_at"])
        let enabled = j["enabled"] as? Bool ?? true
        let jobState = j["state"] as? String ?? ""
        let dispatched = date((j["last_dispatch"] as? [String: Any])?["dispatched_at"])
        let claimed = j["fire_claim"] != nil && !(j["fire_claim"] is NSNull)
        var st: Routine.State
        if !enabled && jobState == "completed" {
            st = .finished
        } else if !enabled || jobState == "paused" {
            st = .paused
        } else if claimed || (dispatched != nil && (last == nil || dispatched! > last!) && now.timeIntervalSince(dispatched!) < 3 * 3600) {
            st = .running
        } else if last == nil {
            st = .never
        } else {
            st = (j["last_status"] as? String) == "error" ? .failed : .worked
        }
        let (often, today, every) = when(sched, now: now)
        let err = (j["last_error"] as? String) ?? ((j["last_failure"] as? [String: Any])?["detail"] as? String)
        var r = Routine(
            id: id, title: title, what: lastSaid(dir.appendingPathComponent("output/\(id)")), often: often, today: today, every: every,
            lastRun: last, next: st == .finished ? nil : next, state: st,
            reason: (st == .failed || (st == .running && (j["last_status"] as? String) == "error")) ? plainError(err) : nil)
        r.miss = miss(err)
        return r
    }

    /// Titles of One's own routines at work right now. A restart (an update) would cut them off midway.
    static func inFlight(now: Date = Date()) -> [String] {
        jobs(at: cron, now: now).filter { $0.state == .running }.map(\.title)
    }

    /// True when the engine stopped the run because One quit or restarted (an update, a reinstall).
    static func cutByRestart(_ e: String?) -> Bool {
        guard let low = e?.lowercased() else { return false }
        return low.contains("gateway shutdown") || low.contains("sigterm") || low.contains("fire claim") || low == "interrupted"
    }

    static func miss(_ e: String?) -> Routine.Miss {
        if cutByRestart(e) { return .cut }
        let t = (e ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("partly done") || t.hasPrefix("partially done") ? .partly : .stopped
    }

    /// The card's line under the title when the last run didn't work.
    static func missLine(_ r: Routine) -> String {
        switch r.miss {
        case .cut: return "Cut short when One restarted. What it did before that is done."
        case .partly: return "Partly done last time."
        case .stopped: return "Didn't finish last time."
        }
    }

    /// The short word for that run on the dial and the card.
    static func missWord(_ r: Routine) -> String {
        switch r.miss {
        case .cut: return "cut short by a restart"
        case .partly: return "partly done"
        case .stopped: return "didn't finish"
        }
    }

    /// The first plain sentence of the job's newest result, or what a quiet job does.
    static func lastSaid(_ out: URL) -> String {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        guard let f = files.last, let text = try? String(contentsOf: out.appendingPathComponent(f), encoding: .utf8) else {
            return "Hasn't said anything yet."
        }
        let body = text.components(separatedBy: "## Response").dropFirst().joined(separator: " ")
        for raw in (body.isEmpty ? text : body).components(separatedBy: "\n") {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("[") || l.hasPrefix("#") || l.hasPrefix("---") || l.hasPrefix("|") || l.hasPrefix("**Job")
                || l.hasPrefix("**Run")
            {
                continue
            }
            if l.contains("[SILENT]") { return "Works quietly. It only speaks up when something's wrong." }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            while l.hasPrefix("-") || l.hasPrefix("*") || l.hasPrefix(">") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return clip(l, 170)
        }
        return "Works quietly. It only speaks up when something's wrong."
    }

    static func plainError(_ e: String?) -> String {
        guard let e, !e.isEmpty else { return "It stopped before it finished." }
        let low = e.lowercased()
        if cutByRestart(e) { return "Stopped partway because One restarted (an update or a reinstall) while it was working." }
        return clip(e, 220)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let cut = String(s.prefix(n))
        if let dot = cut.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }), cut.distance(from: cut.startIndex, to: dot) > n / 2 {
            return String(cut[...dot])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Schedules in plain words

    /// (how often, the minutes it runs today, every N minutes)
    static func when(_ s: [String: Any], now: Date) -> (String, [Int], Int?) {
        let kind = s["kind"] as? String ?? ""
        if kind == "interval", let m = (s["minutes"] as? Int) ?? (s["minutes"] as? Double).map({ Int($0) }) {
            return (every(m), [], m)
        }
        if kind == "cron", let e = s["expr"] as? String { return cron(e, now: now) }
        if let at = date(s["run_at"]) ?? date(s["at"]) {
            let mins = sameDay(at, now) ? [minutes(at)] : []
            return ("Once, " + day(at, now: now, lower: false) + " at " + clock(minutes(at)), mins, nil)
        }
        return ((s["display"] as? String).map { "On its own schedule (\($0))" } ?? "On its own schedule", [], nil)
    }

    static func every(_ m: Int) -> String {
        if m % 60 == 0 { return m == 60 ? "Every hour" : "Every \(m / 60) hours" }
        return "Every \(m) minutes"
    }

    static func cron(_ expr: String, now: Date) -> (String, [Int], Int?) {
        let f = expr.split(separator: " ").map(String.init)
        guard f.count == 5 else { return ("On its own schedule", [], nil) }
        let mins = field(f[0], 0...59) ?? Array(0...59)
        let hours = field(f[1], 0...23) ?? Array(0...23)
        let cal = Calendar.current
        let dows = field(f[4], 0...7)?.map { $0 % 7 }
        let doms = field(f[2], 1...31)
        let mons = field(f[3], 1...12)
        // Every hour, or every few minutes, all day ("0 * * * *", "*/5 * * * *").
        if f[1] == "*" {
            let step = mins.count > 1 ? mins[1] - mins[0] : 60
            return (every(step), [], step)
        }
        var times: [Int] = []
        for h in hours { for m in mins { times.append(h * 60 + m) } }
        times.sort()
        let at = list(times.map(clock))
        let wd = cal.component(.weekday, from: now) - 1  // 0 = Sunday
        let runsToday =
            (dows == nil || dows!.contains(wd)) && (doms == nil || doms!.contains(cal.component(.day, from: now)))
            && (mons == nil || mons!.contains(cal.component(.month, from: now)))
        if let doms, let mons, doms.count == 1, mons.count == 1 {
            let name = DateFormatter().shortMonthSymbols[mons[0] - 1]
            return ("Once, \(name) \(doms[0]) at \(at)", runsToday ? times : [], nil)
        }
        var days = "Every day"
        if let dows, Set(dows).count < 7 {
            let set = Set(dows)
            if set == [1, 2, 3, 4, 5] {
                days = "Weekdays"
            } else if set == [0, 6] {
                days = "Weekends"
            } else {
                let names = cal.weekdaySymbols
                days = set.count == 1 ? names[dows[0]] + "s" : list(set.sorted().map { String(names[$0].prefix(3)) })
            }
        } else if let doms {
            days = "On day " + list(doms.map(String.init)) + " of the month"
        }
        return ("\(days) at \(at)", runsToday ? times : [], nil)
    }

    /// One cron field: "*", "5", "1-5", "0,6", "*/15", "9-17/2". nil = any.
    static func field(_ s: String, _ r: ClosedRange<Int>) -> [Int]? {
        if s == "*" { return nil }
        var out: [Int] = []
        for part in s.split(separator: ",") {
            let bits = part.split(separator: "/")
            let step = bits.count > 1 ? Int(bits[1]) ?? 1 : 1
            var lo = r.lowerBound
            var hi = r.upperBound
            if bits[0] != "*" {
                let ends = bits[0].split(separator: "-").compactMap { Int($0) }
                guard let a = ends.first else { return nil }
                lo = a
                hi = ends.count > 1 ? ends[1] : (bits.count > 1 ? r.upperBound : a)
            }
            guard lo <= hi else { return nil }
            out += stride(from: lo, through: hi, by: max(1, step)).map { $0 }
        }
        return out.isEmpty ? nil : Array(Set(out)).sorted()
    }

    // MARK: Skills

    static func skills() -> [SkillStar] {
        let fm = FileManager.default
        var made: [String: Date] = [:]
        if let t = try? String(contentsOf: Learning.ledger, encoding: .utf8) {
            for line in t.split(separator: "\n") where line.contains("\"action\": \"create\"") || line.contains("\"action\":\"create\"") {
                guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let n = o["skill"] as? String else {
                    continue
                }
                made[n] = date(o["ts"]) ?? made[n]
            }
        }
        var out: [SkillStar] = []
        var seen = Set<String>()
        func add(_ md: URL, room: String?, mine: Bool) {
            let p = md.standardizedFileURL.path
            guard !seen.contains(p) else { return }
            seen.insert(p)
            let name = md.deletingLastPathComponent().lastPathComponent
            let text = (try? String(contentsOf: md, encoding: .utf8)) ?? ""
            let when = made[name] ?? (room == nil ? nil : (try? fm.attributesOfItem(atPath: p)[.creationDate] as? Date) ?? nil)
            out.append(SkillStar(name: name, about: about(text), room: room, made: when, mine: mine || made[name] != nil, path: p))
        }
        let engine = Env.hermesHome.appendingPathComponent("skills")
        if let e = fm.enumerator(at: engine, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent == "SKILL.md" { add(u, room: nil, mine: false) }
        }
        for room in RoomMap.roomFolders() {
            let dir = room.appendingPathComponent("skills/learned")
            for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !n.hasPrefix(".") {
                let md = dir.appendingPathComponent(n).appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: md.path) { add(md, room: RoomMap.roomTitle(room), mine: true) }
            }
        }
        return out.sorted { a, b in
            if a.mine != b.mine { return a.mine }
            return (a.made ?? .distantPast) > (b.made ?? .distantPast)
        }
    }

    /// The `description:` line of a skill, without the "Use when" boilerplate.
    static func about(_ text: String) -> String {
        for l in text.split(separator: "\n").prefix(15) where l.hasPrefix("description:") {
            var d = l.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            d = d.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return d
        }
        return ""
    }

    static func plainName(_ n: String) -> String {
        let s = n.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: Dates in plain words

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func sameDay(_ a: Date, _ b: Date) -> Bool { Calendar.current.isDate(a, inSameDayAs: b) }
    static func clock(_ m: Int) -> String {
        let h = (m / 60) % 24
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m % 60, h < 12 ? "AM" : "PM")
    }
    static func list(_ xs: [String]) -> String {
        if xs.count <= 1 { return xs.first ?? "" }
        return xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }
    /// "today", "yesterday", "tomorrow", "Sun Nov 1".
    static func day(_ d: Date, now: Date, lower: Bool = true) -> String {
        let cal = Calendar.current
        var w: String
        if cal.isDate(d, inSameDayAs: now) {
            w = "Today"
        } else if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) {
            w = "Yesterday"
        } else if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) {
            w = "Tomorrow"
        } else {
            let f = DateFormatter()
            f.dateFormat = "EEE MMM d"
            return f.string(from: d)
        }
        return lower ? w.lowercased() : w
    }
    /// "Today 9:30 AM", "Yesterday 8:24 PM", "Sun Nov 1, 6:00 PM".
    static func stamp(_ d: Date, now: Date) -> String {
        let dd = day(d, now: now, lower: false)
        return dd + (dd.contains(" ") ? ", " : " ") + clock(minutes(d))
    }
}
