import Foundation

/// The outcome of adding an Other AI's key, in the words the key step shows.
enum OtherAIResult: Equatable {
    case works(model: String)
    case refused  // "<name> said this key isn't valid."
    case unreachable  // "I couldn't reach <name>."
    case failed(String)  // anything else, already in plain words

    func line(_ name: String) -> String {
        switch self {
        case .works: "It works. I'm using \(name) now."
        case .refused: "\(name) said this key isn't valid."
        case .unreachable: "I couldn't reach \(name). Check this Mac is online, then try again."
        case .failed(let why): why
        }
    }
}

/// What the engine was using before a switch, so a failed one puts every piece back (a local model also set an
/// address and a context size, which an Other AI must not inherit).
struct AIChoiceSnapshot {
    var provider = "", model = "", baseURL: String?, context: String?
    static func take() async -> AIChoiceSnapshot {
        func get(_ k: String) async -> String? {
            let (s, v) = await hermesRun(["config", "get", k])
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return s == 0 && !t.isEmpty ? t : nil
        }
        return AIChoiceSnapshot(
            provider: await get("model.provider") ?? "", model: await get("model.default") ?? "", baseURL: await get("model.base_url"),
            context: await get("model.context_length"))
    }
    func restore() async {
        _ = await hermesRun(["config", "set", "model.provider", provider])
        _ = await hermesRun(["config", "set", "model.default", model])
        for (k, v) in [("model.base_url", baseURL), ("model.context_length", context)] {
            _ = await hermesRun(v.map { ["config", "set", k, $0] } ?? ["config", "unset", k])
        }
    }
}

extension Model {
    /// Other AIs (Switch AI and first-run setup): save the key the engine's way, check it's real, switch, and keep the
    /// old AI unless the new one actually answers. Its thinking starts on Balanced's level for that model.
    func useOtherAI(_ ai: EngineAI, key: String?) async -> OtherAIResult {
        let before = await AIChoiceSnapshot.take()
        guard !before.provider.isEmpty || !onboarded else { return .failed("I couldn't read your current AI, so I didn't change it.") }
        if let key {  // checked before it's kept, so a refused key never lands on this Mac
            switch await AICatalog.check(ai, key: key) {
            case .refused: return .refused
            case .unreachable: return .unreachable
            case .fine, .unknown: break
            }
            guard await AICatalog.saveKey(ai.id, key) else { return .failed("I couldn't keep that key on this Mac.") }
        }
        if helpers.contains(where: SwitchAI.inFlight) || thinking {
            switchWaitMessage = SwitchAI.waitMessage(for: ai.name, helpers: helpers, thinking: thinking)
        }
        while (!onboarded || switchingAI) && !SwitchAI.ready(helpers, thinking: thinking) {
            try? await Task.sleep(for: .seconds(2))
        }
        switchWaitMessage = nil
        guard !onboarded || switchingAI else { return .failed("The switch was cancelled.") }
        var model = ai.model
        if model.isEmpty { model = await AICatalog.models(ai.id).first ?? "" }
        guard !model.isEmpty else { return .failed("\(ai.name) didn't tell me which model to use.") }
        let oldEffort = Effort.current()
        let levels = (await AICatalog.efforts(ai.id, models: [model]))[model] ?? []
        let set: [[String]] = [
            ["config", "set", "model.provider", ai.id], ["config", "set", "model.default", model],
            ["config", "unset", "model.base_url"], ["config", "unset", "model.context_length"],
        ]
        if let e = Effort.preset(tier: 1, levels: levels) { _ = await Effort.save(e) }
        func undo() async {
            await before.restore()
            if let oldEffort { _ = await Effort.save(oldEffort) }
        }
        for a in set {
            let (s, _) = await hermesRun(a)
            if s != 0 && a[1] == "set" {
                await undo()
                return .failed("I kept your old AI. The new choice couldn't be saved.")
            }
        }
        if let problem = await Engine.shared.start() {
            await undo()
            _ = await Engine.shared.start()
            return .failed("I kept your old AI. " + SignIn.plainReason(problem, provider: ai.name))
        }
        let got = Box("")
        Engine.shared.onText = { got.v += $0 }
        let stop = await Engine.shared.prompt("Reply with exactly one word: ready")
        Engine.shared.onText = nil
        guard SwitchAI.answered(stop: stop, reply: got.v) else {
            await undo()
            _ = await Engine.shared.start()
            let why = stop.hasPrefix("error") ? SignIn.plainReason(String(stop.dropFirst(7)), provider: ai.name) : "It didn't give a usable answer."
            return .failed("I kept your old AI. " + why)
        }
        Effort.byHand = false
        providerRaw = ai.id
        if onboarded {
            step = .done  // Switch AI stays open on "It works" until they tap Done
        } else {
            step = .nameAssistant
            await say("It works. Now, what would you like to call me? You can rename me any time.", voice: "nameAssistant")
        }
        return .works(model: model)
    }
}
