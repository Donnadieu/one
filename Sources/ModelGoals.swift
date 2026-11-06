import Foundation

// MARK: - Standing goals in the chat (Goals.swift): typed /goal commands, the goal line's state, Stop

extension Model {
    /// toNova: the floating orb always talks to Nova, never to an open helper. A typed "/goal …" is looked at first:
    /// status, pause and stop are answered here; a new goal and resume go on to the engine like any message.
    func send(_ text: String, toNova: Bool = false, hidden: Bool = false) async {
        if !hidden, let c = Goals.command(text), await goalTyped(c, text: text, helper: toNova ? nil : openHelper) { return }
        await sendNow(text, toNova: toNova, hidden: hidden)
    }

    /// The engine conversation for "main" or a helper's goal.
    func goalSession(_ helper: UUID?) -> String? {
        guard let helper else { return Engine.shared.mainSession }
        return helpers.first { $0.id == helper }?.sid
    }

    /// True when it was answered here (status, pause, stop); false = send it on (a new goal, resume).
    func goalTyped(_ c: Goals.Command, text: String, helper: UUID?) async -> Bool {
        let sid = goalSession(helper)
        let read = { () async -> GoalLive? in await Task.detached { sid.flatMap { Goals.read($0) } }.value }
        switch c {
        case .set, .resume:
            return false
        case .status:
            goalAnswer(text, Goals.statusWords(await read()), helper: helper)
        case .pause, .stop:
            let g = await read()
            guard let g, g.active || (c == .stop && g.status == "paused") else {
                goalAnswer(text, "No goal is running here.", helper: helper)
                return true
            }
            if g.active { stopGoal(helper) }  // its turn is cancelled and the engine overlay pauses the goal
            if c == .stop, let sid { await goalBare(sid, "/goal stop", helper: helper) }
            goalAnswer(text, c == .stop ? "Stopped, and that goal is cleared." : "Paused. Say /goal resume to pick it back up.", helper: helper)
        }
        return true
    }

    /// One's own answer to a goal command, shown like a reply (nothing sent to the engine for it).
    func goalAnswer(_ typed: String, _ words: String, helper: UUID?) {
        guard let helper else {
            me(typed)
            bubbles.append(Bubble(fromMe: false, text: words))
            return
        }
        update(helper) {
            $0.asked = typed
            $0.reply += ($0.reply.isEmpty ? "" : "\n\n") + words
        }
    }

    /// The goal line's Stop (and "/goal pause"): the turn at work is cancelled; the engine overlay pauses the goal
    /// (one_goals.py). If the goal is somehow still on a moment later (an engine without the overlay), it's paused here.
    func stopGoal(_ helper: UUID?) {
        if let helper { stopHelper(helper) } else { Engine.shared.cancel() }
        let key = helper?.uuidString ?? "main"
        goals[key] = nil
        guard let sid = goalSession(helper) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if await Task.detached(operation: { Goals.read(sid)?.active == true }).value { await goalBare(sid, "/goal pause", helper: helper) }
        }
    }

    /// A goal command the engine answers without a turn, with its words kept off the screen. Waits (up to 20 s)
    /// for the conversation's cancelled turn to end first.
    func goalBare(_ sid: String, _ command: String, helper: UUID?) async {
        for _ in 0..<40 {
            let busy = helper.map { id in helpers.first { $0.id == id }?.state == "working" } ?? thinking
            if !busy { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if helper == nil {
            let keep = Engine.shared.onText
            Engine.shared.onText = nil
            _ = await Engine.shared.prompt(command)
            if Engine.shared.onText == nil { Engine.shared.onText = keep }
        } else {
            _ = await Engine.shared.promptSession(sid, command, onText: { _ in }, onTool: { _ in })
        }
    }

    /// Every 2 s from the main loop: the goal state of each conversation at work (main while a turn runs, helpers
    /// while they work), read off the main thread. Only active goals are kept; nothing at work = nothing read.
    func tendGoals() {
        guard !goalReading else { return }
        var want: [(String, String)] = []
        if thinking, let s = Engine.shared.mainSession { want.append(("main", s)) }
        for h in helpers where h.state == "working" { if let s = h.sid { want.append((h.id.uuidString, s)) } }
        if want.isEmpty {
            if !goals.isEmpty { goals = [:] }
            return
        }
        goalReading = true
        Task.detached {
            var found: [String: GoalLive] = [:]
            for (k, s) in want { if let g = Goals.read(s), g.active { found[k] = g } }
            let now = found
            await MainActor.run {
                self.goalReading = false
                if self.goals != now { self.goals = now }
            }
        }
    }

    /// Added under a reply whose goal just ran out of turns: says so in plain words ("" otherwise).
    func goalEnd(_ helper: UUID?) -> String {
        guard let sid = goalSession(helper), let g = Goals.read(sid), g.turns > 0 else { return "" }
        guard let t = g.lastTurnAt, Date().timeIntervalSince1970 - t < 120 else { return "" }  // this goal, just now
        return Goals.endNote(g)
    }
}
