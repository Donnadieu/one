import Foundation

// MARK: - What the nightly review must see (Iris self-review, Nov 18 2026)
// Four things the review never looked at, so it could not learn from them:
// - the skill edits the learning cap held back (`improve/held-review-edits.jsonl`, LearningCap.swift): 235 of them
//   between Nov 5 and Nov 18, "for the nightly review to weigh", and the review never opened the file;
// - which recipes are over 12 KB (since RecipeTidy.swift they are split before the review; this lists any left over);
// - the person's own rules that still name a feature One took back (the 0.9.116 "main chat is always free to talk"
//   rule stayed in how-to-work-with-me.md after the 0.9.126 revert);
// - the asks it already made and how they were answered (ImproveAsk.swift), so it never asks the same thing again.

enum ImproveSeen {
    static var heldFile: URL { Improve.dir.appendingPathComponent("held-review-edits.jsonl") }
    /// The size limit for every SKILL.md: over it, the night splits the recipe before the review (RecipeTidy.swift).
    static let recipeLimit = 12 * 1024

    struct Held {
        var count = 0
        var bySkill: [String: Int] = [:]
        var samples: [String] = []
    }

    /// Held edits since `since` (unix time): how many, per recipe, and up to `max` short samples of what they'd add.
    static func held(since: Double, text: String? = nil, max: Int = 12) -> Held {
        var h = Held()
        guard let t = text ?? (try? String(contentsOf: heldFile, encoding: .utf8)) else { return h }
        let iso = ISO8601DateFormatter()
        for line in t.split(separator: "\n") {
            guard let j = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                let at = (j["at"] as? String).flatMap({ iso.date(from: $0) }), at.timeIntervalSince1970 >= since
            else { continue }
            for op in (j["operations"] as? [[String: Any]]) ?? [] {
                let name = (op["name"] as? String) ?? "?"
                h.count += 1
                h.bySkill[name, default: 0] += 1
                let words = (op["new_string"] as? String) ?? (op["file_content"] as? String) ?? (op["content"] as? String) ?? ""
                if h.samples.count < max, !words.isEmpty {
                    let act = (op["action"] as? String) ?? "edit"
                    h.samples.append("\(name) (\(act)): \(Improve.short(words.replacingOccurrences(of: "\n", with: " "), 220))")
                }
            }
        }
        return h
    }

    /// The prepare section for held edits ("" when there are none).
    static func heldSection(since: Double) -> String {
        let h = held(since: since)
        guard h.count > 0 else { return "" }
        var out = "\n## HELD EDITS since the last review: \(h.count) (the engine's after-job review wanted these; the cap held them)\n"
        out += "Weigh them like moments: one that repeats a lesson in the ledger is evidence for it; never copy them in whole.\n"
        out +=
            h.bySkill.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10)
            .map { "- \($0.key): \($0.value)" }.joined(separator: "\n") + "\n"
        out += "Samples:\n" + h.samples.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return out
    }

    /// Recipes in the folders a night may edit still over the size limit (the split couldn't make them fit, or
    /// failed its no-line-lost check), biggest first: (name, KB).
    static func tooBig(roots: [String]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        for dir in RecipeTidy.recipes(roots) {
            let f = dir.appendingPathComponent("SKILL.md")
            guard let size = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.size] as? Int, size > recipeLimit else { continue }
            out.append((dir.lastPathComponent, size / 1024))
        }
        return out.sorted { $0.1 > $1.1 }
    }

    static func tooBigSection(roots: [String]) -> String {
        let big = tooBig(roots: roots)
        guard !big.isEmpty else { return "" }
        return "\n## STILL OVER 12 KB (One's split couldn't make these fit; never edit their SKILL.md)\n"
            + big.map { "- \($0.0): \($0.1) KB" }.joined(separator: "\n")
            + "\nTheir lessons still go in with the LESSON COMMAND (LESSONS.md has no size limit). One tries the split again every night.\n"
    }

    // MARK: The person's rules that name a feature One took back

    /// Features One shipped and then took back, with words that name them in a person's rules. Add a line with every
    /// release that reverts something.
    static let reverted: [(version: String, title: String, words: [String])] = [
        ("0.9.116 (reverted in 0.9.126)", "The main chat is always free to talk", ["always free to talk", "free to talk"])
    ]

    /// Lines of the rules text that still name a reverted feature: (line, what was reverted).
    static func staleRules(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for line in text.split(separator: "\n").map(String.init) {
            let l = line.lowercased()
            if let r = reverted.first(where: { $0.words.contains { l.contains($0) } }) {
                out.append((line.trimmingCharacters(in: .whitespaces), "\(r.title), \(r.version)"))
            }
        }
        return out
    }

    static func staleSection() -> String {
        let text = (try? String(contentsOf: FrontPage.howTo, encoding: .utf8)) ?? ""
        let stale = staleRules(text)
        guard !stale.isEmpty else { return "" }
        return "\n## THEIR RULES THAT NAME A FEATURE ONE TOOK BACK (\(FrontPage.howTo.path))\n"
            + stale.map { "- \"\(Improve.short($0.0, 200))\" (\($0.1))" }.joined(separator: "\n")
            + "\nNever edit their rules. Ask once (key stale-rule-<feature>) whether to take the line out.\n"
    }
}
