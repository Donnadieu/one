import Foundation

// MARK: - Recipes stay small by themselves (Omar, Nov 22 2026: "the long-term fix")
// A recipe (SKILL.md) only grows: every job adds a pitfall, and the nightly review could only add lessons to the
// ones under 12 KB, which left the most used recipes (one-assistant-dev reached 98 KB) with no way to learn. So:
// - every SKILL.md has a size limit (`limit`, 12 KB). Before each nightly review (`ImproveNightRun.prepare`),
//   `tend` splits any recipe over it: `SKILL.md.bak-<date>` first, then long sections move word for word into
//   `references/<topic>.md` (a new file each, never written over), and SKILL.md keeps its frontmatter, the overview,
//   the key-rule sections that fit and a one-line index to each new file. Every non-empty line of the old SKILL.md
//   must be in the new SKILL.md, a reference file or LESSONS.md, checked in memory before writing and again from disk
//   after; if one is missing, the recipe is put back exactly as it was and the morning line says so;
// - lessons live in `LESSONS.md` next to the recipe, linked from SKILL.md (`RecipeLessons`), so they never compete
//   with the recipe for space. One line per lesson id: a repeat bumps its dates and count, never a second line.
//   An old "## Lessons" section in SKILL.md is moved there (repeats merged) on the same pass;
// - the morning brief gets one line about it (no question).

struct RecipeTidyResult: Codable, Equatable {
    var skill: String
    var path: String  // the recipe's folder
    var before: Int  // SKILL.md bytes before
    var after: Int  // and after
    var moved: [String] = []  // reference files made, relative to the folder
    var backup: String?  // SKILL.md.bak-<date>
    var lessons = 0  // lesson lines moved out of SKILL.md into LESSONS.md
    var error: String?  // why it was put back as it was
    var split: Bool { !moved.isEmpty && error == nil }
}

enum RecipeTidy {
    /// The size limit for every SKILL.md (bytes), and what a split aims for (room to grow before the next one).
    static let limit = ImproveSeen.recipeLimit
    static let target = 10 * 1024
    static let indexHeading = "## More in references/"
    static let lessonsHeading = "## Lessons"
    /// Checks only: called after the files are written and before they are read back, to prove the put-back.
    nonisolated(unsafe) static var afterWrite: ((URL) -> Void)?
    static var recordDir: URL { Improve.dir.appendingPathComponent("tidy", isDirectory: true) }

    // MARK: finding recipes

    /// Every recipe folder under the roots (a folder holding SKILL.md). No hidden folders, no links, no starter
    /// framework skills (`tier:`, the brain starter's own), never inside a recipe's own folders.
    static func recipes(_ roots: [String]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        func walk(_ d: URL, _ depth: Int) {
            guard depth < 5, let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return
            }
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isDirectory == true, v?.isSymbolicLink != true else { continue }
                if fm.fileExists(atPath: u.appendingPathComponent("SKILL.md").path) { out.append(u) } else { walk(u, depth + 1) }
            }
        }
        for r in roots { walk(URL(fileURLWithPath: r, isDirectory: true), 0) }
        return out
    }

    // MARK: reading a recipe

    struct Doc {
        var front: [String] = []  // the frontmatter, fences included
        var intro: [String] = []  // before the first "## " heading
        var sections: [[String]] = []  // each starts with its "## " line; "### " stays with its parent
    }

    static func lines(_ text: String) -> [String] {
        var l = text.components(separatedBy: "\n")
        if l.last == "" { l.removeLast() }
        return l
    }

    static func parse(_ text: String) -> Doc {
        let all = lines(text)
        var d = Doc()
        var i = 0
        if all.first == "---", let end = all.dropFirst().firstIndex(of: "---") {
            d.front = Array(all[0...end])
            i = end + 1
        }
        var fence = false
        var cur: [String]?
        for l in all[i...] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence.toggle() }
            if !fence, l.hasPrefix("## ") {
                if let c = cur { d.sections.append(c) }
                cur = [l]
            } else if cur != nil {
                cur?.append(l)
            } else {
                d.intro.append(l)
            }
        }
        if let c = cur { d.sections.append(c) }
        return d
    }

    static func bytes(_ l: [String]) -> Int { l.reduce(0) { $0 + $1.utf8.count + 1 } }
    static func title(_ s: [String]) -> String { String((s.first ?? "").dropFirst(3)).trimmingCharacters(in: .whitespaces) }
    static func isLessons(_ s: [String]) -> Bool { title(s).lowercased().hasPrefix("lessons") }
    static func isLink(_ s: [String]) -> Bool { isLessons(s) && !s.contains { $0.hasPrefix("- [L-") } && s.joined().contains(RecipeLessons.file) }
    static func isIndex(_ s: [String]) -> Bool { (s.first ?? "").hasPrefix(indexHeading) }
    /// Sections that carry the recipe's rules: kept first when there's room.
    static func isKey(_ s: [String]) -> Bool {
        let words = Set(title(s).lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["rule", "rules", "pitfall", "pitfalls", "never", "must", "ship", "workflow", "loop", "key", "first"])
    }
    static let linkSection = [
        lessonsHeading,
        "Lessons learned live in `\(RecipeLessons.file)` next to this file (one line each; a repeat bumps its count). Read it before starting.",
    ]

    static func slug(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased().unicodeScalars {
            if ch.isASCII, CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
        }
        var s = String(out.prefix(40))
        while s.hasSuffix("-") { s.removeLast() }
        return s.isEmpty ? "section" : s
    }

    // MARK: the plan (nothing written)

    struct Plan {
        var skill: String
        var refs: [(String, String)] = []  // (relative path, text)
        var lessons: String?  // the new LESSONS.md, nil = unchanged
        var lessonCount = 0
        var changed: Bool { !refs.isEmpty || lessons != nil }
    }

    static func plan(_ text: String, dir: URL, limit: Int = limit, target: Int = target) -> Plan {
        let doc = parse(text)
        var normal: [[String]] = []
        var index: [String]? = nil
        var old: [[String]] = []  // lesson sections to move out
        var link = false
        for s in doc.sections {
            if isIndex(s) {
                index = (index ?? []) + (index == nil ? s : Array(s.dropFirst()))
            } else if isLink(s) {
                link = true
            } else if isLessons(s) {
                old.append(s)
            } else {
                normal.append(s)
            }
        }
        var p = Plan(skill: text)
        if !old.isEmpty {
            let have = try? String(contentsOf: dir.appendingPathComponent(RecipeLessons.file), encoding: .utf8)
            var l = have ?? RecipeLessons.header(dir.lastPathComponent)
            for s in old {
                for line in s.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let e = RecipeLessons.entry(line) {
                        l = RecipeLessons.merge(l, e).0
                        p.lessonCount += 1
                    } else {
                        l += (l.hasSuffix("\n") ? "" : "\n") + line + "\n"  // a note in the old section: kept word for word
                    }
                }
            }
            p.lessons = l
            link = true
        }
        func build(_ intro: [String], _ kept: [[String]], _ idx: [String]?) -> String {
            var out = doc.front + intro
            for block in kept + (idx.map { [$0] } ?? []) + (link ? [linkSection] : []) {
                if let last = out.last, !last.isEmpty { out.append("") }
                out += block
            }
            while out.last == "" { out.removeLast() }
            return out.joined(separator: "\n") + "\n"
        }
        let whole = build(doc.intro, normal, index)
        guard whole.utf8.count > limit else {
            if p.lessons != nil { p.skill = whole }
            return p
        }

        // Over the limit: decide what stays. Names first (a new file each, never one that's there).
        let fm = FileManager.default
        var taken = Set(((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("references").path)) ?? []).map { $0.lowercased() })
        func name(_ t: String) -> String {
            let base = slug(t)
            var n = "\(base).md"
            var k = 2
            while taken.contains(n.lowercased()) {
                n = "\(base)-\(k).md"
                k += 1
            }
            taken.insert(n.lowercased())
            return "references/\(n)"
        }
        var intro = doc.intro
        var introRef: (String, [String])?
        if bytes(intro) > 3 * 1024 {  // a long intro keeps its title and first paragraph
            var cut = 0
            var seen = false
            for (i, l) in intro.enumerated() {
                let blank = l.trimmingCharacters(in: .whitespaces).isEmpty
                if !blank, !l.hasPrefix("# ") { seen = true }
                if (seen && blank) || bytes(Array(intro[0...i])) > 1536 {
                    cut = i
                    break
                }
            }
            if cut > 0 {
                introRef = (name("overview"), Array(intro[cut...]))
                intro = Array(intro[..<cut])
            }
        }
        let names = normal.map { name(title($0)) }
        func indexLine(_ i: Int) -> String {
            var t = title(normal[i])
            if t.count > 60 { t = String(t.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" }
            return "- `\(names[i])`: \(t)"
        }
        let head = index ?? [indexHeading + " (read the one that fits the task)", "Read the file whose topic matches the task before starting it:"]
        var total = build(intro, [], head).utf8.count + normal.indices.reduce(0) { $0 + indexLine($1).utf8.count + 1 }
        if let r = introRef { total += "- `\(r.0)`: the rest of the overview".utf8.count + 1 }
        var keep = Set<Int>()
        let order = normal.indices.filter { isKey(normal[$0]) } + normal.indices.filter { !isKey(normal[$0]) }
        for i in order {
            let size = bytes(normal[i]) + 1
            guard size <= (isKey(normal[i]) ? 3600 : 1500) else { continue }
            let next = total + size - (indexLine(i).utf8.count + 1)
            if next <= target {
                keep.insert(i)
                total = next
            }
        }
        var idx = head
        if let r = introRef {
            idx.append("- `\(r.0)`: the rest of the overview")
            p.refs.append((r.0, r.1.joined(separator: "\n") + "\n"))
        }
        for i in normal.indices where !keep.contains(i) {
            idx.append(indexLine(i))
            var body = normal[i]
            while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
            p.refs.append((names[i], body.joined(separator: "\n") + "\n"))
        }
        p.skill = build(intro, normal.indices.filter { keep.contains($0) }.map { normal[$0] }, idx)
        return p
    }

    // MARK: nothing lost

    /// Lines of `original` (non-empty) missing from `files`, counted (a line said 3 times must be there 3 times).
    /// A lesson line counts as there when its id is (repeats are merged into one line in LESSONS.md).
    static func lost(_ original: String, _ files: [String]) -> [String] {
        var have: [String: Int] = [:]
        var ids = Set<String>()
        for f in files {
            for l in f.components(separatedBy: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
                have[l, default: 0] += 1
                if let e = RecipeLessons.entry(l) { ids.insert(e.id) }
            }
        }
        var out: [String] = []
        for l in original.components(separatedBy: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            if let n = have[l], n > 0 {
                have[l] = n - 1
            } else if let e = RecipeLessons.entry(l), ids.contains(e.id) {
                continue
            } else {
                out.append(l)
            }
        }
        return out
    }

    // MARK: doing it

    static func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    /// Splits one recipe if it's over `limit` and moves an old Lessons section out. Nil when there's nothing to do.
    static func tidy(_ dir: URL, date: String, limit: Int = limit) -> RecipeTidyResult? {
        let fm = FileManager.default
        let md = dir.appendingPathComponent("SKILL.md")
        guard let text = read(md), !LearnedDirs.isFramework(text) else { return nil }
        let p = plan(text, dir: dir, limit: limit)
        guard p.changed, p.skill != text || !p.refs.isEmpty else { return nil }
        var r = RecipeTidyResult(skill: dir.lastPathComponent, path: dir.path, before: text.utf8.count, after: text.utf8.count)
        let lessonsFile = dir.appendingPathComponent(RecipeLessons.file)
        let oldLessons = read(lessonsFile)
        let planned = lost(text, [p.skill] + p.refs.map(\.1) + [p.lessons ?? oldLessons ?? ""])
        guard planned.isEmpty else {
            r.error = "\(planned.count) line(s) wouldn't have been kept (first: \"\(Improve.short(planned[0], 80))\"): left as it was"
            return r
        }
        var bak = dir.appendingPathComponent("SKILL.md.bak-\(date)")
        var k = 2
        while fm.fileExists(atPath: bak.path) {
            bak = dir.appendingPathComponent("SKILL.md.bak-\(date)-\(k)")
            k += 1
        }
        do { try fm.copyItem(at: md, to: bak) } catch {
            r.error = "couldn't keep a copy first: left as it was"
            return r
        }
        r.backup = bak.lastPathComponent
        var made: [URL] = []
        func putBack() -> Bool {
            for u in made { try? fm.removeItem(at: u) }
            let refs = dir.appendingPathComponent("references")
            if ((try? fm.contentsOfDirectory(atPath: refs.path)) ?? []).isEmpty { try? fm.removeItem(at: refs) }
            if let o = oldLessons { try? o.write(to: lessonsFile, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: lessonsFile) }
            try? text.write(to: md, atomically: true, encoding: .utf8)
            guard read(md) == text else { return false }
            try? fm.removeItem(at: bak)  // SKILL.md is the backup again, word for word
            r.backup = nil
            return true
        }
        do {
            for (rel, t) in p.refs {
                let u = dir.appendingPathComponent(rel)
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: u.path) else { throw CocoaError(.fileWriteFileExists) }
                try t.write(to: u, atomically: true, encoding: .utf8)
                made.append(u)
            }
            if let l = p.lessons { try l.write(to: lessonsFile, atomically: true, encoding: .utf8) }
            try p.skill.write(to: md, atomically: true, encoding: .utf8)
        } catch {
            r.error = "couldn't write the new files" + (putBack() ? ": put back as it was" : "; the old copy is \(bak.lastPathComponent)")
            return r
        }
        afterWrite?(dir)
        let onDisk = [read(md) ?? ""] + made.map { read($0) ?? "" } + [read(lessonsFile) ?? ""]
        let missing = lost(text, onDisk)
        guard missing.isEmpty else {
            let back = putBack()
            r.error =
                "\(missing.count) line(s) missing after the split (first: \"\(Improve.short(missing[0], 80))\")"
                + (back ? ": put back as it was" : "; couldn't put it back, the old copy is \(bak.lastPathComponent)")
            return r
        }
        r.moved = p.refs.map(\.0)
        r.lessons = p.lessonCount
        r.after = (read(md) ?? "").utf8.count
        return r
    }

    /// Every recipe under the roots, kept in `improve/tidy/<morning>.json` for that morning's line (`morning`: the
    /// date of the brief that should tell it; the night's own date by default).
    @discardableResult static func tend(roots: [String], date: String, morning: String? = nil, limit: Int = limit) -> [RecipeTidyResult] {
        let out = recipes(roots).compactMap { tidy($0, date: date, limit: limit) }
        guard !out.isEmpty else { return out }
        try? FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let day = morning ?? date
        try? enc.encode(record(day) + out).write(to: recordDir.appendingPathComponent("\(day).json"), options: .atomic)
        return out
    }
    static func record(_ date: String) -> [RecipeTidyResult] {
        (try? Data(contentsOf: recordDir.appendingPathComponent("\(date).json"))).flatMap {
            try? JSONDecoder().decode([RecipeTidyResult].self, from: $0)
        } ?? []
    }

    static func kb(_ n: Int) -> String { n >= 10 * 1024 ? "\(n / 1024)" : String(format: "%.1f", Double(n) / 1024) }

    /// The morning brief's one line about it (nil when nothing was done that night). Never a question.
    static func morningLine(date: String) -> String? {
        let all = record(date)
        let split = all.filter(\.split)
        let failed = all.filter { $0.error != nil }
        let moved = all.filter { $0.error == nil && !$0.split && $0.lessons > 0 }
        var parts: [String] = []
        if !split.isEmpty {
            let list = split.prefix(3).map { "\($0.skill) \(kb($0.before)) to \(kb($0.after)) KB" }.joined(separator: ", ")
            parts.append(
                "I split \(split.count) recipe\(split.count == 1 ? "" : "s") that had grown too big (\(list)\(split.count > 3 ? " and \(split.count - 3) more" : "")): "
                    + "long parts moved word for word into references/, nothing lost, the old copy kept")
        }
        if !moved.isEmpty { parts.append("moved the lessons of \(moved.count) recipe\(moved.count == 1 ? "" : "s") into their own LESSONS.md") }
        if !failed.isEmpty {
            let names = failed.prefix(3).map(\.skill).joined(separator: ", ")
            parts.append("couldn't split \(names) without losing a line, so I left \(failed.count == 1 ? "it as it was" : "them as they were")")
        }
        guard var line = parts.first else { return nil }
        if parts.count > 1 { line += "; " + parts.dropFirst().joined(separator: "; ") }
        return line + "."
    }

    /// The morning brief that will next tell about something done now: today's before 5 AM, else tomorrow's.
    static func nextMorning(_ now: Date) -> String {
        Calendar.current.component(.hour, from: now) < 5 ? Improve.dayKey(now) : Improve.dayKey(now.addingTimeInterval(86400))
    }

    /// `One --improve recipes tidy [--root DIR]… [--date D]`: what the night does before the review, by hand. The
    /// next morning brief says what it did.
    static func cli(_ a: [String], now: Date = Date()) -> Int32 {
        guard a.first == "tidy" else {
            print("usage: One --improve recipes tidy [--root DIR]... [--date YYYY-MM-DD]")
            return 2
        }
        var roots: [String] = []
        for (i, x) in a.enumerated() where x == "--root" && i + 1 < a.count { roots.append(a[i + 1]) }
        let date = ImproveCLI.value(a, "--date") ?? Improve.dayKey(now)
        let out = tend(roots: roots.isEmpty ? LearnedDirs.wanted() : roots, date: date, morning: nextMorning(now))
        for r in out {
            if let e = r.error {
                print("\(r.skill): \(e)")
            } else {
                print(
                    "\(r.skill): \(r.before / 1024) KB -> \(r.after / 1024) KB, \(r.moved.count) reference file(s), \(r.lessons) lesson line(s) moved, backup \(r.backup ?? "-")"
                )
            }
        }
        if out.isEmpty { print("Every recipe is within \(limit / 1024) KB and keeps its lessons in LESSONS.md.") }
        return out.contains { $0.error != nil } ? 1 : 0
    }
}
