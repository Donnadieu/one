import Foundation

// MARK: - What the nightly review must see (Iris self-review, Nov 18 2026)
// Four things the review never looked at, so it could not learn from them:
// - the skill edits the learning cap held back (`improve/held-review-edits.jsonl`, LearningCap.swift): 235 of them
//   between Nov 5 and Nov 18, "for the nightly review to weigh", and the review never opened the file;
// - which recipes are too big to take a lesson (over 12 KB): the most used ones, so their rules were never written;
// - the person's own rules that still name a feature One took back (the 0.9.116 "main chat is always free to talk"
//   rule stayed in how-to-work-with-me.md after the 0.9.126 revert);
// - the asks it already made and how they were answered (ImproveAsk.swift), so it never asks the same thing again.

enum ImproveSeen {
    static var heldFile: URL { Improve.dir.appendingPathComponent("held-review-edits.jsonl") }
    /// The size over which the review may not add a lesson (NightlyRoutine.prompt says the same).
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

    /// Recipes in the folders a night may edit that are over the size limit, biggest first: (name, KB).
    static func tooBig(roots: [String]) -> [(String, Int)] {
        var out: [(String, Int)] = []
        let fm = FileManager.default
        for root in roots {
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []) where !name.hasPrefix(".") {
                let f = URL(fileURLWithPath: root).appendingPathComponent(name).appendingPathComponent("SKILL.md")
                guard let size = (try? fm.attributesOfItem(atPath: f.path))?[.size] as? Int, size > recipeLimit else { continue }
                out.append((name, size / 1024))
            }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    static func tooBigSection(roots: [String]) -> String {
        let big = tooBig(roots: roots)
        guard !big.isEmpty else { return "" }
        return "\n## TOO BIG FOR A LESSON (over 12 KB; never edit these)\n" + big.map { "- \($0.0): \($0.1) KB" }.joined(separator: "\n")
            + "\nA rule that belongs to one of these goes in the ask instead: \"move its long parts into references/ so lessons fit\".\n"
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
