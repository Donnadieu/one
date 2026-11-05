import Foundation

/// The nightly review part of `One --test-improve` (CI only, scratch One folder): the built-in routine is added once into
/// the scratch engine home and updated only when its version changes, the morning note and its Ready for you card, edits
/// recorded / checked a week later / undone with a stand-in engine, and the learning cap plugin installed.
enum ImproveNightlyCheck {
    /// A stand-in for `hermes`: remembers every call and keeps `cron/jobs.json` the way the engine would.
    final class FakeEngine: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        func run(_ a: [String]) -> (Int32, String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(a)
            var jobs = NightlyReview.jobs()
            if a.starts(with: ["cron", "create"]), a.count >= 4 {
                let name = a.firstIndex(of: "--name").map { a[$0 + 1] } ?? ""
                let deliver = a.firstIndex(of: "--deliver").map { a[$0 + 1] } ?? ""
                jobs.append([
                    "id": "nr\(jobs.count + 1)", "name": name, "prompt": a[3], "schedule": ["kind": "cron", "expr": a[2]], "deliver": deliver,
                    "enabled": true,
                ])
            } else if a.starts(with: ["cron", "edit"]), a.count >= 5, let k = jobs.firstIndex(where: { ($0["id"] as? String) == a[2] }) {
                jobs[k]["prompt"] = a[4]
            } else {
                return (0, "curator: done")
            }
            ImproveCheck.write(
                String(data: (try? JSONSerialization.data(withJSONObject: ["jobs": jobs])) ?? Data(), encoding: .utf8) ?? "", NightlyReview.jobsFile)
            return (0, "ok")
        }
        var runner: HermesRunner { { a in self.run(a) } }
        func take() -> [[String]] {
            lock.lock()
            defer { lock.unlock() }
            let c = calls
            calls = []
            return c
        }
    }

    final class Box<T>: @unchecked Sendable {
        var v: T?
        init(_ v: T? = nil) { self.v = v }
    }

    static func block<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.v = await body()
            sem.signal()
        }
        sem.wait()
        return box.v!
    }

    static func run() -> Int {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        let engine = FakeEngine()
        try? FileManager.default.removeItem(at: NightlyReview.jobsFile)

        // The routine: added once, quiet, updated only when the version changes, someone else's never touched.
        let bundled = NightlyReview.promptFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        check("the nightly review prompt ships inside One", bundled?.hasPrefix(NightlyReview.marker) == true)
        let text = bundled ?? NightlyReview.marker + ", version 1).\nRun `ONE --improve collect`.\nYour final answer: exactly [SILENT]\n"
        check("added to a fresh engine home", block { await NightlyReview.ensure(promptText: text, run: engine.runner) } == "added")
        let made = engine.take()
        let job = NightlyReview.jobs().first { ($0["name"] as? String) == NightlyReview.name }
        let prompt = (job?["prompt"] as? String) ?? ""
        check(
            "one engine routine \"Nightly review\" at 3:30 am, delivered nowhere",
            made.count == 1 && made.first?.starts(with: ["cron", "create", "30 3 * * *"]) == true && made.first?.contains("local") == true
                && NightlyReview.jobs().count == 1)
        check(
            "its answer is exactly [SILENT] (One never reads it aloud), One's real paths filled in",
            prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exactly [SILENT]") && prompt.contains(Bridge.exe)
                && !prompt.contains("{ONE}") && !prompt.contains("`ONE ")
                && prompt.components(separatedBy: "\n").first?.contains("Fingerprint") == true)
        check(
            "suggestions only by default, never a whole rewrite or a new skill",
            bundled == nil || (prompt.contains("change nothing") && prompt.contains("never create a skill") && prompt.contains("[L-0142]")))
        check("never twice", block { await NightlyReview.ensure(promptText: text, run: engine.runner) } == "up to date" && engine.take().isEmpty)
        var jobs = NightlyReview.jobs()
        jobs[0]["prompt"] = NightlyReview.marker + ", version 0). Old words.\nold"
        ImproveCheck.write(
            String(data: (try? JSONSerialization.data(withJSONObject: ["jobs": jobs])) ?? Data(), encoding: .utf8) ?? "", NightlyReview.jobsFile)
        let updated = block { await NightlyReview.ensure(promptText: text, run: engine.runner) }
        let edits = engine.take()
        check(
            "a new version of the prompt replaces the old one",
            updated == "updated" && edits.count == 1 && edits.first?.starts(with: ["cron", "edit", "nr1", "--prompt"]) == true)
        jobs = NightlyReview.jobs()
        jobs[0]["prompt"] = "My own nightly review, my words."
        ImproveCheck.write(
            String(data: (try? JSONSerialization.data(withJSONObject: ["jobs": jobs])) ?? Data(), encoding: .utf8) ?? "", NightlyReview.jobsFile)
        check(
            "a routine of theirs with that name is never touched",
            block { await NightlyReview.ensure(promptText: text, run: engine.runner) } == "kept")
        let steps = "1. `ONE --improve collect`\n2. `ONE --link-guard --dry-run` [needs: LinkGuard]\nYour final answer: exactly [SILENT]"
        let without = NightlyReview.render(NightlyReview.marker + ", version 9).\n" + steps, present: { _ in false })
        let with = NightlyReview.render(NightlyReview.marker + ", version 9).\n" + steps, present: { _ in true })
        check(
            "a step needing a part this copy lacks is left out (an unknown command would open the whole app)",
            !without.contains("--link-guard") && without.contains("Skipped") && with.contains("--link-guard --dry-run") && !with.contains("[needs:"))
        check("parts are found by Swift's own type list", NightlyReview.has("ImproveCLI") && !NightlyReview.has("NoSuchPartAnywhere"))

        // The morning note, and its card when there's no morning brief.
        let day = "2027-03-15"
        ImproveCheck.write(
            "# Morning\n\nI'd add 1 rule to pdf: give the result in the chat.\n\nRight the first time: 66% → 69% this week.\n",
            NightlyReview.morningDir.appendingPathComponent("\(day).md"))
        let lines = NightlyReview.morning(day)
        check("morning: the note's lines, no heading", lines.count == 2 && lines.last?.hasPrefix("Right the first time") == true)
        check("morning: nothing when there's no note", NightlyReview.morning("2027-03-16").isEmpty)
        let card = NightlyReview.card(day, lines)
        check(
            "no morning brief: the note becomes a Ready for you card",
            card?.lastPathComponent == "\(day) Last night's review.md" && FileManager.default.fileExists(atPath: card?.path ?? "/nope"))
        jobs = NightlyReview.jobs()
        jobs.append(["id": "mb", "name": "Morning brief", "prompt": "brief"])
        ImproveCheck.write(
            String(data: (try? JSONSerialization.data(withJSONObject: ["jobs": jobs])) ?? Data(), encoding: .utf8) ?? "", NightlyReview.jobsFile)
        check("with a morning brief: no card (the brief shows it)", NightlyReview.card("2027-03-14", lines) == nil)

        // Edits: recorded, checked a week later, undone.
        let iso = ISO8601DateFormatter()
        guard let now = iso.date(from: "2027-03-15T12:00:00Z") else { return fails + 1 }
        let ago = { (d: Double) in now.addingTimeInterval(-d * 86400) }
        func ledger(_ id: String, _ skill: String, _ at: Date) -> String {
            "{\"id\": \"\(id)\", \"ts\": \"\(iso.string(from: at))\", \"actor\": \"agent\", \"action\": \"patch\", \"skill\": \"\(skill)\", \"evidence\": {}, \"after\": []}"
        }
        ImproveCheck.write(
            [ledger("e1", "pdf", ago(9)), ledger("e2", "notes", ago(9)), ledger("e3", "pdf", ago(0.3)), ledger("e4", "notes", ago(0.2))].joined(
                separator: "\n") + "\n", ImproveEdits.ledger)
        let r = ImproveEdits.record(["e1", "e2", "nope"], now: ago(9))
        check(
            "record: ids from the change log kept with their skill; an unknown id refused",
            r.added.map(\.skill) == ["pdf", "notes"] && r.unknown == ["nope"])
        check("record: never twice", ImproveEdits.record(["e1"], now: ago(9)).added.isEmpty)
        func routed(_ at: Date, _ skill: String, _ ok: Bool) -> [String: Any] {
            ["date": iso.string(from: at), "kind": "Job \(at)", "skills": [skill], "ok": ok]
        }
        let memory: [[String: Any]] = [
            routed(ago(12), "pdf", true), routed(ago(11), "pdf", true), routed(ago(8), "pdf", false), routed(ago(7), "pdf", false),
            routed(ago(5), "pdf", true),
            routed(ago(12), "notes", true), routed(ago(8), "notes", true), routed(ago(6), "notes", true), routed(ago(4), "notes", true),
        ]
        ImproveCheck.write(
            String(data: (try? JSONSerialization.data(withJSONObject: ["memory": memory])) ?? Data(), encoding: .utf8) ?? "", ImproveEdits.routingFile
        )
        let out = block { await ImproveEdits.check(now: now, run: engine.runner) }
        let calls = engine.take()
        let after = ImproveEdits.load(Improve.dayKey(ago(9)))
        check(
            "check: worse after (3 jobs, 0.0 → 0.7 problems a job) → rolled back with one plain line",
            calls == [["curator", "rollback", "e1", "--yes"]] && out.first?.hasPrefix("I undid the lesson I added to pdf") == true)
        check(
            "check: no worse → kept; both judged",
            after.first { $0.id == "e1" }?.judged == "undone" && after.first { $0.id == "e2" }?.judged == "kept")
        check(
            "check: judged once only",
            block { await ImproveEdits.check(now: now, run: engine.runner) } == ["No changes old enough to check yet."] && engine.take().isEmpty)

        _ = ImproveEdits.record(["e3"], now: ago(0.3))
        _ = ImproveEdits.record(["e4"], now: ago(0.2))
        let copy = "\(Improve.dayKey(ago(0.4)).prefix(10)) 0330 before nightly review"
        try? FileManager.default.createDirectory(
            at: Env.support.appendingPathComponent("history/\(copy)", isDirectory: true), withIntermediateDirectories: true)
        let seen = Box<[String]>([])
        let undo = block {
            await ImproveEdits.undoLastNight(
                now: now, run: engine.runner,
                restore: { n in
                    seen.v?.append(n)
                    return (0, "Put back 3 files.")
                })
        }
        check(
            "undo last night: every change rolled back, newest first",
            engine.take() == [["curator", "rollback", "e4", "--yes"], ["curator", "rollback", "e3", "--yes"]]
                && undo.first == "I put back 2 changes from last night (notes, pdf).")
        check(
            "undo last night: the safety copy put back with One --restore --snapshot",
            seen.v == [copy] && undo.contains { $0.contains("Put back 3 files.") })
        let again = block { await ImproveEdits.undoLastNight(now: now, run: engine.runner, restore: { _ in (0, "again") }) }
        check(
            "undo last night twice: nothing left to put back",
            again == ["Nothing was changed last night, so there's nothing to put back."] && engine.take().isEmpty)
        check(
            "a copy of One without the history part says so instead of opening itself",
            NightlyReview.has("History") || ImproveEdits.restoreCopy("x").0 == 2)
        check(
            "the assistant knows \"undo last night\"",
            NightlyReview.note.contains("--improve undo-last-night"))

        // The learning cap: installed into the engine home, turned on next to the other plugins.
        let cfg = EnginePlugins.configFile
        try? FileManager.default.removeItem(at: Improve.settingsFile)
        ImproveCheck.write("model:\n  default: x\nplugins:\n  enabled:\n    - one-browser-guard\n  disabled: [one-learning-cap]\n", cfg)
        let src = Bundle.main.url(forResource: LearningCap.plugin, withExtension: nil)
        block { await LearningCap.sync(from: src, run: engine.runner) }
        let set = engine.take()
        check(
            "learning cap: copied into the engine's plugins",
            FileManager.default.fileExists(atPath: LearningCap.pluginDir.appendingPathComponent("__init__.py").path)
                && FileManager.default.fileExists(atPath: LearningCap.pluginDir.appendingPathComponent("plugin.yaml").path))
        check(
            "learning cap: turned on, other plugins kept, taken off the disabled list",
            set.contains(["config", "set", "plugins.enabled", "[\"one-browser-guard\", \"one-learning-cap\"]", "--force"])
                && set.contains(["config", "set", "plugins.disabled", "[]", "--force"]))
        check("learning cap: its folder is read-only to the engine", BrowserGuard.lockedPaths.contains(LearningCap.pluginDir.path))
        check(
            "learning cap: settings written with their defaults (suggest, 5 a night, 1 per skill)",
            FileManager.default.fileExists(atPath: Improve.settingsFile.path) && Improve.settings().maxEditsPerNight == 5
                && Improve.settings().maxEditsPerSkill == 1 && Improve.settings().mode == "suggest")
        return fails
    }
}
