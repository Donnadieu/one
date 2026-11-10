import Foundation

/// Other AIs and thinking levels (docs/design-docs/ai-picker-extras.md). `--test-other-ais`: no engine, no network.
/// `--test-other-ais-engine`: the real engine in ONE_SUPPORT_DIR (fresh-install workflow): its list, a key saved its
/// way, the levels it sends, and the level a new chat, helper and routine get.
enum OtherAIsCheck {
    static func launch() -> Bool {
        let args = CommandLine.arguments
        let engine = args.contains("--test-other-ais-engine")
        guard engine || args.contains("--test-other-ais") else { return false }
        TestWorld.enter()
        Task { @MainActor in exit(engine ? await runEngine() : await run()) }
        return true
    }

    static var failures = 0
    static func check(_ name: String, _ pass: Bool) {
        print("\(pass ? "✓" : "✗") \(name)")
        if !pass { failures += 1 }
    }

    static func row(_ id: String, auth: String = "api_key", keys: [String] = ["K"], base: Bool = true, local: Bool = false) -> EngineAI {
        EngineAI(
            id: id, name: id, about: "", auth_type: auth, key_vars: keys, base_url: base ? "https://x.invalid/v1" : "", api_mode: "",
            model: "m", key_page: "", check_url: "https://x.invalid/v1/models", check_auth: "bearer", needs_base_url: !base, local: local,
            has_key: false)
    }

    @MainActor static func run() async -> Int32 {
        // The list: the engine's rows, minus what One already has and what a key alone can't set up.
        let all = [
            row("anthropic"), row("openrouter"), row("custom", base: false), row("openai-codex", auth: "oauth_external", keys: []),
            row("copilot"), row("azure-foundry", base: false), row("lmstudio", local: true), row("nous", auth: "oauth_device_code"),
            row("deepseek"), row("gemini"), row("brand-new-ai"),
        ]
        let offered = AICatalog.offered(all).map(\.id)
        check("Other AIs keeps only plain-key AIs One doesn't already offer", offered == ["deepseek", "gemini", "brand-new-ai"])
        let groups = AICatalog.grouped(AICatalog.offered(all))
        check("an AI the engine adds later is still shown (under More), never dropped", groups.flatMap(\.1).count == offered.count)
        check("groups come in the design's order", groups.map(\.0) == [.big, .open, .more])
        let out = "warning: something\n{\"schema\": 1, \"providers\": [{\"id\": \"deepseek\"}]}\n"
        check("the engine's own warnings before its answer are skipped", AICatalog.parse(out)?["schema"] as? Int == 1)
        check("a broken answer is an empty list, not a crash", AICatalog.decode(AICatalog.parse("{\"providers\": 3}")).isEmpty)

        // Presets: Smartest = the model's top, Balanced = Medium, Fastest = Low, stepped down, never up, never Off.
        let opus: [Effort] = [.low, .medium, .high, .xhigh, .max]
        let mini: [Effort] = [.none, .low, .medium, .high, .xhigh]
        let k3: [Effort] = [.none, .low, .high, .max]
        func p(_ l: [Effort]) -> [Effort?] { (0..<3).map { Effort.preset(tier: $0, levels: l) } }
        check("Claude Opus: Max, Medium, Low", p(opus) == [.max, .medium, .low])
        check("ChatGPT gpt-5.4-mini (no Max): Extra high, Medium, Low", p(mini) == [.xhigh, .medium, .low])
        check("Grok 4.6: its top is Extra high", Effort.preset(tier: 0, levels: [.low, .medium, .high, .xhigh]) == .xhigh)
        check("Kimi K3 (no Medium): Balanced steps down to Low, never up to High", p(k3) == [.max, .low, .low])
        check("no levels (Grok 4.20, local): nothing is written", p([]) == [nil, nil, nil])
        check("Off alone is never picked for a pill", Effort.preset(tier: 2, levels: [.none]) == nil)
        check("only One's six levels are shown (minimal, ultra dropped)", Effort.list(["minimal", "low", "ultra", "max", "x"]) == [.low, .max])
        check("levels show in order, whatever order the engine sent", Effort.list(["max", "low", "none"]) == [.none, .low, .max])
        check("the pill line names the top level", Effort.pillLine(.max, levels: opus) == "thinks hardest")
        check("a model with none says so", Effort.pillLine(nil, levels: []) == "no thinking levels")

        // Reading the level back: only agent.reasoning_effort, never a side task's or a comment.
        let cfg = """
            model:
              default: x
            auxiliary:
              vision:
                reasoning_effort: none
            agent:
              # reasoning_effort: low
              verbose: false
              reasoning_effort: "high"
            delegation:
              reasoning_effort: low
            """
        check("the card reads the level every chat uses", Effort.current(cfg) == .high)
        check("unset reads as unset", Effort.current("agent:\n  verbose: false\n") == nil)
        check("off reads as Off", Effort.current("agent:\n  reasoning_effort: none\n") == .none)

        // Is the key real? The AI's own model list, the way the engine's doctor asks.
        var ai = row("deepseek")
        let bearer = AICatalog.checkRequest(ai, key: "abc")
        check("a key is sent as the AI expects (bearer)", bearer?.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        ai.check_auth = "x-api-key"
        check("Anthropic-style AIs get x-api-key", AICatalog.checkRequest(ai, key: "abc")?.value(forHTTPHeaderField: "x-api-key") == "abc")
        ai.check_auth = "query"
        check("Google gets it in the address", AICatalog.checkRequest(ai, key: "abc")?.url?.query == "key=abc")
        ai.check_url = ""
        check("an AI with no free check skips it (the ready test still decides)", AICatalog.checkRequest(ai, key: "abc") == nil)
        check("401/403 = refused", AICatalog.verdict(status: 401) == .refused && AICatalog.verdict(status: 403) == .refused)
        check("200 and 429 = the key is real", AICatalog.verdict(status: 200) == .fine && AICatalog.verdict(status: 429) == .fine)
        check("no answer = couldn't reach", AICatalog.verdict(status: nil) == .unreachable)
        check("anything else = let the ready test decide", AICatalog.verdict(status: 500) == .unknown)
        for (status, want) in [(200, AICatalog.KeyCheck.fine), (401, .refused)] {
            StubAI.status = status
            let got = await AICatalog.check(row("deepseek"), key: "abc", session: StubAI.session)
            check("a stand-in AI answering \(status) gives \(want)", got == want)
        }
        StubAI.status = nil
        let off = await AICatalog.check(row("deepseek"), key: "abc", session: StubAI.session)
        check("a stand-in AI that's offline gives couldn't reach", off == .unreachable)
        check("the failure line names the AI and the cause", OtherAIResult.refused.line("DeepSeek") == "DeepSeek said this key isn't valid.")
        check("a key with a line break is refused before it reaches the engine", await AICatalog.saveKey("deepseek", "a\nb") == false)

        print(failures == 0 ? "other ais ok" : "other ais: \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    /// The real engine, in a throwaway One folder (fresh-install job). Nothing here pays for a model call.
    @MainActor static func runEngine() async -> Int32 {
        let all = await AICatalog.providers()
        check("the engine's own list loads (\(all.count) AIs)", all.count >= 30)
        let offered = AICatalog.offered(all)
        check(
            "Other AIs has \(offered.count) of them, none One already offers",
            offered.count >= 20 && !offered.contains { AICatalog.builtIn.contains($0.id) })
        check("every offered AI names its key and a model or a model list", offered.allSatisfy { !$0.key_vars.isEmpty && !$0.name.isEmpty })
        let fake = "sk-one-test-\(UUID().uuidString.prefix(8))"
        let (_, before) = await hermesRun(["auth", "status", "deepseek"])
        check("DeepSeek starts with no key", before.contains("logged out"))
        let saved = await AICatalog.saveKey("deepseek", fake)
        check("a key is saved the engine's way", saved)
        let env = Env.hermesHome.appendingPathComponent(".env")
        let text = (try? String(contentsOf: env, encoding: .utf8)) ?? ""
        let mode = (try? FileManager.default.attributesOfItem(atPath: env.path)[.posixPermissions] as? Int) ?? 0
        check("it lands in the engine's .env under its own name, readable only by this user", text.contains("DEEPSEEK_API_KEY=") && mode == 0o600)
        let (_, after) = await hermesRun(["auth", "status", "deepseek"])
        check("the engine now counts DeepSeek as signed in", after.contains("logged in"))
        check("the list shows it as Key added", (await AICatalog.providers()).first { $0.id == "deepseek" }?.has_key == true)
        let shown = (await AICatalog.run(["providers"])).map { "\($0)" } ?? ""
        check("the key itself never comes back out", !shown.contains(fake))

        let claude = await AICatalog.efforts("anthropic", models: ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-5-5"])
        check("Claude Opus offers Low to Max, no Off", claude["claude-opus-5-5"] == [.low, .medium, .high, .xhigh, .max])
        let grok = await AICatalog.efforts("xai-oauth", models: ["grok-4.6", "grok-4.20-0309-non-reasoning"])
        check("Grok 4.6 tops out at Extra high", grok["grok-4.6"]?.last == .xhigh)
        check("Grok 4.20 non-reasoning has no levels", grok["grok-4.20-0309-non-reasoning"] == [])
        let gpt = await AICatalog.efforts("openai-codex", models: ["gpt-5.4-mini", "gpt-6.1-sol"])
        check("gpt-5.4-mini has no Max", gpt["gpt-5.4-mini"]?.contains(.max) == false && gpt["gpt-5.4-mini"]?.isEmpty == false)
        check("gpt-6.1-sol has no Off", gpt["gpt-6.1-sol"]?.contains(.none) == false && gpt["gpt-6.1-sol"]?.contains(.max) == true)

        for (tier, want) in [(0, Effort.max), (1, .medium), (2, .low)] {
            let e = Effort.preset(tier: tier, levels: claude["claude-opus-5-5"] ?? [])
            let ok = await Effort.save(e ?? .medium)
            let r = await AICatalog.run(["resolved", "claude-sonnet-5", "{\"id\": \"one-check\"}"])
            check(
                "pill \(tier) writes \(want.word): a new chat or helper gets it, and so does a routine",
                ok && e == want && r?["chat"] as? String == want.rawValue && r?["routine"] as? String == want.rawValue)
        }
        let pinned = await AICatalog.run(["resolved", "claude-sonnet-5", "{\"id\": \"p\", \"reasoning_effort\": \"high\"}"])
        check("a routine that sets its own level keeps it", pinned?["routine"] as? String == "high")
        print(failures == 0 ? "other ais engine ok" : "other ais engine: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

/// A stand-in AI for the key check: answers every request with `status`, or fails like an offline Mac when nil.
final class StubAI: URLProtocol {
    nonisolated(unsafe) static var status: Int?
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubAI.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let s = StubAI.status, let u = request.url, let r = HTTPURLResponse(url: u, statusCode: s, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
