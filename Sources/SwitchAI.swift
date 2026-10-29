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
}
