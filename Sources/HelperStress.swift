import AppKit
import Foundation

/// `One --test-helpers-stress <start|after-kill|after-update>` (tools/helpers-check.sh, `make helpers-check`, in preflight).
/// The whole premise of One is sending lots of helpers at once, so this sends 100 of them through `Model` like the
/// app does, against a stand-in engine (tools/fake-engine.py: same protocol, no cost, seconds per job), and then
/// breaks things on purpose:
///   start         25 helpers from one reply that has a helper line twice and is delivered twice, then 75 more
///                 at once; short jobs finish; the engine is killed mid-run; then the script kills One itself.
///   after-kill    One opens again from what it saved: everything is still there and picks back up; then an
///                 update pauses the helpers at work and One quits for it.
///   after-update  One opens again after the update: every helper finishes.
/// Proven: every helper stays listed and has a spot on screen, none starts twice or runs twice at once, none is
/// ever shown done without its real final reply, every cut-off one is picked back up and finishes, every result
/// has its file in the Made by folder. Four "keepers" (finished and not opened, finished and opened and read,
/// needs your yes, stopped by you) are checked after every break: a new helper, 75 more, the engine killed, One
/// killed, an update. Their orbs never go away on their own; each leaves only when they're done with it (Got it in its thread, or asking), and a busy one only once it's stopped.
/// Runs only from a test copy (own settings), with ONE_SUPPORT_DIR and ONE_TEST_ENGINE set by the script.
enum HelperStress {
    nonisolated(unsafe) static var fails = 0
    static func check(_ name: String, _ ok: Bool) {
        print("  \(ok ? "✓" : "✗") \(name)")
        fflush(stdout)
        if !ok { fails += 1 }
    }
    static let chatCount = 25
    static let directCount = 75
    static let long = 25.0  // seconds: long jobs are still at work through every break
    static var plan: URL { Env.support.appendingPathComponent("stress-plan.json") }
    static var log: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ONE_FAKE_ENGINE_LOG"] ?? Env.support.appendingPathComponent("fake.jsonl").path)
    }
    /// The job id the stand-in answers with: `STRESSJOB <id> secs=<n>`.
    static func job(_ h: Helper) -> String {
        h.task.components(separatedBy: " ").drop { $0 != "STRESSJOB" }.dropFirst().first ?? "?"
    }
    static func secs(_ h: Helper) -> Double {
        Double(h.task.components(separatedBy: "secs=").last ?? "") ?? 0
    }

    @MainActor
    static func wait(_ s: Double, until: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(s)
        while Date() < end {
            if until() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return until()
    }

    /// Watches every helper ten times a second: done (or needs a yes) must always come with its real final reply,
    /// and no job may ever be listed twice.
    @MainActor
    static func watch(_ m: Model) {
        Task { @MainActor in
            var told = Set<String>()
            while true {
                for h in m.helpers where h.state == "done" || h.state == "needsYes" {
                    let j = job(h)
                    if !h.reply.contains("DONE \(j)"), told.insert("done:\(j)").inserted {
                        check("\(h.title) shown done without its final reply (\(h.state), \(h.line))", false)
                    }
                }
                let jobs = m.helpers.map(job)
                for j in Set(jobs) where jobs.filter({ $0 == j }).count > 1 && told.insert("twice:\(j)").inserted {
                    check("\(j) is listed twice", false)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @MainActor
    static func setUp() async -> Model? {
        guard Env.selfTest, Bundle.main.bundleIdentifier != TestWorld.productionID, Env.testEngine != nil,
            ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil
        else {
            print("refusing: run tools/helpers-check.sh (a test copy, a scratch folder and the stand-in engine)")
            return nil
        }
        _ = NSApplication.shared  // helpers ask whether One is in front
        UserDefaults.standard.set(true, forKey: "voiceMuted")  // the test copy's own settings: 100 helpers, no voice
        let m = Model.shared
        m.assistantName = "Ava"
        m.userName = "Omar"
        Engine.shared.onPermission = { _, opts, ans in ans(opts.first { $0.0.hasPrefix("allow") }?.0) }
        if let e = await Engine.shared.start() {
            print("FAIL the stand-in engine didn't start: \(e)")
            return nil
        }
        try? await Task.sleep(for: .milliseconds(300))  // the engine's news (getting ready / ready) reaches the model
        watch(m)
        return m
    }

    /// What the stand-in engine did, one event per line.
    struct Event: Decodable {
        let ev: String
        let t: Double
        let pid: Int
        let job: String?
        let resumed: Bool?
        let sid: String?
        var text: String? = nil
    }
    static func events() -> [Event] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    }
    /// Runs of each job that overlapped (two copies at work at the same moment). A run ends with its own end or
    /// cancel, or when its engine went away (the next engine-up from another process, or its own eof).
    static func overlaps(_ evs: [Event]) -> [String] {
        // An engine killed outright leaves no last word: its runs count as going on until its last event.
        var last: [Int: Double] = [:]
        for e in evs { last[e.pid] = max(last[e.pid] ?? 0, e.t) }
        var bad: [String] = []
        let starts = evs.filter { $0.ev == "start" }
        for j in Set(starts.compactMap(\.job)) {
            let runs = starts.filter { $0.job == j }.map { s -> (Double, Double) in
                let own = evs.first { ($0.ev == "end" || $0.ev == "cancelled") && $0.job == j && $0.pid == s.pid && $0.sid == s.sid && $0.t >= s.t }
                return (s.t, own?.t ?? last[s.pid] ?? .infinity)
            }.sorted { $0.0 < $1.0 }
            for k in runs.indices.dropFirst() where runs[k].0 < runs[k - 1].1 - 0.05 { bad.append(j) }
        }
        return bad.sorted()
    }

    struct Plan: Codable {
        var ids: [UUID]
        var cut: [String]  // jobs still at work when the engine was killed
        var keep: [String: UUID] = [:]  // the keepers, by job
    }

    /// The four keepers: finished and not opened, finished and opened, needs your yes, stopped by you.
    static let keepers = ["KD", "KO", "KY", "KS"]
    static func isKeeper(_ h: Helper) -> Bool { keepers.contains(job(h)) }

    /// Each keeper is still on screen, in the state it was left in.
    @MainActor
    static func keepersOK(_ m: Model, _ k: [String: UUID], _ when: String) {
        func h(_ j: String) -> Helper? { k[j].flatMap { id in m.helpers.first { $0.id == id } } }
        check("\(when): finished, not opened: still there and orange", h("KD").map { $0.state == "done" && $0.waiting } == true)
        check("\(when): finished, opened and read: still there", h("KO").map { $0.state == "done" && !$0.waiting } == true)
        check("\(when): needs your yes: still there and asking", h("KY").map { $0.state == "needsYes" && $0.waiting } == true)
        check("\(when): stopped by you: still there and stopped", h("KS").map { $0.state == "stopped" && $0.stoppedByYou == true } == true)
        let shown = Set(HelperRings.sorted(m.helpers).map(\.id))
        let lay = HelperRings.layout(count: m.helpers.count)
        check("\(when): all four on screen, with every other helper", Set(k.values).isSubset(of: shown) && lay.spots.count == m.helpers.count)
    }

    /// Before the 75: the four keepers go out, finish (or are stopped), and are opened, read and stopped like a person would.
    @MainActor
    static func makeKeepers(_ m: Model) async -> [String: UUID] {
        print("1b. four keepers: finished, opened and read, needs your yes, stopped by you")
        m.spawnHelper(title: "Kept done", task: "STRESSJOB KD secs=1")
        m.spawnHelper(title: "Kept opened", task: "STRESSJOB KO secs=1")
        m.spawnHelper(title: "Kept asking", task: "STRESSJOB KY secs=1 ask=1")
        m.spawnHelper(title: "Kept stopped", task: "STRESSJOB KS secs=90")
        var k: [String: UUID] = [:]
        for h in m.helpers where isKeeper(h) { k[job(h)] = h.id }
        _ = await wait(20) { ["KD", "KO", "KY"].allSatisfy { j in m.helpers.first { $0.id == k[j] }?.state != "working" } }
        _ = await wait(20) { events().contains { $0.ev == "start" && $0.job == "KS" } }
        if let s = k["KS"] { m.stopHelper(s) }
        _ = await wait(10) { events().contains { $0.ev == "cancelled" && $0.job == "KS" } }
        if let o = k["KO"] {
            m.focusHelper(o)  // opened
            try? await Task.sleep(for: .milliseconds(300))
            m.focusHelper(o)  // and closed again (back to the assistant)
            if let s = m.helpers.first(where: { $0.id == o })?.shelfID {
                m.openShelf(s)  // its file read on the shelf
                m.openedShelf = nil
            }
        }
        for k2 in m.helpers.indices where isKeeper(m.helpers[k2]) { m.helpers[k2].finishedAway = true }
        m.clearAway()  // "Got it" on the While you were gone card
        try? await Task.sleep(for: .seconds(1))
        keepersOK(m, k, "opened, read on the shelf, and Got it")
        return k
    }

    /// `--test-helpers-stress <phase>`: true if this launch is the stress check (it then runs and exits).
    /// Oct 28: a helper line whose job quotes [close-helper: …], [stop-helper: …] or [choices: …] starts whole,
    /// and nothing is stopped, closed, shown or read aloud from inside it (HelperLines.swift).
    static let quotedJobs: Set<String> = ["Q1", "Q2", "Q3"]  // step 1b's own helpers, not counted with the rest
    @MainActor
    static func quoted(_ m: Model) async {
        print("1b. three helper lines quoting close, stop and choices tags, streamed in small pieces")
        let live = m.helpers.filter { $0.state == "working" }
        guard live.count >= 2 else { return check("two helpers at work to quote (\(live.count))", false) }
        let before = Dictionary(uniqueKeysWithValues: m.helpers.map { ($0.id, $0.state) })
        var shown: [String] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if let b = m.bubbles.last, !b.fromMe { shown.append(Helpers.strip(b.text)) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await m.send("STRESSQUOTED \(live[0].title) \(live[1].title)")
        _ = await wait(20) { !m.thinking }
        watcher.cancel()
        let q = m.helpers.filter { ["Q1", "Q2", "Q3"].contains($0.title) }
        check("all 3 started (\(q.map(\.title)))", q.count == 3)
        check(
            "each with its whole job text",
            q.contains { $0.task.hasSuffix("[close-helper: \(live[0].title)] on its own line.") }
                && q.contains { $0.task.hasSuffix("[stop-helper: \(live[1].title)].") } && q.contains { $0.task.hasSuffix("shows two buttons.") })
        let gone = before.keys.filter { id in !m.helpers.contains { $0.id == id } }
        let stopped = m.helpers.filter { before[$0.id] == "working" && ($0.state == "stopped" || $0.stoppedByYou == true) }
        check("nothing was stopped or closed (\(gone.count) gone, \(stopped.count) stopped)", gone.isEmpty && stopped.isEmpty)
        let said = m.bubbles.last { !$0.fromMe }?.text ?? ""
        let bits = ["[helper", "orbs", "STRESSJOB", "Make Stop", "buttons", "couldn't find"]
        check("the reply shows only what was said (\(said.prefix(60)))", said == "Sending three helpers now.\nThey'll report back.")
        check("no piece of a helper line ever showed while it streamed", !shown.contains { s in bits.contains { s.contains($0) } })
        check(
            "nothing of them is read aloud",
            !Speaker.spoken(said + "\n" + (m.bubbles.last?.text ?? "")).contains { s in bits.contains { s.contains($0) } })
        _ = await wait(15) { q.allSatisfy { h in m.helpers.first { $0.id == h.id }?.state == "done" } }
        m.helpers.removeAll { ["Q1", "Q2", "Q3"].contains($0.title) }  // the rest of the check counts its own helpers
    }

    static func launch() -> Bool {
        guard let k = CommandLine.arguments.firstIndex(of: "--test-helpers-stress") else { return false }
        TestWorld.enter()  // scratch folder, own settings; the stand-in engine only (tools/helpers-check.sh)
        let phase = CommandLine.arguments.count > k + 1 ? CommandLine.arguments[k + 1] : "start"
        Task { @MainActor in exit(await run(phase)) }
        return true
    }

    @MainActor
    static func run(_ phase: String) async -> Int32 {
        guard let m = await setUp() else { return 2 }
        let t0 = Date()
        func at() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
        let fm = FileManager.default
        switch phase {
        case "queue":
            return await queueCheck(m)  // QueueCheck.swift: one line for everything the assistant says
        case "start":
            m.helpers = []
            m.bubbles = []
            m.shelf = []
            try? fm.removeItem(at: Shelf.folder)
            print("1. \(chatCount) helpers from one reply (a helper line written twice, the whole reply delivered twice)")
            await m.send("STRESSSPAWN \(chatCount) prefix=C secs=2,4,\(Int(long))")
            _ = await wait(20) { !m.thinking }
            let fromChat = m.helpers.filter { $0.title.hasPrefix("C") }
            check("\(chatCount) helpers started, not \(chatCount + 1) or \(2 * (chatCount + 1)) (got \(fromChat.count))", fromChat.count == chatCount)
            let said = m.bubbles.last { !$0.fromMe }?.text ?? ""
            check("the doubled reply shows once", said.components(separatedBy: "Sending \(chatCount) helpers now.").count == 2)
            check("and no helper line shows", !said.contains("[helper"))
            await quoted(m)
            let keep = await makeKeepers(m)
            let total = chatCount + directCount + keepers.count
            print("2. \(directCount) more at once (\(total) in all)")
            for n in 1...directCount { m.spawnHelper(title: String(format: "B%02d", n), task: "STRESSJOB B\(n) secs=\(n % 2 == 0 ? 3 : Int(long))") }
            check("all \(total) are listed", m.helpers.count == total)
            keepersOK(m, keep, "a new helper sent (75 of them)")
            let started = await wait(20) { Set(events().filter { $0.ev == "start" }.compactMap(\.job)).subtracting(quotedJobs).count == total }
            print("   [\(at())] \(Set(events().filter { $0.ev == "start" }.compactMap(\.job)).subtracting(quotedJobs).count) at work")
            check("all \(total) are at work at the same time, none waits for a slot", started)
            let shortDone = await wait(30) { m.helpers.filter { secs($0) < 10 && !isKeeper($0) }.allSatisfy { $0.state == "done" } }
            print("   [\(at())] \(m.helpers.filter { $0.state == "done" }.count) done")
            check("the short jobs finished with their real reply", shortDone)
            print("3. the engine is killed mid-run")
            let working = m.helpers.filter { $0.state == "working" }
            let cut = working.map(job)
            check("long jobs are still at work (\(working.count))", working.count > 30)
            check(
                "each shows its real step, still open, from the engine's own step events",
                working.allSatisfy { m.pulses[$0.id]?.stepOpen == true && m.progressLine($0, now: Date()) == "Working on your Mac…" })
            if let pid = Engine.shared.enginePID { kill(pid, SIGKILL) }
            check("One shows it's getting ready the moment the engine goes", await wait(3) { !m.isReady })
            let back = await wait(30) {
                let resumed = Set(events().filter { $0.ev == "start" && $0.resumed == true }.compactMap(\.job))
                return Set(cut).isSubset(of: resumed) && m.helpers.filter { cut.contains(job($0)) }.allSatisfy { $0.state == "working" }
            }
            print(
                "   [\(at())] engine back: \(Engine.shared.running), picked back up: \(m.helpers.filter { cut.contains(job($0)) && $0.state == "working" }.count) of \(cut.count)"
            )
            check("One started the engine again by itself", Engine.shared.running)
            check("and opened again once every helper was back", await wait(30) { m.isReady && m.waking.isEmpty })
            check("every helper the engine cut off was picked back up", back)
            check("none of them was shown done", m.helpers.filter { cut.contains(job($0)) }.allSatisfy { $0.state != "done" })
            let restartLines = m.bubbles.filter { $0.text.contains("picked") && $0.text.contains("back up") }.count
            check("one line in the chat about it, not one per helper (\(restartLines))", restartLines <= 1)
            keepersOK(m, keep, "the engine killed and back")
            let p = Plan(ids: m.helpers.map(\.id), cut: cut, keep: keep)
            try? JSONEncoder().encode(p).write(to: plan)
            try? await Task.sleep(for: .seconds(2))  // the long jobs are mid-run again
            print("   [\(at())] still at work: \(m.helpers.filter { $0.state == "working" }.count)")
            print(fails == 0 ? "READY-TO-KILL" : "helpers-stress FAILED (\(fails))")
            fflush(stdout)
            if fails > 0 { return 1 }
            try? await Task.sleep(for: .seconds(120))  // the script kills One here
            print("FAIL One was not killed")
            return 1

        case "after-kill":
            print("4. One was killed mid-run and opens again")
            guard let p = (try? Data(contentsOf: plan)).flatMap({ try? JSONDecoder().decode(Plan.self, from: $0) }) else {
                print("FAIL no plan from the first run")
                return 1
            }
            check("every helper is still listed (\(m.helpers.count) of \(p.ids.count))", Set(m.helpers.map(\.id)) == Set(p.ids))
            keepersOK(m, p.keep, "One killed (kill -9) and opened again")
            let others = m.helpers.filter { !isKeeper($0) }
            let wasDone = others.filter { $0.state == "done" }
            check("the finished ones are still done, results kept (\(wasDone.count))", wasDone.count >= p.ids.count - keepers.count - p.cut.count)
            check("and still orange until opened", wasDone.allSatisfy(\.waiting))
            let queued = m.helpers.filter { $0.resumeQueued == true }
            check(
                "the ones at work are waiting to pick back up (\(queued.count))", queued.count == others.count - wasDone.count && !queued.isEmpty)
            let before = events().count
            let saidBefore = m.bubbles.count
            await gateHolds(m, queued: queued)  // getting ready: no messages to sleeping helpers, nothing lost; resumes them
            let back = await wait(20) { events().dropFirst(before).filter { $0.ev == "start" }.count >= queued.count }
            print("   [\(at())] picked back up: \(events().dropFirst(before).filter { $0.ev == "start" }.count) of \(queued.count)")
            check("all of them picked back up", back)
            let lines = m.bubbles.dropFirst(saidBefore).filter { $0.text.contains("picked") && $0.text.contains("back up") }.count
            check("one line in the chat about it (\(lines))", lines <= 1)
            try? await Task.sleep(for: .seconds(2))
            print("5. an update arrives with \(m.helpers.filter { $0.state == "working" }.count) helpers at work")
            let t = Date()
            m.pauseHelpersForUpdate()
            check(
                "every working helper is paused for it at once",
                m.helpers.allSatisfy { $0.state != "working" } && Date().timeIntervalSince(t) < 1)
            Engine.shared.stop()  // what the update's swap script does
            try? await Task.sleep(for: .seconds(1))
            check("none was shown done by the engine going away", m.helpers.filter { $0.updatePaused == true }.allSatisfy { $0.state != "done" })
            keepersOK(m, p.keep, "an update pausing everything")
            print(fails == 0 ? "UPDATE-QUIT" : "helpers-stress FAILED (\(fails))")
            return fails == 0 ? 0 : 1

        default:
            print("6. One opens again after the update")
            guard let p = (try? Data(contentsOf: plan)).flatMap({ try? JSONDecoder().decode(Plan.self, from: $0) }) else {
                print("FAIL no plan from the first run")
                return 1
            }
            check("every helper is still listed (\(m.helpers.count) of \(p.ids.count))", Set(m.helpers.map(\.id)) == Set(p.ids))
            keepersOK(m, p.keep, "the update installed and One opened again")
            let others = { m.helpers.filter { !isKeeper($0) } }
            check("the paused ones wait to pick back up", others().filter { $0.state != "done" }.allSatisfy { $0.resumeQueued == true })
            m.resumeInterrupted()
            let finished = await wait(long + 30) { others().allSatisfy { $0.state == "done" } }
            print("   [\(at())] done: \(m.helpers.filter { $0.state == "done" }.count) of \(m.helpers.count)")
            check("every helper finished", finished)
            check("each with its own real final reply", others().allSatisfy { $0.reply.contains("DONE \(job($0))") })
            check("never stopped by you", others().allSatisfy { $0.stoppedByYou != true })
            check("finished ones carry no progress line", others().allSatisfy { m.pulses[$0.id] == nil })
            keepersOK(m, p.keep, "every other helper finished")
            let cut = m.helpers.filter { p.cut.contains(job($0)) }
            check(
                "every cut-off one was picked back up and finished (\(cut.count))", cut.count == p.cut.count && cut.allSatisfy { $0.state == "done" })
            let files = ((try? fm.contentsOfDirectory(at: Shelf.folder, includingPropertiesForKeys: nil)) ?? [])
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            let missing = m.helpers.filter { $0.state == "done" }.filter { h in !files.contains { $0.contains("DONE \(job(h))\n") } }
            check("every result has its file in the Made by folder (\(files.count) files, \(missing.count) missing)", missing.isEmpty)
            let extra = m.helpers.filter { h in files.filter { $0.contains("DONE \(job(h))\n") }.count > 1 }
            check("and only one each (\(extra.count) with more)", extra.isEmpty)
            let evs = events()
            let fresh = evs.filter { $0.ev == "start" && $0.resumed != true }.compactMap(\.job).filter { !quotedJobs.contains($0) }
            let twice = Set(fresh.filter { j in fresh.filter { $0 == j }.count > 1 })
            check(
                "none was started twice (\(Set(fresh).count) jobs started fresh, \(twice.count) twice)",
                twice.isEmpty && Set(fresh).count == p.ids.count)
            let both = overlaps(evs)
            check("no job ever ran twice at the same moment\(both.isEmpty ? "" : ": " + both.prefix(5).joined(separator: ", "))", both.isEmpty)
            let lay = HelperRings.layout(count: m.helpers.count)
            let spots = Set(lay.spots.map { "\(Int($0.at.x)),\(Int($0.at.y))" })
            check(
                "every one of the \(m.helpers.count) has its own spot on screen", lay.spots.count == m.helpers.count && spots.count == m.helpers.count
            )
            check("all sorted onto the screen, none dropped", HelperRings.sorted(m.helpers).count == m.helpers.count)
            print("7. a finished helper stays until they're done with it")
            let all = Set(m.helpers.map(\.id))
            if let k = m.helpers.indices.first { m.helpers[k].seen = true }  // opened: no longer orange, still kept
            m.spawnHelper(title: "One more", task: "STRESSJOB X1 secs=1")
            if let busy = m.helpers.last?.id {
                check("a working one can't be taken off the screen", !m.closeHelper(busy) && m.helpers.contains { $0.id == busy })
            }
            check(
                "sending one more keeps every finished one, opened or not",
                all.isSubset(of: Set(m.helpers.map(\.id))) && m.helpers.count == all.count + 1)
            _ = await wait(15) { m.helpers.last?.state == "done" }
            check("and it finished too", m.helpers.last?.reply.contains("DONE X1") == true)
            try? await Task.sleep(for: .seconds(2))
            check("still all there a moment later", all.isSubset(of: Set(m.helpers.map(\.id))))
            if let gone = m.helpers.first?.id {
                m.closeHelper(gone)  // Got it in its thread
                try? await Task.sleep(for: .seconds(1))
                check("Got it: that one is gone and only that one", !m.helpers.contains { $0.id == gone } && m.helpers.count == all.count)
            }
            print("8. each keeper leaves only when they're done with it")
            m.markShelfRead()  // "Mark all read": read, never gone
            check("Mark all read keeps every orb", Set(p.keep.values).isSubset(of: Set(m.helpers.map(\.id))))
            for j in keepers {
                guard let id = p.keep[j] else { continue }
                let before = Set(m.helpers.map(\.id))
                if j == "KY" {
                    // Waiting for their yes: asking (the older [close-helper: …] line) keeps it, and says why.
                    let title = m.helpers.first { $0.id == id }?.title ?? ""
                    _ = await wait(15) { !m.thinking && m.followUps.isEmpty }
                    check("Got it can't take one waiting for a yes", !m.closeHelper(id))
                    await m.send("STRESSCLOSE \(title)")
                    _ = await wait(15) { !m.thinking }
                    var said = m.bubbles.last { !$0.fromMe }?.text ?? ""
                    check(
                        "asked while it waits for a yes: it stays, and says so (\(said.suffix(60)))",
                        m.helpers.contains { $0.id == id } && said.contains("waiting for your yes") && !said.contains("[close-helper"))
                    // Stopped first, then cleared by asking: the [done-helper: …] line.
                    m.stopHelper(id)
                    check("stopped while waiting for a yes", m.helpers.first { $0.id == id }?.state == "stopped")
                    _ = await wait(15) { !m.thinking && m.followUps.isEmpty }
                    await m.send("STRESSDONE \(title)")
                    _ = await wait(15) { !m.thinking }
                    said = m.bubbles.last { !$0.fromMe }?.text ?? ""
                    check("cleared by asking: no done line shows (\(said.prefix(40)))", !said.contains("[done-helper") && !said.isEmpty)
                } else {
                    check("\(j) Got it", m.closeHelper(id))  // Got it in its thread
                }
                try? await Task.sleep(for: .milliseconds(800))
                check("\(j) off the screen: gone, and only it", Set(m.helpers.map(\.id)) == before.subtracting([id]))
            }
            await neverStuck(m)
            Engine.shared.stop()
            print(fails == 0 ? "helpers-stress ok" : "helpers-stress FAILED (\(fails))")
            return fails == 0 ? 0 : 1
        }
    }
}
