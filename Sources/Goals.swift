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
    /// The engine's turn budget unless `goals.max_turns` says otherwise.
    static let defaultTurns = 20

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
        case set(String)  // a new goal
        case status, pause, resume, stop
    }

    /// "/goal …" typed into a chat; nil = not a goal command. Stop, clear and done all end the goal (the engine's words).
    static func command(_ text: String) -> Command? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased() == "/goal" || t.lowercased().hasPrefix("/goal ") || t.lowercased().hasPrefix("/goal\n") else { return nil }
        let arg = String(t.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        switch arg.lowercased() {
        case "", "status", "show": return .status
        case "pause": return .pause
        case "resume", "continue", "unpause": return .resume
        case "stop", "clear", "done": return .stop
        default: return .set(arg)
        }
    }

    // MARK: Helpers that carry a goal

    /// A helper job that is a standing goal starts with "Goal:" (the assistant writes it so, like "Look only:").
    static func helperGoal(_ task: String) -> String? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix("goal:") else { return nil }
        let g = t.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        return g.isEmpty ? nil : g
    }

    /// A goal helper's first prompt: the engine sets the goal from the /goal line, and the usual brief goes with the
    /// goal's first turn as a note (the overlay keeps every One app note out of the goal text itself).
    static func helperPrompt(goal: String, brief: String) -> String {
        "/goal " + goal + "\n\n(One app note, not from the user: you are working on this as a STANDING GOAL: after each turn "
            + "One checks whether it's done and has you carry on, up to \(defaultTurns) turns, until it is. Take one solid step "
            + "per turn and say plainly when it's done. Your brief: " + brief + ")"
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

    /// The engine's own "Goal set" / "Goal resumed" notice: the goal line says it already, so it never shows.
    static func isNotice(_ chunk: String) -> Bool { chunk.hasPrefix("⊙ Goal set") || chunk.hasPrefix("▶ Goal resumed") }

    // MARK: What the assistant is told

    static let soul =
        "Standing goals: when they say \"keep at this until it's done: …\", \"don't stop until …\" or ask you to keep going on something until it's finished, send a helper whose job starts with \"Goal:\" and says what done looks like, like [helper: Quebec trip plan | Goal: a day-by-day plan for Quebec City, Dec 20 to 24, with a flight and a hotel picked for each night; done when every day has a plan.]. That helper keeps working turn after turn, a check after each turn decides whether it's done, and it stops when it is, after \(defaultTurns) turns, or when they press Stop. It still asks before sending, posting, spending or deleting, and stops there until they answer. They can also type /goal and what they want in any chat, then /goal status, /goal pause, /goal resume or /goal stop."
    static var note: String { "\n\n(One app note, not from the user: STANDING GOALS. \(soul))" }
}
