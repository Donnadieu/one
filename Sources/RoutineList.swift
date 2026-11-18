import Foundation

// MARK: - The routines list on the right of the Routines panel: every routine in groups that fold, each with a count.
// Grouped by who it's for (the assistant, each room, each bot, a Hermes outside One) or by how often it runs. Routines
// that look done ("Looks done") and the finished ones get their own quiet groups at the end, where they can be cleared.

enum RoutineList {
    enum By: String, CaseIterable { case who, often }

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        var rows: [Routine]
        var tint: UInt32? = nil
        /// Leftovers and finished ones: quiet, and they can all be cleared at once (after a yes).
        var clearable = false
    }

    static let leftoverID = "looks-done"
    static let finishedID = "finished"

    /// `bot`: the bot a routine belongs to (id, name, colour), if any. `me`: the assistant's name.
    static func groups(_ rs: [Routine], by: By, me: String, bot: (Routine) -> (id: String, name: String, tint: UInt32)?) -> [Group] {
        var out: [Group] = []
        func add(_ id: String, _ title: String, _ r: Routine, tint: UInt32? = nil, clearable: Bool = false) {
            if let i = out.firstIndex(where: { $0.id == id }) {
                out[i].rows.append(r)
            } else {
                out.append(Group(id: id, title: title, rows: [r], tint: tint, clearable: clearable))
            }
        }
        var tail: [(String, String, Routine)] = []
        // A routine renewed with Run again comes back under a new id: its finished copy steps aside (as on the dial).
        let active = Set(rs.filter { $0.state != .finished && !$0.outside }.map(\.title))
        for r in rs {
            if r.state == .finished && active.contains(r.title) { continue }
            if r.state == .finished {
                tail.append((finishedID, "Finished", r))
                continue
            }
            if r.leftover != nil {
                tail.append((leftoverID, "Looks done", r))
                continue
            }
            switch by {
            case .who:
                if r.outside {
                    add("outside", "Runs outside One", r)
                } else if let b = bot(r) {
                    add("bot:" + b.id, b.name, r, tint: b.tint)
                } else if let room = r.room {
                    add("room:" + room, room, r)
                } else {
                    add("me", me, r)
                }
            case .often:
                let k = often(r)
                add("often:" + k.rawValue, k.title, r)
            }
        }
        // Who: the assistant first, then rooms, bots, outside. How often: most often first.
        let rank: (Group) -> Int = { g in
            switch by {
            case .who: return g.id == "me" ? 0 : g.id.hasPrefix("room:") ? 1 : g.id.hasPrefix("bot:") ? 2 : 3
            case .often: return Often.allCases.firstIndex { "often:" + $0.rawValue == g.id } ?? 9
            }
        }
        out = out.enumerated().sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }.map(
            \.element)
        for (id, title, r) in tail where id == leftoverID { add(id, title, r, clearable: true) }  // looks done, then finished
        for (id, title, r) in tail where id == finishedID { add(id, title, r, clearable: true) }
        return out.map { g in
            var g = g
            g.rows.sort(by: order)
            return g
        }
    }

    /// Needs a look first, then the next to run.
    static func order(_ a: Routine, _ b: Routine) -> Bool {
        if a.needsLook != b.needsLook { return a.needsLook }
        if a.state == .finished { return (a.lastRun ?? .distantPast) > (b.lastRun ?? .distantPast) }
        return (a.next ?? .distantFuture) < (b.next ?? .distantFuture)
    }

    enum Often: String, CaseIterable {
        case minutes, daily, weekly, once, paused
        var title: String {
            switch self {
            case .minutes: return "Every hour or more"
            case .daily: return "Every day"
            case .weekly: return "Some days of the week"
            case .once: return "Once"
            case .paused: return "Paused"
            }
        }
    }

    static func often(_ r: Routine) -> Often {
        if r.state == .paused { return .paused }
        if r.every != nil { return .minutes }
        if r.once || r.often.hasPrefix("Once") { return .once }
        if r.often.hasPrefix("Every day") { return .daily }
        return .weekly
    }

    /// The row's second line: next run and last result, or paused / finished / looks done.
    static func status(_ r: Routine, now: Date) -> String {
        if r.state == .finished { return Routines.finishedLine(r) }
        if r.state == .paused { return "Paused" + (r.lastRun.map { " · last ran " + Routines.day($0, now: now) } ?? "") }
        if r.state == .running { return "Running now" }
        var s = r.every.map { Routines.every($0) } ?? r.next.map { "Next " + short($0, now: now) } ?? "Not again"
        if r.state == .never { return s + " · never ran yet" }
        s += " · last " + (r.state == .worked ? "done" : Routines.missWord(r))
        return s
    }

    /// "today 9:00 AM", "Sun 10:00 AM", "Nov 30 9:00 AM".
    static func short(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let t = Routines.clock(Routines.minutes(d))
        if cal.isDate(d, inSameDayAs: now) { return "today " + t }
        if let tm = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tm) { return "tomorrow " + t }
        let f = DateFormatter()
        f.dateFormat = d.timeIntervalSince(now) < 6 * 86400 ? "EEE" : "MMM d"
        return f.string(from: d) + " " + t
    }

    /// The groups folded at first: with a short list, only the quiet ones; with a long list, all but those holding
    /// something that needs a look, so the list starts as a few lines with counts.
    static func folded(_ gs: [Group]) -> Set<String> {
        let total = gs.reduce(0) { $0 + $1.rows.count }
        if total <= 12 { return Set(gs.filter(\.clearable).map(\.id)) }
        return Set(gs.filter { g in g.clearable || !g.rows.contains(where: \.needsLook) }.map(\.id))
    }

    /// The engine command that removes a routine for good (asked first, on its card or its group).
    static func removeSteps(_ r: Routine) -> [String] { ["cron", "remove", r.id] }
}
