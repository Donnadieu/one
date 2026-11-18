import Foundation

// MARK: - Plain words for each routine (Omar, Nov 17 2026: "Hestia Sunday hub refresh", "Ping: helper-lines bug",
// "Then It Clicked: Short of the day": "that's the kind of thing that a user wouldn't be able to tell you").
// Each routine shows a plain name and one line saying what it does. The assistant's own words win: when it sets up a
// routine it writes them to `routines/labels.json` ({"<job id>": {"name", "line"}}); the engine's job is never renamed.
// Until then they come from the routine itself: a room's AI name comes off (the list groups it under its room),
// "Ping: X" says what it is, "Show: thing" becomes "Thing", and the line is the first plain sentence of its instructions.

struct RoutineLabel: Codable, Equatable {
    var name: String
    var line: String
}

extension Routine {
    var name: String { shownName ?? title }
    var line: String { shownLine ?? what }
    /// Set to check something every few minutes until a job is done, say so once, then stop after so many runs:
    /// it said its one thing and has had nothing to say since. Safe to remove (after a yes).
    var leftover: String? {
        guard state != .finished, state != .paused, let every, every <= 60, times != nil, quiet else { return nil }
        return "Its last runs had nothing to say: what it was watching for is over. It stops by itself after \(times ?? 0) runs."
    }
}

enum RoutineLabels {
    static var file: URL { Env.support.appendingPathComponent("routines/labels.json") }

    /// Every prompt: routines get plain words when they're made (the Routines list shows them).
    static var note: String {
        "\n\n(One app note, not from the user: ROUTINE NAMES. When you set up a routine, give it a plain name a person would "
            + "understand (no code names, no room AI names, no \"Ping:\"), then add its plain name and one line saying what it does to "
            + "\(file.path) as {\"<job id>\": {\"name\": \"…\", \"line\": \"…\"}}, keeping the other entries. That only changes what the "
            + "Routines screen shows; never rename or change the routine itself for it.)"
    }

    static func load() -> [String: RoutineLabel] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: RoutineLabel].self, from: d)) ?? [:]
    }

    /// Plain words, the room and the bot for each routine. `owner` is the person's own name ("you" in the line).
    static func dress(
        _ rs: [Routine], labels: [String: RoutineLabel], rooms: [RoomFacts], bots: [Helper], owner: String? = nil
    ) -> [Routine] {
        let ais = rooms.compactMap(\.ai).filter { !$0.isEmpty }
        return rs.map { r in
            var x = r
            let botOwned = bots.contains { BotStore.owns($0, r) }
            x.room = botOwned || r.outside ? nil : room(r, rooms)
            let l = labels[r.id]
            x.shownName = l.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? plainName(r.title, ais: ais)
            x.shownLine = l.map(\.line).flatMap { $0.isEmpty ? nil : $0 } ?? plainLine(r, owner: owner, ais: ais)
            return x
        }
    }

    /// The one room its name or the start of its instructions names; nil when none or several (the assistant's own).
    static func room(_ r: Routine, _ rooms: [RoomFacts]) -> String? {
        let inTitle = RoomPrivacy.named(in: r.title, facts: rooms)
        if inTitle.count == 1 { return inTitle[0].title }
        if inTitle.count > 1 { return nil }
        // In its instructions only the room's folder as a path ("personal-room/…") or its AI's name count: "the Personal,
        // Work and Co-Founder rooms" is a routine that works across rooms (the assistant's own), not one room's.
        let head = String(r.prompt.prefix(400))
        let inPrompt = rooms.filter { f in
            let folder = NSRegularExpression.escapedPattern(for: f.url.lastPathComponent)
            if head.range(of: "(^|[\\s\"'/(])" + folder + "/", options: .regularExpression) != nil { return true }
            // An AI named like its room ("Nyx") is just the room's name: "personal, work, nyx rooms" names several.
            guard let a = f.ai, a.count >= 3, a.lowercased() != f.title.lowercased(), !f.url.lastPathComponent.lowercased().hasPrefix(a.lowercased())
            else { return false }
            return head.range(of: "\\b" + NSRegularExpression.escapedPattern(for: a) + "\\b", options: .regularExpression) != nil
        }
        return inPrompt.count == 1 ? inPrompt[0].title : nil
    }

    static let tidy: [(String, String)] = [("hub refresh", "notes review"), ("Hub refresh", "Notes review")]

    static func plainName(_ title: String, ais: [String]) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("ping:") {
            let what = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return "Tell me when “\(what)” is done"
        }
        for a in ais { t = t.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: a))\\b", with: "", options: .regularExpression) }
        // "Then It Clicked: Short of the day" → "Short of the day" (the line says it's for Then It Clicked).
        if let c = t.range(of: ": "), t.distance(from: t.startIndex, to: c.lowerBound) <= 24 {
            let head = String(t[..<c.lowerBound])
            let rest = String(t[c.upperBound...])
            t = ["check", "test", "fix", "try"].contains(head.lowercased()) ? head + " " + rest : rest
        }
        for (a, b) in tidy { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t.capitalizingFirst
    }

    /// What it does, in one line: the first plain sentence of its instructions (rules, file paths and code skipped).
    static func plainLine(_ r: Routine, owner: String?, ais: [String]) -> String {
        if r.title.lowercased().hasPrefix("ping:") {
            return "Checks every few minutes whether that job is done, and tells you once."
        }
        if let s = firstSentence(r.prompt, owner: owner) { return s }
        if r.script && r.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Runs a small script by itself, no AI needed." }
        if r.what != "Hasn't said anything yet." { return r.what }
        return "Not explained yet. Tap it, then Ask, to find out."
    }

    static let skip = try! NSRegularExpression(
        pattern:
            #"^(you run\b|read only|look only|do not|don't|never|read first|load skills|context:|gate:|steps?\b|ids?:|input:|important|note:|rules?\b|attempt\b|follow\b|end with|if )"#,
        options: [.caseInsensitive])
    static let running = try! NSRegularExpression(pattern: #"^You are [^.]*?, running (?:the |a |an )?(.+)$"#, options: [])

    static func firstSentence(_ prompt: String, owner: String?) -> String? {
        let flat = prompt.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let parts = flat.components(separatedBy: ". ").prefix(8)
        for raw in parts {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasSuffix(".") { s.removeLast() }
            let ns = NSRange(s.startIndex..., in: s)
            if let m = running.firstMatch(in: s, range: ns), let g = Range(m.range(at: 1), in: s) {
                s = "Runs the " + s[g]
            } else if s.hasPrefix("You are") || skip.firstMatch(in: s, range: ns) != nil {
                continue
            }
            if s.count < 12 || s.contains("/") || s.contains("`") || s.contains("$") || s.contains(".md") || s.count > 170 { continue }
            if s.range(of: #"\b[A-Z]{3,} [A-Z]{3,}"#, options: .regularExpression) != nil { continue }  // "CODENAME RULE"
            s = s.replacingOccurrences(of: #"^[A-Z ]{4,}: "#, with: "", options: .regularExpression)  // "DRAFT MODE: "
            if let owner, !owner.isEmpty {
                let o = NSRegularExpression.escapedPattern(for: owner)
                s = s.replacingOccurrences(of: "\\b\(o)'s\\b", with: "your", options: .regularExpression)
                s = s.replacingOccurrences(of: "\\b\(o)\\b", with: "you", options: .regularExpression)
            }
            for (a, b) in tidy { s = s.replacingOccurrences(of: a, with: b) }
            return s.capitalizingFirst + "."
        }
        return nil
    }
}

extension Routines {
    /// Its newest few runs (three or more) all had nothing to say.
    static func quietLately(_ out: URL) -> Bool {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted().suffix(6)
        guard files.count >= 3 else { return false }
        return files.allSatisfy { f in
            guard let t = try? String(contentsOf: out.appendingPathComponent(f), encoding: .utf8) else { return false }
            if t.contains("**Status:** silent") { return true }
            let body = t.components(separatedBy: "## Response").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty || body == "[SILENT]"
        }
    }
}
