import CryptoKit
import Foundation

/// Skills that ship inside One: repo `skills/<category>/<name>/SKILL.md`, bundled into Resources/skills by build.sh.
/// Copied into the engine's skills folder after install and at every launch. Additive: a skill the person (or
/// their assistant) changed is never overwritten; an untouched copy is updated when a newer version ships.
/// What One last put there is remembered by hash in `<hermes home>/.one-bundled-skills.json`.
enum BundledSkills {
    static var source: URL? { Bundle.main.resourceURL?.appendingPathComponent("skills", isDirectory: true) }
    static var target: URL { Env.hermesHome.appendingPathComponent("skills", isDirectory: true) }
    static var record: URL { Env.hermesHome.appendingPathComponent(".one-bundled-skills.json") }

    /// Every skill folder under `root`, relative to it ("productivity/basecamp-connect").
    static func list(in root: URL) -> [String] {
        let base = root.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let u as URL in e where u.lastPathComponent == "SKILL.md" {
            let dir = u.deletingLastPathComponent().standardizedFileURL.path
            if dir.hasPrefix(base + "/") { out.append(String(dir.dropFirst(base.count + 1))) }
        }
        return out.sorted()
    }

    /// One hash for a whole skill folder (file names and contents), so an edit anywhere counts. Nil when empty or missing.
    static func hash(_ dir: URL) -> String? {
        let base = dir.standardizedFileURL.path
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        var files: [(String, URL)] = []
        for case let u as URL in e where u.lastPathComponent != ".DS_Store" {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append((String(u.standardizedFileURL.path.dropFirst(base.count)), u))
        }
        guard !files.isEmpty else { return nil }
        var h = SHA256()
        for (rel, u) in files.sorted(by: { $0.0 < $1.0 }) {
            h.update(data: Data(rel.utf8))
            h.update(data: Data([0]))
            h.update(data: (try? Data(contentsOf: u)) ?? Data())
            h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies bundled skills in. Returns what happened to each: added, updated, up to date, kept (changed here).
    @discardableResult static func sync(from src: URL? = source, to dst: URL = target, record rec: URL = record) -> [String: String] {
        let fm = FileManager.default
        guard let src, fm.fileExists(atPath: src.path) else { return [:] }
        var seen = (try? Data(contentsOf: rec)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        var out: [String: String] = [:]
        for rel in list(in: src) {
            let from = src.appendingPathComponent(rel, isDirectory: true)
            let to = dst.appendingPathComponent(rel, isDirectory: true)
            guard let shipped = hash(from) else { continue }
            let have = hash(to)
            if have == shipped {
                seen[rel] = shipped
                out[rel] = "up to date"
            } else if have == nil || have == seen[rel] {
                // Missing, or still exactly what One put there before: safe to (re)place.
                try? fm.removeItem(at: to)
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? fm.copyItem(at: from, to: to)) != nil else {
                    out[rel] = "failed"
                    continue
                }
                out[rel] = have == nil ? "added" : "updated"
                seen[rel] = shipped
            } else {
                out[rel] = "kept (changed here)"
            }
        }
        if let d = try? JSONSerialization.data(withJSONObject: seen, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: rec, options: .atomic)
        }
        return out
    }

    /// `One --test-skills` (run by preflight with ONE_SUPPORT_DIR set to an empty folder): a fresh home receives
    /// every bundled skill, a second run changes nothing, an edited copy is kept, an untouched older copy is updated,
    /// and a same-named skill the person made themselves is left alone.
    static func check() -> Int32 {
        let fm = FileManager.default
        var fails = 0
        func ok(_ name: String, _ pass: Bool) {
            print("  \(pass ? "✓" : "✗") \(name)")
            if !pass { fails += 1 }
        }
        guard let src = source else {
            print("  ✗ no skills folder in the app")
            return 1
        }
        let names = list(in: src)
        ok("the app carries skills (\(names.joined(separator: ", ")))", !names.isEmpty)
        guard let first = names.first else { return 1 }
        let skill = { (root: URL) in root.appendingPathComponent(first).appendingPathComponent("SKILL.md") }
        let shipped = (try? String(contentsOf: skill(src), encoding: .utf8)) ?? ""

        let r1 = sync()
        ok("a fresh home receives every skill", names.allSatisfy { r1[$0] == "added" && hash(target.appendingPathComponent($0)) != nil })
        ok("the copy matches the app", (try? String(contentsOf: skill(target), encoding: .utf8)) == shipped)
        ok("a second run changes nothing", sync().values.allSatisfy { $0 == "up to date" })

        let edited = shipped + "\nMy own note.\n"
        try? edited.write(to: skill(target), atomically: true, encoding: .utf8)
        ok("an edited copy is kept", sync()[first] == "kept (changed here)")
        ok("the edit is still there", (try? String(contentsOf: skill(target), encoding: .utf8)) == edited)

        // An older version that One shipped before and nobody touched: gets updated.
        let old = Env.support.appendingPathComponent("skills-check-old", isDirectory: true)
        let home2 = Env.support.appendingPathComponent("skills-check-home2", isDirectory: true)
        let rec2 = Env.support.appendingPathComponent("skills-check-home2.json")
        try? fm.removeItem(at: old)
        try? fm.createDirectory(at: skill(old).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "---\nname: old\ndescription: old\n---\nOld version.\n".write(to: skill(old), atomically: true, encoding: .utf8)
        sync(from: old, to: home2, record: rec2)
        ok("an untouched older copy is updated", sync(from: src, to: home2, record: rec2)[first] == "updated")
        ok("it now matches the app", (try? String(contentsOf: skill(home2), encoding: .utf8)) == shipped)

        // A skill with the same name that the person made before One shipped one: left alone.
        let home3 = Env.support.appendingPathComponent("skills-check-home3", isDirectory: true)
        try? fm.createDirectory(at: skill(home3).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "mine".write(to: skill(home3), atomically: true, encoding: .utf8)
        let r3 = sync(from: src, to: home3, record: Env.support.appendingPathComponent("skills-check-home3.json"))
        ok("a same-named skill of their own is left alone", r3[first] == "kept (changed here)")

        print(fails == 0 ? "skills ok" : "skills FAILED (\(fails))")
        return fails == 0 ? 0 : 1
    }
}
