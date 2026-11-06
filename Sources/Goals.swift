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

/// One conversation's goal, as the engine keeps it (`state_meta` row `goal:<conversation>` in hermes/state.db).
struct GoalLive: Equatable, Sendable {
    var goal: String
    var status: String  // active, paused, done, cleared
    var turns: Int  // turns the judge has looked at so far
    var max: Int
    var verdict: String?
    var reason: String?
    var lastTurnAt: Double? = nil  // when the judge last looked (seconds since 1970)
    var active: Bool { status == "active" }
    /// The turn being worked on now (never past the budget).
    var turn: Int { Swift.min(turns + 1, Swift.max(max, 1)) }
    /// Stopped because every turn of its budget was used.
    var budgetUsed: Bool { status == "paused" && (reason ?? "").contains("budget") }
    /// Stopped because the next step needs them (a yes, a choice, something only they can give).
    var waitsOnThem: Bool { status == "paused" && verdict == "blocked" }
}

enum Goals {
    /// The engine's turn budget unless `goals.max_turns` says otherwise, or the goal carries its own limit.
    static let defaultTurns = 20
    /// A goal's own limit stays in 1...200 (the engine overlay keeps the same bounds: one_goals.py MIN/MAX_TURNS).
    static let minTurns = 1
    static let maxTurns = 200
    static func clamp(_ n: Int) -> Int { Swift.max(minTurns, Swift.min(maxTurns, n)) }

    // MARK: Reading the engine's state (read only, never written)

    static func read(_ sid: String, db: URL = Env.hermesHome.appendingPathComponent("state.db")) -> GoalLive? {
        guard !sid.isEmpty, let d = ReadOnlyDB(db.path) else { return nil }
        var out: GoalLive?
        d.each("SELECT value FROM state_meta WHERE key = ?", ["goal:" + sid]) { st in
            guard let c = sqlite3_column_text(st, 0) else { return }
            out = parse(String(cString: c))
        }
        return out
    }

    static func parse(_ json: String) -> GoalLive? {
        guard let j = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
            let goal = j["goal"] as? String, let status = j["status"] as? String
        else { return nil }
        let n = { (k: String) in (j[k] as? NSNumber)?.intValue ?? 0 }
        return GoalLive(
            goal: goal, status: status, turns: n("turns_used"), max: n("max_turns") > 0 ? n("max_turns") : defaultTurns,
            verdict: j["last_verdict"] as? String, reason: j["paused_reason"] as? String, lastTurnAt: (j["last_turn_at"] as? NSNumber)?.doubleValue)
    }

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
            + "One checks whether it's done and has you carry on, up to \(turns.map(clamp) ?? defaultTurns) turns, until it is. "
            + "Take one solid step per turn and say plainly when it's done. Your brief: " + brief + ")"
    }

    // MARK: Words

    /// The goal as the line shows it: one line, about 52 characters, cut at a word.
    static func short(_ goal: String, _ n: Int = 52) -> String {
        let one = goal.components(separatedBy: .newlines).first ?? goal
        guard one.count > n else { return one }
        let cut = String(one.prefix(n))
        return (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut) + "…"
    }

    /// The one line shown while a goal works: what it is and how far along.
    static func line(_ g: GoalLive) -> String { "Turn \(g.turn) of \(g.max)" }

    /// The answer to "/goal status", in plain words, from the engine's own state.
    static func statusWords(_ g: GoalLive?) -> String {
        guard let g, g.status != "cleared" else { return "No goal is running here. Say /goal and what you want done." }
        switch g.status {
        case "active": return "Working on it: \(g.goal)\nTurn \(g.turn) of \(g.max)."
        case "done": return "Done, in \(g.turns) \(g.turns == 1 ? "turn" : "turns"): \(g.goal)"
        default:
            if g.budgetUsed { return "Paused after all \(g.max) turns, not done yet: \(g.goal)\nSay /goal resume to keep going." }
            if g.waitsOnThem { return "Waiting on you: \(g.goal)\nAnswer the question above, or say /goal resume." }
            return "Paused: \(g.goal)\nSay /goal resume to pick it back up."
        }
    }

    /// Added under a reply whose goal just ran out of turns (done and blocked replies speak for themselves).
    static func endNote(_ g: GoalLive?) -> String {
        guard let g, g.budgetUsed else { return "" }
        return "\n\nI stopped after \(g.max) turns and it isn't done yet. Say /goal resume to keep going."
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
        "Standing goals: when they say \"keep at this until it's done: …\", \"don't stop until …\" or ask you to keep going on something until it's finished, send a helper whose job starts with \"Goal:\" and says what done looks like, like [helper: Quebec trip plan | Goal: a day-by-day plan for Quebec City, Dec 20 to 24, with a flight and a hotel picked for each night; done when every day has a plan.]. That helper keeps working turn after turn, a check after each turn decides whether it's done, and it stops when it is, after \(defaultTurns) turns, or when they press Stop. If they give a limit (\"up to 50 tries\", \"50 turns\"), put it in the job as \"Goal (50 turns): …\"; \(minTurns) to \(maxTurns) turns, and without one it's \(defaultTurns). It still asks before sending, posting, spending or deleting, and stops there until they answer. They can also type /goal and what they want in any chat (/goal 50 turns: <goal> for a limit of its own), then /goal status, /goal pause, /goal resume, /goal stop, or /goal turns 50 to change the limit of the goal at work."
    static var note: String { "\n\n(One app note, not from the user: STANDING GOALS. \(soul))" }
}
