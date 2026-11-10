import AppKit
import SwiftUI

// MARK: - Render-only (`One --render-switch-ai <png> [mode]`, from a test copy): the Switch AI pop-up over the
// home screen, to check it against the old first-run-screen bug (duplicate title, clipped list, blank wait), plus
// Other AIs and the card's thinking levels (docs/design-docs/ai-picker-extras.md, Direction B).
// Modes: picker, waiting, other, other-key, other-checking, other-works, other-fail, card-closed, card-open,
// card-none, card-other.

enum SwitchAIPanelRender {
    static func cli(_ args: [String]) {
        // Not this one: maybe --render-helper-tags (HelperTagsRender.swift).
        guard let k = args.firstIndex(of: "--render-switch-ai"), k + 1 < args.count else { return HelperTagsRender.cli(args) }
        let mode = k + 2 < args.count ? args[k + 2] : "picker"
        MainActor.assumeIsolated { png(args[k + 1], mode: mode) }
        exit(0)
    }

    /// A few rows shaped like the engine's own answer (one_ai_catalog.py `providers`), for stills only.
    static func sample() -> [EngineAI] {
        let rows: [(String, String, Bool)] = [
            ("openai-api", "OpenAI API", false), ("gemini", "Google AI Studio", false), ("xai", "xAI", false),
            ("deepseek", "DeepSeek", true), ("kimi-coding", "Kimi / Kimi Coding Plan", false), ("zai", "Z.AI (GLM)", false),
            ("minimax", "MiniMax", false), ("alibaba", "Qwen Cloud", false), ("arcee", "Arcee AI", false), ("stepfun", "StepFun Step Plan", false),
            ("huggingface", "HuggingFace", false), ("nvidia", "NVIDIA NIM", false), ("ai-gateway", "Vercel AI Gateway", false),
            ("fireworks", "Fireworks AI", false),
        ]
        return rows.map { id, name, key in
            EngineAI(
                id: id, name: name, about: "", auth_type: "api_key", key_vars: ["KEY"], base_url: "https://example.invalid/v1",
                api_mode: "", model: id == "deepseek" ? "deepseek-flash" : "", key_page: "https://example.invalid/keys",
                check_url: "", check_auth: "bearer", needs_base_url: false, local: false, has_key: key)
        }
    }

    @MainActor static func png(_ path: String, mode: String) {
        let scene = HomeRender.scene(3)
        let m = Model.shared
        SwitchAIPanel.renderStill = true
        let list = sample()
        var deepseek = list[3]
        deepseek.has_key = false
        m.switchingAI = true
        switch mode {
        case "waiting":
            m.switchWaitMessage = "Switching to Grok once your 2 helpers finish. They'll stay on their current AI."
        case "other":
            SwitchAIPanel.renderOther = true
            OtherAIsView.still = (list, nil, .idle)
        case "other-key", "other-checking", "other-works", "other-fail":
            SwitchAIPanel.renderOther = true
            let stage: OtherAIKeyView.Stage =
                mode == "other-key"
                ? .idle : mode == "other-checking" ? .checking : mode == "other-works" ? .result(.works(model: "deepseek-flash")) : .result(.refused)
            OtherAIsView.still = (list, deepseek, stage)
        default: break
        }
        if mode.hasPrefix("card") {
            m.switchingAI = false
            cardPNG(path, mode: mode, scene: scene)
            return
        }
        let v = AnyView(
            scene.overlay {
                PopupStage(close: {}, panel: { _ in SwitchAIPanel(m: m) {} })
            }
        )
        HomeRender.png(v, path, height: 760)
    }

    @MainActor static func cardPNG(_ path: String, mode: String, scene: AnyView) {
        let m = Model.shared
        let claude: [String: [Effort]] = [
            "claude-opus-5-5": [.low, .medium, .high, .xhigh, .max], "claude-sonnet-5": [.off, .low, .medium, .high, .xhigh, .max],
            "claude-haiku-5-5": [.off, .low, .medium, .high, .xhigh, .max],
        ]
        switch mode {
        case "card-none":
            m.providerRaw = "grok"
            let grok: [String: [Effort]] = [
                "grok-4.6": [.low, .medium, .high, .xhigh], "grok-4.20-0309-reasoning": [], "grok-4.20-0309-non-reasoning": [],
            ]
            BrainSection.still = ("grok-4.20-0309-non-reasoning", grok, .low, true, false, "")
        case "card-other":
            m.providerRaw = "deepseek"
            BrainSection.still = ("deepseek-flash", ["deepseek-flash": [.off, .low, .medium, .high, .max]], .medium, true, false, "DeepSeek")
        default:
            m.providerRaw = "claude"
            BrainSection.still = ("claude-opus-5-5", claude, .max, mode == "card-open", false, "")
        }
        let v = AnyView(
            scene.overlay {
                PopupStage(close: {}, align: .topLeading, inset: HomePopups.nameInset(top: 6)) { _ in MeCard(m: m) }
            })
        HomeRender.png(v, path, height: mode == "card-closed" ? 760 : 960)
    }
}
