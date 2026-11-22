import AppKit
import Foundation

/// `One --test-helpers-stress replay | replay-after | replay-again` (tools/restart-replay-check.sh, in preflight): what
/// the person sent is never lost when One goes away mid-turn, and never runs twice (Nov 10-22 2026: answers lost to
/// update installs and restarts; TurnJournal.swift). Against the stand-in engine (tools/fake-engine.py, no cost).
///   replay        leaves, at the same moment: the main chat's turn in flight, a message typed during it (Next up), a
///                 choice tapped on a helper that was asking (its new turn in flight), and an answer sent into another
///                 helper's running turn. Then One is killed (no clean quit; the engine goes with it).
///   replay-after  One opens again: each goes again exactly once and is answered; their message shows once.
///   replay-again  One opens a third time: nothing runs again.
/// Run 1 against today's main (before TurnJournal) fails run 2: the main chat's message and the Next up one are gone.
extension HelperStress {
    static let replayMain = "STRESSSLOWMAIN RPL1 steps=4 secs=30"
    static let replayNext = "QUEUEMSG NEXT1"
    static let replayTap = "Go STRESSJOB AJ2 secs=30"  // the asking helper's first choice (fake-engine `askjob=`)
    static let replaySteer = "STEERMSG ANS1 use the window seat"

    @MainActor
    static func replayCheck(_ m: Model) async -> Int32 {
        m.helpers = []
        m.bubbles = []
        m.shelf = []
        m.followUps = []
        func h(_ title: String) -> Helper? { m.helpers.last { $0.title == title } }
        print("1. One helper asks, another works")
        m.spawnHelper(title: "Asking", task: "STRESSJOB AQ1 secs=1 ask=1 askjob=AJ2")
        m.spawnHelper(title: "Working", task: "STRESSJOB LW1 secs=45")
        _ = await wait(20) { h("Asking")?.state == "needsYes" && events().contains { $0.ev == "start" && $0.job == "LW1" } }
        check("one asks, one is at work", h("Asking")?.state == "needsYes" && h("Working")?.state == "working")
        print("2. The main chat's turn goes out")
        Task { @MainActor in await m.send(replayMain) }
        _ = await wait(20) { events().contains { $0.ev == "main-start" && $0.title == "RPL1" } }
        check("the main chat's turn is at work", m.thinking)
        print("3. Meanwhile: a message typed, a choice tapped, an answer into the working helper's turn")
        await m.send(replayNext)
        check("the typed one waits Next up", m.followUps.contains { $0.helper == nil && $0.engine.hasPrefix(replayNext) })
        if let a = h("Asking") { m.focusHelper(a.id) }
        Task { @MainActor in await m.choose(replayTap) }
        _ = await wait(20) { events().contains { $0.ev == "start" && $0.job == "AJ2" } }
        check("the tapped choice started its turn", h("Asking")?.state == "working" && h("Asking")?.pending?.contains(replayTap) == true)
        if let w = h("Working") { m.focusHelper(w.id) }
        Task { @MainActor in await m.send(replaySteer) }
        _ = await wait(20) { events().contains { $0.ev == "steer" && ($0.text ?? "").contains("STEERMSG ANS1") } }
        check("the answer went into the working helper's turn", events().contains { $0.ev == "steer" && ($0.text ?? "").contains("STEERMSG ANS1") })
        m.openHelper = nil
        let saved = TurnJournal.read()
        check("on disk: the main chat's turn", saved?.main?.c.engine.hasPrefix(replayMain) == true)
        check(
            "and the waiting ones",
            saved.map { j in j.queued.contains { $0.engine.hasPrefix(replayNext) } && j.queued.contains { $0.helper != nil } } == true)
        print(fails == 0 ? "READY-TO-QUIT" : "replay FAILED (\(fails))")
        fflush(stdout)
        exit(fails == 0 ? 0 : 1)  // killed mid-turn: no clean quit, nothing more saved (the engine goes with it)
    }

    @MainActor
    static func replayAfter(_ m: Model) async -> Int32 {
        print("4. One opens again")
        let me = getpid()
        let pid = Engine.shared.enginePID.map(Int.init) ?? -1
        func h(_ title: String) -> Helper? { m.helpers.last { $0.title == title } }
        func mine(_ ev: String) -> [Event] { events().filter { $0.ev == ev && $0.pid == pid } }
        check("the helpers are back from what was saved", h("Asking") != nil && h("Working") != nil)
        m.resumeInterrupted()  // what launch does once the engine is up (ensureEngine)
        let answered = await wait(90) {
            !m.thinking && m.bubbles.contains { !$0.fromMe && $0.text.contains("ANSWER RPL1") } && h("Asking")?.state != "working"
                && mine("steer").contains { ($0.text ?? "").contains("STEERMSG ANS1") }
        }
        print("   [pid \(me)] main: \(mine("main-start").count) start(s); Asking: \(h("Asking")?.state ?? "gone"); steers: \(mine("steer").count)")
        check("everything was picked back up", answered)
        let main = mine("main-start").filter { $0.title == "RPL1" }
        check("the main chat's message went again, once", main.count == 1)
        check("with the message typed during it, once", main.first.map { ($0.text ?? "").components(separatedBy: replayNext).count == 2 } == true)
        check("answered once", m.bubbles.filter { !$0.fromMe && $0.text.contains("ANSWER RPL1") }.count == 1)
        check("their message shows once", m.bubbles.filter { $0.fromMe && $0.text.contains("RPL1") }.count == 1)
        let tap = mine("start").filter { $0.job == "AJ2" }
        check("the tapped choice's turn picked back up once, with the tap", tap.count == 1 && tap.first?.resumed == true)
        check("and finished", h("Asking")?.reply.contains("DONE AJ2") == true)
        check("the answer reached the working helper again, once", mine("steer").filter { ($0.text ?? "").contains("STEERMSG ANS1") }.count == 1)
        check(
            "no 'will not be run again', no 'send it again' anywhere",
            !m.bubbles.contains { $0.text.contains("will not be run") || $0.text.lowercased().contains("send it again") })
        if let w = h("Working") { m.stopHelper(w.id) }  // its 45 s job: not needed any more
        _ = await wait(10) { TurnJournal.read().map { $0.main == nil && $0.queued.isEmpty } == true }
        check("nothing left on disk", TurnJournal.read().map { $0.main == nil && $0.queued.isEmpty } == true)
        Engine.shared.stop()
        print(fails == 0 ? "replay-after ok" : "replay-after FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }

    @MainActor
    static func replayAgain(_ m: Model) async -> Int32 {
        print("5. One opens a third time")
        let pid = Engine.shared.enginePID.map(Int.init) ?? -1
        m.resumeInterrupted()
        try? await Task.sleep(for: .seconds(6))
        let ran = events().filter { $0.pid == pid && ["main-start", "steer", "start"].contains($0.ev) }
        check("nothing runs again (\(ran.map(\.ev)))", ran.isEmpty)
        check("each answer is still there once", m.bubbles.filter { !$0.fromMe && $0.text.contains("ANSWER RPL1") }.count == 1)
        Engine.shared.stop()
        print(fails == 0 ? "replay-again ok" : "replay-again FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
