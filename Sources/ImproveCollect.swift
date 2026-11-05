import Foundation
import SQLite3

// MARK: - The collector: the engine's history (state.db), opened read-only
// The engine writes state.db all the time (WAL mode). One opens it read-only (`mode=ro`, `query_only`), never
// writes, never checkpoints, and reads only the conversations active in the days asked for.

/// A read-only connection to an SQLite file.
final class ReadOnlyDB {
    private var db: OpaquePointer?

    /// A WAL file with no `-wal` beside it means nobody is writing: then (and only then) it's read as immutable,
    /// because a read-only connection can't create the `-shm` file it would otherwise need.
    init?(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let base = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        let quiet = !FileManager.default.fileExists(atPath: path + "-wal")
        for q in quiet ? ["?mode=ro&immutable=0", "?mode=ro&immutable=1"] : ["?mode=ro&immutable=0"] {
            guard sqlite3_open_v2(base + q, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                sqlite3_exec(db, "PRAGMA query_only=1; SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK
            else {
                sqlite3_close(db)
                db = nil
                continue
            }
            sqlite3_busy_timeout(db, 5000)
            return
        }
        return nil
    }
    deinit { sqlite3_close(db) }

    /// Runs `sql` with `?` bindings (String, Double or Int) and calls `row` for each result.
    func each(_ sql: String, _ args: [Any] = [], _ row: (OpaquePointer) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            sqlite3_finalize(st)
            return
        }
        defer { sqlite3_finalize(st) }
        let keep = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            switch a {
            case let s as String: sqlite3_bind_text(st, Int32(i + 1), s, -1, keep)
            case let d as Double: sqlite3_bind_double(st, Int32(i + 1), d)
            case let n as Int: sqlite3_bind_int64(st, Int32(i + 1), Int64(n))
            default: sqlite3_bind_null(st, Int32(i + 1))
            }
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }
    static func text(_ st: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
    static func num(_ st: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(st, i) }
}

/// One message row.
struct ImproveRow {
    var id: Int
    var role: String
    var content: String
    var calls: String
    var ts: Double
}

/// A day being built.
struct ImproveDayBuild {
    var counts: [String: Int] = [:]
    var kinds: [String: [Int]] = [:]
    var events: [ImproveEvent] = []
    mutating func add(_ k: String, _ n: Int = 1) { counts[k, default: 0] += n }
}

enum ImproveCollect {
    /// A helper's length and steps, for "far too long compared with similar jobs".
    struct Past {
        var started: Double
        var minutes: Double?
        var steps: Int
        var kind: String
    }

    /// Builds each day in `days` (keys) from `from` to `to` (Unix seconds). Incidents are folded afterwards.
    static func run(from: Double, to: Double, days: [String]) -> [ImproveDay] {
        var build = Dictionary(uniqueKeysWithValues: days.map { ($0, ImproveDayBuild()) })
        let jobs = ImproveFiles.jobs()
        let titles = Dictionary(jobs.map { ($0.session, $0.title) }, uniquingKeysWith: { a, _ in a })
        var fileEvents = ImproveFiles.events(from: from, to: to, jobs: jobs)
        let now = Date().timeIntervalSince1970
        if now >= from && now < to + 86400 { fileEvents += ImproveFiles.health(now: min(now, to - 1)) }
        // Sessions the person "un-did" without words: stopped, sent again, picked back up, failed.
        var spoiled = Set<String>()
        for e in fileEvents {
            if let s = e.session, ["stopped", "redo", "picked_back_up", "helper_failed"].contains(e.sub) { spoiled.insert(s) }
        }
        let paths = ImprovePrivate.paths
        if let db = ReadOnlyDB(Improve.stateDB) {
            let past = history(db, before: to)
            var ids: [(String, String, Double, String, Int)] = []
            db.each(
                "select s.id, s.source, s.started_at, coalesce(s.title,''), coalesce(s.tool_call_count,0) from sessions s where s.started_at >= ?1 and s.started_at < ?2 "
                    + "or s.id in (select distinct session_id from messages where timestamp >= ?1 and timestamp < ?2) order by s.started_at",
                [from, to]
            ) { st in
                ids.append(
                    (
                        ReadOnlyDB.text(st, 0) ?? "", ReadOnlyDB.text(st, 1) ?? "", ReadOnlyDB.num(st, 2), ReadOnlyDB.text(st, 3) ?? "",
                        Int(sqlite3_column_int64(st, 4))
                    ))
            }
            for (sid, source, started, title, toolCalls) in ids {
                var rows: [ImproveRow] = []
                db.each(
                    "select id, role, coalesce(content,''), coalesce(tool_calls,''), timestamp from messages where session_id=? order by id", [sid]
                ) { st in
                    rows.append(
                        ImproveRow(
                            id: Int(sqlite3_column_int64(st, 0)), role: ReadOnlyDB.text(st, 1) ?? "", content: ReadOnlyDB.text(st, 2) ?? "",
                            calls: ReadOnlyDB.text(st, 3) ?? "", ts: ReadOnlyDB.num(st, 4)))
                }
                let name = titles[sid] ?? (title.isEmpty ? nil : title)
                session(
                    sid, source: source, started: started, title: name, rows: rows, from: from, to: to, past: past, toolCalls: toolCalls,
                    spoiled: spoiled.contains(sid),
                    paths: paths, into: &build)
            }
        }
        for e in fileEvents {
            let k = Improve.dayKey(ts: e.ts)
            guard build[k] != nil else { continue }
            build[k]!.events.append(e)
            let c: [String: String] = [
                "stopped": ImproveCount.stops, "redo": ImproveCount.redos, "undo": ImproveCount.undos, "helper_failed": ImproveCount.helperFailed,
                "engine_stop": ImproveCount.engineStops, "handoff": ImproveCount.handoffs,
                "handoff_answered": ImproveCount.handoffs, "routine_not_done": ImproveCount.notDone, "routine_partly": ImproveCount.partly,
                "routine_failed": ImproveCount.routineFailed,
            ]
            if let key = c[e.sub] { build[k]!.add(key) }
            if e.sub == "handoff_answered" { build[k]!.add(ImproveCount.answered) }
        }
        let lessons = ImproveScore.sameAgain(days)
        let stamp = Improve.iso(now)
        return days.map { k in
            var b = build[k] ?? ImproveDayBuild()
            b.counts[ImproveCount.sameAgain] = lessons[k] ?? 0
            b.events.sort { $0.ts < $1.ts }
            let signals = Dictionary(grouping: b.events.filter { $0.kind != "health" }, by: \.key).mapValues(\.count)
            return ImproveDay(date: k, collected: stamp, counts: b.counts, signals: signals, kinds: b.kinds, events: b.events, incidents: [])
        }
    }

    /// The first skill a helper opened: its kind of job ("other" when it opened none).
    static func kind(_ rows: [ImproveRow]) -> String {
        for r in rows where r.role == "assistant" && r.calls.contains("skill_view") {
            for (n, a) in calls(r.calls) where n == "skill_view" {
                if let d = a.data(using: .utf8), let name = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["name"] as? String {
                    return name
                }
            }
        }
        return "other"
    }
    /// A helper's first full answer: words, no steps, over 200 characters.
    static func answered(_ rows: [ImproveRow]) -> Double? {
        rows.first { $0.role == "assistant" && $0.content.count > 200 && ($0.calls.isEmpty || $0.calls == "[]") }?.ts
    }

    /// Every helper started in the 45 days before `to`: length, steps and kind (for "similar past jobs").
    static func history(_ db: ReadOnlyDB, before to: Double) -> [Past] {
        var out: [Past] = []
        var answers: [String: Double] = [:]
        db.each(
            "select session_id, min(timestamp) from messages where role='assistant' and length(content) > 200 and (tool_calls is null or tool_calls='' or tool_calls='[]') "
                + "and timestamp >= ? and timestamp < ? group by session_id", [to - 45 * 86400, to]
        ) { st in answers[ReadOnlyDB.text(st, 0) ?? ""] = ReadOnlyDB.num(st, 1) }
        var kinds: [String: String] = [:]
        db.each(
            "select m.session_id, json_extract(j.value,'$.function.arguments') from messages m, json_each(m.tool_calls) j where m.role='assistant' "
                + "and m.tool_calls like '%skill_view%' and m.timestamp >= ? and m.timestamp < ? and json_extract(j.value,'$.function.name')='skill_view' order by m.id",
            [to - 45 * 86400, to]
        ) { st in
            let sid = ReadOnlyDB.text(st, 0) ?? ""
            guard kinds[sid] == nil, let a = ReadOnlyDB.text(st, 1)?.data(using: .utf8),
                let n = ((try? JSONSerialization.jsonObject(with: a)) as? [String: Any])?["name"] as? String
            else { return }
            kinds[sid] = n
        }
        db.each(
            "select s.id, s.started_at, s.tool_call_count from sessions s where s.started_at >= ? and s.started_at < ? and s.source in ('acp','local') "
                + "and (select substr(content,1,80) from messages m where m.session_id=s.id and m.role='user' order by m.id limit 1) like 'You''re one of%helpers%'",
            [to - 45 * 86400, to]
        ) { st in
            let sid = ReadOnlyDB.text(st, 0) ?? ""
            let t = ReadOnlyDB.num(st, 1)
            out.append(
                Past(started: t, minutes: answers[sid].map { ($0 - t) / 60 }, steps: Int(sqlite3_column_int64(st, 2)), kind: kinds[sid] ?? "other"))
        }
        return out
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// What's usual for a job like this one: similar (same kind) past jobs, at least 3, else every past helper (at least 5).
    static func usual(_ past: [Past], kind: String, before t: Double, _ value: (Past) -> Double?) -> Double? {
        let earlier = past.filter { $0.started < t }
        let same = earlier.filter { $0.kind == kind }.compactMap(value)
        if same.count >= 3 { return median(same) }
        let all = earlier.compactMap(value)
        return all.count >= 5 ? median(all) : nil
    }

    /// Reads one conversation into the days it touches.
    static func session(
        _ sid: String, source: String, started: Double, title: String?, rows: [ImproveRow], from: Double, to: Double, past: [Past],
        toolCalls: Int, spoiled: Bool, paths: [String], into build: inout [String: ImproveDayBuild]
    ) {
        let first = rows.first { $0.role == "user" }?.content ?? ""
        let place = JobPlace.of(source: source, first: first)
        let jobKind = place == .helper ? kind(rows) : nil
        let job = title ?? (place == .helper ? (first.range(of: "The job: ").map { Improve.short(String(first[$0.upperBound...]), 60) }) : nil)
        // Private: the person's words, the assistant's words, a step it took or a file it read mention a private place.
        let isPrivate = ImprovePrivate.conversation(rows, paths)
        func event(_ kind: String, _ sub: String, _ r: ImproveRow, _ quote: String?) -> ImproveEvent {
            var e = ImproveEvent(
                kind, sub, at: r.ts, session: sid, title: job, jobKind: jobKind, place: place.rawValue, quote: isPrivate ? nil : quote, msg: r.id)
            if isPrivate { e.isPrivate = true }
            return e
        }
        var corrected = false
        var cut = false
        var picked = false
        var cutDays = Set<String>()  // days with a reply cut off by an engine shutdown
        var pickedDays = Set<String>()  // days this conversation was picked back up after a restart
        var prev = ""  // the last message with words: "user" or "assistant"
        var streak = 0
        var lastCall: String?
        for r in rows {
            let k = Improve.dayKey(ts: r.ts)
            let inside = r.ts >= from && r.ts < to && build[k] != nil
            switch r.role {
            case "assistant":
                if r.content.hasPrefix(StepCheck.cutOff) {
                    cut = true
                    cutDays.insert(k)
                    if inside {
                        build[k]!.add(ImproveCount.cutOff)
                        build[k]!.events.append(event("broke", "cut_off", r, nil))
                    }
                }
                if !r.calls.isEmpty && r.calls != "[]" {
                    for call in calls(r.calls) {
                        if StepCheck.polling.contains(call.0) {
                            lastCall = nil
                            continue
                        }
                        let sig = call.0 + "|" + call.1
                        if sig == lastCall, inside {
                            build[k]!.add(ImproveCount.repeats)
                            build[k]!.events.append(event("broke", "repeated_step", r, "\(call.0) called twice in a row"))
                        }
                        lastCall = sig
                    }
                } else {
                    prev = "assistant"
                }
            case "user":
                defer { prev = "user" }
                // One picked the helper back up after a restart (once a conversation a day).
                if r.content.hasPrefix(StepCheck.pickedBack), place == .helper || place == .resumed {
                    if inside, pickedDays.insert(k).inserted {
                        build[k]!.add(ImproveCount.pickedBack)
                        build[k]!.events.append(event("broke", "picked_back_up", r, nil))
                    }
                    picked = true
                    continue
                }
                guard place.personTalks, let said = Corrections.clean(r.content) else { continue }
                if inside { build[k]!.add(ImproveCount.said) }
                if prev == "assistant", let c = Corrections.find(r.content) {
                    corrected = true
                    if inside {
                        build[k]!.add(ImproveCount.corrections)
                        if c == .statedRule { build[k]!.add(ImproveCount.statedRules) }
                        build[k]!.events.append(event("correction", c.rawValue, r, said))
                    }
                }
            case "tool":
                guard inside else { continue }
                build[k]!.add(ImproveCount.steps)
                if StepCheck.timedOut(r.content) {
                    build[k]!.add(ImproveCount.timeouts)
                    build[k]!.events.append(event("slow", "command_timeout", r, Improve.short(r.content, 160)))
                }
                guard StepCheck.failed(r.content) else {
                    streak = 0
                    continue
                }
                build[k]!.add(ImproveCount.failedSteps)
                streak += 1
                if streak == 3 {
                    build[k]!.add(ImproveCount.streaks)
                    build[k]!.events.append(event("broke", "failed_steps", r, "3 failed steps in a row"))
                }
                if let w = StepCheck.wall(r.content) {
                    build[k]!.add(w == "folder_lock" ? ImproveCount.folderLock : w == "signed_out" ? ImproveCount.signedOut : ImproveCount.rateLimits)
                    build[k]!.events.append(event("wall", w, r, Improve.short(r.content, 200)))
                }
            default: break
            }
        }
        // A pick-back-up counts toward "cut off" only when no reply of this conversation was cut off that day.
        for d in pickedDays.subtracting(cutDays) where build[d] != nil { build[d]!.add(ImproveCount.pickedAlone) }
        // A helper counts on the day it started: right the first time, too long, too many steps.
        let day = Improve.dayKey(ts: started)
        guard place == .helper, started >= from, started < to, build[day] != nil else { return }
        let right = !corrected && !cut && !picked && !spoiled
        build[day]!.add(ImproveCount.helpers)
        if right { build[day]!.add(ImproveCount.right) }
        let jk = jobKind ?? "other"
        var tally = build[day]!.kinds[jk] ?? [0, 0]
        tally[0] += 1
        if right { tally[1] += 1 }
        build[day]!.kinds[jk] = tally
        let minutes = answered(rows).map { ($0 - started) / 60 }
        let steps = toolCalls
        let at = ImproveRow(id: rows.first?.id ?? 0, role: "user", content: "", calls: "", ts: started)
        if let m = minutes {
            if m > 30 { build[day]!.add(ImproveCount.over30) }
            if m > 15, let u = usual(past, kind: jk, before: started, { $0.minutes }), m > 3 * u {
                build[day]!.add(ImproveCount.slowHelpers)
                build[day]!.events.append(event("slow", "helper_long", at, "took \(Int(m)) min; similar jobs take about \(Int(u.rounded())) min"))
            }
        }
        if steps >= 20, let u = usual(past, kind: jk, before: started, { Double($0.steps) }), Double(steps) > 2 * u {
            build[day]!.add(ImproveCount.manySteps)
            build[day]!.events.append(event("slow", "many_steps", at, "\(steps) steps; similar jobs take about \(Int(u.rounded()))"))
        }
    }

    /// The (tool name, arguments) pairs in an assistant row's tool calls.
    static func calls(_ json: String) -> [(String, String)] {
        guard let d = json.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let f = c["function"] as? [String: Any], let n = f["name"] as? String else { return nil }
            return (n, (f["arguments"] as? String) ?? "")
        }
    }
}
