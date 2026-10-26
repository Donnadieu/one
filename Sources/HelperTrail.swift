import Foundation

// MARK: - Helpers never get lost: One keeps a trail of what each helper did, and picks up the ones a restart cut off.

/// One itself (not the helper) writes `Support/One/helpers/<id>.md` for every helper: the whole job,
/// when it started, the plain-words steps it took and its latest reply, saved as it goes. When One
/// stopped while a helper was working, the next launch sends that helper its job again with this trail,
/// at most `maxResumes` times, keeping the limit of 3 working at once.
@MainActor
enum HelperTrail {
    static let maxResumes = 2
    static let maxWorking = 3
    static var folder: URL { Env.support.appendingPathComponent("helpers", isDirectory: true) }
    static func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).md") }
    private static var lastWrite: [UUID: Date] = [:]

    /// The trail file: job, start time, steps so far and the latest reply.
    static func text(_ h: Helper) -> String {
        let when = DateFormatter.localizedString(from: h.started ?? Date(), dateStyle: .medium, timeStyle: .short)
        var out = "# \(h.title)\n\nStarted: \(when)\n"
        if let n = h.resumes, n > 0 { out += "Picked back up after a restart: \(n) time\(n == 1 ? "" : "s")\n" }
        out += "\n## The job\n\n\(h.task)\n\n## Steps so far\n\n"
        let steps = h.trail ?? []
        out += steps.isEmpty ? "(none yet)\n" : steps.map { "- \($0)" }.joined(separator: "\n") + "\n"
        let r = h.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n## Latest reply\n\n\(r.isEmpty ? "(nothing yet)" : r)\n"
        return out
    }

    /// Save the trail. Steps save right away; streaming reply text at most every 2 seconds unless forced.
    static func flush(_ h: Helper, force: Bool = true) {
        let now = Date()
        if !force, let last = lastWrite[h.id], now.timeIntervalSince(last) < 2 { return }
        lastWrite[h.id] = now
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? text(h).write(to: url(h.id), atomically: true, encoding: .utf8)
    }

    /// Add one plain-words step (repeats of the same step in a row are kept once).
    static func add(_ step: String, to h: inout Helper) {
        let s = step.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, h.trail?.last != s else { return }
        var t = h.trail ?? []
        t.append(s)
        if t.count > 200 { t.removeFirst(t.count - 200) }
        h.trail = t
    }

    /// What the helper is told when it's picked back up.
    static func resumePrompt(_ h: Helper, brief: String) -> String {
        let steps = (h.trail ?? []).map { "- \($0)" }.joined(separator: "\n")
        var r = h.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.count > 4000 { r = String(r.suffix(4000)) }
        let did = (steps.isEmpty ? "(no steps were recorded)" : steps) + (r.isEmpty ? "" : "\n\nYour last words before the restart:\n\(r)")
        return """
            You were interrupted by a restart. Here's what you already did:
            \(did)

            (The full trail is saved in \(url(h.id).path).) Check the real state first (files, git, releases) before redoing anything, then finish the job. Being picked back up is not a yes: anything that sends, posts, spends money or deletes still needs their yes, as usual.

            Your original job, as you were given it:

            """ + brief
    }

    static func told(_ title: String) -> String { "\(title) was interrupted by a restart. I picked it back up." }
    static func gaveUp(_ n: Int) -> String { "Stopped: cut off by a restart \(n + 1) times · tap to see what it did" }

    /// At launch: helpers that were working (or waiting to be picked back up) when One stopped are
    /// queued to resume, unless they were already picked up `maxResumes` times.
    static func restore(_ hs: [Helper]) -> [Helper] {
        var hs = hs
        for k in hs.indices where hs[k].state == "working" || hs[k].resumeQueued == true {
            hs[k].state = "stopped"
            if (hs[k].resumes ?? 0) < maxResumes {
                hs[k].resumeQueued = true
                hs[k].line = "Cut off by a restart · picking it back up"
            } else {
                hs[k].resumeQueued = false
                hs[k].line = gaveUp(hs[k].resumes ?? 0)
                hs[k].reply = hs[k].reply.isEmpty ? "I couldn't finish this. One restarted while I was working, more than once." : hs[k].reply
            }
        }
        return hs
    }

    /// Queued helpers to start now (oldest first, never more than 3 working). Marks them working,
    /// counts the resume and leaves a note for the assistant. Returns each helper's id and the prompt to send.
    static func pick(_ hs: inout [Helper], brief: (String) -> String) -> [(id: UUID, prompt: String)] {
        var out: [(id: UUID, prompt: String)] = []
        for k in hs.indices where hs[k].resumeQueued == true {
            guard hs.filter({ $0.state == "working" }).count < maxWorking else { break }
            let prompt = resumePrompt(hs[k], brief: brief(hs[k].task))
            hs[k].resumeQueued = false
            hs[k].resumes = (hs[k].resumes ?? 0) + 1
            hs[k].state = "working"
            hs[k].line = "Picking up where it left off…"
            hs[k].restartNews = told(hs[k].title)
            out.append((hs[k].id, prompt))
        }
        return out
    }

    /// The old conversation if the engine can reopen it, otherwise a new one.
    static func session(old: String?, reopen: (String) async -> Bool, open: () async -> String?) async -> String? {
        if let old, await reopen(old) { return old }
        return await open()
    }
}
