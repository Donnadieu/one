import Foundation

// MARK: - Look-only helpers really can't change anything

/// A helper sent only to check or report is "look only": its job starts with `Look only:` (the main assistant adds
/// it, per SOUL and its per-prompt note). One then writes a mark for the helper's engine conversation into
/// `guard/look-only/<session>.json`, a folder the engine can read but never write (`BrowserGuard.lockedPaths`).
/// The engine plugin (`tools/overlay/plugins/one-browser-guard`) reads that mark before every terminal command and
/// script, and blocks saving or pushing code (git commit, push, tag, merge…), releases, pull requests and issues,
/// installing apps and posting; the helper gets a plain message telling it to say what it wanted to do instead.
/// Their own message in that helper's thread lifts it: they're the one asking now.
enum LookOnly {
    static let tag = "Look only:"
    static var dir: URL { BrowserGuard.dir.appendingPathComponent("look-only", isDirectory: true) }
    static func file(_ sid: String) -> URL { dir.appendingPathComponent(safe(sid) + ".json") }

    /// The job starts with "Look only" (any case, "look-only" too, then ":" or a dash).
    static func marked(_ task: String) -> Bool {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.range(of: #"^\(?look[ -]only\)?\s*[:\-–—]"#, options: .regularExpression) != nil
    }

    /// The engine conversation of a look-only helper gets its mark (again after a restart or a new session).
    static func mark(_ sid: String, title: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: file(sid).path) else { return }
        let j: [String: Any] = ["session": sid, "title": title, "at": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: file(sid), options: .atomic) }
        prune()
    }
    static func lift(_ sid: String) { try? FileManager.default.removeItem(at: file(sid)) }
    static func isMarked(_ sid: String) -> Bool { FileManager.default.fileExists(atPath: file(sid).path) }

    /// Marks older than two weeks go (their helpers are long gone).
    static func prune(now: Date = Date()) {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(at) > 14 * 86400 { try? fm.removeItem(at: f) }
        }
    }
    static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) }

    /// The plain line in the helper's own steps.
    static let trailLine = "Look only: it can't save, push, release, install or post"

    /// The main assistant: how to send a look-only helper (SOUL and the per-prompt helper note).
    static let soul =
        "If a helper's job is only to check, look into or report on something (it must change nothing), start its job with \"Look only:\", like [helper: Check the build | Look only: see why last night's build failed and report back.]. One then makes sure that helper can't save or push code, publish a release, install apps or post anything; it tells them what it wanted to do instead."
    static var note: String { "\n\n(One app note, not from the user: LOOK-ONLY HELPERS. \(soul))" }

    /// The helper itself, in its first prompt.
    static func helperNote(_ user: String) -> String {
        "\n\n(One app note, not from the user: LOOK ONLY. You were sent only to look and report. One blocks this helper from "
            + "saving or pushing code (git commit, push, tag, merge), releases, pull requests, installing apps and posting. Don't "
            + "look for a way around it. If something should change, say exactly what you would do and why, and ask "
            + "\(user.isEmpty ? "them" : user), ending with [choices: Do it | Not now]. Their answer in this thread lets you go ahead.)"
    }
}

@MainActor
extension Model {
    /// Every helper turn: a look-only helper's current conversation carries its mark.
    func syncLookOnly(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.lookOnly == true, let sid = h.sid else { return }
        LookOnly.mark(sid, title: h.title)
    }
    /// They wrote to a look-only helper in its own thread: from now on it may do what they ask.
    func liftLookOnly(_ id: UUID) {
        guard let h = helpers.first(where: { $0.id == id }), h.lookOnly == true else { return }
        if let sid = h.sid { LookOnly.lift(sid) }
        update(id) {
            $0.lookOnly = false
            HelperTrail.add("You answered it: look only lifted", to: &$0)
        }
        Helpers.log("helper \"\(h.title)\": look only lifted by their message in its thread")
    }
}
