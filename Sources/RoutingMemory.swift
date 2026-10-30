import Foundation

// MARK: - What worked before (smart routing's memory)
// Every helper job leaves one memory: its words, the recipes it used (loaded up front or looked up itself) and
// whether it went well (done) or not (failed, stopped, or the same job sent again soon after = a redo).
// Similar later jobs get the recipes that worked; recipes from jobs that went badly count against.
// First launch: seeded from the helper conversations already in the engine's own history (state.db), read only.

struct RouteMemory: Codable, Sendable {
    var date: Date
    var terms: [String: Int]
    var skills: [String]
    var ok: Bool
    var kind = ""

    static func cosine(_ a: [String: Int], _ b: [String: Int]) -> Double {
        func c(_ v: Int) -> Double { Double(min(v, 3)) }
        var num = 0.0
        for (w, v) in a { if let u = b[w] { num += c(v) * c(u) } }
        guard num > 0 else { return 0 }
        let na = a.values.reduce(0.0) { $0 + c($1) * c($1) }
        let nb = b.values.reduce(0.0) { $0 + c($1) * c($1) }
        return num / (na * nb).squareRoot()
    }

    /// The 7 most similar past jobs (similarity 0.12 or more) vote for their recipes: +sim if it went well, −sim/2 if not.
    static func vote(_ q: [String: Int], _ memory: [RouteMemory]) -> [String: Double] {
        guard !q.isEmpty else { return [:] }
        let near = memory.map { (cosine(q, $0.terms), $0) }.filter { $0.0 >= 0.12 }.sorted { $0.0 > $1.0 }.prefix(7)
        var out: [String: Double] = [:]
        for (sim, m) in near { for k in m.skills { out[k, default: 0] += sim * (m.ok ? 1 : -0.5) } }
        return out
    }

    /// Only the words that matter are kept (the 60 most frequent), so the file stays small.
    static func terms(_ text: String) -> [String: Int] {
        let c = RouteWords.counts(RouteWords.of(text))
        guard c.count > 60 else { return c }
        return Dictionary(
            uniqueKeysWithValues: c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(60).map { ($0.key, $0.value) })
    }
}

/// A helper's job while it runs: what was offered and what it looked up itself.
struct RouteOpen: Codable {
    var terms: [String: Int]
    var offered: [String]
    var used: [String] = []
    var kind: String
    var started = Date()
}

struct RouteState: Codable {
    var seeded = false
    var memory: [RouteMemory] = []
    var open: [String: RouteOpen] = [:]  // helper id
}

/// The router's state on the Mac: the recipe index (rebuilt every 10 minutes in the background) and the memory file.
@MainActor
enum RouteStore {
    static var file: URL { Env.support.appendingPathComponent(Env.selfTest ? "selftest-routing.json" : "routing.json") }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-routing.log") }
    static var index = RouteIndex()
    static var state = load()
    private static var built: Date?
    private static var building = false
    static let maxMemory = 600

    static func load() -> RouteState {
        guard let d = try? Data(contentsOf: file) else { return RouteState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(RouteState.self, from: d)) ?? RouteState()
    }
    static func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if state.memory.count > maxMemory { state.memory.removeFirst(state.memory.count - maxMemory) }
        try? enc.encode(state).write(to: file, options: .atomic)
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

    static var dirs: [URL] {
        [Env.hermesHome.appendingPathComponent("skills", isDirectory: true)]
            + LearnedDirs.wanted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Called from the main loop: reads the recipe book in the background (at most every 10 minutes), and seeds the
    /// memory from the engine's history once. Never blocks a turn.
    static func tend() {
        guard !building, built.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        building = true
        let d = dirs
        let seed = !state.seeded
        let db = Env.hermesHome.appendingPathComponent("state.db").path
        Task.detached(priority: .utility) {
            let t0 = Date()
            let idx = RouteIndex.build(dirs: d)
            let seeded = seed ? RouteSeed.read(db: db) : []
            await MainActor.run {
                index = idx
                built = Date()
                building = false
                if seed {
                    state.memory = seeded + state.memory
                    state.seeded = true
                    save()
                }
                log(
                    "index: \(idx.skills.count) recipes in \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
                        + (seed ? ", seeded \(seeded.count) past jobs" : ""))
            }
        }
    }

    /// The route for a job, or nil when the router isn't ready (then nothing changes).
    static func route(_ text: String) -> Route? {
        guard !index.skills.isEmpty else { return nil }
        return Router.route(text, index: index, memory: state.memory)
    }

    // MARK: Learning

    /// A helper starts: remember what was offered. A very similar job that finished in the last 2 hours went wrong (a redo).
    static func began(_ id: UUID, text: String, kind: String, route r: Route) {
        let t = RouteMemory.terms(text)
        let since = Date().addingTimeInterval(-7200)
        if let k = state.memory.indices.last(where: { state.memory[$0].date > since && RouteMemory.cosine(t, state.memory[$0].terms) >= 0.6 }),
            state.memory[k].ok
        {
            state.memory[k].ok = false
            log("redo: \"\(kind)\" looks like \"\(state.memory[k].kind)\" sent again, counted as not worked")
        }
        state.open[id.uuidString] = RouteOpen(terms: t, offered: r.preload, kind: kind)
        save()
        log(
            "helper \"\(kind)\": \(r.preload.isEmpty ? "nothing sure" : r.preload.joined(separator: ", ")) | ranked "
                + r.ranked.map { "\($0.name) \(String(format: "%.2f", $0.score))" }.joined(separator: ", ")
                + " | room \(r.room ?? "-") | yes \(r.needsYes) | tier \(r.tier) | \(String(format: "%.1f", r.ms)) ms")
    }

    /// A step of a helper: a recipe it looked up itself counts as used.
    static func saw(_ id: UUID, _ title: String) {
        guard let k = Router.viewed(title), state.open[id.uuidString] != nil, state.open[id.uuidString]?.used.contains(k) == false else { return }
        state.open[id.uuidString]?.used.append(k)
    }

    /// A helper's turn is over. ok: done (or asking for a yes); not ok: failed or stopped.
    static func finished(_ id: UUID, ok: Bool) {
        guard let o = state.open.removeValue(forKey: id.uuidString) else { return }
        var skills = o.used
        for k in o.offered where !skills.contains(k) { skills.append(k) }
        state.memory.append(RouteMemory(date: Date(), terms: o.terms, skills: skills, ok: ok, kind: o.kind))
        save()
        log("finished \"\(o.kind)\": \(ok ? "worked" : "didn't work") with \(skills.isEmpty ? "no recipes" : skills.joined(separator: ", "))")
    }
}

/// The first memory: helper jobs already in the engine's history and the recipes each looked up. Read only.
enum RouteSeed {
    static func sql(_ db: String, _ q: String) -> [[String: Any]] { Learning.sqlJSON(db, q) }

    /// The job inside a helper's first prompt; a job file it points to, when it still exists, is read instead.
    static func job(_ first: String) -> String? {
        guard first.hasPrefix("You're one of"), let a = first.range(of: "The job: ") else { return nil }
        var job = String(first[a.upperBound...])
        if let e = job.range(of: "\n\nDo it now.") { job = String(job[..<e.lowerBound]) }
        if let r = job.range(of: #"/Users/[^\n]+?/helper-jobs/[\w\-]+\.md"#, options: .regularExpression),
            let t = try? String(contentsOfFile: String(job[r]), encoding: .utf8)
        {
            job = t
        }
        return job
    }

    static func read(db: String, days: Int = 30) -> [RouteMemory] {
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        let since = Int(Date().timeIntervalSince1970) - days * 86400
        let firsts = sql(
            db,
            "select s.id as id, s.started_at as t, (select content from messages m where m.session_id=s.id and m.role='user' order by m.id limit 1) as first "
                + "from sessions s where s.started_at > \(since) order by s.started_at")
        let views = sql(
            db,
            "select m.session_id as id, json_extract(j.value,'$.function.arguments') as args from messages m, json_each(m.tool_calls) j "
                + "where m.tool_calls is not null and m.timestamp > \(since) and json_extract(j.value,'$.function.name')='skill_view' order by m.id")
        var used: [String: [String]] = [:]
        for v in views {
            guard let id = v["id"] as? String, let a = (v["args"] as? String)?.data(using: .utf8),
                let j = try? JSONSerialization.jsonObject(with: a) as? [String: Any], let n = j["name"] as? String
            else { continue }
            if used[id]?.contains(n) != true { used[id, default: []].append(n) }
        }
        return firsts.compactMap { r in
            guard let id = r["id"] as? String, let f = r["first"] as? String, let job = job(f), let skills = used[id] else { return nil }
            let t = (r["t"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            return RouteMemory(date: t, terms: RouteMemory.terms(job), skills: skills, ok: true, kind: "seed")
        }
    }
}

/// Read-only questions to the engine's history (state.db), as JSON rows. Same reader as `Learning.parent(of:)`.
extension Learning {
    static func sqlJSON(_ db: String, _ q: String) -> [[String: Any]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-json", db, q]
        let o = Pipe()
        p.standardOutput = o
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
    }

}
