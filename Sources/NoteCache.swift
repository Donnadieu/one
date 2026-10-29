import Foundation

// MARK: - The long app notes go once per conversation, not on every turn
//
// Every prompt used to carry about 10 KB of the same notes (helpers, stop, blocked, screen, logins, Chrome, GitHub,
// folders, version, browser), for a 40-character message. Over a long day that buried the conversation under
// repeated rules and the assistant started acting on them oddly (reading tags aloud). Now the whole set goes on the
// first turn of each conversation after One opens, again whenever any of it changes (a new folder, a new version,
// a shared-room clash), and again every `every` turns so a long conversation never loses it. Every other turn gets
// one short line saying the earlier notes still apply, plus what changes turn by turn (helper status, room notes).
// No rule is dropped; each is said once.
@MainActor
enum NoteCache {
    /// Turns between two full copies of the notes, so a long conversation (or one the engine shortened) keeps them.
    static let every = 20
    static let reminder =
        "\n\n(One app note, not from the user: the One app notes given earlier in this conversation still apply. Only changes are sent from now on.)"
    private static var sent: [String: (hash: Int, turns: Int)] = [:]

    /// The full notes when this conversation hasn't had them since One opened, they changed, or it's time again;
    /// otherwise the short reminder. No conversation id yet: always the full notes.
    static func pack(_ sid: String?, rules: String) -> String {
        guard let sid, !sid.isEmpty else { return rules }
        let h = rules.hashValue
        if let s = sent[sid], s.hash == h, s.turns < every {
            sent[sid] = (h, s.turns + 1)
            return reminder
        }
        sent[sid] = (h, 1)
        return rules
    }

    /// A turn that never reached the engine: send the full notes again next time.
    static func forget(_ sid: String?) {
        if let sid { sent[sid] = nil }
    }

    /// Tests only.
    static func reset() { sent = [:] }
}
