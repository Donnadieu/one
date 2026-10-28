import Foundation

/// `One --test-helpers`: proves a helper cut off by a restart gets a trail file and is picked back up
/// exactly once at launch with its trail in the prompt, that a finished helper isn't, that a third
/// cut-off isn't picked up again, and that every helper cut off is picked up at once (no limit of 3). Run with ONE_SUPPORT_DIR set
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

        // Five cut off at once: all five pick back up together, none waits for a slot.
        var many = (1...5).map { Helper(title: "Job \($0)", task: "Task \($0)", sid: nil, state: "working", line: "") }
        many = relaunch(many)
        check("five cut off at once are all picked up together", HelperTrail.pick(&many, brief: brief).count == 5)
        check("none is left waiting", many.allSatisfy { $0.resumeQueued != true && $0.state == "working" })

        // Stopped on purpose (the Stop button) vs cut off by a restart.
        var mine = Helper(title: "Price watch", task: "Watch the price.", sid: "s-1", state: "working", line: "")
        let cutOff = Helper(title: "Hotel search", task: "Find a hotel.", sid: "s-2", state: "working", line: "")
        var queued = Helper(title: "Queued job", task: "Wait.", sid: "s-3", state: "stopped", line: "")
        queued.resumeQueued = true
        check("Stop on a working helper asks to cancel its work", HelperTrail.stopByYou(&mine))
        check("and Stop on one waiting to be picked up doesn't", !HelperTrail.stopByYou(&queued))
        check("Stop leaves it stopped with a plain line", mine.state == "stopped" && mine.line == HelperTrail.stoppedLine)
        var after = relaunch([mine, cutOff, queued])
        check("a helper stopped with Stop is not picked back up at launch", after[0].resumeQueued != true && after[0].state == "stopped")
        check("nor one stopped while it waited to be picked up", after[2].resumeQueued != true)
        check("one cut off by a restart still is", after[1].resumeQueued == true)
        let again = HelperTrail.pick(&after, brief: brief)
        check("only the cut-off one is picked up", again.count == 1 && again.first?.id == cutOff.id)
        var saved = mine
        saved.state = "working"  // saved before its cancel came back
        check("even if One quit before the cancel landed", relaunch([saved])[0].resumeQueued != true)
        check("and it stays stopped after another restart", relaunch(relaunch([mine]))[0].state == "stopped")

        quotedTags(check)

        // Stop by chat: the assistant's [stop-helper: …] line.
        let (said, names) = HelperStop.extract("Stopped Flight to Quebec.\n[stop-helper: Flight to Quebec]\n[STOP-HELPER: all]\n")
        check("a stop line is taken out of the reply", said == "Stopped Flight to Quebec." && names == ["Flight to Quebec", "all"])
        check("and hidden while it streams", Helpers.strip("Ok.\n[stop-helper: X]") == "Ok." && Helpers.strip("Ok. [stop-hel") == "Ok.")
        let (inl, inlNames) = HelperStop.extract("By the way, X is done.[stop-helper: Price check]  Stopped Price check.")
        check("the same stop line twice stops it once", HelperStop.extract("[stop-helper: A]\n[stop-helper: a]").1 == ["A"])
        check(
            "a stop line run into a sentence is taken out too", inlNames == ["Price check"] && inl == "By the way, X is done.\nStopped Price check.")
        var t1 = Helper(title: "Flight to Quebec", task: "", sid: nil, state: "working", line: "")
        t1.started = Date(timeIntervalSince1970: 100)
        var t2 = Helper(title: "flight to quebec", task: "", sid: nil, state: "working", line: "")
        t2.started = Date(timeIntervalSince1970: 200)
        let t3 = Helper(title: "Hotel", task: "", sid: nil, state: "working", line: "")
        let t4 = Helper(title: "Flight to Quebec", task: "", sid: nil, state: "done", line: "")
        let pool = [t1, t2, t3, t4]
        check("a stop line matches the title in any case, the most recent on ties", HelperStop.match("FLIGHT TO QUEBEC", in: pool) == [t2.id])
        check("\"all\" means every helper still at work", Set(HelperStop.match("all", in: pool)) == Set([t1.id, t2.id, t3.id]))
        check("a finished helper or an unknown name matches nothing", HelperStop.match("Movie times", in: pool).isEmpty)
        check(
            "the assistant is told how, every turn and in its SOUL",
            Helpers.note.contains("[stop-helper: all]") && HelperStop.soul.contains("[stop-helper:"))

        // An update never stops a helper: it's paused, picks back up after the restart, and that isn't counted as a cut-off.
        var upd = Helper(title: "Long job", task: "Do it.", sid: "s-9", state: "working", line: "")
        upd.resumes = HelperTrail.maxResumes  // even one already picked up the most times
        HelperStop.pauseForUpdate(&upd)
        check("an update pauses a working helper", upd.state == "stopped" && upd.resumeQueued == true && upd.stoppedByYou != true)
        var back = relaunch([upd])
        check("after the update it's queued to pick back up", back[0].resumeQueued == true && back[0].line == HelperStop.pausedLine)
        check("never marked stopped by you", back[0].stoppedByYou != true && back[0].line != HelperTrail.stoppedLine)
        let resumed = HelperTrail.pick(&back, brief: brief)
        check("it's picked back up", resumed.count == 1 && back[0].state == "working")
        check("and the update didn't count toward the restart limit", back[0].resumes == HelperTrail.maxResumes && back[0].updatePaused == nil)
        check("the person is told it was paused for the update", back[0].restartNews == HelperTrail.toldUpdate("Long job"))
        // A newly allowed folder restarts the engine even while helpers work: they're paused the same way.
        var fol = Helper(title: "Ledger run", task: "Post.", sid: "s-10", state: "working", line: "")
        fol.resumes = HelperTrail.maxResumes
        HelperStop.pauseForFolder(&fol)
        check("a folder restart pauses a working helper", fol.state == "stopped" && fol.resumeQueued == true && fol.line == FolderWatch.pausedLine)
        var fback = [fol]
        let fres = HelperTrail.pick(&fback, brief: brief)
        check("it's picked back up, not counted as a cut-off", fres.count == 1 && fback[0].resumes == HelperTrail.maxResumes)
        check("the person is told why it paused", fback[0].restartNews == "Ledger run was paused for a new folder. I picked it back up.")
        var mid = Helper(title: "Stopped one", task: "", sid: nil, state: "working", line: "")
        HelperTrail.stopByYou(&mid)
        HelperStop.pauseForUpdate(&mid)
        check(
            "a helper stopped by you stays stopped through an update", relaunch([mid])[0].resumeQueued != true && mid.trail?.last == "Stopped by you")

        // A finished helper stays orange until it's opened, also across a restart; then it shows the check mark.
        var fin = Helper(title: "Hotel search", task: "Find a hotel.", sid: "s-4", state: "done", line: "Done")
        fin.seen = false
        check("a finished helper not opened yet glows orange like a yes", fin.waiting && fin.viewState == .needsYes)
        check("and still does after a restart", relaunch([fin])[0].viewState == .needsYes)
        fin.seen = true
        check("opened, it shows the check mark", !fin.waiting && fin.viewState == .done)
        var old = fin
        old.seen = nil
        check("one finished before this existed counts as opened", old.viewState == .done)
        // Only good mornings and status reports get one combined report; everything else just a "by the way" line.
        check("good morning and status reports are routines", Helpers.isRoutine("Good morning!") && Helpers.isRoutine("status report please"))
        check("other asks are not", !Helpers.isRoutine("Find me a flight to Quebec"))
        let a = Helper(title: "Flights", task: "", sid: nil, state: "done", line: "")
        let b = Helper(title: "Hotels", task: "", sid: nil, state: "done", line: "")
        let one = Helpers.doneNote([a], user: "Omar")
        check("the note asks for one by-the-way line", one.contains("\"By the way, Flights is done. Tap it to take a look.\""))
        check("and says not to repeat the result or ask its question", one.contains("Don't repeat") && one.contains("don't ask its question"))
        check(
            "several finished in one reply share one line",
            Helpers.doneNote([a, b], user: "Omar").contains("By the way, Flights and Hotels are done. Tap them"))

        // Only a real, complete answer is "done" (Oct 28: an engine restart flipped seven half-done helpers to done).
        let half = "\n\nNow the engine plugin."
        check("a finished answer is done", HelperEnd.of(stop: "end_turn", reply: "Here are the 3 designs.") == .finished)
        check("the engine restarting under it is a cut-off", HelperEnd.of(stop: "error: stopped", reply: half) == .cutOff)
        check(
            "a dropped connection is a cut-off",
            HelperEnd.of(stop: "error: Gateway disconnected; turn outcome is unknown. Resume the session", reply: half) == .cutOff)
        check("cancelled without Stop is a cut-off", HelperEnd.of(stop: "cancelled", reply: half) == .cutOff)
        check("running out of room is a cut-off", HelperEnd.of(stop: "max_tokens", reply: half) == .cutOff)
        check("ending without a word is a cut-off", HelperEnd.of(stop: "end_turn", reply: "  \n") == .cutOff)
        check(
            "the gateway's own shutdown words are a cut-off",
            HelperEnd.of(stop: "end_turn", reply: "Gateway shutting down: this turn was interrupted") == .cutOff)
        check("its old turn still running means wait", HelperEnd.of(stop: "error: session_busy", reply: "") == .busy)
        check("a real error is a failure", HelperEnd.of(stop: "error: admitted_turn_failed", reply: half) == .failed("admitted_turn_failed"))
        var cut = Helper(title: "No browser popups", task: "Ship it.", sid: "s-9", state: "working", line: "")
        cut.reply = half
        check(
            "cut off: queued to pick back up, not done", HelperTrail.notFinished(&cut, .cutOff) && cut.state == "stopped" && cut.resumeQueued == true)
        check("it says so plainly", cut.line == HelperTrail.cutLine && !cut.waiting && cut.viewState == .stopped)
        var hs2 = [cut]
        check("and it's picked back up", HelperTrail.pick(&hs2, brief: brief).count == 1)
        check("which counts as one resume", hs2[0].resumes == 1 && hs2[0].state == "working")
        check("its old turn still running: waits, queued again", HelperTrail.notFinished(&hs2[0], .busy) && hs2[0].line == HelperTrail.busyLine)
        _ = HelperTrail.pick(&hs2, brief: brief)
        check("and the retry doesn't count as another cut-off", hs2[0].resumes == 1)
        hs2[0].resumes = HelperTrail.maxResumes
        check("cut off too many times: stopped, not queued", !HelperTrail.notFinished(&hs2[0], .cutOff) && hs2[0].line == HelperTrail.gaveUp(2))
        var bad = Helper(title: "Bad", task: "", sid: nil, state: "working", line: "")
        check(
            "a failure is stopped with the reason, never done",
            !HelperTrail.notFinished(&bad, .failed("x")) && bad.state == "stopped" && bad.reply.contains("couldn't finish"))

        // Doubled replies and repeated helper lines start each job once (make helpers-check runs it end to end).
        let block = "Sending all three now.\n[helper: A | job a]\n[helper: B | job b]"
        check("a reply delivered twice shows once", Helpers.undouble(block + "\n" + block) == block && Helpers.undouble(block) == block)
        check("a short reply that just repeats a word is left alone", Helpers.undouble("ha ha") == "ha ha")
        let jobs = Helpers.unique([("A", "job a"), ("a", "Job  a"), ("B", "job b")], among: []).keep
        check("the same helper line twice starts one helper", jobs.count == 2)
        var busy = Helper(title: "B", task: "job b", sid: nil, state: "working", line: "")
        busy.started = Date()
        check("a job already at work isn't started again", Helpers.unique([("B", "job b")], among: [busy]).keep.isEmpty)
        busy.state = "done"
        busy.started = Date(timeIntervalSinceNow: -600)
        check("but the same job asked for later is", Helpers.unique([("B", "job b")], among: [busy]).keep.count == 1)
        try? fm.removeItem(at: HelperTrail.folder)
        print(fails == 0 ? "helpers ok" : "helpers FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
