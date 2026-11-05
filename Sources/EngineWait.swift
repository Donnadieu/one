import Foundation

// MARK: - Restarts and long jobs don't cut work off or lose the chat

/// How long One waits on a turn. It used to be a fixed 15 minutes (the main chat) or 30 minutes (a helper): a helper
/// still busy at 30 minutes came back "timed out", showed "Picking it back up…" and was sent its job again while
/// its first turn was still running. That, not a restart, is what cut "Forge triage moves" off twice on Nov 4 2026
/// (one-gateway-guard.log: "didn't finish (error: timed out)" at 20:59 and 21:37). Now a turn is waited for as long
/// as it keeps doing something (words, thoughts, a step starting or ending) and given up on only after the same
/// window with nothing at all (a hung engine). The engine dying still ends every wait at once (`Engine.ended`).
enum TurnWait {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: [String: Date] = [:]

    /// Something came back on this conversation.
    static func saw(_ sid: String, at: Date = Date()) {
        lock.lock()
        last[sid] = at
        lock.unlock()
    }
    static func forget(_ sid: String) {
        lock.lock()
        last[sid] = nil
        lock.unlock()
    }

    /// Seconds left before a call started at `started` is given up on (0 or less = now). Without a conversation
    /// to watch, it's the plain window; with one, the window restarts at its latest sign of life.
    static func left(_ sid: String?, started: Date, window: TimeInterval, now: Date = Date()) -> TimeInterval {
        var from = started
        if let sid {
            lock.lock()
            if let seen = last[sid], seen > from { from = seen }
            lock.unlock()
        }
        return window - now.timeIntervalSince(from)
    }
}

extension Engine {
    /// How long a saved conversation is waited for after a restart before a new one is started.
    /// Nov 4 2026, 17:29: One started while the old background helper was still finishing a routine (it drained for
    /// 54 s, then the new one took 20 s to come up). Meanwhile every reopen answered "Gateway could not start:
    /// Another gateway instance is already running", which wasn't on the old "not yet" list of words, so One
    /// gave up after the first answers, opened a new conversation and saved it over the old one: only the
    /// on-screen tail came back. Now only "not found" counts as gone; everything else is waited out this long.
    static let loadPatience: TimeInterval = 4 * 60

    /// The engine's answer says the conversation really doesn't exist (anything else: not ready yet, try again).
    static func gone(_ error: String) -> Bool {
        let e = error.lowercased()
        return ["not_found", "not found", "no such session", "unknown session", "session_not_found"].contains { e.contains($0) }
    }

    /// Why a saved conversation couldn't be reopened, kept so the next time it happens there's a record.
    static func logLoad(_ sid: String, error: String, gaveUp: Bool) {
        GatewayGuard.log("conversation \(sid.prefix(18))… \(gaveUp ? "couldn't be reopened" : "not ready yet"): \(error.prefix(200))")
    }

    /// True when a turn failed because the background helper went away under it (not a real error).
    static func dropped(_ stop: String, text: String, gatewayBefore: pid_t?) -> Bool {
        if text.contains("Gateway shutting down") || text.contains("this turn was interrupted") { return true }
        guard stop.hasPrefix("error") else { return false }
        let e = stop.lowercased()
        if ["shutting down", "interrupted", "draining", "not_ready", "stopped"].contains(where: { e.contains($0) }) { return true }
        // A generic "Internal error" counts only if the gateway really changed or died during the turn.
        guard let g = gatewayBefore else { return false }
        return GatewayGuard.recordedPID() != g || kill(g, 0) != 0
    }
}
