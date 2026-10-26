import Foundation

/// `One --test-helpers`: proves a helper cut off by a restart gets a trail file and is picked back up
/// exactly once at launch with its trail in the prompt, that a finished helper isn't, that a third
/// cut-off isn't picked up again, and that no more than 3 work at once. Run with ONE_SUPPORT_DIR set
/// to an empty folder. The engine calls are stand-ins and saved helpers go through in-memory data,
/// so the person's real settings and engine are never touched.
enum HelperCheck {
    @MainActor
    static func run() async -> Int32 {
        var fails = 0
        func check(_ name: String, _ ok: Bool) {
            print("  \(ok ? "✓" : "✗") \(name)")
            if !ok { fails += 1 }
        }
        check("runs as a command-line tool (never touches a real engine)", Env.commandLine)
        let fm = FileManager.default
        // One quits and opens again: what was saved is read back the way launch reads it.
        func relaunch(_ hs: [Helper]) -> [Helper] {
            guard let d = try? JSONEncoder().encode(hs), let back = try? JSONDecoder().decode([Helper].self, from: d) else { return [] }
            return HelperTrail.restore(back)
        }
        let brief = { (task: String) in "BRIEF: \(task)" }

        // A helper at work: One writes its trail as it goes.
        var job = Helper(
            title: "Flight prices", task: "Find the cheapest flight to Quebec City in December.", sid: "old-1", state: "working", line: "")
        job.started = Date()
        HelperTrail.flush(job)
        for s in ["Searching the web", "Searching the web", "Reading kayak.com"] { HelperTrail.add(s, to: &job) }
        job.reply = "So far the cheapest is $212 on Dec 20."
        HelperTrail.flush(job)
        let file = (try? String(contentsOf: HelperTrail.url(job.id), encoding: .utf8)) ?? ""
        check("the trail file is in One's own folder", HelperTrail.url(job.id).path.hasPrefix(Env.support.path + "/helpers/"))
        check("it has the whole job", file.contains(job.task))
        check("it has the steps, each once", file.contains("- Searching the web\n- Reading kayak.com"))
        check("and the latest reply", file.contains("$212"))

        var done = Helper(title: "Movie times", task: "Movie times tonight.", sid: "old-2", state: "done", line: "Done")
        done.reply = "7:40 and 9:15."
        let asks = Helper(title: "Buy tickets", task: "Buy 2 tickets.", sid: "old-3", state: "needsYes", line: "Needs your yes")

        // First restart.
        var hs = relaunch([job, done, asks])
        check("a working helper is queued to pick back up", hs[0].resumeQueued == true && hs[0].state == "stopped")
        check("a finished helper is left alone", hs[1].state == "done" && hs[1].resumeQueued != true)
        check("a helper waiting for a yes is left alone", hs[2].state == "needsYes" && hs[2].resumeQueued != true)
        var picked = HelperTrail.pick(&hs, brief: brief)
        check("it is picked back up once the engine is ready", picked.count == 1 && picked.first?.id == job.id)
        let prompt = picked.first?.prompt ?? ""
        check("the prompt says it was interrupted", prompt.hasPrefix("You were interrupted by a restart. Here's what you already did:"))
        check("with its trail", prompt.contains("- Searching the web\n- Reading kayak.com") && prompt.contains("$212"))
        check("and asks to check the real state first", prompt.contains("Check the real state first (files, git, releases) before redoing anything"))
        check("and the original job", prompt.contains("BRIEF: \(job.task)"))
        check("and never counts as a yes", prompt.contains("still needs their yes"))
        check("it's working again", hs[0].state == "working" && hs[0].resumes == 1)
        check("the person is told once", hs[0].restartNews == "Flight prices was interrupted by a restart. I picked it back up.")
        check("only once", HelperTrail.pick(&hs, brief: brief).isEmpty)

        // The old conversation is reopened if the engine can; otherwise a new one is opened.
        var opened = 0
        let same = await HelperTrail.session(
            old: "old-1", reopen: { _ in true },
            open: {
                opened += 1
                return "new"
            })
        check("reopens the old conversation when it can", same == "old-1" && opened == 0)
        let fresh = await HelperTrail.session(
            old: "old-1", reopen: { _ in false },
            open: {
                opened += 1
                return "new"
            })
        check("otherwise opens a new one", fresh == "new" && opened == 1)

        // Second restart: picked up a second time. Third: stopped, with a plain line.
        hs = relaunch(hs)
        picked = HelperTrail.pick(&hs, brief: brief)
        check("a second cut-off is picked up again", picked.count == 1 && hs[0].resumes == 2)
        hs = relaunch(hs)
        check("a third cut-off is not picked up", hs[0].resumeQueued == false && HelperTrail.pick(&hs, brief: brief).isEmpty)
        check("it shows as stopped with a plain line", hs[0].state == "stopped" && hs[0].line.hasPrefix("Stopped: cut off by a restart 3 times"))

        // Five cut off at once: 3 work, 2 wait for a free slot.
        var many = (1...5).map { Helper(title: "Job \($0)", task: "Task \($0)", sid: nil, state: "working", line: "") }
        many = relaunch(many)
        check("no more than 3 at once", HelperTrail.pick(&many, brief: brief).count == 3)
        check("the rest wait their turn", many.filter { $0.resumeQueued == true }.count == 2)
        many[0].state = "done"
        let next = HelperTrail.pick(&many, brief: brief)
        check("a free slot picks up the next one", next.count == 1 && next.first?.id == many[3].id)
        let waiting = relaunch(many)
        check("one still waiting when One stops again is still picked up later", waiting[4].resumeQueued == true)

        try? fm.removeItem(at: HelperTrail.folder)
        print(fails == 0 ? "helpers ok" : "helpers FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
