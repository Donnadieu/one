import Foundation
import SQLite3

/// `One --test-goals` (preflight, from a test copy; no engine, no network): typed /goal commands, "Goal:" helper jobs,
/// the engine's goal row read and put in plain words, the goal line's state, Stop. The goal loop itself and One's
/// engine overlay are checked by tools/goal-overlay-check.py (preflight) and tools/goal-engine-check.sh (real engine).
enum GoalsCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-goals") else { return false }
        TestWorld.enter()
        Task { @MainActor in exit(await run()) }
        return true
    }

    @MainActor
    static func run() async -> Int32 {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "✓" : "✗") \(name)")
            if !pass { failures += 1 }
        }
        // Typed commands.
        check("/goal and /goal status ask how it's going", Goals.command("/goal") == .status && Goals.command(" /goal status ") == .status)
        check(
            "pause, resume, stop",
            Goals.command("/goal pause") == .pause && Goals.command("/goal resume") == .resume && Goals.command("/goal stop") == .stop)
        check("clear and done also stop it", Goals.command("/goal clear") == .stop && Goals.command("/goal done") == .stop)
        check("anything else sets a goal", Goals.command("/goal Find the cheapest flight") == .set("Find the cheapest flight"))
        check(
            "a goal with its own limit goes to the engine as typed (its overlay reads the number)",
            Goals.command("/goal 50 turns: Find a flight") == .set("50 turns: Find a flight")
                && Goals.command("/goal --turns 50 Find a flight") == .set("--turns 50 Find a flight"))
        check(
            "/goal turns 50 changes the limit of the goal here",
            Goals.command("/goal turns 50") == .turns(50) && Goals.command("/goal turns: 7") == .turns(7)
                && Goals.command("/goal 30 turns") == .turns(30) && Goals.command("/goal turns") == .status)
        check("numbers are kept between 1 and 200", Goals.clamp(500) == 200 && Goals.clamp(0) == 1 && Goals.clamp(50) == 50)
        let at50 = GoalLive(goal: "x", status: "active", turns: 3, max: 50)
        check("a new limit is said in plain words", Goals.turnsWords(asked: 50, after: at50) == "Done. This goal can take up to 50 turns now.")
        check(
            "a capped number says so",
            Goals.turnsWords(asked: 900, after: GoalLive(goal: "x", status: "active", turns: 3, max: 200)).contains("200 is the most a goal can have")
        )
        check(
            "a limit the goal already passed stops it after this turn",
            Goals.turnsWords(asked: 2, after: GoalLive(goal: "x", status: "active", turns: 3, max: 2)).contains("stops after the turn at work"))
        check(
            "a paused goal is told how to go on",
            Goals.turnsWords(asked: 40, after: GoalLive(goal: "x", status: "paused", turns: 20, max: 40)).hasSuffix("Say /goal resume to keep going.")
        )
        check(
            "an engine that didn't take it is said plainly",
            Goals.turnsWords(asked: 50, after: GoalLive(goal: "x", status: "active", turns: 3, max: 20)).hasPrefix("I couldn't change"))
        check("no goal, no change", Goals.turnsWords(asked: 50, after: nil).hasPrefix("No goal is running"))
        check(
            "ordinary words aren't commands",
            Goals.command("keep at it") == nil && Goals.command("/goals x") == nil && Goals.command("a /goal b") == nil)

        // Helpers that carry a goal.
        check(
            "a \"Goal:\" job is a goal, with the default limit",
            Goals.helperGoal("Goal: tidy Downloads; done when it's empty.")?.goal == "tidy Downloads; done when it's empty."
                && Goals.helperGoal("Goal: tidy")?.turns == nil)
        let limited = Goals.helperGoal("Goal (50 turns): tidy Downloads")
        check("a \"Goal (50 turns):\" job carries its own limit", limited?.goal == "tidy Downloads" && limited?.turns == 50)
        check(
            "and so do other ways of writing it",
            Goals.helperGoal("Goal (up to 50 tries): x")?.turns == 50 && Goals.helperGoal("goal(7 turns): x")?.turns == 7
                && Goals.helperGoal("Goals: x") == nil)
        let lb = Helpers.brief(assistant: "Ava", user: "Omar", task: "Goal (50 turns): tidy Downloads")
        check(
            "its first prompt sets the goal with that limit",
            lb.hasPrefix("/goal --turns 50 tidy Downloads\n\n(One app note") && lb.contains("starts with 50 turns"))
        check(
            "a helper asking for too many is told the most",
            Helpers.brief(assistant: "Ava", user: "Omar", task: "Goal (900 turns): x").contains("starts with 200 turns"))
        check(
            "a goal helper is told it keeps going while it makes progress, and to report its count",
            lb.contains("gets more while it keeps making progress (up to 500)") && lb.contains("Progress: 15/282")
                && lb.contains("nothing moves for 5 turns"))
        check("other jobs aren't", Goals.helperGoal("Look only: check the build") == nil && Goals.helperGoal("Goal:") == nil)
        let b = Helpers.brief(assistant: "Ava", user: "Omar", task: "Goal: tidy Downloads")
        check("a goal helper's first prompt sets the goal from its first line", b.hasPrefix("/goal tidy Downloads\n\n(One app note"))
        check(
            "and still carries the whole brief as a note",
            b.contains("You're one of Ava's helpers") && b.contains("You are a helper working on one job"))
        check(
            "a plain helper's brief is unchanged",
            Helpers.brief(assistant: "Ava", user: "Omar", task: "tidy").hasPrefix("You're one of Ava's helpers"))

        // The engine's own goal row (the shape hermes_cli/goals.py writes).
        let row =
            #"{"goal": "Count to 8", "status": "paused", "turns_used": 3, "max_turns": 3, "last_turn_at": 1793926262.5, "last_verdict": "continue", "paused_reason": "turn budget exhausted (3/3)"}"#
        let g = Goals.parse(row)
        check("the engine's row is read", g?.goal == "Count to 8" && g?.turns == 3 && g?.max == 3 && g?.lastTurnAt == 1_793_926_262.5)
        check("a goal out of turns is told apart", g?.budgetUsed == true && g?.active == false)
        check("its end says so in plain words", Goals.endNote(g).contains("stopped after 3 turns") && Goals.endNote(g).contains("/goal resume"))
        let live = GoalLive(goal: "Tidy", status: "active", turns: 2, max: 20)
        check("the line counts the turn at work", Goals.line(live) == "Turn 3 of 20")
        check("the last turn never reads past the budget", Goals.line(GoalLive(goal: "x", status: "active", turns: 20, max: 20)) == "Turn 20 of 20")
        check(
            "done, blocked and no-goal have no end note",
            Goals.endNote(GoalLive(goal: "x", status: "done", turns: 2, max: 20)).isEmpty && Goals.endNote(nil).isEmpty)
        let blocked = GoalLive(
            goal: "Email Bob", status: "paused", turns: 1, max: 20, verdict: "blocked", reason: "waiting for you: needs their yes")
        check(
            "waiting on their yes reads as waiting for them, and says it carries on by itself",
            blocked.waitsOnThem && !blocked.cantBeDone && Goals.statusWords(blocked).hasPrefix("Waiting for you")
                && Goals.statusWords(blocked).contains("I'll carry on") && !Goals.statusWords(blocked).contains("/goal resume"))
        let cant = GoalLive(goal: "x", status: "paused", turns: 1, max: 20, verdict: "blocked", reason: "judged unachievable: no such API")
        check(
            "a goal that can't be done isn't waiting on them",
            cant.cantBeDone && !cant.waitsOnThem && Goals.statusWords(cant).contains("can't be done"))
        let stalled = GoalLive(
            goal: "Build it", status: "paused", turns: 9, max: 20, verdict: "continue",
            reason: "stalled: no progress in the last 5 turns (40/282 done)",
            lastTurnAt: Date().timeIntervalSince1970, done: 40, total: 282)
        check(
            "a stalled goal says plainly why, with the count",
            stalled.stalled && Goals.endNote(stalled).contains("no progress in the last 5 turns (40/282 done)")
                && Goals.statusWords(stalled).contains("no progress in the last 5 turns"))
        let top = GoalLive(
            goal: "x", status: "paused", turns: 500, max: 500, reason: "turn budget exhausted (500/500)", done: 270, total: 282, ceiling: true)
        check(
            "the ceiling is said as the most a goal can run",
            Goals.endNote(top).contains("the most a goal can run") && Goals.endNote(top).contains("270/282"))

        // Progress, as the engine's goal loop keeps it beside the goal (one_goal_progress.py).
        let goalRow = #"{"goal": "Build", "status": "active", "turns_used": 33, "max_turns": 40, "created_at": 1793936227.5}"#
        let mine = #"{"created_at": 1793936227.5, "seen": 34, "done": 120, "total": 282, "extended_at": 30, "extended_by": 20}"#
        let p = Goals.parse(goalRow, progress: mine)
        check("its count is read with the goal", p?.done == 120 && p?.total == 282 && p?.extendedBy == nil)
        check("the line shows the turn and the count, not the limit", p.map(Goals.line) == "Turn 34 · 120/282 done")
        let ext = Goals.parse(goalRow, progress: mine.replacingOccurrences(of: "\"extended_at\": 30", with: "\"extended_at\": 33"))
        check("and says when it was just given more turns", ext.map(Goals.line) == "Turn 34 · 120/282 done · +20 turns, still moving")
        check("a count without a total", Goals.line(GoalLive(goal: "x", status: "active", turns: 11, max: 20, done: 37)) == "Turn 12 · 37 done")
        let old = Goals.parse(goalRow, progress: mine.replacingOccurrences(of: "1793936227.5", with: "1"))
        check("a count from an earlier goal isn't used", old?.done == nil && old.map(Goals.line) == "Turn 34 of 40")
        check("status words", Goals.statusWords(live).contains("Turn 3 of 20") && Goals.statusWords(nil).hasPrefix("No goal is running"))
        check(
            "the engine's own goal-set notice is kept off the screen",
            Goals.isNotice("⊙ Goal set (20-turn budget): x\n") && !Goals.isNotice("Done, it's set."))

        // Reading it from state.db (read only), the line's state, Stop.
        let db = Env.hermesHome.appendingPathComponent("state.db")
        try? FileManager.default.createDirectory(at: Env.hermesHome, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: db)
        var conn: OpaquePointer?
        sqlite3_open(db.path, &conn)
        defer { sqlite3_close(conn) }
        func sql(_ q: String) { sqlite3_exec(conn, q, nil, nil, nil) }
        sql("create table state_meta (key text primary key, value text);")
        sql(#"insert into state_meta values ('goal:h-1', '{"goal": "Tidy Downloads", "status": "active", "turns_used": 4, "max_turns": 20}');"#)
        check("the goal is read from the engine's state", Goals.read("h-1") == GoalLive(goal: "Tidy Downloads", status: "active", turns: 4, max: 20))
        sql(#"insert into state_meta values ('goal:h-2', '{"goal": "Plan", "status": "active", "turns_used": 2, "max_turns": 50}');"#)
        check("a goal's own limit is what its line shows", Goals.read("h-2").map(Goals.line) == "Turn 3 of 50")
        sql(#"insert into state_meta values ('goal:h-3', '{"goal": "Plan", "status": "active", "turns_used": 2}');"#)
        check("no limit in the row = the default", Goals.read("h-3")?.max == Goals.defaultTurns)
        check("a conversation with no goal has none", Goals.read("nope") == nil)

        let m = Model.shared
        m.goals = [:]
        let h = Helper(title: "Tidy Downloads", task: "Goal: Tidy Downloads", sid: "h-1", state: "working", line: "Working on it…")
        m.helpers = [h]
        m.tendGoals()
        for _ in 0..<40 where m.goals[h.id.uuidString] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        check("a working helper's goal shows its line", m.goals[h.id.uuidString]?.turn == 5)
        check("nothing for the main chat while it's idle", m.goals["main"] == nil)
        m.stopGoal(h.id)
        sql(
            #"update state_meta set value = '{"goal": "Tidy Downloads", "status": "paused", "turns_used": 4, "max_turns": 20, "paused_reason": "user-paused"}';"#
        )  // what the engine overlay does on Stop
        check("Stop on the line stops that helper and takes the line away", m.helpers.first?.state == "stopped" && m.goals[h.id.uuidString] == nil)
        m.tendGoals()
        try? await Task.sleep(for: .milliseconds(400))
        check("a stopped helper's goal isn't read again", m.goals.isEmpty)

        // Answered here, never sent to the engine.
        m.openHelper = nil
        m.bubbles = []
        await m.send("/goal status")
        check(
            "/goal status with no goal answers in plain words",
            m.bubbles.last?.text.hasPrefix("No goal is running") == true && m.bubbles.first?.fromMe == true)
        await m.send("/goal pause")
        check("/goal pause with no goal says so", m.bubbles.last?.text == "No goal is running here.")
        await m.send("/goal turns 50")
        check("/goal turns with no goal says so", m.bubbles.last?.text.hasPrefix("No goal is running") == true)
        check("neither started the engine", !Engine.shared.running)

        // A /goal command passed on with [tell-helper: …] runs as one in that helper (it used to arrive as
        // "From Omar, via Ava: /goal resume", plain words, and the goal stayed paused).
        let told = Helper(title: "Build EK intake tool", task: "Goal: x", sid: "h-1", state: "done", line: "")
        m.helpers = [told]
        m.paused = true  // queued, never run: no engine here
        m.followUps = []
        m.tellHelper(told.id, message: "/goal resume")
        for _ in 0..<30 where m.followUps.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        check(
            "a told /goal resume goes to that helper as the command itself",
            m.followUps.count == 1 && m.followUps.first?.engine == "/goal resume" && m.followUps.first?.helper == told.id)
        m.followUps = []
        m.tellHelper(told.id, message: "/goal status")
        for _ in 0..<30 where m.helpers.first?.asked != "/goal status" { try? await Task.sleep(for: .milliseconds(100)) }
        check(
            "a told /goal status is answered in that helper's thread from its goal",
            m.followUps.isEmpty && m.helpers.first?.asked == "/goal status" && m.helpers.first?.reply.contains("Tidy Downloads") == true)
        m.tellHelper(told.id, message: "skip the tests")
        check(
            "other words still say who they're from",
            m.followUps.last?.engine.hasPrefix("From ") == true && m.followUps.last?.engine.hasSuffix("skip the tests") == true)
        m.followUps = []
        m.paused = false
        m.helpers = []

        // What the assistant is told.
        check("SOUL tells it how standing goals work", Persona.soul(assistant: "Ava", user: "Omar").contains("Standing goals:"))
        check("so does every main prompt", SessionNotes.main.contains("STANDING GOALS"))
        check(
            "and where a goal's progress is counted",
            SessionNotes.main.contains("Progress: file `") && SessionNotes.main.contains("Progress: command `")
                && SessionNotes.main.contains("a safety net, not a target") && SessionNotes.main.contains("[tell-helper: <title> | /goal resume]"))
        check(
            "and the limit syntax",
            SessionNotes.main.contains("Goal (50 turns):") && SessionNotes.main.contains("/goal 50 turns:")
                && SessionNotes.main.contains("/goal turns 50"))
        check("helpers aren't told to send goal helpers", !SessionNotes.helper.contains("STANDING GOALS"))
        print(failures == 0 ? "goals ok" : "goals: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
