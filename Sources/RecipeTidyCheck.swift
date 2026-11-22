import Foundation

/// Part of `One --test-nightly` (ImproveNightCheck.swift): recipes stay small by themselves (RecipeTidy.swift).
/// Before this, a recipe over 12 KB was only listed as "too big for a lesson" and never shrank (one-assistant-dev
/// reached 98 KB, so no lesson could ever reach it), and the review appended a lesson as a new line each time it
/// came back, so one lesson seen 12 times would be 12 lines. Each check below failed on 0.9.144:
/// - a recipe over the limit is split: a backup first, long sections word for word into `references/`, the
///   frontmatter, the overview, the key rules and a one-line index to each file left in SKILL.md;
/// - no line is lost (checked here independently of the code's own check), and a split that would lose one is put
///   back exactly as it was;
/// - lessons live in LESSONS.md next to the recipe, linked from it; an old "## Lessons" section is moved there;
/// - the same lesson again bumps its count and dates instead of adding a line;
/// - the nightly review splits by itself before it runs and says so in one morning line.
enum RecipeTidyCheck {
    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    /// A recipe of about 33 KB: an overview, a key-rules section, 30 long topics, a code block holding a line that
    /// looks like a heading, and an old Lessons section with the same lesson twice.
    static func bigRecipe(_ name: String) -> String {
        var t = "---\nname: \(name)\ndescription: Use when checking the split.\n---\n\n# \(name)\n\nA short overview of the recipe.\n\n"
        t += "## Rules that bite\n- Never run a test on the person's Mac.\n- Always sign commits.\n\n"
        for i in 0..<30 {
            t += "## Topic \(i)\n"
            t += (0..<12).map { "- Step \($0) of topic \(i): " + String(repeating: "word ", count: 12) }.joined(separator: "\n")
            t += "\n- A line said in every topic.\n\n"
        }
        t += "## Code\n```\n## not a heading, it's inside code\n```\n\n"
        t += "## Lessons\n- [L-dup] Say the result. (seen 2099-01-01)\n- [L-dup] Say the result. (seen 2099-01-03)\n"
        t += "- [L-other] Wait inside one step. (seen 2099-01-02, 2099-01-04)\n"
        return t
    }

    /// Every non-empty line of `original` is somewhere in `files` (as many times as it was there), except lesson lines,
    /// whose id only has to be in LESSONS.md (repeats are merged into one line).
    static func everyLineKept(_ original: String, _ files: [String], lessons: String) -> Bool {
        var have: [String: Int] = [:]
        for f in files { for l in f.components(separatedBy: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty { have[l, default: 0] += 1 } }
        for l in original.components(separatedBy: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            if l.hasPrefix("- [L-"), let id = l.split(separator: "]").first.map({ String($0.dropFirst(3)) }) {
                if lessons.contains("[\(id)]") { continue }
                return false
            }
            guard let n = have[l], n > 0 else {
                print("    lost: \(l.prefix(80))")
                return false
            }
            have[l] = n - 1
        }
        return true
    }

    static func files(_ dir: URL) -> [String] {
        let refs = dir.appendingPathComponent("references")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: refs.path)) ?? []).sorted()
        return [read(dir.appendingPathComponent("SKILL.md"))] + names.map { read(refs.appendingPathComponent($0)) }
    }

    static func run(_ check: (String, Bool) -> Void, root: URL, now: Date) {
        let fm = FileManager.default
        let big = root.appendingPathComponent("big")
        let skill = big.appendingPathComponent("SKILL.md")
        let original = bigRecipe("big")
        ImproveCheck.write(original, skill)
        ImproveCheck.write("An older reference with the same name as a topic.\n", big.appendingPathComponent("references/topic-1.md"))
        check("the check's recipe is over the limit", original.utf8.count > RecipeTidy.limit)

        // 1. The split.
        let results = RecipeTidy.tend(roots: [root.path], date: "2099-03-01")
        let r = results.first { $0.skill == "big" }
        let text = read(skill)
        check("an oversize recipe is split by itself", r?.split == true && (r?.moved.count ?? 0) > 0)
        check("its SKILL.md is under the limit after", text.utf8.count <= RecipeTidy.limit && r?.after == text.utf8.count)
        check("a backup is kept first, word for word", read(big.appendingPathComponent("SKILL.md.bak-2099-03-01")) == original)
        check("the frontmatter stays on top", text.hasPrefix("---\nname: big\ndescription: Use when checking the split.\n---\n"))
        check("the overview and the key rules stay", text.contains("A short overview") && text.contains("## Rules that bite\n- Never run a test"))
        let index = text.components(separatedBy: "\n").filter { $0.hasPrefix("- `references/") }
        let pointed = index.compactMap { $0.split(separator: "`").dropFirst().first.map(String.init) }
        check(
            "one index line for each file it made, each pointing at a real file",
            !index.isEmpty && Set(pointed) == Set(r?.moved ?? ["?"])
                && pointed.allSatisfy { fm.fileExists(atPath: big.appendingPathComponent($0).path) })
        check(
            "an existing reference file is never written over",
            read(big.appendingPathComponent("references/topic-1.md")).hasPrefix("An older reference"))
        let lessons = read(big.appendingPathComponent("LESSONS.md"))
        check(
            "no line is lost (every line of the old recipe is in SKILL.md, a reference or LESSONS.md)",
            everyLineKept(original, files(big), lessons: lessons))
        check(
            "a code block moves whole (a heading-looking line inside it doesn't cut it)",
            files(big).contains { $0.contains("```\n## not a heading, it's inside code\n```") })

        // 2. Lessons in their own file, repeats merged.
        check("the old Lessons section moved into LESSONS.md, linked from SKILL.md", !text.contains("- [L-") && text.contains("LESSONS.md"))
        let dup = lessons.components(separatedBy: "\n").filter { $0.contains("[L-dup]") }
        check(
            "the same lesson twice in the old section is one line: seen 2 times",
            dup.count == 1 && dup[0].contains("2099-01-01 to 2099-01-03, 2 times"))
        check("an old \"(seen A, B)\" counts each date", lessons.contains("[L-other] Wait inside one step. (seen 2099-01-02 to 2099-01-04, 2 times)"))
        check("a second run changes nothing", RecipeTidy.tend(roots: [root.path], date: "2099-03-02").isEmpty && read(skill) == text)

        _ = RecipeLessons.add(dir: big, key: "answer-lost", rule: "Keep the answer.", first: "2099-03-02", last: nil, times: 1)
        _ = RecipeLessons.add(dir: big, key: "L-answer-lost", rule: "Keep the answer.", first: "2099-03-03", last: nil, times: 1)
        let code = ImproveCLI.run([
            "One", "--improve", "lesson", "add", "--skill", big.path, "--key", "answer-lost", "--rule", "Keep the answer.", "--date", "2099-03-01",
            "--to", "2099-03-05", "--times", "10",
        ])
        let lost = read(big.appendingPathComponent("LESSONS.md")).components(separatedBy: "\n").filter { $0.contains("[L-answer-lost]") }
        check("the same lesson again bumps its count and dates, never a second line", lost.count == 1)
        check(
            "with the whole range and count",
            code == 0 && lost.first == "- [L-answer-lost] Keep the answer. (seen 2099-03-01 to 2099-03-05, 12 times)")
        check("a lesson never lands in SKILL.md", !read(skill).contains("answer-lost"))
        let small = root.appendingPathComponent("small")
        ImproveCheck.write("---\nname: small\n---\n# small\n", small.appendingPathComponent("SKILL.md"))
        _ = RecipeLessons.add(dir: small, key: "first", rule: "A first lesson.", first: "2099-03-02", last: nil, times: 1)
        check(
            "a recipe's first lesson makes LESSONS.md and links it",
            read(small.appendingPathComponent("LESSONS.md")).contains("- [L-first] A first lesson. (seen 2099-03-02)")
                && read(small.appendingPathComponent("SKILL.md")).contains("LESSONS.md"))

        // 3. A split that would lose a line is put back as it was.
        let spoilt = root.appendingPathComponent("spoilt")
        let spoiltText = bigRecipe("spoilt")
        ImproveCheck.write(spoiltText, spoilt.appendingPathComponent("SKILL.md"))
        RecipeTidy.afterWrite = { dir in
            let refs = dir.appendingPathComponent("references")
            guard let f = ((try? fm.contentsOfDirectory(atPath: refs.path)) ?? []).sorted().first else { return }
            let u = refs.appendingPathComponent(f)
            let kept = read(u).components(separatedBy: "\n").dropFirst(2).joined(separator: "\n")
            try? kept.write(to: u, atomically: true, encoding: .utf8)
        }
        let bad = RecipeTidy.tend(roots: [root.path], date: "2099-03-03").first { $0.skill == "spoilt" }
        RecipeTidy.afterWrite = nil
        check("a split that lost a line is reported", bad?.error?.isEmpty == false && bad?.split == false)
        check("and the recipe is put back exactly as it was", read(spoilt.appendingPathComponent("SKILL.md")) == spoiltText)
        check(
            "with no half-made files left",
            ((try? fm.contentsOfDirectory(atPath: spoilt.path)) ?? []).filter { $0 != "SKILL.md" && !$0.hasPrefix("SKILL.md.bak") }.isEmpty)
        check(
            "the morning line says what it split, and what it couldn't",
            RecipeTidy.morningLine(date: "2099-03-03")?.contains("couldn't split spoilt") == true)
        let line = RecipeTidy.morningLine(date: "2099-03-01") ?? ""
        check("one line, no question", line.contains("I split 1 recipe") && line.contains("big") && !line.contains("?") && !line.contains("\n"))

        // 4. By hand (`One --improve recipes tidy`) at noon: the next morning's brief tells it.
        let byHand = root.appendingPathComponent("byhand")
        ImproveCheck.write(bigRecipe("byhand"), byHand.appendingPathComponent("SKILL.md"))
        let noon = Calendar.current.date(from: DateComponents(year: 2099, month: 5, day: 1, hour: 12)) ?? now
        let handCode = RecipeTidy.cli(["tidy", "--root", root.path], now: noon)
        check(
            "a split by hand is told in the next morning's brief",
            handCode == 0 && RecipeTidy.morningLine(date: "2099-05-02")?.contains("byhand") == true
                && fm.fileExists(atPath: byHand.appendingPathComponent("SKILL.md.bak-2099-05-01").path))
        try? fm.removeItem(at: byHand)

        // 5. The nightly review does it by itself, before it runs, and says so in the morning.
        try? fm.removeItem(at: spoilt)
        let giant = root.appendingPathComponent("giant")
        ImproveCheck.write(bigRecipe("giant"), giant.appendingPathComponent("SKILL.md"))
        try? fm.removeItem(at: ImproveNight.recordFile(Improve.dayKey(now)))
        let out = ImproveNightRun.prepare(now: now, waitMinutes: 0.1, force: true)
        check(
            "the night's prepare splits an oversize recipe before the review",
            read(giant.appendingPathComponent("SKILL.md")).utf8.count <= RecipeTidy.limit)
        check("and hands the review the lesson command", out.contains("LESSON COMMAND") && out.contains("--improve lesson add"))
        check("the morning lines say it split it", ImproveNightRun.morning(now: now).contains { $0.contains("I split") && $0.contains("giant") })
        check("the review is told never to write a lesson into SKILL.md", NightlyRoutine.prompt.contains("never write a lesson into SKILL.md"))
        for n in ["big", "small", "giant"] { try? fm.removeItem(at: root.appendingPathComponent(n)) }
    }
}
