import Foundation

// MARK: - Helpers never get lost: One keeps a trail of what each helper did, and picks up the ones a restart cut off.

/// One itself (not the helper) writes `Support/One/helpers/<id>.md` for every helper: the whole job,
/// when it started, the plain-words steps it took and its latest reply, saved as it goes. When One
/// stopped while a helper was working, the next launch sends that helper its job again with this trail,
/// at most `maxResumes` times. There's no limit on how many work at once: the engine runs every
/// conversation in parallel (`max_concurrent_sessions` is unset in its config).
@MainActor
enum HelperTrail {
    static let maxResumes = 2
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

    static let stoppedLine = "Stopped by you · tap to see what it did"
    /// The person stopped this helper on purpose. It stays stopped, even after a restart.
    /// Returns true if it was working (so its conversation should be cancelled too).
    @discardableResult
    static func stopByYou(_ h: inout Helper) -> Bool {
        guard h.state == "working" || h.resumeQueued == true else { return false }
        let wasWorking = h.state == "working"
        h.state = "stopped"
        h.resumeQueued = false
        h.stoppedByYou = true
        h.updatePaused = nil
        h.line = stoppedLine
        add("Stopped by you", to: &h)
        return wasWorking
    }

    static func told(_ title: String) -> String { "\(title) was interrupted by a restart. I picked it back up." }
    static func toldUpdate(_ title: String, for reason: String? = nil) -> String {
        "\(title) was paused for \(reason ?? "the update"). I picked it back up."
    }
    static func gaveUp(_ n: Int) -> String { "Stopped: cut off by a restart \(n + 1) times · tap to see what it did" }

    /// At launch: helpers that were working (or waiting to be picked back up) when One stopped are
    /// queued to resume, unless they were already picked up `maxResumes` times. Helpers the person
    /// stopped on purpose stay stopped.
    static func restore(_ hs: [Helper]) -> [Helper] {
        var hs = hs
        for k in hs.indices where hs[k].stoppedByYou == true && (hs[k].state == "working" || hs[k].resumeQueued == true) {
            hs[k].state = "stopped"
            hs[k].resumeQueued = false
            hs[k].line = stoppedLine
        }
        for k in hs.indices where hs[k].state == "working" || hs[k].resumeQueued == true {
            hs[k].state = "stopped"
            if hs[k].updatePaused == true {
                // Paused so an update could install: always picked back up, and it doesn't count as a cut-off.
                hs[k].resumeQueued = true
                hs[k].line = hs[k].pausedFor == nil ? HelperStop.pausedLine : FolderWatch.pausedLine
            } else if (hs[k].resumes ?? 0) < maxResumes {
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

    /// Queued helpers to start now (all of them, oldest first). Marks them working,
    /// counts the resume and leaves a note for the assistant. Returns each helper's id and the prompt to send.
    static func pick(_ hs: inout [Helper], brief: (String) -> String) -> [(id: UUID, prompt: String)] {
        var out: [(id: UUID, prompt: String)] = []
        for k in hs.indices where hs[k].resumeQueued == true && hs[k].stoppedByYou != true {
            let prompt = resumePrompt(hs[k], brief: brief(hs[k].task))
            hs[k].resumeQueued = false
            let update = hs[k].updatePaused == true
            let reason = hs[k].pausedFor
            hs[k].updatePaused = nil
            hs[k].pausedFor = nil
            // A retry while its old turn was still finishing isn't another cut-off.
            if !update, hs[k].busyTries == nil { hs[k].resumes = (hs[k].resumes ?? 0) + 1 }
            hs[k].state = "working"
            hs[k].line = "Picking up where it left off…"
            hs[k].restartNews = update ? toldUpdate(hs[k].title, for: reason) : told(hs[k].title)
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
