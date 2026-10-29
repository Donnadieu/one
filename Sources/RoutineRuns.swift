import Foundation

// MARK: - What a routine's last run really did. A run marked failed can have done most of its work (the post went out,
// then One restarted), and a later run or a catch-up can finish what it missed. The dial shows three plain states from
// real records, never a guess: done (or caught up later), partly done, and didn't run / did nothing.
//
// Records read:
// - the run's own report (`cron/output/<id>/<time>.md`, `## Response`): a line starting "Partly done:" says which part
//   worked and which didn't; "Not done:" says nothing worked.
// - the step log `cron/steps/<id>.jsonl`, one line per step as it finishes:
//     {"at": "2026-10-28T09:51:00-04:00", "step": "Morning post", "ok": true}
//     {"at": "…", "step": "Evening post", "ok": false, "why": "signed out"}
//     {"at": "…", "step": "Morning post", "ok": true, "catch_up": true}   ← a later run made up a missed part
//   A run owns the lines from its scheduled time until the job's next run. A step's last line decides it.

struct RunNotes: Equatable {
    var did: [String] = []  // steps that worked (their last line is ok)
    var didnt: [String] = []  // steps whose last line is not ok
    var caughtUp: [String] = []  // steps that failed first and were made up later
    var caughtUpAt: Date?  // when the last catch-up landed
    var partly: String?  // the report's own "Partly done: …" line
    var nothing = false  // the report says "Not done:"
    var cut = false  // One quit or restarted mid-run
    var cutAt: Date?

    var hasWork: Bool { !did.isEmpty || partly != nil }
    /// Everything a missed run left undone was made up later.
    var madeUp: Bool { caughtUpAt != nil && didnt.isEmpty && !nothing && (!cut || !caughtUp.isEmpty) }
}

extension Routines {
    static func stepsFile(_ dir: URL, _ id: String) -> URL { dir.appendingPathComponent("steps/\(id).jsonl") }

    struct Step {
        let at: Date
        let step: String
        let ok: Bool
        let catchUp: Bool
        let why: String?
    }

    static func steps(_ file: URL) -> [Step] {
        guard let t = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return t.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let at = date(o["at"]), let s = (o["step"] as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty
            else { return nil }
            let ok = o["ok"] as? Bool ?? true
            return Step(at: at, step: s, ok: ok, catchUp: o["catch_up"] as? Bool ?? false, why: o["why"] as? String)
        }.sorted { $0.at < $1.at }
    }

    /// The `## Response` of the run's report: the newest output file written in [from, to].
    static func report(_ out: URL, from: Date, to: Date) -> String? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        for name in files.reversed() {
            guard let d = f.date(from: String(name.dropLast(3))), d >= from.addingTimeInterval(-60), d <= to.addingTimeInterval(120) else { continue }
            guard let text = try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8), !text.isEmpty else { continue }
            let parts = text.components(separatedBy: "## Response")
            return parts.count > 1 ? parts.dropFirst().joined(separator: "\n") : nil
        }
        return nil
    }

    /// What the run that started at `start` did, from its report and the step log (lines until `end`).
    static func notes(steps all: [Step], report: String?, start: Date, end: Date, ranUntil: Date?, error: String?) -> RunNotes {
        var n = RunNotes()
        n.cut = cutByRestart(error)
        n.cutAt = n.cut ? ranUntil : nil
        for raw in (report ?? "").components(separatedBy: "\n") + [error ?? ""] {
            let l = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let low = l.lowercased()
            if n.partly == nil, low.hasPrefix("partly done") || low.hasPrefix("partially done") { n.partly = l }
            if low.hasPrefix("not done:") { n.nothing = true }
        }
        let mine = all.filter { $0.at >= start.addingTimeInterval(-60) && $0.at < end }
        var last: [String: Step] = [:]
        var order: [String] = []
        var failedOnce = Set<String>()
        for s in mine {
            if last[s.step] == nil { order.append(s.step) }
            last[s.step] = s
            if !s.ok { failedOnce.insert(s.step) }
        }
        for k in order {
            guard let s = last[k] else { continue }
            if s.ok {
                n.did.append(k)
                // Made up later: it failed first, or the run was cut and a catch-up line finished it.
                if s.catchUp && (failedOnce.contains(k) || n.cut || error != nil) {
                    n.caughtUp.append(k)
                    n.caughtUpAt = max(n.caughtUpAt ?? s.at, s.at)
                }
            } else {
                n.didnt.append(k)
            }
        }
        return n
    }

    /// The run's notes for a job's last run: its window starts at the scheduled time of that run.
    static func lastRunNotes(_ j: [String: Any], id: String, dir: URL, last: Date, next: Date?, now: Date) -> RunNotes {
        let disp = j["last_dispatch"] as? [String: Any]
        var start = date(disp?["scheduled_at"]) ?? date(disp?["dispatched_at"]) ?? last.addingTimeInterval(-3 * 3600)
        if start > last { start = last.addingTimeInterval(-3 * 3600) }
        let end = max(next ?? now, now)
        let err = (j["last_error"] as? String) ?? ((j["last_failure"] as? [String: Any])?["detail"] as? String)
        let rep = report(dir.appendingPathComponent("output/\(id)"), from: start, to: last)
        return notes(steps: steps(stepsFile(dir, id)), report: rep, start: start, end: end, ranUntil: last, error: err)
    }

    // MARK: Plain words

    /// "Morning post, Replies and 7 of 12 rounds": the steps as the routine named them.
    static func names(_ xs: [String]) -> String { list(xs) }

    /// The card's line for a partly done run: the report's own words when it has them, else from the step log.
    static func partlyLine(_ n: RunNotes) -> String {
        if let p = n.partly { return clip(p, 220) }
        var s = "Partly done: " + names(n.did).capitalizingFirst + " worked"
        if !n.didnt.isEmpty { s += "; " + names(n.didnt) + " didn't" }
        if n.cut { s += n.didnt.isEmpty ? ". The rest was cut short when One restarted" : ". Then One restarted" }
        return s + "."
    }

    /// The card's line for a run whose missing part was made up later.
    static func caughtUpLine(_ r: Routine) -> String {
        let at = r.caughtUpAt.map { " at " + clock(minutes($0)) } ?? ""
        return "Done. The first try missed a part, and it was caught up\(at)."
    }
}
