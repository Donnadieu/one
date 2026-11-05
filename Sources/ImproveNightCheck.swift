import Foundation

/// `One --test-nightly` (preflight, CI only): the nightly review's limits on a scratch brain. A suggestions-only night
/// that changes a recipe is put back; a new recipe folder (the filer's) is left alone; an edit night within the
/// limits is kept and "Undo last night" puts back only what is still as the night left it; over the nightly limit
/// or one recipe changed twice puts the whole night back; private rooms are never in what a night may edit; the
/// gate skips the AI while something else is working; the 7-day check puts back a change whose jobs went worse;
/// the morning lines; the pre-run script refuses an older One; the routine is made once and stays removed.
enum ImproveNightCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-nightly") else { return false }
        TestWorld.enter()  // scratch One folder (ONE_SUPPORT_DIR), own settings; CI only
        exit(run())
    }

    static func write(_ s: String, _ u: URL) { ImproveCheck.write(s, u) }
    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    static func run() -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "  ✓ " : "  ✗ ") + name)
            if !ok { fails += 1 }
        }
        let fm = FileManager.default
        let brain = Brain.root
        try? fm.removeItem(at: brain)
        write("# brain\n", brain.appendingPathComponent("AGENTS.md"))
        let mine = brain.appendingPathComponent("assistant/skills")
        for n in ["alpha", "beta", "gamma", "delta"] { write("---\nname: \(n)\n---\n# \(n)\n", mine.appendingPathComponent("\(n)/SKILL.md")) }
        let work = brain.appendingPathComponent("work-room")
        write("title: Work\nprivate: false\n", work.appendingPathComponent("room.yaml"))
        write("---\nname: board\n---\n# board\n", work.appendingPathComponent("skills/board/SKILL.md"))
        let nyx = brain.appendingPathComponent("nyx-room")
        write("title: Nyx\nprivate: true\n", nyx.appendingPathComponent("room.yaml"))
        write("---\nname: secret\n---\n", nyx.appendingPathComponent("skills/secret/SKILL.md"))
        let memory = Env.hermesHome.appendingPathComponent("memories/MEMORY.md")
        write("Fact one.\n", memory)
        let alpha = mine.appendingPathComponent("alpha/SKILL.md")
        let beta = mine.appendingPathComponent("beta/SKILL.md")
        let original = read(alpha)
        var s = ImproveSettings()
        let now = Date()

        // 1. Suggestions only: any change is put back; a new recipe folder isn't the review's and stays.
        Improve.save(s)
        var r = ImproveNight.begin(date: "2099-01-01", now: now)
        let roots = Set(r.roots.values)
        check("a night may edit assistant/skills and the work room's recipes", roots.contains(mine.standardizedFileURL.path) && roots.count == 2)
        check(
            "never a private room's recipes, and no notes on a suggestions night",
            !roots.contains { $0.contains("nyx-room") || $0.contains("memories") })
        write(original + "\n## Lessons\n- [L-x] a rule\n", alpha)
        write("---\nname: fresh\n---\n", mine.appendingPathComponent("fresh/SKILL.md"))
        r = ImproveNight.end(date: "2099-01-01", now: now) ?? r
        check("suggestions only: a changed recipe is put back", read(alpha) == original && r.note?.contains("put back") == true)
        check("a new recipe folder (the filer's) is left as it is", fm.fileExists(atPath: mine.appendingPathComponent("fresh/SKILL.md").path))

        // 2. Safe edits within the limits are kept; undo puts back only what's still as the night left it.
        s.mode = "edit"
        Improve.save(s)
        r = ImproveNight.begin(date: "2099-01-02", now: now)
        check("an edit night copies the notes too", r.roots.values.contains { $0.hasSuffix("memories") })
        write(original + "\n## Lessons\n- [L-a] rule a\n", alpha)
        write(read(beta) + "\n## Lessons\n- [L-b] rule b\n", beta)
        write("Fact one.\nFact two.\n", memory)
        r = ImproveNight.end(date: "2099-01-02", now: now) ?? r
        check("2 recipes and the notes changed, within the limit: kept", read(alpha).contains("L-a") && r.changed.allSatisfy { $0.undone == nil })
        write(read(beta) + "- changed by the person this morning\n", beta)
        let lines = ImproveNight.undo(now: now)
        check("undo last night puts the recipe back", read(alpha) == original)
        check("undo puts the notes back", read(memory) == "Fact one.\n")
        check(
            "a recipe changed again since is left alone, and undo says so",
            read(beta).contains("this morning") && lines.joined().contains("Left alone"))
        check("a second undo has nothing left to do", ImproveNight.undo(date: "2099-01-02", now: now).joined().contains("already"))

        // 3. Over the nightly limit: the whole night is put back.
        s.maxEditsPerNight = 2
        Improve.save(s)
        _ = ImproveNight.begin(date: "2099-01-03", now: now)
        for n in ["alpha", "gamma", "delta"] {
            write(read(mine.appendingPathComponent("\(n)/SKILL.md")) + "- more\n", mine.appendingPathComponent("\(n)/SKILL.md"))
        }
        r = ImproveNight.end(date: "2099-01-03", now: now) ?? r
        check("3 recipes over a limit of 2: the whole night is put back", read(alpha) == original && r.note?.contains("over the limit") == true)

        // 4. One recipe changed twice (the engine's change log): the night is put back.
        s.maxEditsPerNight = 5
        Improve.save(s)
        r = ImproveNight.begin(date: "2099-01-04", now: now)
        write(original + "- twice\n", alpha)
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let entry = "{\"ts\": \"\(ts)\", \"actor\": \"agent\", \"action\": \"patch\", \"skill\": \"alpha\"}\n"
        write(entry + entry, Env.hermesHome.appendingPathComponent("skills/.curator_ledger.jsonl"))
        r = ImproveNight.end(date: "2099-01-04", now: now.addingTimeInterval(120)) ?? r
        check("one recipe changed twice in a night: put back", read(alpha) == original && r.note?.contains("more than 1") == true)
        try? fm.removeItem(at: Env.hermesHome.appendingPathComponent("skills/.curator_ledger.jsonl"))

        // 5. The gate: busy (a helper wrote a minute ago) skips the AI run silently; idle hands over the moments.
        let db = Env.hermesHome.appendingPathComponent("state.db").path
        let f = ImproveCheck.Fixture(db)
        f.session("helper-1", "acp", now.timeIntervalSince1970 - 120, [("user", "Do the job.", nil, 0), ("assistant", "On it.", nil, 1)])
        f.close()
        let busy = ImproveNightRun.prepare(now: now, waitMinutes: 0.1)
        check("busy: the AI run is skipped (wakeAgent false)", busy.hasSuffix("{\"wakeAgent\": false}\n"))
        let skipped = ImproveNightRun.morning(now: now).first ?? ""
        check("busy: the morning says it didn't run", skipped.contains("didn't run"))
        let f2 = ImproveCheck.Fixture(db)  // a fresh history: nothing in the last 10 minutes
        f2.session("helper-1", "acp", now.timeIntervalSince1970 - 7200, [("user", "Do the job.", nil, 0), ("assistant", "Done.", nil, 1)])
        f2.close()
        try? fm.removeItem(at: ImproveNight.recordFile(Improve.dayKey(now)))
        let idle = ImproveNightRun.prepare(now: now, waitMinutes: 0.1)
        check(
            "idle: the review gets its mode, files and recipes",
            idle.contains("MODE: edit") && idle.contains(alpha.path) && idle.contains("REVIEW FILE"))
        check("idle: never a private room's recipe", !idle.contains("nyx-room"))

        // 6. The 7-day check: a change whose jobs went worse is put back.
        s.mode = "edit"
        Improve.save(s)
        let old = now.addingTimeInterval(-9 * 86400)
        let key = Improve.dayKey(old)
        _ = ImproveNight.begin(date: key, now: old)
        write(original + "- a lesson that made it worse\n", alpha)
        _ = ImproveNight.end(date: key, now: old)
        let f3 = ImproveCheck.Fixture(db)
        let view = ImproveCheck.call("skill_view", "{\"name\": \"alpha\"}")
        var days: [String: [ImproveEvent]] = [:]
        for i in 0..<4 {
            let b = old.timeIntervalSince1970 - Double(i + 1) * 86400
            let a = old.timeIntervalSince1970 + Double(i + 1) * 86400
            f3.session("before-\(i)", "acp", b, [("assistant", "", view, 1)])
            f3.session("after-\(i)", "acp", a, [("assistant", "", view, 1)])
            if i > 0 { days[Improve.dayKey(ts: a), default: []].append(ImproveEvent("correction", "said", at: a + 120, session: "after-\(i)")) }
        }
        f3.close()
        for (d, ev) in days {
            Improve.writeDay(ImproveDay(date: d, collected: d, counts: [:], signals: [:], kinds: [:], events: ev, incidents: []))
        }
        let verdict = ImproveNightRun.verdicts(now: now)
        check("7 days on, 3 of 4 jobs went wrong after vs 0 of 4 before: the change is put back", read(alpha) == original && verdict.count == 1)
        check("the verdict is kept with the night", ImproveNight.read(key)?.verdicts?["alpha"]?.hasPrefix("put back") == true)

        // 7. The morning lines.
        let today = Improve.dayKey(now)
        _ = ImproveNight.begin(date: today, now: now)
        write(original + "\n## Lessons\n- [L-c] Give the result in the chat.\n", alpha)
        _ = ImproveNight.end(date: today, now: now)
        let review: [String: Any] = [
            "date": today, "mode": "edit",
            "lessons": [["key": "c", "skill": "alpha", "rule": "Give the result in the chat.", "status": "rule", "applied": true]],
            "ask": ["text": "Make a recipe for weekly invoices? (seen in 3 jobs)", "choices": ["Yes", "Not now"]],
        ]
        try? JSONSerialization.data(withJSONObject: review).write(to: ImproveNight.reviewFile(today))
        let m = ImproveNightRun.morning(now: now)
        check(
            "morning line 1: what it learned, and how to undo",
            m.first?.contains("Last night I learned 1 thing") == true && m.first?.contains("undo last night") == true)
        check("morning line 2: the one thing that needs a yes", m.count > 1 && m[1].hasPrefix("One thing needs your yes"))
        check("morning line 3: the score", m.count == 3 && (m[2].contains("Right the first time") || m[2].contains("score")))

        // 8. The pre-run script refuses a One older than 0.9.90 (it would open its window), runs a new one.
        let apps = Env.support.appendingPathComponent("apps")
        func fakeApp(_ v: String) -> String {
            let c = apps.appendingPathComponent("\(v)/One.app/Contents")
            write(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                    + "<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>\(v)</string></dict></plist>\n",
                c.appendingPathComponent("Info.plist"))
            let exe = c.appendingPathComponent("MacOS/One")
            write("#!/bin/bash\necho \"prepared $*\"\n", exe)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            return exe.path
        }
        func runScript(_ exe: String) -> String {
            NightlyRoutine.writeScript(exe: exe)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [NightlyRoutine.scriptFile.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        check("the script skips an older One (0.9.88) silently", runScript(fakeApp("0.9.88")).hasSuffix("{\"wakeAgent\": false}\n"))
        check("the script runs prepare on 0.9.90", runScript(fakeApp("0.9.90")).contains("prepared --improve night prepare"))
        check("and on 0.10.1", runScript(fakeApp("0.10.1")).contains("prepared --improve night prepare"))

        // 9. The routine: adopted if it exists by name, made once, never brought back once removed.
        let cron = Routines.cron.appendingPathComponent("jobs.json")
        try? fm.createDirectory(at: Routines.cron, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["jobs": [["id": "abc123", "name": NightlyRoutine.name]]]).write(to: cron)
        try? fm.removeItem(at: NightlyRoutine.markerFile)
        let sem = DispatchSemaphore(value: 0)
        let box = Said()
        Task.detached {
            box.add(await NightlyRoutine.ensure())
            box.add(await NightlyRoutine.ensure())
            try? JSONSerialization.data(withJSONObject: ["jobs": [[String: Any]]()]).write(to: cron)
            box.add(await NightlyRoutine.ensure())
            sem.signal()
        }
        sem.wait()
        let said = box.all
        check("an existing Nightly review is adopted, not doubled", said.first == "adopted" && said.count == 3 && said[1] == "already there")
        check("removed by the person: stays removed", said.last?.hasPrefix("removed") == true)
        check("the engine's learning cap has its settings file", fm.fileExists(atPath: Improve.settingsFile.path))

        print(fails == 0 ? "nightly ok" : "nightly failed: \(fails)")
        return fails == 0 ? 0 : 1
    }

    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.withLock { items.append(s) } }
        var all: [String] { lock.withLock { items } }
    }
}
