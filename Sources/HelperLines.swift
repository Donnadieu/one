import Foundation

// MARK: - A [helper: Title | job] line is opaque
// Oct 28, 2026: two helpers never started because their job text quoted "[close-helper: …]" and "[stop-helper: …]".
// The stop/close tags were read first, anywhere in the reply, so each helper line was cut in two: nothing started,
// the whole job text showed in the chat and was read aloud, and a close ran on a made-up name.
// Now helper lines come out first, whole; nothing inside one is ever read as a stop, close, choices or job-kind tag.
// Checked by `One --test-helpers` (HelperCheck.swift) and `make helpers-check` (HelperStress.swift).

extension Helpers {
    /// The tags in a finished reply, read in the only safe order: helper lines first, whole; then the stop and close
    /// lines in what's left. A stop or close quoted inside a helper's job is part of that job, never acted on.
    static func read(_ reply: String) -> (said: String, jobs: [(String, String)], stops: [String], closes: [String]) {
        let (clean, jobs) = extract(reply)
        var said = jobs.isEmpty && !reply.components(separatedBy: "\n").contains(where: isLine) ? reply : clean
        let (unstopped, stops) = HelperStop.extract(said)
        if !stops.isEmpty { said = unstopped }
        let (unclosed, closes) = HelperStop.extract(said, tag: "close-helper")
        if !closes.isEmpty { said = unclosed }
        return (said, jobs, stops, closes)
    }

    /// A line the assistant meant as a helper: it starts with "[helper:". Never shown, never spoken.
    static func isLine(_ l: String) -> Bool {
        l.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[helper:")
    }

    /// Splits a reply into what's left to say and the helper lines, each whole. A helper line that doesn't end in "]"
    /// takes the following lines up to the one that does (the job ran onto a new line), if one comes before a blank line.
    static func lines(_ text: String) -> (keep: [String], helpers: [String]) {
        let all = text.components(separatedBy: "\n")
        var keep: [String] = []
        var found: [String] = []
        var i = 0
        while i < all.count {
            let tl = all[i].trimmingCharacters(in: .whitespaces)
            guard isLine(tl) else {
                keep.append(all[i])
                i += 1
                continue
            }
            var line = tl
            var j = i
            if !tl.hasSuffix("]") {
                var k = i + 1
                while k < all.count, k <= i + 10 {
                    let n = all[k].trimmingCharacters(in: .whitespaces)
                    if n.isEmpty || n.hasPrefix("[") { break }  // a new tag line ([choices: …], another helper) is never part of it
                    if n.hasSuffix("]") {
                        line = all[i...k].map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                        j = k
                        break
                    }
                    k += 1
                }
            }
            found.append(line)
            i = j + 1
        }
        return (keep, found)
    }

    /// Title and job from one helper line: the title is the text up to the first "|", the job the rest up to the last "]".
    /// Recovers a line that lost its closing "]" too. nil when there's no title or no job.
    static func parse(_ line: String) -> (String, String)? {
        let tl = line.trimmingCharacters(in: .whitespaces)
        guard isLine(tl) else { return nil }
        var body = Substring(tl.dropFirst(8))
        if let k = body.lastIndex(of: "]") { body = body[..<k] }
        let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// A helper line that wasn't written right: logged to hermes/logs/one-helpers.log (started anyway when it could be read).
    static func logOdd(_ line: String, started: Bool) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let what = started ? "read a helper line that wasn't written right, started it anyway" : "couldn't read a helper line, hid it"
        appendLog("\(stamp) \(what): \(String(line.prefix(300)))\n")
    }
    static func appendLog(_ text: String) {
        let dir = Env.hermesHome.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("one-helpers.log")
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
    }
}
