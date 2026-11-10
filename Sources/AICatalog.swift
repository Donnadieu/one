import Foundation

/// One AI the engine offers, as its own `provider_catalog()` describes it (tools/overlay/tools/one_ai_catalog.py).
struct EngineAI: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var about: String
    var auth_type: String
    var key_vars: [String]
    var base_url: String
    var api_mode: String
    var model: String
    var key_page: String
    var check_url: String
    var check_auth: String
    var needs_base_url: Bool
    var local: Bool
    var has_key: Bool
}

/// The engine's own lists, read through a small script One copies into the engine (like one_my_chrome.py). Nothing
/// here keeps a list of AIs: the names, key variables, key pages, model and thinking levels all come from the engine.
enum AICatalog {
    static let script = "one_ai_catalog"

    /// The engine ids One already offers with their own rows (Claude, ChatGPT, Grok, OpenRouter) and Local model.
    static var builtIn: Set<String> { Set(Provider.allCases.map(\.hermesID) + ["custom", "anthropic"]) }

    /// "Other AIs": every AI that takes a plain key and nothing else. Left out: the five One already has, any that
    /// also needs its own address (Azure), a server on this Mac (Local model covers those), GitHub Copilot (a GitHub
    /// sign-in, not a key) and sign-in-only ones (Nous Portal, Qwen, MiniMax OAuth, Bedrock, Vertex: a later step).
    static func offered(_ all: [EngineAI]) -> [EngineAI] {
        all.filter {
            $0.auth_type == "api_key" && !$0.key_vars.isEmpty && !$0.needs_base_url && !$0.local && !builtIn.contains($0.id)
                && $0.id != "copilot"
        }
    }

    /// Direction B's groups. The engine doesn't group its list, so this is the one hand-kept part, by engine id; an
    /// AI the engine adds later lands under "More" until it's placed. Never a reason to hide one.
    enum Group: String, CaseIterable {
        case big = "Big AI companies"
        case open = "Open models"
        case many = "One key, many AIs"
        case more = "More"
    }
    static let groups: [String: Group] = [
        "openai-api": .big, "gemini": .big, "xai": .big, "meta-ai": .big,
        "deepseek": .open, "kimi-coding": .open, "kimi-coding-cn": .open, "zai": .open, "minimax": .open, "minimax-cn": .open,
        "alibaba": .open, "alibaba-cn": .open, "alibaba-coding-plan": .open, "alibaba-coding-plan-cn": .open,
        "alibaba-token-plan": .open, "alibaba-token-plan-cn": .open, "arcee": .open, "stepfun": .open, "xiaomi": .open,
        "upstage": .open, "tencent-tokenhub": .open, "tencent-tokenplan": .open,
        "ai-gateway": .many, "huggingface": .many, "nvidia": .many, "fireworks": .many, "deepinfra": .many, "novita": .many,
        "gmi": .many, "nebius-token-factory": .many, "router": .many, "kilocode": .many, "opencode-zen": .many,
        "opencode-go": .many, "commandcode": .many, "commandcode-anthropic": .many, "ollama-cloud": .many, "actual": .many,
    ]
    static func grouped(_ ais: [EngineAI]) -> [(Group, [EngineAI])] {
        Group.allCases.compactMap { g in
            let rows = ais.filter { (groups[$0.id] ?? .more) == g }
            return rows.isEmpty ? nil : (g, rows)
        }
    }

    // MARK: - Calls into the engine

    /// Copies the script into the engine (it may be replaced by an engine update) and runs it. The last `{…}` line is
    /// the answer; the engine's own warnings come before it.
    static func run(_ args: [String], input: String? = nil, timeout: TimeInterval = 60) async -> [String: Any]? {
        guard let src = Bundle.main.url(forResource: script, withExtension: "py") else { return nil }
        let dst = Env.engineDir.appendingPathComponent("tools/\(script).py")
        if (try? Data(contentsOf: dst)) != (try? Data(contentsOf: src)) {
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        let (_, out) = await hermesRun(["--run-module", "tools.\(script)"] + args, timeout: timeout, input: input)
        return parse(out)
    }
    static func parse(_ out: String) -> [String: Any]? {
        guard let line = out.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("{") }) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
    static func decode(_ j: [String: Any]?) -> [EngineAI] {
        // isValidJSONObject first: data(withJSONObject:) on a bare number raises an Objective-C exception, which AppKit
        // swallows on the main thread, so the caller just never returns.
        guard let rows = j?["providers"] as? [Any], JSONSerialization.isValidJSONObject(rows),
            let d = try? JSONSerialization.data(withJSONObject: rows)
        else { return [] }
        return (try? JSONDecoder().decode([EngineAI].self, from: d)) ?? []
    }

    /// A first run after an install or update can take a while (the engine warms up), so it gets two minutes and one retry.
    static func providers() async -> [EngineAI] {
        let first = decode(await run(["providers"], timeout: 120))
        return first.isEmpty ? decode(await run(["providers"], timeout: 120)) : first
    }

    /// The engine's model list for one AI (its live list once a key is in, else its own).
    static func models(_ id: String) async -> [String] {
        (await run(["models", id], timeout: 30))?["models"] as? [String] ?? []
    }

    /// The thinking levels the engine really sends for each model (it builds the request for every level and looks).
    static func efforts(_ id: String, models: [String]) async -> [String: [Effort]] {
        guard !models.isEmpty, let levels = (await run(["efforts", id] + models))?["levels"] as? [String: [String]] else { return [:] }
        return levels.mapValues(Effort.list)
    }

    /// Saves the key the way the engine's own screens do (`.env`, owner-only, plus its credential pool). The key goes
    /// in on stdin and never comes back out.
    static func saveKey(_ id: String, _ key: String) async -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !k.contains("\n") else { return false }
        return (await run(["save-key", id], input: k))?["ok"] as? Bool == true
    }

    // MARK: - Is the key real? (free: the AI's own model list, as the engine's `hermes doctor` checks it)

    enum KeyCheck: Equatable { case fine, refused, unreachable, unknown }

    static func checkRequest(_ ai: EngineAI, key: String) -> URLRequest? {
        guard var c = URLComponents(string: ai.check_url), !ai.check_url.isEmpty else { return nil }
        if ai.check_auth == "query" { c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "key", value: key)] }
        guard let u = c.url else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 15)
        switch ai.check_auth {
        case "x-api-key":
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case "query": break
        default: r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return r
    }
    static func verdict(status: Int?) -> KeyCheck {
        guard let status else { return .unreachable }
        if status == 401 || status == 403 { return .refused }
        if (200..<300).contains(status) || status == 429 { return .fine }
        return .unknown
    }
    /// `fetch` answers a request with its HTTP status (nil = no answer); tests pass a stand-in.
    static func check(_ ai: EngineAI, key: String, fetch: ((URLRequest) async -> Int?)? = nil) async -> KeyCheck {
        guard let r = checkRequest(ai, key: key) else { return .unknown }
        if let fetch { return verdict(status: await fetch(r)) }
        let got = try? await URLSession.shared.data(for: r)
        return verdict(status: got.flatMap { ($0.1 as? HTTPURLResponse)?.statusCode })
    }
}
