import Foundation

// MARK: - Smart routing
// Before a helper starts (and before each main-chat turn) a small step decides, on this Mac, in a few milliseconds:
// which recipes (skills) fit the job, which room it belongs to, whether it will need their yes, and which brain to use.
// No model call, no service: words in the job matched against each recipe's name and description, plus what worked
// for similar jobs before (RoutingMemory.swift). The helper then starts with the fitting recipes already in hand.
// Unsure or not ready: nothing is added, and the job runs exactly as before. The person never sees any of it, except
// one plain line inside the helper's own steps.

/// One recipe the engine can load: what the router matches against.
struct RouteSkill: Sendable {
    var name: String
    var desc: String
    var path: String
    var size: Int
    var terms: [String: Int]
    var length: Int
}

/// What the router decided for one job.
struct Route: Sendable {
    var ranked: [(name: String, score: Double)] = []
    var preload: [String] = []
    var room: String?  // "personal", "work", "cofounder"; nil = no claim (today's behaviour)
    var needsYes = false
    var tier = 0  // 0 = their own pick / strongest, 1 = balanced
    var ms = 0.0
}

/// The words of a text, the same way for jobs and recipes: lowercased, common words out, simple endings off.
enum RouteWords {
    static let stop: Set<String> = Set(
        ("a an the for of to and my on in with up is it this that be at by or as from are was were will would can could should do does "
            + "did done not no yes you your i me we our he his she her they them their its into out about if then than so but all any some "
            + "each every one two three new run use using via get make sure just only also more most very what when where which who how why "
            + "there here have has had been being too own same other omar elias helper helpers job jobs don ve ll re let lets please now "
            + "today tomorrow week oct 2026 mac app").split(separator: " ").map(String.init))

    static func stem(_ w: String) -> String {
        for suf in ["ing", "ed", "es", "s"] where w.count > 4 && w.hasSuffix(suf) { return String(w.dropLast(suf.count)) }
        return w
    }
    static func of(_ text: String) -> [String] {
        text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
            .filter { $0.count > 1 && !stop.contains($0) }.map(stem)
    }
    static func counts(_ words: [String]) -> [String: Int] { words.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
}

/// The recipe book, read once in the background and kept in memory. BM25 over name (×3), description (×2) and headings.
struct RouteIndex: Sendable {
    var skills: [RouteSkill] = []
    var idf: [String: Double] = [:]
    var avgLength = 1.0

    /// Every SKILL.md under the engine's skills folder (dot folders skipped) and the private rooms' learned recipes.
    static func build(dirs: [URL]) -> RouteIndex {
        var out: [RouteSkill] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in dirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let u as URL in e where u.lastPathComponent == "SKILL.md" {
                guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                let s = parse(t, path: u.path)
                if seen.insert(s.name).inserted { out.append(s) }
            }
        }
        return RouteIndex(skills: out)
    }

    static func parse(_ text: String, path: String) -> RouteSkill {
        var name = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        var desc = ""
        var body = Substring(text)
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            for l in text[text.startIndex..<end.lowerBound].split(separator: "\n") {
                let t = l.trimmingCharacters(in: .whitespaces)
                func value(_ k: String) -> String {
                    String(t.dropFirst(k.count)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
                if t.hasPrefix("name:") { name = value("name:") }
                if t.hasPrefix("description:") { desc = value("description:") }
            }
            body = text[end.upperBound...]
        }
        let heads = body.split(separator: "\n").filter { $0.hasPrefix("#") }.map { $0.drop { $0 == "#" || $0 == " " } }
            .joined(separator: " ").prefix(600)
        let nameWords = RouteWords.of(name.replacingOccurrences(of: "-", with: " "))
        let words = nameWords + nameWords + nameWords + RouteWords.of(desc) + RouteWords.of(desc) + RouteWords.of(String(heads))
        return RouteSkill(name: name, desc: desc, path: path, size: text.utf8.count, terms: RouteWords.counts(words), length: max(1, words.count))
    }

    init(skills: [RouteSkill] = []) {
        self.skills = skills
        guard !skills.isEmpty else { return }
        var df: [String: Int] = [:]
        for s in skills { for w in s.terms.keys { df[w, default: 0] += 1 } }
        let n = Double(skills.count)
        idf = df.mapValues { log(1 + (n - Double($0) + 0.5) / (Double($0) + 0.5)) }
        avgLength = Double(skills.map(\.length).reduce(0, +)) / n
    }

    func bm25(_ query: Set<String>) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in skills {
            var v = 0.0
            for w in query {
                guard let f = s.terms[w].map(Double.init), let i = idf[w] else { continue }
                v += i * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * Double(s.length) / avgLength))
            }
            if v > 0 { out[s.name] = v }
        }
        return out
    }
    func skill(_ name: String) -> RouteSkill? { skills.first { $0.name == name } }
}

enum Router {
    static let keep = 3  // ranked recipes looked at
    static let close = 0.7  // a recipe is loaded up front only if it scores at least this share of the best one
    static let historyWeight = 1.6
    static let budget = 120_000  // bytes of recipes put in front of one helper, at most

    /// Ranks the recipes for a job and picks the ones to load up front. Pure: the index and memory come in.
    static func route(_ text: String, index: RouteIndex, memory: [RouteMemory]) -> Route {
        let t0 = Date()
        var r = Route()
        r.room = room(text)
        r.needsYes = needsYes(text)
        r.tier = tier(text)
        let q = RouteWords.of(text)
        let b = index.bm25(Set(q))
        var score: [String: Double] = [:]
        let top = b.values.max() ?? 1
        for (k, v) in b { score[k, default: 0] += v / top }
        for (k, v) in RouteMemory.vote(RouteWords.counts(q), memory) where index.skill(k) != nil { score[k, default: 0] += historyWeight * v }
        r.ranked = score.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(keep).map { ($0.key, $0.value) }
        if let best = r.ranked.first?.score {
            var bytes = 0
            for (k, v) in r.ranked where v >= close * best {
                let size = index.skill(k)?.size ?? 0
                if bytes + size > budget { continue }
                bytes += size
                r.preload.append(k)
            }
        }
        r.ms = Date().timeIntervalSince(t0) * 1000
        return r
    }

    // MARK: Room, the yes gate, the brain

    static func has(_ t: String, _ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }

    static let roomWords: [(String, String)] = [
        ("work", #"\b(andela|constructease|construct ease|constructis|basecamp|ajax|work ?room|day ?jobs?|my job)\b"#),
        (
            "cofounder",
            #"\b(co-?founder|argo|ek|ek's|erika|intakeedge|forjado ai|p0\d\d|strategy canvas|problem bank|business partner|vibe founding)\b"#
        ),
        ("personal", #"\b(personal room|hestia|my wife|my daughter|family|vacation|trip to|my health|doctor)\b"#),
    ]
    static let oneApp = #"(one mac app|one-assistant|bundle id ai\.forjado\.one|/applications/one\.app|omar's one\b)"#

    /// The room a job clearly belongs to, or nil (no claim). Nyx is never routed into from outside, nor out of.
    static func room(_ text: String) -> String? {
        let t = text.lowercased()
        if has(t, #"\bnyx\b"#) { return nil }
        let hits = roomWords.filter { has(t, $0.1) }.map(\.0)
        guard hits.count == 1, let r = hits.first else { return nil }  // none or several: ask, as today
        // Building One itself touches rooms only by the way: no claim unless the job names the room.
        if has(t, oneApp) && !(r == "cofounder" && has(t, #"(co-?founder room|argo)"#)) { return nil }
        return r
    }

    /// Money, sending, posting or deleting anywhere in the job. Only ever adds a reminder; the rule itself stays on.
    static let yesWords =
        #"\b(buy|buying|purchas\w*|order|pay|pays|paid|paying|payment|charge[sd]?|refund\w*|checkout|book(ing)?|reserv\w*|subscri\w*|transfer|wire|venmo|donat\w*|send|sending|text me|text (him|her|them)|email (him|her|them)|reply|replies|message (him|her|them)|dm|post|posts|posting|tweet\w*|publish\w*|boost\w*|merge|approve|delete|deleting|remove|trash|unsubscribe|cancel|profile (picture|photo)|avatar)\b"#
    /// Not about them: sending a helper, sending something to them, the assistant's own reply.
    static let notYes =
        #"\b(send(ing)?|sent) (out )?(a |an |another |the |more |all |\d+ )?(new )?(helpers?|one)\b|\b(send(ing)?|sent) (it |this )?(to )?(you|me)\b|\b(your|final|short|my|in the|a) repl(y|ies)\b"#
    static func needsYes(_ text: String) -> Bool {
        has(text.lowercased().replacingOccurrences(of: notYes, with: " ", options: .regularExpression), yesWords)
    }

    static let heavy =
        #"\b(build|ship|release|fix|bug|code|repo|swift|feature|design|write|draft|plan|spec|refactor|debug|pr|pull request|ci|deploy)\w*"#
    static let light = #"\b(status|what time|showtimes?|weather|look ?up|find|check|list|how many|which version|what version|summar\w*|recap)\b"#
    /// 1 (the balanced brain) only for a short lookup or status job with nothing to build or write.
    static func tier(_ text: String) -> Int {
        let t = text.lowercased()
        if has(t, heavy) { return 0 }
        return has(t, light) && t.count < 400 ? 1 : 0
    }

    /// The model for a helper's job, or nil to keep their own pick. Steps down to Balanced only from Smartest, for
    /// light jobs; never picks a model on a pay-per-use account (that would spend their money without a yes).
    static func model(_ r: Route, provider: Provider, current: String) -> String? {
        let t = provider.tiers
        guard r.tier == 1, provider != .openrouter, t.count > 1, current == t[0].1 else { return nil }
        return t[1].1
    }
}

// MARK: - What goes to the assistant

extension Router {
    static let roomNames = ["personal": "Personal", "work": "Work", "cofounder": "Co-Founder"]

    /// A helper's first prompt: the recipes that fit, already loaded, plus its room. Empty when there's nothing sure to add.
    static func helperNote(_ r: Route, index: RouteIndex) -> String {
        var parts: [String] = []
        var loaded: [(String, String)] = []
        for k in r.preload {
            guard let s = index.skill(k), let body = try? String(contentsOfFile: s.path, encoding: .utf8) else { continue }
            loaded.append((k, body))
        }
        if !loaded.isEmpty {
            parts.append(
                "these skills fit this job and are loaded below, so you don't need skill_view for them: "
                    + loaded.map(\.0).joined(separator: ", ") + ". Skip any that doesn't fit; load others as usual.")
        }
        if let room = r.room, let n = roomNames[room] { parts.append("this job belongs in the \(n) room; follow that room's AGENTS.md") }
        guard !parts.isEmpty else { return "" }
        var out = "\n\n(One app note, not from the user: " + parts.joined(separator: "; ") + ".)"
        for (k, body) in loaded { out += "\n\n<skill name=\"\(k)\">\n\(body)\n</skill>" }
        return out
    }

    /// The main chat: one short line, only when there's something sure to say. Never a recipe name, never Nyx.
    static func mainNote(_ r: Route, inNyx: Bool) -> String {
        var parts: [String] = []
        if !inNyx, let room = r.room, let n = roomNames[room] { parts.append("if this needs a room, it's likely the \(n) room") }
        if r.needsYes { parts.append("this may involve money, sending, posting or deleting: ask for their yes before that step") }
        guard !parts.isEmpty else { return "" }
        return "\n\n(One app note, not from the user: " + parts.joined(separator: "; ") + ".)"
    }

    /// The one plain line in the helper's own steps: what it started from, in words, never a file name.
    static func plainLine(_ r: Route, index: RouteIndex) -> String? {
        guard let k = r.preload.first, let s = index.skill(k) else { return nil }
        var d = s.desc
        if d.lowercased().hasPrefix("use when ") {
            d = String(d.dropFirst(9))
            if let dot = d.firstIndex(of: ".") { d = String(d[..<dot]) }
            return "Started from what I already know about this: " + d.trimmingCharacters(in: .whitespaces) + "."
        }
        return "Started from what I already know about " + Learning.plain(k).lowercased() + "."
    }

    /// `skill_view: one-assistant-dev` / `skill_view: monarch → references/x.md` → the recipe's name.
    static func viewed(_ title: String) -> String? {
        guard title.hasPrefix("skill_view") else { return nil }
        let rest = title.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        let name = rest.prefix { !$0.isWhitespace }
        return name.isEmpty ? nil : String(name)
    }
}
