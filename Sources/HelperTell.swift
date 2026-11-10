import Foundation

// MARK: - Passing a message to a working (or finished) helper (Omar: "tell Switch AI bug to skip the tests",
// "let all helpers know I'm going to bed"). The main chat can only start, stop or clear a helper with its tags;
// typing inside its orb already sends it a message while it works. [tell-helper: …] reuses that exact path,
// so the assistant can do the same thing from the main chat without the person opening the orb themselves.

enum HelperTell {
    /// Told to the assistant on every prompt (old conversations never see a new SOUL).
    static var note: String {
        "\n\n(One app note, not from the user: when they say \"tell <helper> …\", \"let <helper> know …\" or \"tell all helpers …\", "
            + "add a line exactly like [tell-helper: <its exact title> | <the message>] or [tell-helper: all | <the message>], "
            + "and confirm in one short line, like \"Sent to Switch AI bug.\" Never invent a message they didn't ask for. "
            + "Match titles case-insensitively; if the name is unclear, ask which one.)"
    }
    /// The same rule in the assistant's SOUL (`Persona.write`).
    static let soul =
        "When they say \"tell <helper> …\", \"let <helper> know …\" or \"tell all helpers …\", add a line exactly like "
        + "[tell-helper: Flight to Quebec | Skip the tests, I just need the flight] or [tell-helper: all | I'm going to bed], "
        + "and confirm in one short line, like \"Sent to Flight to Quebec.\" Never invent a message they didn't ask for. "
        + "Match titles case-insensitively; if the name is unclear, ask which one."

    /// Pull "[tell-helper: Title | message]" lines out of the assistant's reply. Like a helper line, the whole tag is
    /// opaque: it runs to the "]" that balances its own "[" (TagLines.swift), so a [choices: …] tag, a link or code
    /// inside the message reaches the helper whole and nothing of it shows or is spoken. This runs on what
    /// `Helpers.read` has left after helper lines come out, so a tell quoted inside a helper's own job text (as in
    /// the Oct 28 fix for stop/close) is part of that job, never acted on here.
    static func extract(_ text: String) -> (String, [(String, String)]) {
        let (rest, bodies) = TagLines.extract(text, tag: "tell-helper")
        return (rest, bodies.compactMap(parts))
    }
    /// Title and message from what's after "[tell-helper:"; every line of the message kept. nil without both.
    static func parts(_ body: String) -> (String, String)? {
        let p = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return p.count == 2 && !p[0].isEmpty && !p[1].isEmpty ? (p[0], p[1]) : nil
    }
    /// While a reply streams in: hide a tell line, even half-written, nested brackets and all.
    static func hide(_ text: String) -> String { TagLines.hide(text, tags: ["tell-helper"]) }

    /// Which helpers a tell line means: "all" = every one still at work or waiting for their yes; a name matches
    /// that exact title (any case, the most recently sent on ties) in ANY state — the same helper typing in its
    /// open orb would reach, finished or stopped included (it reopens the same as typing there does today).
    static func match(_ name: String, in hs: [Helper]) -> [UUID] {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’"))).lowercased()
        if n == "all" { return hs.filter { $0.state == "working" || $0.state == "needsYes" }.map(\.id) }
        let same = hs.enumerated().filter { $0.element.title.lowercased() == n }
        let pick = same.max { a, b in (a.element.started ?? .distantPast, a.offset) < (b.element.started ?? .distantPast, b.offset) }
        return pick.map { [$0.element.id] } ?? []
    }
    static func notFound(_ name: String) -> String { "I couldn't find a helper called \"\(name)\"." }
}

@MainActor
extension Model {
    /// The assistant wrote "[tell-helper: Title | message]" (or "all"): deliver that message into the matched
    /// helper's thread(s). Returns a plain line if nothing matched.
    func tellHelpers(named name: String, message: String) -> String? {
        let ids = HelperTell.match(name, in: helpers)
        if ids.isEmpty {
            let n = name.lowercased().trimmingCharacters(in: .whitespaces)
            if n == "all" { return nil }  // no working/waiting helper to tell: nothing to say
            return HelperTell.notFound(name)
        }
        for id in ids { tellHelper(id, message: message) }
        return nil
    }

    /// Delivers one message into a helper's thread, exactly as if they'd typed it in its orb — the same path
    /// (FollowUps.swift) typing there uses, so it's queued while the helper works and run right away otherwise
    /// (which reopens it if it had already finished or stopped, same as opening its orb and typing would).
    func tellHelper(_ id: UUID, message: String) {
        guard helpers.contains(where: { $0.id == id }) else { return }
        if let c = Goals.command(message) {
            // A /goal command passed on ("/goal resume", "/goal turns 50") runs as one in that helper, the same as typed in
            // its orb: never wrapped in "From …, via …", which made it plain words and left the goal paused.
            Task { @MainActor in
                if await goalTyped(c, text: message, helper: id) { return }
                followUp(Composed(display: message, engine: message, images: [], typed: message), helper: id, hidden: false)
            }
            return
        }
        let who = userName.isEmpty ? "Omar" : userName
        let mark = "From \(who), via \(assistantName): "
        let c = Composed(display: mark + message, engine: mark + message, images: [], typed: message)
        followUp(c, helper: id, hidden: false)
    }
}
