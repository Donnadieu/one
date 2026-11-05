import Foundation
import SQLite3

// MARK: - Moments for the nightly review, and `One --improve …`
// For each event the review reads only the moment around it: the 2 replies before and the 2 after, each trimmed.
// Never whole conversations, and never anything from a private conversation (Nyx, a locked drawer, a shared room).

enum ImproveMoments {
    static let names: [String: String] = [
        "correction/phrase": "Correction", "correction/stated_rule": "Their own rule (always / never)",
        "correction/stopped": "They stopped a helper", "correction/redo": "The same job sent again within 2 hours",
        "correction/undo": "Undo on something it learned", "broke/cut_off": "A reply cut off by an engine shutdown",
        "broke/picked_back_up": "A helper picked back up after a restart", "broke/helper_failed": "A helper stopped by an error",
        "broke/engine_stop": "The engine shut down", "broke/routine_not_done": "A routine report: not done",
        "broke/routine_partly": "A routine report: partly done", "broke/routine_failed": "A routine failed",
        "broke/failed_steps": "3 failed steps in a row", "broke/repeated_step": "The same step twice in a row",
        "wall/handoff": "A step only they could do (not answered)", "wall/handoff_answered": "A step only they could do",
        "wall/folder_lock": "The folder lock said no", "wall/signed_out": "Signed out or an expired sign-in",
        "wall/rate_limit": "A rate limit", "slow/helper_long": "A job far longer than similar ones",
        "slow/many_steps": "Far more steps than similar jobs", "slow/command_timeout": "A command hit the time limit",
    ]
    static func name(_ key: String) -> String { names[key] ?? key }

    /// Which events come first when there are more than `max`: their words, then incidents, then the rest.
    static func rank(_ e: ImproveEvent) -> Int {
        switch e.key {
        case "correction/stated_rule": return 0
        case "correction/phrase": return 1
        case _ where e.kind == "correction": return 2
        case _ where e.kind == "broke": return 4
        case _ where e.kind == "wall": return 5
        default: return 6
        }
    }

    /// The markdown the nightly review reads for one day.
    static func render(date: String, max: Int) -> String {
        guard let day = Improve.readDay(date) else { return "No moments for \(date): run `One --improve collect --date \(date)` first.\n" }
        let db = ReadOnlyDB(Improve.stateDB)
        let paths = ImprovePrivate.paths
        var out = "# Moments, \(date)\n\n"
        var skipped = 0
        var n = 0
        for inc in day.incidents where n < max {
            n += 1
            out += "## \(n). Incident: \(name(inc.kind + "/" + inc.sub)), \(inc.count) times (usually about \(Int(inc.usual.rounded())) a day)\n\n"
            out +=
                "From \(inc.first) to \(inc.last), in \(inc.sessions.count) conversation\(inc.sessions.count == 1 ? "" : "s"). One cause, one fix: not a lesson per event.\n"
            if let q = inc.quote, !ImprovePrivate.touches(q, paths) { out += "\n> \(q)\n" }
            out += "\n"
        }
        let events = day.events.filter { $0.kind != "health" }.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        var cache: [String: [ImproveRow]] = [:]
        for e in events where n < max {
            var rows: [ImproveRow] = []
            if let s = e.session {
                if cache[s] == nil, let db { cache[s] = load(db, s) }
                rows = cache[s] ?? []
                if e.isPrivate == true || ImprovePrivate.conversation(rows, paths) {
                    skipped += 1
                    continue
                }
            }
            if let q = e.quote, ImprovePrivate.touches(q, paths) {
                skipped += 1
                continue
            }
            n += 1
            let who = [e.place, e.title.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            out += "## \(n). \(name(e.key))\(who.isEmpty ? "" : " · \(who)") · \(e.time)\n\n"
            let ids = [e.session.map { "conversation `\($0)`" }, e.jobKind.map { "job kind: \($0)" }, e.msg.map { "row \($0)" }].compactMap { $0 }
            if !ids.isEmpty { out += ids.joined(separator: " · ") + "\n\n" }
            let lines = around(rows, e, paths)
            if lines.isEmpty, let q = e.quote { out += "> \(q)\n" }
            out += lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
            out += "\n"
        }
        let health = day.events.filter { $0.kind == "health" }
        if !health.isEmpty {
            out += "## Health\n\n" + health.map { "- \(Improve.short($0.quote ?? $0.sub, 200))" }.joined(separator: "\n") + "\n\n"
        }
        if n == 0 && health.isEmpty { out += "Nothing to look at.\n" }
        if skipped > 0 { out += "(\(skipped) moment\(skipped == 1 ? "" : "s") left out: private conversations.)\n" }
        return out
    }

    static func load(_ db: ReadOnlyDB, _ sid: String) -> [ImproveRow] {
        var rows: [ImproveRow] = []
        db.each("select id, role, coalesce(content,''), coalesce(tool_calls,''), timestamp from messages where session_id=? order by id", [sid]) {
            st in
            rows.append(
                ImproveRow(
                    id: Int(sqlite3_column_int64(st, 0)), role: ReadOnlyDB.text(st, 1) ?? "", content: ReadOnlyDB.text(st, 2) ?? "",
                    calls: ReadOnlyDB.text(st, 3) ?? "", ts: ReadOnlyDB.num(st, 4)))
        }
        return rows
    }

    /// The 2 replies before the event and the 2 after (the event's own message marked), each trimmed to 300 characters.
    static func around(_ rows: [ImproveRow], _ e: ImproveEvent, _ paths: [String]) -> [String] {
        let replies: [(ImproveRow, String, String)] = rows.compactMap { r in
            if r.role == "assistant", !r.content.isEmpty { return (r, "Assistant", r.content) }
            if r.role == "user", let t = Corrections.clean(r.content) { return (r, "Person", t) }
            return nil
        }
        guard !replies.isEmpty else { return [] }
        let at = replies.lastIndex { r in e.msg.map { r.0.id <= $0 } ?? (r.0.ts <= e.ts) } ?? 0
        let lo = Swift.max(0, at - 2)
        let hi = Swift.min(replies.count - 1, at + 2)
        return (lo...hi).compactMap { i in
            let (r, who, text) = replies[i]
            guard !ImprovePrivate.touches(text, paths) else { return nil }
            let mark = r.id == e.msg ? "  ← this one" : ""
            return "- **\(who):** \(Improve.short(text, 300))\(mark)"
        }
    }
}

/// `One --improve collect|score|moments|settings`: used by the nightly review routine and the morning brief.
enum ImproveCLI {
    static func value(_ a: [String], _ flag: String) -> String? {
        guard let k = a.firstIndex(of: flag), k + 1 < a.count else { return nil }
        return a[k + 1]
    }

    /// Exit code, or nil when this isn't an improve call.
    static func run(_ args: [String]) -> Int32? {
        guard let k = args.firstIndex(of: "--improve") else { return nil }
        let a = Array(args[(k + 1)...])
        let usage =
            "usage: One --improve collect [--date YYYY-MM-DD | --since YYYY-MM-DD] | score [--week] | moments [--date D] [--max 20] | settings [show | set <key> <value>]"
        switch a.first ?? "" {
        case "collect":
            let today = Date()
            var from = Improve.defaultSince()
            var to = today
            if let d = value(a, "--date") {
                guard let day = Improve.day(d) else { return bad("not a date: \(d)") }
                (from, to) = (day, day)
            } else if let s = value(a, "--since") {
                guard let day = Improve.day(s) else { return bad("not a date: \(s)") }
                from = day
            }
            let days = Improve.collect(from: from, to: to)
            for d in days {
                let l = ImproveScore.line(d.date, [d], week: false)
                print(
                    "\(d.date): \(d.events.count) events, \(d.incidents.count) incidents · helpers \(l.helpers), right first time \(l.right) · "
                        + "corrections \(l.corrections) of \(l.said) messages · cut off \(l.cutOff) · walls \(l.walls) · slow \(l.slowJobs)")
            }
            print("saved in \(Improve.dir.path)")
            return 0
        case "score":
            ImproveScore.brief(lastWeek: a.contains("--week")).forEach { print($0) }
            return 0
        case "moments":
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            let date = value(a, "--date") ?? Improve.dayKey(yesterday)
            print(ImproveMoments.render(date: date, max: Int(value(a, "--max") ?? "") ?? 20), terminator: "")
            return 0
        case "settings":
            return settings(Array(a.dropFirst()))
        default:
            print(usage)
            return 2
        }
    }
    static func bad(_ s: String) -> Int32 {
        print(s)
        return 2
    }

    static func show(_ s: ImproveSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print((try? enc.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
    }

    /// `settings show` (default) or `settings set <key> <value>` (mode suggest|edit, max_edits_per_night, max_edits_per_skill,
    /// snapshot_first, auto_undo_on_drop).
    static func settings(_ a: [String]) -> Int32 {
        var s = Improve.settings()
        guard a.first == "set" else {
            show(s)
            return 0
        }
        guard a.count >= 3 else { return bad("usage: One --improve settings set <key> <value>") }
        let (key, v) = (a[1], a[2])
        switch key {
        case "mode":
            guard v == "suggest" || v == "edit" else { return bad("mode is suggest or edit") }
            s.mode = v
        case "max_edits_per_night", "max_edits_per_skill":
            guard let n = Int(v), n >= 0, n <= 50 else { return bad("\(key) is a number from 0 to 50") }
            if key == "max_edits_per_night" { s.maxEditsPerNight = n } else { s.maxEditsPerSkill = n }
        case "snapshot_first", "auto_undo_on_drop":
            guard v == "true" || v == "false" else { return bad("\(key) is true or false") }
            if key == "snapshot_first" { s.snapshotFirst = v == "true" } else { s.autoUndoOnDrop = v == "true" }
        default:
            return bad("unknown setting: \(key)")
        }
        Improve.save(s)
        show(s)
        return 0
    }
}
