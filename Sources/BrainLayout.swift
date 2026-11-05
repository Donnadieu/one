import Foundation

// MARK: - The assistant's own folder in the brain (storage design 3a, 3c item 1)
//
// `My Brain/assistant/` holds what's read in every room: the person's rules for the assistant, facts about this
// Mac, longer notes, general recipes and a readable list of routines. Made on first launch and, for brains made
// before it existed, at launch. Nothing that's already there is ever overwritten.

enum BrainLayout {
    static func assistant(_ brain: URL = Brain.root) -> URL { brain.appendingPathComponent("assistant", isDirectory: true) }
    static func skills(_ brain: URL = Brain.root) -> URL { assistant(brain).appendingPathComponent("skills", isDirectory: true) }

    static let starters: [(String, String)] = [
        (
            "how-to-work-with-me.md",
            "# How to work with me\n\nYour rules for the assistant go here, in your own words: how you like answers, what to always do, what never to do.\n"
        ),
        ("this-mac.md", "# This Mac\n\n## Always on\n"),
        ("routines.md", "# Routines\n"),
    ]

    /// Creates `assistant/` with its starter files and folders where missing. Returns what it made.
    @discardableResult static func ensure(_ brain: URL = Brain.root) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: brain.appendingPathComponent("AGENTS.md").path) else { return [] }
        var made: [String] = []
        let a = assistant(brain)
        for d in ["notes", "skills"] {
            let u = a.appendingPathComponent(d, isDirectory: true)
            if !fm.fileExists(atPath: u.path), (try? fm.createDirectory(at: u, withIntermediateDirectories: true)) != nil { made.append(d + "/") }
        }
        for (name, text) in starters {
            let f = a.appendingPathComponent(name)
            if !fm.fileExists(atPath: f.path), (try? text.write(to: f, atomically: true, encoding: .utf8)) != nil { made.append(name) }
        }
        return made
    }

    /// The line a new brain's AGENTS.md gets, so the assistant may write in `assistant/` (it writes nothing else
    /// outside a room).
    static let exception =
        "- Exception: `assistant/` holds the assistant's own notes, recipes and routines list (read in every room, so nothing private goes there); the assistant may write there."

    /// Adds `exception` to a brain's AGENTS.md once: after the "write only into that room" rule, else after the
    /// sentence saying nothing is written outside a room, else at the end. True when the file has it afterwards.
    @discardableResult static func addException(_ agents: URL) -> Bool {
        guard var t = try? String(contentsOf: agents, encoding: .utf8) else { return false }
        return addException(&t) && (try? t.write(to: agents, atomically: true, encoding: .utf8)) != nil
    }
    static func addException(_ t: inout String) -> Bool {
        if t.contains("`assistant/`") { return true }
        var lines = t.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.contains("**Write only into that room:**") }) {
            lines.insert(exception, at: i + 1)
        } else if let i = lines.firstIndex(where: { $0.contains("writes nothing outside a room") }) {
            lines.insert(contentsOf: ["", String(exception.dropFirst(2))], at: i + 1)
        } else {
            lines += ["", String(exception.dropFirst(2))]
        }
        t = lines.joined(separator: "\n")
        return true
    }
}
