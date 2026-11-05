import CryptoKit
import Foundation

// MARK: - The nightly review: a routine that ships with One
// Design "One gets better by itself" (Nov 5 2026), sections 3b, 3c, 4, 6, 7. The prompt is `routines/nightly-review.md`
// (bundled into Resources/routines by build.sh). At every launch One makes sure the engine has a routine named exactly
// "Nightly review" at 3:30 am (`hermes cron create`, never twice) and brings its prompt up to date when a new version
// of One ships a new prompt (the first line carries the version and a fingerprint). It's an engine routine, so it shows
// on the Routines dial with Run now and Pause like the others. It works quietly: its answer is exactly [SILENT], which
// One never reads aloud or shows (`Model.tendRoutines`), and it delivers nowhere (`--deliver local`).
// By default it only suggests (improve/settings.json `mode: suggest`); its morning note is `improve/morning/<date>.md`.

enum NightlyReview {
    static let name = "Nightly review"
    static let schedule = "30 3 * * *"
    static let marker = "One's nightly review (built in"
    static var promptFile: URL? { Bundle.main.url(forResource: "nightly-review", withExtension: "md", subdirectory: "routines") }
    static var jobsFile: URL { Env.hermesHome.appendingPathComponent("cron/jobs.json") }
    static var logFile: URL { Env.hermesHome.appendingPathComponent("logs/one-nightly-review.log") }

    /// True when this copy of One has the part named `type` (another part of One may not be in every build). A command
    /// One doesn't know would open the whole app instead of printing an error, so steps that need a missing part are left
    /// out of the prompt. Asks Swift's own type list, so it can't be fooled by a name merely written in this file.
    static func has(_ type: String) -> Bool {
        ["O", "V", "C"].contains { _typeByName("3One\(type.utf8.count)\(type)\($0)") != nil }  // Swift's names: enum, struct, class
    }

    /// The prompt as this copy of One runs it: One's real paths filled in, steps needing a part this build lacks replaced
    /// by a skip line, and the first line carrying a fingerprint of the rest (so a new version is noticed).
    static func render(_ text: String, exe: String = Bridge.exe, present: (String) -> Bool = has) -> String {
        let one = "\"\(exe)\""
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var l = raw
            if let r = l.range(of: #"\s*\[needs: ([A-Za-z]+)\]"#, options: .regularExpression) {
                let type = String(l[r]).components(separatedBy: ": ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "] ")) ?? ""
                if present(type) {
                    l.removeSubrange(r)
                } else {
                    let indent = l.prefix { $0 == " " }
                    l =
                        indent
                        + "- (Skipped: this copy of One can't do this step yet. Say so in the morning note; if it was the safety copy, make no changes tonight.)"
                }
            }
            l = l.replacingOccurrences(of: "{ONE}", with: one).replacingOccurrences(of: "{SUPPORT}", with: Env.support.path)
                .replacingOccurrences(of: "{BRAIN}", with: Brain.root.path)
                .replacingOccurrences(of: "`ONE ", with: "`\(one) ").replacingOccurrences(of: "`SUPPORT/", with: "`\(Env.support.path)/")
                .replacingOccurrences(of: "`BRAIN/", with: "`\(Brain.root.path)/")
            lines.append(l)
        }
        guard let first = lines.first else { return "" }
        let body = lines.dropFirst().joined(separator: "\n")
        let fp = SHA256.hash(data: Data(body.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return first + " Fingerprint \(fp).\n" + body
    }

    /// The engine's routines (`cron/jobs.json`).
    static func jobs() -> [[String: Any]] {
        guard let d = try? Data(contentsOf: jobsFile), let top = try? JSONSerialization.jsonObject(with: d) else { return [] }
        return (top as? [String: Any])?["jobs"] as? [[String: Any]] ?? top as? [[String: Any]] ?? []
    }

    /// Makes sure the routine is there and up to date. Returns what happened: added, updated, up to date, kept (a routine
    /// with that name that isn't One's own: never touched), no prompt (this copy doesn't carry it), or failed.
    @discardableResult
    static func ensure(promptText: String? = nil, run: HermesRunner = { await hermesRun($0, timeout: 60) }) async -> String {
        guard let text = promptText ?? promptFile.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return "no prompt" }
        let prompt = render(text)
        let mine = jobs().filter { ($0["name"] as? String) == name }
        guard let job = mine.first else {
            let (code, out) = await run(["cron", "create", schedule, prompt, "--name", name, "--deliver", "local"])
            let ok = code == 0 && jobs().contains { ($0["name"] as? String) == name }
            log(ok ? "added the nightly review (3:30 am, suggestions only until they say otherwise)" : "couldn't add it: \(out.suffix(300))")
            return ok ? "added" : "failed"
        }
        let have = (job["prompt"] as? String) ?? ""
        let firstLine = { (s: String) in s.components(separatedBy: "\n").first ?? "" }
        guard have.hasPrefix(marker) else { return "kept" }
        guard firstLine(have) != firstLine(prompt), let id = job["id"] as? String else { return "up to date" }
        let (code, out) = await run(["cron", "edit", id, "--prompt", prompt])
        log(code == 0 ? "brought the nightly review's prompt up to date" : "couldn't update it: \(out.suffix(300))")
        return code == 0 ? "updated" : "failed"
    }

    static func log(_ s: String) {
        try? FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: The morning note

    static var morningDir: URL { Improve.dir.appendingPathComponent("morning", isDirectory: true) }

    /// The note's lines (at most 5: three lines and a choices line), or none.
    static func morning(_ date: String) -> [String] {
        guard let t = try? String(contentsOf: morningDir.appendingPathComponent("\(date).md"), encoding: .utf8) else { return [] }
        let lines = t.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Array(lines.prefix(5))
    }

    /// True when one of their routines is a morning brief (it shows the note itself).
    static var hasMorningBrief: Bool { jobs().contains { (($0["name"] as? String) ?? "").localizedCaseInsensitiveContains("morning brief") } }

    /// The note as a card on the Ready for you list, for someone with no morning brief. Never written twice.
    @discardableResult static func card(_ date: String, _ lines: [String]) -> URL? {
        // Only the person's own One (or a test in its scratch world) ever puts a card in their Documents, never a test copy.
        guard !lines.isEmpty, !hasMorningBrief, Env.selfTest || Bundle.main.bundleIdentifier == TestWorld.productionID else { return nil }
        let u = Shelf.folder.appendingPathComponent("\(date) Last night's review.md")
        guard !FileManager.default.fileExists(atPath: u.path) else { return u }
        try? FileManager.default.createDirectory(at: Shelf.folder, withIntermediateDirectories: true)
        let text = "# Last night's review\n\n" + lines.joined(separator: "\n\n") + "\n"
        return (try? text.write(to: u, atomically: true, encoding: .utf8)) != nil ? u : nil
    }

    /// `One --improve morning [--date D]`: the note's lines for the morning brief, or nothing.
    static func morningCLI(_ a: [String]) -> Int32 {
        let date = ImproveCLI.value(a, "--date") ?? Improve.dayKey(Date())
        let lines = morning(date)
        lines.forEach { print($0) }
        card(date, lines)
        return 0
    }

    /// Told to the assistant on every prompt (SessionNotes).
    static var note: String {
        "\n\n(One app note, not from the user: if they say \"undo last night\", run `\(Bridge.exe) --improve undo-last-night` and tell them in plain words what came back.)"
    }
}
