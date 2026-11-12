import Foundation

// MARK: - A routine the engine switched off and never turned back on

/// The engine pauses a routine by itself when a run is cut off and it can't tell how that run ended ("Cron execution
/// unverified; reconcile <journal>" / "Canonical cron unknown"). Only that run's admission journal
/// (`hermes/cron/admissions/*.json`) can lift the pause again. But when the firer itself gave up, it books the run as
/// failed, and the engine's next recovery pass deletes the journal of a failed run without lifting the pause
/// (cron/scheduler_authority.py `reconcile_pending`). The routine then stays off for good and nothing says so:
/// Project Ledger PM, cut off when One restarted on Nov 8 2026, stayed off Nov 9, 10 and 11.
///
/// One turns such a routine back on once nothing is left that could lift its pause (no journal for that job), the
/// same way the person's Turn back on does (`hermes cron resume`). A slot it missed while off stays due, so the
/// engine makes it up once, right away (its catch-up rule). And One says so out loud. Never a pause the person made,
/// nor one for any other reason.
enum RoutineRevive {
    /// The engine's own pause reasons for a run it couldn't check (cron/scheduler_authority.py).
    static let enginePauses = ["Cron execution unverified", "Canonical cron unknown"]

    struct Stuck: Equatable {
        let id: String
        let title: String
        let since: Date?  // when the engine paused it
        let missed: Bool  // a run time passed while it was off
    }

    /// Routines held off by the engine for good, read from `cron/jobs.json`. Call off the main thread.
    static func find(at cron: URL, now: Date = Date()) -> [Stuck] {
        guard let d = try? Data(contentsOf: cron.appendingPathComponent("jobs.json")),
            let top = try? JSONSerialization.jsonObject(with: d)
        else { return [] }
        let list = (top as? [String: Any])?["jobs"] as? [[String: Any]] ?? top as? [[String: Any]] ?? []
        let held = list.filter(engineHeld)
        guard !held.isEmpty else { return [] }
        let waiting = journalJobs(cron.appendingPathComponent("admissions"))
        return held.compactMap { j in
            guard let id = j["id"] as? String, !waiting.contains(id), !waiting.contains("") else { return nil }
            let next = Routines.date(j["next_run_at"])
            let title = (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A routine"
            return Stuck(id: id, title: title, since: Routines.date(j["paused_at"]), missed: next.map { $0 <= now } ?? false)
        }
    }

    /// Paused by the engine for a run it couldn't check: a pause with one of its own reasons.
    static func engineHeld(_ j: [String: Any]) -> Bool {
        guard (j["state"] as? String) == "paused", let why = j["paused_reason"] as? String else { return false }
        return enginePauses.contains { why.hasPrefix($0) }
    }

    /// The jobs that still have a run's journal waiting, which the engine can still settle (and lift its own pause).
    /// A journal that can't be read counts as "" (anyone's), so nothing is turned back on while it's there.
    static func journalJobs(_ dir: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var ids = Set<String>()
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                let id = (o["params"] as? [String: Any])?["job_id"] as? String
            else {
                ids.insert("")
                continue
            }
            ids.insert(id)
        }
        return ids
    }

    /// The engine command that turns it back on (the Routines card's Turn back on).
    static func steps(_ id: String) -> [String] { ["cron", "resume", id] }

    /// `hermes/logs/one-routine-revive.log`: each routine turned back on and what the engine said.
    static func log(_ s: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-routine-revive.log")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    static func day(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return " on " + f.string(from: d)
    }

    /// What One says once it's back on.
    static func line(_ s: Stuck) -> String {
        "\(s.title) turned itself off\(day(s.since)) after a run was cut off, and nothing told you. I turned it back on"
            + (s.missed ? ", and it's making up its missed run now." : ".")
    }

    /// What One says when the engine wouldn't turn it back on.
    static func failedLine(_ s: Stuck) -> String {
        "\(s.title) turned itself off\(day(s.since)) after a run was cut off, and I couldn't turn it back on. "
            + "It won't run until it's on again. Ask me and I'll sort it out."
    }
}

extension Routines {
    /// What a finished run says in the chat: its title and its answer, or nil for a quiet one (`[SILENT]`, empty).
    /// A run that crashed leaves no answer, only an `## Error` section (Project Ledger PM, Nov 8 2026): that's said
    /// too, in plain words, so a routine never fails without a word.
    static func report(_ text: String) -> (title: String, body: String)? {
        var title = text.split(separator: "\n").first.map { $0.replacingOccurrences(of: "# Cron Job: ", with: "") } ?? "A routine"
        if title.hasSuffix(" (FAILED)") { title = String(title.dropLast(" (FAILED)".count)) }
        if let r = text.range(of: "## Response") {
            var body = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let cut = body.range(of: "\n⚠️") { body = String(body[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
            if body.isEmpty || body.hasPrefix("[SILENT]") { return nil }
            return (title, body)
        }
        // The engine appends the run's own error last; one quoted from an earlier run's report comes before it.
        guard let e = text.range(of: "\n## Error\n", options: .backwards) else { return nil }
        let lines = text[e.upperBound...].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let last = lines.last { !$0.isEmpty && !$0.hasPrefix("```") }
        return (title, "It didn't work. " + plainError(last) + " Ask me and I'll look into it.")
    }
}
