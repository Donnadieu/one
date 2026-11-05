import Foundation

// MARK: - The nightly review's commands (`One --improve night …`)
// prepare   (--force: a run by hand, no waiting) the routine's pre-run script: waits until nothing else is working (up to --wait minutes, 45 by default),
//           collects the score, closes the last night, runs the 7-day checks, copies what the night may edit, then
//           prints everything the review needs. Still busy at the end: prints `{"wakeAgent": false}` (the engine then
//           skips the AI run, silently).
// end       compares and applies the limits (the routine runs it last; `prepare` and `morning` run it too, in case).
// undo      "Undo last night".
// morning   the 3 lines for the morning brief.
// verdicts  the 7-day checks on their own.

enum ImproveNightRun {
    /// On every prompt (SessionNotes): how to act on the morning lines.
    static var note: String {
        "\n\n(One app note, not from the user: ONE'S NIGHTLY REVIEW. If they say \"undo last night\", run `\"\(Bridge.exe)\" --improve night undo` "
            + "and tell them in plain words what it put back. To turn the review's safe edits off or on: `\"\(Bridge.exe)\" --improve settings set mode "
            + "suggest` (suggestions only) or `... mode edit`. Last night's lines: `\"\(Bridge.exe)\" --improve night morning`.)"
    }
    static func cli(_ a: [String], now: Date = Date()) -> Int32 {
        let today = Improve.dayKey(now)
        switch a.first ?? "" {
        case "prepare":
            let wait = Double(ImproveCLI.value(a, "--wait") ?? "") ?? 45
            print(prepare(now: now, waitMinutes: wait, force: a.contains("--force")), terminator: "")
            return 0
        case "end":
            let d = ImproveCLI.value(a, "--date") ?? today
            guard let r = ImproveNight.end(date: d, now: now) else {
                print("No review was started on \(d).")
                return 0
            }
            print("Review of \(d) (\(r.mode)): \(r.note ?? "done").")
            writeMorning(date: d, now: now)
            return 0
        case "undo":
            ImproveNight.undo(date: ImproveCLI.value(a, "--date"), now: now).forEach { print($0) }
            return 0
        case "morning":
            morning(now: now).forEach { print($0) }
            return 0
        case "verdicts":
            let v = verdicts(now: now)
            print(v.isEmpty ? "No recipe change is old enough to judge yet." : v.joined(separator: "\n"))
            return 0
        default:
            print("usage: One --improve night prepare [--wait 45] [--force] | end [--date D] | undo [--date D] | morning | verdicts")
            return 2
        }
    }

    // MARK: only when nothing else is working

    /// Why now is a bad time, or nil when nothing else is working: another routine running, or a chat, helper or
    /// phone message in the last 10 minutes.
    static func busy(now: Date) -> String? {
        let others = Routines.jobs(at: Routines.cron, now: now).filter { $0.state == .running && $0.title != NightlyRoutine.name }
        if let o = others.first { return "the routine \"\(o.title)\" is running" }
        guard let db = ReadOnlyDB(Improve.stateDB) else { return nil }
        var n = 0
        db.each(
            "SELECT count(*) FROM messages m JOIN sessions s ON s.id = m.session_id WHERE m.timestamp > ? AND coalesce(s.source, '') != 'cron'",
            [now.timeIntervalSince1970 - 600]
        ) { n = Int(ReadOnlyDB.num($0, 0)) }
        return n > 0 ? "a chat or helper was working in the last 10 minutes" : nil
    }

    /// `force`: a run by hand (no waiting for quiet).
    static func prepare(now start: Date, waitMinutes: Double, force: Bool = false) -> String {
        var now = start
        while !force, let why = busy(now: now) {
            guard now.timeIntervalSince(start) < waitMinutes * 60 else {
                let d = Improve.dayKey(start)
                try? FileManager.default.createDirectory(at: ImproveNight.reviewDir, withIntermediateDirectories: true)
                let j: [String: Any] = ["date": d, "skipped": "busy: \(why)"]
                try? JSONSerialization.data(withJSONObject: j).write(to: ImproveNight.reviewFile(d))
                return "Skipped tonight: \(why) for \(Int(waitMinutes)) minutes.\n{\"wakeAgent\": false}\n"
            }
            Thread.sleep(forTimeInterval: Env.selfTest ? 0.05 : 120)
            now = Env.selfTest ? now.addingTimeInterval(120) : Date()
        }
        let date = Improve.dayKey(now)
        for d in ImproveNight.dates() where d != date { _ = ImproveNight.end(date: d, now: now) }
        Improve.collect(from: Improve.defaultSince(), to: now)
        let judged = verdicts(now: now)
        let s = Improve.settings()
        let r = ImproveNight.begin(date: date, now: now)
        let yesterday = Improve.dayKey(Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now)
        var out = "# One's nightly review, \(date)\n\n"
        out +=
            "MODE: \(s.mode) (\(s.mode == "edit" ? "safe edits on: at most \(s.maxEditsPerNight) recipes tonight, \(s.maxEditsPerSkill) change each" : "suggestions only: change nothing"))\n"
        out += "REVIEW FILE (write it): \(ImproveNight.reviewFile(date).path)\n"
        out += "LESSONS LEDGER (append to it): \(Improve.lessonsFile.path)\n"
        out += "WHEN DONE, RUN: \"\(Bridge.exe)\" --improve night end\n"
        out += "Copied before the review (\(r.roots.count) folders), so tonight can be undone.\n\n"
        out += "## Recipes you may add a lesson to\n"
        for root in r.roots.values.sorted() {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
                let f = URL(fileURLWithPath: root).appendingPathComponent(name).appendingPathComponent("SKILL.md")
                if FileManager.default.fileExists(atPath: f.path) { out += "- \(name): \(f.path)\n" }
            }
        }
        if s.mode == "edit" { out += "- notes (the assistant's MEMORY.md): \(Env.hermesHome.appendingPathComponent("memories/MEMORY.md").path)\n" }
        out += "\n## The lessons ledger so far (newest last)\n"
        let ledger = ((try? String(contentsOf: Improve.lessonsFile, encoding: .utf8)) ?? "").split(separator: "\n").suffix(60)
        out += ledger.isEmpty ? "(empty)\n" : ledger.joined(separator: "\n") + "\n"
        if !judged.isEmpty { out += "\n## 7-day checks on earlier changes\n" + judged.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        out += "\n" + ImproveMoments.render(date: yesterday, max: 20)
        return out
    }

    // MARK: the 7-day check

    /// For each recipe a night changed 7 to 30 days ago: jobs that used it in the 7 days before vs the 7 days after.
    /// With 3 or more jobs on each side and a worse share of corrected or broken jobs after, the change is put back.
    static func verdicts(now: Date) -> [String] {
        var out: [String] = []
        let s = Improve.settings()
        for d in ImproveNight.dates() {
            guard var r = ImproveNight.read(d), r.mode == "edit", let ended = r.ended, r.verdicts == nil,
                now.timeIntervalSince1970 - ended >= 7 * 86400, now.timeIntervalSince1970 - ended <= 30 * 86400
            else { continue }
            var v: [String: String] = [:]
            for name in Set(r.changed.filter { $0.undone == nil && $0.skill != "notes" }.map(\.skill)).sorted() {
                let before = jobs(using: name, from: ended - 7 * 86400, to: ended)
                let after = jobs(using: name, from: ended, to: ended + 7 * 86400)
                guard before.all >= 3, after.all >= 3 else {
                    v[name] = "kept (too few jobs to judge: \(before.all) before, \(after.all) after)"
                    continue
                }
                let worse = Double(after.bad) / Double(after.all) > Double(before.bad) / Double(before.all)
                if worse, s.autoUndoOnDrop {
                    ImproveNight.putBack(&r, why: "jobs went worse after it", only: name, now: now)
                    v[name] = "put back: \(after.bad) of \(after.all) jobs went wrong after, \(before.bad) of \(before.all) before"
                    out.append(
                        "I put back my \(d) change to \(name): jobs using it went worse (\(after.bad) of \(after.all) vs \(before.bad) of \(before.all))."
                    )
                } else {
                    v[name] = "kept: \(after.bad) of \(after.all) after, \(before.bad) of \(before.all) before"
                }
            }
            r.verdicts = v
            ImproveNight.write(r)
        }
        return out
    }

    /// Conversations that opened a recipe (skill_view / skill_manage by name) in a time window, and how many of them
    /// drew a correction or broke (from the collected days).
    static func jobs(using name: String, from: Double, to: Double) -> (all: Int, bad: Int) {
        var sessions: Set<String> = []
        ReadOnlyDB(Improve.stateDB)?.each(
            "SELECT session_id, tool_calls FROM messages WHERE role = 'assistant' AND timestamp >= ? AND timestamp < ? AND tool_calls LIKE '%skill_%'",
            [from, to]
        ) { st in
            guard let sid = ReadOnlyDB.text(st, 0), let tc = ReadOnlyDB.text(st, 1), uses(tc, name) else { return }
            sessions.insert(sid)
        }
        var bad: Set<String> = []
        for key in Improve.dayKeys() {
            guard let day = Improve.day(key), day.timeIntervalSince1970 >= from - 86400, day.timeIntervalSince1970 < to,
                let rec = Improve.readDay(key)
            else { continue }
            for e in rec.events where ["correction", "broke"].contains(e.kind) && e.ts >= from && e.ts < to {
                if let sid = e.session, sessions.contains(sid) { bad.insert(sid) }
            }
        }
        return (sessions.count, bad.count)
    }
    static func uses(_ toolCalls: String, _ name: String) -> Bool {
        guard let calls = try? JSONSerialization.jsonObject(with: Data(toolCalls.utf8)) as? [[String: Any]] else { return false }
        for c in calls {
            guard let f = c["function"] as? [String: Any], let fn = f["name"] as? String, fn == "skill_view" || fn == "skill_manage",
                let a = f["arguments"] as? String, let args = try? JSONSerialization.jsonObject(with: Data(a.utf8)) as? [String: Any]
            else { continue }
            if (args["name"] as? String) == name { return true }
            if let ops = args["operations"] as? [[String: Any]], ops.contains(where: { ($0["name"] as? String) == name }) { return true }
        }
        return false
    }

    // MARK: the morning brief's lines

    /// Up to 3 short lines: what last night learned (or would), one thing that needs a yes, and the score.
    static func morning(now: Date) -> [String] {
        let date = Improve.dayKey(now)
        if let r = ImproveNight.read(date), r.ended == nil, now.timeIntervalSince1970 - r.began > 3600 { ImproveNight.end(date: date, now: now) }
        var out: [String] = []
        let j = (try? Data(contentsOf: ImproveNight.reviewFile(date))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let night = ImproveNight.read(date)
        if let why = j?["skipped"] as? String {
            out.append("Last night's review didn't run (\(why.replacingOccurrences(of: "busy: ", with: ""))). It tries again tonight.")
        } else if j == nil {
            out.append(night == nil ? "Last night's review didn't run." : "Last night's review started but wrote no report.")
        } else {
            let lessons = (j?["lessons"] as? [[String: Any]]) ?? []
            let rules = lessons.filter { ($0["status"] as? String) == "rule" }.compactMap { $0["rule"] as? String }
            let applied = lessons.filter { ($0["applied"] as? Bool) == true }.compactMap { $0["rule"] as? String }
            let kept = night?.changed.contains { $0.undone == nil } == true
            if night?.mode == "edit", kept, !applied.isEmpty {
                out.append(
                    "Last night I learned \(applied.count) thing\(applied.count == 1 ? "" : "s"): \(short(applied)). Say \"undo last night\" to put it back."
                )
            } else if !rules.isEmpty {
                out.append(
                    "Last night's review found \(rules.count) lesson\(rules.count == 1 ? "" : "s") (suggestions only, nothing changed): \(short(rules))."
                )
            } else if lessons.isEmpty {
                out.append("Last night's review found nothing new to learn.")
            } else {
                out.append(
                    "Last night's review noted \(lessons.count) possible lesson\(lessons.count == 1 ? "" : "s"), each seen once so far "
                        + "(one becomes a rule only when it happens twice).")
            }
            if let note = night?.note, note.contains("put back") { out[0] += " (\(note).)" }
        }
        if let ask = j?["ask"] as? [String: Any], let t = ask["text"] as? String, !t.isEmpty {
            out.append("One thing needs your yes: \(t)")
        } else if let v = verdictLine(now: now) {
            out.append(v)
        }
        if let score = ImproveScore.brief(lastWeek: false, today: now).first { out.append(score) }
        return out
    }
    static func short(_ items: [String]) -> String {
        let first = items.prefix(2).map { Improve.short($0, 110) }.joined(separator: "; ")
        return items.count > 2 ? first + "; and \(items.count - 2) more" : first
    }
    static func verdictLine(now: Date) -> String? {
        for d in ImproveNight.dates().reversed() {
            guard let r = ImproveNight.read(d), let ended = r.ended, now.timeIntervalSince1970 - ended < 8 * 86400, let v = r.verdicts,
                let put = v.first(where: { $0.value.hasPrefix("put back") })
            else { continue }
            return "I put back my \(d) change to \(put.key): jobs using it went worse after."
        }
        return nil
    }

    // MARK: the morning note file

    /// `improve/morning/<date>.md`: the morning lines as a file, written when a night's review ends (and by the app
    /// after 5 AM if the review never ran `end`). The morning brief's pre-run script reads it (it never runs One's
    /// binary), and "Turn on safe edits" counts these notes to know the review really ran.
    static var morningDir: URL { Improve.dir.appendingPathComponent("morning", isDirectory: true) }
    static func writeMorning(date: String, now: Date) {
        try? FileManager.default.createDirectory(at: morningDir, withIntermediateDirectories: true)
        let text = morning(now: now).map { "- \($0)" }.joined(separator: "\n") + "\n"
        try? text.write(to: morningDir.appendingPathComponent("\(date).md"), atomically: true, encoding: .utf8)
    }

    // MARK: no morning brief: a card in Ready for you

    /// Once a day after 7 AM, for someone with no "Morning brief" routine: the morning lines as one card.
    static func tendShelf(now: Date = Date()) {
        guard !Env.commandLine, Calendar.current.component(.hour, from: now) >= 5 else { return }
        let date = Improve.dayKey(now)
        if let r = ImproveNight.read(date), now.timeIntervalSince1970 - r.began > 3600,
            !FileManager.default.fileExists(atPath: morningDir.appendingPathComponent("\(date).md").path)
        {
            writeMorning(date: date, now: now)  // the review never ran `end`: close it and leave the note
        }
        guard Calendar.current.component(.hour, from: now) >= 7 else { return }
        let stamp = Improve.dir.appendingPathComponent(".shelved")
        guard (try? String(contentsOf: stamp, encoding: .utf8)) != date, ImproveNight.read(date) != nil else { return }
        try? date.write(to: stamp, atomically: true, encoding: .utf8)
        guard !NightlyRoutine.jobs().contains(where: { (($0["name"] as? String) ?? "").lowercased().contains("morning brief") }) else { return }
        let text = "# Overnight review, \(date)\n\n" + morning(now: now).map { "- \($0)" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: Shelf.folder, withIntermediateDirectories: true)
        try? text.write(to: Shelf.folder.appendingPathComponent("\(date) Overnight review.md"), atomically: true, encoding: .utf8)
    }
}
