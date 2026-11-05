import Foundation

// MARK: - One gets better by itself, step 1: the score (look-only)
// Once a day One reads its own records (never writing them) and writes `improve/days/<date>.json`: where the person
// corrected it, where a job broke or was cut off, where it hit a wall, where a job took far too long, and health
// warnings. From those it keeps `improve/score.jsonl` (a line a day) and `improve/weeks.jsonl` (a line a week).
// Nothing here changes a skill, a note or a setting. The nightly review (later steps) reads these through
// `One --improve …`. Design: Made by Iris, "2026-11-05 One gets better by itself - design.md", sections 3a, 5, 6.

/// One thing the collector found.
struct ImproveEvent: Codable, Equatable {
    var kind: String  // correction | broke | wall | slow | health
    var sub: String
    var time: String  // ISO 8601, local offset
    var ts: Double
    var session: String?
    var title: String?
    var jobKind: String?
    var place: String?
    var quote: String?  // at most 200 characters, never from a private conversation
    var msg: Int?  // the row in the engine's history, for moments
    var isPrivate: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, time, ts, place, quote, msg
        case sub = "sub_kind"
        case session = "session_id"
        case title = "job_title"
        case jobKind = "job_kind"
        case isPrivate = "private"
    }

    init(
        _ kind: String, _ sub: String, at ts: Double, session: String? = nil, title: String? = nil, jobKind: String? = nil,
        place: String? = nil, quote: String? = nil, msg: Int? = nil
    ) {
        self.kind = kind
        self.sub = sub
        self.ts = ts
        self.time = Improve.iso(ts)
        self.session = session
        self.title = title
        self.jobKind = jobKind
        self.place = place
        self.quote = quote.map { Improve.short($0, 200) }
        self.msg = msg
    }
    var key: String { "\(kind)/\(sub)" }
}

/// A signal far above its usual daily level (like 83 cut-off replies in one day): one record, not many events.
struct ImproveIncident: Codable, Equatable {
    var kind: String
    var sub: String
    var count: Int
    var usual: Double
    var first: String
    var last: String
    var sessions: [String]
    var quote: String?

    enum CodingKeys: String, CodingKey {
        case kind, count, usual, first, last, sessions, quote
        case sub = "sub_kind"
    }
}

struct ImproveDay: Codable {
    var date: String
    var collected: String
    var counts: [String: Int]  // see `ImproveCount`
    var signals: [String: Int]  // events per "kind/sub" before incidents were folded (the usual level)
    var kinds: [String: [Int]]  // job kind: [helpers, right the first time]
    var events: [ImproveEvent]
    var incidents: [ImproveIncident]
}

/// The names of the day's counts.
enum ImproveCount {
    static let said = "said", corrections = "corrections", statedRules = "stated_rules", stops = "stops", redos = "redos"
    static let undos = "undos", helpers = "helpers", right = "right_first_time", over30 = "helpers_over_30_min"
    static let cutOff = "cut_off", pickedBack = "picked_back_up", engineStops = "engine_stops", helperFailed = "helpers_failed"
    /// Helpers picked back up whose conversation shows no cut-off reply that day (so one cut isn't counted twice).
    static let pickedAlone = "picked_back_up_alone"
    static let notDone = "routines_not_done", partly = "routines_partly", routineFailed = "routines_failed"
    static let steps = "steps", failedSteps = "failed_steps", streaks = "failed_streaks", repeats = "repeated_steps"
    static let handoffs = "handoffs", answered = "handoffs_answered", folderLock = "folder_lock", signedOut = "signed_out"
    static let rateLimits = "rate_limits", slowHelpers = "slow_helpers", manySteps = "many_steps", timeouts = "command_timeouts"
    static let sameAgain = "same_mistake_again"
}

/// The review's own settings (`improve/settings.json`). Step 1 only reads and shows them.
struct ImproveSettings: Codable, Equatable {
    var mode = "suggest"  // suggest | edit
    var maxEditsPerNight = 5
    var maxEditsPerSkill = 1
    var snapshotFirst = true
    var autoUndoOnDrop = true

    enum CodingKeys: String, CodingKey {
        case mode
        case maxEditsPerNight = "max_edits_per_night"
        case maxEditsPerSkill = "max_edits_per_skill"
        case snapshotFirst = "snapshot_first"
        case autoUndoOnDrop = "auto_undo_on_drop"
    }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "suggest"
        maxEditsPerNight = (try? c.decode(Int.self, forKey: .maxEditsPerNight)) ?? 5
        maxEditsPerSkill = (try? c.decode(Int.self, forKey: .maxEditsPerSkill)) ?? 1
        snapshotFirst = (try? c.decode(Bool.self, forKey: .snapshotFirst)) ?? true
        autoUndoOnDrop = (try? c.decode(Bool.self, forKey: .autoUndoOnDrop)) ?? true
    }
}

enum Improve {
    static var dir: URL { Env.support.appendingPathComponent("improve", isDirectory: true) }
    static var daysDir: URL { dir.appendingPathComponent("days", isDirectory: true) }
    static var scoreFile: URL { dir.appendingPathComponent("score.jsonl") }
    static var weeksFile: URL { dir.appendingPathComponent("weeks.jsonl") }
    static var lessonsFile: URL { dir.appendingPathComponent("lessons.jsonl") }
    static var settingsFile: URL { dir.appendingPathComponent("settings.json") }
    static var stateDB: String { Env.hermesHome.appendingPathComponent("state.db").path }

    // MARK: Dates (the person's own days)

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
    static func day(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key).map { Calendar.current.startOfDay(for: $0) }
    }
    static func dayKey(ts: Double) -> String { dayKey(Date(timeIntervalSince1970: ts)) }
    static func iso(_ ts: Double) -> String {
        ISO8601DateFormatter.string(
            from: Date(timeIntervalSince1970: ts), timeZone: .current, formatOptions: [.withInternetDateTime])
    }
    /// ISO week, e.g. "2026-W45" (Monday to Sunday).
    static func weekKey(_ dayKey: String) -> String {
        guard let d = day(dayKey) else { return "" }
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        let p = c.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return String(format: "%04d-W%02d", p.yearForWeekOfYear ?? 0, p.weekOfYear ?? 0)
    }
    static func short(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return one.count <= n ? one : String(one.prefix(n - 1)) + "…"
    }

    // MARK: Files

    static func readDay(_ key: String) -> ImproveDay? {
        guard let d = try? Data(contentsOf: daysDir.appendingPathComponent("\(key).json")) else { return nil }
        return try? JSONDecoder().decode(ImproveDay.self, from: d)
    }
    static func writeDay(_ day: ImproveDay) {
        try? FileManager.default.createDirectory(at: daysDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(day).write(to: daysDir.appendingPathComponent("\(day.date).json"), options: .atomic)
    }
    static func dayKeys() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: daysDir.path)) ?? []).filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted()
    }

    static func settings() -> ImproveSettings {
        guard let d = try? Data(contentsOf: settingsFile) else { return ImproveSettings() }
        return (try? JSONDecoder().decode(ImproveSettings.self, from: d)) ?? ImproveSettings()
    }
    static func save(_ s: ImproveSettings) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: settingsFile, options: .atomic)
    }

    // MARK: Collect

    /// Collects every day from `from` to `to` (inclusive), then rewrites their score lines and weeks. Returns the days.
    @discardableResult
    static func collect(from: Date, to: Date) -> [ImproveDay] {
        var start = Calendar.current.startOfDay(for: from)
        let last = Calendar.current.startOfDay(for: to)
        var keys: [String] = []
        while start <= last {
            keys.append(dayKey(start))
            start = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? last.addingTimeInterval(86400)
        }
        guard let first = keys.first.flatMap(day), let end = keys.last.flatMap(day) else { return [] }
        let built = ImproveCollect.run(from: first.timeIntervalSince1970, to: end.addingTimeInterval(86400).timeIntervalSince1970, days: keys)
        let days = ImproveScore.foldIncidents(built)
        for d in days { writeDay(d) }
        ImproveScore.write(days: days.map(\.date))
        return days
    }

    /// The default range: from the last day already collected (or 14 days back) through today.
    static func defaultSince() -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        let floor = Calendar.current.date(byAdding: .day, value: -14, to: today) ?? today
        guard let lastKey = dayKeys().last, let last = day(lastKey) else { return floor }
        return max(floor, min(last, Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today))
    }

    // MARK: Once a day, by itself

    nonisolated(unsafe) private static var running = false
    static var stampFile: URL { dir.appendingPathComponent(".collected") }
    static let firstTend = Date()  // set on the first call, right after launch

    /// Called from the app's every-few-seconds loop: once a day (a few minutes after launch, in the background) the
    /// collector runs on its own, so the score exists even without the nightly routine. Seconds of work, no AI.
    static func tend() {
        guard !Env.selfTest, !Env.commandLine, !running, Date().timeIntervalSince(firstTend) > 180 else { return }
        let today = dayKey(Date())
        guard (try? String(contentsOf: stampFile, encoding: .utf8)) != today else { return }
        running = true
        Task.detached(priority: .background) {
            collect(from: defaultSince(), to: Date())
            try? today.write(to: stampFile, atomically: true, encoding: .utf8)
            running = false
        }
    }
}
