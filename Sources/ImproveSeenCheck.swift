import Foundation

/// Part of `One --test-nightly` (ImproveNightCheck.swift): what the review must see, from the Iris self-review of
/// Nov 18 2026. Each of these read nothing or the wrong thing on 0.9.127:
/// - the same mistake again, counted from the ledger the review really writes (`key`, `date`, `evidence`);
/// - the edits the learning cap held back, handed to the review;
/// - recipes too big for a lesson, kept out of what it may edit and listed apart;
/// - the person's rules that still name a feature One took back;
/// - the asks it already made, so it never repeats one.
enum ImproveSeenCheck {
    static func run(_ check: (String, Bool) -> Void, roots: [String]) {
        // 1. The same mistake again, from the ledger's real shape. Night dates; each night reviews the day before.
        let ledger = [
            #"{"key":"poll-quietly","status":"seen once","evidence":["a"],"date":"2099-02-02"}"#,
            #"{"key":"poll-quietly","status":"rule","evidence":["a","b"],"date":"2099-02-03"}"#,
            #"{"key":"poll-quietly","status":"rule","evidence":["a","b","c"],"date":"2099-02-05"}"#,
            #"{"key":"poll-quietly","status":"rule","evidence":["a","b","c"],"date":"2099-02-06"}"#,
            #"{"key":"other","status":"seen once","evidence":["x"],"date":"2099-02-05"}"#,
            #"{"id":"old-shape","status":"rule","rule_since":"2099-02-01","seen":["2099-02-03"]}"#,
        ].joined(separator: "\n")
        let again = ImproveScore.sameAgain(["2099-02-02", "2099-02-03", "2099-02-04", "2099-02-05"], text: ledger)
        check("same mistake again: a rule seen again with new evidence counts, on the day it happened", again["2099-02-04"] == 1)
        check(
            "the night it became a rule, a restated line and a lesson seen once don't count", again["2099-02-02"] == nil && again["2099-02-05"] == nil
        )
        check("the older ledger shape still counts", again["2099-02-03"] == 1)

        // 2. Held edits reach the review.
        let iso = ISO8601DateFormatter()
        let old = iso.string(from: Date(timeIntervalSince1970: 1000))
        let new = iso.string(from: Date())
        let held = [
            #"{"at":"\#(old)","operations":[{"action":"patch","name":"alpha","new_string":"too old"}]}"#,
            #"{"at":"\#(new)","operations":[{"action":"patch","name":"alpha","new_string":"Wait inside one step."},{"action":"write_file","name":"beta","file_content":"x"}]}"#,
        ].joined(separator: "\n")
        let h = ImproveSeen.held(since: Date().timeIntervalSince1970 - 3600, text: held)
        check("held edits since the last review are counted per recipe", h.count == 2 && h.bySkill["alpha"] == 1 && h.bySkill["beta"] == 1)
        check("with a sample of what they'd add", h.samples.contains { $0.contains("Wait inside one step.") })
        check("older ones are left out", !h.samples.contains { $0.contains("too old") })

        // 3. Recipes too big for a lesson.
        if let root = roots.first {
            let big = URL(fileURLWithPath: root).appendingPathComponent("huge/SKILL.md")
            ImproveCheck.write("---\nname: huge\n---\n" + String(repeating: "A long recipe line.\n", count: 900), big)
            let tb = ImproveSeen.tooBig(roots: roots)
            check("a recipe over 12 KB is listed as too big", tb.contains { $0.0 == "huge" })
            check("and the review is told never to edit it", ImproveSeen.tooBigSection(roots: roots).contains("never edit their SKILL.md"))
            try? FileManager.default.removeItem(at: big.deletingLastPathComponent())
        }

        // 4. Their rules that name a feature One took back.
        let rules = "- Before money, sending: wait for his yes.\n- The main chat is always free to talk (Nov 11 2026): any work goes to a helper.\n"
        let stale = ImproveSeen.staleRules(rules)
        check("a rule that names a reverted feature is found", stale.count == 1 && stale[0].1.contains("0.9.116"))
        check("the other rules are not", ImproveSeen.staleRules("- Ek uses they/them.\n").isEmpty)
    }
}
