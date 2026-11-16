import Foundation

// MARK: - A [helper: Title | job] tag is opaque
// Oct 28, 2026: two helpers never started because their job text quoted "[close-helper: …]" and "[stop-helper: …]".
// The stop/close tags were read first, anywhere in the reply, so each helper line was cut in two: nothing started,
// the whole job text showed in the chat and was read aloud, and a close ran on a made-up name.
// Nov 10, 2026: a job over several paragraphs was read only to the end of its first line (see TagLines.swift).
// Now every tag comes out in one pass, outermost first, each to its own closing "]": nothing inside a helper's job
// is ever read as a stop, close, tell, choices or job-kind tag, and every paragraph of it reaches the helper.
// Checked by `One --test-helpers` (HelperCheck.swift, HelperSpanCheck.swift) and `make helpers-check` (HelperStress.swift).

extension Helpers {
    /// The tags in a finished reply, read in one pass, outermost first: helper tags, tell tags, stop and close tags,
    /// each whole. A stop, close or tell quoted inside a helper's job (or a stop or close quoted inside a tell's
    /// message) is part of that job or message, never acted on.
    typealias Tags = (said: String, jobs: [(String, String)], stops: [String], closes: [String], tells: [(String, String)])
    static func read(_ reply: String) -> Tags {
        let c = Array(reply)
        let hs = TagLines.hits(c, tags: TagLines.acted, streaming: false)
        guard !hs.isEmpty else { return (reply, [], [], [], []) }
        TagLines.logOpen(hs)
        var jobs: [(String, String)] = []
        var tells: [(String, String)] = []
        var stops: [String] = []
        var closes: [String] = []
        var seen = Set<String>()
        for h in hs {
            guard let body = h.body else { continue }
            switch h.tag {
            case "helper":
                let j = job(body)
                if let j { jobs.append(j) } else { logOdd("[helper:" + body, started: false) }  // never shown either way
            case "tell-helper":
                if let t = HelperTell.parts(body) { tells.append(t) }  // one with no "|" never shows either
            default:
                let n = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty, seen.insert(h.tag + ":" + n.lowercased()).inserted else { continue }  // the same line twice counts once
                if h.tag == "stop-helper" { stops.append(n) } else { closes.append(n) }  // [done-helper: …] or the older [close-helper: …]
            }
        }
        return (TagLines.cut(c, hs), jobs, stops, closes, tells)
    }

    /// Title and job from what's after "[helper:": the title is the text up to the first "|" (one line), the job
    /// everything after it, every paragraph. nil when there's no title or no job.
    static func job(_ body: String) -> (String, String)? {
        guard let bar = body.firstIndex(of: "|") else { return nil }
        let title = body[..<bar].trimmingCharacters(in: .whitespacesAndNewlines)
        let task = body[body.index(after: bar)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("\n"), !task.isEmpty else { return nil }
        return (title, task)
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

@MainActor
extension Model {
    /// Acts on the tags of one finished reply, in the order that keeps them apart, and returns a plain line for each
    /// that matched nothing ("I couldn't find a helper called …"). The same for One's own chat and a phone-chat
    /// reply (PhoneTags.swift: `phone` = where it came from, so the result goes back there).
    func actOn(_ tags: Helpers.Tags, typed: String, phone: String? = nil) -> [String] {
        var misses: [String] = []
        // "[stop-helper: …]": stopped first, so a helper sent in the same reply is never caught by "all".
        for s in tags.stops { if let miss = stopHelpers(named: s) { misses.append(miss) } }
        // "[done-helper: …]" (or the older "[close-helper: …]"): asked to take an orb off the screen. The only way besides
        // Got it in its thread. After the stops, so "stop it and clear it" in one reply works.
        for s in tags.closes { if let miss = closeHelpers(named: s) { misses.append(miss) } }
        // "[tell-helper: Title | message]": passes a message into that helper's thread, just as typing in its orb
        // would. After the stops/closes, so a helper stopped or cleared in the same reply is never told anything.
        for (name, msg) in tags.tells { if let miss = tellHelpers(named: name, message: msg) { misses.append(miss) } }
        let (jobs, skipped) = Helpers.unique(tags.jobs, among: helpers)  // the same job twice starts one helper
        Helpers.logSkipped(skipped)
        if !jobs.isEmpty {
            // Started after the stops, so a helper sent in the same reply is never caught by "all".
            let routine = Helpers.isRoutine(typed) ? UUID() : nil  // a good morning or status report: one combined report later
            for j in jobs { spawnHelper(title: j.0, task: j.1, routine: routine, phone: phone) }
        }
        return misses
    }
}
