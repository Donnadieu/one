import Foundation

/// The engine is shared by every conversation. Replacing it mid-turn cuts off helpers, so a brain
/// change waits for all their old turns (including queued restart pickups) to finish.
enum SwitchAI {
    static func currentProvider(_ config: String) -> Provider? {
        guard let line = config.split(separator: "\n").first(where: { $0.hasPrefix("  provider:") }) else { return nil }
        let id = line.dropFirst("  provider:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return Provider.allCases.first { $0.hermesID == id }
    }
    static func inFlight(_ h: Helper) -> Bool { h.state == "working" || h.resumeQueued == true }
    static func ready(_ helpers: [Helper], thinking: Bool) -> Bool {
        !thinking && !helpers.contains(where: inFlight)
    }
    static func answered(stop: String, reply: String) -> Bool {
        !stop.hasPrefix("error") && reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ready"
    }
    /// The plain-words line shown with Cancel while a switch waits for helpers to finish on their old AI.
    /// `nil` means there's nothing to wait for and the switch can go straight ahead.
    static func waitMessage(for title: String, helpers: [Helper], thinking: Bool) -> String? {
        guard !ready(helpers, thinking: thinking) else { return nil }
        let waitingCount = helpers.filter(inFlight).count
        guard waitingCount > 0 else { return "Switching to \(title) once the current answer finishes." }
        let plural = waitingCount == 1 ? "" : "s"
        let verb = waitingCount == 1 ? "es" : ""
        return "Switching to \(title) once your \(waitingCount) helper\(plural) finish\(verb). They'll stay on their current AI."
    }
}
