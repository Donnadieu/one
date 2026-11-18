import Foundation

/// Which models stand behind each AI's Smartest, Balanced and Fastest (`Provider.tiers`), and the move off a model
/// its maker retired, so nobody's saved choice breaks. Every id here was checked on Nov 18 2026 against the maker's
/// own docs and model list: Anthropic's models overview, model deprecations page and GET /v1/models; ChatGPT's Codex
/// model list (the account's own) and learn.chatgpt.com/docs/models; docs.x.ai models + the May 15 2026 retirement
/// guide; OpenRouter's /api/v1/models. Never add an id from memory: a wrong one fails every chat on that AI.
enum ModelLineup {
    /// Retired or retiring ids, by engine provider id, and the replacement the maker itself names. Keys are lowercase.
    static let replacements: [String: [String: String]] = [
        "anthropic": [
            "claude-sonnet-4-5-20250929": "claude-sonnet-5-5",  // deprecated Sep 30 2026, retires Nov 30 2026
            "claude-sonnet-4-20250514": "claude-sonnet-5-5",
            "claude-opus-4-20250514": "claude-opus-4-8",
            "claude-opus-4-1-20250805": "claude-opus-4-8",
            "claude-3-7-sonnet-20250219": "claude-sonnet-5-5",
            "claude-3-5-sonnet-20241022": "claude-sonnet-5-5",
            "claude-3-5-sonnet-20240620": "claude-sonnet-5-5",
            "claude-3-5-haiku-20241022": "claude-haiku-4-5-20251001",
            "claude-3-haiku-20240307": "claude-haiku-4-5-20251001",
            "claude-3-opus-20240229": "claude-opus-4-8",
        ],
        // Retired from Codex with ChatGPT sign-in (gpt-5.4 + mini Aug 31 2026, gpt-5.5 Oct 14 2026); the API keeps them.
        "openai-codex": ["gpt-5.4": "gpt-6-sol", "gpt-5.4-mini": "gpt-6-luna", "gpt-5.5": "gpt-6.1-sol"],
        "xai-oauth": xaiRetired,
        "xai": xaiRetired,
        // Gone from OpenRouter's list; each goes where its maker sends it.
        "openrouter": [
            "anthropic/claude-sonnet-4": "anthropic/claude-sonnet-5.5",
            "anthropic/claude-opus-4": "anthropic/claude-opus-4.8",
            "anthropic/claude-3.7-sonnet": "anthropic/claude-sonnet-5.5",
            "anthropic/claude-3.5-haiku": "anthropic/claude-haiku-4.5",
            "x-ai/grok-4": "x-ai/grok-4.3",
            "x-ai/grok-code-fast-1": "x-ai/grok-build-0.1",
        ],
    ]
    /// xAI retired these on May 15 2026 and serves them as grok-4.3 (grok-code-fast-1 as grok-build-0.1).
    static let xaiRetired: [String: String] = [
        "grok-4-0709": "grok-4.3", "grok-4-1-fast-reasoning": "grok-4.3", "grok-4-1-fast-non-reasoning": "grok-4.3",
        "grok-4-fast-reasoning": "grok-4.3", "grok-4-fast-non-reasoning": "grok-4.3", "grok-3": "grok-4.3",
        "grok-code-fast-1": "grok-build-0.1",
    ]

    /// The replacement for a saved model the maker retired, or nil when the model is still offered.
    static func replacement(_ model: String, provider: String) -> String? {
        replacements[provider]?[model.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The models that held each pill before this lineup (index 0 Smartest, 1 Balanced, 2 Fastest). Someone still on
    /// one keeps that pill's meaning (a light helper job still steps down from an old Smartest) without being moved.
    static let earlierTiers: [Provider: [[String]]] = [
        .claude: [["claude-opus-5-5"], ["claude-sonnet-5"], []],
        .chatgpt: [["gpt-6.1-sol"], ["gpt-6-sol"], ["gpt-5.4-mini"]],
        .grok: [[], ["grok-4.20-0309-reasoning"], []],
        .openrouter: [["anthropic/claude-opus-5.5"], [], ["google/gemini-3-flash-preview"]],
    ]

    /// Which pill a model stands for (0 Smartest, 1 Balanced, 2 Fastest), now or before; nil when it never held one.
    static func tier(of model: String, provider: Provider) -> Int? {
        if let i = provider.tiers.firstIndex(where: { $0.1 == model }) { return i }
        return earlierTiers[provider]?.firstIndex { $0.contains(model) }
    }

    /// Routines that pin a retired model, with the replacement each moves to. A pin without its own provider is on
    /// the person's main AI (`provider`).
    static func pinnedUpgrades(_ jobs: Data, provider: String) -> [(id: String, model: String)] {
        guard let j = try? JSONSerialization.jsonObject(with: jobs) else { return [] }
        let rows = ((j as? [String: Any])?["jobs"] as? [[String: Any]]) ?? (j as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let m = r["model"] as? String, !m.isEmpty else { return nil }
            let p = (r["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? provider
            return replacement(m, provider: p).map { (id, $0) }
        }
    }

    /// At launch, before the engine starts: a saved model (or a routine's pinned one) the maker retired moves to its
    /// replacement. Anything still offered is left exactly as the person picked it.
    static func atLaunch(provider raw: String) async {
        let pid = Provider(rawValue: raw)?.hermesID ?? (raw.isEmpty ? Provider.claude.hermesID : raw)
        let saved = MeCard.currentModel()
        if let new = replacement(saved, provider: pid) {
            let (status, _) = await hermesRun(["config", "set", "model.default", new])
            BrowserGuard.log("model lineup: \(saved) is retired, moved to \(new) (\(status == 0 ? "done" : "failed"))")
        }
        guard let jobs = try? Data(contentsOf: Env.hermesHome.appendingPathComponent("cron/jobs.json")) else { return }
        for (id, model) in pinnedUpgrades(jobs, provider: pid) {
            let (status, _) = await hermesRun(["cron", "edit", id, "--model", model], timeout: 60)
            BrowserGuard.log("model lineup: routine \(id) pinned a retired model, moved to \(model) (\(status == 0 ? "done" : "failed"))")
        }
    }
}
