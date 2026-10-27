import Foundation

// MARK: - Tell me when I learn
// The engine writes every skill change to one log, `<hermes home>/skills/.curator_ledger.jsonl`, with the
// skill, the kind of change and the chat it came from (the same chat id One keeps). One reads that log,
// never the skills folder (copies like the Skills sync never reach the log) and never the chat stream
// (the background review that makes most changes never reaches it).
// A new skill from one of One's chats: one line after the job, with Undo. A fix to a skill: nothing.
// A long or repeated job with nothing saved: ask once, about 2 minutes after it ended.

/// One line of the engine's skill log.
struct LedgerLine: Codable, Equatable {
    var id: String
    var ts: Date
    var actor: String
    var action: String
    var skill: String
    var session: String
    /// Files the change left behind (for a create: the new skill's files).
    var paths: [String]

    static let creates: Set<String> = ["create"]
    static let fixes: Set<String> = ["patch", "edit", "write_file", "remove_file"]

    /// The log's timestamps carry microseconds and a UTC offset; seconds are plenty here.
    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(s.prefix(19)))
    }

    static func parse(_ line: Substring) -> LedgerLine? {
        guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let id = j["id"] as? String, let ts = (j["ts"] as? String).flatMap(date)
        else { return nil }
        let ev = j["evidence"] as? [String: Any] ?? [:]
        let after = (j["after"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        return LedgerLine(
            id: id, ts: ts, actor: j["actor"] as? String ?? "", action: j["action"] as? String ?? "", skill: j["skill"] as? String ?? "",
            session: ev["session_id"] as? String ?? "", paths: after)
    }
}

/// One finished job (a turn of the main chat, or a helper's turn) that may have taught the assistant something.
struct LearnJob: Codable, Identifiable {
    var id = UUID()
    var session: String
    var helper: UUID?
    var kind: String
    var started: Date
    var ended: Date
    var steps: Int
    var usedSkill: Bool
    var failed: Bool
    var lines: [LedgerLine] = []
    /// open → learned (new skill) / fixed (silent) / asked / quiet (nothing to say) / dropped
    var state = "open"
}

struct LearnedSkill: Codable {
    var name: String
    var room: String?  // nil: in the engine's own skills folder (Undo uses the engine's rollback)
    var path: String  // its SKILL.md
    var ledgerIDs: [String] = []
    var fixes = 0
    var lastFix: Date?
    var card: UUID?
    var session: String?
}

/// Something One put in a chat that a tap answers: Undo, or Yes / No to "want me to remember?".
struct LearnOffer: Codable {
    var kind: String  // "undo" or "ask"
    var job: UUID
    var helper: UUID?
    var skills: [String] = []
    var line: String
    var made = Date()
}

struct LearningState: Codable {
    struct Thresholds: Codable {
        var toolSteps = 15  // Hermes's own creation_nudge_interval
        var minutes = 5.0
        var reviewWindowSeconds = 120.0  // the background review saved 8 to 41 s after a job on Omar's Mac
    }
    struct Declined: Codable {
        var kind: String
        var date: Date
    }
    var started = false
    var seenLedgerIDs: [String] = []
    var thresholds = Thresholds()
    var jobs: [LearnJob] = []
    var declinedKinds: [Declined] = []
    var learned: [LearnedSkill] = []
    var explainedSkill = false
    var offers: [LearnOffer] = []
    /// Log lines from One's chats that no finished job has taken yet (the job is still running).
    var pending: [LedgerLine] = []
}

/// What `Learning.evaluate` decided for a job.
enum LearnEvent {
    case learned(LearnJob, skills: [String])
    case ask(LearnJob)
    case undoQuietly(LearnJob, skills: [String])  // a skill saved for a kind of job they said no to
}

enum Learning {
    static var file: URL { Env.support.appendingPathComponent(Env.selfTest ? "selftest-learning.json" : "learning.json") }
    static var ledger: URL { Env.hermesHome.appendingPathComponent("skills/.curator_ledger.jsonl") }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-learning.log") }
    static let learnedLine = "I just learned how to do this, so next time it'll be faster."
    static let explain = "(A skill is a recipe I keep, so I don't have to figure it out from scratch.)"
    static let askLine = "Want me to remember how I did this? Next time it'll be faster and you won't have to explain it again."
    static let yes = "Yes, remember it"
    static let no = "No thanks"
    static let undo = "Undo"
    static let forgot = "Okay, I forgot that one."

    static func load() -> LearningState {
        guard let d = try? Data(contentsOf: file) else { return LearningState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(LearningState.self, from: d)) ?? LearningState()
    }
    static func save(_ s: LearningState) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: file, options: .atomic)
    }
    static func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    /// The review window; a test copy may shorten it (never the person's own One).
    static func window(_ s: LearningState) -> TimeInterval {
        if Env.selfTest, let w = ProcessInfo.processInfo.environment["ONE_LEARN_WINDOW"].flatMap(Double.init) { return w }
        return s.thresholds.reviewWindowSeconds
    }

    // MARK: Reading the log

    private nonisolated(unsafe) static var lastStamp: (Date, Int)?
    /// Every line of the log, or nil when it hasn't changed since the last read (or doesn't exist).
    static func readLedger(force: Bool = false) -> [LedgerLine]? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: ledger.path) else { return nil }
        let stamp = ((a[.modificationDate] as? Date) ?? .distantPast, (a[.size] as? Int) ?? 0)
        if !force, let l = lastStamp, l == stamp { return nil }
        lastStamp = stamp
        guard let t = try? String(contentsOf: ledger, encoding: .utf8) else { return nil }
        return t.split(separator: "\n").compactMap(LedgerLine.parse)
    }

    /// Takes new log lines into the state. Lines from chats One doesn't know are only marked seen.
    /// The first time ever, everything already there is marked seen, so old changes are never announced.
    static func take(_ lines: [LedgerLine], into s: inout LearningState, known: (String) -> String?) {
        var seen = Set(s.seenLedgerIDs)
        let fresh = lines.filter { !seen.contains($0.id) }
        fresh.forEach { seen.insert($0.id) }
        defer {
            // The log is trimmed past 5 MB: only ids still in it need remembering.
            let inLog = Set(lines.map(\.id))
            s.seenLedgerIDs = seen.filter { inLog.contains($0) }.sorted()
        }
        guard s.started else {
            s.started = true
            return
        }
        for var l in fresh {
            // A fix to a skill learned through One: counted for its card, never said in the chat.
            if LedgerLine.fixes.contains(l.action), let k = s.learned.firstIndex(where: { $0.name == l.skill }) {
                s.learned[k].fixes += 1
                s.learned[k].lastFix = l.ts
            }
            guard let chat = known(l.session) else { continue }
            l.session = chat
            s.pending.append(l)
        }
    }

    // MARK: Deciding

    static func words(_ kind: String) -> Set<String> {
        let stop: Set<String> = ["a", "an", "the", "for", "of", "to", "and", "my", "on", "in", "with", "up"]
        return Set(kind.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 && !stop.contains($0) })
    }
    /// Two kinds of job are the same when they share most of their words (0.5 or more).
    static func sameKind(_ a: String, _ b: String) -> Bool {
        let x = words(a)
        let y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.5
    }
    static func declined(_ kind: String, _ s: LearningState) -> Bool { s.declinedKinds.contains { sameKind($0.kind, kind) } }

    /// Was this a job worth asking about? Long (15 steps or 5 minutes), or the same kind came up before.
    static func worthAsking(_ j: LearnJob, _ s: LearningState) -> Bool {
        guard !j.failed, !j.usedSkill, !declined(j.kind, s) else { return false }
        if j.steps >= s.thresholds.toolSteps || j.ended.timeIntervalSince(j.started) >= s.thresholds.minutes * 60 { return true }
        let since = j.started.addingTimeInterval(-60 * 86400)
        return j.steps >= 3
            && s.jobs.contains { o in o.id != j.id && o.ended < j.started && o.ended > since && !o.failed && sameKind(o.kind, j.kind) }
    }

    /// Gives each finished job the log lines of its chat from its start to the end of the review window,
    /// then decides: new skill → learned (at once), only fixes → silent, nothing → maybe ask once the window closed.
    static func evaluate(_ s: inout LearningState, now: Date = Date()) -> [LearnEvent] {
        var out: [LearnEvent] = []
        let w = window(s)
        for k in s.jobs.indices where s.jobs[k].state == "open" {
            let j = s.jobs[k]
            let mine = s.pending.filter {
                $0.session == j.session && $0.ts >= j.started.addingTimeInterval(-5) && $0.ts <= j.ended.addingTimeInterval(w)
            }
            if !mine.isEmpty {
                let ids = Set(mine.map(\.id))
                s.pending.removeAll { ids.contains($0.id) }
                s.jobs[k].lines += mine
            }
            let lines = s.jobs[k].lines
            var made: [String] = []
            for l in lines where LedgerLine.creates.contains(l.action) && !made.contains(l.skill) { made.append(l.skill) }
            if !made.isEmpty {
                if !j.kind.isEmpty, declined(j.kind, s) {
                    s.jobs[k].state = "dropped"
                    out.append(.undoQuietly(s.jobs[k], skills: made))
                } else {
                    s.jobs[k].state = "learned"
                    out.append(.learned(s.jobs[k], skills: made))
                }
                continue
            }
            guard now > j.ended.addingTimeInterval(w) else { continue }
            if lines.contains(where: { LedgerLine.fixes.contains($0.action) }) {
                s.jobs[k].state = "fixed"
            } else if worthAsking(j, s) {
                s.jobs[k].state = "asked"
                out.append(.ask(s.jobs[k]))
            } else {
                s.jobs[k].state = "quiet"
            }
        }
        // Lines no job took within an hour are dropped; old jobs are kept 60 days for the repeat check.
        s.pending.removeAll { $0.ts < now.addingTimeInterval(-3600) }
        s.jobs.removeAll { $0.ended < now.addingTimeInterval(-60 * 86400) }
        if s.jobs.count > 300 { s.jobs.removeFirst(s.jobs.count - 300) }
        return out
    }

    // MARK: Names in plain words

    /// "movie-showtimes" → "Movie showtimes"
    static func plain(_ name: String) -> String {
        let t = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// The skill's SKILL.md from the lines that made it.
    static func skillFile(_ lines: [LedgerLine], _ skill: String) -> String? {
        lines.filter { $0.skill == skill }.flatMap(\.paths).first { $0.hasSuffix("/SKILL.md") }
    }

    // MARK: Undo

    /// Undoes everything one job did to a skill in the engine's own folder: each change rolled back, newest first,
    /// with the engine's own one-step rollback (it keeps a safety copy). True when the skill is gone afterwards.
    static func rollback(_ lines: [LedgerLine], skill: String) async -> Bool {
        let mine = lines.filter { $0.skill == skill && ($0.action == "create" || LedgerLine.fixes.contains($0.action)) }.sorted { $0.ts > $1.ts }
        let file = skillFile(lines, skill)
        for l in mine {
            let (code, out) = await hermesRun(["curator", "rollback", l.id, "--yes"])
            log("undo \(skill) \(l.action) \(l.id): \(code) \(out.split(separator: "\n").last ?? "")")
        }
        guard let file else { return mine.isEmpty }
        let dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: file) { return false }
        // The rollback removes the files; an empty folder left behind would still look like a skill to a person.
        if let left = try? fm.subpathsOfDirectory(atPath: dir.path), left.allSatisfy({ $0.hasPrefix(".") || $0.hasSuffix("/") }) {
            try? fm.removeItem(at: dir)
        }
        return true
    }

    /// A skill saved into a room: moved to the Trash, so it can be got back. If the Trash can't be reached,
    /// it goes to One's own `forgotten/` folder instead (never deleted outright).
    static func trash(_ skillMD: String) -> Bool {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: skillMD).deletingLastPathComponent()
        guard fm.fileExists(atPath: dir.path) else { return true }
        if (try? fm.trashItem(at: dir, resultingItemURL: nil)) != nil { return true }
        let keep = Env.support.appendingPathComponent("forgotten", isDirectory: true)
        try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let ok = (try? fm.moveItem(at: dir, to: keep.appendingPathComponent("\(stamp) \(dir.lastPathComponent)"))) != nil
        log("undo room skill \(dir.lastPathComponent): Trash unreachable, kept in forgotten/ (\(ok))")
        return ok
    }

    // MARK: Tags in replies

    /// `[job-kind: movie times lookup]` and `[learned: name | room]` lines: read, then taken out of what's shown.
    static func tags(_ text: String) -> (clean: String, kind: String?, learned: (name: String, room: String)?) {
        var kind: String?
        var learned: (String, String)?
        var keep: [String] = []
        for l in text.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            let low = t.lowercased()
            if low.hasPrefix("[job-kind:"), t.hasSuffix("]") {
                kind = String(t.dropFirst(10).dropLast()).trimmingCharacters(in: .whitespaces)
            } else if low.hasPrefix("[learned:"), t.hasSuffix("]") {
                let parts = t.dropFirst(9).dropLast().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[0].isEmpty, parts[0].lowercased() != "none" { learned = (parts[0], parts[1]) }
            } else {
                keep.append(l)
            }
        }
        var clean = keep.joined(separator: "\n")
        while clean.hasSuffix("\n") { clean.removeLast() }
        return (clean, kind, learned)
    }
    /// While a reply streams in: hide a tag line, even half-written.
    static func hideTags(_ text: String) -> String {
        text.components(separatedBy: "\n").filter {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return !l.hasPrefix("[job-kind") && !l.hasPrefix("[learned")
        }.joined(separator: "\n")
    }

    /// Asked on every main-chat job: name its kind, so a repeat and a "no thanks" can be recognised.
    static let kindNote =
        "\n\n(One app note, not from the user: on the very last line of your reply, add [job-kind: <2 to 4 plain words naming this kind of job, like movie times lookup>]. One hides it.)"

    /// The hidden prompt after "Yes, remember it": the skill goes into the room the job belongs to.
    static func savePrompt(brain: String) -> String {
        "(One app note, not from the user: they said yes to remembering how you did this job. Write it now as a skill, "
            + "straight into the room this job belongs to, following the brain's AGENTS.md: \(brain)/<room folder>/skills/learned/<short-name>/SKILL.md "
            + "(write the file directly; don't use skill_manage). Start it with front matter (---, name: <short-name>, description: Use when <the trigger in a few words>., ---), "
            + "then the steps that worked and the pitfalls, in plain words. Nothing from any other room. Never into a shared room unless the job was that room's work. "
            + "Then reply with one short plain line saying you'll remember it, and on the last line: [learned: <short-name> | <room folder>]. "
            + "If you can't save it, reply [learned: none | none].)"
    }

    /// Facts for the assistant's memory: kinds of job they said no to.
    static var declinedFact: String? {
        let s = load()
        let kinds = s.declinedKinds.map(\.kind).filter { !$0.isEmpty }
        guard !kinds.isEmpty else { return nil }
        return "Don't save recipes (skills) for these kinds of jobs; they said no: \(kinds.joined(separator: "; "))."
    }

    // MARK: Which chat a log line came from

    private nonisolated(unsafe) static var parents: [String: String] = [:]
    /// A delegated subagent's chat counts as its parent's (state.db `sessions.parent_session_id`).
    static func parent(of sid: String) -> String? {
        if let p = parents[sid] { return p.isEmpty ? nil : p }
        let db = Env.hermesHome.appendingPathComponent("state.db").path
        guard sid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), FileManager.default.fileExists(atPath: db) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", db, "select coalesce(parent_session_id,'') from sessions where id='\(sid)';"]
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let r = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        parents[sid] = r
        return r.isEmpty ? nil : r
    }
}

/// Skills saved into rooms count as skills: each PRIVATE room's `skills/learned` folder goes into the engine's
/// `skills.external_dirs`. Never a shared room's: any chat can edit a skill it finds, so a personal job could
/// write personal details into a skill the other members see. That is checked here in code, every time.
enum LearnedDirs {
    static func isShared(_ path: String, _ shared: [String] = Shared.paths) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return shared.contains { s in
            let r = URL(fileURLWithPath: s).standardizedFileURL.path
            return p == r || p.hasPrefix(r + "/")
        }
    }
    /// The folders One wants the engine to read: private rooms only.
    static func wanted(rooms: [URL] = RoomMap.roomFolders(), shared: [String] = Shared.paths) -> [String] {
        rooms.map { $0.appendingPathComponent("skills/learned").path }.filter { !isShared($0, shared) }
    }
    /// Keeps whatever else is listed, drops One's old entries and anything inside a shared room, adds the private rooms.
    static func merged(current: [String], wanted: [String], shared: [String] = Shared.paths) -> [String] {
        var out = current.filter { !$0.hasSuffix("/skills/learned") && !isShared($0, shared) }
        for w in wanted where !out.contains(w) { out.append(w) }
        return out
    }
    /// `[]` or `- a\n- b` from `hermes config get`. Long items are folded onto indented next lines
    /// ("- /Users/x/Library/Application\n    Support/One/…"): those are joined back with a space.
    static func parseList(_ out: String) -> [String] {
        var items: [String] = []
        for raw in out.split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") {
                items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !items.isEmpty, raw.hasPrefix(" "), !t.isEmpty, !t.hasPrefix("⚠") {
                items[items.count - 1] += " " + t
            }
        }
        return items.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
    }

    /// Before the engine starts, and after a skill is saved into a room.
    @discardableResult
    static func sync() async -> [String] {
        let want = wanted()
        for w in want { try? FileManager.default.createDirectory(atPath: w, withIntermediateDirectories: true) }
        let key = Env.selfTest ? "learnedDirsTest" : "learnedDirs"
        let (gc, got) = await hermesRun(["config", "get", "skills.external_dirs"])
        let current = gc == 0 ? parseList(got) : []
        let next = merged(current: current, wanted: want)
        if next == current, UserDefaults.standard.stringArray(forKey: key) == next { return next }
        let yaml = "[" + next.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        let (code, _) = await hermesRun(["config", "set", "skills.external_dirs", yaml, "--force"])
        if code == 0 { UserDefaults.standard.set(next, forKey: key) }
        Learning.log("external_dirs → \(next.count) folder(s), shared rooms left out (\(code))")
        return next
    }

    /// One line in the log at launch when the engine's skill log is off: then only "want me to remember?" works.
    static func checkLedgerOn() async {
        let (code, out) = await hermesRun(["config", "get", "skills.ledger"])
        if code == 0, out.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "false" }) {
            Learning.log("skills.ledger is off: new skills and fixes can't be seen; only the remember question works")
        }
    }
}
