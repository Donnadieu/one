import Foundation

// MARK: - Helpers never falsely done, never doubled, never lost to a restart
// Checked end to end by `make helpers-check` (HelperStress.swift, tools/helpers-check.sh).

extension Helpers {
    /// The engine sometimes delivers one reply twice in a row (Oct 27, 2026: "Sending all three now." twice,
    /// and six helpers instead of three). A reply that is exactly the same block twice is shown once.
    static func undouble(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 40 else { return text }
        let chars = Array(t)
        // The two copies may be joined by nothing or by whitespace.
        for gap in 0...2 {
            let rest = chars.count - gap
            guard rest > 0, rest % 2 == 0 else { continue }
            let half = rest / 2
            let a = String(chars[0..<half])
            let b = String(chars[(half + gap)...])
            if a == b, String(chars[half..<(half + gap)]).allSatisfy(\.isWhitespace) { return a }
        }
        return text
    }

    static func key(_ title: String, _ task: String) -> String {
        (title + "|" + task).lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Each job once: the same title and job twice in one reply starts one helper, and a job already at work
    /// (or sent in the last 2 minutes) isn't started again. Returns the jobs to start and the ones skipped.
    static func unique(_ jobs: [(String, String)], among hs: [Helper], now: Date = Date()) -> (keep: [(String, String)], skipped: [String]) {
        var seen = Set<String>()
        for h in hs where h.state == "working" || h.resumeQueued == true || now.timeIntervalSince(h.started ?? .distantPast) < 120 {
            seen.insert(key(h.title, h.task))
        }
        var keep: [(String, String)] = []
        var skipped: [String] = []
        for j in jobs {
            if seen.insert(key(j.0, j.1)).inserted { keep.append(j) } else { skipped.append(j.0) }
        }
        return (keep, skipped)
    }

    /// One line per skipped duplicate in hermes/logs/one-helpers.log.
    static func logSkipped(_ titles: [String]) {
        guard !titles.isEmpty else { return }
        let dir = Env.hermesHome.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("one-helpers.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let lines = titles.map { "\(stamp) skipped a second copy of helper \"\($0)\" (same job already sent)\n" }.joined()
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data(lines.utf8))
            try? h.close()
        } else {
            try? lines.write(to: u, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
extension Model {
    /// Start the engine again when it's gone (it crashed or was killed) so the helpers it cut off can pick back up.
    /// Command-line modes never start an engine, except a test's own stand-in in its throwaway home.
    func startEngineAgain() async {
        guard !Engine.shared.running else { return }
        if Env.commandLine {
            guard Env.selfTest else { return }
            _ = await Engine.shared.ensureStarted()
        } else {
            await ensureEngine()
        }
    }
}
