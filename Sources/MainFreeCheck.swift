import Foundation

/// `One --test-helpers-stress mainfree` (tools/main-free-check.sh, in preflight on every pull request).
/// Omar (Nov 11 2026): "We should always default to a helper. My main assistant should always be ready to talk."
/// That evening the main chat read his note, wrote two long job files with tool calls, and was cut off before its
/// helper lines went out: minutes stuck, nothing sent. Earlier the same day it ran checks itself instead of sending
/// a helper. Replayed here against the stand-in engine (tools/fake-engine.py), through `Model` like the app:
///   1. the rule: the main chat's own notes say to send the helper line in its first reply, the whole job on it
///   2. a turn that does long tool work before dispatching is cut short and handed to a helper (STRESSWORK)
///   3. a message sent while such a turn works is answered right away, never stuck behind it
///   4. a turn cut off after it wrote job files: the jobs go out as helpers (STRESSCUT), never dropped
///   5. the same after they press Stop: nothing starts by itself, they're told plainly, one tap sends them
///   6. never over-eager: one quick look, and a long reply that keeps talking, finish as they are
extension HelperStress {
    @MainActor
    static func mainFreeCheck(_ m: Model) async -> Int32 {
        m.helpers = []
        m.bubbles = []
        m.shelf = []
        m.followUps = []
        let t0 = Date()
        func at() -> String { String(format: "%5.1fs", Date().timeIntervalSince(t0)) }
        func evs() -> [MainEvent] {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(MainEvent.self, from: Data($0.utf8)) }
        }
        func helper(_ token: String) -> Helper? { m.helpers.first { $0.task.contains(token) } }
        func lastSaid() -> String { m.bubbles.last { !$0.fromMe }?.text ?? "" }
        let jobs = Env.support.appendingPathComponent("work/helper-jobs")

        print("1. the main chat's own rules: send the helper line at once, the whole job on that line")
        let soul = Persona.soul(assistant: "Ava", user: "Omar")
        for (name, text) in [("its instructions (SOUL)", soul), ("the note on every prompt", Helpers.note)] {
            check("\(name): the helper line goes in the first reply", text.contains("Send the helper line in your first reply"))
            check("\(name): never a job file first, never checks or reading here", text.contains("never write the job into a file"))
            check("\(name): One hands a long turn to a helper itself", text.contains("about 20 seconds"))
        }

        print("   when One hands a turn over (MainFree.handOff)")
        let h = MainFree.handOff
        check("a 4th step: handed over", h(8, 4, 0, false, .step) && !h(8, 3, 0, false, .step))
        check("any step after 20 s: handed over", h(21, 2, 0, false, .step) && !h(15, 2, 0, false, .step))
        check("a long single step, quiet past 20 s: handed over", h(21, 1, 6, false, .tick) && !h(21, 1, 2, false, .tick))
        check("words still coming and no step: never (a long reply)", !h(45, 0, 1, false, .tick))
        check("nothing at all for a minute: handed over", h(61, 0, 12, false, .tick))
        check(
            "a message while a step is under way: handed over; while only talking: never", h(3, 1, 0, false, .message) && !h(3, 0, 0, false, .message)
        )
        check("never once its helper line is on the way", !h(90, 9, 30, true, .step) && !h(90, 9, 30, true, .tick) && !h(90, 9, 30, true, .message))
        check(
            "\"own it, don't send a helper\" is done right here, never handed over",
            MainFree.ownIt("Own it, don't send a helper") && MainFree.ownIt("Do this yourself, right here, never with a helper")
                && !MainFree.ownIt("Fix these Forge bugs"))
        check(
            "a short plain title from their words",
            MainFree.title("So can you fix these Forge bugs please") == "Fix these Forge bugs" && MainFree.title("?!") == "Your ask")

        print("2. Nov 11 replayed: a turn that reads and checks things itself (8 steps, 32 s) before it sends anything")
        let sent = Date()
        Task { await m.send("Fix these Forge bugs STRESSWORK tools=8 gap=4 TOKA") }
        let freed = await wait(40) { !m.thinking && helper("TOKA") != nil }
        let secs = Date().timeIntervalSince(sent)
        print("   [\(at())] main chat free after \(Int(secs)) s; helpers: \(m.helpers.map(\.title)); said: \(lastSaid().prefix(90))")
        check("cut short within about 20 seconds (\(Int(secs)) s), not after all 32 s of steps", freed && secs <= 22)
        check("its work went to a helper, with the whole ask", helper("Fix these Forge bugs STRESSWORK tools=8 gap=4 TOKA") != nil)
        check(
            "the engine's turn was stopped mid-work, never finished",
            evs().contains { $0.ev == "main-cancelled" && $0.title == "TOKA" } && !evs().contains { $0.ev == "main-end" && $0.title == "TOKA" })
        let said2 = lastSaid()
        check(
            "the chat says plainly a helper took it (\(said2.prefix(70)))",
            said2.contains("sent a helper") && !said2.contains("Operation interrupted") && !said2.contains("[helper"))
        check("its own late helper line never went out on top", !m.helpers.contains { $0.title == "Late helper TOKA" })

        print("3. a message sent while such a turn works is answered right away")
        Task { await m.send("Look through my notes STRESSWORK tools=8 gap=3 TOKB") }
        _ = await wait(10) { m.thinking && m.working != nil }  // its first step is under way
        try? await Task.sleep(for: .milliseconds(1500))
        let asked = Date()
        await m.send("QUEUEMSG KIWI")
        let answered = await wait(30) { m.bubbles.contains { !$0.fromMe && $0.text == "Got KIWI." } }
        let wait3 = Date().timeIntervalSince(asked)
        print("   [\(at())] answered after \(String(format: "%.1f", wait3)) s; helpers: \(m.helpers.map(\.title))")
        check("answered in \(Int(wait3)) s, not after the other turn's 24 s", answered && wait3 <= 6)
        check("the busy turn went to a helper, with the whole ask", helper("Look through my notes STRESSWORK tools=8 gap=3 TOKB") != nil)
        _ = await wait(10) { !m.thinking && m.outbox.isEmpty }

        print("4. Nov 11, 9:30 PM replayed: two job files written, then the turn is cut off before its helper lines")
        let a4 = ["forge-chat-render-bugs", "forge-sidebar-pr-design"]
        Task { await m.send("Forge bugs STRESSCUT dir=\(jobs.path) jobs=\(a4.joined(separator: ",")) wait=2 TOKC") }
        let both = await wait(20) { !m.thinking && a4.allSatisfy { s in m.helpers.contains { $0.task.contains(s + ".md") } } }
        let said4 = lastSaid()
        print("   [\(at())] helpers: \(m.helpers.map(\.title)); said: \(said4.prefix(120))")
        check("both written jobs went out as helpers", both)
        check(
            "the chat says so plainly, never just \"Operation interrupted\"",
            !said4.hasPrefix("Operation interrupted") && said4.contains("Forge chat render bugs") && said4.contains("Forge sidebar pr design"))

        print("5. the same, but they press Stop first: nothing starts by itself, they're told plainly")
        let a5 = ["routine-fix-job", "orb-colors-job"]
        Task { await m.send("More bugs STRESSCUT dir=\(jobs.path) jobs=\(a5.joined(separator: ",")) wait=40 TOKD") }
        _ = await wait(10) { a5.allSatisfy { FileManager.default.fileExists(atPath: jobs.appendingPathComponent($0 + ".md").path) } }
        try? await Task.sleep(for: .milliseconds(500))
        m.toggleStop()
        let told = await wait(10) { !m.thinking && lastSaid().contains("[choices: Send them now | Leave them]") }
        print("   [\(at())] said: \(lastSaid().prefix(160))")
        check("told the two jobs never started, with Send them now / Leave them", told && lastSaid().contains("Routine fix job"))
        check("nothing started by itself after Stop", !a5.contains { s in m.helpers.contains { $0.task.contains(s + ".md") } })
        m.toggleStop()
        await m.choose("Send them now")
        let sent5 = await wait(10) { a5.allSatisfy { s in m.helpers.contains { $0.task.contains(s + ".md") } } }
        check("Send them now starts both", sent5)
        _ = await wait(10) { !m.thinking && m.outbox.isEmpty }

        print("6. never over-eager: one quick look, and a long reply that keeps talking, finish as they are")
        Task { await m.send("Quick one STRESSWORK tools=1 gap=2 TOKE") }
        let quick = await wait(20) { !m.thinking && evs().contains { $0.ev == "main-end" && $0.title == "TOKE" } }
        check("one quick look, then its own helper line: finished by itself", quick && m.helpers.contains { $0.title == "Late helper TOKE" })
        let longs = evs().filter { $0.ev == "main-end" && $0.kind == "long" }.count
        Task { await m.send("STRESSLONG n=12 secs=26") }
        _ = await wait(5) { m.thinking }
        let long = await wait(45) { !m.thinking }
        check(
            "a 26 s reply that keeps talking is never cut",
            long && evs().filter { $0.ev == "main-end" && $0.kind == "long" }.count == longs + 1 && lastSaid().contains("END-OF-LONG-REPLY"))

        print(fails == 0 ? "main-free ok" : "main-free FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
