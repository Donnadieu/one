import Foundation

/// How hard the AI thinks before it answers (the engine's `agent.reasoning_effort`). Smartest, Balanced and Fastest
/// set it by themselves (Omar's pick, Nov 9 2026, design docs/design-docs/ai-picker-extras.md, Direction B); the card's
/// "More options" shows only the levels the engine really sends for that model (`AICatalog.efforts`).
enum Effort: String, CaseIterable, Identifiable {
    case none, low, medium, high, xhigh, max
    var id: String { rawValue }

    var word: String {
        switch self {
        case .none: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
    /// The one-line meaning beside each level.
    var meaning: String {
        switch self {
        case .none: "answers right away"
        case .low: "quick answers"
        case .medium: "a bit of thought"
        case .high: "thinks it through"
        case .xhigh: "thinks a long time"
        case .max: "slowest, most careful"
        }
    }

    /// What a brain pill sets: Smartest (tier 0) the model's top level, Balanced (1) Medium, Fastest (2) Low, each
    /// stepped down to the nearest level the model has (never up, like the engine's own clamp). Off is never picked
    /// for them. Nil when the model has no thinking levels: then nothing is written.
    static func preset(tier: Int, levels: [Effort]) -> Effort? {
        let on = levels.filter { $0 != .none }
        guard let top = on.last else { return nil }
        if tier <= 0 { return top }
        let want: Effort = tier == 1 ? .medium : .low
        let order = Effort.allCases
        let below = on.filter { order.firstIndex(of: $0)! <= order.firstIndex(of: want)! }
        return below.last ?? on.first
    }

    /// The small line under a pill's model name (Direction B).
    static func pillLine(_ e: Effort?, levels: [Effort]) -> String {
        guard let e else { return "no thinking levels" }
        if e == levels.filter({ $0 != .none }).last, levels.count > 1 { return "thinks hardest" }
        switch e {
        case .none, .low: return "thinks briefly"
        case .medium: return "thinks a bit"
        case .high: return "thinks it through"
        case .xhigh: return "thinks a long time"
        case .max: return "thinks hardest"
        }
    }

    /// The engine's words, in order, from one `efforts` answer; anything else ("minimal", "ultra") is not offered.
    static func list(_ words: [String]) -> [Effort] {
        let set = Set(words.compactMap(Effort.init(rawValue:)))
        return Effort.allCases.filter(set.contains)
    }

    /// What config.yaml has now (`agent.reasoning_effort`), or nil when unset or unknown.
    static func current(_ config: String) -> Effort? {
        var inAgent = false
        for raw in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.hasPrefix("#") && !line.isEmpty { inAgent = line.hasPrefix("agent:") }
            let t = line.trimmingCharacters(in: .whitespaces)
            guard inAgent, line.hasPrefix("  "), !line.hasPrefix("   "), t.hasPrefix("reasoning_effort:") else { continue }
            let v = t.dropFirst("reasoning_effort:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return Effort(rawValue: v == "false" || v == "disabled" ? "none" : v)
        }
        return nil
    }
    static func current() -> Effort? {
        current((try? String(contentsOf: Env.hermesHome.appendingPathComponent("config.yaml"), encoding: .utf8)) ?? "")
    }

    /// Writes the level for every new chat, helper and routine. Only One's six words ever reach the engine: its own
    /// `config set` takes any string and a typo there silently means "unset".
    static func save(_ e: Effort) async -> Bool {
        guard Effort(rawValue: e.rawValue) != nil else { return false }
        let (status, _) = await hermesRun(["config", "set", "agent.reasoning_effort", e.rawValue])
        return status == 0 && current() == e
    }

    /// Set by hand under More options (the dot on the pill). Picking a brain clears it.
    static var byHand: Bool {
        get { UserDefaults.standard.bool(forKey: "effortByHand") }
        set { UserDefaults.standard.set(newValue, forKey: "effortByHand") }
    }
}
