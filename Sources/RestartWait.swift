import Foundation

// MARK: - A helper waiting for One to restart (Nov 17 2026, the "Free Docker memory" helper)
//
// A helper that gets a new folder is told to say it'll restart to use it and end its reply (FolderWatch.note): One
// restarts its engine a moment later. Its turn ended before the restart, so it showed done with Got it; Omar tapped
// Got it, One restarted for the folder, and nothing ever picked the job back up (only helpers still mid-turn were
// paused for the restart). Now a helper whose turn ends while a restart it asked for is still to come (a folder it was
// given, `One --update`, `One --update --restart`) waits: "Waiting for One to restart", no Got it, Done or done-helper
// line (Stop still works), and after the restart it carries on by itself in the same conversation. One an older One
// showed done, or took off the screen, before the restart is brought back at the next restart.
@MainActor
enum RestartWait {
    static let line = "Waiting for One to restart"
    /// How long after its turn ended a helper an older One showed done is still brought back at a restart.
    static let window: TimeInterval = 2 * 3600
    static let recoveredKey = "restartRecovered"
    /// Helpers whose turn ran `One --grant-folder` or `One --update` (this turn).
    private static var askers = Set<UUID>()

    /// The restart that's still to come, in the words of the "was paused for …" line; nil = none.
    static func pending() -> String? {
        if FolderWatch.changed { return FolderWatch.added.isEmpty ? "a restart" : "a new folder" }
        if Updater.shared.installing { return "the update" }
        if let a = UpdateRequest.read() { return a.kind == .restart ? "a restart" : "the update" }
        return nil
    }
    /// Waiting for a restart that hasn't happened yet: never picked back up before it, never asleep.
    static func holding(_ h: Helper) -> Bool { h.restartWait != nil && pending() != nil }

    /// A step of a helper's turn (the engine's raw tool title): did it ask One for a folder or a restart?
    static func saw(_ title: String, by id: UUID) {
        if title.contains("One --grant-folder") || title.contains("One --update") { askers.insert(id) }
    }
    /// The words a helper says when it waits for One to restart (FolderWatch.note tells it to).
    static func says(_ reply: String) -> Bool {
        let l = reply.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return ["restart to use it", "restart one", "one restarts", "one to restart", "one restart", "restart to open"].contains { l.contains($0) }
    }

    /// Its turn ended: wait for the restart if one is still to come and this helper asked for it (or says so).
    static func shouldHold(_ h: Helper, asked: Bool) -> String? {
        guard h.stoppedByYou != true, let reason = pending(), asked || says(h.reply) else { return nil }
        return reason
    }
    static func takeAsked(_ id: UUID) -> Bool { askers.remove(id) != nil }

    /// Waits for the restart: not done, can't be cleared (`HelperClose.busy`), picked back up by itself after it.
    static func hold(_ h: inout Helper, reason: String) {
        h.state = "stopped"
        h.resumeQueued = true
        h.updatePaused = true  // never counted as a cut-off
        h.pausedFor = reason
        h.restartWait = reason
        h.stoppedByYou = nil
        h.seen = nil
        h.finishedAway = false
        h.line = line
        HelperTrail.add("Waiting for One to restart (\(reason))", to: &h)
    }

    /// What it's told when it's picked back up after the restart (its conversation is reopened too).
    static func lead(_ reason: String) -> String {
        "One restarted (for \(reason)), as you said it would. Carry on with your job from where you stopped; don't redo what's done."
    }

    // MARK: Brought back after an older One

    /// At a restart: a helper an older One showed done (still on the screen) or that Got it took off the screen,
    /// whose last words say it was waiting for One to restart, within `window`: waiting again, picked back up after it.
    /// Each one once. Returns the helpers and whether anything changed.
    static func recover(_ hs: [Helper], now: Date = Date()) -> ([Helper], Bool) {
        var hs = hs
        var told = Set(UserDefaults.standard.stringArray(forKey: recoveredKey) ?? [])
        var changed = false
        func recent(_ id: UUID) -> Bool {
            let at = (try? FileManager.default.attributesOfItem(atPath: HelperTrail.url(id).path))?[.modificationDate] as? Date
            return at.map { now.timeIntervalSince($0) < window } ?? false
        }
        for k in hs.indices
        where hs[k].state == "done" && hs[k].bot == nil && hs[k].stoppedByYou != true && !told.contains(hs[k].id.uuidString)
            && says(hs[k].reply) && recent(hs[k].id)
        {
            hold(&hs[k], reason: "a restart")
            told.insert(hs[k].id.uuidString)
            changed = true
        }
        // Taken off the screen: only its trail is left (One's own folder; a test's own folder, never the person's in a test).
        if Env.production || ProcessInfo.processInfo.environment["ONE_SUPPORT_DIR"] != nil {
            let have = Set(hs.map(\.id))
            let files = (try? FileManager.default.contentsOfDirectory(at: HelperTrail.folder, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "md" {
                guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !have.contains(id), !told.contains(id.uuidString),
                    recent(id), let text = try? String(contentsOf: f, encoding: .utf8), var h = fromTrail(text, id: id), says(h.reply)
                else { continue }
                hold(&h, reason: "a restart")
                hs.append(h)
                told.insert(id.uuidString)
                changed = true
            }
        }
        if changed { UserDefaults.standard.set(Array(told.suffix(200)), forKey: recoveredKey) }
        return (hs, changed)
    }

    /// A helper read back from its trail file (HelperTrail.text): title, job, steps, conversation, last words.
    static func fromTrail(_ text: String, id: UUID) -> Helper? {
        func between(_ a: String, _ b: String?) -> String? {
            guard let r = text.range(of: a) else { return nil }
            let rest = text[r.upperBound...]
            let end = b.flatMap { rest.range(of: $0)?.lowerBound } ?? rest.endIndex
            return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("# "), let task = between("## The job\n", "\n## Steps so far"), !task.isEmpty,
            let reply = between("## Latest reply\n", nil), reply != "(nothing yet)"
        else { return nil }
        let steps = (between("## Steps so far\n", "\n## ") ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.map {
            String($0.dropFirst(2))
        }
        if steps.last == HelperTrail.stoppedLine { return nil }  // stopped on purpose: stays stopped
        var h = Helper(title: String(first.dropFirst(2)), task: task, sid: nil, state: "done", line: "Done")
        h.id = id
        h.sid = lines.first { $0.hasPrefix("Conversation: ") }.map { String($0.dropFirst("Conversation: ".count)) }
        h.reply = reply
        h.log = [reply]
        h.trail = steps
        return h
    }
}

@MainActor
extension Model {
    /// The helper's turn ended with a restart it asked for still to come: it waits for it (true), never shows done.
    func holdForRestart(_ id: UUID, stop: String) -> Bool {
        let asked = RestartWait.takeAsked(id)
        guard !stop.hasPrefix("error"), let h = helpers.first(where: { $0.id == id }), let reason = RestartWait.shouldHold(h, asked: asked)
        else { return false }
        update(id) {
            let said = Choices.split($0.reply).body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { $0.log = ($0.log ?? []) + [said] }  // its file keeps these words too
            RestartWait.hold(&$0, reason: reason)
        }
        saveTrail(id)
        Helpers.log("helper \"\(h.title)\" waits for One to restart (\(reason))")
        return true
    }

    /// At a restart: helpers an older One showed done, or took off the screen, while they waited for it come back.
    func recoverRestartWaiters() {
        let (hs, changed) = RestartWait.recover(helpers)
        guard changed else { return }
        helpers = hs
        for h in hs where h.restartWait != nil { HelperTrail.flush(h) }
    }
}
