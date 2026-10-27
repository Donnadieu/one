import Foundation

// MARK: - What a helper's own session is told: it does the work itself; only the main assistant sends helpers.

extension Helpers {
    /// Every prompt to a helper's own session carries this instead of the main assistant's helper note:
    /// helpers do the work themselves, and only the main assistant's [helper: …] lines start anything.
    static var helperNote: String {
        let user = UserDefaults.standard.string(forKey: "userName") ?? ""
        return
            "\n\n(One app note, not from the user: You are a helper working on one job. Do the work yourself with your own tools. Never write [helper: …] lines; they do nothing here. If the job truly needs a separate parallel job, say so in one plain line and \(user.isEmpty ? "their" : user + "'s") assistant will send it.)"
    }
    static func forHelper(_ text: String) -> String {
        text.contains("(One app note, not from the user: You are a helper working on one job.") ? text : text + helperNote
    }
    /// A helper wrote "[helper: …]" lines anyway: they're taken out of what's shown, logged, and never started.
    static func dropStrayLines(_ text: String, helper title: String) -> String {
        let (clean, jobs) = extract(text)
        let loose = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[helper") }
        guard !jobs.isEmpty || !loose.isEmpty else { return text }
        for l in loose { log("helper \"\(title)\" wrote a helper line (not started): \(short(l.trimmingCharacters(in: .whitespaces), 200))") }
        return strip(clean)
    }
    static func log(_ s: String) {
        let f = Env.hermesHome.appendingPathComponent("logs/one-helpers.log")
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}
