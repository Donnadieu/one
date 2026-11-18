import Foundation

/// `--test-model-lineup` (run by preflight): the models behind Smartest, Balanced and Fastest for each AI, and the
/// move off a model its maker retired. Pure: no engine, no network. The ids were checked against each maker's own
/// docs and model list on Nov 18 2026 (ModelLineup.swift says where).
enum ModelLineupCheck {
    static func launch() -> Bool {
        guard CommandLine.arguments.contains("--test-model-lineup") else { return false }
        TestWorld.enter()
        Task { @MainActor in exit(run()) }
        return true
    }

    @MainActor static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ pass: Bool) {
            print("\(pass ? "✓" : "✗") \(name)")
            if !pass { failures += 1 }
        }
        func ids(_ p: Provider) -> [String] { p.tiers.map(\.1) }

        print("the three brains: the newest best model is Smartest")
        check("Claude: Fable 5.2, Sonnet 5.5, Haiku 5.5", ids(.claude) == ["claude-fable-5-2", "claude-sonnet-5-5", "claude-haiku-5-5"])
        check("ChatGPT: GPT-6.2 Astra, GPT-6.2 Sol, GPT-6 Luna", ids(.chatgpt) == ["gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna"])
        check("Grok: 4.7, 4.6, 4.20 non-reasoning", ids(.grok) == ["grok-4.7", "grok-4.6", "grok-4.20-0309-non-reasoning"])
        check(
            "OpenRouter: Fable 5.2, Sonnet 5.5, Gemini 3.8 Flash",
            ids(.openrouter) == ["anthropic/claude-fable-5.2", "anthropic/claude-sonnet-5.5", "google/gemini-3.8-flash"])
        check("the pills keep their plain names", Provider.allCases.allSatisfy { $0.tiers.map(\.0) == ["Smartest", "Balanced", "Fastest"] })
        check("a new Claude starts on Balanced (Sonnet 5.5)", Provider.claude.defaultModel == "claude-sonnet-5-5")
        check(
            "a new ChatGPT starts on GPT-6.2 Sol, then 6.1 Sol, then Luna",
            Provider.chatgpt.models.prefix(3) == ["gpt-6.2-sol", "gpt-6.1-sol", "gpt-6-luna"])
        check("a new Grok starts on 4.6", Provider.grok.defaultModel == "grok-4.6")

        print("no brain is a retired model")
        for p in Provider.allCases {
            let all = p.tiers.map(\.1) + p.models
            check("\(p.title): no pill or first-try model is retired", all.allSatisfy { ModelLineup.replacement($0, provider: p.hermesID) == nil })
        }
        check("ChatGPT's old Fastest (gpt-5.4-mini) is gone: ChatGPT sign-in refuses it", !ids(.chatgpt).contains("gpt-5.4-mini"))

        print("a saved choice its maker retired moves to the maker's own replacement")
        let a = "anthropic"
        check(
            "Sonnet 4.5 (retires Nov 30 2026) → Sonnet 5.5", ModelLineup.replacement("claude-sonnet-4-5-20250929", provider: a) == "claude-sonnet-5-5"
        )
        check("Sonnet 4 → Sonnet 5.5", ModelLineup.replacement("claude-sonnet-4-20250514", provider: a) == "claude-sonnet-5-5")
        check("Opus 4 → Opus 4.8", ModelLineup.replacement("claude-opus-4-20250514", provider: a) == "claude-opus-4-8")
        check("Opus 4.1 → Opus 4.8", ModelLineup.replacement("claude-opus-4-1-20250805", provider: a) == "claude-opus-4-8")
        check("Haiku 3.5 → Haiku 4.5", ModelLineup.replacement("claude-3-5-haiku-20241022", provider: a) == "claude-haiku-4-5-20251001")
        check("gpt-5.4-mini → gpt-6-luna", ModelLineup.replacement("gpt-5.4-mini", provider: "openai-codex") == "gpt-6-luna")
        check("gpt-5.4 → gpt-6-sol", ModelLineup.replacement("gpt-5.4", provider: "openai-codex") == "gpt-6-sol")
        check("gpt-5.5 → gpt-6.1-sol", ModelLineup.replacement("gpt-5.5", provider: "openai-codex") == "gpt-6.1-sol")
        check("grok-code-fast-1 → grok-build-0.1", ModelLineup.replacement("grok-code-fast-1", provider: "xai-oauth") == "grok-build-0.1")
        check("grok-4-0709 → grok-4.3", ModelLineup.replacement("grok-4-0709", provider: "xai-oauth") == "grok-4.3")
        check(
            "OpenRouter's dropped Claude Sonnet 4 → Sonnet 5.5",
            ModelLineup.replacement("anthropic/claude-sonnet-4", provider: "openrouter") == "anthropic/claude-sonnet-5.5")
        check("a model still offered stays put (Opus 5.5)", ModelLineup.replacement("claude-opus-5-5", provider: a) == nil)
        check("an older model still offered stays put (Sonnet 5)", ModelLineup.replacement("claude-sonnet-5", provider: a) == nil)
        check("another AI's ids are never touched", ModelLineup.replacement("gpt-5.4-mini", provider: "openai-api") == nil)
        check("an unknown model stays put", ModelLineup.replacement("my-local-model", provider: "custom") == nil)
        check("ids match whatever the case", ModelLineup.replacement("Claude-Sonnet-4-20250514", provider: a) == "claude-sonnet-5-5")
        let ends = ModelLineup.replacements.flatMap { pid, map in map.values.map { (pid, $0) } }
        check("every replacement is itself current (no chains, no loops)", ends.allSatisfy { ModelLineup.replacement($0.1, provider: $0.0) == nil })

        print("someone still on an earlier pill keeps that pill's meaning")
        check("Opus 5.5 was Smartest", ModelLineup.tier(of: "claude-opus-5-5", provider: .claude) == 0)
        check("Sonnet 5 was Balanced", ModelLineup.tier(of: "claude-sonnet-5", provider: .claude) == 1)
        check("Fable 5.2 is Smartest now", ModelLineup.tier(of: "claude-fable-5-2", provider: .claude) == 0)
        check("GPT-6.1 Sol was ChatGPT's Smartest", ModelLineup.tier(of: "gpt-6.1-sol", provider: .chatgpt) == 0)
        check("a model that never held a pill has none", ModelLineup.tier(of: "claude-opus-4-8", provider: .claude) == nil)
        check(
            "a light job steps down from the new Smartest",
            Router.model(JobRoute(tier: 1), provider: .claude, current: "claude-fable-5-2") == "claude-sonnet-5-5")
        check("and from the old Smartest too", Router.model(JobRoute(tier: 1), provider: .claude, current: "claude-opus-5-5") == "claude-sonnet-5-5")
        check("never from the old Balanced", Router.model(JobRoute(tier: 1), provider: .claude, current: "claude-sonnet-5") == nil)

        print("routines that pin a retired model")
        let jobs = """
            {"jobs": [
              {"id": "a1", "model": "claude-sonnet-4-5-20250929", "provider": "anthropic"},
              {"id": "a2", "model": "claude-sonnet-5", "provider": "anthropic"},
              {"id": "a3"},
              {"id": "a4", "model": "gpt-5.4-mini"},
              {"id": "a5", "model": "gpt-5.4-mini", "provider": "openai-api"}
            ]}
            """
        let up = ModelLineup.pinnedUpgrades(Data(jobs.utf8), provider: "openai-codex")
        check(
            "only the retired pins move, each to its replacement",
            up.map(\.id) == ["a1", "a4"] && up.map(\.model) == ["claude-sonnet-5-5", "gpt-6-luna"])
        check("a broken jobs file moves nothing", ModelLineup.pinnedUpgrades(Data("nope".utf8), provider: a).isEmpty)

        print("thinking levels the new models really have (the engine's answer, Nov 18 2026)")
        let fable: [Effort] = [.low, .medium, .high, .xhigh, .max]
        let sonnet55: [Effort] = [.off, .low, .medium, .high, .xhigh, .max]
        let astra: [Effort] = [.off, .low, .medium, .high, .xhigh]
        check("Fable 5.2 as Smartest thinks at Max", Effort.preset(tier: 0, levels: fable) == .max)
        check("Sonnet 5.5 as Balanced thinks at Medium", Effort.preset(tier: 1, levels: sonnet55) == .medium)
        check("Haiku 5.5 as Fastest thinks at Low", Effort.preset(tier: 2, levels: sonnet55) == .low)
        check("GPT-6.2 Astra as Smartest thinks at Extra high", Effort.preset(tier: 0, levels: astra) == .xhigh)
        check("Grok 4.7 has no level the engine sends yet: nothing is written", Effort.preset(tier: 0, levels: []) == nil)

        print(failures == 0 ? "model lineup ok" : "model lineup: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
