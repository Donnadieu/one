import Foundation

// MARK: - A helper is "done" only when its job really finished

/// How a helper's turn really ended. Only a real, complete answer counts as done. Anything else (the engine
/// restarted under it, its connection dropped, it was cancelled without the Stop button, it ran out of room,
/// or it ended without a word) leaves it stopped, and a cut-off one is picked back up by itself.
/// Oct 28: the Folders window's Done restarted the engine with seven helpers at work; every one of them
/// came back "error: stopped" with half a sentence of narration, and One showed all seven as done.
enum HelperEnd: Equatable {
    case finished
    /// Cut off: picked back up by itself (counts toward `HelperTrail.maxResumes`).
    case cutOff
    /// Its conversation is still busy finishing the old turn (the engine keeps running a turn whose
    /// connection dropped): wait and try again, without counting it as a cut-off.
    case busy
    /// A real error: stopped with the reason, never shown as done.
    case failed(String)

    /// Words in an engine error that mean the turn was cut off rather than failed.
    static let cutWords = [
        "stopped", "shutting down", "interrupted", "draining", "not_ready", "not ready", "disconnected", "outcome is unknown",
        "timed out", "no answer", "not started", "couldn't pick this job back up", "starting", "unavailable", "connection",
    ]

    static func of(stop: String, reply: String) -> HelperEnd {
        let s = stop.lowercased()
        let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.contains("busy") { return .busy }
        if s.hasPrefix("error") {
            return cutWords.contains { s.contains($0) } ? .cutOff : .failed(String(stop.dropFirst(7)))
        }
        // The gateway's own words when it stopped mid-turn, delivered as an ordinary reply.
        if said.contains("Gateway shutting down") || said.contains("this turn was interrupted") { return .cutOff }
        switch s {
        case "cancelled", "max_tokens", "max_turn_requests": return .cutOff
        case "refusal": return .failed("the AI refused to go on")
        default: return said.isEmpty ? .cutOff : .finished
        }
    }
}

extension HelperTrail {
    static let cutLine = "Stopped · picking it back up"
    static let busyLine = "Stopped · finishing its last step, then picking back up"
    static let failedLine = "Stopped: couldn't finish · tap to see what it did"
    /// How long a helper may wait for its old turn to end before One gives up on it (tries × 20 s).
    static let maxBusyTries = 90

    /// A turn ended without finishing the job: never "done". Returns true when it's queued to pick back up.
    @discardableResult
    static func notFinished(_ h: inout Helper, _ end: HelperEnd) -> Bool {
        h.state = "stopped"
        h.seen = nil
        switch end {
        case .finished: return false
        case .busy:
            let n = (h.busyTries ?? 0) + 1
            h.busyTries = n
            guard n <= maxBusyTries else {
                h.resumeQueued = false
                h.line = failedLine
                add("Gave up waiting for its last step", to: &h)
                return false
            }
            h.resumeQueued = true
            h.line = busyLine
            if n == 1 { add("Waiting for its last step to finish", to: &h) }
            return true
        case .cutOff:
            h.busyTries = nil
            guard (h.resumes ?? 0) < maxResumes else {
                h.resumeQueued = false
                h.line = gaveUp(h.resumes ?? 0)
                add("Cut off again · stopped", to: &h)
                return false
            }
            h.resumeQueued = true
            h.line = cutLine
            add("Cut off before it finished · picking it back up", to: &h)
            return true
        case .failed(let why):
            h.busyTries = nil
            h.resumeQueued = false
            h.line = failedLine
            let note = "I couldn't finish this (\(why))."
            h.reply = h.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : h.reply + "\n\n" + note
            add("Stopped: \(why)", to: &h)
            return false
        }
    }
}

@MainActor
extension Model {
    /// The helper's turn ended without finishing its job: show it stopped (never done, no shelf card, no
    /// "is done" line) and pick it back up once the engine answers again. Returns true if it was handled.
    func helperDidNotFinish(_ id: UUID, stop: String) -> Bool {
        guard let h = helpers.first(where: { $0.id == id }) else { return false }
        let end = HelperEnd.of(stop: stop, reply: h.reply)
        guard end != .finished else {
            update(id) { $0.busyTries = nil }
            return false
        }
        var queued = false
        update(id) { queued = HelperTrail.notFinished(&$0, end) }
        GatewayGuard.log("helper \"\(h.title)\" didn't finish (\(stop.prefix(120))): \(queued ? "picking it back up" : "stopped")")
        saveTrail(id)
        if queued {
            resumeWhenReady(after: end == .busy ? 20 : 3)
        } else if let b = h.routine {
            Task { await deliverRoutine(b) }
        }
        return true
    }

    /// Once the engine answers again (a restart may be under way), pick up every helper waiting for it.
    func resumeWhenReady(after secs: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            // The engine may be gone for good (it crashed or was killed, not restarted): start it again.
            for _ in 0..<100 where !Engine.shared.running {
                await self.startEngineAgain()
                if !Engine.shared.running { try? await Task.sleep(for: .seconds(3)) }
            }
            self.resumeInterrupted()
        }
    }
}
