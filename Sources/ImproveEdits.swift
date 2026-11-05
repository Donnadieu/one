import Foundation

// MARK: - Changes the nightly review made: recorded, checked a week later, undone on request
// Design "One gets better by itself", sections 4 and 5: every change is a skill_manage edit with an id in the engine's
// skill change log (`skills/.curator_ledger.jsonl`), so `hermes curator rollback <id>` puts it back.
//   One --improve edits record <ledger-id>…   remembered in improve/edits/<date>.json (id, skill, time)
//   One --improve edits check                 a week on: the jobs that used that skill before vs after; worse → undone
//   One --improve undo-last-night             last night's changes undone (newest first) + the safety copy put back

struct ImproveEdit: Codable, Equatable {
    var id: String
    var skill: String
    var time: String  // ISO 8601
    var judged: String?  // kept | undone | worse, kept (auto undo off) | undone by you | …
    var undone: Bool?
}

enum ImproveEdits {
    static var dir: URL { Improve.dir.appendingPathComponent("edits", isDirectory: true) }
    static func file(_ day: String) -> URL { dir.appendingPathComponent("\(day).json") }
    static var ledger: URL { Env.hermesHome.appendingPathComponent("skills/.curator_ledger.jsonl") }
    static var routingFile: URL { Env.support.appendingPathComponent(Env.selfTest ? "selftest-routing.json" : "routing.json") }

    static func load(_ day: String) -> [ImproveEdit] {
        guard let d = try? Data(contentsOf: file(day)) else { return [] }
        return (try? JSONDecoder().decode([ImproveEdit].self, from: d)) ?? []
    }
    static func save(_ day: String, _ edits: [ImproveEdit]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? enc.encode(edits).write(to: file(day), options: .atomic)
    }
    static func days() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .sorted()
    }
    static func date(_ iso: String) -> Date? { ISO8601DateFormatter().date(from: iso) }

    /// The skill change log, by id.
    static func changes() -> [String: LedgerLine] {
        let t = (try? String(contentsOf: ledger, encoding: .utf8)) ?? ""
        return Dictionary(t.split(separator: "\n").compactMap(LedgerLine.parse).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// Remembers the review's changes. Ids not in the change log are refused (nothing could undo them).
    static func record(_ ids: [String], now: Date = Date()) -> (added: [ImproveEdit], unknown: [String]) {
        let log = changes()
        let day = Improve.dayKey(now)
        var list = load(day)
        var added: [ImproveEdit] = []
        var unknown: [String] = []
        for id in ids {
            guard let l = log[id] else {
                unknown.append(id)
                continue
            }
            guard !days().contains(where: { d in load(d).contains { $0.id == id } }) && !list.contains(where: { $0.id == id }) else { continue }
            let e = ImproveEdit(id: id, skill: l.skill, time: Improve.iso(now.timeIntervalSince1970))
            list.append(e)
            added.append(e)
        }
        if !added.isEmpty { save(day, list) }
        return (added, unknown)
    }

    // MARK: A week later: did the jobs that used the skill get better or worse?

    struct Tally: Equatable {
        var jobs = 0
        var problems = 0
        var rate: Double { jobs == 0 ? 0 : Double(problems) / Double(jobs) }
    }

    /// Jobs that used `skill` between `from` and `to` (smart routing remembers the recipes each job used), and their
    /// problems: a job that didn't work out, and the collector's corrections, redos and failures for those jobs (or for
    /// helpers whose first step was that skill).
    static func tally(_ skill: String, from: Date, to: Date) -> Tally {
        var t = Tally()
        var titles = Set<String>()
        let iso = ISO8601DateFormatter()
        if let d = try? Data(contentsOf: routingFile), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            for m in (j["memory"] as? [[String: Any]]) ?? [] {
                guard let at = (m["date"] as? String).flatMap(iso.date), at >= from, at < to, ((m["skills"] as? [String]) ?? []).contains(skill)
                else { continue }
                t.jobs += 1
                if (m["ok"] as? Bool) == false { t.problems += 1 }
                if let k = m["kind"] as? String { titles.insert(k) }
            }
        }
        var day = Calendar.current.startOfDay(for: from)
        while day < to {
            for e in Improve.readDay(Improve.dayKey(day))?.events ?? [] where e.ts >= from.timeIntervalSince1970 && e.ts < to.timeIntervalSince1970 {
                let bad = e.kind == "correction" || e.sub == "helper_failed"
                if bad, e.title.map(titles.contains) == true || e.jobKind == skill { t.problems += 1 }
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? to
        }
        return t
    }

    static func rate(_ t: Tally) -> String { String(format: "%.1f", t.rate) }
    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    /// Every change 7 or more days old and not judged yet: with 3 or more jobs after it (and some before) and more problems
    /// per job than before, it's rolled back (when `auto_undo_on_drop` is on). Judged either way. Returns plain lines.
    static func check(now: Date = Date(), run: HermesRunner = { await hermesRun($0) }) async -> [String] {
        var out: [String] = []
        var judged = 0
        let auto = Improve.settings().autoUndoOnDrop
        for day in days() {
            var list = load(day)
            var changed = false
            for k in list.indices where list[k].judged == nil && list[k].undone != true {
                guard let at = date(list[k].time), now.timeIntervalSince(at) >= 7 * 86400 else { continue }
                let e = list[k]
                let before = tally(e.skill, from: at.addingTimeInterval(-7 * 86400), to: at)
                let after = tally(e.skill, from: at, to: at.addingTimeInterval(7 * 86400))
                changed = true
                judged += 1
                guard after.jobs >= 3, before.jobs >= 1, after.rate > before.rate else {
                    list[k].judged = after.jobs >= 3 && before.jobs >= 1 ? "kept" : "kept (not enough jobs to tell)"
                    continue
                }
                let numbers = "\(rate(before)) → \(rate(after)) problems a job"
                guard auto else {
                    list[k].judged = "worse, kept (auto undo is off)"
                    out.append(
                        "The lesson I added to \(e.skill) on \(when(at)) seems to have made things worse (\(numbers)). I left it, since automatic undo is off."
                    )
                    continue
                }
                let (code, msg) = await run(["curator", "rollback", e.id, "--yes"])
                if code == 0 {
                    list[k].judged = "undone"
                    list[k].undone = true
                    out.append("I undid the lesson I added to \(e.skill) on \(when(at)): jobs using it went worse (\(numbers)).")
                } else {
                    list[k].judged = "undo failed"
                    out.append(
                        "The lesson I added to \(e.skill) on \(when(at)) made things worse, and I couldn't undo it: \(msg.split(separator: "\n").last ?? "")."
                    )
                }
            }
            if changed { save(day, list) }
        }
        if out.isEmpty {
            out.append(
                judged == 0 ? "No changes old enough to check yet." : "Checked \(judged) change\(judged == 1 ? "" : "s") from a week ago: kept.")
        }
        return out
    }

    // MARK: "Undo last night"

    /// The newest copy labeled "before nightly review" from today or yesterday (`history/<YYYY-MM-DD HHMM> before nightly review`).
    static func lastSafetyCopy(now: Date = Date()) -> String? {
        let folder = Env.support.appendingPathComponent("history", isDirectory: true)
        let days = [Improve.dayKey(now), Improve.dayKey(now.addingTimeInterval(-86400))]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { n in
            n.hasSuffix(" before nightly review") && n.range(of: #"^\d{4}-\d{2}-\d{2} \d{4} "#, options: .regularExpression) != nil
                && days.contains(String(n.prefix(10)))
        }
        return names.sorted().last
    }

    /// Puts the brain back as it was in a history copy, with One's own `--restore --snapshot` (the history part of One).
    /// That part may not be in every build, and a command One doesn't know would open the whole app, so it's asked first.
    static func restoreCopy(_ name: String) -> (Int32, String) {
        guard NightlyReview.has("History"), let exe = Bundle.main.executablePath else {
            return (2, "This copy of One can't put the notes back from a copy yet (it has no One --restore).")
        }
        return Bridge.runSelf(exe, ["--restore", "--snapshot", name])
    }

    /// Undoes every change recorded last night (the newest night on record, if it's today or yesterday), newest first,
    /// then puts back last night's safety copy when there is one. Returns plain lines.
    static func undoLastNight(
        now: Date = Date(), run: HermesRunner = { await hermesRun($0) }, restore: (String) -> (Int32, String) = restoreCopy
    ) async -> [String] {
        var out: [String] = []
        let recent = [Improve.dayKey(now.addingTimeInterval(-86400)), Improve.dayKey(now)]
        if let day = days().last(where: recent.contains) {
            var list = load(day)
            var back: [String] = []
            var failed: [String] = []
            for k in list.indices.sorted(by: { list[$0].time > list[$1].time }) where list[k].undone != true {
                let (code, msg) = await run(["curator", "rollback", list[k].id, "--yes"])
                if code == 0 {
                    list[k].undone = true
                    list[k].judged = "undone by you"
                    back.append(list[k].skill)
                } else {
                    failed.append("\(list[k].skill) (\(msg.split(separator: "\n").last ?? ""))")
                }
            }
            save(day, list)
            if !back.isEmpty {
                let names = Array(Set(back)).sorted().joined(separator: ", ")
                out.append("I put back \(back.count) change\(back.count == 1 ? "" : "s") from last night (\(names)).")
            }
            if !failed.isEmpty { out.append("I couldn't put back: \(failed.joined(separator: "; ")).") }
        }
        let restoredFile = dir.appendingPathComponent(".restored")
        let restored = ((try? String(contentsOf: restoredFile, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if let copy = lastSafetyCopy(now: now), !restored.contains(copy) {
            let (code, msg) = restore(copy)
            out.append(code == 0 ? "Your notes are back as they were before last night's review. \(msg)" : msg)
            if code == 0 {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? (restored.filter { !$0.isEmpty } + [copy]).joined(separator: "\n").write(to: restoredFile, atomically: true, encoding: .utf8)
            }
        }
        if out.isEmpty { out.append("Nothing was changed last night, so there's nothing to put back.") }
        return out
    }

    // MARK: Command line

    /// Runs async work from the command line and waits for it.
    static func wait(_ body: @escaping @Sendable () async -> [String]) -> [String] {
        final class Box: @unchecked Sendable { var v: [String] = [] }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.v = await body()
            sem.signal()
        }
        sem.wait()
        return box.v
    }

    /// `One --improve edits record <id>… | edits check`, `One --improve undo-last-night`. Nil when not one of these.
    static func cli(_ a: [String]) -> Int32? {
        switch a.first ?? "" {
        case "edits":
            switch a.dropFirst().first ?? "" {
            case "record":
                let ids = Array(a.dropFirst(2))
                guard !ids.isEmpty else { return ImproveCLI.bad("usage: One --improve edits record <ledger-id> [<ledger-id> …]") }
                let r = record(ids)
                for e in r.added { print("recorded \(e.id) (\(e.skill))") }
                for id in r.unknown { print("\(id) isn't in the skill change log, so it couldn't be undone: not recorded") }
                return r.unknown.isEmpty ? 0 : 1
            case "check":
                wait { await check() }.forEach { print($0) }
                return 0
            default:
                return ImproveCLI.bad("usage: One --improve edits record <ledger-id>… | edits check")
            }
        case "undo-last-night":
            wait { await undoLastNight() }.forEach { print($0) }
            return 0
        default:
            return nil
        }
    }
}

extension Bridge {
    /// Runs One's own program with `args` and waits ("undo last night" puts last night's safety copy back this way).
    static func runSelf(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe()
        p.standardOutput = o
        p.standardError = o
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
