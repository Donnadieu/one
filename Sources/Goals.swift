import Foundation
import SQLite3

// MARK: - Standing goals (`/goal`): "keep at this until it's done"
//
// The loop is the engine's own (hermes_cli/goals.py, run by its gateway after every turn: a judge looks at the
// reply, the turn budget, 20 by default, the auto-pause). One's engine overlay `tools/overlay/acp_adapter/one_goals.py`
// (Installer.applyGoals) keeps One's prompt open for all of a goal's turns, so a goal is one long reply here and
// every rule One has for a reply still holds: Stop ends it (the overlay pauses the goal), the Mac stays awake, a
// helper with a goal is "done" only when the goal is. One itself only reads the goal's state for its one line,
// turns typed commands and "Goal:" helper jobs into /goal, and says what happened in plain words.
// The turn limit is a safety net, not a target: `tools/overlay/hermes_cli/one_goal_progress.py` (hooked into the
// engine's goal loop) gives a goal that is still moving more turns, up to a ceiling, pauses one that stalled, and
// pauses one that asked them something as "waiting for you" (it carries on when they answer). Its count sits in
// state_meta `one-goal:<conversation>` beside the goal.

/// One conversation's goal, as the engine keeps it (`state_meta` row `goal:<conversation>` in hermes/state.db).
struct GoalLive: Equatable, Sendable {
    var goal: String
    var status: String  // active, paused, done, cleared
    var turns: Int  // turns the judge has looked at so far
    var max: Int
    var verdict: String?
    var reason: String?
    var lastTurnAt: Double? = nil  // when the judge last looked (seconds since 1970)
    var done: Int? = nil  // its progress count, when one is known ("120" of "282")
    var total: Int? = nil
    var extendedBy: Int? = nil  // given this many more turns at its last turn or the one before (it was still moving)
    var ceiling = false  // stopped at the most turns a goal can run
    var active: Bool { status == "active" }
    /// The turn being worked on now (never past the budget).
    var turn: Int { Swift.min(turns + 1, Swift.max(max, 1)) }
    /// Stopped because every turn of its budget was used.
    var budgetUsed: Bool { status == "paused" && (reason ?? "").contains("budget") }
    /// Stopped because the next step needs them (a yes, a choice, an answer): it carries on when they answer.
    var waitsOnThem: Bool { status == "paused" && (reason ?? "").hasPrefix("waiting for you") }
    /// Stopped because nothing moved for several turns in a row (the reason says how many, with the count).
    var stalled: Bool { status == "paused" && (reason ?? "").hasPrefix("stalled") }
    /// Stopped because the check after its turn found it can't be done as asked.
    var cantBeDone: Bool { status == "paused" && verdict == "blocked" && !waitsOnThem }
    /// "120/282 done", "37 done", or nil when no count is known.
    var progress: String? { done.map { d in total.map { "\(d)/\($0) done" } ?? "\(d) done" } }
}

enum Goals {
    /// The engine's turn budget unless `goals.max_turns` says otherwise, or the goal carries its own limit.
    static let defaultTurns = 20
    /// The most turns any goal runs, however well it's moving (one_goal_progress.py, `goals.max_turns_ceiling`),
    /// the turns it gets each time it reaches its limit still moving, and the turns in a row with no progress that
    /// pause it (`goals.extend_by`, `goals.stall_turns`).
    static let ceilingTurns = 500
    static let extendTurns = 20
    static let stallTurns = 5
    /// A goal's own limit stays in 1...200 (the engine overlay keeps the same bounds: one_goals.py MIN/MAX_TURNS).
    static let minTurns = 1
    static let maxTurns = 200
    static func clamp(_ n: Int) -> Int { Swift.max(minTurns, Swift.min(maxTurns, n)) }

    // MARK: Reading the engine's state (read only, never written)

    static func read(_ sid: String, db: URL = Env.hermesHome.appendingPathComponent("state.db")) -> GoalLive? {
        guard !sid.isEmpty, let d = ReadOnlyDB(db.path) else { return nil }
        var rows: [String: String] = [:]
        d.each("SELECT key, value FROM state_meta WHERE key IN (?, ?)", ["goal:" + sid, "one-goal:" + sid]) { st in
            guard let k = sqlite3_column_text(st, 0), let v = sqlite3_column_text(st, 1) else { return }
            rows[String(cString: k)] = String(cString: v)
        }
        return rows["goal:" + sid].flatMap { parse($0, progress: rows["one-goal:" + sid]) }
    }

    static func parse(_ json: String, progress: String? = nil) -> GoalLive? {
        guard let j = object(json), let goal = j["goal"] as? String, let status = j["status"] as? String else { return nil }
        let n = { (k: String) in (j[k] as? NSNumber)?.intValue ?? 0 }
        var g = GoalLive(
            goal: goal, status: status, turns: n("turns_used"), max: n("max_turns") > 0 ? n("max_turns") : defaultTurns,
            verdict: j["last_verdict"] as? String, reason: j["paused_reason"] as? String, lastTurnAt: (j["last_turn_at"] as? NSNumber)?.doubleValue)
        // One's count beside it, only when it belongs to this goal (a new goal starts a new count).
        guard let p = progress.flatMap(object), (p["created_at"] as? NSNumber)?.doubleValue == (j["created_at"] as? NSNumber)?.doubleValue
        else { return g }
        let pn = { (k: String) in (p[k] as? NSNumber)?.intValue }
        g.done = pn("done")
        g.total = pn("total").flatMap { $0 > 0 ? $0 : nil }
        if let at = pn("extended_at"), let seen = pn("seen"), seen - at < 2 { g.extendedBy = pn("extended_by") }
        g.ceiling = (p["ceiling"] as? Bool) == true
        return g
    }
    static func object(_ json: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] }

    // MARK: What they type

    enum Command: Equatable {
        case set(String)  // a new goal, as typed ("50 turns: …" or "--turns 50 …" in it is read by the engine overlay)
        case turns(Int)  // "/goal turns 50": a new limit for the goal here (the number as asked, not yet capped)
        case status, pause, resume, stop
    }

    /// "turns 50", "turns: 50", "50 turns": the number, or nil when it isn't a change of limit.
    static func turnsChange(_ arg: String) -> Int? {
        let a = arg.lowercased().trimmingCharacters(in: .whitespaces)
        for p in [#"^turns?\s*[:=]?\s*(\d{1,12})(\s*turns?)?$"#, #"^(\d{1,12})\s*turns?$"#] {
            guard let r = a.range(of: p, options: .regularExpression) else { continue }
            return Int(a[r].filter(\.isNumber).prefix(12))
        }
        return nil
    }

    /// "/goal …" typed into a chat; nil = not a goal command. Stop, clear and done all end the goal (the engine's words).
    static func command(_ text: String) -> Command? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased() == "/goal" || t.lowercased().hasPrefix("/goal ") || t.lowercased().hasPrefix("/goal\n") else { return nil }
        let arg = String(t.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        switch arg.lowercased() {
        case "", "status", "show", "turns": return .status
        case "pause": return .pause
        case "resume", "continue", "unpause": return .resume
        case "stop", "clear", "done": return .stop
        default: return turnsChange(arg).map { .turns($0) } ?? .set(arg)
        }
    }

    // MARK: Helpers that carry a goal

    /// A helper job that is a standing goal starts with "Goal:" (the assistant writes it so, like "Look only:"), or
    /// "Goal (50 turns):" for a limit of its own. turns: the number as written (the engine overlay caps it), nil = default.
    static func helperGoal(_ task: String) -> (goal: String, turns: Int?)? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let head = t.range(of: #"^[Gg][Oo][Aa][Ll]\s*(\([^)\n]*\))?\s*:"#, options: .regularExpression) else { return nil }
        let g = t[head.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let inParens = t[head].range(of: #"\d{1,12}"#, options: .regularExpression).flatMap { Int(t[$0]) }
        return g.isEmpty ? nil : (g, inParens)
    }

    /// A goal helper's first prompt: the engine sets the goal from the /goal line (with its own limit, if it has one),
    /// and the usual brief goes with the goal's first turn as a note (the overlay keeps One's notes out of the goal).
    static func helperPrompt(goal: String, turns: Int? = nil, brief: String) -> String {
        "/goal " + (turns.map { "--turns \($0) " } ?? "") + goal
            + "\n\n(One app note, not from the user: you are working on this as a STANDING GOAL: after each turn "
            + "One checks whether it's done and has you carry on until it is. It starts with \(turns.map(clamp) ?? defaultTurns) turns "
            + "and gets more while it keeps making progress (up to \(ceilingTurns)); it pauses if nothing moves for \(stallTurns) turns. "
            + "Take one solid step per turn, end each turn with a line like \"Progress: 15/282\" when the work can be counted, "
            + "and say plainly when it's done. Your brief: " + brief + ")"
    }

    // MARK: Words

    /// The goal as the line shows it: one line, about 52 characters, cut at a word.
    static func short(_ goal: String, _ n: Int = 52) -> String {
        let one = goal.components(separatedBy: .newlines).first ?? goal
        guard one.count > n else { return one }
        let cut = String(one.prefix(n))
        return (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut) + "…"
    }

    /// The one line shown while a goal works: how far along. With a count, the limit isn't the point (it's a
    /// safety net that grows while the count moves), so only the turn and the count show.
    static func line(_ g: GoalLive) -> String {
        var parts = [g.progress == nil ? "Turn \(g.turn) of \(g.max)" : "Turn \(g.turn)"]
        if let p = g.progress { parts.append(p) }
        if let by = g.extendedBy { parts.append("+\(by) turns, still moving") }
        return parts.joined(separator: " · ")
    }
    /// "(120/282 done)" for a sentence, or "".
    static func counted(_ g: GoalLive) -> String { g.progress.map { " (\($0))" } ?? "" }

    /// The answer to "/goal status", in plain words, from the engine's own state.
    static func statusWords(_ g: GoalLive?) -> String {
        guard let g, g.status != "cleared" else { return "No goal is running here. Say /goal and what you want done." }
        switch g.status {
        case "active": return "Working on it: \(g.goal)\n\(line(g))."
        case "done": return "Done, in \(g.turns) \(g.turns == 1 ? "turn" : "turns"): \(g.goal)"
        default:
            if g.waitsOnThem { return "Waiting for you: \(g.goal)\nAnswer the question above and I'll carry on." }
            if g.stalled { return "Paused, \(stallWhy(g)): \(g.goal)\nSay /goal resume to try again, or tell me what to change." }
            if g.budgetUsed && g.ceiling {
                return "Paused at \(g.max) turns, the most a goal can run, not done yet\(counted(g)): \(g.goal)\nSay /goal resume to keep going."
            }
            if g.budgetUsed { return "Paused after all \(g.max) turns, not done yet\(counted(g)): \(g.goal)\nSay /goal resume to keep going." }
            if g.cantBeDone { return "Paused, it can't be done as asked: \(g.goal)\nSay /goal resume to try anyway, or set a new goal." }
            return "Paused: \(g.goal)\nSay /goal resume to pick it back up."
        }
    }
    /// "no progress in the last 5 turns (120/282 done)", from the engine's own reason.
    static func stallWhy(_ g: GoalLive) -> String {
        let r = (g.reason ?? "").replacingOccurrences(of: "stalled: ", with: "")
        return r.isEmpty ? "no progress in the last \(stallTurns) turns" : r
    }

    /// Added under a reply whose goal just stopped by itself: out of turns, or stalled (done and waiting replies
    /// speak for themselves).
    static func endNote(_ g: GoalLive?) -> String {
        guard let g else { return "" }
        if g.stalled { return "\n\nI paused this goal: \(stallWhy(g)). Say /goal resume to try again, or tell me what to change." }
        guard g.budgetUsed else { return "" }
        if g.ceiling {
            return "\n\nI stopped at \(g.max) turns, the most a goal can run, and it isn't done yet\(counted(g)). Say /goal resume to keep going."
        }
        return "\n\nI stopped after \(g.max) turns and it isn't done yet\(counted(g)). Say /goal resume to keep going."
    }

    /// The answer to "/goal turns N" once the engine has it (after = the goal's row read back).
    static func turnsWords(asked: Int, after g: GoalLive?) -> String {
        let n = clamp(asked)
        guard let g, g.status == "active" || g.status == "paused" else { return "No goal is running here. Say /goal and what you want done." }
        guard g.max == n else { return "I couldn't change the limit of this goal. It still has \(g.max) turns." }
        var s = "Done. This goal can take up to \(n) \(n == 1 ? "turn" : "turns") now."
        if asked > maxTurns { s += " \(maxTurns) is the most a goal can have." }
        if asked < minTurns { s += " A goal needs at least \(minTurns) turn." }
        if g.active && g.turns >= n { s += " It stops after the turn at work." }
        if !g.active { s += " Say /goal resume to keep going." }
        return s
    }

    /// The engine overlay in this engine reads a goal's own limit (one_goals.py from 0.9.94 on). Without it,
    /// "/goal turns 50" would set a new goal called "turns 50", so it's never sent.
    static var overlayKnowsTurns: Bool {
        let f = Env.engineDir.appendingPathComponent("acp_adapter/one_goals.py")
        return (try? String(contentsOf: f, encoding: .utf8))?.contains("LIMIT_NOTICE") == true
    }

    /// The engine's own "Goal set" / "Goal resumed" / "Goal limit" notice: the goal line (or One's own answer) says it
    /// already, so it never shows.
    static func isNotice(_ chunk: String) -> Bool {
        chunk.hasPrefix("⊙ Goal set") || chunk.hasPrefix("▶ Goal resumed") || chunk.hasPrefix("⊙ Goal limit")
    }

    // MARK: What the assistant is told

    static let soul =
        "Standing goals: when they say \"keep at this until it's done: …\", \"don't stop until …\" or ask you to keep going on something until it's finished, send a helper whose job starts with \"Goal:\" and says what done looks like, like [helper: Quebec trip plan | Goal: a day-by-day plan for Quebec City, Dec 20 to 24, with a flight and a hotel picked for each night; done when every day has a plan.]. That helper keeps working turn after turn and a check after each turn decides whether it's done. The turn limit is a safety net, not a target: it starts at \(defaultTurns) turns and gets \(extendTurns) more each time it reaches it while still making progress, up to \(ceilingTurns); it pauses and says why if nothing moves for \(stallTurns) turns in a row, and it stops when it's done or when they press Stop. Say where its progress is counted, on the job's last words: \"Progress: file `<path>`\" (ticked [x] boxes out of all the boxes in that checklist), \"Progress: file `<path>` matching <pattern>\" (lines that match) or \"Progress: command `<command>`\" (a number, or 15/282, in what it prints), like [helper: Build the app | Goal: every requirement in docs/spec-coverage.md built with a passing test. Progress: file `docs/spec-coverage.md`]. Without one, the helper reports \"Progress: 15/282\" itself when the work can be counted, else the check judges whether each turn moved it closer. If they give a limit (\"up to 50 tries\", \"50 turns\"), put it in the job as \"Goal (50 turns): …\"; \(minTurns) to \(maxTurns) turns, and without one it's \(defaultTurns). It still asks before sending, posting, spending or deleting, and waits there until they answer; when it asks them something it waits for them and carries on as soon as they answer, no resume needed. They can also type /goal and what they want in any chat (/goal 50 turns: <goal> for a limit of its own), then /goal status, /goal pause, /goal resume, /goal stop, or /goal turns 50 to change the limit of the goal at work; a /goal command passed on with [tell-helper: <title> | /goal resume] runs in that helper."
    static var note: String { "\n\n(One app note, not from the user: STANDING GOALS. \(soul))" }
}
