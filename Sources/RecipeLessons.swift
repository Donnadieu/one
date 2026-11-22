import Foundation

// MARK: - Lessons live next to the recipe, one line each (RecipeTidy.swift has the why)
// `<recipe>/LESSONS.md`, linked from its SKILL.md:
//     - [L-<key>] <rule> (seen 2026-11-10 to 2026-11-22, 12 times)
// The same key again never adds a line: its dates widen and its count goes up (`merge`). The nightly review adds a
// lesson only through `One --improve lesson add`, so the merge is code, not a promise in its instructions.

enum RecipeLessons {
    static let file = "LESSONS.md"

    struct Entry: Equatable {
        var id: String  // "L-<key>"
        var rule: String
        var first: String  // YYYY-MM-DD, "" when the line had no date
        var last: String
        var times: Int
    }

    static func header(_ name: String) -> String {
        "# Lessons: \(name)\n\nLearned by One's nightly review. One line per lesson; the same lesson again bumps its dates and count "
            + "instead of adding a line.\n\n"
    }

    static func id(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespaces)
        return k.hasPrefix("L-") ? k : "L-\(k)"
    }

    static func dates(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// A lesson line (`- [L-key] rule (seen …)`), or nil.
    static func entry(_ line: String) -> Entry? {
        guard line.hasPrefix("- [L-"), let close = line.firstIndex(of: "]") else { return nil }
        let id = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        guard !id.contains(" ") else { return nil }
        var rule = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        var seen = ""
        if rule.hasSuffix(")"), let open = rule.range(of: "(seen ", options: .backwards) {
            seen = String(rule[open.upperBound..<rule.index(before: rule.endIndex)])
            rule = String(rule[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        let d = Set(dates(seen)).sorted()
        var times = d.count
        if let re = try? NSRegularExpression(pattern: #"(\d+) times?\b"#),
            let m = re.firstMatch(in: seen, range: NSRange(seen.startIndex..., in: seen)), let r = Range(m.range(at: 1), in: seen)
        {
            times = Int(seen[r]) ?? times
        }
        return Entry(id: id, rule: rule, first: d.first ?? "", last: d.last ?? "", times: max(times, 1))
    }

    static func render(_ e: Entry) -> String {
        let seen: String
        if e.first.isEmpty {
            seen = e.times == 1 ? "once" : "\(e.times) times"
        } else if e.first == e.last {
            seen = e.times == 1 ? e.first : "\(e.first), \(e.times) times"
        } else {
            seen = "\(e.first) to \(e.last), \(e.times) times"
        }
        return "- [\(e.id)] \(e.rule) (seen \(seen))"
    }

    /// Adds `e` to a LESSONS.md text, or merges it into the line with its id. Returns the text and whether it merged.
    static func merge(_ text: String, _ e: Entry) -> (String, Bool) {
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { entry($0)?.id == e.id }), var have = entry(lines[i]) {
            let ds = [have.first, have.last, e.first, e.last].filter { !$0.isEmpty }.sorted()
            have.first = ds.first ?? ""
            have.last = ds.last ?? ""
            have.times += e.times
            if have.rule.isEmpty { have.rule = e.rule }
            lines[i] = render(have)
            return (lines.joined(separator: "\n"), true)
        }
        if let i = lines.lastIndex(where: { entry($0) != nil }) {
            lines.insert(render(e), at: i + 1)
            return (lines.joined(separator: "\n"), false)
        }
        var t = text
        if !t.isEmpty, !t.hasSuffix("\n") { t += "\n" }
        return (t + render(e) + "\n", false)
    }

    /// Adds one lesson to the recipe in `dir`: an old Lessons section in SKILL.md moves to LESSONS.md first, SKILL.md
    /// gets its one link line if it has none. Returns a plain line saying what happened.
    @discardableResult static func add(dir: URL, key: String, rule: String, first: String, last: String?, times: Int) -> String {
        let md = dir.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: md.path) else { return "no recipe at \(dir.path)" }
        _ = RecipeTidy.tidy(dir, date: Improve.dayKey(Date()), limit: Int.max)  // moves an old Lessons section, never splits
        let f = dir.appendingPathComponent(file)
        let text = (try? String(contentsOf: f, encoding: .utf8)) ?? header(dir.lastPathComponent)
        let e = Entry(
            id: id(key), rule: rule.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " "), first: first,
            last: last ?? first, times: max(times, 1))
        let (out, merged) = merge(text, e)
        try? out.write(to: f, atomically: true, encoding: .utf8)
        if let s = try? String(contentsOf: md, encoding: .utf8), !s.contains(file) {
            let link = RecipeTidy.linkSection.joined(separator: "\n")
            try? (s + (s.hasSuffix("\n") ? "" : "\n") + "\n" + link + "\n").write(to: md, atomically: true, encoding: .utf8)
        }
        let now = out.components(separatedBy: "\n").first { entry($0)?.id == e.id } ?? render(e)
        return (merged ? "merged: " : "added: ") + now
    }

    /// The recipe folder for `--skill`: a folder, a SKILL.md path, or a recipe's name in the folders a night may edit.
    static func folder(_ s: String) -> URL? {
        let fm = FileManager.default
        var u = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        if u.lastPathComponent == "SKILL.md" { u.deleteLastPathComponent() }
        if s.contains("/"), fm.fileExists(atPath: u.appendingPathComponent("SKILL.md").path) { return u }
        return RecipeTidy.recipes(LearnedDirs.wanted()).first { $0.lastPathComponent == s }
    }

    /// `One --improve lesson add --skill <folder|name> --key <key> --rule <text> [--date D] [--to D] [--times N]`
    static func cli(_ a: [String]) -> Int32 {
        let v = { (f: String) in ImproveCLI.value(a, f) }
        guard a.first == "add", let s = v("--skill"), let key = v("--key"), let rule = v("--rule"), !key.isEmpty, !rule.isEmpty else {
            print("usage: One --improve lesson add --skill <recipe folder or name> --key <key> --rule <text> [--date D] [--to D] [--times N]")
            return 2
        }
        guard let dir = folder(s) else {
            print("No recipe found for \(s).")
            return 1
        }
        let first = v("--date") ?? Improve.dayKey(Date())
        guard Improve.day(first) != nil, v("--to").map({ Improve.day($0) != nil }) ?? true else {
            print("Dates are YYYY-MM-DD.")
            return 2
        }
        print(add(dir: dir, key: key, rule: rule, first: first, last: v("--to"), times: Int(v("--times") ?? "") ?? 1))
        return 0
    }
}
